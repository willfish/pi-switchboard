-module(bus_model_tests).
-include_lib("eunit/include/eunit.hrl").

-define(A, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(B, <<"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb">>).
-define(S1, <<"11111111-1111-4111-8111-111111111111">>).
-define(S2, <<"22222222-2222-4222-8222-222222222222">>).
-define(MID, <<"33333333-3333-4333-8333-333333333333">>).

upsert_and_list_test() ->
    S0 = bus_model:new(),
    {ok, S1} = bus_model:put_agent(S0, agent(?A, ?S1, false), 100, 1_700_000_000),
    Listed = bus_model:list_agents(S1, 100, 1_700_000_000),
    ?assertEqual(1, length(Listed)),
    [Doc] = Listed,
    ?assertEqual(?A, maps:get(<<"agentId">>, Doc)),
    ?assertEqual(1_700_000_000, maps:get(<<"updatedAt">>, Doc)),
    ?assertEqual(false, maps:get(<<"receiving">>, Doc)).

session_ids_are_not_routing_keys_test() ->
    S0 = bus_model:new(),
    {ok, S1} = bus_model:put_agent(S0, agent(?A, ?S1, false), 100, 50),
    {ok, S2} = bus_model:put_agent(S1, agent(?B, ?S1, false), 100, 50),
    ?assertEqual(2, length(bus_model:list_agents(S2, 100, 0))).

ttl_boundary_test() ->
    S0 = bus_model:new(),
    {ok, S1} = bus_model:put_agent(S0, agent(?A, ?S1, false), 100, 50),
    ?assertEqual(1, length(bus_model:list_agents(S1, 114, 0))),
    ?assertEqual(0, length(bus_model:list_agents(S1, 115, 0))).

expire_without_listing_test() ->
    S0 = bus_model:new(),
    {ok, S1} = bus_model:put_agent(S0, agent(?A, ?S1, false), 100, 50),
    S2 = bus_model:expire(S1, 115),
    %% listing at the original time would still have shown it before expire/2
    ?assertEqual(#{}, maps:get(agents, S2)).

independent_clocks_test() ->
    S0 = bus_model:new(),
    {ok, S1} = bus_model:put_agent(S0, agent(?A, ?S1, false), 5, 42),
    [Doc] = bus_model:list_agents(S1, 5, 99),
    ?assertEqual(42, maps:get(<<"updatedAt">>, Doc)),
    {ok, S2} = bus_model:put_agent(S1, agent(?A, ?S1, false), 10, 37),
    [Updated] = bus_model:list_agents(S2, 24, 1000),
    ?assertEqual(37, maps:get(<<"updatedAt">>, Updated)),
    ?assertEqual([], bus_model:list_agents(S2, 25, 0)).

delete_drops_mail_test() ->
    S = two_agents(100),
    {ok, S1, _} = bus_model:accept_mail(S, notice(?A, ?B), 100, 50),
    S2 = bus_model:delete_agent(S1, ?B),
    ?assertEqual({empty, S2}, bus_model:pop_mail(S2, ?B, 100)).

self_send_test() ->
    S = two_agents(100),
    ?assertEqual({error, self_send}, bus_model:accept_mail(S, notice(?A, ?A), 100, 50)).

missing_peer_test() ->
    S0 = bus_model:new(),
    {ok, S1} = bus_model:put_agent(S0, agent(?A, ?S1, false), 100, 50),
    ?assertEqual({error, not_found}, bus_model:accept_mail(S1, notice(?A, ?B), 100, 50)).

control_rejected_test() ->
    S = two_agents(100),
    Msg = (notice(?A, ?B))#{<<"kind">> => <<"prompt">>},
    ?assertEqual({error, control_disabled}, bus_model:accept_mail(S, Msg, 100, 50)).

control_allowed_test() ->
    S0 = bus_model:new(),
    {ok, S1} = bus_model:put_agent(S0, agent(?A, ?S1, false), 100, 50),
    {ok, S2} = bus_model:put_agent(S1, agent(?B, ?S2, true), 100, 50),
    Msg = (notice(?A, ?B))#{<<"kind">> => <<"steer">>},
    ?assertMatch({ok, _, _}, bus_model:accept_mail(S2, Msg, 100, 50)).

live_capacity_test() ->
    S = lists:foldl(fun(N,Acc) ->
        {ok,Next} = bus_model:put_agent(Acc,agent(integer_to_binary(N),?S1,false),100,50), Next
    end,bus_model:new(),lists:seq(1,5000)),
    ?assertEqual(5000,length(bus_model:list_agents(S,100,50))),
    ?assertEqual({error,capacity},bus_model:put_agent(S,agent(<<"5001">>,?S1,false),100,50)),
    ?assertMatch({ok,_},bus_model:put_agent(S,agent(<<"1">>,?S1,false),114,64)),
    ?assertMatch({ok,_},bus_model:put_agent(S,agent(<<"5001">>,?S1,false),115,65)),
    ?assert(bus_model:has_agent(S,<<"1">>,114)),
    ?assertNot(bus_model:has_agent(S,<<"1">>,115)).

fifo_and_capacity_test() ->
    S = two_agents(100),
    S1 = lists:foldl(
        fun(N, Acc) ->
            Msg = (notice(?A, ?B))#{
                <<"id">> => uuid_n(N),
                <<"body">> => integer_to_binary(N)
            },
            {ok, Next, _} = bus_model:accept_mail(Acc, Msg, 100, 50),
            Next
        end,
        S,
        lists:seq(1, 32)
    ),
    Extra = (notice(?A, ?B))#{<<"id">> => uuid_n(33), <<"body">> => <<"x">>},
    ?assertEqual({error, mailbox_full}, bus_model:accept_mail(S1, Extra, 100, 50)),
    {ok, S2, First} = bus_model:pop_mail(S1, ?B, 100),
    ?assertEqual(<<"1">>, maps:get(<<"body">>, First)),
    {ok, _, Second} = bus_model:pop_mail(S2, ?B, 100),
    ?assertEqual(<<"2">>, maps:get(<<"body">>, Second)).

dedup_repeat_test() ->
    S = two_agents(100),
    Msg = notice(?A, ?B),
    {ok, S1, R1} = bus_model:accept_mail(S, Msg, 100, 50),
    {ok, S2, R2} = bus_model:accept_mail(S1, Msg, 101, 51),
    ?assertEqual(R1, R2),
    {ok, S3, _} = bus_model:pop_mail(S2, ?B, 101),
    ?assertEqual({empty, S3}, bus_model:pop_mail(S3, ?B, 101)).

dedup_conflict_test() ->
    S = two_agents(100),
    Msg = notice(?A, ?B),
    {ok, S1, _} = bus_model:accept_mail(S, Msg, 100, 50),
    Changed = Msg#{<<"body">> => <<"other">>},
    ?assertEqual({error, conflict}, bus_model:accept_mail(S1, Changed, 101, 51)).

expired_recipient_cannot_pop_test() ->
    S = bus_model:set_receiving(two_agents(100), ?B, true),
    Msg = notice(?A, ?B),
    {ok, S1, Result} = bus_model:accept_mail(S, Msg, 100, 50),
    ?assertMatch({ok, _, _}, bus_model:pop_mail(S1, ?B, 114)),
    {empty, S2} = bus_model:pop_mail(S1, ?B, 115),
    ?assertNot(maps:is_key(?B, maps:get(mail, S2))),
    ?assertNot(maps:is_key(?B, maps:get(receiving, S2))),
    ?assertEqual(maps:get(dedup, S1), maps:get(dedup, S2)),
    ?assertEqual({ok, S2, Result}, bus_model:accept_mail(S2, Msg, 115, 65)).

put_after_expiry_drops_mail_test() ->
    S = two_agents(100),
    Msg = notice(?A, ?B),
    {ok, S1, Result} = bus_model:accept_mail(S, Msg, 100, 50),
    {ok, S2} = bus_model:put_agent(S1, agent(?B, ?S2, false), 115, 65),
    ?assert(bus_model:has_agent(S2, ?B, 115)),
    ?assertEqual({empty, S2}, bus_model:pop_mail(S2, ?B, 115)),
    ?assertEqual(maps:get(dedup, S1), maps:get(dedup, S2)),
    ?assertEqual({ok, S2, Result}, bus_model:accept_mail(S2, Msg, 115, 65)),
    ?assertEqual({error, conflict},
        bus_model:accept_mail(S2, Msg#{<<"body">> => <<"changed">>}, 115, 65)).

put_after_expiry_drops_receiving_test() ->
    S = bus_model:set_receiving(two_agents(100), ?B, true),
    {ok, Live} = bus_model:put_agent(S, agent(?B, ?S2, false), 114, 64),
    ?assert(maps:is_key(?B, maps:get(receiving, Live))),
    {ok, Expired} = bus_model:put_agent(S, agent(?B, ?S2, false), 115, 65),
    ?assertNot(maps:is_key(?B, maps:get(receiving, Expired))).

mail_expires_test() ->
    S = two_agents(100),
    {ok, S1, _} = bus_model:accept_mail(S, notice(?A, ?B), 100, 50),
    Live = heartbeat_recipient(S1, [110, 120, 130, 140, 150]),
    ?assertMatch({ok, _, _}, bus_model:pop_mail(Live, ?B, 159)),
    {empty, S2} = bus_model:pop_mail(Live, ?B, 160),
    ?assert(bus_model:has_agent(S2, ?B, 160)),
    ?assertEqual(#{}, maps:get(mail, S2)).

periodic_expire_purges_live_recipient_mail_test() ->
    S = two_agents(100),
    Msg = notice(?A, ?B),
    {ok, S1, Result} = bus_model:accept_mail(S, Msg, 100, 50),
    LaterMsg = Msg#{<<"id">> => uuid_n(1)},
    {ok, S2, _} = bus_model:accept_mail(S1, LaterMsg, 101, 51),
    Live = heartbeat_recipient(S2, [110, 120, 130, 140, 150]),
    Before = bus_model:expire(Live, 159),
    ?assertEqual(2, length(maps:get(?B, maps:get(mail, Before)))),
    Boundary = bus_model:expire(Before, 160),
    ?assert(bus_model:has_agent(Boundary, ?B, 160)),
    [Remaining] = maps:get(?B, maps:get(mail, Boundary)),
    ?assertEqual(uuid_n(1), maps:get(<<"id">>, Remaining)),
    ?assertEqual(maps:get(dedup, S2), maps:get(dedup, Boundary)),
    ?assertEqual({ok, Boundary, Result}, bus_model:accept_mail(Boundary, Msg, 160, 110)),
    After = bus_model:expire(Boundary, 161),
    ?assertEqual(#{}, maps:get(mail, After)).

sender_snapshot_survives_expiry_test() ->
    S = two_agents(100),
    {ok, S1, _} = bus_model:accept_mail(S, notice(?A, ?B), 100, 50),
    Live = heartbeat_recipient(S1, [110]),
    S2 = bus_model:expire(Live, 115),
    ?assertNot(bus_model:has_agent(S2, ?A, 115)),
    ?assert(bus_model:has_agent(S2, ?B, 115)),
    {ok, S3, Entry} = bus_model:pop_mail(S2, ?B, 115),
    ?assertEqual(#{<<"host">> => <<"andromeda">>, <<"label">> => <<"lab">>},
        maps:get(<<"sender">>, bus_model:public_mail(Entry))),
    assert_bytes(0, S3).

queue_budget_boundary_and_dedup_test() ->
    Msg = notice(?A, ?B),
    Bytes = wire_bytes(Msg, agent(?A, ?S1, false), 50),
    S = (two_agents(100))#{queue_byte_limit => Bytes},
    ?assertEqual({error, capacity},
        bus_model:accept_mail(S#{queue_byte_limit => Bytes - 1}, Msg, 100, 50)),
    {ok, Full, Result} = bus_model:accept_mail(S, Msg, 100, 50),
    assert_bytes(Bytes, Full),
    ?assertEqual({ok, Full, Result}, bus_model:accept_mail(Full, Msg, 101, 51)),
    ?assertEqual({error, conflict},
        bus_model:accept_mail(Full, Msg#{<<"body">> => <<"changed">>}, 101, 51)),
    Other = notice(?B, ?A),
    ?assertEqual({error, capacity}, bus_model:accept_mail(Full, Other, 100, 50)),
    {ok, Empty, _} = bus_model:pop_mail(Full, ?B, 100),
    assert_bytes(0, Empty),
    ?assertEqual({ok, Empty, Result}, bus_model:accept_mail(Empty, Msg, 101, 51)),
    {ok, Refilled, _} = bus_model:accept_mail(Empty, Other, 100, 50),
    assert_bytes(Bytes, Refilled).

queue_budget_encoded_snapshot_test() ->
    Sender = (agent(?A, ?S1, false))#{<<"label">> => <<"quote\" slash\\ ", 16#1f642/utf8>>},
    Msg = (notice(?A, ?B))#{<<"body">> => <<"\n\t", 16#e9/utf8>>},
    Bytes = wire_bytes(Msg, Sender, 50),
    {ok, S} = bus_model:put_agent(two_agents(-100), Sender, -100, 50),
    ?assertEqual({error, capacity}, bus_model:accept_mail(
        S#{queue_byte_limit => Bytes - 1}, Msg, -100, 50)),
    {ok, Full, _} = bus_model:accept_mail(S#{queue_byte_limit => Bytes}, Msg, -100, 50),
    assert_bytes(Bytes, Full),
    {ok, Updated} = bus_model:put_agent(Full, agent(?A, ?S1, false), -99, 51),
    assert_bytes(Bytes, Updated),
    {ok, Empty, Entry} = bus_model:pop_mail(Updated, ?B, -99),
    ?assertEqual(Bytes, iolist_size(json:encode(bus_model:public_mail(Entry)))),
    assert_bytes(0, Empty).

queue_budget_release_transitions_test() ->
    {ok, S1, _} = bus_model:accept_mail(two_agents(100), notice(?A, ?B), 100, 50),
    {ok, S2, _} = bus_model:accept_mail(S1, notice(?B, ?A), 100, 50),
    Bytes = wire_bytes(notice(?A, ?B), agent(?A, ?S1, false), 50),
    assert_bytes(2 * Bytes, S2),
    Deleted = bus_model:delete_agent(S2, ?B),
    assert_bytes(Bytes, Deleted),
    assert_bytes(Bytes, bus_model:delete_agent(Deleted, ?B)),
    {ok, Registered} = bus_model:put_agent(S2, agent(?B, ?S2, false), 115, 65),
    assert_bytes(Bytes, Registered),
    {empty, PoppedExpired} = bus_model:pop_mail(S2, ?B, 115),
    assert_bytes(Bytes, PoppedExpired),
    assert_bytes(0, bus_model:expire(S2, 115)),
    assert_bytes(0, bus_model:expire(bus_model:expire(S2, 115), 116)),
    assert_bytes(0, bus_model:new()),
    ?assertEqual(5_000_000_000, maps:get(queue_byte_limit, bus_model:new())).

queue_budget_partial_expiry_test() ->
    Msg = notice(?A, ?B),
    Later = Msg#{<<"id">> => uuid_n(1), <<"body">> => <<"longer body">>},
    B1 = wire_bytes(Msg, agent(?A, ?S1, false), 50),
    B2 = wire_bytes(Later, agent(?A, ?S1, false), 51),
    {ok, S1, _} = bus_model:accept_mail(two_agents(100), Msg, 100, 50),
    {ok, S2, _} = bus_model:accept_mail(S1, Later, 101, 51),
    Live = heartbeat_recipient(S2, [110, 120, 130, 140, 150]),
    assert_bytes(B1 + B2, bus_model:expire(Live, 159)),
    Partial = bus_model:expire(Live, 160),
    assert_bytes(B2, Partial),
    assert_bytes(B2, bus_model:expire(Partial, 160)),
    assert_bytes(0, bus_model:expire(Partial, 161)),
    {ok, Popped, Entry} = bus_model:pop_mail(Live, ?B, 160),
    ?assertEqual(uuid_n(1), maps:get(<<"id">>, Entry)),
    assert_bytes(0, Popped),
    {empty, Empty} = bus_model:pop_mail(Live, ?B, 161),
    assert_bytes(0, Empty),
    {ok, Ready} = bus_model:put_agent(Live, agent(?A, ?S1, false), 160, 110),
    New = Msg#{<<"id">> => uuid_n(2)},
    B3 = wire_bytes(New, agent(?A, ?S1, false), 110),
    {ok, Refilled, _} = bus_model:accept_mail(
        Ready#{queue_byte_limit => B2 + B3}, New, 160, 110),
    assert_bytes(B2 + B3, Refilled).

wire_bytes(Msg, Sender, Wall) ->
    iolist_size(json:encode(Msg#{
        <<"acceptedAt">> => Wall,
        <<"expiresAt">> => Wall + 60,
        <<"sender">> => maps:with([<<"host">>, <<"label">>], Sender)
    })).

assert_bytes(Expected, State) ->
    ?assertEqual(Expected, maps:get(queued_bytes, State)),
    ?assertEqual(Expected, lists:sum([
        iolist_size(json:encode(bus_model:public_mail(Entry)))
        || Queue <- maps:values(maps:get(mail, State)), Entry <- Queue
    ])).

heartbeat_recipient(State, Times) ->
    lists:foldl(
        fun(Time, Acc) ->
            {ok, Next} = bus_model:put_agent(Acc, agent(?B, ?S2, false), Time, Time - 50),
            Next
        end,
        State,
        Times
    ).

two_agents(Mono) ->
    S0 = bus_model:new(),
    {ok, S1} = bus_model:put_agent(S0, agent(?A, ?S1, false), Mono, 50),
    {ok, S2} = bus_model:put_agent(S1, agent(?B, ?S2, false), Mono, 50),
    S2.

agent(Id, Session, Control) ->
    (bus_protocol_tests:fixture_map("register-valid.json"))#{
        <<"agentId">> => Id,
        <<"sessionId">> => Session,
        <<"host">> => <<"andromeda">>,
        <<"cwd">> => <<"/tmp">>,
        <<"sessionName">> => <<"s">>,
        <<"label">> => <<"lab">>,
        <<"model">> => null,
        <<"status">> => <<"idle">>,
        <<"pid">> => 1,
        <<"acceptsControl">> => Control
    }.

notice(From, To) ->
    (bus_protocol_tests:fixture_map("message-notice.json"))#{
        <<"id">> => ?MID,
        <<"from">> => From,
        <<"to">> => To,
        <<"kind">> => <<"notice">>,
        <<"body">> => <<"hello">>
    }.

public_envelope_boundary_test() ->
    Sender = (agent(?A, ?S1, false))#{
        <<"host">> => binary:copy(<<"\\">>, 255),
        <<"label">> => binary:copy(<<16#1f642/utf8>>, 200)},
    {ok, S} = bus_model:put_agent(two_agents(100), Sender, 100, 50),
    lists:foreach(fun(Wall) ->
        Msg = envelope_message(Sender, Wall, 32768),
        ?assertMatch({ok, _}, bus_protocol:decode_message(Msg)),
        ?assertEqual(32768, wire_bytes(Msg, Sender, Wall)),
        {ok, Full, Result} = bus_model:accept_mail(S, Msg, 100, Wall),
        assert_bytes(32768, Full),
        [Entry] = maps:get(?B, maps:get(mail, Full)),
        ?assertEqual(32768, iolist_size(json:encode(bus_model:public_mail(Entry)))),
        ?assertNot(maps:is_key(wire_bytes, bus_model:public_mail(Entry))),
        ?assertNot(maps:is_key(<<"expires_mono">>, bus_model:public_mail(Entry))),
        TooLarge = Msg#{<<"body">> => <<(maps:get(<<"body">>, Msg))/binary, "x">>},
        ?assertEqual({error, payload_too_large}, bus_model:accept_mail(S, TooLarge, 100, Wall)),
        ?assertEqual({error, conflict}, bus_model:accept_mail(Full, TooLarge, 100, Wall)),
        %% A later timestamp would enlarge a new envelope, but not a retry.
        ?assertEqual({ok, Full, Result}, bus_model:accept_mail(Full, Msg, 101, Wall * 100)),
        ?assertEqual(#{}, maps:get(dedup, S)),
        assert_bytes(0, S)
    end, [50, 1_700_000_000]).

envelope_message(Sender, Wall, Target) ->
    Base = (notice(?A, ?B))#{<<"body">> => <<>>},
    Remaining = Target - wire_bytes(Base, Sender, Wall),
    %% NUL needs six JSON bytes, while the decoded UTF-8 body remains small.
    Body = <<(binary:copy(<<0>>, Remaining div 6))/binary,
        (binary:copy(<<"x">>, Remaining rem 6))/binary>>,
    Base#{<<"body">> => Body}.

dedup_saturation_and_ordering_test() ->
    S = two_agents(100),
    Base = notice(?A, ?B),
    Full = lists:foldl(fun(N, Acc) ->
        Msg = Base#{<<"id">> => uuid_n(N)},
        {ok, Queued, _} = bus_model:accept_mail(Acc, Msg, 100, 50),
        {ok, Empty, _} = bus_model:pop_mail(Queued, ?B, 100),
        Empty
    end, S, lists:seq(1, 4096)),
    ?assertEqual(4096, map_size(maps:get(dedup, Full))),
    assert_bytes(0, Full),
    ?assertEqual({error, dedup_full}, bus_model:accept_mail(
        Full, Base#{<<"id">> => uuid_n(4097)}, 100, 50)),
    Retry = Base#{<<"id">> => uuid_n(1)},
    {ok, Full, Result} = bus_model:accept_mail(Full, Retry, 100, 50),
    Deleted = bus_model:delete_agent(bus_model:delete_agent(Full, ?A), ?B),
    ?assertEqual({ok, Deleted, Result}, bus_model:accept_mail(Deleted, Retry, 219, 999)),
    ?assertEqual({error, conflict}, bus_model:accept_mail(
        Deleted, Retry#{<<"body">> => <<"changed">>}, 219, 999)),
    ?assertEqual({error, not_found}, bus_model:accept_mail(Deleted, Retry, 220, 999)),
    {ok, ReadyA} = bus_model:put_agent(Full, agent(?A, ?S1, false), 220, 170),
    {ok, Ready} = bus_model:put_agent(ReadyA, agent(?B, ?S2, false), 220, 170),
    {ok, Accepted, NewResult} = bus_model:accept_mail(Ready, Retry, 220, 170),
    ?assertNotEqual(Result, NewResult),
    ?assertEqual(1, map_size(maps:get(dedup, Accepted))),
    ?assertEqual(4096, map_size(maps:get(dedup, bus_model:expire(Full, 219)))),
    ?assertEqual(0, map_size(maps:get(dedup, bus_model:expire(Full, 220)))).

dedup_precedes_mailbox_control_and_presence_test() ->
    {ok, Start} = bus_model:put_agent(two_agents(100), agent(?B, ?S2, true), 100, 50),
    Msg = (notice(?A, ?B))#{<<"kind">> => <<"prompt">>},
    {ok, S1, Result} = bus_model:accept_mail(Start, Msg, 100, 50),
    Full = lists:foldl(fun(N, Acc) ->
        {ok, Next, _} = bus_model:accept_mail(Acc,
            (notice(?A, ?B))#{<<"id">> => uuid_n(N)}, 100, 50),
        Next
    end, S1, lists:seq(1, 31)),
    ?assertEqual({ok, Full, Result}, bus_model:accept_mail(Full, Msg, 100, 50)),
    {ok, Disabled} = bus_model:put_agent(Full, agent(?B, ?S2, false), 101, 51),
    ?assertEqual({ok, Disabled, Result}, bus_model:accept_mail(Disabled, Msg, 101, 51)),
    ?assertEqual({error, conflict}, bus_model:accept_mail(
        Disabled, Msg#{<<"to">> => ?A}, 101, 51)),
    Gone = bus_model:expire(Disabled, 116),
    ?assertEqual({ok, Gone, Result}, bus_model:accept_mail(Gone, Msg, 116, 66)).

uuid_n(N) ->
    iolist_to_binary(io_lib:format("33333333-3333-4333-8333-~12.16.0b", [N])).
