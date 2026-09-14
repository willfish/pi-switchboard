-module(bus_protocol_tests).
-include_lib("eunit/include/eunit.hrl").
-export([fixture_map/1]).

-define(UUID1, <<"11111111-1111-4111-8111-111111111111">>).
-define(UUID2, <<"22222222-2222-4222-8222-222222222222">>).

decode_json_object_test() ->
    {ok, Map} = bus_protocol:decode_json(<<"{\"ok\":true}">>),
    ?assertEqual(true, maps:get(<<"ok">>, Map)).

duplicate_key_test() ->
    ?assertEqual(
        {error, {duplicate_key, <<"a">>}},
        bus_protocol:decode_json(<<"{\"a\":1,\"a\":2}">>)
    ).

trailing_data_test() ->
    ?assertEqual({error, trailing_data}, bus_protocol:decode_json(<<"{\"ok\":true}{}">>)).

invalid_utf8_test() ->
    ?assertMatch({error, _}, bus_protocol:decode_json(<<123, 255, 125>>)).

health_test() ->
    ?assertEqual(<<"{\"ok\":true}">>, bus_protocol:encode_health()).

error_envelope_test() ->
    Bin = bus_protocol:encode_error(<<"not_found">>, <<"missing">>),
    {ok, Map} = bus_protocol:decode_json(Bin),
    Error = maps:get(<<"error">>, Map),
    ?assertEqual(<<"not_found">>, maps:get(<<"code">>, Error)),
    ?assertEqual(<<"missing">>, maps:get(<<"message">>, Error)).

register_fixture_test() ->
    {ok, Bin} = file:read_file(fixture("register-valid.json")),
    {ok, Map} = bus_protocol:decode_json(Bin),
    {ok, Decoded} = bus_protocol:decode_register(Map),
    ?assertEqual(?UUID1, maps:get(<<"agentId">>, Decoded)),
    Model = maps:get(<<"model">>, Decoded),
    ?assertEqual(<<"anthropic">>, maps:get(<<"provider">>, Model)).

register_null_model_test() ->
    Map = (valid_register())#{<<"model">> => null},
    {ok, Decoded} = bus_protocol:decode_register(Map),
    ?assertEqual(null, maps:get(<<"model">>, Decoded)).

register_extra_field_test() ->
    Map = (valid_register())#{<<"updatedAt">> => 1},
    ?assertEqual({error, extra_fields}, bus_protocol:decode_register(Map)).

register_unknown_status_test() ->
    Map = (valid_register())#{<<"status">> => <<"ready">>},
    ?assertMatch({error, _}, bus_protocol:decode_register(Map)).

register_label_too_long_test() ->
    Long = unicode:characters_to_binary(lists:duplicate(201, $a)),
    Map = (valid_register())#{<<"label">> => Long},
    ?assertMatch({error, _}, bus_protocol:decode_register(Map)).

register_label_code_points_test() ->
    Ok = unicode:characters_to_binary(lists:duplicate(200, 16#e9)),
    Bad = unicode:characters_to_binary(lists:duplicate(201, 16#e9)),
    ?assertMatch({ok, _}, bus_protocol:decode_register((valid_register())#{<<"label">> => Ok})),
    ?assertMatch({error, _}, bus_protocol:decode_register((valid_register())#{<<"label">> => Bad})).

register_newline_label_test() ->
    Map = (valid_register())#{<<"label">> => <<"one\ntwo">>},
    ?assertMatch({error, _}, bus_protocol:decode_register(Map)).

register_bad_uuid_test() ->
    Map = (valid_register())#{<<"agentId">> => <<"not-a-uuid">>},
    ?assertMatch({error, _}, bus_protocol:decode_register(Map)).

message_fixture_test() ->
    {ok, Bin} = file:read_file(fixture("message-notice.json")),
    {ok, Map} = bus_protocol:decode_json(Bin),
    {ok, Decoded} = bus_protocol:decode_message(Map),
    ?assertEqual(<<"notice">>, maps:get(<<"kind">>, Decoded)).

message_kind_ask_invalid_test() ->
    Map = (valid_message())#{<<"kind">> => <<"ask">>},
    ?assertMatch({error, _}, bus_protocol:decode_message(Map)).

message_body_too_large_test() ->
    Body = binary:copy(<<"a">>, 16 * 1024 + 1),
    Map = (valid_message())#{<<"body">> => Body},
    ?assertMatch({error, _}, bus_protocol:decode_message(Map)).

message_empty_body_test() ->
    Map = (valid_message())#{<<"body">> => <<>>},
    ?assertMatch({error, _}, bus_protocol:decode_message(Map)).

valid_register() -> fixture_map("register-valid.json").
valid_message() -> fixture_map("message-notice.json").

fixture_map(Name) ->
    {ok, Bin} = file:read_file(fixture(Name)),
    {ok, Map} = bus_protocol:decode_json(Bin),
    Map.

fixture(Name) ->
    filename:join(["..", "tests", "fixtures", Name]).

exact_fields_test() ->
    lists:foreach(fun({Map, Decode}) ->
        lists:foreach(fun(Key) ->
            ?assertEqual({error, missing_fields}, Decode(maps:remove(Key, Map)))
        end, maps:keys(Map)),
        ?assertEqual({error, extra_fields}, Decode(Map#{<<"unknown">> => true})),
        lists:foreach(fun(Value) -> ?assertEqual({error, invalid_schema}, Decode(Value)) end,
            [null, [], <<>>, 1, true])
    end, [{valid_register(), fun bus_protocol:decode_register/1},
          {valid_message(), fun bus_protocol:decode_message/1}]).

metadata_controls_test_() ->
    [?_assertMatch({error, _}, bus_protocol:decode_register(
        metadata(Key, unicode:characters_to_binary([$a, C, $b]))))
     || Key <- [<<"cwd">>, <<"label">>, <<"sessionName">>, <<"provider">>, <<"modelId">>],
        C <- lists:seq(0, 31) ++ lists:seq(127, 159)].

unicode_line_separators_test() ->
    lists:foreach(fun({C, Escape}) ->
        Value = <<"a", C/utf8, "b">>,
        lists:foreach(fun(Key) ->
            Literal = bus_protocol:encode_map(metadata(Key, Value)),
            Escaped = binary:replace(Literal, <<C/utf8>>, Escape, [global]),
            lists:foreach(fun(Json) ->
                {ok, Map} = bus_protocol:decode_json(Json),
                ?assertMatch({error, _}, bus_protocol:decode_register(Map))
            end, [Literal, Escaped])
        end, [<<"label">>, <<"sessionName">>, <<"provider">>, <<"modelId">>]),
        BodyJson = bus_protocol:encode_map((valid_message())#{<<"body">> => Value}),
        lists:foreach(fun(Json) ->
            {ok, Message} = bus_protocol:decode_json(Json),
            ?assertMatch({ok, _}, bus_protocol:decode_message(Message))
        end, [BodyJson, binary:replace(BodyJson, <<C/utf8>>, Escape, [global])])
    end, [{16#2028, <<"\\u2028">>}, {16#2029, <<"\\u2029">>}]).

metadata_bounds_test() ->
    lists:foreach(fun({Key, Max, Char}) ->
        Good = unicode:characters_to_binary(lists:duplicate(Max, Char)),
        Bad = <<Good/binary, Char/utf8>>,
        ?assertMatch({ok, _}, bus_protocol:decode_register(metadata(Key, Good))),
        ?assertMatch({error, _}, bus_protocol:decode_register(metadata(Key, Bad))),
        lists:foreach(fun(Value) ->
            ?assertMatch({error, _}, bus_protocol:decode_register(metadata(Key, Value)))
        end, [<<>>, <<255>>, null, 1, true, []])
    end, [{<<"host">>, 255, $a}, {<<"cwd">>, 2048, 16#e9},
          {<<"label">>, 200, 16#1f642}, {<<"sessionName">>, 200, 16#1f642},
          {<<"provider">>, 200, 16#1f642}, {<<"modelId">>, 512, 16#1f642}]),
    ?assertMatch({error, _}, bus_protocol:decode_register(metadata(<<"host">>, <<16#e9/utf8>>))),
    ?assertMatch({ok, _}, bus_protocol:decode_register(metadata(<<"cwd">>, binary:copy(<<"x">>, 4096)))),
    ?assertMatch({error, _}, bus_protocol:decode_register(metadata(<<"cwd">>, binary:copy(<<"x">>, 4097)))).

metadata(<<"provider">>, Value) ->
    (valid_register())#{<<"model">> => #{<<"provider">> => Value, <<"id">> => <<"m">>}};
metadata(<<"modelId">>, Value) ->
    (valid_register())#{<<"model">> => #{<<"provider">> => <<"p">>, <<"id">> => Value}};
metadata(Key, Value) -> (valid_register())#{Key => Value}.

nested_model_fields_test() ->
    lists:foreach(fun(Model) ->
        ?assertMatch({error, _}, bus_protocol:decode_register((valid_register())#{<<"model">> => Model}))
    end, [#{}, #{<<"id">> => <<"m">>}, #{<<"provider">> => <<"p">>},
        #{<<"id">> => <<"m">>, <<"provider">> => <<"p">>, <<"extra">> => 1}, [], <<"m">>]).

nested_duplicate_keys_test() ->
    lists:foreach(fun(Bin) ->
        ?assertEqual({error, {duplicate_key, <<"id">>}}, bus_protocol:decode_json(Bin))
    end, [<<"{\"model\":{\"id\":\"a\",\"id\":\"b\"}}">>,
          <<"{\"items\":[{\"id\":1,\"id\":2}]}">>,
          <<"{\"model\":{\"id\":1,\"\\u0069d\":2}}">>]).

scalar_fields_test() ->
    lists:foreach(fun({Key, Values}) ->
        lists:foreach(fun(Value) ->
            ?assertMatch({error, _}, bus_protocol:decode_register((valid_register())#{Key => Value}))
        end, Values)
    end, [{<<"agentId">>, [null, <<"bad">>]}, {<<"sessionId">>, [null, <<"bad">>]},
          {<<"pid">>, [0, -1, 1.0, <<"1">>, true]},
          {<<"acceptsControl">>, [0, 1, null, <<"true">>]},
          {<<"status">>, [null, <<"ready">>, true]}]),
    ?assertMatch({ok, _}, bus_protocol:decode_register((valid_register())#{
        <<"status">> => <<"busy">>, <<"pid">> => 1, <<"acceptsControl">> => true})),
    lists:foreach(fun(Key) ->
        ?assertMatch({error, _}, bus_protocol:decode_message((valid_message())#{Key => <<"bad">>}))
    end, [<<"id">>, <<"from">>, <<"to">>]),
    lists:foreach(fun(Kind) ->
        ?assertMatch({ok, _}, bus_protocol:decode_message((valid_message())#{<<"kind">> => Kind}))
    end, [<<"notice">>, <<"prompt">>, <<"steer">>]).

body_utf8_byte_boundary_test() ->
    Good = binary:copy(<<16#1f642/utf8>>, 4096),
    ?assertMatch({ok, _}, bus_protocol:decode_message((valid_message())#{<<"body">> => Good})),
    ?assertEqual({error, payload_too_large}, bus_protocol:decode_message(
        (valid_message())#{<<"body">> => <<Good/binary, "a">>})),
    ?assertEqual({error, payload_too_large}, bus_protocol:decode_message(
        (valid_message())#{<<"body">> => binary:copy(<<"a">>, 16385)})),
    lists:foreach(fun(Value) ->
        ?assertMatch({error, {invalid_field, <<"body">>}},
            bus_protocol:decode_message((valid_message())#{<<"body">> => Value}))
    end, [<<>>, <<255>>, null, 1, true, []]),
    ?assertMatch({ok, _}, bus_protocol:decode_message(
        (valid_message())#{<<"body">> => <<0, 10, 127, 16#9b/utf8>>})).
