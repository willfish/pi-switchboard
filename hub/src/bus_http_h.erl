-module(bus_http_h).

-export([init/2, authorize/1]).

-define(MAX_BODY, 32768).
-define(REQUEST_TIMEOUT_MS, 5000).

init(Req, list) ->
    handle(Req, fun list_agents/1);
init(Req, agent) ->
    handle(Req, fun agent/1);
init(Req, messages) ->
    handle(Req, fun messages/1).

authorize(Req) ->
    Expected = application:get_env(pi_agent_bus, token, <<>>),
    case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Token0/binary>> ->
            %% Header obs-text need not be valid UTF-8. Invalid credentials
            %% must fail authentication, not raise from Unicode trimming.
            try secure_compare(string:trim(Token0), Expected)
            catch error:_ -> false end;
        _ ->
            false
    end.

handle(Req0, Fun) ->
    %% Interim fallback starts at handler init, not connection acceptance.
    %% A transport helper must supply bus_deadline for the full request budget;
    %% socket completion and a fenced write watchdog are separate obligations.
    Deadline = maps:get(bus_deadline, Req0,
        erlang:monotonic_time(millisecond) + ?REQUEST_TIMEOUT_MS),
    Req = Req0#{bus_deadline => Deadline},
    Reply = within_deadline(Req, fun() ->
        case authorize(Req) of
            false -> error_reply(Req, 401, <<"unauthorized">>, <<"invalid token">>);
            true -> Fun(Req)
        end
    end),
    {ok, Reply, []}.

remaining(Req) ->
    maps:get(bus_deadline, Req) - erlang:monotonic_time(millisecond).

within_deadline(Req, Fun) ->
    case remaining(Req) =< 0 of
        true -> store_error(Req, timeout);
        false -> Fun()
    end.

list_agents(Req) ->
    case cowboy_req:method(Req) of
        <<"GET">> ->
            case bus_dashboard_authority:allowed_read(Req) of
                false -> error_reply(Req, 403, <<"forbidden">>, <<"request rejected">>);
                true -> list_agents_page(Req)
            end;
        _ ->
            error_reply(Req, 405, <<"method_not_allowed">>, <<"GET required">>)
    end.

list_agents_page(Req) ->
    case discovery_cursor(Req) of
        {ok, Cursor} ->
            case bus_store:list_agents_page(Cursor, maps:get(bus_deadline, Req)) of
                {ok, EncodedPage} -> encoded_json_reply(Req, 200, EncodedPage);
                {error, Reason} -> store_error(Req, Reason)
            end;
        {error, Reason} -> store_error(Req, Reason)
    end.

discovery_cursor(Req) ->
    try cowboy_req:parse_qs(Req) of
        [] -> {ok, first};
        [{<<"cursor">>, Cursor}] when is_binary(Cursor),
                byte_size(Cursor) > 0, byte_size(Cursor) =< 64 -> {ok, Cursor};
        [{<<"cursor">>, _}] -> {error, invalid_cursor};
        _ -> {error, invalid_schema}
    catch _:_ -> {error, invalid_schema} end.

agent(Req) ->
    AgentId = cowboy_req:binding(agent_id, Req),
    case cowboy_req:method(Req) of
        <<"PUT">> ->
            put_agent(Req, AgentId);
        <<"DELETE">> ->
            case bus_protocol:is_uuid(AgentId) of
                false -> schema_error(Req, invalid_schema);
                true ->
                    case bus_store:delete_agent(AgentId, maps:get(bus_deadline, Req)) of
                        ok -> cowboy_req:reply(204, #{}, <<>>, Req);
                        {error, Reason} -> store_error(Req, Reason)
                    end
            end;
        _ ->
            error_reply(Req, 405, <<"method_not_allowed">>, <<"PUT or DELETE required">>)
    end.

messages(Req) ->
    case cowboy_req:method(Req) of
        <<"POST">> ->
            post_message(Req);
        _ ->
            error_reply(Req, 405, <<"method_not_allowed">>, <<"POST required">>)
    end.

put_agent(Req0, AgentId) ->
    case read_json(Req0) of
        {ok, Map, Req} ->
            case bus_protocol:decode_register(Map) of
                {ok, Agent} ->
                    case maps:get(<<"agentId">>, Agent) of
                        AgentId ->
                            case bus_store:put_agent(Agent, maps:get(bus_deadline, Req)) of
                                ok ->
                                    cowboy_req:reply(204, #{}, <<>>, Req);
                                {error, Reason} ->
                                    store_error(Req, Reason)
                            end;
                        _ ->
                            within_deadline(Req, fun() ->
                                error_reply(Req, 400, <<"invalid_schema">>, <<"agentId mismatch">>)
                            end)
                    end;
                {error, Reason} ->
                    schema_error(Req, Reason)
            end;
        {error, Status, Code, Message, Req} ->
            error_reply(Req, Status, Code, Message)
    end.

post_message(Req0) ->
    case read_json(Req0) of
        {ok, Map, Req} ->
            case bus_protocol:decode_message(Map) of
                {ok, Msg} ->
                    case bus_store:accept_mail(Msg, maps:get(bus_deadline, Req)) of
                        {ok, Result} ->
                            json_reply(Req, 202, Result);
                        {error, Reason} ->
                            store_error(Req, Reason)
                    end;
                {error, Reason} ->
                    schema_error(Req, Reason)
            end;
        {error, Status, Code, Message, Req} ->
            error_reply(Req, Status, Code, Message)
    end.

read_json(Req0) ->
    case cowboy_req:header(<<"content-length">>, Req0) of
        undefined ->
            {error, 400, <<"invalid_schema">>, <<"Content-Length required">>, Req0};
        LengthBin ->
            case string:to_integer(binary_to_list(LengthBin)) of
                {N, []} when is_integer(N), N > ?MAX_BODY ->
                    {error, 413, <<"payload_too_large">>, <<"body too large">>, Req0};
                {N, []} when is_integer(N), N >= 0 ->
                    read_chunks(Req0, [], 0);
                _ ->
                    {error, 400, <<"invalid_schema">>, <<"invalid Content-Length">>, Req0}
            end
    end.

read_chunks(Req0, Chunks, Size) ->
    case remaining(Req0) of
        Remaining when Remaining =< 0 -> body_timeout(Req0);
        Remaining ->
            try cowboy_req:read_body(Req0, #{length => ?MAX_BODY - Size + 1,
                    period => Remaining, timeout => Remaining}) of
                {Status, Chunk, Req} ->
                    Total = Size + byte_size(Chunk),
                    case {remaining(Req) =< 0, Total > ?MAX_BODY, Status} of
                        {true, _, _} -> body_timeout(Req);
                        {false, true, _} ->
                            {error, 413, <<"payload_too_large">>, <<"body too large">>, Req};
                        {false, false, more} -> read_chunks(Req, [Chunk | Chunks], Total);
                        {false, false, ok} ->
                            decode_body(iolist_to_binary(lists:reverse([Chunk | Chunks])), Req)
                    end
            catch
                exit:timeout -> body_timeout(Req0);
                exit:{timeout, _} -> body_timeout(Req0)
            end
    end.

body_timeout(Req) ->
    {error, 503, <<"capacity">>, <<"request timeout">>, Req}.

decode_body(Body, Req) ->
    Result = decode_document(Body, Req),
    case remaining(Req) =< 0 of
        true -> body_timeout(Req);
        false -> Result
    end.

decode_document(Body, Req) ->
    case bus_protocol:decode_json(Body) of
        {ok, Map} when is_map(Map) ->
            {ok, Map, Req};
        {ok, _} ->
            {error, 400, <<"invalid_schema">>, <<"object required">>, Req};
        {error, {duplicate_key, _}} ->
            {error, 400, <<"invalid_schema">>, <<"duplicate keys">>, Req};
        {error, _} ->
            {error, 400, <<"invalid_schema">>, <<"invalid JSON">>, Req}
    end.

schema_error(Req, Reason) ->
    within_deadline(Req, fun() -> schema_error_reason(Req, Reason) end).

schema_error_reason(Req, payload_too_large) ->
    error_reply(Req, 413, <<"payload_too_large">>, <<"body too large">>);
schema_error_reason(Req, extra_fields) ->
    error_reply(Req, 400, <<"invalid_schema">>, <<"unknown fields">>);
schema_error_reason(Req, missing_fields) ->
    error_reply(Req, 400, <<"invalid_schema">>, <<"missing fields">>);
schema_error_reason(Req, invalid_schema) ->
    error_reply(Req, 400, <<"invalid_schema">>, <<"invalid document">>);
schema_error_reason(Req, {invalid_field, Key}) ->
    error_reply(Req, 400, <<"invalid_schema">>, <<"invalid field: ", Key/binary>>);
schema_error_reason(Req, _) ->
    error_reply(Req, 400, <<"invalid_schema">>, <<"invalid document">>).

store_error(Req, invalid_cursor) ->
    error_reply(Req, 400, <<"invalid_cursor">>, <<"invalid discovery cursor">>);
store_error(Req, discovery_reset) ->
    error_reply(Req, 409, <<"discovery_reset">>, <<"discovery changed; start a new read">>);
store_error(Req, payload_too_large) ->
    error_reply(Req, 413, <<"payload_too_large">>, <<"message envelope too large">>);
store_error(Req, self_send) ->
    error_reply(Req, 400, <<"self_send">>, <<"cannot send to self">>);
store_error(Req, control_disabled) ->
    error_reply(Req, 403, <<"control_disabled">>, <<"recipient does not accept control">>);
store_error(Req, not_found) ->
    error_reply(Req, 404, <<"not_found">>, <<"unknown runtime">>);
store_error(Req, conflict) ->
    error_reply(Req, 409, <<"conflict">>, <<"message id reused with different payload">>);
store_error(Req, mailbox_full) ->
    retry_reply(Req, 429, <<"mailbox_full">>, <<"recipient mailbox full">>, 1);
store_error(Req, dedup_full) ->
    retry_reply(Req, 503, <<"dedup_full">>, <<"deduplication cache full">>, 1);
store_error(Req, capacity) ->
    retry_reply(Req, 503, <<"capacity">>, <<"hub capacity exhausted">>, 2);
store_error(Req, overloaded) ->
    retry_reply(Req, 503, <<"capacity">>, <<"hub overloaded">>, 1);
store_error(Req, timeout) ->
    retry_reply(Req, 503, <<"capacity">>, <<"store timeout">>, 1);
store_error(Req, unavailable) ->
    retry_reply(Req, 503, <<"capacity">>, <<"store unavailable">>, 1);
store_error(Req, _) ->
    error_reply(Req, 400, <<"invalid_schema">>, <<"request rejected">>).

json_reply(Req, Status, Map) ->
    encoded_json_reply(Req, Status, bus_protocol:encode_map(Map)).

encoded_json_reply(Req, Status, Encoded) ->
    cowboy_req:reply(
        Status,
        #{
            <<"content-type">> => <<"application/json">>,
            <<"cache-control">> => <<"no-store">>
        },
        Encoded,
        Req
    ).

error_reply(Req, Status, Code, Message) ->
    cowboy_req:reply(
        Status,
        #{
            <<"content-type">> => <<"application/json">>,
            <<"cache-control">> => <<"no-store">>
        },
        bus_protocol:encode_error(Code, Message),
        Req
    ).

retry_reply(Req, Status, Code, Message, Seconds) ->
    cowboy_req:reply(
        Status,
        #{
            <<"content-type">> => <<"application/json">>,
            <<"cache-control">> => <<"no-store">>,
            <<"retry-after">> => integer_to_binary(Seconds)
        },
        bus_protocol:encode_error(Code, Message),
        Req
    ).

secure_compare(A, B) when is_binary(A), is_binary(B) ->
    crypto:hash_equals(crypto:hash(sha256, A), crypto:hash(sha256, B));
secure_compare(_, _) ->
    false.
