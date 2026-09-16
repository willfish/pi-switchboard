-module(bus_operator_updates_tests).
-include_lib("eunit/include/eunit.hrl").
-define(AGENT, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
with_owner(F) ->
    {ok, Pid} = bus_operator_updates:start_link(),
    try F(Pid) after gen_server:stop(Pid), drain() end.
drain() -> receive {operator_update, _} -> drain() after 0 -> ok end.
wake(Ref) -> receive {operator_update, Ref} -> ok after 1000 -> error(missing_wake) end.
none() -> receive {operator_update, _} -> error(extra_wake) after 0 -> ok end.
coalescing_and_isolation_test() -> with_owner(fun(_) ->
    {ok, {_, Ref, _} = Handle} = bus_operator_updates:subscribe(?AGENT), wake(Ref),
    lists:foreach(fun(_) -> bus_operator_updates:publish(?AGENT) end, lists:seq(1, 10000)), none(),
    true = bus_operator_updates:ack(Handle),
    bus_operator_updates:publish(browser), none(),
    bus_operator_updates:publish(?AGENT), wake(Ref),
    bus_operator_updates:publish(?AGENT), none(),
    true = bus_operator_updates:ack(Handle), bus_operator_updates:publish(?AGENT), wake(Ref)
end).
quota_and_ownership_test() -> with_owner(fun(Pid) ->
    {ok, Handle} = bus_operator_updates:subscribe(?AGENT),
    ?assertEqual({error, capacity}, bus_operator_updates:subscribe(?AGENT)),
    Handles = [begin {ok, H} = bus_operator_updates:subscribe(browser), H end || _ <- lists:seq(1, 32)],
    ?assertEqual({error, capacity}, bus_operator_updates:subscribe(browser)),
    Parent = self(), spawn(fun() -> bus_operator_updates:unsubscribe(Handle), Parent ! checked end),
    receive checked -> ok end,
    _ = sys:get_state(Pid),
    ?assertEqual({error, capacity}, bus_operator_updates:subscribe(?AGENT)),
    lists:foreach(fun bus_operator_updates:unsubscribe/1, [Handle | Handles]),
    _ = sys:get_state(Pid),
    ?assertEqual(0, ets:info(bus_operator_update_watches, size)),
    ?assertEqual(0, ets:info(bus_operator_update_keys, size))
end).
native_capacity_test_() -> {timeout, 30, fun() -> with_owner(fun(_) ->
    lists:foreach(fun(N) ->
        Id = iolist_to_binary(io_lib:format("~8.16.0b-aaaa-4aaa-8aaa-aaaaaaaaaaaa", [N])),
        ?assertMatch({ok, _}, bus_operator_updates:subscribe(Id))
    end, lists:seq(1, 5000)),
    ?assertEqual({error, capacity}, bus_operator_updates:subscribe(?AGENT)),
    ?assertEqual(5000, ets:info(bus_operator_update_watches, size))
end) end}.

dead_subscriber_reclaimed_test() -> with_owner(fun(Pid) ->
    Parent = self(),
    Child = spawn(fun() -> {ok, H} = bus_operator_updates:subscribe(?AGENT), Parent ! {ready, H}, receive stop -> ok end end),
    receive {ready, _} -> ok end, Mon = monitor(process, Child), Child ! stop,
    receive {'DOWN', Mon, process, _, _} -> ok end,
    wait_empty(Pid, 100),
    ?assertMatch({ok, _}, bus_operator_updates:subscribe(?AGENT))
end).
wait_empty(_, 0) -> error(not_reclaimed);
wait_empty(Pid, N) ->
    _ = sys:get_state(Pid),
    case ets:info(bus_operator_update_watches, size) of
        0 -> ok;
        _ -> timer:sleep(1), wait_empty(Pid, N - 1)
    end.
unavailable_publish_is_noop_test() ->
    ?assertEqual(ok, bus_operator_updates:publish(browser)),
    ?assertEqual({error, unavailable}, bus_operator_updates:subscribe(browser)).
