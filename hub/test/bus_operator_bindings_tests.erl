-module(bus_operator_bindings_tests).
-include_lib("eunit/include/eunit.hrl").

-define(A, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(B, <<"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb">>).
-define(C, <<"cccccccc-cccc-4ccc-8ccc-cccccccccccc">>).
-define(E, <<"dddddddd-dddd-4ddd-8ddd-dddddddddddd">>).

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

doc() ->
    #{<<"schemaVersion">> => 1,
      <<"agentId">> => ?A,
      <<"sessionId">> => ?A,
      <<"runtimeGeneration">> => <<"1">>,
      <<"sessionGeneration">> => <<"1">>,
      <<"branchId">> => null,
      <<"registration">> => null,
      <<"permissionRevision">> => <<"0">>,
      <<"reportRevision">> => <<"1">>,
      <<"capabilities">> => [<<"work.report.v1">>],
      <<"permissions">> => perms(),
      <<"work">> => work(),
      <<"activeRunId">> => null}.

auth() ->
    #{epoch => ?E, registrationGeneration => 1, agentId => ?A, sessionId => ?A}.

id() -> ?A.
id2() -> ?B.

announce(Doc, Auth, Id, S) -> bus_operator_bindings:announce(Doc, Auth, Id, S).

first_bind_and_null_work_test() ->
    S0 = bus_operator_bindings:new(),
    {ok, R, S1} = announce(doc(), auth(), id(), S0),
    ?assertEqual(?A, maps:get(<<"bindingId">>, R)),
    ?assertEqual(<<"1">>, maps:get(<<"workRevision">>, R)),
    ?assertEqual(<<"1">>, maps:get(<<"generation">>, maps:get(<<"registration">>, R))),
    {ok, #{work := W}} = bus_operator_bindings:lookup(?A, S1),
    ?assertEqual(null, maps:get(<<"phase">>, W)),
    ?assertEqual(null, maps:get(<<"objective">>, W)),
    ?assertEqual(null, maps:get(<<"currentStep">>, W)).

populated_first_work_advances_global_revision_test() ->
    D = (doc())#{<<"work">> => populated()},
    {ok, R, S1} = announce(D, auth(), id(), bus_operator_bindings:new()),
    ?assertEqual(<<"1">>, maps:get(<<"workRevision">>, R)),
    {ok, #{work := W}} = bus_operator_bindings:lookup(?A, S1),
    ?assertEqual(<<"implementing">>, maps:get(<<"phase">>, W)),
    {ok, R2, S2} = announce(D, auth(), id2(), S1),
    ?assertEqual(<<"1">>, maps:get(<<"workRevision">>, R2)),
    ?assertEqual(maps:get(<<"bindingId">>, R), maps:get(<<"bindingId">>, R2)),
    ?assertEqual(bus_operator_bindings:bytes(S1), bus_operator_bindings:bytes(S2)).

runtime_scoped_counters_reset_on_new_runtime_test() ->
    High = (doc())#{<<"runtimeGeneration">> => <<"2">>, <<"sessionGeneration">> => <<"9">>,
                    <<"permissionRevision">> => <<"9">>, <<"reportRevision">> => <<"9">>},
    {ok, R1, S1} = announce(High, auth(), id(), bus_operator_bindings:new()),
    Reset = (doc())#{<<"runtimeGeneration">> => <<"3">>, <<"sessionGeneration">> => <<"1">>,
                     <<"permissionRevision">> => <<"0">>, <<"reportRevision">> => <<"1">>},
    {ok, R2, _} = announce(Reset, auth(), id2(), S1),
    ?assert(maps:get(<<"bindingId">>, R1) =/= maps:get(<<"bindingId">>, R2)),
    SameReportNewRuntime = (doc())#{<<"runtimeGeneration">> => <<"4">>,
                                    <<"reportRevision">> => <<"1">>},
    {ok, R3, _} = announce(SameReportNewRuntime, auth(), ?C, S1),
    ?assert(maps:get(<<"bindingId">>, R1) =/= maps:get(<<"bindingId">>, R3)).

capacity_failure_leaves_state_immutable_test() ->
    S0 = bus_operator_bindings:new(),
    SFull = S0#{encoded_bytes => 67108864},
    ?assertEqual({error, capacity}, announce(doc(), auth(), id(), SFull)),
    ?assertEqual(0, bus_operator_bindings:size(S0)),
    ?assertEqual({error, not_found}, bus_operator_bindings:lookup(?A, S0)),
    {ok, _, S1} = announce(doc(), auth(), id(), S0),
    Before = bus_operator_bindings:size(S1),
    Bytes = bus_operator_bindings:bytes(S1),
    Exhausted = S1#{next_work_revision => 18446744073709551616},
    WorkChange = (doc())#{<<"reportRevision">> => <<"2">>, <<"work">> => populated()},
    ?assertEqual({error, capacity}, announce(WorkChange, auth(), id2(), Exhausted)),
    ?assertEqual(Before, bus_operator_bindings:size(Exhausted)),
    ?assertEqual(Bytes, bus_operator_bindings:bytes(Exhausted)),
    {ok, #{work := W}} = bus_operator_bindings:lookup(?A, Exhausted),
    ?assertEqual(null, maps:get(<<"phase">>, W)).

identical_heartbeat_keeps_binding_test() ->
    {ok, R1, S1} = announce(doc(), auth(), id(), bus_operator_bindings:new()),
    WithReg = (doc())#{<<"registration">> =>
        #{<<"epoch">> => ?E, <<"generation">> => <<"1">>}},
    {ok, R2, S2} = announce(WithReg, auth(), id2(), S1),
    ?assertEqual(maps:get(<<"bindingId">>, R1), maps:get(<<"bindingId">>, R2)),
    ?assertEqual(<<"1">>, maps:get(<<"workRevision">>, R2)),
    ?assertEqual(1, bus_operator_bindings:size(S2)).

work_only_keeps_binding_bumps_work_revision_test() ->
    {ok, R1, S1} = announce(doc(), auth(), id(), bus_operator_bindings:new()),
    D2 = (doc())#{<<"reportRevision">> => <<"2">>, <<"work">> => populated()},
    {ok, R2, _} = announce(D2, auth(), id2(), S1),
    ?assertEqual(maps:get(<<"bindingId">>, R1), maps:get(<<"bindingId">>, R2)),
    ?assertEqual(<<"2">>, maps:get(<<"workRevision">>, R2)).

same_report_revision_idempotent_and_conflict_test() ->
    {ok, R1, S1} = announce(doc(), auth(), id(), bus_operator_bindings:new()),
    {ok, R2, _} = announce(doc(), auth(), id2(), S1),
    ?assertEqual(R1, R2),
    Conflict = (doc())#{<<"work">> => populated()},
    ?assertEqual({error, conflict}, announce(Conflict, auth(), id2(), S1)).

older_generations_rejected_test() ->
    D = (doc())#{<<"runtimeGeneration">> => <<"2">>, <<"sessionGeneration">> => <<"2">>,
                 <<"permissionRevision">> => <<"2">>, <<"reportRevision">> => <<"5">>},
    {ok, _, S1} = announce(D, auth(), id(), bus_operator_bindings:new()),
    ?assertEqual({error, stale_generation},
        announce((D)#{<<"runtimeGeneration">> => <<"1">>, <<"reportRevision">> => <<"6">>},
            auth(), id2(), S1)),
    ?assertEqual({error, stale_generation},
        announce((D)#{<<"sessionGeneration">> => <<"1">>, <<"reportRevision">> => <<"6">>},
            auth(), id2(), S1)),
    ?assertEqual({error, stale_generation},
        announce((D)#{<<"permissionRevision">> => <<"1">>, <<"reportRevision">> => <<"6">>},
            auth(), id2(), S1)),
    ?assertEqual({error, stale_generation},
        announce((D)#{<<"reportRevision">> => <<"4">>}, auth(), id2(), S1)).

capability_and_permission_rotate_binding_test() ->
    {ok, R1, S1} = announce(doc(), auth(), id(), bus_operator_bindings:new()),
    Cap = (doc())#{<<"reportRevision">> => <<"2">>,
                   <<"capabilities">> => [<<"work.report.v1">>, <<"label.set.v1">>]},
    {ok, R2, S2} = announce(Cap, auth(), id2(), S1),
    ?assert(maps:get(<<"bindingId">>, R1) =/= maps:get(<<"bindingId">>, R2)),
    ?assertEqual(<<"1">>, maps:get(<<"workRevision">>, R2)),
    Perm = (doc())#{<<"reportRevision">> => <<"3">>,
                    <<"permissions">> => (perms())#{<<"label">> => true}},
    {ok, R3, S3} = announce(Perm, auth(), ?C, S2),
    ?assert(maps:get(<<"bindingId">>, R2) =/= maps:get(<<"bindingId">>, R3)),
    Rev = (doc())#{<<"reportRevision">> => <<"4">>, <<"permissionRevision">> => <<"1">>},
    {ok, R4, _} = announce(Rev, auth(), ?E, S3),
    ?assert(maps:get(<<"bindingId">>, R3) =/= maps:get(<<"bindingId">>, R4)).

offered_unimplemented_caps_are_not_advertised_test() ->
    Offered = [<<"work.report.v1">>, <<"session.current.read.v1">>, <<"label.set.v1">>],
    Cap = (doc())#{<<"capabilities">> => Offered},
    {ok, R1, S1} = announce(Cap, auth(), id(), bus_operator_bindings:new()),
    ?assertEqual([<<"work.report.v1">>, <<"label.set.v1">>, <<"session.current.read.v1">>],
        maps:get(<<"capabilities">>, R1)),
    {ok, #{binding := B}} = bus_operator_bindings:lookup(?A, S1),
    ?assertEqual([<<"work.report.v1">>, <<"label.set.v1">>, <<"session.current.read.v1">>],
        maps:get(<<"capabilities">>, B)),
    OnlyWork = (doc())#{<<"reportRevision">> => <<"2">>,
                        <<"capabilities">> => [<<"work.report.v1">>]},
    {ok, R2, S2} = announce(OnlyWork, auth(), id2(), S1),
    ?assert(maps:get(<<"bindingId">>, R1) =/= maps:get(<<"bindingId">>, R2)),
    ?assertEqual([<<"work.report.v1">>], maps:get(<<"capabilities">>, R2)),
    LabelOnly = (doc())#{<<"reportRevision">> => <<"3">>,
                         <<"capabilities">> => [<<"label.set.v1">>]},
    {ok, R3, _} = announce(LabelOnly, auth(), ?C, S2),
    ?assertEqual([<<"label.set.v1">>], maps:get(<<"capabilities">>, R3)),
    ?assert(maps:get(<<"bindingId">>, R2) =/= maps:get(<<"bindingId">>, R3)).

session_branch_runtime_rotate_test() ->
    {ok, R1, S1} = announce(doc(), auth(), id(), bus_operator_bindings:new()),
    Sess = (doc())#{<<"reportRevision">> => <<"2">>, <<"sessionGeneration">> => <<"2">>},
    {ok, R2, S2} = announce(Sess, auth(), id2(), S1),
    ?assert(maps:get(<<"bindingId">>, R1) =/= maps:get(<<"bindingId">>, R2)),
    Branch = (doc())#{<<"reportRevision">> => <<"3">>, <<"sessionGeneration">> => <<"2">>,
                      <<"branchId">> => <<"leaf-1">>},
    {ok, R3, S3} = announce(Branch, auth(), ?C, S2),
    ?assert(maps:get(<<"bindingId">>, R2) =/= maps:get(<<"bindingId">>, R3)),
    Run = (doc())#{<<"reportRevision">> => <<"4">>, <<"sessionGeneration">> => <<"2">>,
                   <<"branchId">> => <<"leaf-1">>, <<"runtimeGeneration">> => <<"2">>},
    {ok, R4, _} = announce(Run, auth(), ?E, S3),
    ?assert(maps:get(<<"bindingId">>, R3) =/= maps:get(<<"bindingId">>, R4)).

old_registration_and_new_authority_test() ->
    {ok, R1, S1} = announce(doc(), auth(), id(), bus_operator_bindings:new()),
    Stale = (doc())#{<<"registration">> =>
        #{<<"epoch">> => ?E, <<"generation">> => <<"0">>}, <<"reportRevision">> => <<"2">>},
    ?assertEqual({error, stale_generation}, announce(Stale, auth(), id2(), S1)),
    WrongEpoch = (doc())#{<<"registration">> =>
        #{<<"epoch">> => ?A, <<"generation">> => <<"1">>}, <<"reportRevision">> => <<"2">>},
    ?assertEqual({error, epoch_reset}, announce(WrongEpoch, auth(), id2(), S1)),
    NewAuth = (auth())#{registrationGeneration => 2},
    ?assertEqual({error, conflict},
        announce((doc())#{<<"reportRevision">> => <<"2">>}, NewAuth,
            maps:get(<<"bindingId">>, R1), S1)),
    {ok, R2, S2} = announce((doc())#{<<"reportRevision">> => <<"2">>}, NewAuth, id2(), S1),
    ?assert(maps:get(<<"bindingId">>, R1) =/= maps:get(<<"bindingId">>, R2)),
    ?assertEqual(<<"2">>, maps:get(<<"generation">>, maps:get(<<"registration">>, R2))),
    {ok, R3, _} = announce((doc())#{<<"reportRevision">> => <<"3">>}, NewAuth, id(), S2),
    ?assertEqual(maps:get(<<"bindingId">>, R2), maps:get(<<"bindingId">>, R3)).

session_must_match_authority_test() ->
    Auth = (auth())#{sessionId => ?B},
    ?assertEqual({error, conflict}, announce(doc(), Auth, id(), bus_operator_bindings:new())),
    ?assertEqual({error, not_found},
        announce(doc(), (auth())#{agentId => ?B}, id(), bus_operator_bindings:new())).

remove_and_expire_registration_test() ->
    {ok, _, S1} = announce(doc(), auth(), id(), bus_operator_bindings:new()),
    S2 = bus_operator_bindings:expire_registration(?A, ?E, 2, S1),
    ?assertEqual(1, bus_operator_bindings:size(S2)),
    S3 = bus_operator_bindings:expire_registration(?A, ?E, 1, S1),
    ?assertEqual(0, bus_operator_bindings:size(S3)),
    S4 = bus_operator_bindings:remove(?A, S1),
    ?assertEqual({error, not_found}, bus_operator_bindings:lookup(?A, S4)).

invalid_and_envelope_test() ->
    S = bus_operator_bindings:new(),
    ?assertEqual({error, invalid_schema}, announce(#{}, auth(), id(), S)),
    ?assertEqual({error, invalid_schema}, announce(doc(), auth(), <<"not-a-uuid">>, S)),
    Extra = (doc())#{<<"secret">> => <<"no">>},
    ?assertEqual({error, invalid_schema}, announce(Extra, auth(), id(), S)),
    BadCap = (doc())#{<<"capabilities">> => [<<"work.report.v1">>, <<"work.report.v1">>]},
    ?assertEqual({error, invalid_schema}, announce(BadCap, auth(), id(), S)),
    Path = (doc())#{<<"branchId">> => <<"/tmp/session.jsonl">>},
    ?assertEqual({error, invalid_schema}, announce(Path, auth(), id(), S)),
    ?assertEqual({error, envelope},
        announce(binary:copy(<<" ">>, 32769), auth(), id(), S)).

capacity_does_not_evict_test_() ->
    {timeout, 60, fun capacity_does_not_evict/0}.

capacity_does_not_evict() ->
    S0 = bus_operator_bindings:new(),
    SFull = S0#{encoded_bytes => 67108864},
    ?assertEqual({error, capacity}, announce(doc(), auth(), id(), SFull)),
    {ok, _, S1} = announce(doc(), auth(), id(), S0),
    Filled = fill(S1, 2, 5000),
    ?assertEqual(5000, bus_operator_bindings:size(Filled)),
    Extra = (doc())#{<<"agentId">> => <<"ffffffff-ffff-4fff-8fff-ffffffffffff">>,
                     <<"sessionId">> => <<"ffffffff-ffff-4fff-8fff-ffffffffffff">>},
    Auth = #{epoch => ?E, registrationGeneration => 1,
             agentId => <<"ffffffff-ffff-4fff-8fff-ffffffffffff">>,
             sessionId => <<"ffffffff-ffff-4fff-8fff-ffffffffffff">>},
    ?assertEqual({error, capacity}, announce(Extra, Auth, ?C, Filled)),
    ?assertEqual(5000, bus_operator_bindings:size(Filled)),
    {ok, _, _} = announce((doc())#{<<"reportRevision">> => <<"2">>}, auth(), ?C, Filled).

fill(State, N, Max) when N > Max -> State;
fill(State, N, Max) ->
    Agent = uuid_n(N),
    Doc = (doc())#{<<"agentId">> => Agent, <<"sessionId">> => Agent},
    Auth = #{epoch => ?E, registrationGeneration => 1, agentId => Agent, sessionId => Agent},
    {ok, _, Next} = announce(Doc, Auth, Agent, State),
    fill(Next, N + 1, Max).

uuid_n(N) ->
    iolist_to_binary(io_lib:format("~8.16.0b-0000-4000-8000-000000000000", [N])).

work_revision_exhaustion_allows_identity_refresh_test() ->
    {ok, _, S1} = announce(doc(), auth(), id(), bus_operator_bindings:new()),
    Exhausted = S1#{next_work_revision => 18446744073709551616},
    WorkChange = (doc())#{<<"reportRevision">> => <<"2">>, <<"work">> => populated()},
    ?assertEqual({error, capacity}, announce(WorkChange, auth(), id2(), Exhausted)),
    Cap = (doc())#{<<"reportRevision">> => <<"2">>,
                   <<"capabilities">> => [<<"label.set.v1">>]},
    {ok, R, _} = announce(Cap, auth(), id2(), Exhausted),
    ?assertEqual(<<"1">>, maps:get(<<"workRevision">>, R)).
