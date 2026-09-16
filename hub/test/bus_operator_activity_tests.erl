-module(bus_operator_activity_tests).
-include_lib("eunit/include/eunit.hrl").

-define(A, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(E1, <<"11111111-1111-4111-8111-111111111111">>).
-define(E2, <<"22222222-2222-4222-8222-222222222222">>).

activity_test_() ->
    {setup, fun setup/0, fun cleanup/1, {timeout, 30, {inorder, [
        fun rejects_without_capability/0,
        fun accepts_and_dedups/0,
        fun dropped_is_not_hub_loss/0
    ]}}}.

setup() ->
    application:ensure_all_started(crypto),
    stop_all(),
    {ok, Store} = bus_store:start_link(),
    unlink(Store),
    {ok, Native} = bus_operator_native:start_link(),
    unlink(Native),
    {ok, Journal} = bus_operator_journal:start_link(),
    unlink(Journal),
    {ok, Act} = bus_operator_activity:start_link(),
    unlink(Act),
    ok = bus_store:put_agent(agent()),
    #{store => Store}.

cleanup(_) ->
    stop_all(),
    ok.

stop_all() ->
    lists:foreach(fun(N) ->
        case whereis(N) of undefined -> ok; Pid -> catch gen_server:stop(Pid) end
    end, [bus_operator_activity, bus_operator_journal, bus_operator_native, bus_store]).

agent() ->
    #{<<"agentId">> => ?A, <<"sessionId">> => ?A, <<"host">> => <<"h">>,
      <<"cwd">> => <<"/tmp">>, <<"sessionName">> => <<"s">>, <<"label">> => <<"l">>,
      <<"model">> => null, <<"status">> => <<"idle">>, <<"pid">> => 1,
      <<"acceptsControl">> => false}.

perms() ->
    #{<<"notice">> => false, <<"work">> => false, <<"guidance">> => false,
      <<"sessionRead">> => false, <<"label">> => false, <<"interrupt">> => false,
      <<"content">> => false, <<"workAssign">> => false, <<"history">> => false}.

work() ->
    {ok, Bin} = file:read_file("../tests/fixtures/operator-work.json"),
    maps:get(<<"allNull">>, json:decode(Bin)).

announce(Caps) -> announce(Caps, <<"1">>).
announce(Caps, Report) ->
    Doc = #{<<"schemaVersion">> => 1, <<"agentId">> => ?A, <<"sessionId">> => ?A,
            <<"runtimeGeneration">> => <<"1">>, <<"sessionGeneration">> => <<"1">>,
            <<"branchId">> => null, <<"registration">> => null,
            <<"permissionRevision">> => <<"0">>, <<"reportRevision">> => Report,
            <<"capabilities">> => Caps, <<"permissions">> => perms(),
            <<"work">> => work(), <<"activeRunId">> => null},
    bus_operator_native:announce(self(), Doc, deadline()).

deadline() -> erlang:monotonic_time(millisecond) + 5000.

event(Id) ->
    #{<<"id">> => Id, <<"toolCallId">> => <<"call-1">>, <<"toolName">> => <<"read">>,
      <<"state">> => <<"started">>, <<"occurredAt">> => <<"1700000000000">>}.

report(Binding, Events) ->
    bus_operator_activity:report(self(), #{
        <<"schemaVersion">> => 1,
        <<"agentId">> => ?A,
        <<"bindingId">> => Binding,
        <<"runtimeGeneration">> => <<"1">>,
        <<"sessionGeneration">> => <<"1">>,
        <<"events">> => Events,
        <<"dropped">> => <<"0">>
    }, deadline()).

rejects_without_capability() ->
    {ok, R} = announce([<<"work.report.v1">>]),
    Binding = maps:get(<<"bindingId">>, R),
    ?assertEqual({error, forbidden}, report(Binding, [event(?E1)])).

accepts_and_dedups() ->
    {ok, R} = announce([<<"work.report.v1">>, <<"activity.report.v1">>], <<"2">>),
    Binding = maps:get(<<"bindingId">>, R),
    {ok, A1} = report(Binding, [event(?E1), event(?E2)]),
    ?assertEqual(2, maps:get(<<"accepted">>, A1)),
    {ok, A2} = report(Binding, [event(?E1)]),
    ?assertEqual(0, maps:get(<<"accepted">>, A2)),
    Journal = whereis(bus_operator_journal),
    Journal ! drain,
    sys:get_state(Journal),
    {ok, Bin} = bus_operator_journal:page(first, self(),
        crypto:hash(sha256, <<"x">>), deadline()),
    Events = maps:get(<<"events">>, json:decode(Bin)),
    Tools = [E || E <- Events, maps:get(<<"kind">>, E) =:= <<"tool_reported">>],
    ?assertEqual(2, length(Tools)),
    [T | _] = Tools,
    ?assertEqual(<<"client_reported">>, maps:get(<<"source">>, T)),
    Pay = maps:get(<<"payload">>, T),
    ?assertEqual(<<"call-1">>, maps:get(<<"toolCallId">>, Pay)),
    ?assertEqual(false, maps:is_key(<<"args">>, Pay)).

dropped_is_not_hub_loss() ->
    {ok, R} = announce([<<"activity.report.v1">>], <<"3">>),
    Binding = maps:get(<<"bindingId">>, R),
    {ok, #{<<"accepted">> := 0}} = bus_operator_activity:report(self(), #{
        <<"schemaVersion">> => 1,
        <<"agentId">> => ?A,
        <<"bindingId">> => Binding,
        <<"runtimeGeneration">> => <<"1">>,
        <<"sessionGeneration">> => <<"1">>,
        <<"events">> => [],
        <<"dropped">> => <<"9">>
    }, deadline()),
    Journal = whereis(bus_operator_journal),
    Journal ! drain,
    sys:get_state(Journal),
    {ok, Bin} = bus_operator_journal:page(first, self(),
        crypto:hash(sha256, <<"y">>), deadline()),
    Lost = [E || E <- maps:get(<<"events">>, json:decode(Bin)),
        maps:get(<<"kind">>, E) =:= <<"observation_lost">>],
    ?assertEqual([], Lost).
