-module(bus_operator_http_tests).
-include_lib("eunit/include/eunit.hrl").

hex_roundtrip_test() ->
    Raw = crypto:strong_rand_bytes(32),
    Hex = bus_operator_http:encode_nonce(Raw),
    ?assertEqual(64, byte_size(Hex)),
    ?assertEqual(Hex, string:lowercase(Hex)),
    ?assertEqual({ok, Raw}, bus_operator_http:decode_nonce(Hex)).

malformed_nonce_rejected_test() ->
    lists:foreach(fun(Value) ->
        ?assertEqual({error, unauthorized}, bus_operator_http:decode_nonce(Value))
    end, [<<>>, <<"aa">>, binary:copy(<<"A">>, 64), binary:copy(<<"g">>, 64),
          <<(binary:copy(<<"a">>, 64))/binary, ",", (binary:copy(<<"b">>, 64))/binary>>,
          not_binary, <<"0">>]).

empty_object_test() ->
    ?assertEqual(ok, bus_operator_http:empty_object(#{})),
    ?assertEqual({error, invalid_schema}, bus_operator_http:empty_object(#{<<"x">> => 1})),
    ?assertEqual({error, invalid_schema}, bus_operator_http:empty_object([])).

canonical_origin_default_port_and_case_test() ->
    ?assertEqual(<<"http://localhost">>,
        bus_operator_http:canonical_origin(<<"http">>, <<"localhost">>, 80)),
    ?assertEqual(<<"https://example.com">>,
        bus_operator_http:canonical_origin(<<"https">>, <<"Example.COM">>, 443)),
    ?assertEqual(<<"http://localhost:7420">>,
        bus_operator_http:canonical_origin(<<"http">>, <<"LocalHost">>, 7420)),
    ?assertEqual(<<"http://localhost.">>,
        bus_operator_http:canonical_origin(<<"http">>, <<"localhost.">>, 80)),
    ?assertEqual(<<"http://localhost.:7420">>,
        bus_operator_http:canonical_origin(<<"http">>, <<"LocalHost.">>, 7420)),
    ?assertEqual(<<"http://[::1]">>,
        bus_operator_http:canonical_origin(<<"http">>, <<"::1">>, 80)),
    ?assertEqual(<<"http://[::1]:7420">>,
        bus_operator_http:canonical_origin(<<"http">>, <<"::1">>, 7420)).
