-module(bus_operator_ingress_tests).
-include_lib("eunit/include/eunit.hrl").

-define(FROM, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(TO, <<"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb">>).
-define(MSG, <<"cccccccc-cccc-4ccc-8ccc-cccccccccccc">>).

limits_test() ->
    ?assertEqual(128, bus_operator_ingress:limit()),
    ?assertEqual(1048576, bus_operator_ingress:byte_limit()),
    ?assertEqual(98304, bus_operator_ingress:record_limit()).

table() ->
    Tab = ets:new(ingress_test, [set, public]),
    ok = bus_operator_ingress:init(Tab),
    Tab.

meta() ->
    #{<<"kind">> => <<"mail_accepted">>,
      <<"source">> => <<"relay_observed">>,
      <<"payload">> => #{
          <<"id">> => ?MSG,
          <<"from">> => ?FROM,
          <<"to">> => ?TO,
          <<"kind">> => <<"notice">>,
          <<"acceptedAt">> => 1,
          <<"receiving">> => false,
          <<"bodyBytes">> => 0}}.

with_body(Body) ->
    Payload = maps:get(<<"payload">>, meta()),
    maps:put(<<"payload">>, Payload#{<<"body">> => Body,
        <<"bodyBytes">> => byte_size(Body)}, meta()).

insert_ok(Tab, Rec) ->
    case bus_operator_ingress:try_in(Tab, self(), Rec) of
        {ok, wake} -> ok;
        {ok, armed} -> ok;
        Other -> error({unexpected, Other})
    end.

count_overflow_increments_dropped_test() ->
    Tab = table(),
    lists:foreach(fun(_) -> insert_ok(Tab, meta()) end, lists:seq(1, 128)),
    ?assertEqual(128, bus_operator_ingress:occupied(Tab)),
    ?assertEqual(dropped, bus_operator_ingress:try_in(Tab, self(), meta())),
    ?assertEqual(dropped, bus_operator_ingress:try_in(Tab, self(), meta())),
    ?assertEqual(128, bus_operator_ingress:occupied(Tab)),
    ?assertEqual(2, bus_operator_ingress:dropped(Tab)),
    {ok, Recs, Dropped} = bus_operator_ingress:take(Tab, self()),
    ?assertEqual(128, length(Recs)),
    ?assertEqual(2, Dropped),
    ?assertEqual(2, bus_operator_ingress:dropped(Tab)),
    ?assertEqual(0, bus_operator_ingress:occupied(Tab)),
    insert_ok(Tab, meta()),
    ?assertEqual(1, bus_operator_ingress:occupied(Tab)),
    ?assertEqual(2, bus_operator_ingress:dropped(Tab)).

byte_cap_precedes_count_test() ->
    Tab = table(),
    Rec = with_body(binary:copy(<<"x">>, 16384)),
    Opts = #{enroll_bodies => true},
    Fun = fun() -> bus_operator_ingress:try_in(Tab, self(), Rec, Opts) end,
    Results = [Fun() || _ <- lists:seq(1, 128)],
    Ok = [R || R <- Results, R =:= {ok, wake} orelse R =:= {ok, armed}],
    Dropped = [R || R <- Results, R =:= dropped],
    ?assert(length(Ok) < 128),
    ?assert(length(Ok) > 0),
    ?assertEqual(128, length(Ok) + length(Dropped)),
    ?assertEqual(length(Dropped), bus_operator_ingress:dropped(Tab)),
    Encoded = lists:sum([bus_operator_ingress:encoded_size(R, Opts) ||
        R <- lists:duplicate(length(Ok), Rec)]),
    ?assert(Encoded =< 1048576),
    ?assertEqual(length(Ok), bus_operator_ingress:occupied(Tab)).

per_record_cap_drops_expanded_body_test() ->
    Tab = table(),
    Rec = with_body(binary:copy(<<1>>, 16384)),
    Opts = #{enroll_bodies => true},
    Size = bus_operator_ingress:encoded_size(Rec, Opts),
    case Size > 98304 of
        true ->
            ?assertEqual(dropped, bus_operator_ingress:try_in(Tab, self(), Rec, Opts)),
            ?assertEqual(1, bus_operator_ingress:dropped(Tab)),
            ?assertEqual(0, bus_operator_ingress:occupied(Tab)),
            ?assertEqual(true, bus_operator_ingress:drain(Tab));
        false ->
            ?assertMatch({ok, _}, bus_operator_ingress:try_in(Tab, self(), Rec, Opts)),
            ?assert(Size =< 98304)
    end.

oversized_loss_sets_drain_without_pending_test() ->
    Tab = table(),
    Rec = with_body(binary:copy(<<1>>, 16384)),
    Opts = #{enroll_bodies => true},
    Size = bus_operator_ingress:encoded_size(Rec, Opts),
    ?assert(Size > 98304),
    ?assertEqual(dropped, bus_operator_ingress:try_in(Tab, self(), Rec, Opts)),
    ?assertEqual(true, bus_operator_ingress:drain(Tab)),
    ?assertEqual(0, bus_operator_ingress:occupied(Tab)),
    ?assertEqual(1, bus_operator_ingress:dropped(Tab)).

cas_exhaustion_accounts_loss_test() ->
    Tab = table(),
    ok = bus_operator_ingress:force_loss(true),
    try
        ?assertEqual(dropped, bus_operator_ingress:try_in(Tab, self(), meta())),
        ?assertEqual(1, bus_operator_ingress:dropped(Tab)),
        ?assertEqual(0, bus_operator_ingress:occupied(Tab)),
        ?assertEqual(true, bus_operator_ingress:drain(Tab))
    after
        bus_operator_ingress:force_loss(false)
    end.

owner_read_exhaustion_does_not_account_loss_test() ->
    Tab = table(),
    insert_ok(Tab, meta()),
    insert_ok(Tab, meta()),
    ?assertEqual(2, bus_operator_ingress:occupied(Tab)),
    ?assertEqual(0, bus_operator_ingress:dropped(Tab)),
    ok = bus_operator_ingress:force_owner_contention(true),
    try
        ?assertEqual({error, unavailable}, bus_operator_ingress:take(Tab, self())),
        ?assertEqual(2, bus_operator_ingress:occupied(Tab)),
        ?assertEqual(0, bus_operator_ingress:dropped(Tab))
    after
        bus_operator_ingress:force_owner_contention(false)
    end.

invalid_utf8_body_is_invalid_record_not_unavailable_test() ->
    Tab = table(),
    Rec = with_body(<<255, 254>>),
    ?assertEqual({error, invalid_record},
        bus_operator_ingress:try_in(Tab, self(), Rec, #{enroll_bodies => true})),
    ?assertEqual(0, bus_operator_ingress:dropped(Tab)),
    ?assertEqual(0, bus_operator_ingress:occupied(Tab)).

unenrolled_body_is_invalid_not_dropped_test() ->
    Tab = table(),
    Rec = with_body(<<"secret">>),
    ?assertEqual({error, invalid_record},
        bus_operator_ingress:try_in(Tab, self(), Rec)),
    ?assertEqual(0, bus_operator_ingress:dropped(Tab)),
    ?assertEqual(0, bus_operator_ingress:occupied(Tab)).

encode_failure_does_not_throw_or_drop_test() ->
    Tab = table(),
    ?assertEqual({error, invalid_record},
        bus_operator_ingress:try_in(Tab, self(), #{<<"kind">> => self()})),
    ?assertEqual({error, invalid_record},
        bus_operator_ingress:try_in(Tab, self(), #{})),
    ?assertEqual({error, invalid_record},
        bus_operator_ingress:try_in(Tab, self(),
            maps:put(<<"kind">>, <<"heartbeat">>, meta()))),
    ?assertEqual(0, bus_operator_ingress:dropped(Tab)).

wake_rearm_after_take_test() ->
    Tab = table(),
    ?assertEqual(false, bus_operator_ingress:drain(Tab)),
    ?assertEqual({ok, wake}, bus_operator_ingress:try_in(Tab, self(), meta())),
    ?assertEqual(true, bus_operator_ingress:drain(Tab)),
    ?assertEqual({ok, armed}, bus_operator_ingress:try_in(Tab, self(), meta())),
    ?assertEqual(true, bus_operator_ingress:drain(Tab)),
    {ok, [_, _], 0} = bus_operator_ingress:take(Tab, self()),
    ?assertEqual(false, bus_operator_ingress:drain(Tab)),
    ?assertEqual({ok, wake}, bus_operator_ingress:try_in(Tab, self(), meta())).

non_owner_cannot_take_test() ->
    Tab = table(),
    insert_ok(Tab, meta()),
    Parent = self(),
    spawn(fun() -> Parent ! {took, bus_operator_ingress:take(Tab, Parent)} end),
    Other = receive {took, T} -> T after 1000 -> error(stuck) end,
    ?assertEqual({error, unavailable}, Other),
    ?assertEqual(1, bus_operator_ingress:occupied(Tab)).

stale_owner_does_not_use_replaced_table_test() ->
    Tab = table(),
    Old = self(),
    New = spawn(fun() -> receive stop -> ok end end),
    true = ets:give_away(Tab, New, []),
    try
        ?assertEqual({error, unavailable},
            bus_operator_ingress:try_in(Tab, Old, meta())),
        ?assertEqual(undefined, bus_operator_ingress:tid(Old)),
        ?assertEqual(0, bus_operator_ingress:dropped(Tab))
    after
        New ! stop
    end.

ets_write_failure_is_contained_test() ->
    Parent = self(),
    {Owner, Mon} = spawn_monitor(fun() ->
        Tab = ets:new(ingress_protected, [set, protected]),
        ok = bus_operator_ingress:init(Tab),
        Parent ! {ready, self(), Tab},
        receive stop -> ok end
    end),
    receive
        {ready, Owner, Tab} ->
            try
                ?assertEqual({error, unavailable},
                    bus_operator_ingress:try_in(Tab, Owner, meta())),
                ?assertEqual(0, bus_operator_ingress:occupied(Tab))
            after
                Owner ! stop,
                receive {'DOWN', Mon, process, Owner, _} -> ok
                after 1000 -> error(owner_cleanup_timeout)
                end
            end
    after 1000 ->
        exit(Owner, kill),
        error(owner_start_timeout)
    end.

dead_table_is_unavailable_test() ->
    Owner = spawn(fun() -> receive stop -> ok end end),
    Tab = ets:new(ingress_dead, [set, public, {heir, none}]),
    true = ets:give_away(Tab, Owner, []),
    Owner ! stop,
    Mon = monitor(process, Owner),
    receive {'DOWN', Mon, process, Owner, _} -> ok end,
    ?assertEqual({error, unavailable},
        bus_operator_ingress:try_in(Tab, Owner, meta())).

concurrent_overflow_test() ->
    Tab = table(),
    Owner = self(),
    Parent = self(),
    N = bus_operator_ingress:limit() + 32,
    _ = [spawn(fun() ->
        Parent ! {in, bus_operator_ingress:try_in(Tab, Owner, meta())}
    end) || _ <- lists:seq(1, N)],
    Results = [receive {in, R} -> R after 2000 -> error(stuck) end || _ <- lists:seq(1, N)],
    Ok = [R || R <- Results, R =:= {ok, wake} orelse R =:= {ok, armed}],
    Dropped = [R || R <- Results, R =:= dropped],
    ?assertEqual(N, length(Ok) + length(Dropped)),
    ?assertEqual(128, length(Ok)),
    ?assertEqual(32, length(Dropped)),
    ?assertEqual(128, bus_operator_ingress:occupied(Tab)),
    ?assertEqual(32, bus_operator_ingress:dropped(Tab)),
    Wakes = [R || R <- Ok, R =:= {ok, wake}],
    ?assertEqual(1, length(Wakes)).

take_does_not_reset_dropped_test() ->
    Tab = table(),
    lists:foreach(fun(_) -> insert_ok(Tab, meta()) end, lists:seq(1, 128)),
    dropped = bus_operator_ingress:try_in(Tab, self(), meta()),
    {ok, _, 1} = bus_operator_ingress:take(Tab, self()),
    lists:foreach(fun(_) -> insert_ok(Tab, meta()) end, lists:seq(1, 128)),
    dropped = bus_operator_ingress:try_in(Tab, self(), meta()),
    ?assertEqual(2, bus_operator_ingress:dropped(Tab)).
