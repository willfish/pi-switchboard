-module(bus_pressure_tests).
-include_lib("eunit/include/eunit.hrl").
-export([suspend/1, fill/2, collect/1, queue_len/1, agent/1]).

pressure_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun(P) -> {timeout, 15, fun() -> threshold_recovery(P) end} end,
        fun(P) -> {timeout, 15, fun() -> concurrent_pressure(P) end} end,
        fun(P) -> {timeout, 15, fun() -> cleanup_under_pressure(P) end} end,
        fun(P) -> fun() -> restart_no_replay(P) end end
    ]}.

setup() ->
    {ok, P} = bus_store:start_link(),
    unlink(P),
    P.
cleanup(P) ->
    catch sys:resume(P),
    catch gen_server:stop(P),
    case whereis(bus_store) of undefined -> ok; Other -> gen_server:stop(Other) end.

%% Remove the one-shot expiry tick while suspended, without changing production
%% timers or limits. This makes the exact mailbox boundary independent of time.
suspend(P) ->
    ok = sys:suspend(P),
    timer:sleep(1050),
    sys:replace_state(P, fun(S) -> receive expire -> ok after 0 -> error(no_tick) end, S end),
    ok.

fill(N, Op) ->
    Parent = self(),
    D = now_ms() + 400,
    [spawn(fun() -> Parent ! {pressure_result, self(), Op(D)} end)
     || _ <- lists:seq(1, N)].
collect(Pids) ->
    [receive {pressure_result, P, R} -> R after 3000 -> error(caller_stuck) end || P <- Pids].
queue_len(P) -> {message_queue_len, N} = process_info(P, message_queue_len), N.
await_queue(P, N) -> await_queue(P, N, now_ms() + 2000).
await_queue(P, N, D) ->
    case queue_len(P) of
        N -> ok;
        _ -> case now_ms() < D of
            true -> timer:sleep(1), await_queue(P, N, D);
            false -> error({queue_not_reached, N, queue_len(P)})
        end
    end.
now_ms() -> erlang:monotonic_time(millisecond).
memory(P) -> {memory, N} = process_info(P, memory), N.

threshold_recovery(P) ->
    ok = bus_store:put_agent(agent(<<"a">>)),
    ok = bus_store:put_agent(agent(<<"b">>)),
    {ok, _} = bus_store:accept_mail(mail()),
    Before = sys:get_state(P),
    erlang:garbage_collect(P),
    AcceptedMemory = memory(P),
    #{model := #{queued_bytes := AcceptedBytes}} = Before,
    suspend(P),
    %% Real API callers retain expired requested mutations, not dummy messages.
    Ops = [fun(D) -> bus_store:put_agent(agent(<<"c">>), D) end,
           fun(D) -> bus_store:delete_agent(<<"a">>, D) end,
           fun(D) -> bus_store:accept_mail((mail())#{<<"id">> := <<"new">>}, D) end,
           fun(D) -> bus_store:subscribe(<<"b">>, self(), D) end],
    Callers = fill(4095, fun(D) -> (lists:nth(erlang:unique_integer([positive]) rem 4 + 1, Ops))(D) end),
    await_queue(P, 4095),
    %% 4095 admits exactly the next call, which times out while retained.
    ?assertEqual({error, timeout}, bus_store:delete_agent(<<"b">>, now_ms() + 20)),
    ?assertEqual(4096, queue_len(P)),
    ?assertEqual({error, timeout}, bus_store:list_agents(now_ms())),
    Ref = make_ref(),
    lists:foreach(fun(Op) ->
        ?assertEqual({error, overloaded}, Op(now_ms() + 100))
    end, Ops ++ [fun(D) -> bus_store:pop_mail(<<"b">>, Ref, D) end,
                 fun(D) -> bus_store:pull_presence(<<"b">>, Ref, D) end]),
    Start = now_ms(),
    lists:foreach(fun(_) ->
        ?assertEqual({error, overloaded}, bus_store:list_agents(now_ms() + 100))
    end, lists:seq(1, 1000)),
    ?assert(now_ms() - Start < 1000),
    ?assertEqual(4096, queue_len(P)),
    ?assertEqual(lists:duplicate(4095, {error, timeout}), collect(Callers)),
    RetainedMemory = memory(P),
    ?assert(RetainedMemory > AcceptedMemory),
    ?assertEqual(4096, queue_len(P)),
    io:format(user, "pressure accepted_only_memory=~p accepted_json_bytes=~p retained_queue=4096 memory=~p~n",
              [AcceptedMemory, AcceptedBytes, RetainedMemory]),
    ok = sys:resume(P),
    ?assertEqual(maps:remove(last_expiry,Before), maps:remove(last_expiry,sys:get_state(P))),
    ?assertMatch({ok, [_, _]}, bus_store:list_agents()),
    ?assertEqual(0, queue_len(P)),
    ok = bus_store:put_agent(agent(<<"c">>)).

concurrent_pressure(P) ->
    suspend(P),
    Initial = fill(4095, fun bus_store:list_agents/1),
    await_queue(P, 4095),
    Parent = self(),
    Racers = [spawn(fun() -> receive go ->
        Parent ! {pressure_result, self(), bus_store:list_agents(now_ms() + 200)}
    end end) || _ <- lists:seq(1, 256)],
    [R ! go || R <- Racers],
    Results = collect(Racers),
    Admitted = length([R || R <- Results, R =:= {error, timeout}]),
    Rejected = length([R || R <- Results, R =:= {error, overloaded}]),
    ?assertEqual(256, Admitted + Rejected),
    ?assert(Admitted >= 1),
    ?assertEqual(4095 + Admitted, queue_len(P)),
    io:format(user, "pressure concurrent=256 admitted=~p rejected=~p queue=~p overshoot=~p memory=~p~n",
              [Admitted, Rejected, queue_len(P), queue_len(P) - 4096, memory(P)]),
    ?assertEqual(lists:duplicate(4095, {error, timeout}), collect(Initial)),
    ok = sys:resume(P),
    ?assertEqual({ok, []}, bus_store:list_agents()).

cleanup_under_pressure(P) ->
    ok = bus_store:put_agent(agent(<<"a">>)),
    ok = bus_store:put_agent(agent(<<"b">>)),
    Subscriber = spawn(fun() -> receive stop -> ok end end),
    {ok, Ref} = bus_store:subscribe(<<"a">>, self()),
    {ok, _} = bus_store:subscribe(<<"b">>, Subscriber),
    suspend(P),
    Callers = fill(4096, fun bus_store:list_agents/1),
    await_queue(P, 4096),
    ok = bus_store:unsubscribe(<<"a">>, Ref),
    Subscriber ! stop,
    await_queue(P, 4098),
    ?assertEqual(lists:duplicate(4096, {error, timeout}), collect(Callers)),
    ok = sys:resume(P),
    #{subs := Subs} = sys:get_state(P),
    ?assertEqual(#{}, Subs),
    {ok, Agents} = bus_store:list_agents(),
    ?assert(lists:all(fun(A) -> maps:get(<<"receiving">>, A) =:= false end, Agents)).

restart_no_replay(P) ->
    ok = sys:suspend(P),
    Callers = fill(1, fun(D) -> bus_store:put_agent(agent(<<"old">>), D) end),
    await_queue(P, 1),
    Mon = monitor(process, P),
    exit(P, kill),
    receive {'DOWN', Mon, process, P, _} -> ok end,
    ?assertEqual({error, unavailable}, bus_store:list_agents()),
    ?assertEqual({error, timeout}, bus_store:list_agents(now_ms())),
    {ok, New} = bus_store:start_link(),
    unlink(New),
    ?assertEqual([{error, unavailable}], collect(Callers)),
    ?assertEqual({ok, []}, bus_store:list_agents()),
    ?assertEqual({error, timeout}, bus_store:put_agent(agent(<<"expired">>), now_ms())),
    ?assertEqual({ok, []}, bus_store:list_agents()).

agent(Id) ->
    #{<<"agentId">> => Id, <<"sessionId">> => Id, <<"host">> => <<"test">>,
      <<"cwd">> => <<"/tmp">>, <<"sessionName">> => <<"test">>, <<"label">> => <<"test">>,
      <<"model">> => null, <<"status">> => <<"idle">>, <<"pid">> => 1,
      <<"acceptsControl">> => false}.
mail() ->
    #{<<"id">> => <<"mail">>, <<"from">> => <<"a">>, <<"to">> => <<"b">>,
      <<"kind">> => <<"notice">>, <<"body">> => <<"small pressure fixture">>}.
