-module(bus_operator_http_gate_tests).
-include_lib("eunit/include/eunit.hrl").

gate_test_() ->
    {setup, fun setup/0, fun cleanup/1, {inorder, [
        fun init_does_not_lookup_interfaces/0,
        fun holds_until_connection_death/0,
        fun per_session_and_global_limits/0,
        fun distinct_from_auth_table/0,
        fun output_redaction/0
    ]}}.

setup() ->
    case whereis(bus_operator_http_gate) of
        undefined -> ok;
        Old -> catch gen_server:stop(Old)
    end,
    {ok, Pid} = bus_operator_http_gate:start_link(),
    unlink(Pid),
    Pid.

cleanup(Pid) ->
    catch gen_server:stop(Pid),
    case whereis(bus_operator_http_gate) of
        undefined -> ok;
        Other -> catch gen_server:stop(Other)
    end,
    catch ets:delete(bus_operator_http_gate:table()),
    ok.

occupied() -> bus_operator_http_gate:occupied().

await_occupied(N) -> await_occupied(N, erlang:monotonic_time(millisecond) + 2000).
await_occupied(N, Until) ->
    case occupied() of
        N -> ok;
        Other ->
            case erlang:monotonic_time(millisecond) < Until of
                true -> timer:sleep(1), await_occupied(N, Until);
                false -> error({occupied, Other, expected, N})
            end
    end.

counts(MFA) ->
    case erlang:trace_info(MFA, call_count) of
        {call_count, undefined} -> 0;
        {call_count, N} -> N
    end.

init_does_not_lookup_interfaces() ->
    Pid = whereis(bus_operator_http_gate),
    gen_server:stop(Pid),
    _ = erlang:trace_pattern({net, getifaddrs, 0}, true, [call_count]),
    try
        {ok, New} = bus_operator_http_gate:start_link(),
        unlink(New),
        ?assertEqual(0, counts({net, getifaddrs, 0}))
    after
        erlang:trace_pattern({net, getifaddrs, 0}, false, [call_count])
    end.

holds_until_connection_death() ->
    Conn = spawn(fun() -> receive stop -> ok end end),
    {ok, Ref} = bus_operator_http_gate:acquire(Conn, bootstrap),
    ?assertEqual(1, occupied()),
    ?assertEqual(ok, bus_operator_http_gate:checkout(Ref, Conn)),
    exit(Conn, kill),
    await_occupied(0),
    ?assertEqual(stale, bus_operator_http_gate:checkout(Ref, Conn)).

per_session_and_global_limits() ->
    Digest = crypto:hash(sha256, <<1:256>>),
    Session = {session, Digest},
    Conns = [spawn(fun() -> receive stop -> ok end end) || _ <- lists:seq(1, 5)],
    [C1, C2, C3, C4, C5] = Conns,
    lists:foreach(fun(C) ->
        ?assertMatch({ok, _}, bus_operator_http_gate:acquire(C, Session))
    end, [C1, C2, C3, C4]),
    ?assertEqual({error, overloaded}, bus_operator_http_gate:acquire(C5, Session)),
    ?assertMatch({ok, _}, bus_operator_http_gate:acquire(C5, bootstrap)),
    ?assertEqual(5, occupied()),
    [exit(C, kill) || C <- Conns],
    await_occupied(0).

distinct_from_auth_table() ->
    {ok, Auth} = bus_operator_auth:start_link(),
    unlink(Auth),
    try
        Conn = spawn(fun() -> receive stop -> ok end end),
        {ok, _} = bus_operator_http_gate:acquire(Conn, bootstrap),
        ?assertEqual(1, occupied()),
        ?assertEqual(0, bus_operator_admission:occupied(bus_operator_admission:table())),
        exit(Conn, kill),
        await_occupied(0)
    after
        gen_server:stop(Auth)
    end.

output_redaction() ->
    Marker = <<"operator-http-gate-redact-7e21">>,
    Status = maps:from_list([{K, Marker} || K <- [state, message, reason, log, future_otp_field]]),
    Safe = bus_operator_http_gate:format_status(Status),
    ?assertEqual(lists:sort(maps:keys(Status)), lists:sort(maps:keys(Safe))),
    ?assertEqual(nomatch, binary:match(term_to_binary(Safe), Marker)).
