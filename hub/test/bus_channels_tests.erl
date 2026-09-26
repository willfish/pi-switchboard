-module(bus_channels_tests).
-include_lib("eunit/include/eunit.hrl").

-define(A, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(B, <<"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb">>).

operator_post_uses_reserved_sender_test() ->
    ?assertEqual(true, bus_protocol:is_uuid(bus_channels:operator_id())),
    {ok, Id, <<"hello from the operator">>} = bus_channels:decode_operator_post(#{<<"id">> => ?A, <<"body">> => <<"hello from the operator">>}),
    {ok, S, Result} = bus_channels:post(bus_channels:new(1_000), <<"general">>, bus_channels:operator_id(), Id, <<"hello from the operator">>, 1_000, 1_000),
    {ok, Page} = bus_channels:read(S, <<"general">>, #{audience => operator, mode => tail, limit => 8}),
    [Message] = maps:get(<<"messages">>, Page),
    ?assertEqual(bus_channels:operator_id(), maps:get(<<"from">>, Message)),
    ?assertEqual(<<"accepted">>, maps:get(<<"state">>, Result)).

status_document_roundtrip_test() ->
    Bin = bus_protocol:encode_map(#{<<"from">> => ?A, <<"summary">> => <<"checking in">>,
        <<"label">> => <<"ct-agent">>, <<"project">> => <<"suite">>, <<"area">> => <<"general">>}),
    {ok, Map} = bus_protocol:decode_json(Bin),
    ?assertMatch({ok, _}, bus_channels:decode_status(Map)).

recent_window_is_not_the_operator_history_test() ->
    S0 = lists:foldl(fun(N, Acc) -> post(Acc, <<"general">>, N) end, bus_channels:new(1_000), lists:seq(1, 40)),
    {ok, AgentQ} = bus_channels:parse_query([], agent),
    {ok, Agent} = bus_channels:read(S0, <<"general">>, AgentQ),
    ?assertEqual(<<"recent">>, maps:get(<<"window">>, Agent)),
    ?assertEqual(24, length(maps:get(<<"messages">>, Agent))),
    ?assertEqual(<<"40">>, maps:get(<<"toSequence">>, Agent)),
    ?assertEqual(true, maps:get(<<"earlier">>, Agent)),
    ?assertEqual(true, maps:get(<<"caughtUp">>, Agent)),
    {ok, HistoryQ} = bus_channels:parse_query([{<<"after">>, <<"0">>}], operator),
    {ok, History} = bus_channels:read(S0, <<"general">>, HistoryQ),
    ?assertEqual(<<"history">>, maps:get(<<"window">>, History)),
    ?assertEqual(40, length(maps:get(<<"messages">>, History))),
    ?assertEqual(<<"1">>, maps:get(<<"fromSequence">>, History)),
    ?assertEqual(false, maps:get(<<"earlier">>, History)),
    ?assertEqual(true, maps:get(<<"caughtUp">>, History)),
    {ok, OlderQ} = bus_channels:parse_query([{<<"before">>, <<"25">>}, {<<"limit">>, <<"10">>}], operator),
    {ok, Older} = bus_channels:read(S0, <<"general">>, OlderQ),
    ?assertEqual([integer_to_binary(N) || N <- lists:seq(15, 24)], [maps:get(<<"seq">>, M) || M <- maps:get(<<"messages">>, Older)]).

channel_index_does_not_copy_other_channel_bodies_test() ->
    S0 = bus_channels:new(1_000),
    {ok, S1, _} = bus_channels:post(S0, <<"general">>, ?A, id(1), <<"fleet">>, 1_000, 1_000),
    {ok, S2, _} = bus_channels:post(S1, <<"billing">>, ?A, id(2), <<"invoice">>, 1_000, 1_000),
    {ok, Page} = bus_channels:read(S2, <<"billing">>, #{audience => agent, mode => tail, limit => 24}),
    ?assertEqual([<<"invoice">>], [maps:get(<<"body">>, M) || M <- maps:get(<<"messages">>, Page)]),
    ?assertEqual(message_bytes(S2, 1) + message_bytes(S2, 2), maps:get(bytes, S2)).

identical_status_does_not_append_test() ->
    S0 = bus_channels:new(1_000),
    Status = status(<<"planning the import">>),
    {ok, S1, Noted} = bus_channels:put_status(S0, <<"general">>, Status, 1_000, 1_000),
    ?assertEqual(<<"noted">>, maps:get(<<"state">>, Noted)),
    {ok, S2, Current} = bus_channels:put_status(S1, <<"general">>, Status, 1_010, 1_010),
    ?assertEqual(<<"current">>, maps:get(<<"state">>, Current)),
    ?assertEqual(null, maps:get(<<"sequence">>, Current)),
    ?assertEqual(1, maps:get(retained, maps:get(<<"general">>, maps:get(channels, S2)))),
    {ok, S3, _} = bus_channels:put_status(S2, <<"general">>, status(<<"checking the catalogue">>), 1_020, 1_020),
    ?assertEqual(2, maps:get(retained, maps:get(<<"general">>, maps:get(channels, S3)))).

duplicate_post_keeps_one_packet_test() ->
    S0 = bus_channels:new(1_000),
    {ok, S1, First} = bus_channels:post(S0, <<"general">>, ?A, id(1), <<"once">>, 1_000, 1_000),
    ?assertEqual({duplicate, First}, bus_channels:classify(S1, <<"general">>, ?A, id(1), <<"say">>, <<"once">>)),
    ?assertEqual({error, conflict}, bus_channels:classify(S1, <<"general">>, ?A, id(1), <<"say">>, <<"twice">>)),
    ?assertEqual(1, maps:get(retained, maps:get(<<"general">>, maps:get(channels, S1)))).

stale_status_expires_so_new_checkins_fit_test() ->
    S0 = bus_channels:new(1_000),
    {ok, S1, _} = bus_channels:put_status(S0, <<"general">>, status(<<"old check-in">>), 1_000, 1_000),
    S2 = bus_channels:expire(S1, 1_000, 1_000 + 86400),
    {ok, Board} = bus_channels:statuses(S2, <<"general">>),
    ?assertEqual([], maps:get(<<"statuses">>, Board)),
    {ok, _, Noted} = bus_channels:put_status(S2, <<"general">>, status(<<"new check-in">>), 90_000, 90_000),
    ?assertEqual(<<"noted">>, maps:get(<<"state">>, Noted)).

retention_drops_oldest_without_removing_the_channel_test() ->
    S0 = bus_channels:new(1_000),
    {ok, S1, _} = bus_channels:post(S0, <<"general">>, ?A, id(1), <<"old">>, 1_000, 1_000),
    S2 = bus_channels:expire(S1, 1_000, 1_000 + 86400),
    ?assertEqual(0, maps:get(retained, maps:get(<<"general">>, maps:get(channels, S2)))),
    ?assertEqual(<<"general">>, maps:get(<<"name">>, hd(maps:get(<<"channels">>, bus_channels:list(S2))))).

post(State, Name, N) ->
    {ok, Next, _} = bus_channels:post(State, Name, ?A, id(N), integer_to_binary(N), 1_000, 1_000),
    Next.

status(Summary) ->
    #{<<"from">> => ?A, <<"summary">> => Summary, <<"label">> => <<"agent">>, <<"project">> => <<"switchboard">>, <<"area">> => <<"general">>}.

id(N) ->
    Suffix = integer_to_binary(N),
    Pad = binary:copy(<<"0">>, 12 - byte_size(Suffix)),
    <<"11111111-1111-4111-8111-", Pad/binary, Suffix/binary>>.

message_bytes(State, Seq) ->
    maps:get(bytes, maps:get(Seq, maps:get(messages, State))).
