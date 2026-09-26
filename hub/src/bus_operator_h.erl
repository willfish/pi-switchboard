-module(bus_operator_h).

%% Network-admitted operator routes, separate from native bearer authority.
-export([init/2]).
-ifdef(TEST).
-export([store_error/2]).
-endif.

-define(MAX_BODY, 256).
-define(MAX_OP_BODY, 32768).
-define(MAX_WORK_REPLY, 65536).
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
dispatch(Req, presence) -> read(Req, presence);
dispatch(Req, events) -> read(Req, events);
dispatch(Req, search) -> read(Req, search);
dispatch(Req, work) -> read(Req, work);
dispatch(Req, work_fleet) -> read(Req, work_fleet);
dispatch(Req, operations) ->
    case cowboy_req:method(Req) of
        <<"POST">> -> mutation_op(Req, operations);
        <<"GET">> -> read(Req, operation_list);
        _ ->
            cowboy_req:reply(405, headers(#{<<"allow">> => <<"GET, POST">>,
                <<"content-type">> => <<"application/json">>}),
                bus_protocol:encode_error(<<"method_not_allowed">>, <<"GET or POST required">>), Req)
    end;
dispatch(Req, operation_status) -> read(Req, operation_status);
dispatch(Req, operation_cancel) -> mutation_op(Req, operation_cancel);
dispatch(Req, channels) -> read(Req, channels);
dispatch(Req, channel_messages) -> read(Req, channel_messages);
dispatch(Req, channel_status) -> read(Req, channel_status);
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

mutation_op(Req, Kind) ->
    case cowboy_req:method(Req) of
        <<"POST">> ->
            case bus_dashboard_authority:allowed_mutation(Req) of
                false -> error_reply(Req, 403, <<"forbidden">>, <<"request rejected">>);
                true ->
                    case json_type(Req) of
                        false -> error_reply(Req, 400, <<"invalid_schema">>, <<"JSON required">>);
                        true ->
                            case cowboy_req:qs(Req) of
                                <<>> -> mutate_op(Req, Kind);
                                _ -> error_reply(Req, 400, <<"invalid_schema">>, <<"empty query required">>)
                            end
                    end
            end;
        _ -> error_reply(Req, 405, <<"method_not_allowed">>, <<"POST required">>)
    end.

read(Req, Kind) ->
    case cowboy_req:method(Req) of
        <<"GET">> ->
            case bus_dashboard_authority:allowed_read(Req) of
                false -> error_reply(Req, 403, <<"forbidden">>, <<"request rejected">>);
                true -> present(Req, Kind)
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

mutate_op(Req0, Kind) ->
    case nonce(Req0) of
        {error, unauthorized} -> error_reply(Req0, 401, <<"unauthorized">>, <<"invalid session">>);
        {ok, Nonce} ->
            Conn = maps:get(pid, Req0),
            Deadline = maps:get(bus_deadline, Req0),
            Bound = bus_operator_http:canonical_origin(Req0),
            Digest = crypto:hash(sha256, Nonce),
            case occupy(Conn, {session, Digest}) of
                {error, Occupy} -> store_error(Req0, Occupy);
                {ok, Ref} ->
                    case admit_current(Conn, Ref) of
                        {error, Stale} -> store_error(Req0, Stale);
                        ok ->
                            case bus_operator_auth:authorize(Nonce, Bound, Conn, Deadline) of
                                {error, Auth} -> store_error(Req0, Auth);
                                {ok, _} ->
                                    case Kind of
                                        operations -> create_op(Req0, Conn, Digest, Deadline);
                                        operation_cancel -> cancel_op(Req0, Conn, Digest, Deadline)
                                    end
                            end
                    end
            end
    end.

create_op(Req0, Conn, Digest, Deadline) ->
    case read_op_json(Req0) of
        {error, Status, Code, Message, Req} -> error_reply(Req, Status, Code, Message);
        {ok, Map, Req} ->
            case bus_operator_ops:create(Conn, Digest, Map, Deadline) of
                {ok, Public} -> json_reply(Req, 200, Public);
                {error, Reason} -> store_error(Req, Reason)
            end
    end.

cancel_op(Req0, Conn, Digest, Deadline) ->
    OpId = cowboy_req:binding(operation_id, Req0),
    case bus_protocol:is_uuid(OpId) of
        false -> store_error(Req0, invalid_schema);
        true ->
            case read_empty(Req0) of
                {error, Status, Code, Message, Req} -> error_reply(Req, Status, Code, Message);
                {ok, Req} ->
                    case bus_operator_ops:cancel(Conn, Digest, OpId, Deadline) of
                        {ok, Public} -> json_reply(Req, 200, Public);
                        {error, Reason} -> store_error(Req, Reason)
                    end
            end
    end.

operation_list(Req, Conn, Nonce, Deadline) ->
    try cowboy_req:parse_qs(Req) of
        [{<<"agentId">>, AgentId}] ->
            case bus_protocol:is_uuid(AgentId) of
                false -> store_error(Req, invalid_schema);
                true ->
                    Digest = crypto:hash(sha256, Nonce),
                    case bus_operator_ops:list(Conn, Digest, AgentId, Deadline) of
                        {ok, Page} -> json_reply(Req, 200, Page);
                        {error, Reason} -> store_error(Req, Reason)
                    end
            end;
        _ -> store_error(Req, invalid_schema)
    catch _:_ -> store_error(Req, invalid_schema)
    end.

operation_status(Req, Conn, Nonce, Deadline) ->
    OpId = cowboy_req:binding(operation_id, Req),
    case cowboy_req:qs(Req) =:= <<>> andalso bus_protocol:is_uuid(OpId) of
        false -> store_error(Req, invalid_schema);
        true ->
            Digest = crypto:hash(sha256, Nonce),
            case bus_operator_ops:status(Conn, Digest, OpId, Deadline) of
                {ok, Public} -> json_reply(Req, 200, Public);
                {error, Reason} -> store_error(Req, Reason)
            end
    end.

read_op_json(Req0) ->
    case cowboy_req:header(<<"content-length">>, Req0) of
        undefined -> {error, 400, <<"invalid_schema">>, <<"Content-Length required">>, Req0};
        LengthBin ->
            case string:to_integer(binary_to_list(LengthBin)) of
                {N, []} when is_integer(N), N > ?MAX_OP_BODY ->
                    {error, 413, <<"payload_too_large">>, <<"body too large">>, Req0};
                {N, []} when is_integer(N), N >= 0 -> read_op_chunks(Req0, [], 0);
                _ -> {error, 400, <<"invalid_schema">>, <<"invalid Content-Length">>, Req0}
            end
    end.

read_op_chunks(Req0, Chunks, Size) ->
    case remaining(Req0) of
        Remaining when Remaining =< 0 ->
            {error, 503, <<"capacity">>, <<"request timeout">>, Req0};
        Remaining ->
            try cowboy_req:read_body(Req0, #{length => ?MAX_OP_BODY - Size + 1,
                    period => Remaining, timeout => Remaining}) of
                {Status, Chunk, Req} ->
                    Total = Size + byte_size(Chunk),
                    case {remaining(Req) =< 0, Total > ?MAX_OP_BODY, Status} of
                        {true, _, _} ->
                            {error, 503, <<"capacity">>, <<"request timeout">>, Req};
                        {false, true, _} ->
                            {error, 413, <<"payload_too_large">>, <<"body too large">>, Req};
                        {false, false, more} -> read_op_chunks(Req, [Chunk | Chunks], Total);
                        {false, false, ok} ->
                            decode_op(iolist_to_binary(lists:reverse([Chunk | Chunks])), Req)
                    end
            catch
                exit:timeout -> {error, 503, <<"capacity">>, <<"request timeout">>, Req0};
                exit:{timeout, _} -> {error, 503, <<"capacity">>, <<"request timeout">>, Req0}
            end
    end.

decode_op(Body, Req) ->
    case bus_protocol:decode_json(Body) of
        {ok, Map} when is_map(Map) -> {ok, Map, Req};
        {ok, _} -> {error, 400, <<"invalid_schema">>, <<"object required">>, Req};
        {error, {duplicate_key, _}} ->
            {error, 400, <<"invalid_schema">>, <<"duplicate keys">>, Req};
        {error, _} -> {error, 400, <<"invalid_schema">>, <<"invalid JSON">>, Req}
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

present(Req, Kind) ->
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
                                {ok, _} -> read_page(Req, Kind, Conn, Nonce, Deadline);
                                {error, Auth} -> store_error(Req, Auth)
                            end
                    end
            end
    end.

read_page(Req, presence, _Conn, _Nonce, Deadline) ->
    presence_page(Req, Deadline);
read_page(Req, work, Conn, _Nonce, Deadline) ->
    work_page(Req, Conn, Deadline);
read_page(Req, work_fleet, Conn, Nonce, Deadline) ->
    fleet_page(Req, Conn, Nonce, Deadline);
read_page(Req, operation_status, Conn, Nonce, Deadline) ->
    operation_status(Req, Conn, Nonce, Deadline);
read_page(Req, operation_list, Conn, Nonce, Deadline) ->
    operation_list(Req, Conn, Nonce, Deadline);
read_page(Req, search, Conn, Nonce, Deadline) ->
    search_page(Req, Conn, Nonce, Deadline);
read_page(Req, channels, _Conn, _Nonce, Deadline) ->
    case cowboy_req:qs(Req) of
        <<>> ->
            case bus_store:channels(Deadline) of
                {ok, Doc} -> json_reply(Req, 200, Doc);
                {error, Reason} -> store_error(Req, Reason)
            end;
        _ -> store_error(Req, invalid_schema)
    end;
read_page(Req, channel_messages, _Conn, _Nonce, Deadline) ->
    channel_messages(Req, Deadline);
read_page(Req, channel_status, _Conn, _Nonce, Deadline) ->
    case {channel_name(Req), cowboy_req:qs(Req)} of
        {{ok, Name}, <<>>} ->
            case bus_store:channel_statuses(Name, Deadline) of
                {ok, Doc} -> json_reply(Req, 200, Doc);
                {error, Reason} -> store_error(Req, Reason)
            end;
        {{error, Reason}, _} -> store_error(Req, Reason);
        _ -> store_error(Req, invalid_schema)
    end;
read_page(Req, events, Conn, Nonce, Deadline) ->
    case cursor(Req, 128) of
        {error, Reason} -> store_error(Req, Reason);
        {ok, Cursor} ->
            case bus_operator_journal:page(Cursor, Conn, crypto:hash(sha256, Nonce), Deadline) of
                {ok, Encoded} ->
                    cowboy_req:reply(200, headers(#{<<"content-type">> => <<"application/json">>}),
                        Encoded, Req);
                {error, Reason} -> store_error(Req, Reason)
            end
    end.

channel_name(Req) ->
    case bus_channels:decode_name(cowboy_req:binding(name, Req)) of
        {ok, Name} -> {ok, Name};
        {error, Reason} -> {error, Reason}
    end.

channel_messages(Req, Deadline) ->
    case channel_name(Req) of
        {error, Reason} -> store_error(Req, Reason);
        {ok, Name} ->
            case query_pairs(Req) of
                {error, Reason} -> store_error(Req, Reason);
                {ok, Pairs} ->
                    case bus_channels:parse_query(Pairs, operator) of
                        {error, Reason} -> store_error(Req, Reason);
                        {ok, Query} ->
                            case bus_store:channel_read(Name, Query, Deadline) of
                                {ok, Page} -> json_reply(Req, 200, Page);
                                {error, Reason} -> store_error(Req, Reason)
                            end
                    end
            end
    end.

query_pairs(Req) ->
    try {ok, cowboy_req:parse_qs(Req)} catch _:_ -> {error, invalid_schema} end.

search_page(Req, Conn, Nonce, Deadline) ->
    case search_query(Req) of
        {error, Reason} -> store_error(Req, Reason);
        {ok, Filter, Cursor} ->
            case bus_operator_journal:search(Filter, Cursor, Conn,
                    crypto:hash(sha256, Nonce), Deadline) of
                {ok, Encoded} ->
                    cowboy_req:reply(200, headers(#{<<"content-type">> => <<"application/json">>}),
                        Encoded, Req);
                {error, Reason} -> store_error(Req, Reason)
            end
    end.

fleet_page(Req, Conn, Nonce, Deadline) ->
    case cursor(Req, 128) of
        {error, Reason} -> store_error(Req, Reason);
        {ok, Cursor} ->
            case bus_operator_native:page(Conn, crypto:hash(sha256, Nonce), Cursor, Deadline) of
                {ok, Encoded} ->
                    cowboy_req:reply(200, headers(#{<<"content-type">> => <<"application/json">>}),
                        Encoded, Req);
                {error, Reason} -> store_error(Req, Reason)
            end
    end.

work_page(Req, Conn, Deadline) ->
    case cowboy_req:qs(Req) of
        <<>> ->
            AgentId = cowboy_req:binding(agent_id, Req),
            case bus_protocol:is_uuid(AgentId) of
                false -> store_error(Req, invalid_schema);
                true ->
                    case bus_operator_native:lookup(Conn, AgentId, Deadline) of
                        {ok, View} -> work_reply(Req, View);
                        {error, Reason} -> store_error(Req, Reason)
                    end
            end;
        _ -> store_error(Req, invalid_schema)
    end.

work_reply(Req, #{binding := Binding, work := Work, permissions := Perms}) ->
    Encoded = bus_protocol:encode_map(#{
        <<"binding">> => Binding,
        <<"work">> => Work,
        <<"permissions">> => Perms
    }),
    case byte_size(Encoded) > ?MAX_WORK_REPLY of
        true -> store_error(Req, capacity);
        false ->
            cowboy_req:reply(200, headers(#{<<"content-type">> => <<"application/json">>}),
                Encoded, Req)
    end;
work_reply(Req, _) ->
    store_error(Req, invalid_schema).

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

discovery_cursor(Req) -> cursor(Req, 64).

cursor(Req, Limit) ->
    try cowboy_req:parse_qs(Req) of
        [] -> {ok, first};
        [{<<"cursor">>, Cursor}] when is_binary(Cursor),
                byte_size(Cursor) > 0, byte_size(Cursor) =< Limit -> {ok, Cursor};
        [{<<"cursor">>, _}] -> {error, invalid_cursor};
        _ -> {error, invalid_schema}
    catch _:_ -> {error, invalid_schema} end.

search_query(Req) ->
    try cowboy_req:parse_qs(Req) of
        Qs ->
            case parse_search(Qs, #{}, first) of
                {ok, Filter, Cursor} -> finish_search(Filter, Cursor);
                Error -> Error
            end
    catch _:_ -> {error, invalid_schema} end.

finish_search(Filter, Cursor) ->
    From = maps:get(from, Filter, undefined),
    To = maps:get(to, Filter, undefined),
    case is_integer(From) andalso is_integer(To) andalso From > To of
        true -> {error, invalid_schema};
        false -> {ok, Filter, Cursor}
    end.

parse_search([], Filter, Cursor) -> {ok, Filter, Cursor};
parse_search([{<<"cursor">>, C} | Rest], Filter, first)
  when is_binary(C), byte_size(C) > 0, byte_size(C) =< 128 ->
    parse_search(Rest, Filter, C);
parse_search([{<<"cursor">>, _} | _], _, _) -> {error, invalid_cursor};
parse_search([{<<"q">>, <<>>} | Rest], Filter, Cursor) ->
    parse_search(Rest, Filter, Cursor);
parse_search([{<<"q">>, Q} | Rest], Filter, Cursor) when is_binary(Q), byte_size(Q) =< 200 ->
    case unicode:characters_to_binary(Q) of
        Q -> parse_search(Rest, Filter#{q => Q}, Cursor);
        _ -> {error, invalid_schema}
    end;
parse_search([{<<"q">>, _} | _], _, _) -> {error, invalid_schema};
parse_search([{<<"participant">>, Id} | Rest], Filter, Cursor) ->
    case bus_protocol:is_uuid(Id) of
        true -> parse_search(Rest, Filter#{participant => Id}, Cursor);
        false -> {error, invalid_schema}
    end;
parse_search([{<<"workId">>, Id} | Rest], Filter, Cursor) ->
    case bus_protocol:is_uuid(Id) of
        true -> parse_search(Rest, Filter#{workId => Id}, Cursor);
        false -> {error, invalid_schema}
    end;
parse_search([{<<"threadId">>, Id} | Rest], Filter, Cursor) ->
    case bus_protocol:is_uuid(Id) of
        true -> parse_search(Rest, Filter#{threadId => Id}, Cursor);
        false -> {error, invalid_schema}
    end;
parse_search([{<<"outcome">>, Outcome} | Rest], Filter, Cursor) ->
    case search_outcome(Outcome) of
        true -> parse_search(Rest, Filter#{outcome => Outcome}, Cursor);
        false -> {error, invalid_schema}
    end;
parse_search([{<<"source">>, Src} | Rest], Filter, Cursor) ->
    case lists:member(Src, [<<"relay_observed">>, <<"client_reported">>,
            <<"operator_requested">>]) of
        true -> parse_search(Rest, Filter#{source => Src}, Cursor);
        false -> {error, invalid_schema}
    end;
parse_search([{<<"category">>, Cat} | Rest], Filter, Cursor) ->
    case lists:member(Cat, [<<"communications">>, <<"work">>, <<"activity">>,
            <<"operations">>, <<"observation">>]) of
        true -> parse_search(Rest, Filter#{category => Cat}, Cursor);
        false -> {error, invalid_schema}
    end;
parse_search([{<<"from">>, Bin} | Rest], Filter, Cursor) ->
    case search_seconds(Bin) of
        {ok, N} -> parse_search(Rest, Filter#{from => N}, Cursor);
        error -> {error, invalid_schema}
    end;
parse_search([{<<"to">>, Bin} | Rest], Filter, Cursor) ->
    case search_seconds(Bin) of
        {ok, N} -> parse_search(Rest, Filter#{to => N}, Cursor);
        error -> {error, invalid_schema}
    end;
parse_search(_, _, _) -> {error, invalid_schema}.

search_outcome(Bin) ->
    lists:member(Bin, [<<"completed">>, <<"failed">>, <<"queued">>, <<"accepted">>,
        <<"received">>, <<"context_reserved">>, <<"rejected">>, <<"assembling">>,
        <<"attempted">>, <<"observed">>, <<"labelled">>, <<"abort_requested">>,
        <<"settled">>, <<"cancelled">>, <<"expired">>, <<"unknown">>,
        <<"work_assigned">>]).

search_seconds(Bin) when is_binary(Bin) ->
    try
        N = binary_to_integer(Bin),
        true = N >= 0 andalso Bin =:= integer_to_binary(N),
        {ok, N}
    catch _:_ -> error end;
search_seconds(_) -> error.

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
store_error(Req, forbidden) ->
    error_reply(Req, 403, <<"forbidden">>, <<"capability or permission denied">>);
store_error(Req, expired) ->
    error_reply(Req, 409, <<"expired">>, <<"operation expired">>);
store_error(Req, not_found) ->
    error_reply(Req, 404, <<"not_found">>, <<"unknown runtime">>);
store_error(Req, capacity) ->
    retry_reply(Req, 503, <<"capacity">>, <<"operator capacity">>, 2);
store_error(Req, invalid_request) ->
    error_reply(Req, 400, <<"invalid_schema">>, <<"invalid request">>);
store_error(Req, invalid_schema) ->
    error_reply(Req, 400, <<"invalid_schema">>, <<"invalid request">>);
store_error(Req, invalid_cursor) ->
    error_reply(Req, 400, <<"invalid_cursor">>, <<"invalid discovery cursor">>);
store_error(Req, epoch_reset) ->
    error_reply(Req, 409, <<"epoch_reset">>, <<"observation epoch changed; start a new read">>);
store_error(Req, history_lost) ->
    error_reply(Req, 409, <<"history_lost">>, <<"observation history expired; start a new read">>);
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
