-module(bus_operator_auth_tests).
-include_lib("eunit/include/eunit.hrl").

origin() -> <<"http://localhost:7420">>.
peer() -> {127, 0, 0, 1}.
deadline() -> erlang:monotonic_time(millisecond) + 5000.
occupied() -> bus_operator_admission:occupied(bus_operator_admission:table()).

auth_test_() ->
    {setup, fun setup/0, fun cleanup/1, {inorder, [
        fun init_does_not_lookup_interfaces/0,
        fun crypto_nonce_roundtrip/0,
        fun invalid_origin_is_unauthorized/0,
        fun output_redaction/0,
        fun captured_clock_once/0,
        fun explicit_deadline_and_pid/0,
        fun stale_slot_ref_is_rejected/0,
        fun dispatch_deadline_is_not_the_model_clock/0,
        fun session_capacity_and_disconnect/0,
        {timeout, 15, fun expiry_sweep/0},
        {timeout, 15, fun owner_restart_drops_sessions/0},
        {timeout, 15, fun timeout_does_not_release_queued_work/0},
        {timeout, 15, fun caller_death_reclaims_before_mutation/0},
        {timeout, 15, fun per_session_admission_limit/0},
        {timeout, 15, fun global_admission_limit/0}
    ]}}.

setup() ->
    application:ensure_all_started(crypto),
    case whereis(bus_operator_auth) of
        undefined -> ok;
        Old -> catch gen_server:stop(Old)
    end,
    {ok, Pid} = bus_operator_auth:start_link(),
    unlink(Pid),
    Pid.

cleanup(Pid) ->
    catch sys:resume(Pid),
    catch gen_server:stop(Pid),
    case whereis(bus_operator_auth) of
        undefined -> ok;
        Other -> catch gen_server:stop(Other)
    end,
    catch ets:delete(bus_operator_admission:table()),
    ok.

await_occupied(N) -> await_occupied(N, erlang:monotonic_time(millisecond) + 2000).
await_occupied(N, Until) ->
    case occupied() of
        N -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) < Until of
                true -> timer:sleep(1), await_occupied(N, Until);
                false -> error({occupied, occupied(), expected, N})
            end
    end.

counts(MFA) ->
    case erlang:trace_info(MFA, call_count) of
        {call_count, undefined} -> 0;
        {call_count, N} -> N
    end.

init_does_not_lookup_interfaces() ->
    Pid = whereis(bus_operator_auth),
    gen_server:stop(Pid),
    _ = erlang:trace_pattern({net, getifaddrs, 0}, true, [call_count]),
    _ = erlang:trace_pattern({bus_operator_access, admit, 3}, true, [call_count]),
    _ = erlang:trace_pattern({bus_operator_access, admit, 4}, true, [call_count]),
    try
        {ok, New} = bus_operator_auth:start_link(),
        unlink(New),
        ?assertEqual(0, counts({net, getifaddrs, 0})),
        ?assertEqual(0, counts({bus_operator_access, admit, 3})),
        ?assertEqual(0, counts({bus_operator_access, admit, 4}))
    after
        erlang:trace_pattern({net, getifaddrs, 0}, false, [call_count]),
        erlang:trace_pattern({bus_operator_access, admit, 3}, false, [call_count]),
        erlang:trace_pattern({bus_operator_access, admit, 4}, false, [call_count])
    end.

crypto_nonce_roundtrip() ->
    {ok, Nonce} = bus_operator_auth:bootstrap(peer(), origin(), self(), deadline()),
    {ok, Other} = bus_operator_auth:bootstrap(peer(), origin(), self(), deadline()),
    ?assertEqual(32, byte_size(Nonce)),
    ?assertEqual(32, byte_size(Other)),
    ?assertNotEqual(Nonce, Other),
    ?assertMatch({ok, #{expires_at := _}}, bus_operator_auth:authorize(Nonce, origin(), self(), deadline())),
    ?assertEqual(nomatch, binary:match(term_to_binary(sys:get_state(bus_operator_auth)), Nonce)).

invalid_origin_is_unauthorized() ->
    {ok, Nonce} = bus_operator_auth:bootstrap(peer(), origin(), self(), deadline()),
    ?assertEqual({error, unauthorized},
        bus_operator_auth:authorize(Nonce, <<"http://localhost.:7420">>, self(), deadline())),
    ?assertEqual({error, unauthorized},
        bus_operator_auth:disconnect(Nonce, <<"http://foreign.invalid">>, self(), deadline())),
    ?assertEqual({error, invalid_request},
        bus_operator_auth:bootstrap(peer(), <<>>, self(), deadline())),
    ?assertMatch({ok, _}, bus_operator_auth:authorize(Nonce, origin(), self(), deadline())).

output_redaction() ->
    Marker = <<"operator-auth-redact-nonce-7f3a">>,
    Status = maps:from_list([{K, Marker} || K <- [state, message, reason, log, future_otp_field]]),
    Safe = bus_operator_auth:format_status(Status),
    ?assertEqual(lists:sort(maps:keys(Status)), lists:sort(maps:keys(Safe))),
    ?assertEqual(nomatch, binary:match(term_to_binary(Safe), Marker)),
    {ok, Nonce} = bus_operator_auth:bootstrap(peer(), origin(), self(), deadline()),
    ?assertEqual(nomatch, binary:match(term_to_binary(sys:get_status(bus_operator_auth)), Nonce)).

captured_clock_once() ->
    1 = erlang:trace_pattern({bus_operator_auth, mono, 0}, true, [call_count]),
    try
        {ok, Nonce} = bus_operator_auth:bootstrap(peer(), origin(), self(), deadline()),
        ?assertEqual({call_count, 1}, erlang:trace_info({bus_operator_auth, mono, 0}, call_count)),
        erlang:trace_pattern({bus_operator_auth, mono, 0}, true, [call_count]),
        {ok, _} = bus_operator_auth:authorize(Nonce, origin(), self(), deadline()),
        ?assertEqual({call_count, 1}, erlang:trace_info({bus_operator_auth, mono, 0}, call_count)),
        erlang:trace_pattern({bus_operator_auth, mono, 0}, true, [call_count]),
        ok = bus_operator_auth:disconnect(Nonce, origin(), self(), deadline()),
        ?assertEqual({call_count, 1}, erlang:trace_info({bus_operator_auth, mono, 0}, call_count))
    after
        erlang:trace_pattern({bus_operator_auth, mono, 0}, false, [call_count])
    end.

explicit_deadline_and_pid() ->
    ?assertEqual({error, timeout}, bus_operator_auth:bootstrap(peer(), origin(), self(),
        erlang:monotonic_time(millisecond))),
    Pid = whereis(bus_operator_auth),
    ok = gen_server:stop(Pid),
    ?assertEqual({error, unavailable}, bus_operator_auth:bootstrap(peer(), origin(), self(), deadline())),
    {ok, New} = bus_operator_auth:start_link(),
    unlink(New),
    {ok, Nonce} = bus_operator_auth:bootstrap(peer(), origin(), self(), deadline()),
    ?assertEqual({error, unauthorized}, bus_operator_auth:authorize(<<0:256>>, origin(), self(), deadline())),
    ?assertMatch({ok, _}, bus_operator_auth:authorize(Nonce, origin(), self(), deadline())).

stale_slot_ref_is_rejected() ->
    Pid = whereis(bus_operator_auth),
    Nonce = crypto:strong_rand_bytes(32),
    ?assertEqual({error, stale_slot}, gen_server:call(Pid,
        {op, deadline(), make_ref(), self(), {authorize, Nonce, origin()}})),
    {ok, _} = bus_operator_auth:bootstrap(peer(), origin(), self(), deadline()).

dispatch_deadline_is_not_the_model_clock() ->
    Pid = whereis(bus_operator_auth),
    State = sys:get_state(Pid),
    Tab = maps:get(tab, State),
    {ok, Ref} = bus_operator_admission:acquire(Tab, Pid, self(), bootstrap),
    Deadline = erlang:monotonic_time(millisecond) - 1,
    InjectedNow = Deadline - 10000,
    Before = bus_operator_sessions:stats(maps:get(sessions, State)),
    {reply, Reply, Next} = bus_operator_auth:handle_call_at(
        {op, Deadline, Ref, self(), {bootstrap, peer(), origin()}},
        {self(), tag}, State, InjectedNow),
    ?assertEqual({error, timeout}, Reply),
    ?assertEqual(Before, bus_operator_sessions:stats(maps:get(sessions, Next))),
    sys:replace_state(Pid, fun(S) -> bus_operator_admission:release(Tab, Ref), S end),
    ?assertEqual(stale, bus_operator_admission:checkout(Tab, Ref, self())).

session_capacity_and_disconnect() ->
    Pid = whereis(bus_operator_auth),
    gen_server:stop(Pid),
    {ok, New} = bus_operator_auth:start_link(#{max_sessions => 1, bucket_capacity => 10}),
    unlink(New),
    {ok, Nonce} = bus_operator_auth:bootstrap(peer(), origin(), self(), deadline()),
    ?assertEqual({error, session_capacity}, bus_operator_auth:bootstrap(peer(), origin(), self(), deadline())),
    ok = bus_operator_auth:disconnect(Nonce, origin(), self(), deadline()),
    ?assertEqual({error, unauthorized}, bus_operator_auth:authorize(Nonce, origin(), self(), deadline())),
    ?assertMatch({ok, _}, bus_operator_auth:bootstrap(peer(), origin(), self(), deadline())).

expiry_sweep() ->
    Pid = whereis(bus_operator_auth),
    gen_server:stop(Pid),
    {ok, New} = bus_operator_auth:start_link(#{ttl_ms => 40}),
    unlink(New),
    {ok, Nonce} = bus_operator_auth:bootstrap(peer(), origin(), self(), deadline()),
    timer:sleep(50),
    New ! expire,
    sys:get_state(New),
    ?assertEqual({error, unauthorized}, bus_operator_auth:authorize(Nonce, origin(), self(), deadline())),
    ?assertMatch({ok, _}, bus_operator_auth:bootstrap(peer(), origin(), self(), deadline())).

owner_restart_drops_sessions() ->
    {ok, Nonce} = bus_operator_auth:bootstrap(peer(), origin(), self(), deadline()),
    Pid = whereis(bus_operator_auth),
    Mon = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Mon, process, Pid, _} -> ok end,
    ?assertEqual({error, unavailable}, bus_operator_auth:authorize(Nonce, origin(), self(), deadline())),
    {ok, New} = bus_operator_auth:start_link(),
    unlink(New),
    ?assertEqual({error, unauthorized}, bus_operator_auth:authorize(Nonce, origin(), self(), deadline())),
    ?assertMatch({ok, _}, bus_operator_auth:bootstrap(peer(), origin(), self(), deadline())).

timeout_does_not_release_queued_work() ->
    Auth = whereis(bus_operator_auth),
    ok = sys:suspend(Auth),
    Parent = self(),
    spawn(fun() ->
        Parent ! {auth_result, bus_operator_auth:bootstrap(peer(), origin(), self(),
            erlang:monotonic_time(millisecond) + 80)}
    end),
    await_occupied(1),
    receive {auth_result, {error, timeout}} -> ok after 2000 -> error(no_timeout) end,
    %% Caller timeout must not free the slot while the queued call remains.
    ?assertEqual(1, occupied()),
    ok = sys:resume(Auth),
    await_occupied(0).

caller_death_reclaims_before_mutation() ->
    Auth = whereis(bus_operator_auth),
    ok = sys:suspend(Auth),
    Conn = spawn(fun() -> receive after infinity -> ok end end),
    Parent = self(),
    spawn(fun() ->
        Parent ! {auth_result, bus_operator_auth:bootstrap(peer(), origin(), Conn, deadline())}
    end),
    await_occupied(1),
    exit(Conn, kill),
    ?assertEqual(1, occupied()),
    ok = sys:resume(Auth),
    receive
        {auth_result, Result} -> ?assertEqual({error, stale_slot}, Result)
    after 2000 -> error(no_result) end,
    await_occupied(0),
    {ok, Nonce} = bus_operator_auth:bootstrap(peer(), origin(), self(), deadline()),
    ?assertMatch({ok, _}, bus_operator_auth:authorize(Nonce, origin(), self(), deadline())).

per_session_admission_limit() ->
    {ok, Nonce} = bus_operator_auth:bootstrap(peer(), origin(), self(), deadline()),
    Auth = whereis(bus_operator_auth),
    ok = sys:suspend(Auth),
    Parent = self(),
    lists:foreach(fun(_) ->
        spawn(fun() ->
            Parent ! {auth_result, bus_operator_auth:authorize(Nonce, origin(), self(), deadline())}
        end)
    end, lists:seq(1, bus_operator_admission:session_limit())),
    await_occupied(bus_operator_admission:session_limit()),
    lists:foreach(fun(_) ->
        ?assertEqual({error, overloaded}, bus_operator_auth:authorize(Nonce, origin(), self(), deadline()))
    end, lists:seq(1, 8)),
    ?assertEqual(bus_operator_admission:session_limit(), occupied()),
    ok = sys:resume(Auth),
    lists:foreach(fun(_) ->
        receive {auth_result, {ok, _}} -> ok after 2000 -> error(no_authorize) end
    end, lists:seq(1, bus_operator_admission:session_limit())),
    await_occupied(0),
    {ok, Other} = bus_operator_auth:bootstrap({127, 0, 0, 2}, origin(), self(), deadline()),
    ?assertMatch({ok, _}, bus_operator_auth:authorize(Other, origin(), self(), deadline())).

global_admission_limit() ->
    Auth = whereis(bus_operator_auth),
    ok = sys:suspend(Auth),
    lists:foreach(fun(_) ->
        spawn(fun() ->
            _ = bus_operator_auth:bootstrap(peer(), origin(), self(), deadline())
        end)
    end, lists:seq(1, bus_operator_admission:limit())),
    await_occupied(bus_operator_admission:limit()),
    ?assertEqual({error, overloaded}, bus_operator_auth:bootstrap(peer(), origin(), self(), deadline())),
    ok = sys:resume(Auth),
    await_occupied(0).
