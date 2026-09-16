-module(bus_operator_operations_tests).
-include_lib("eunit/include/eunit.hrl").

-define(A, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(B, <<"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb">>).
-define(C, <<"cccccccc-cccc-4ccc-8ccc-cccccccccccc">>).
-define(D, <<"dddddddd-dddd-4ddd-8ddd-dddddddddddd">>).
-define(R, <<"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee">>).
-define(O1, <<"11111111-1111-4111-8111-111111111111">>).
-define(O2, <<"22222222-2222-4222-8222-222222222222">>).
-define(O3, <<"33333333-3333-4333-8333-333333333333">>).
-define(NOW, 1700000000000).

digest() ->
    application:ensure_all_started(crypto),
    crypto:hash(sha256, <<"session-a">>).
digest2() -> crypto:hash(sha256, <<"session-b">>).

work_null() ->
    {ok, Bin} = file:read_file("../tests/fixtures/operator-work.json"),
    maps:get(<<"allNull">>, json:decode(Bin)).

work_pop() ->
    {ok, Bin} = file:read_file("../tests/fixtures/operator-work.json"),
    maps:get(<<"populated">>, json:decode(Bin)).

perms(Overrides) ->
    Base = #{<<"notice">> => false, <<"work">> => false, <<"guidance">> => false,
             <<"sessionRead">> => false, <<"label">> => false,
             <<"interrupt">> => false, <<"content">> => false,
             <<"workAssign">> => false, <<"history">> => false},
    maps:merge(Base, Overrides).

caps(List) -> List.

view(Opts) ->
    Binding = #{
        <<"agentId">> => maps:get(agent, Opts, ?A),
        <<"sessionId">> => maps:get(session, Opts, ?A),
        <<"bindingId">> => maps:get(binding, Opts, ?B),
        <<"runtimeGeneration">> => maps:get(runtime, Opts, <<"1">>),
        <<"sessionGeneration">> => maps:get(session_gen, Opts, <<"1">>),
        <<"branchId">> => maps:get(branch, Opts, null),
        <<"capabilities">> => maps:get(caps, Opts, caps([
            <<"notice.receive.v1">>, <<"work.enqueue.v1">>,
            <<"guidance.attempt.v1">>, <<"label.set.v1">>,
            <<"run.interrupt.active.v1">>, <<"session.current.read.v1">>,
            <<"work.assign.v1">>])),
        <<"activeRunId">> => maps:get(run, Opts, null)
    },
    #{binding => Binding,
      work => maps:get(work, Opts, work_null()),
      permissions => perms(maps:get(perms, Opts, #{}))}.

create_doc(Id, Kind, Payload) ->
    create_doc(Id, Kind, Payload, #{}).
create_doc(Id, Kind, Payload, Opts) ->
    #{<<"schemaVersion">> => 1,
      <<"operationId">> => Id,
      <<"kind">> => Kind,
      <<"agentId">> => maps:get(agent, Opts, ?A),
      <<"bindingId">> => maps:get(binding, Opts, ?B),
      <<"runtimeGeneration">> => maps:get(runtime, Opts, <<"1">>),
      <<"sessionGeneration">> => maps:get(session_gen, Opts, <<"1">>),
      <<"branchId">> => maps:get(branch, Opts, null),
      <<"runId">> => maps:get(run, Opts, null),
      <<"workId">> => maps:get(work_id, Opts, null),
      <<"deadline">> => integer_to_binary(maps:get(deadline, Opts, ?NOW + 20000)),
      <<"payload">> => Payload}.

native_doc(Kind, OpId, Status) ->
    native_doc(Kind, OpId, Status, #{}).
native_doc(Kind, OpId, Status, Extra) ->
    maps:merge(#{
        <<"schemaVersion">> => 1,
        <<"kind">> => Kind,
        <<"operationId">> => OpId,
        <<"agentId">> => ?A,
        <<"bindingId">> => ?B,
        <<"runtimeGeneration">> => <<"1">>,
        <<"sessionGeneration">> => <<"1">>,
        <<"status">> => Status
    }, Extra).

all_unassembled_status_pages_are_json_null_test() ->
    V = view(#{run => ?R, perms => #{<<"notice">> => true, <<"work">> => true,
        <<"guidance">> => true, <<"label">> => true, <<"interrupt">> => true,
        <<"sessionRead">> => true, <<"content">> => true, <<"workAssign">> => true}}),
    Cases = [{<<"notice">>, #{<<"text">> => <<"hello">>}},
             {<<"work">>, #{<<"text">> => <<"hello">>}},
             {<<"guidance">>, #{<<"text">> => <<"hello">>}},
             {<<"label">>, #{<<"label">> => <<"Label">>}},
             {<<"interrupt">>, #{<<"reason">> => null}},
             {<<"sessionRead">>, #{<<"leafId">> => null, <<"limit">> => <<"64">>}},
             {<<"workAssign">>, #{<<"work">> => work_pop()}}],
    lists:foreach(fun({Kind, Payload}) ->
        Opts = case Kind of <<"interrupt">> -> #{run => ?R}; _ -> #{} end,
        {ok, Queued, created, S1} = bus_operator_operations:create(
            create_doc(?O1, Kind, Payload, Opts), V, digest(), ?NOW, bus_operator_operations:new()),
        ?assertEqual(null, maps:get(<<"page">>, json:decode(iolist_to_binary(json:encode(Queued))))),
        {ok, _, true, S2} = bus_operator_operations:result(
            native_doc(<<"receipt">>, ?O1, <<"received">>), V, ?NOW + 1, S1),
        {ok, Received} = bus_operator_operations:status(?O1, S2),
        ?assertEqual(null, maps:get(<<"page">>, json:decode(iolist_to_binary(json:encode(Received)))))
    end, Cases).

notice_create_and_receipt_received_test() ->
    V = view(#{perms => #{<<"notice">> => true}}),
    S0 = bus_operator_operations:new(),
    {ok, Pub, created, S1} = bus_operator_operations:create(
        create_doc(?O1, <<"notice">>, #{<<"text">> => <<"hello">>}), V, digest(), ?NOW, S0),
    ?assertEqual(<<"queued">>, maps:get(<<"state">>, Pub)),
    {ok, Ack, true, S2} = bus_operator_operations:result(
        native_doc(<<"receipt">>, ?O1, <<"received">>), V, ?NOW + 1, S1),
    ?assertEqual(<<"received">>, maps:get(<<"state">>, Ack)),
    {ok, St} = bus_operator_operations:status(?O1, S2),
    ?assertEqual(<<"received">>, maps:get(<<"state">>, St)),
    {ok, Ack2, true, _} = bus_operator_operations:result(
        native_doc(<<"result">>, ?O1, <<"context_reserved">>), V, ?NOW + 2, S2),
    ?assertEqual(<<"context_reserved">>, maps:get(<<"state">>, Ack2)).

notice_does_not_occupy_mutating_slot_test() ->
    V = view(#{perms => #{<<"notice">> => true, <<"work">> => true}}),
    S0 = bus_operator_operations:new(),
    {ok, _, created, S1} = bus_operator_operations:create(
        create_doc(?O1, <<"notice">>, #{<<"text">> => <<"n">>}), V, digest(), ?NOW, S0),
    {ok, Work, created, _} = bus_operator_operations:create(
        create_doc(?O2, <<"work">>, #{<<"text">> => <<"do it">>}), V, digest(), ?NOW, S1),
    ?assertEqual(<<"queued">>, maps:get(<<"state">>, Work)).

notice_quota_32_test() ->
    V = view(#{perms => #{<<"notice">> => true}}),
    S = lists:foldl(fun(N, Acc) ->
        Id = uuid_n(N),
        {ok, _, created, Next} = bus_operator_operations:create(
            create_doc(Id, <<"notice">>, #{<<"text">> => <<"n">>}), V,
            crypto:hash(sha256, integer_to_binary(N)), ?NOW, Acc),
        Next
    end, bus_operator_operations:new(), lists:seq(1, 32)),
    ?assertEqual({error, capacity}, bus_operator_operations:create(
        create_doc(?O1, <<"notice">>, #{<<"text">> => <<"n">>}), V, digest(), ?NOW, S)).

mutating_slot_one_test() ->
    V = view(#{perms => #{<<"work">> => true, <<"guidance">> => true}}),
    {ok, _, created, S1} = bus_operator_operations:create(
        create_doc(?O1, <<"work">>, #{<<"text">> => <<"a">>}), V, digest(), ?NOW,
        bus_operator_operations:new()),
    ?assertEqual({error, capacity}, bus_operator_operations:create(
        create_doc(?O2, <<"guidance">>, #{<<"text">> => <<"b">>}), V, digest(), ?NOW, S1)).

interrupt_pins_run_id_test() ->
    V = view(#{perms => #{<<"interrupt">> => true}, run => ?R}),
    {ok, Pub, created, _} = bus_operator_operations:create(
        create_doc(?O1, <<"interrupt">>, #{<<"reason">> => null}, #{run => ?R}),
        V, digest(), ?NOW, bus_operator_operations:new()),
    ?assertEqual(?R, maps:get(<<"runId">>, Pub)),
    ?assertEqual({error, stale_generation}, bus_operator_operations:create(
        create_doc(?O2, <<"interrupt">>, #{<<"reason">> => null}, #{run => ?C}),
        V, digest(), ?NOW, bus_operator_operations:new())).

work_id_pin_and_work_assign_test() ->
    Pop = work_pop(),
    V = view(#{perms => #{<<"workAssign">> => true}, work => work_null()}),
    {ok, Pub, created, S1} = bus_operator_operations:create(
        create_doc(?O1, <<"workAssign">>, #{<<"work">> => Pop}),
        V, digest(), ?NOW, bus_operator_operations:new()),
    ?assertEqual(null, maps:get(<<"workId">>, Pub)),
    {ok, Ack, true, S2} = bus_operator_operations:result(
        native_doc(<<"receipt">>, ?O1, <<"received">>), V, ?NOW + 1, S1),
    ?assertEqual(<<"accepted">>, maps:get(<<"state">>, Ack)),
    {ok, Done, true, _} = bus_operator_operations:result(
        native_doc(<<"result">>, ?O1, <<"work_assigned">>), V, ?NOW + 2, S2),
    ?assertEqual(<<"work_assigned">>, maps:get(<<"state">>, Done)),
    V2 = view(#{perms => #{<<"workAssign">> => true}, work => Pop}),
    ?assertEqual({error, stale_generation}, bus_operator_operations:create(
        create_doc(?O2, <<"workAssign">>, #{<<"work">> => Pop}),
        V2, digest(), ?NOW, bus_operator_operations:new())).

label_and_session_page_omitted_integer_test() ->
    V = view(#{perms => #{<<"label">> => true, <<"sessionRead">> => true,
                         <<"content">> => true}}),
    {ok, _, created, S1} = bus_operator_operations:create(
        create_doc(?O1, <<"label">>, #{<<"label">> => <<"ok">>}), V, digest(), ?NOW,
        bus_operator_operations:new()),
    {ok, _, true, S2} = bus_operator_operations:result(
        native_doc(<<"receipt">>, ?O1, <<"received">>), V, ?NOW + 1, S1),
    {ok, Lab, true, _} = bus_operator_operations:result(
        native_doc(<<"result">>, ?O1, <<"labelled">>), V, ?NOW + 2, S2),
    ?assertEqual(<<"labelled">>, maps:get(<<"state">>, Lab)),
    {ok, _, created, S3} = bus_operator_operations:create(
        create_doc(?O2, <<"sessionRead">>, #{<<"leafId">> => null, <<"limit">> => <<"8">>}),
        V, digest(), ?NOW, bus_operator_operations:new()),
    {ok, _, true, S4} = bus_operator_operations:result(
        native_doc(<<"receipt">>, ?O2, <<"received">>), V, ?NOW + 1, S3),
    Page = #{<<"schemaVersion">> => 1, <<"sessionId">> => ?A,
             <<"leafId">> => null, <<"nextLeafId">> => null,
             <<"records">> => [#{<<"entryId">> => <<"e1">>, <<"role">> => <<"user">>,
                                 <<"text">> => <<"hi">>}],
             <<"omitted">> => 3, <<"truncated">> => false},
    Raw = iolist_to_binary(json:encode(Page)),
    Hex = string:lowercase(binary:encode_hex(crypto:hash(sha256, Raw))),
    {ok, _, _, S5} = bus_operator_operations:result(
        native_doc(<<"fragment">>, ?O2, <<"assembling">>,
            #{<<"index">> => 0, <<"count">> => 1,
              <<"data">> => base64:encode(Raw), <<"digest">> => Hex}),
        V, ?NOW + 2, S4),
    {ok, St} = bus_operator_operations:status(?O2, S5),
    ?assertEqual(<<"completed">>, maps:get(<<"state">>, St)),
    Assembled = maps:get(<<"page">>, St),
    ?assertEqual(3, maps:get(<<"omitted">>, Assembled)),
    ?assertEqual(false, is_boolean(maps:get(<<"omitted">>, Assembled))).

boolean_omitted_rejected_test() ->
    V = view(#{perms => #{<<"sessionRead">> => true, <<"content">> => true}}),
    {ok, _, created, S1} = bus_operator_operations:create(
        create_doc(?O1, <<"sessionRead">>, #{<<"leafId">> => null, <<"limit">> => <<"1">>}),
        V, digest(), ?NOW, bus_operator_operations:new()),
    {ok, _, true, S2} = bus_operator_operations:result(
        native_doc(<<"receipt">>, ?O1, <<"received">>), V, ?NOW + 1, S1),
    Page = #{<<"schemaVersion">> => 1, <<"sessionId">> => ?A,
             <<"leafId">> => null, <<"nextLeafId">> => null, <<"records">> => [],
             <<"omitted">> => true, <<"truncated">> => false},
    Raw = iolist_to_binary(json:encode(Page)),
    Hex = string:lowercase(binary:encode_hex(crypto:hash(sha256, Raw))),
    ?assertEqual({error, invalid_schema}, bus_operator_operations:result(
        native_doc(<<"fragment">>, ?O1, <<"assembling">>,
            #{<<"index">> => 0, <<"count">> => 1,
              <<"data">> => base64:encode(Raw), <<"digest">> => Hex}),
        V, ?NOW + 2, S2)).

session_page() ->
    #{<<"schemaVersion">> => 1, <<"sessionId">> => ?A,
      <<"leafId">> => null, <<"nextLeafId">> => null, <<"records">> => [],
      <<"omitted">> => 0, <<"truncated">> => false}.

session_frag(OpId, Raw, Hex) ->
    native_doc(<<"fragment">>, OpId, <<"assembling">>,
        #{<<"index">> => 0, <<"count">> => 1,
          <<"data">> => base64:encode(Raw), <<"digest">> => Hex}).

cancel_then_fragment_stays_cancelled_test() ->
    V = view(#{perms => #{<<"sessionRead">> => true, <<"content">> => true}}),
    {ok, _, created, S1} = bus_operator_operations:create(
        create_doc(?O1, <<"sessionRead">>, #{<<"leafId">> => null, <<"limit">> => <<"1">>}),
        V, digest(), ?NOW, bus_operator_operations:new()),
    {ok, _, true, S2} = bus_operator_operations:result(
        native_doc(<<"receipt">>, ?O1, <<"received">>), V, ?NOW + 1, S1),
    {ok, C, true, S3} = bus_operator_operations:cancel(?O1, digest(), ?NOW + 2, S2),
    ?assertEqual(<<"cancelled">>, maps:get(<<"state">>, C)),
    ?assertEqual(null, maps:get(<<"page">>, C)),
    Raw = iolist_to_binary(json:encode(session_page())),
    Hex = string:lowercase(binary:encode_hex(crypto:hash(sha256, Raw))),
    {ok, Ack, false, S4} = bus_operator_operations:result(
        session_frag(?O1, Raw, Hex), V, ?NOW + 3, S3),
    ?assertEqual(<<"cancelled">>, maps:get(<<"state">>, Ack)),
    {ok, St} = bus_operator_operations:status(?O1, S4),
    ?assertEqual(<<"cancelled">>, maps:get(<<"state">>, St)),
    ?assertEqual(null, maps:get(<<"page">>, St)).

completed_duplicate_last_fragment_idempotent_test() ->
    V = view(#{perms => #{<<"sessionRead">> => true, <<"content">> => true}}),
    {ok, _, created, S1} = bus_operator_operations:create(
        create_doc(?O1, <<"sessionRead">>, #{<<"leafId">> => null, <<"limit">> => <<"1">>}),
        V, digest(), ?NOW, bus_operator_operations:new()),
    {ok, _, true, S2} = bus_operator_operations:result(
        native_doc(<<"receipt">>, ?O1, <<"received">>), V, ?NOW + 1, S1),
    Raw = iolist_to_binary(json:encode(session_page())),
    Hex = string:lowercase(binary:encode_hex(crypto:hash(sha256, Raw))),
    {ok, Done, true, S3} = bus_operator_operations:result(
        session_frag(?O1, Raw, Hex), V, ?NOW + 2, S2),
    ?assertEqual(<<"completed">>, maps:get(<<"state">>, Done)),
    {ok, Again, false, S4} = bus_operator_operations:result(
        session_frag(?O1, Raw, Hex), V, ?NOW + 3, S3),
    ?assertEqual(<<"completed">>, maps:get(<<"state">>, Again)),
    {ok, St} = bus_operator_operations:status(?O1, S4),
    ?assertEqual(<<"completed">>, maps:get(<<"state">>, St)),
    Other = string:lowercase(binary:encode_hex(crypto:hash(sha256, <<"nope">>))),
    ?assertEqual({error, conflict}, bus_operator_operations:result(
        session_frag(?O1, Raw, Other), V, ?NOW + 4, S4)).

conflict_duplicate_index_test() ->
    V = view(#{perms => #{<<"sessionRead">> => true, <<"content">> => true}}),
    {ok, _, created, S1} = bus_operator_operations:create(
        create_doc(?O1, <<"sessionRead">>, #{<<"leafId">> => null, <<"limit">> => <<"2">>}),
        V, digest(), ?NOW, bus_operator_operations:new()),
    {ok, _, true, S2} = bus_operator_operations:result(
        native_doc(<<"receipt">>, ?O1, <<"received">>), V, ?NOW + 1, S1),
    A = <<"aaaa">>,
    B = <<"bbbb">>,
    {ok, _, _, S3} = bus_operator_operations:result(
        native_doc(<<"fragment">>, ?O1, <<"assembling">>,
            #{<<"index">> => 0, <<"count">> => 2, <<"data">> => base64:encode(A)}),
        V, ?NOW + 2, S2),
    {ok, Dup, false, _} = bus_operator_operations:result(
        native_doc(<<"fragment">>, ?O1, <<"assembling">>,
            #{<<"index">> => 0, <<"count">> => 2, <<"data">> => base64:encode(A)}),
        V, ?NOW + 3, S3),
    ?assertEqual(<<"assembling">>, maps:get(<<"state">>, Dup)),
    ?assertEqual({error, conflict}, bus_operator_operations:result(
        native_doc(<<"fragment">>, ?O1, <<"assembling">>,
            #{<<"index">> => 0, <<"count">> => 2, <<"data">> => base64:encode(B)}),
        V, ?NOW + 4, S3)).

result_survives_binding_rotation_receipt_does_not_test() ->
    V1 = view(#{perms => #{<<"work">> => true}}),
    {ok, _, created, S1} = bus_operator_operations:create(
        create_doc(?O1, <<"work">>, #{<<"text">> => <<"a">>}), V1, digest(), ?NOW,
        bus_operator_operations:new()),
    {ok, _, true, S2} = bus_operator_operations:result(
        native_doc(<<"receipt">>, ?O1, <<"received">>), V1, ?NOW + 1, S1),
    V2 = view(#{binding => ?C, session_gen => <<"2">>,
                perms => #{<<"work">> => true}}),
    ?assertEqual({error, stale_generation}, bus_operator_operations:result(
        native_doc(<<"receipt">>, ?O1, <<"received">>), V2, ?NOW + 2, S2)),
    {ok, Attempted, true, S3} = bus_operator_operations:result(
        native_doc(<<"result">>, ?O1, <<"attempted">>), V2, ?NOW + 3, S2),
    ?assertEqual(<<"attempted">>, maps:get(<<"state">>, Attempted)),
    {ok, Observed, true, _} = bus_operator_operations:result(
        native_doc(<<"result">>, ?O1, <<"observed">>), V2, ?NOW + 4, S3),
    ?assertEqual(<<"observed">>, maps:get(<<"state">>, Observed)).

fragment_requires_current_content_permission_test() ->
    V = view(#{perms => #{<<"sessionRead">> => true, <<"content">> => true}}),
    {ok, _, created, S1} = bus_operator_operations:create(
        create_doc(?O1, <<"sessionRead">>, #{<<"leafId">> => null, <<"limit">> => <<"1">>}),
        V, digest(), ?NOW, bus_operator_operations:new()),
    {ok, _, true, S2} = bus_operator_operations:result(
        native_doc(<<"receipt">>, ?O1, <<"received">>), V, ?NOW + 1, S1),
    VRevoked = view(#{perms => #{<<"sessionRead">> => true, <<"content">> => false}}),
    Page = #{<<"schemaVersion">> => 1, <<"sessionId">> => ?A,
             <<"leafId">> => null, <<"nextLeafId">> => null, <<"records">> => [],
             <<"omitted">> => 0, <<"truncated">> => false},
    Raw = iolist_to_binary(json:encode(Page)),
    Hex = string:lowercase(binary:encode_hex(crypto:hash(sha256, Raw))),
    ?assertEqual({error, forbidden}, bus_operator_operations:result(
        native_doc(<<"fragment">>, ?O1, <<"assembling">>,
            #{<<"index">> => 0, <<"count">> => 1,
              <<"data">> => base64:encode(Raw), <<"digest">> => Hex}),
        VRevoked, ?NOW + 2, S2)).

expiry_and_clock_rollback_test() ->
    V = view(#{perms => #{<<"work">> => true}}),
    {ok, _, created, S1} = bus_operator_operations:create(
        create_doc(?O1, <<"work">>, #{<<"text">> => <<"a">>}), V, digest(), ?NOW,
        bus_operator_operations:new()),
    {S2, []} = bus_operator_operations:expire(?NOW - 1, S1),
    {ok, Still} = bus_operator_operations:status(?O1, S2),
    ?assertEqual(<<"queued">>, maps:get(<<"state">>, Still)),
    {S3, [Exp]} = bus_operator_operations:expire(?NOW + 30001, S2),
    ?assertEqual(<<"expired">>, maps:get(<<"state">>, Exp)),
    {ok, Tomb} = bus_operator_operations:status(?O1, S3),
    ?assertEqual(<<"expired">>, maps:get(<<"state">>, Tomb)),
    Deadline = binary_to_integer(maps:get(<<"deadline">>, Tomb)),
    {S4, []} = bus_operator_operations:expire(Deadline, S3),
    ?assertMatch({ok, _}, bus_operator_operations:status(?O1, S4)),
    {S5, []} = bus_operator_operations:expire(Deadline + 1, S4),
    ?assertEqual({error, not_found}, bus_operator_operations:status(?O1, S5)).

duplicate_create_idempotent_test() ->
    V = view(#{perms => #{<<"notice">> => true}}),
    Doc = create_doc(?O1, <<"notice">>, #{<<"text">> => <<"a">>}),
    {ok, P1, created, S1} = bus_operator_operations:create(Doc, V, digest(), ?NOW,
        bus_operator_operations:new()),
    {ok, P2, duplicate, S2} = bus_operator_operations:create(Doc, V, digest(), ?NOW, S1),
    ?assertEqual(P1, P2),
    ?assertEqual(bus_operator_operations:size(S1), bus_operator_operations:size(S2)),
    Other = create_doc(?O1, <<"notice">>, #{<<"text">> => <<"b">>}),
    ?assertEqual({error, conflict},
        bus_operator_operations:create(Other, V, digest(), ?NOW, S1)).

owner_cancel_and_list_page_null_test() ->
    V = view(#{perms => #{<<"notice">> => true}}),
    {ok, _, created, S1} = bus_operator_operations:create(
        create_doc(?O1, <<"notice">>, #{<<"text">> => <<"a">>}), V, digest(), ?NOW,
        bus_operator_operations:new()),
    {ok, Page} = bus_operator_operations:list(?A, digest(), S1),
    [Item] = maps:get(<<"operations">>, Page),
    ?assertEqual(null, maps:get(<<"page">>, Item)),
    {ok, Listed} = bus_operator_operations:list(?A, digest2(), S1),
    ?assertEqual(1, length(maps:get(<<"operations">>, Listed))),
    ?assertEqual({error, forbidden},
        bus_operator_operations:status(?O1, digest2(), S1)),
    ?assertEqual({error, forbidden},
        bus_operator_operations:cancel(?O1, digest2(), ?NOW, S1)),
    {ok, Own} = bus_operator_operations:status(?O1, digest(), S1),
    ?assertEqual(<<"queued">>, maps:get(<<"state">>, Own)),
    {ok, C, true, _} = bus_operator_operations:cancel(?O1, digest(), ?NOW, S1),
    ?assertEqual(<<"cancelled">>, maps:get(<<"state">>, C)).

uuid_n(N) ->
    iolist_to_binary(io_lib:format("00000000-0000-4000-8000-~12.16.0b", [N])).
