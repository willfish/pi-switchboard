-module(bus_operator_history_tests).
-include_lib("eunit/include/eunit.hrl").

-define(A, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(B, <<"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb">>).

history_test() ->
    catch ets:delete(bus_operator_history:table()),
    ?assertEqual(false, bus_operator_history:granted(self(), ?A, 1)),
    ?assertEqual(false, bus_operator_history:current(?A)),
    Tab = ets:new(bus_operator_history:table(), [named_table, set, protected,
        {read_concurrency, true}]),
    ok = bus_operator_history:init(Tab),
    try
        Store = self(),
        ok = bus_operator_history:put(Store, ?A, 1, true),
        ?assertEqual(true, bus_operator_history:granted(Store, ?A, 1)),
        ?assertEqual(false, bus_operator_history:granted(Store, ?A, 2)),
        Other = spawn(fun() -> receive after infinity -> ok end end),
        ?assertEqual(false, bus_operator_history:granted(Other, ?A, 1)),
        exit(Other, kill),
        ?assertEqual(false, bus_operator_history:granted(Store, ?B, 1)),
        ?assertEqual(true, bus_operator_history:current(?A)),
        ok = bus_operator_history:put(Store, ?A, 2, true),
        ?assertEqual(false, bus_operator_history:granted(Store, ?A, 1)),
        ?assertEqual(true, bus_operator_history:granted(Store, ?A, 2)),
        ok = bus_operator_history:put(Store, ?A, 3, false),
        ?assertEqual(false, bus_operator_history:granted(Store, ?A, 3)),
        ok = bus_operator_history:put(Store, ?A, 4, true),
        Limit = bus_operator_history:limit(),
        lists:foreach(fun(N) ->
            Id = iolist_to_binary(io_lib:format("00000000-0000-4000-8000-~12.16.0b", [N])),
            ok = bus_operator_history:put(Store, Id, 1, true)
        end, lists:seq(1, Limit)),
        Extra = <<"ffffffff-ffff-4fff-8fff-ffffffffffff">>,
        ok = bus_operator_history:put(Store, Extra, 1, true),
        ?assertEqual(false, bus_operator_history:current(Extra)),
        ?assertEqual(Limit, ets:info(bus_operator_history:table(), size)),
        ok = bus_operator_history:reset(),
        ?assertEqual(false, bus_operator_history:current(?A))
    after
        catch ets:delete(Tab)
    end.
