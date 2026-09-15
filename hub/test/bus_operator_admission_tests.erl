-module(bus_operator_admission_tests).
-include_lib("eunit/include/eunit.hrl").

limit() -> bus_operator_admission:limit().
session_limit() -> bus_operator_admission:session_limit().
digest() -> crypto:hash(sha256, <<1:256>>).
other_digest() -> crypto:hash(sha256, <<2:256>>).

table() ->
    Tab = ets:new(admission_test, [set, public]),
    ok = bus_operator_admission:init(Tab),
    Tab.

acquire(Tab, Conn, Key) -> bus_operator_admission:acquire(Tab, self(), Conn, Key).

global_capacity_and_duplicate_release_test() ->
    Tab = table(),
    Refs = [begin
        {ok, Ref} = acquire(Tab, self(), bootstrap),
        Ref
    end || _ <- lists:seq(1, limit())],
    ?assertEqual(limit(), bus_operator_admission:occupied(Tab)),
    ?assertEqual({error, overloaded}, acquire(Tab, self(), bootstrap)),
    ok = bus_operator_admission:release(Tab, hd(Refs)),
    ok = bus_operator_admission:release(Tab, hd(Refs)),
    ?assertEqual(limit() - 1, bus_operator_admission:occupied(Tab)),
    {ok, New} = acquire(Tab, self(), bootstrap),
    ?assertEqual(limit(), bus_operator_admission:occupied(Tab)),
    ?assertEqual(stale, bus_operator_admission:checkout(Tab, hd(Refs), self())),
    ?assertEqual(ok, bus_operator_admission:checkout(Tab, New, self())).

rejected_session_acquire_does_not_admit_a_fifth_test() ->
    Tab = table(),
    Session = {session, digest()},
    Held = [begin
        {ok, Ref} = acquire(Tab, self(), Session),
        Ref
    end || _ <- lists:seq(1, session_limit())],
    ?assertEqual(session_limit(), bus_operator_admission:occupied(Tab)),
    lists:foreach(fun(_) ->
        ?assertEqual({error, overloaded}, acquire(Tab, self(), Session))
    end, lists:seq(1, 16)),
    ?assertEqual(session_limit(), bus_operator_admission:occupied(Tab)),
    ?assertEqual(session_limit(), length(Held)),
    lists:foreach(fun(Ref) ->
        ?assertEqual(ok, bus_operator_admission:checkout(Tab, Ref, self()))
    end, Held).

per_session_limit_is_not_global_test() ->
    Tab = table(),
    Session = {session, digest()},
    Other = {session, other_digest()},
    lists:foreach(fun(_) ->
        ?assertMatch({ok, _}, acquire(Tab, self(), Session))
    end, lists:seq(1, session_limit())),
    ?assertEqual({error, overloaded}, acquire(Tab, self(), Session)),
    {ok, OtherRef} = acquire(Tab, self(), Other),
    lists:foreach(fun(_) ->
        ?assertMatch({ok, _}, acquire(Tab, self(), bootstrap))
    end, lists:seq(1, 5)),
    ?assertEqual(session_limit() + 6, bus_operator_admission:occupied(Tab)),
    ?assertEqual(ok, bus_operator_admission:checkout(Tab, OtherRef, self())).

stale_ref_and_pid_test() ->
    Tab = table(),
    {ok, Ref} = acquire(Tab, self(), bootstrap),
    Impostor = spawn(fun() -> receive after infinity -> ok end end),
    try
        ?assertEqual(stale, bus_operator_admission:checkout(Tab, Ref, Impostor)),
        ?assertEqual(stale, bus_operator_admission:checkout(Tab, make_ref(), self())),
        ok = bus_operator_admission:release(Tab, Ref),
        ?assertEqual(stale, bus_operator_admission:checkout(Tab, Ref, self()))
    after
        exit(Impostor, kill)
    end.

dead_pid_is_rejected_and_reclaimed_test() ->
    Tab = table(),
    Dead = spawn(fun() -> ok end),
    Mon = monitor(process, Dead),
    receive {'DOWN', Mon, process, Dead, _} -> ok end,
    ?assertEqual({error, unavailable}, acquire(Tab, Dead, bootstrap)),
    Conn = spawn(fun() -> receive after infinity -> ok end end),
    {ok, Ref} = acquire(Tab, Conn, {session, digest()}),
    exit(Conn, kill),
    Mon2 = monitor(process, Conn),
    receive {'DOWN', Mon2, process, Conn, _} -> ok end,
    ?assertEqual(1, bus_operator_admission:occupied(Tab)),
    ?assertEqual(1, bus_operator_admission:reclaim_dead(Tab)),
    ?assertEqual(0, bus_operator_admission:occupied(Tab)),
    ?assertEqual(stale, bus_operator_admission:checkout(Tab, Ref, Conn)),
    {ok, _} = acquire(Tab, self(), {session, digest()}).

non_owner_cannot_release_or_reclaim_test() ->
    Tab = table(),
    {ok, Ref} = acquire(Tab, self(), bootstrap),
    Parent = self(),
    Conn = spawn(fun() -> receive after infinity -> ok end end),
    {ok, Live} = acquire(Tab, Conn, bootstrap),
    Other = spawn(fun() ->
        bus_operator_admission:release(Tab, Ref),
        N = bus_operator_admission:reclaim_dead(Tab),
        Parent ! {other_done, N}
    end),
    Reclaimed = receive {other_done, N0} -> N0 after 1000 -> error(no_other) end,
    ?assertEqual(0, Reclaimed),
    ?assertEqual(2, bus_operator_admission:occupied(Tab)),
    ?assertEqual(ok, bus_operator_admission:checkout(Tab, Ref, self())),
    ?assertEqual(ok, bus_operator_admission:checkout(Tab, Live, Conn)),
    exit(Conn, kill),
    Mon = monitor(process, Conn),
    receive {'DOWN', Mon, process, Conn, _} -> ok end,
    OtherDone = spawn(fun() ->
        Parent ! {other_reclaim, bus_operator_admission:reclaim_dead(Tab)}
    end),
    FromOther = receive {other_reclaim, N1} -> N1 after 1000 -> error(no_reclaim) end,
    ?assertEqual(0, FromOther),
    ?assertEqual(2, bus_operator_admission:occupied(Tab)),
    ?assertEqual(1, bus_operator_admission:reclaim_dead(Tab)),
    ?assertEqual(1, bus_operator_admission:occupied(Tab)),
    exit(Other, kill),
    exit(OtherDone, kill).

concurrent_acquires_respect_global_limit_test() ->
    Tab = table(),
    Owner = self(),
    Parent = self(),
    N = limit() + 32,
    Pids = [spawn(fun() ->
        Parent ! {acq, bus_operator_admission:acquire(Tab, Owner, self(), bootstrap)}
    end) || _ <- lists:seq(1, N)],
    Results = [receive {acq, R} -> R after 2000 -> error(stuck) end || _ <- Pids],
    Ok = [Ref || {ok, Ref} <- Results],
    Over = [R || R <- Results, R =:= {error, overloaded}],
    ?assertEqual(N, length(Ok) + length(Over)),
    ?assertEqual(limit(), length(Ok)),
    ?assertEqual(limit(), bus_operator_admission:occupied(Tab)).

stale_owner_does_not_use_replaced_table_test() ->
    Tab = table(),
    Old = self(),
    New = spawn(fun() -> receive stop -> ok end end),
    true = ets:give_away(Tab, New, []),
    try
        ?assertEqual({error, unavailable},
            bus_operator_admission:acquire(Tab, Old, self(), bootstrap)),
        ?assertEqual(undefined, bus_operator_admission:tid(Old))
    after
        New ! stop
    end.
