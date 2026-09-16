-module(bus_operator_fleet_tests).
-include_lib("eunit/include/eunit.hrl").

-define(E, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(S, <<"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb">>).

digest() -> <<1:256>>.
digest2() -> <<2:256>>.
dl() -> erlang:monotonic_time(millisecond) + 5000.

view(N) ->
    Id = iolist_to_binary(io_lib:format("~8.16.0b-0000-4000-8000-000000000000", [N])),
    #{<<"binding">> => #{<<"agentId">> => Id, <<"bindingId">> => Id},
      <<"work">> => #{<<"phase">> => null, <<"objective">> => null},
      <<"permissions">> => #{<<"label">> => false}}.

large_view(N) ->
    V = view(N),
    W = maps:get(<<"work">>, V),
    V#{<<"work">> := W#{<<"objective">> => binary:copy(<<"o">>, 16000)}}.

empty_page_test() ->
    {ok, Bin, F} = bus_operator_fleet:capture([], ?E, 0, 0, 0, 10, dl(), digest(),
        bus_operator_fleet:new(), ?S),
    Doc = json:decode(Bin),
    ?assertEqual(?E, maps:get(<<"epoch">>, Doc)),
    ?assertEqual(?S, maps:get(<<"snapshotId">>, Doc)),
    ?assertEqual(<<"0">>, maps:get(<<"revision">>, Doc)),
    ?assertEqual(10, maps:get(<<"capturedAt">>, Doc)),
    ?assertEqual(0, maps:get(<<"page">>, Doc)),
    ?assertEqual(0, maps:get(<<"total">>, Doc)),
    ?assertEqual([], maps:get(<<"snapshots">>, Doc)),
    ?assertEqual(null, maps:get(<<"nextCursor">>, Doc)),
    ?assertEqual(1, bus_operator_fleet:snapshot_count(F)).

page_splits_at_128_test() ->
    Views = [view(N) || N <- lists:seq(1, 129)],
    {ok, B1, F} = bus_operator_fleet:capture(Views, ?E, 1, 0, 0, 10, dl(), digest(),
        bus_operator_fleet:new(), ?S),
    P1 = json:decode(B1),
    ?assertEqual(128, length(maps:get(<<"snapshots">>, P1))),
    ?assertEqual(129, maps:get(<<"total">>, P1)),
    C = maps:get(<<"nextCursor">>, P1),
    ?assert(is_binary(C)),
    ?assert(byte_size(C) =< 128),
    {ok, B2, _} = bus_operator_fleet:continue(C, digest(), 0, 1, ?E, dl(), F),
    P2 = json:decode(B2),
    ?assertEqual(1, length(maps:get(<<"snapshots">>, P2))),
    ?assertEqual(1, maps:get(<<"page">>, P2)),
    ?assertEqual(null, maps:get(<<"nextCursor">>, P2)).

page_byte_cap_splits_test() ->
    Views = [large_view(N) || N <- lists:seq(1, 80)],
    {ok, B1, F} = bus_operator_fleet:capture(Views, ?E, 1, 0, 0, 10, dl(), digest(),
        bus_operator_fleet:new(), ?S),
    P1 = json:decode(B1),
    ?assert(length(maps:get(<<"snapshots">>, P1)) < 80),
    ?assert(byte_size(B1) =< 1048576),
    C = maps:get(<<"nextCursor">>, P1),
    ?assert(is_binary(C)),
    {ok, B2, _} = bus_operator_fleet:continue(C, digest(), 0, 1, ?E, dl(), F),
    ?assertEqual(80, maps:get(<<"total">>, json:decode(B2))).

total_5000_capacity_test() ->
    Views = [view(1) || _ <- lists:seq(1, 5001)],
    ?assertEqual({error, capacity},
        bus_operator_fleet:capture(Views, ?E, 1, 0, 0, 10, dl(), digest(),
            bus_operator_fleet:new(), ?S)).

eight_snapshots_then_capacity_test() ->
    F0 = bus_operator_fleet:new(),
    F = lists:foldl(fun(N, Acc) ->
        Dig = <<N:256>>,
        Sid = iolist_to_binary(io_lib:format("~8.16.0b-0000-4000-8000-000000000001", [N])),
        {ok, _, Next} = bus_operator_fleet:capture([view(N)], ?E, 1, 0, 0, 10, dl(), Dig, Acc, Sid),
        Next
    end, F0, lists:seq(1, 8)),
    ?assertEqual(8, bus_operator_fleet:snapshot_count(F)),
    ?assertEqual(false, bus_operator_fleet:can_capture(F, 0)),
    ?assertEqual({error, capacity},
        bus_operator_fleet:capture([view(9)], ?E, 1, 0, 0, 10, dl(), digest2(), F, ?S)).

snapshot_byte_budget_test() ->
    F = (bus_operator_fleet:new())#{bytes => 67108864},
    ?assertEqual(false, bus_operator_fleet:can_capture(F, 0)).

expiry_and_stale_cursor_test() ->
    Views = [view(N) || N <- lists:seq(1, 129)],
    {ok, B1, F} = bus_operator_fleet:capture(Views, ?E, 1, 0, 0, 10, dl(), digest(),
        bus_operator_fleet:new(), ?S),
    C = maps:get(<<"nextCursor">>, json:decode(B1)),
    Ttl = bus_operator_fleet:ttl_ms(),
    ?assertEqual({error, epoch_reset},
        bus_operator_fleet:continue(C, digest(), Ttl, 1, ?E, dl(), F)),
    ?assertEqual({error, epoch_reset},
        bus_operator_fleet:continue(C, digest2(), 0, 1, ?E, dl(), F)),
    ?assertEqual({error, epoch_reset},
        bus_operator_fleet:continue(C, digest(), 0, 2, ?E, dl(), F)),
    ?assertEqual({error, invalid_cursor},
        bus_operator_fleet:continue(<<"bad">>, digest(), 0, 1, ?E, dl(), F)).

bound_reuses_first_page_test() ->
    {ok, B1, F} = bus_operator_fleet:capture([view(1)], ?E, 3, 0, 0, 10, dl(), digest(),
        bus_operator_fleet:new(), ?S),
    {ok, B2, _} = bus_operator_fleet:bound(digest(), F, 0, 3, 0, ?E, dl()),
    ?assertEqual(B1, B2),
    ?assertEqual(none, bus_operator_fleet:bound(digest(), F, 0, 4, 0, ?E, dl())).
