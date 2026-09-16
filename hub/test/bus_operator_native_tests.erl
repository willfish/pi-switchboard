-module(bus_operator_native_tests).
-include_lib("eunit/include/eunit.hrl").

-define(A, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(B, <<"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb">>).
-define(C, <<"cccccccc-cccc-4ccc-8ccc-cccccccccccc">>).

native_test_() ->
    {setup, fun setup/0, fun cleanup/1, {inorder, [
        fun init_does_not_call_store/0,
        fun announce_unavailable_without_store/0,
        fun announce_and_stable_receipt/0,
        fun lookup_revalidates_and_drops_expired/0,
        fun generation_conflict/0,
        fun fleet_page_filters_missing_and_view_revision/0,
        {timeout, 15, fun queued_timeout_keeps_slot/0}
    ]}}.

setup() ->
    application:ensure_all_started(crypto),
    stop_all(),
    {ok, Store} = bus_store:start_link(),
    unlink(Store),
    {ok, Native} = bus_operator_native:start_link(),
    unlink(Native),
    #{store => Store, native => Native}.

cleanup(_) ->
    stop_all(),
    ok.

stop_all() ->
    lists:foreach(fun(Name) ->
        case whereis(Name) of
            undefined -> ok;
            Pid -> catch gen_server:stop(Pid)
        end
    end, [bus_operator_native, bus_store]).

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

doc() -> doc(?A).
doc(Id) ->
    #{<<"schemaVersion">> => 1, <<"agentId">> => Id, <<"sessionId">> => Id,
      <<"runtimeGeneration">> => <<"1">>, <<"sessionGeneration">> => <<"1">>,
      <<"branchId">> => null, <<"registration">> => null,
      <<"permissionRevision">> => <<"0">>, <<"reportRevision">> => <<"1">>,
      <<"capabilities">> => [<<"work.report.v1">>],
      <<"permissions">> => perms(), <<"work">> => work(),
      <<"activeRunId">> => null}.

agent(Id) ->
    #{<<"agentId">> => Id, <<"sessionId">> => Id, <<"host">> => <<"test">>,
      <<"cwd">> => <<"/tmp">>, <<"sessionName">> => <<"test">>, <<"label">> => <<"test">>,
      <<"model">> => null, <<"status">> => <<"idle">>, <<"pid">> => 1,
      <<"acceptsControl">> => false}.

deadline() -> erlang:monotonic_time(millisecond) + 5000.

announce(Doc) -> bus_operator_native:announce(self(), Doc, deadline()).

init_does_not_call_store() ->
    catch gen_server:stop(whereis(bus_operator_native)),
    {ok, Pid} = bus_operator_native:start_link(),
    unlink(Pid),
    #{store := undefined} = sys:get_state(Pid),
    Pid ! expire,
    #{store := Store} = sys:get_state(Pid),
    ?assert(is_pid(Store)).

announce_unavailable_without_store() ->
    catch gen_server:stop(whereis(bus_store)),
    whereis(bus_operator_native) ! expire,
    sys:get_state(whereis(bus_operator_native)),
    ?assertEqual({error, unavailable}, announce(doc())),
    {ok, Store} = bus_store:start_link(),
    unlink(Store),
    whereis(bus_operator_native) ! expire,
    sys:get_state(whereis(bus_operator_native)).

announce_and_stable_receipt() ->
    ok = bus_store:put_agent(agent(?A)),
    {ok, R1} = announce(doc()),
    {ok, R2} = announce(doc()),
    ?assertEqual(maps:get(<<"bindingId">>, R1), maps:get(<<"bindingId">>, R2)),
    {ok, #{work := W}} = bus_operator_native:lookup(self(), ?A, deadline()),
    ?assertEqual(null, maps:get(<<"phase">>, W)).

lookup_revalidates_and_drops_expired() ->
    ok = bus_store:put_agent(agent(?B)),
    {ok, _} = announce(doc(?B)),
    ok = bus_store:delete_agent(?B),
    ?assertEqual({error, not_found}, bus_operator_native:lookup(self(), ?B, deadline())),
    ok = bus_store:put_agent(agent(?B)),
    {ok, R} = announce((doc(?B))#{<<"reportRevision">> => <<"2">>}),
    ?assertEqual(true, is_binary(maps:get(<<"bindingId">>, R))).

generation_conflict() ->
    ok = bus_store:put_agent(agent(?C)),
    {ok, _} = announce(doc(?C)),
    Conflict = (doc(?C))#{<<"work">> => populated()},
    ?assertEqual({error, conflict}, announce(Conflict)),
    Stale = (doc(?C))#{<<"runtimeGeneration">> => <<"0">>, <<"reportRevision">> => <<"2">>},
    ?assertEqual({error, stale_generation}, announce(Stale)).

fleet_page_filters_missing_and_view_revision() ->
    Digest = <<1:256>>,
    Rev1 = maps:get(view_revision, sys:get_state(whereis(bus_operator_native))),
    {ok, _} = announce(doc()),
    Rev2 = maps:get(view_revision, sys:get_state(whereis(bus_operator_native))),
    ?assertEqual(Rev1, Rev2),
    {ok, Bin} = bus_operator_native:page(self(), Digest, first, deadline()),
    Page = json:decode(Bin),
    lists:foreach(fun(K) -> ?assertEqual(true, maps:is_key(K, Page)) end,
        [<<"epoch">>, <<"snapshotId">>, <<"revision">>, <<"capturedAt">>,
         <<"page">>, <<"total">>, <<"snapshots">>, <<"nextCursor">>]),
    Ids = [maps:get(<<"agentId">>, maps:get(<<"binding">>, S))
           || S <- maps:get(<<"snapshots">>, Page)],
    ?assert(lists:member(?A, Ids)),
    ?assert(lists:member(?C, Ids)),
    ok = bus_store:delete_agent(?C),
    {ok, Bin2} = bus_operator_native:page(self(), Digest, first, deadline()),
    Ids2 = [maps:get(<<"agentId">>, maps:get(<<"binding">>, S))
            || S <- maps:get(<<"snapshots">>, json:decode(Bin2))],
    ?assertEqual(false, lists:member(?C, Ids2)).

queued_timeout_keeps_slot() ->
    Native = whereis(bus_operator_native),
    ok = bus_store:put_agent(agent(?A)),
    ok = sys:suspend(Native),
    Parent = self(),
    spawn(fun() ->
        Parent ! {ann, bus_operator_native:announce(self(), doc(),
            erlang:monotonic_time(millisecond) + 80)}
    end),
    await_occupied(1),
    receive {ann, {error, timeout}} -> ok after 2000 -> error(no_timeout) end,
    ?assertEqual(1, occupied()),
    ok = sys:resume(Native),
    await_occupied(0).

occupied() -> bus_operator_admission:occupied(bus_operator_native:slots()).

await_occupied(N) -> await_occupied(N, 40).
await_occupied(N, 0) -> error({occupied, occupied(), expected, N});
await_occupied(N, Tries) ->
    case occupied() of
        N -> ok;
        _ -> timer:sleep(25), await_occupied(N, Tries - 1)
    end.
