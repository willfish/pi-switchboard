-module(bus_operator_events_tests).
-include_lib("eunit/include/eunit.hrl").

-define(FROM, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(TO, <<"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb">>).
-define(MSG, <<"cccccccc-cccc-4ccc-8ccc-cccccccccccc">>).
-define(WORK, <<"dddddddd-dddd-4ddd-8ddd-dddddddddddd">>).

new_journal_test() ->
    J = bus_operator_events:new(),
    ?assertEqual(true, bus_protocol:is_uuid(bus_operator_events:epoch(J))),
    ?assertEqual(0, bus_operator_events:sequence(J)),
    ?assertEqual(0, bus_operator_events:dropped_seen(J)),
    ?assertEqual(0, bus_operator_events:retained_from(J)),
    ?assertEqual(false, maps:is_key(mail, J)),
    ?assertEqual(100000, bus_operator_events:max_events()),
    ?assertEqual(134217728, bus_operator_events:max_bytes()),
    ?assertEqual(86400, bus_operator_events:max_age_s()),
    ?assertEqual(18446744073709551615, bus_operator_events:max_sequence()),
    ?assertEqual(128, bus_operator_events:page_limit()),
    ?assertEqual(1048576, bus_operator_events:page_bytes()),
    ?assertEqual(524288, bus_operator_events:stream_bytes()),
    ?assertEqual(128, bus_operator_events:cursor_limit()).

record_assigns_decimal_sequence_test() ->
    {ok, J1} = bus_operator_events:record(meta(), 0, 10, bus_operator_events:new()),
    ?assertEqual(1, bus_operator_events:sequence(J1)),
    {ok, Page} = element(1, bus_operator_events:page(first, 0, deadline(), J1)),
    Doc = json:decode(Page),
    [Ev] = maps:get(<<"events">>, Doc),
    ?assertEqual(<<"1">>, maps:get(<<"sequence">>, Ev)),
    ?assertEqual(true, is_binary(maps:get(<<"sequence">>, Ev))),
    ?assertEqual(1, maps:get(<<"schemaVersion">>, Ev)),
    ?assertEqual(<<"mail_accepted">>, maps:get(<<"kind">>, Ev)),
    ?assertEqual(<<"10">>, maps:get(<<"observedAt">>, Ev)),
    ?assertEqual(false, maps:is_key(<<"body">>, maps:get(<<"payload">>, Ev))),
    ?assertEqual(bus_operator_events:epoch(J1), maps:get(<<"epoch">>, Doc)),
    ?assertEqual(<<"live">>, maps:get(<<"coverage">>, Doc)),
    ?assertEqual(<<"1">>, maps:get(<<"retainedFrom">>, Doc)).

owner_observed_at_and_source_time_test() ->
    Event = maps:put(<<"occurredAt">>, 7, meta()),
    {ok, J} = bus_operator_events:record(Event, 0, 99, bus_operator_events:new()),
    {ok, Page} = element(1, bus_operator_events:page(first, 0, deadline(), J)),
    [Ev] = maps:get(<<"events">>, json:decode(Page)),
    ?assertEqual(<<"99">>, maps:get(<<"observedAt">>, Ev)),
    ?assertEqual(<<"7">>, maps:get(<<"occurredAt">>, Ev)),
    ?assertEqual(true, is_binary(maps:get(<<"observedAt">>, Ev))),
    ?assertEqual(true, is_binary(maps:get(<<"occurredAt">>, Ev))).

journal_owns_event_identity_test() ->
    {ok, J1} = bus_operator_events:record(meta(), 0, 1, bus_operator_events:new()),
    {ok, J2} = bus_operator_events:record(meta(), 0, 1, J1),
    {ok, Page} = element(1, bus_operator_events:page(first, 0, deadline(), J2)),
    [A, B] = maps:get(<<"events">>, json:decode(Page)),
    ?assertEqual(true, bus_protocol:is_uuid(maps:get(<<"eventId">>, A))),
    ?assertEqual(true, bus_protocol:is_uuid(maps:get(<<"eventId">>, B))),
    ?assert(maps:get(<<"eventId">>, A) =/= maps:get(<<"eventId">>, B)),
    ?assertEqual(?MSG, maps:get(<<"id">>, maps:get(<<"payload">>, A))).

caller_owned_ids_rejected_test() ->
    J = bus_operator_events:new(),
    lists:foreach(fun(Key) ->
        Bad = maps:put(Key, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>, meta()),
        ?assertEqual({error, invalid_event, J},
            bus_operator_events:record(Bad, 0, 1, J))
    end, [<<"epoch">>, <<"eventId">>]),
    ?assertEqual({error, invalid_event, J},
        bus_operator_events:record(maps:put(<<"sequence">>, <<"1">>, meta()), 0, 1, J)),
    ?assertEqual({error, invalid_event, J},
        bus_operator_events:record(maps:put(<<"observedAt">>, 1, meta()), 0, 1, J)),
    ?assertEqual({error, invalid_event, J},
        bus_operator_events:record(maps:put(<<"schemaVersion">>, 1, meta()), 0, 1, J)).

exact_payload_and_pairing_test() ->
    J = bus_operator_events:new(),
    Nested = meta_payload(#{<<"thinking">> => #{<<"password">> => <<"x">>}}),
    ?assertEqual({error, invalid_event, J},
        bus_operator_events:record(meta(#{<<"payload">> => Nested}), 0, 1, J)),
    Secret = meta_payload(#{<<"raw_output">> => <<"x">>}),
    ?assertEqual({error, invalid_event, J},
        bus_operator_events:record(meta(#{<<"payload">> => Secret}), 0, 1, J)),
    Pair = meta(#{<<"source">> => <<"client_reported">>}),
    ?assertEqual({error, invalid_event, J},
        bus_operator_events:record(Pair, 0, 1, J)),
    Work = #{<<"kind">> => <<"work_reported">>,
             <<"source">> => <<"client_reported">>,
             <<"workId">> => ?WORK,
             <<"payload">> => #{<<"objective">> => <<"ship it">>,
                                <<"phase">> => <<"implementing">>}},
    ?assertMatch({ok, _}, bus_operator_events:record(Work, 0, 1, J)),
    ?assertEqual({error, invalid_event, J},
        bus_operator_events:record(maps:remove(<<"workId">>, Work), 0, 1, J)).

bodies_rejected_until_enrolled_test() ->
    WithBody = meta(#{<<"payload">> => meta_payload(#{<<"body">> => <<"secret">>})}),
    J = bus_operator_events:new(),
    ?assertEqual({error, invalid_event, J},
        bus_operator_events:record(WithBody, 0, 10, J)),
    {ok, J1} = bus_operator_events:record(WithBody, 0, 10, J, #{enroll_bodies => true}),
    {ok, Page} = element(1, bus_operator_events:page(first, 0, deadline(), J1)),
    [Ev] = maps:get(<<"events">>, json:decode(Page)),
    ?assertEqual(<<"secret">>, maps:get(<<"body">>, maps:get(<<"payload">>, Ev))).

invalid_event_does_not_throw_test() ->
    J = bus_operator_events:new(),
    ?assertEqual({error, invalid_event, J},
        bus_operator_events:record(#{<<"kind">> => self()}, 0, 10, J)),
    ?assertEqual({error, invalid_event, J},
        bus_operator_events:record(#{}, 0, 10, J)),
    ?assertEqual({error, invalid_event, J},
        bus_operator_events:record(meta(#{<<"kind">> => <<"heartbeat">>}), 0, 10, J)).

sequence_exhausted_is_explicit_test() ->
    J = bus_operator_events:set_sequence(bus_operator_events:new(),
        bus_operator_events:max_sequence()),
    ?assertEqual({error, sequence_exhausted, J},
        bus_operator_events:record(meta(), 0, 1, J)),
    ?assertEqual(bus_operator_events:max_sequence(),
        bus_operator_events:sequence(J)).

page_bounds_and_cursor_test() ->
    J0 = lists:foldl(fun(N, Acc) ->
        {ok, Next} = bus_operator_events:record(
            maps:put(<<"occurredAt">>, N, meta()), N, N, Acc),
        Next
    end, bus_operator_events:new(), lists:seq(1, 129)),
    {Reply1, J1} = bus_operator_events:page(first, 129, deadline(), J0),
    {ok, B1} = Reply1,
    P1 = json:decode(B1),
    ?assertEqual(128, length(maps:get(<<"events">>, P1))),
    ?assert(byte_size(B1) =< 1048576),
    C = maps:get(<<"nextCursor">>, P1),
    ?assertEqual(true, is_binary(C)),
    ?assert(byte_size(C) =< 128),
    {ok, B2} = element(1, bus_operator_events:page(C, 129, deadline(), J1)),
    P2 = json:decode(B2),
    ?assertEqual(1, length(maps:get(<<"events">>, P2))),
    ?assertEqual(null, maps:get(<<"nextCursor">>, P2)),
    ?assertEqual(true, maps:get(<<"caughtUp">>, P2)).

cursor_cap_and_canonical_form_test() ->
    {ok, J} = bus_operator_events:record(meta(), 0, 10, bus_operator_events:new()),
    C = cursor_for(bus_operator_events:epoch(J), 1),
    MaxRaw = <<(bus_operator_events:epoch(J))/binary, $:,
               <<"18446744073709551615">>/binary>>,
    MaxCursor = base64:encode(MaxRaw, #{mode => urlsafe, padding => false}),
    ?assert(byte_size(MaxCursor) =< 76),
    ?assert(byte_size(MaxCursor) =< 128),
    {ok, Caught} = element(1, bus_operator_events:page(C, 0, deadline(), J)),
    ?assertEqual([], maps:get(<<"events">>, json:decode(Caught))),
    ?assertMatch({{error, invalid_cursor}, _},
        bus_operator_events:page(binary:copy(<<"x">>, 129), 0, deadline(), J)),
    ?assertMatch({{error, invalid_cursor}, _},
        bus_operator_events:page(<<C/binary, "=">>, 0, deadline(), J)),
    ?assertMatch({{error, invalid_cursor}, _},
        bus_operator_events:page(<<"g2gCZAAEZXZpbA">>, 0, deadline(), J)),
    ?assertMatch({{error, invalid_cursor}, _},
        bus_operator_events:page(MaxCursor, 0, deadline(), J)).

epoch_reset_and_restart_test() ->
    {ok, J} = bus_operator_events:record(meta(), 0, 10, bus_operator_events:new()),
    C = cursor_for(bus_operator_events:epoch(J), 1),
    Other = bus_operator_events:new(),
    ?assertMatch({{error, epoch_reset}, _},
        bus_operator_events:page(C, 0, deadline(), Other)),
    ?assert(bus_operator_events:epoch(J) =/= bus_operator_events:epoch(Other)),
    ?assertEqual(0, bus_operator_events:sequence(Other)).

history_gap_after_trim_test() ->
    J1 = lists:foldl(fun(_, Acc) ->
        {ok, Next} = bus_operator_events:record(meta(), 0, 10, Acc),
        Next
    end, bus_operator_events:new(), lists:seq(1, 2)),
    {ok, FirstPage} = element(1, bus_operator_events:page(first, 0, deadline(), J1)),
    C0 = cursor_after(FirstPage, 0),
    Aged = bus_operator_events:expire(86400, J1),
    ?assertEqual(0, sequence_count(Aged)),
    ?assertMatch({{error, history_lost}, _},
        bus_operator_events:page(C0, 86400, deadline(), Aged)).

first_page_after_trim_bootstraps_test() ->
    {ok, J1} = bus_operator_events:record(meta(), 0, 1, bus_operator_events:new()),
    {ok, J2} = bus_operator_events:record(meta(), 10, 2, J1),
    Truncated = bus_operator_events:expire(86400, J2),
    {ok, Page} = element(1, bus_operator_events:page(first, 86400, deadline(), Truncated)),
    Doc = json:decode(Page),
    ?assertEqual(1, length(maps:get(<<"events">>, Doc))),
    ?assertEqual(<<"truncated">>, maps:get(<<"coverage">>, Doc)),
    ?assertEqual(<<"2">>, maps:get(<<"retainedFrom">>, Doc)),
    Empty = bus_operator_events:expire(86410, J2),
    {ok, EmptyPage} = element(1, bus_operator_events:page(first, 86410, deadline(), Empty)),
    EmptyDoc = json:decode(EmptyPage),
    ?assertEqual([], maps:get(<<"events">>, EmptyDoc)),
    ?assertEqual(<<"empty">>, maps:get(<<"coverage">>, EmptyDoc)),
    ?assertEqual(true, maps:get(<<"caughtUp">>, EmptyDoc)),
    ?assertEqual(integer_to_binary(bus_operator_events:sequence(Empty)),
        maps:get(<<"retainedFrom">>, EmptyDoc)),
    O = bus_operator_events:observer(),
    {frame, PullBin, false, _, _} = bus_operator_events:pull(O, 86410, deadline(), Empty),
    PullDoc = json:decode(PullBin),
    ?assertEqual([], maps:get(<<"events">>, PullDoc)),
    ?assertEqual(<<"empty">>, maps:get(<<"coverage">>, PullDoc)).

age_byte_and_count_trim_test_() ->
    [{timeout, 180, fun count_trim/0},
     {timeout, 60, fun byte_trim/0},
     fun age_trim/0].

count_trim() ->
    Max = bus_operator_events:max_events(),
    J = lists:foldl(fun(_, Acc) ->
        {ok, Next} = bus_operator_events:record(meta(), 0, 1, Acc),
        Next
    end, bus_operator_events:new(), lists:seq(1, Max + 1)),
    ?assertEqual(Max, sequence_count(J)),
    ?assertEqual(Max + 1, bus_operator_events:sequence(J)),
    {ok, Page} = element(1, bus_operator_events:page(first, 0, deadline(), J)),
    Doc = json:decode(Page),
    ?assertEqual(<<"truncated">>, maps:get(<<"coverage">>, Doc)),
    ?assertEqual(<<"2">>, maps:get(<<"retainedFrom">>, Doc)),
    ?assert(length(maps:get(<<"events">>, Doc)) > 0),
    assert_index(J).

byte_trim() ->
    Event = enrolled_body(binary:copy(<<"x">>, 16384)),
    J = fill_until_byte_cap(Event, bus_operator_events:new(), 0),
    ?assert(bus_operator_events:journal_bytes(J) =< bus_operator_events:max_bytes()),
    ?assert(sequence_count(J) < 100000),
    assert_index(J).

age_trim() ->
    {ok, J1} = bus_operator_events:record(meta(), 0, 1, bus_operator_events:new()),
    {ok, J2} = bus_operator_events:record(meta(), 10, 2, J1),
    Kept = bus_operator_events:expire(86399, J2),
    ?assertEqual(2, sequence_count(Kept)),
    Gone = bus_operator_events:expire(86400, J2),
    ?assertEqual(1, sequence_count(Gone)),
    Empty = bus_operator_events:expire(86410, J2),
    ?assertEqual(0, sequence_count(Empty)).

apply_drops_monotonic_and_wrap_test() ->
    J = bus_operator_events:new(),
    {ok, J1} = bus_operator_events:apply_drops(0, 0, 1, J),
    ?assertEqual(0, bus_operator_events:dropped_seen(J1)),
    {ok, J2} = bus_operator_events:apply_drops(3, 0, 1, J1),
    ?assertEqual(3, bus_operator_events:dropped_seen(J2)),
    {ok, Page} = element(1, bus_operator_events:page(first, 0, deadline(), J2)),
    [Ev] = maps:get(<<"events">>, json:decode(Page)),
    ?assertEqual(<<"observation_lost">>, maps:get(<<"kind">>, Ev)),
    ?assertEqual(<<"3">>, maps:get(<<"count">>, maps:get(<<"payload">>, Ev))),
    ?assertEqual(<<"1">>, maps:get(<<"observedAt">>, Ev)),
    {ok, J3} = bus_operator_events:apply_drops(3, 0, 1, J2),
    ?assertEqual(3, bus_operator_events:dropped_seen(J3)),
    ?assertEqual(1, bus_operator_events:sequence(J3)),
    ?assertMatch({error, coverage_wrap, _},
        bus_operator_events:apply_drops(2, 0, 1, J3)).

single_flight_wake_rearm_test() ->
    {ok, J} = bus_operator_events:record(meta(), 0, 1, bus_operator_events:new()),
    O0 = bus_operator_events:observer(),
    {wake, O1} = bus_operator_events:signal(O0),
    {quiet, O1} = bus_operator_events:signal(O1),
    {frame, EmptyBin, false, O2, _} = bus_operator_events:pull(O1, 0, deadline(),
        bus_operator_events:new()),
    EmptyDoc = json:decode(EmptyBin),
    ?assertEqual([], maps:get(<<"events">>, EmptyDoc)),
    ?assertEqual(<<"empty">>, maps:get(<<"coverage">>, EmptyDoc)),
    ?assertEqual(false, maps:get(wake, O2)),
    {frame, Bin, false, O3, J} = bus_operator_events:pull(O0, 0, deadline(), J),
    ?assertEqual(false, maps:get(wake, O3)),
    ?assertEqual(1, length(maps:get(<<"events">>, json:decode(Bin)))),
    O4 = bus_operator_events:rearm(O1),
    {wake, _} = bus_operator_events:signal(O4).

pull_gap_and_timeout_test() ->
    {ok, J} = bus_operator_events:record(meta(), 0, 1, bus_operator_events:new()),
    O = bus_operator_events:observer(),
    {error, timeout, O, J} = bus_operator_events:pull(O, 0,
        erlang:monotonic_time(millisecond) - 1, J),
    C0 = cursor_for(bus_operator_events:epoch(J), 0),
    Aged = bus_operator_events:expire(86400, J),
    ?assertMatch({{error, history_lost}, _},
        bus_operator_events:page(C0, 86400, deadline(), Aged)).

pull_stream_frame_bound_test() ->
    Event = enrolled_body(binary:copy(<<"x">>, 16384)),
    J = lists:foldl(fun(_, Acc) ->
        {ok, Next} = bus_operator_events:record(Event, 0, 1, Acc, #{enroll_bodies => true}),
        Next
    end, bus_operator_events:new(), lists:seq(1, 128)),
    {ok, Page} = element(1, bus_operator_events:page(first, 0, deadline(), J)),
    {frame, Stream, More, _, _} = bus_operator_events:pull(
        bus_operator_events:observer(), 0, deadline(), J),
    ?assert(byte_size(Page) =< 1048576),
    ?assert(byte_size(Stream) =< 524288),
    ?assert(byte_size(Stream) =< byte_size(Page)),
    ?assertEqual(true, More orelse byte_size(Page) =< 524288).

expired_deadline_does_not_trim_test() ->
    {ok, J} = bus_operator_events:record(meta(), 0, 1, bus_operator_events:new()),
    1 = erlang:trace_pattern({bus_operator_events, trim, 2}, true, [call_count]),
    try
        Past = erlang:monotonic_time(millisecond) - 1,
        {error, timeout, _, J} = bus_operator_events:pull(
            bus_operator_events:observer(), 86400, Past, J),
        {{error, timeout}, J} = bus_operator_events:page(first, 86400, Past, J),
        {call_count, N} = erlang:trace_info({bus_operator_events, trim, 2}, call_count),
        ?assertEqual(0, N)
    after
        erlang:trace_pattern({bus_operator_events, trim, 2}, false, [call_count])
    end.

utf8_and_decimal_bounds_test() ->
    J = bus_operator_events:new(),
    BadBody = enrolled_body(<<255, 254, 253>>),
    ?assertEqual({error, invalid_event, J},
        bus_operator_events:record(BadBody, 0, 1, J, #{enroll_bodies => true})),
    Work = #{<<"kind">> => <<"work_reported">>,
             <<"source">> => <<"client_reported">>,
             <<"workId">> => ?WORK,
             <<"payload">> => #{<<"objective">> => <<255>>,
                                <<"phase">> => <<"planning">>}},
    ?assertEqual({error, invalid_event, J},
        bus_operator_events:record(Work, 0, 1, J)),
    Block = #{<<"kind">> => <<"blocker_reported">>,
              <<"source">> => <<"client_reported">>,
              <<"workId">> => ?WORK,
              <<"payload">> => #{<<"reason">> => <<16#C3>>}},
    ?assertEqual({error, invalid_event, J},
        bus_operator_events:record(Block, 0, 1, J)),
    Long = binary:copy(<<"1">>, 21),
    ?assertEqual({error, invalid_event, J},
        bus_operator_events:record(maps:put(<<"occurredAt">>, Long, meta()), 0, 1, J)),
    Lost = #{<<"kind">> => <<"observation_lost">>,
             <<"source">> => <<"relay_observed">>,
             <<"payload">> => #{<<"count">> => Long}},
    ?assertEqual({error, invalid_event, J},
        bus_operator_events:record(Lost, 0, 1, J)).

pack_encodes_final_frame_once_test() ->
    Event = enrolled_body(binary:copy(<<"x">>, 16384)),
    J = lists:foldl(fun(_, Acc) ->
        {ok, Next} = bus_operator_events:record(Event, 0, 1, Acc, #{enroll_bodies => true}),
        Next
    end, bus_operator_events:new(), lists:seq(1, 40)),
    1 = erlang:trace_pattern({json, encode, 1}, true, [call_count]),
    try
        {ok, B} = element(1, bus_operator_events:page(first, 0, deadline(), J)),
        {call_count, N} = erlang:trace_info({json, encode, 1}, call_count),
        ?assert(byte_size(B) =< 1048576),
        ?assert(N =< 2)
    after
        erlang:trace_pattern({json, encode, 1}, false, [call_count])
    end.

page_byte_packing_test() ->
    Event = enrolled_body(binary:copy(<<"x">>, 16384)),
    J = lists:foldl(fun(_, Acc) ->
        {ok, Next} = bus_operator_events:record(Event, 0, 1, Acc, #{enroll_bodies => true}),
        Next
    end, bus_operator_events:new(), lists:seq(1, 128)),
    {ok, B} = element(1, bus_operator_events:page(first, 0, deadline(), J)),
    ?assert(byte_size(B) =< 1048576),
    ?assert(length(maps:get(<<"events">>, json:decode(B))) < 128).

search_runtime_participant_not_session_test() ->
    Mail = meta(#{<<"agentId">> => ?TO, <<"sessionId">> => ?FROM}),
    {ok, J} = bus_operator_events:record(Mail, 0, 1, bus_operator_events:new()),
    {ok, Hit} = element(1, bus_operator_events:search(#{participant => ?TO}, first,
        0, deadline(), J)),
    ?assertEqual(1, length(maps:get(<<"events">>, json:decode(Hit)))),
    {ok, Miss} = element(1, bus_operator_events:search(#{participant => ?FROM},
        first, 0, deadline(), J)),
    %% FROM is mail from, so it should hit as participant runtime/from/to.
    ?assertEqual(1, length(maps:get(<<"events">>, json:decode(Miss)))),
    Other = <<"ffffffff-ffff-4fff-8fff-ffffffffffff">>,
    SessionOnly = meta(#{<<"agentId">> => ?TO, <<"sessionId">> => Other,
                         <<"payload">> => meta_payload(#{<<"from">> => ?TO, <<"to">> => ?TO})}),
    {ok, J2} = bus_operator_events:record(SessionOnly, 0, 2, bus_operator_events:new()),
    {ok, No} = element(1, bus_operator_events:search(#{participant => Other}, first,
        0, deadline(), J2)),
    ?assertEqual(0, length(maps:get(<<"events">>, json:decode(No)))).

search_operation_outcome_and_frozen_high_water_test() ->
    Op = #{<<"kind">> => <<"operator_requested">>,
           <<"source">> => <<"operator_requested">>,
           <<"operationId">> => ?WORK,
           <<"payload">> => #{<<"action">> => <<"notice">>, <<"state">> => <<"queued">>}},
    {ok, J1} = bus_operator_events:record(Op, 0, 1, bus_operator_events:new()),
    {ok, Page} = element(1, bus_operator_events:search(#{outcome => <<"queued">>},
        first, 0, deadline(), J1)),
    Doc = json:decode(Page),
    ?assertEqual(1, length(maps:get(<<"events">>, Doc))),
    ?assertEqual(<<"1">>, maps:get(<<"throughSequence">>, Doc)),
    {ok, J2} = bus_operator_events:record(Op, 0, 2, J1),
    {ok, Later} = element(1, bus_operator_events:search(#{outcome => <<"queued">>},
        first, 0, deadline(), J2)),
    ?assertEqual(2, length(maps:get(<<"events">>, json:decode(Later)))).

tool_reported_no_raw_output_test() ->
    J = bus_operator_events:new(),
    Bad = #{<<"kind">> => <<"tool_reported">>,
            <<"source">> => <<"client_reported">>,
            <<"payload">> => #{<<"toolCallId">> => <<"c">>, <<"toolName">> => <<"t">>,
                               <<"state">> => <<"ended">>, <<"args">> => #{}}},
    ?assertEqual({error, invalid_event, J}, bus_operator_events:record(Bad, 0, 1, J)),
    Good = #{<<"kind">> => <<"tool_reported">>,
             <<"source">> => <<"client_reported">>,
             <<"payload">> => #{<<"toolCallId">> => <<"c">>, <<"toolName">> => <<"t">>,
                                <<"state">> => <<"ended">>}},
    ?assertMatch({ok, _}, bus_operator_events:record(Good, 0, 1, J)).

ingest_keeps_authorized_body_test() ->
    {ok, Canonical} = bus_operator_events:candidate(enrolled_body(<<"preview">>),
        #{enroll_bodies => true}),
    {ok, J} = bus_operator_events:ingest(Canonical, 0, 1, bus_operator_events:new()),
    {ok, Page} = element(1, bus_operator_events:page(first, 0, deadline(), J)),
    [Ev] = maps:get(<<"events">>, json:decode(Page)),
    ?assertEqual(<<"preview">>, maps:get(<<"body">>, maps:get(<<"payload">>, Ev))).

deadline() -> erlang:monotonic_time(millisecond) + 5000.

meta() -> meta(#{}).
meta(Overrides) ->
    maps:merge(#{<<"kind">> => <<"mail_accepted">>,
        <<"source">> => <<"relay_observed">>,
        <<"payload">> => meta_payload()}, Overrides).

meta_payload() -> meta_payload(#{}).
meta_payload(Overrides) ->
    maps:merge(#{<<"id">> => ?MSG,
        <<"from">> => ?FROM,
        <<"to">> => ?TO,
        <<"kind">> => <<"notice">>,
        <<"acceptedAt">> => 1,
        <<"receiving">> => false,
        <<"bodyBytes">> => 0}, Overrides).

enrolled_body(Body) ->
    meta(#{<<"payload">> => meta_payload(#{<<"body">> => Body, <<"bodyBytes">> => byte_size(Body)})}).

sequence_count(J) -> bus_operator_events:journal_count(J).

cursor_for(Epoch, Seq) ->
    Raw = <<Epoch/binary, $:, (integer_to_binary(Seq))/binary>>,
    base64:encode(Raw, #{mode => urlsafe, padding => false}).

cursor_after(Page, Index) ->
    Ev = lists:nth(Index + 1, maps:get(<<"events">>, json:decode(Page))),
    Epoch = maps:get(<<"epoch">>, Ev),
    Seq = binary_to_integer(maps:get(<<"sequence">>, Ev)),
    cursor_for(Epoch, Seq).

fill_until_byte_cap(_Event, J, N) when N > 20000 -> J;
fill_until_byte_cap(Event, J, N) ->
    case bus_operator_events:record(Event, 0, 1, J, #{enroll_bodies => true}) of
        {ok, Next} ->
            case bus_operator_events:journal_bytes(Next) >=
                    bus_operator_events:max_bytes() * 99 div 100 of
                true -> Next;
                false -> fill_until_byte_cap(Event, Next, N + 1)
            end;
        {error, invalid_event, _} -> J
    end.

assert_index(J) ->
    Count = bus_operator_events:journal_count(J),
    Bytes = bus_operator_events:journal_bytes(J),
    ?assert(Count =< bus_operator_events:max_events()),
    ?assert(Bytes =< bus_operator_events:max_bytes()),
    ?assert(Count >= 0).
