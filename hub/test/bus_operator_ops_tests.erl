-module(bus_operator_ops_tests).
-include_lib("eunit/include/eunit.hrl").

-define(A, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(O1, <<"11111111-1111-4111-8111-111111111111">>).

ops_test_() ->
    {setup, fun setup/0, fun cleanup/1, {timeout, 30, {inorder, [
        fun create_notice_journals_thread/0,
        fun history_enrolls_notice_body/0
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
    {ok, Ops} = bus_operator_ops:start_link(),
    unlink(Ops),
    ok = bus_store:put_agent(agent()),
    ok.

cleanup(_) ->
    stop_all(),
    ok.

stop_all() ->
    lists:foreach(fun(N) ->
        case whereis(N) of undefined -> ok; Pid -> catch gen_server:stop(Pid) end
    end, [bus_operator_ops, bus_operator_journal, bus_operator_native, bus_store]).

agent() ->
    #{<<"agentId">> => ?A, <<"sessionId">> => ?A, <<"host">> => <<"h">>,
      <<"cwd">> => <<"/tmp">>, <<"sessionName">> => <<"s">>, <<"label">> => <<"l">>,
      <<"model">> => null, <<"status">> => <<"idle">>, <<"pid">> => 1,
      <<"acceptsControl">> => false}.

perms(Hist) ->
    #{<<"notice">> => true, <<"work">> => false, <<"guidance">> => false,
      <<"sessionRead">> => false, <<"label">> => false, <<"interrupt">> => false,
      <<"content">> => false, <<"workAssign">> => false, <<"history">> => Hist}.

work() ->
    {ok, Bin} = file:read_file("../tests/fixtures/operator-work.json"),
    maps:get(<<"allNull">>, json:decode(Bin)).

deadline() -> erlang:monotonic_time(millisecond) + 5000.
digest() -> crypto:hash(sha256, <<"ops-session">>).

announce(Hist) ->
    Doc = #{<<"schemaVersion">> => 1, <<"agentId">> => ?A, <<"sessionId">> => ?A,
            <<"runtimeGeneration">> => <<"1">>, <<"sessionGeneration">> => <<"1">>,
            <<"branchId">> => null, <<"registration">> => null,
            <<"permissionRevision">> => <<"0">>, <<"reportRevision">> => <<"1">>,
            <<"capabilities">> => [<<"notice.receive.v1">>],
            <<"permissions">> => perms(Hist), <<"work">> => work(),
            <<"activeRunId">> => null},
    bus_operator_native:announce(self(), Doc, deadline()).

create(Binding, Text) ->
    bus_operator_ops:create(self(), digest(), #{
        <<"schemaVersion">> => 1,
        <<"operationId">> => ?O1,
        <<"kind">> => <<"notice">>,
        <<"agentId">> => ?A,
        <<"bindingId">> => Binding,
        <<"runtimeGeneration">> => <<"1">>,
        <<"sessionGeneration">> => <<"1">>,
        <<"branchId">> => null,
        <<"runId">> => null,
        <<"workId">> => null,
        <<"deadline">> => integer_to_binary(erlang:system_time(millisecond) + 20000),
        <<"payload">> => #{<<"text">> => Text}
    }, deadline()).

drain() ->
    J = whereis(bus_operator_journal),
    J ! drain,
    sys:get_state(J),
    {ok, Bin} = bus_operator_journal:page(first, self(), digest(), deadline()),
    maps:get(<<"events">>, json:decode(Bin)).

create_notice_journals_thread() ->
    {ok, R} = announce(false),
    Binding = maps:get(<<"bindingId">>, R),
    {ok, Pub} = create(Binding, <<"hello">>),
    ?assertEqual(<<"queued">>, maps:get(<<"state">>, Pub)),
    Events = drain(),
    Ops = [E || E <- Events, maps:get(<<"kind">>, E) =:= <<"operator_requested">>],
    ?assertEqual(1, length(Ops)),
    [Ev] = Ops,
    ?assertEqual(?O1, maps:get(<<"threadId">>, Ev)),
    ?assertEqual(?O1, maps:get(<<"operationId">>, Ev)),
    ?assertEqual(false, maps:is_key(<<"body">>, maps:get(<<"payload">>, Ev))).

history_enrolls_notice_body() ->
    stop_all(),
    setup(),
    {ok, R} = announce(true),
    Binding = maps:get(<<"bindingId">>, R),
    {ok, _} = create(Binding, <<"secret-preview">>),
    Events = drain(),
    Ops = [E || E <- Events, maps:get(<<"kind">>, E) =:= <<"operator_requested">>],
    [Ev] = Ops,
    ?assertEqual(<<"secret-preview">>, maps:get(<<"body">>, maps:get(<<"payload">>, Ev))).
