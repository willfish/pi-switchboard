-module(bus_operator_h).

%% Testable operator HTTP routes. Production dispatch is not wired here.
-export([init/2]).
-ifdef(TEST).
-export([store_error/2]).
-endif.

-define(MAX_BODY, 256).
-define(REQUEST_TIMEOUT_MS, 5000).

init(Req0, Route) ->
    Deadline = maps:get(bus_deadline, Req0,
        erlang:monotonic_time(millisecond) + ?REQUEST_TIMEOUT_MS),
    Req = Req0#{bus_deadline => Deadline},
    {ok, handle(Req, Route), []}.

handle(Req, Route) ->
    case remaining(Req) =< 0 of
        true -> error_reply(Req, 503, <<"capacity">>, <<"request timeout">>);
        false ->
            case mode() of
                disabled -> error_reply(Req, 403, <<"disabled">>, <<"operator api disabled">>);
                Mode -> admit_network(Req, Route, Mode)
            end
    end.

mode() ->
    case application:get_env(pi_agent_bus, operator_access, disabled) of
        disabled -> disabled;
        loopback -> loopback;
        {tailnet, Name} -> {tailnet, Name};
        _ -> disabled
    end.

admit_network(Req, Route, Mode) ->
    case bus_dashboard_authority:allowed_host(Req) of
        false -> error_reply(Req, 403, <<"forbidden">>, <<"request rejected">>);
        true ->
            {Peer, _} = cowboy_req:peer(Req),
            {Local, _} = cowboy_req:sock(Req),
            case bus_operator_access:admit(Mode, Peer, Local) of
                {error, disabled} ->
                    error_reply(Req, 403, <<"disabled">>, <<"operator api disabled">>);
                {error, forbidden} ->
                    error_reply(Req, 403, <<"forbidden">>, <<"request rejected">>);
                {error, unavailable} ->
                    error_reply(Req, 503, <<"capacity">>, <<"operator unavailable">>);
                ok -> dispatch(Req, Route)
            end
    end.

dispatch(Req, session) -> mutation(Req, session);
dispatch(Req, disconnect) -> mutation(Req, disconnect);
dispatch(Req, presence) -> read(Req);
dispatch(Req, _) -> error_reply(Req, 404, <<"not_found">>, <<"unknown route">>).

mutation(Req, Kind) ->
    case cowboy_req:method(Req) of
        <<"POST">> ->
            case bus_dashboard_authority:allowed_mutation(Req) of
                false -> error_reply(Req, 403, <<"forbidden">>, <<"request rejected">>);
                true ->
                    case json_type(Req) of
                        false -> error_reply(Req, 400, <<"invalid_schema">>, <<"JSON required">>);
                        true ->
                            case cowboy_req:qs(Req) of
                                <<>> -> mutate(Req, Kind);
                                _ -> error_reply(Req, 400, <<"invalid_schema">>, <<"empty query required">>)
                            end
                    end
            end;
        _ -> error_reply(Req, 405, <<"method_not_allowed">>, <<"POST required">>)
    end.

read(Req) ->
    case cowboy_req:method(Req) of
        <<"GET">> ->
            case bus_dashboard_authority:allowed_read(Req) of
                false -> error_reply(Req, 403, <<"forbidden">>, <<"request rejected">>);
                true -> present(Req)
            end;
        _ -> error_reply(Req, 405, <<"method_not_allowed">>, <<"GET required">>)
    end.

json_type(Req) ->
    try cowboy_req:parse_header(<<"content-type">>, Req) of
        {<<"application">>, <<"json">>, _} -> true;
        _ -> false
    catch
        _:_ -> false
    end.

mutate(Req0, Kind) ->
    case bounded_length(Req0) of
        {error, Status, Code, Message} ->
            error_reply(Req0, Status, Code, Message);
        ok ->
            Conn = maps:get(pid, Req0),
            Deadline = maps:get(bus_deadline, Req0),
            Bound = bus_operator_http:canonical_origin(Req0),
            case Kind of
                session -> bootstrap(Req0, Bound, Conn, Deadline);
                disconnect -> disconnect(Req0, Bound, Conn, Deadline)
            end
    end.

bootstrap(Req0, Bound, Conn, Deadline) ->
    case bus_operator_http:session_header(Req0) of
        undefined ->
            case occupy(Conn, bootstrap) of
                {error, Reason} -> store_error(Req0, Reason);
                {ok, Ref} ->
                    case read_empty(Req0) of
                        {error, Status, Code, Message, Req} ->
                            error_reply(Req, Status, Code, Message);
                        {ok, Req} ->
                            case admit_current(Conn, Ref) of
                                {error, Stale} -> store_error(Req, Stale);
                                ok ->
                                    {Peer, _} = cowboy_req:peer(Req),
                                    reply_auth(Req,
                                        bus_operator_auth:bootstrap(Peer, Bound, Conn, Deadline))
                            end
                    end
            end;
        _ -> error_reply(Req0, 400, <<"invalid_schema">>, <<"session header not allowed">>)
    end.

disconnect(Req0, Bound, Conn, Deadline) ->
    case nonce(Req0) of
        {error, unauthorized} -> error_reply(Req0, 401, <<"unauthorized">>, <<"invalid session">>);
        {ok, Nonce} ->
            case occupy(Conn, {session, crypto:hash(sha256, Nonce)}) of
                {error, Occupy} -> store_error(Req0, Occupy);
                {ok, Ref} ->
                    case read_empty(Req0) of
                        {error, Status, Code, Message, Req} ->
                            error_reply(Req, Status, Code, Message);
                        {ok, Req} ->
                            case admit_current(Conn, Ref) of
                                {error, Stale} -> store_error(Req, Stale);
                                ok ->
                                    case bus_operator_auth:disconnect(Nonce, Bound, Conn, Deadline) of
                                        ok -> cowboy_req:reply(204, headers(), <<>>, Req);
                                        {error, Auth} -> store_error(Req, Auth)
                                    end
                            end
                    end
            end
    end.

present(Req) ->
    case nonce(Req) of
        {error, unauthorized} -> error_reply(Req, 401, <<"unauthorized">>, <<"invalid session">>);
        {ok, Nonce} ->
            Conn = maps:get(pid, Req),
            Deadline = maps:get(bus_deadline, Req),
            Bound = bus_operator_http:canonical_origin(Req),
            case occupy(Conn, {session, crypto:hash(sha256, Nonce)}) of
                {error, Occupy} -> store_error(Req, Occupy);
                {ok, Ref} ->
                    case admit_current(Conn, Ref) of
                        {error, Stale} -> store_error(Req, Stale);
                        ok ->
                            case bus_operator_auth:authorize(Nonce, Bound, Conn, Deadline) of
                                {ok, _} -> presence_page(Req, Deadline);
                                {error, Auth} -> store_error(Req, Auth)
                            end
                    end
            end
    end.

presence_page(Req, Deadline) ->
    case discovery_cursor(Req) of
        {error, CursorErr} -> store_error(Req, CursorErr);
        {ok, Cursor} ->
            case bus_store:list_agents_page(Cursor, Deadline) of
                {ok, Encoded} ->
                    cowboy_req:reply(200, headers(#{<<"content-type">> => <<"application/json">>}),
                        Encoded, Req);
                {error, Reason} -> store_error(Req, Reason)
            end
    end.

discovery_cursor(Req) ->
    try cowboy_req:parse_qs(Req) of
        [] -> {ok, first};
        [{<<"cursor">>, Cursor}] when is_binary(Cursor),
                byte_size(Cursor) > 0, byte_size(Cursor) =< 64 -> {ok, Cursor};
        [{<<"cursor">>, _}] -> {error, invalid_cursor};
        _ -> {error, invalid_schema}
    catch _:_ -> {error, invalid_schema} end.

nonce(Req) ->
    case bus_operator_http:session_header(Req) of
        undefined -> {error, unauthorized};
        {ok, Raw} -> {ok, Raw};
        {error, unauthorized} -> {error, unauthorized}
    end.

occupy(Conn, Key) ->
    bus_operator_http_gate:acquire(Conn, Key).

%% Never reacquire or retarget a replacement gate. Stale means this request's
%% HTTP permit is gone; fail closed until transport has dropped the connection.
admit_current(Conn, Ref) ->
    case bus_operator_http_gate:checkout(Ref, Conn) of
        ok -> ok;
        stale -> {error, unavailable}
    end.

bounded_length(Req) ->
    case cowboy_req:header(<<"content-length">>, Req) of
        undefined -> {error, 400, <<"invalid_schema">>, <<"Content-Length required">>};
        LengthBin ->
            case string:to_integer(binary_to_list(LengthBin)) of
                {N, []} when is_integer(N), N > ?MAX_BODY ->
                    {error, 413, <<"payload_too_large">>, <<"body too large">>};
                {N, []} when is_integer(N), N >= 0 -> ok;
                _ -> {error, 400, <<"invalid_schema">>, <<"invalid Content-Length">>}
            end
    end.

read_empty(Req0) ->
    case bounded_length(Req0) of
        {error, Status, Code, Message} -> {error, Status, Code, Message, Req0};
        ok -> read_chunks(Req0, [], 0)
    end.

read_chunks(Req0, Chunks, Size) ->
    case remaining(Req0) of
        Remaining when Remaining =< 0 ->
            {error, 503, <<"capacity">>, <<"request timeout">>, Req0};
        Remaining ->
            try cowboy_req:read_body(Req0, #{length => ?MAX_BODY - Size + 1,
                    period => Remaining, timeout => Remaining}) of
                {Status, Chunk, Req} ->
                    Total = Size + byte_size(Chunk),
                    case {remaining(Req) =< 0, Total > ?MAX_BODY, Status} of
                        {true, _, _} ->
                            {error, 503, <<"capacity">>, <<"request timeout">>, Req};
                        {false, true, _} ->
                            {error, 413, <<"payload_too_large">>, <<"body too large">>, Req};
                        {false, false, more} -> read_chunks(Req, [Chunk | Chunks], Total);
                        {false, false, ok} ->
                            decode_empty(iolist_to_binary(lists:reverse([Chunk | Chunks])), Req)
                    end
            catch
                exit:timeout -> {error, 503, <<"capacity">>, <<"request timeout">>, Req0};
                exit:{timeout, _} -> {error, 503, <<"capacity">>, <<"request timeout">>, Req0}
            end
    end.

decode_empty(Body, Req) ->
    case bus_protocol:decode_json(Body) of
        {ok, Map} ->
            case bus_operator_http:empty_object(Map) of
                ok -> {ok, Req};
                {error, invalid_schema} ->
                    {error, 400, <<"invalid_schema">>, <<"empty object required">>, Req}
            end;
        {error, {duplicate_key, _}} ->
            {error, 400, <<"invalid_schema">>, <<"duplicate keys">>, Req};
        {error, _} ->
            {error, 400, <<"invalid_schema">>, <<"invalid JSON">>, Req}
    end.

reply_auth(Req, {ok, Nonce}) ->
    json_reply(Req, 200, #{<<"session">> => bus_operator_http:encode_nonce(Nonce)});
reply_auth(Req, {error, Reason}) ->
    store_error(Req, Reason).

store_error(Req, unauthorized) ->
    error_reply(Req, 401, <<"unauthorized">>, <<"invalid session">>);
store_error(Req, invalid_request) ->
    error_reply(Req, 400, <<"invalid_schema">>, <<"invalid request">>);
store_error(Req, invalid_schema) ->
    error_reply(Req, 400, <<"invalid_schema">>, <<"invalid request">>);
store_error(Req, invalid_cursor) ->
    error_reply(Req, 400, <<"invalid_cursor">>, <<"invalid discovery cursor">>);
store_error(Req, discovery_reset) ->
    error_reply(Req, 409, <<"discovery_reset">>, <<"discovery changed; start a new read">>);
store_error(Req, rate_limited) ->
    retry_reply(Req, 429, <<"rate_limited">>, <<"bootstrap rate limited">>, 6);
store_error(Req, overloaded) ->
    retry_reply(Req, 503, <<"capacity">>, <<"operator overloaded">>, 1);
store_error(Req, timeout) ->
    retry_reply(Req, 503, <<"capacity">>, <<"operator timeout">>, 1);
store_error(Req, unavailable) ->
    retry_reply(Req, 503, <<"capacity">>, <<"operator unavailable">>, 1);
store_error(Req, stale_slot) ->
    retry_reply(Req, 503, <<"capacity">>, <<"operator unavailable">>, 1);
store_error(Req, session_capacity) ->
    retry_reply(Req, 503, <<"capacity">>, <<"session capacity">>, 2);
store_error(Req, peer_capacity) ->
    retry_reply(Req, 503, <<"capacity">>, <<"peer capacity">>, 2);
store_error(Req, bucket_capacity) ->
    retry_reply(Req, 503, <<"capacity">>, <<"rate tracker full">>, 2);
store_error(Req, nonce_collision) ->
    retry_reply(Req, 503, <<"capacity">>, <<"operator unavailable">>, 1);
store_error(Req, _) ->
    error_reply(Req, 400, <<"invalid_schema">>, <<"request rejected">>).

json_reply(Req, Status, Map) ->
    cowboy_req:reply(Status, headers(#{<<"content-type">> => <<"application/json">>}),
        bus_protocol:encode_map(Map), Req).

error_reply(Req, Status, Code, Message) ->
    cowboy_req:reply(Status, headers(#{<<"content-type">> => <<"application/json">>}),
        bus_protocol:encode_error(Code, Message), Req).

retry_reply(Req, Status, Code, Message, Seconds) ->
    cowboy_req:reply(Status,
        headers(#{<<"content-type">> => <<"application/json">>,
                  <<"retry-after">> => integer_to_binary(Seconds)}),
        bus_protocol:encode_error(Code, Message), Req).

headers() -> headers(#{}).
headers(Extra) ->
    maps:merge(#{
        <<"cache-control">> => <<"no-store">>,
        <<"referrer-policy">> => <<"no-referrer">>,
        <<"x-content-type-options">> => <<"nosniff">>,
        <<"x-frame-options">> => <<"DENY">>,
        <<"content-security-policy">> =>
            <<"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'">>
    }, Extra).

remaining(Req) ->
    maps:get(bus_deadline, Req) - erlang:monotonic_time(millisecond).
