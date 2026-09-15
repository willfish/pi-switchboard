-module(bus_operator_sessions_tests).
-include_lib("eunit/include/eunit.hrl").

origin() -> <<"http://localhost:7420">>.
peer() -> {127, 0, 0, 1}.
nonce(N) -> binary:copy(<<N>>, 32).
create(N, Now, S) -> bus_operator_sessions:bootstrap(peer(), origin(), nonce(N), Now, S).

empty_and_options_test() ->
    ?assertEqual(#{sessions => 0, buckets => 0}, bus_operator_sessions:stats(bus_operator_sessions:new())),
    lists:foreach(fun(Options) ->
        ?assertError(badarg, bus_operator_sessions:new(Options))
    end, [#{unknown => 1}, #{max_sessions => 0}, #{ttl_ms => -1}, #{refill_ms => 1.5},
          #{bucket_idle_ms => 1}, not_a_map]).

nonce_is_not_retained_test() ->
    {ok, S} = create(167, 0, bus_operator_sessions:new()),
    ?assertEqual(nomatch, binary:match(term_to_binary(S), nonce(167))),
    ?assertMatch({ok, #{expires_at := 1800000}}, bus_operator_sessions:authorize(nonce(167), origin(), 1, S)).

origin_and_expiry_test() ->
    {ok, S} = create(1, -100, bus_operator_sessions:new(#{ttl_ms => 20})),
    ?assertMatch({ok, _}, bus_operator_sessions:authorize(nonce(1), origin(), -81, S)),
    ?assertEqual({error, unauthorized}, bus_operator_sessions:authorize(nonce(1), origin(), -80, S)),
    ?assertEqual({error, unauthorized}, bus_operator_sessions:authorize(nonce(1), <<"http://localhost.:7420">>, -90, S)),
    ?assertEqual({error, unauthorized}, bus_operator_sessions:authorize(nonce(2), origin(), -90, S)).

malformed_input_does_not_allocate_test() ->
    S = bus_operator_sessions:new(),
    lists:foreach(fun(Value) ->
        ?assertEqual({error, invalid_request, S}, bus_operator_sessions:bootstrap(peer(), origin(), Value, 0, S)),
        ?assertEqual({error, unauthorized}, bus_operator_sessions:authorize(Value, origin(), 0, S))
    end, [<<>>, <<0:248>>, <<0:264>>, not_binary]),
    ?assertEqual({error, invalid_request, S}, bus_operator_sessions:bootstrap(bad_peer, origin(), nonce(1), 0, S)),
    ?assertEqual({error, invalid_request, S}, bus_operator_sessions:bootstrap(peer(), <<>>, nonce(1), 0, S)).

global_capacity_and_expiry_release_test() ->
    S0 = bus_operator_sessions:new(#{max_sessions => 1, ttl_ms => 10}),
    {ok, S1} = create(1, 0, S0),
    {error, session_capacity, S2} = create(2, 1, S1),
    ?assertMatch({ok, _}, bus_operator_sessions:authorize(nonce(1), origin(), 2, S2)),
    {ok, S3} = create(2, 10, S2),
    ?assertEqual(1, maps:get(sessions, bus_operator_sessions:stats(S3))),
    ?assertEqual({error, unauthorized}, bus_operator_sessions:authorize(nonce(1), origin(), 10, S3)).

peer_capacity_is_not_global_test() ->
    {ok, S1} = create(1, 0, bus_operator_sessions:new(#{max_per_peer => 1})),
    {error, peer_capacity, S2} = create(2, 0, S1),
    {ok, S3} = bus_operator_sessions:bootstrap({127, 0, 0, 2}, origin(), nonce(2), 0, S2),
    ?assertEqual(2, maps:get(sessions, bus_operator_sessions:stats(S3))).

independent_sessions_and_disconnect_test() ->
    {ok, S1} = create(1, 0, bus_operator_sessions:new()),
    {ok, S2} = create(2, 0, S1),
    ?assertEqual({error, unauthorized, S2}, bus_operator_sessions:disconnect(nonce(1), <<"http://foreign.invalid">>, 0, S2)),
    {ok, S3} = bus_operator_sessions:disconnect(nonce(1), origin(), 0, S2),
    ?assertEqual({error, unauthorized}, bus_operator_sessions:authorize(nonce(1), origin(), 0, S3)),
    ?assertMatch({ok, _}, bus_operator_sessions:authorize(nonce(2), origin(), 0, S3)).

nonce_collision_does_not_overwrite_test() ->
    {ok, S1} = create(1, 0, bus_operator_sessions:new()),
    {error, nonce_collision, S2} = bus_operator_sessions:bootstrap(peer(), <<"http://localhost:7421">>, nonce(1), 0, S1),
    ?assertMatch({ok, _}, bus_operator_sessions:authorize(nonce(1), origin(), 0, S2)),
    ?assertEqual({error, unauthorized}, bus_operator_sessions:authorize(nonce(1), <<"http://localhost:7421">>, 0, S2)).

rate_limit_refills_without_rounding_test() ->
    S0 = bus_operator_sessions:new(#{bucket_capacity => 1, refill_ms => 100}),
    {ok, S1} = create(1, 0, S0),
    {error, rate_limited, S2} = create(2, 99, S1),
    {ok, S3} = create(2, 100, S2),
    {error, rate_limited, S4} = create(3, 199, S3),
    ?assertMatch({ok, _}, create(3, 200, S4)).

idle_time_does_not_accumulate_unbounded_burst_test() ->
    S0 = bus_operator_sessions:new(#{bucket_capacity => 1, refill_ms => 100}),
    {ok, S1} = create(1, 0, S0),
    {ok, S2} = create(2, 10000, S1),
    ?assertMatch({error, rate_limited, _}, create(3, 10000, S2)).

bucket_capacity_and_expiry_test() ->
    S0 = bus_operator_sessions:new(#{max_buckets => 1, bucket_capacity => 1,
                                     refill_ms => 10, bucket_idle_ms => 20, ttl_ms => 10}),
    {ok, S1} = create(1, 0, S0),
    ?assertMatch({error, bucket_capacity, _}, bus_operator_sessions:bootstrap({127, 0, 0, 2}, origin(), nonce(2), 19, S1)),
    {ok, S2} = bus_operator_sessions:bootstrap({127, 0, 0, 2}, origin(), nonce(2), 20, S1),
    ?assertEqual(#{sessions => 1, buckets => 1}, bus_operator_sessions:stats(S2)),
    ?assertEqual(#{sessions => 0, buckets => 0}, bus_operator_sessions:stats(bus_operator_sessions:sweep(40, S2))).

ipv6_peer_test() ->
    ?assertMatch({ok, _}, bus_operator_sessions:bootstrap({0, 0, 0, 0, 0, 0, 0, 1}, origin(), nonce(1), 0, bus_operator_sessions:new())).
