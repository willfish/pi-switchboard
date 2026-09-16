-module(bus_operator_native_h).

%% Bearer native operator HTTP. No CORS. Browser session nonce is not authority.
-export([init/2]).

-define(MAX_BODY, 32768).
-define(REQUEST_TIMEOUT_MS, 5000).

init(Req0, Route) ->
    Deadline = maps:get(bus_deadline, Req0,
        erlang:monotonic_time(millisecond) + ?REQUEST_TIMEOUT_MS),
    Req = Req0#{bus_deadline => Deadline},
    Reply = within_deadline(Req, fun() ->
        case bus_http_h:authorize(Req) of
            false -> error_reply(Req, 401, <<"unauthorized">>, <<"invalid token">>);
            true -> dispatch(Req, Route)
        end
    end),
    {ok, Reply, []}.

dispatch(Req, announce) -> announce(Req);
dispatch(Req, requests) -> requests(Req);
dispatch(Req, content) -> content(Req);
dispatch(Req, results) -> results(Req);
dispatch(Req, activity) -> activity(Req);
dispatch(Req, _) -> error_reply(Req, 404, <<"not_found">>, <<"unknown route">>).

announce(Req) ->
    case cowboy_req:method(Req) of
        <<"POST">> ->
            case cowboy_req:qs(Req) of
                <<>> -> post_announce(Req);
                _ -> error_reply(Req, 400, <<"invalid_schema">>, <<"empty query required">>)
            end;
        _ ->
            cowboy_req:reply(405, #{<<"allow">> => <<"POST">>,
                <<"cache-control">> => <<"no-store">>,
                <<"content-type">> => <<"application/json">>},
                bus_protocol:encode_error(<<"method_not_allowed">>, <<"POST required">>), Req)
    end.

post_announce(Req0) ->
    case json_type(Req0) of
        false -> error_reply(Req0, 400, <<"invalid_schema">>, <<"JSON required">>);
        true ->
            case read_json(Req0) of
                {ok, Map, Req} ->
                    Conn = maps:get(pid, Req),
                    Deadline = maps:get(bus_deadline, Req),
                    case bus_operator_native:announce(Conn, Map, Deadline) of
                        {ok, Receipt} -> json_reply(Req, 200, Receipt);
                        {error, Reason} -> owner_error(Req, Reason)
                    end;
                {error, Status, Code, Message, Req} ->
                    error_reply(Req, Status, Code, Message)
            end
    end.

requests(Req) ->
    case cowboy_req:method(Req) of
        <<"GET">> ->
            case agent_query(Req) of
                {error, Reason} -> owner_error(Req, Reason);
                {ok, AgentId} ->
                    Conn = maps:get(pid, Req),
                    Deadline = maps:get(bus_deadline, Req),
                    case bus_operator_ops:requests(Conn, AgentId, Deadline) of
                        {ok, List} ->
                            json_reply(Req, 200, #{<<"schemaVersion">> => 1,
                                <<"requests">> => List});
                        {error, Reason} -> owner_error(Req, Reason)
                    end
            end;
        _ -> method_not(Req, <<"GET">>)
    end.

content(Req) ->
    case cowboy_req:method(Req) of
        <<"GET">> ->
            case content_query(Req) of
                {error, Reason} -> owner_error(Req, Reason);
                {ok, OpId, ContentId} ->
                    Conn = maps:get(pid, Req),
                    Deadline = maps:get(bus_deadline, Req),
                    case bus_operator_ops:content(Conn, OpId, ContentId, Deadline) of
                        {ok, Body} ->
                            json_reply(Req, 200, #{<<"schemaVersion">> => 1,
                                <<"operationId">> => OpId,
                                <<"contentId">> => ContentId,
                                <<"body">> => Body});
                        {error, Reason} -> owner_error(Req, Reason)
                    end
            end;
        _ -> method_not(Req, <<"GET">>)
    end.

results(Req) ->
    case cowboy_req:method(Req) of
        <<"POST">> ->
            case cowboy_req:qs(Req) of
                <<>> -> post_results(Req);
                _ -> error_reply(Req, 400, <<"invalid_schema">>, <<"empty query required">>)
            end;
        _ -> method_not(Req, <<"POST">>)
    end.

activity(Req) ->
    case cowboy_req:method(Req) of
        <<"POST">> ->
            case cowboy_req:qs(Req) of
                <<>> -> post_activity(Req);
                _ -> error_reply(Req, 400, <<"invalid_schema">>, <<"empty query required">>)
            end;
        _ -> method_not(Req, <<"POST">>)
    end.

post_activity(Req0) ->
    case json_type(Req0) of
        false -> error_reply(Req0, 400, <<"invalid_schema">>, <<"JSON required">>);
        true ->
            case read_json(Req0) of
                {ok, Map, Req} ->
                    Conn = maps:get(pid, Req),
                    Deadline = maps:get(bus_deadline, Req),
                    case bus_operator_activity:report(Conn, Map, Deadline) of
                        {ok, Reply} -> json_reply(Req, 200, Reply);
                        {error, Reason} -> owner_error(Req, Reason)
                    end;
                {error, Status, Code, Message, Req} ->
                    error_reply(Req, Status, Code, Message)
            end
    end.

post_results(Req0) ->
    case json_type(Req0) of
        false -> error_reply(Req0, 400, <<"invalid_schema">>, <<"JSON required">>);
        true ->
            case read_json(Req0) of
                {ok, Map, Req} ->
                    Conn = maps:get(pid, Req),
                    Deadline = maps:get(bus_deadline, Req),
                    case bus_operator_ops:result(Conn, Map, Deadline) of
                        {ok, Public} -> json_reply(Req, 200, Public);
                        {error, Reason} -> owner_error(Req, Reason)
                    end;
                {error, Status, Code, Message, Req} ->
                    error_reply(Req, Status, Code, Message)
            end
    end.

agent_query(Req) ->
    try cowboy_req:parse_qs(Req) of
        [{<<"agentId">>, Id}] ->
            case bus_protocol:is_uuid(Id) of
                true -> {ok, Id};
                false -> {error, invalid_schema}
            end;
        _ -> {error, invalid_schema}
    catch _:_ -> {error, invalid_schema} end.

content_query(Req) ->
    try cowboy_req:parse_qs(Req) of
        Qs ->
            Op = proplists:get_value(<<"operationId">>, Qs),
            Cid = proplists:get_value(<<"contentId">>, Qs),
            Extra = [K || {K, _} <- Qs, K =/= <<"operationId">>, K =/= <<"contentId">>],
            case Extra =:= [] andalso bus_protocol:is_uuid(Op) andalso bus_protocol:is_uuid(Cid) of
                true -> {ok, Op, Cid};
                false -> {error, invalid_schema}
            end
    catch _:_ -> {error, invalid_schema} end.

method_not(Req, Allow) ->
    cowboy_req:reply(405, #{<<"allow">> => Allow,
        <<"cache-control">> => <<"no-store">>,
        <<"content-type">> => <<"application/json">>},
        bus_protocol:encode_error(<<"method_not_allowed">>, <<"method not allowed">>), Req).

json_type(Req) ->
    try cowboy_req:parse_header(<<"content-type">>, Req) of
        {<<"application">>, <<"json">>, _} -> true;
        _ -> false
    catch
        _:_ -> false
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

decode_body(Body, Req) ->
    case remaining(Req) =< 0 of
        true -> body_timeout(Req);
        false ->
            case bus_protocol:decode_json(Body) of
                {ok, Map} when is_map(Map) -> {ok, Map, Req};
                {ok, _} -> {error, 400, <<"invalid_schema">>, <<"object required">>, Req};
                {error, {duplicate_key, _}} ->
                    {error, 400, <<"invalid_schema">>, <<"duplicate keys">>, Req};
                {error, _} ->
                    {error, 400, <<"invalid_schema">>, <<"invalid JSON">>, Req}
            end
    end.

body_timeout(Req) ->
    {error, 503, <<"capacity">>, <<"request timeout">>, Req}.

remaining(Req) ->
    maps:get(bus_deadline, Req) - erlang:monotonic_time(millisecond).

within_deadline(Req, Fun) ->
    case remaining(Req) =< 0 of
        true -> owner_error(Req, timeout);
        false -> Fun()
    end.

owner_error(Req, stale_generation) ->
    error_reply(Req, 409, <<"stale_generation">>, <<"stale generation">>);
owner_error(Req, epoch_reset) ->
    error_reply(Req, 409, <<"epoch_reset">>, <<"store epoch changed">>);
owner_error(Req, conflict) ->
    error_reply(Req, 409, <<"conflict">>, <<"conflicting announcement">>);
owner_error(Req, forbidden) ->
    error_reply(Req, 403, <<"forbidden">>, <<"capability or permission denied">>);
owner_error(Req, expired) ->
    error_reply(Req, 409, <<"expired">>, <<"operation expired">>);
owner_error(Req, unauthorized) ->
    error_reply(Req, 401, <<"unauthorized">>, <<"invalid token">>);
owner_error(Req, invalid_schema) ->
    error_reply(Req, 400, <<"invalid_schema">>, <<"invalid document">>);
owner_error(Req, invalid_work) ->
    error_reply(Req, 400, <<"invalid_schema">>, <<"invalid work snapshot">>);
owner_error(Req, invalid_request) ->
    error_reply(Req, 400, <<"invalid_schema">>, <<"invalid request">>);
owner_error(Req, duplicate_key) ->
    error_reply(Req, 400, <<"invalid_schema">>, <<"duplicate keys">>);
owner_error(Req, envelope) ->
    error_reply(Req, 413, <<"payload_too_large">>, <<"body too large">>);
owner_error(Req, not_found) ->
    error_reply(Req, 404, <<"not_found">>, <<"unknown runtime">>);
owner_error(Req, overloaded) ->
    retry_reply(Req, 503, <<"capacity">>, <<"operator overloaded">>, 1);
owner_error(Req, timeout) ->
    retry_reply(Req, 503, <<"capacity">>, <<"operator timeout">>, 1);
owner_error(Req, unavailable) ->
    retry_reply(Req, 503, <<"capacity">>, <<"operator unavailable">>, 1);
owner_error(Req, stale_slot) ->
    retry_reply(Req, 503, <<"capacity">>, <<"operator unavailable">>, 1);
owner_error(Req, capacity) ->
    retry_reply(Req, 503, <<"capacity">>, <<"operator capacity">>, 2);
owner_error(Req, _) ->
    error_reply(Req, 400, <<"invalid_schema">>, <<"request rejected">>).

json_reply(Req, Status, Map) ->
    cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json">>,
          <<"cache-control">> => <<"no-store">>},
        bus_protocol:encode_map(Map), Req).

error_reply(Req, Status, Code, Message) ->
    cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json">>,
          <<"cache-control">> => <<"no-store">>},
        bus_protocol:encode_error(Code, Message), Req).

retry_reply(Req, Status, Code, Message, Seconds) ->
    cowboy_req:reply(Status,
        #{<<"content-type">> => <<"application/json">>,
          <<"cache-control">> => <<"no-store">>,
          <<"retry-after">> => integer_to_binary(Seconds)},
        bus_protocol:encode_error(Code, Message), Req).
