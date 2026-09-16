-module(bus_operator_work_tests).
-include_lib("eunit/include/eunit.hrl").

fixture_path() ->
    filename:join(["..", "tests", "fixtures", "operator-work.json"]).

load_fixture() ->
    {ok, Bin} = file:read_file(fixture_path()),
    json:decode(Bin).

all_null() -> maps:get(<<"allNull">>, load_fixture()).
populated() -> maps:get(<<"populated">>, load_fixture()).
hostile() -> maps:get(<<"hostile">>, load_fixture()).

roundtrip_shared_fixtures_test() ->
    lists:foreach(fun(Snap) ->
        ?assertEqual(true, bus_operator_work:valid(Snap)),
        {ok, Bin} = bus_operator_work:encode(Snap),
        {ok, Again} = bus_operator_work:decode_bin(Bin),
        ?assertEqual(Snap, Again)
    end, [all_null(), populated(), hostile()]),
    Null = all_null(),
    ?assertEqual(null, maps:get(<<"phase">>, Null)),
    ?assertEqual(null, maps:get(<<"objective">>, Null)),
    ?assertEqual(null, maps:get(<<"currentStep">>, Null)),
    ?assertEqual(null, maps:get(<<"nextStep">>, Null)),
    ?assertEqual(null, maps:get(<<"blocker">>, Null)),
    ?assertEqual([], maps:get(<<"evidence">>, Null)),
    ?assertEqual(null, maps:get(<<"parentWorkId">>, Null)),
    ?assertEqual(null, maps:get(<<"delegatedWorkId">>, Null)),
    Pop = populated(),
    ?assertEqual(<<"write shared fixture">>, maps:get(<<"currentStep">>, Pop)),
    ?assertEqual(<<"round-trip Erlang and TypeScript">>, maps:get(<<"nextStep">>, Pop)),
    ?assertEqual(<<"decision">>, maps:get(<<"kind">>, maps:get(<<"blocker">>, Pop))),
    ?assertEqual(2, length(maps:get(<<"evidence">>, Pop))),
    Hostile = hostile(),
    Objective = maps:get(<<"objective">>, Hostile),
    ?assertEqual(true, binary:match(Objective, <<"<script>">>) =/= nomatch).

required_fields_test() ->
    Null = all_null(),
    lists:foreach(fun(Key) ->
        Bad = maps:remove(Key, Null),
        ?assertEqual({error, invalid_work}, bus_operator_work:decode(Bad), Key)
    end, [<<"currentStep">>, <<"nextStep">>, <<"blocker">>, <<"evidence">>,
          <<"parentWorkId">>, <<"delegatedWorkId">>]).

rejects_extra_body_nested_and_empty_test() ->
    Null = all_null(),
    ?assertEqual({error, invalid_work},
        bus_operator_work:decode(Null#{<<"body">> => <<"secret">>})),
    ?assertEqual({error, invalid_work},
        bus_operator_work:decode(Null#{<<"extra">> => true})),
    ?assertEqual({error, invalid_work},
        bus_operator_work:decode(Null#{<<"objective">> => <<>>})),
    ?assertEqual({error, invalid_work},
        bus_operator_work:decode(Null#{<<"phase">> => <<"planningx">>})),
    ?assertEqual({error, invalid_work},
        bus_operator_work:decode(Null#{<<"blocker">> =>
            #{<<"kind">> => <<"blocked">>, <<"reason">> => <<"x">>, <<"extra">> => 1}})),
    ?assertEqual({error, invalid_work},
        bus_operator_work:decode(Null#{<<"evidence">> =>
            [#{<<"kind">> => <<"file">>, <<"ref">> => <<"a">>, <<"nested">> => #{}}]})),
    ?assertEqual({error, invalid_work},
        bus_operator_work:decode(Null#{<<"project">> => #{<<"name">> => <<"x">>}})).

duplicate_key_wire_test() ->
    {ok, Bin} = bus_operator_work:encode(all_null()),
    %% Insert a second workId key before the final brace.
    Dup = <<(binary:part(Bin, 0, byte_size(Bin) - 1))/binary, ",\"workId\":null}">>,
    ?assertEqual({error, duplicate_key}, bus_operator_work:decode_bin(Dup)).

byte_bounds_not_codepoints_test() ->
    Null = all_null(),
    Text = binary:copy(<<"a">>, 2048),
    ?assertMatch({ok, _}, bus_operator_work:decode(Null#{<<"objective">> => Text})),
    ?assertEqual({error, invalid_work},
        bus_operator_work:decode(Null#{<<"objective">> => <<Text/binary, $a>>})),
    Owner = binary:copy(<<"o">>, 200),
    ?assertMatch({ok, _}, bus_operator_work:decode(Null#{<<"owner">> => Owner})),
    ?assertEqual({error, invalid_work},
        bus_operator_work:decode(Null#{<<"owner">> => <<Owner/binary, $o>>})),
    Pound = binary:copy(<<194, 163>>, 1024),
    ?assertEqual(2048, byte_size(Pound)),
    ?assertMatch({ok, _}, bus_operator_work:decode(Null#{<<"objective">> => Pound})),
    ?assertEqual({error, invalid_work},
        bus_operator_work:decode(Null#{<<"objective">> => <<Pound/binary, 194, 163>>})),
    Ref = binary:copy(<<"r">>, 512),
    ?assertMatch({ok, _}, bus_operator_work:decode(Null#{<<"evidence">> =>
        [#{<<"kind">> => <<"file">>, <<"ref">> => Ref}]})),
    ?assertEqual({error, invalid_work},
        bus_operator_work:decode(Null#{<<"evidence">> =>
        [#{<<"kind">> => <<"file">>, <<"ref">> => <<Ref/binary, $r>>}]})),
    TooMany = lists:duplicate(9, #{<<"kind">> => <<"file">>, <<"ref">> => <<"a">>}),
    ?assertEqual({error, invalid_work},
        bus_operator_work:decode(Null#{<<"evidence">> => TooMany})),
    ?assertEqual({error, envelope},
        bus_operator_work:decode_bin(binary:copy(<<" ">>, 32769))).
