-module(bus_operator_native_h_tests).
-include_lib("eunit/include/eunit.hrl").

-define(A, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(TOKEN, <<"native-eunit-token">>).

http_test_() ->
    {setup, fun setup/0, fun cleanup/1, {timeout, 30, {inorder, [
        fun bearer_required_session_ignored/0,
        fun unsupported_namespace_404/0,
        fun announce_200_stable_and_conflicts/0,
        fun large_body_413/0,
        fun no_cors/0
    ]}}}.

setup() ->
    application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(cowboy),
    lists:foreach(fun(N) -> ?assertEqual(undefined, whereis(N)) end,
        [bus_store, bus_operator_native]),
    OldToken = application:get_env(pi_agent_bus, token),
    application:set_env(pi_agent_bus, token, ?TOKEN),
    {ok, Store} = bus_store:start_link(),
    unlink(Store),
    {ok, Native} = bus_operator_native:start_link(),
    unlink(Native),
    {ok, _} = ranch:start_listener(listener(), ranch_tcp, trans_opts(),
        bus_connection, proto_opts()),
    #{store => Store, native => Native, old_token => OldToken}.

cleanup(#{old_token := OldToken}) ->
    catch ranch:stop_listener(listener()),
    lists:foreach(fun(N) ->
        case whereis(N) of undefined -> ok; Pid -> catch gen_server:stop(Pid) end
    end, [bus_operator_native, bus_store]),
    restore(OldToken),
    ok.

restore(undefined) -> application:unset_env(pi_agent_bus, token);
restore({ok, V}) -> application:set_env(pi_agent_bus, token, V).

listener() -> operator_native_http_eunit.
trans_opts() ->
    #{logger => bus_log, num_acceptors => 4, num_conns_sups => 1,
      max_connections => 64, connection_type => supervisor,
      socket_opts => [{ip, {127, 0, 0, 1}}, {port, 0},
          {send_timeout, 5000}, {send_timeout_close, true}]}.
proto_opts() ->
    Dispatch = cowboy_router:compile([{'_', [
        {"/dashboard/api/v1/session", bus_operator_h, session},
        {"/v1/agents", bus_http_h, list},
        {"/v1/agents/:agent_id", bus_http_h, agent},
        {"/v1/operator/announce", bus_operator_native_h, announce}
    ]}]),
    #{logger => bus_log, env => #{dispatch => Dispatch}, protocols => [http],
      max_keepalive => 1, stream_handlers => [bus_deadline_stream, cowboy_stream_h],
      reset_idle_timeout_on_send => true, max_request_line_length => 8192,
      max_header_name_length => 256, max_header_value_length => 4096,
      max_headers => 32, request_timeout => 5000, shutdown_timeout => 1000,
      idle_timeout => 30000}.

port() -> ranch:get_port(listener()).
host() -> iolist_to_binary(["localhost:", integer_to_list(port())]).
bearer() -> [{<<"authorization">>, <<"Bearer ", ?TOKEN/binary>>}].
json() -> [{<<"content-type">>, <<"application/json">>}].

work() ->
    {ok, Bin} = file:read_file("../tests/fixtures/operator-work.json"),
    maps:get(<<"allNull">>, json:decode(Bin)).

populated() ->
    {ok, Bin} = file:read_file("../tests/fixtures/operator-work.json"),
    maps:get(<<"populated">>, json:decode(Bin)).

perms() ->
    #{<<"notice">> => false, <<"work">> => false, <<"guidance">> => false,
      <<"sessionRead">> => false, <<"label">> => false, <<"interrupt">> => false,
      <<"content">> => false, <<"workAssign">> => false, <<"history">> => false}.

doc() ->
    #{<<"schemaVersion">> => 1, <<"agentId">> => ?A, <<"sessionId">> => ?A,
      <<"runtimeGeneration">> => <<"1">>, <<"sessionGeneration">> => <<"1">>,
      <<"branchId">> => null, <<"registration">> => null,
      <<"permissionRevision">> => <<"0">>, <<"reportRevision">> => <<"1">>,
      <<"capabilities">> => [<<"work.report.v1">>],
      <<"permissions">> => perms(), <<"work">> => work(),
      <<"activeRunId">> => null}.

agent() ->
    #{<<"agentId">> => ?A, <<"sessionId">> => ?A, <<"host">> => <<"h">>,
      <<"cwd">> => <<"/tmp">>, <<"sessionName">> => <<"s">>, <<"label">> => <<"l">>,
      <<"model">> => null, <<"status">> => <<"idle">>, <<"pid">> => 1,
      <<"acceptsControl">> => false}.

bearer_required_session_ignored() ->
    Body = bus_protocol:encode_map(doc()),
    {401, H, _} = post("/v1/operator/announce", json(), Body),
    ?assertEqual(false, maps:is_key(<<"access-control-allow-origin">>, H)),
    {401, _, _} = post("/v1/operator/announce",
        json() ++ [{<<"x-switchboard-session">>, <<"aa">>}], Body),
    {401, _, _} = post("/v1/operator/announce",
        json() ++ [{<<"authorization">>, <<"Bearer wrong">>}], Body).

unsupported_namespace_404() ->
    {404, _, _} = request("GET", "/v1/operator/requests", host(), bearer(), <<>>),
    {405, H, _} = request("GET", "/v1/operator/announce", host(), bearer(), <<>>),
    ?assertEqual(<<"POST">>, maps:get(<<"allow">>, H)).

announce_200_stable_and_conflicts() ->
    {204, _, _} = request("PUT", "/v1/agents/" ++ binary_to_list(?A), host(),
        bearer() ++ json(), bus_protocol:encode_map(agent())),
    Body = bus_protocol:encode_map(doc()),
    {200, H, R1} = post("/v1/operator/announce", bearer() ++ json(), Body),
    ?assertEqual(<<"no-store">>, maps:get(<<"cache-control">>, H)),
    {ok, M1} = bus_protocol:decode_json(R1),
    {200, _, R2} = post("/v1/operator/announce", bearer() ++ json(), Body),
    {ok, M2} = bus_protocol:decode_json(R2),
    ?assertEqual(maps:get(<<"bindingId">>, M1), maps:get(<<"bindingId">>, M2)),
    Conflict = bus_protocol:encode_map((doc())#{<<"work">> => populated()}),
    {409, _, C} = post("/v1/operator/announce", bearer() ++ json(), Conflict),
    {ok, #{<<"error">> := #{<<"code">> := <<"conflict">>}}} = bus_protocol:decode_json(C),
    Stale = bus_protocol:encode_map((doc())#{<<"runtimeGeneration">> => <<"0">>,
        <<"reportRevision">> => <<"2">>}),
    {409, _, S} = post("/v1/operator/announce", bearer() ++ json(), Stale),
    {ok, #{<<"error">> := #{<<"code">> := <<"stale_generation">>}}} =
        bus_protocol:decode_json(S).

large_body_413() ->
    {413, _, _} = post("/v1/operator/announce", bearer() ++ json() ++
        [{<<"content-length">>, <<"32769">>}], <<"x">>).

no_cors() ->
    Origin = [{<<"origin">>, <<"http://evil.example">>},
              {<<"access-control-request-method">>, <<"POST">>}],
    {401, H1, _} = request("OPTIONS", "/v1/operator/announce", host(), Origin, <<>>),
    {405, H2, _} = request("OPTIONS", "/v1/operator/announce", host(),
        bearer() ++ Origin, <<>>),
    ?assertEqual(false, maps:is_key(<<"access-control-allow-origin">>, H1)),
    ?assertEqual(false, maps:is_key(<<"access-control-allow-origin">>, H2)).

post(Path, Headers, Body) -> request("POST", Path, host(), Headers, Body).

request(Method, Path, Host, Headers, Body) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, port(),
        [binary, {active, false}, {packet, raw}], 5000),
    try
        Extra = case lists:keymember(<<"content-length">>, 1, Headers) of
            true -> [];
            false when Body =:= <<>> -> [];
            false -> [[<<"content-length: ">>, integer_to_binary(byte_size(Body)), <<"\r\n">>]]
        end,
        ok = gen_tcp:send(Sock, [Method, " ", Path, " HTTP/1.1\r\nHost: ", Host,
            "\r\nConnection: close\r\n",
            [[K, ": ", V, "\r\n"] || {K, V} <- Headers], Extra, "\r\n", Body]),
        Raw = recv_all(Sock, []),
        decode_http(Raw)
    after gen_tcp:close(Sock) end.

decode_http(Raw) ->
    [Head | Rest] = binary:split(Raw, <<"\r\n\r\n">>),
    RespBody = case Rest of [] -> <<>>; [B] -> B end,
    [StatusLine | Lines] = binary:split(Head, <<"\r\n">>, [global]),
    [_, Status | _] = binary:split(StatusLine, <<" ">>, [global]),
    H = maps:from_list([begin
        case binary:split(Line, <<": ">>) of
            [K, V] -> {K, V};
            _ -> {Line, <<>>}
        end
    end || Line <- Lines, Line =/= <<>>]),
    {binary_to_integer(Status), H, strip_chunk(RespBody)}.

recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_all(Sock, [Data | Acc]);
        {error, closed} -> iolist_to_binary(lists:reverse(Acc))
    end.

strip_chunk(Body) ->
    case binary:split(Body, <<"\r\n">>) of
        [Len, Rest] ->
            try binary_to_integer(Len, 16) of
                _ ->
                    case binary:split(Rest, <<"\r\n">>) of
                        [Content | _] -> Content;
                        _ -> Body
                    end
            catch _:_ -> Body end;
        _ -> Body
    end.
