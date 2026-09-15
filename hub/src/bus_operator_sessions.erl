-module(bus_operator_sessions).

%% Pure, bounded automatic-session state. The caller owns the clock, randomness,
%% request admission and HTTP origin parsing. No nonce is retained in this state.
-export([new/0, new/1, bootstrap/5, authorize/4, disconnect/4, sweep/2, stats/1]).

new() -> new(#{}).
new(Overrides) when is_map(Overrides) ->
    Defaults = #{max_sessions => 1024, max_per_peer => 32, ttl_ms => 1800000,
        max_buckets => 4096, bucket_capacity => 10, refill_ms => 6000,
        bucket_idle_ms => 600000},
    Known = lists:all(fun(K) -> maps:is_key(K, Defaults) end, maps:keys(Overrides)),
    Positive = lists:all(fun(V) -> is_integer(V) andalso V > 0 end, maps:values(Overrides)),
    Limits = maps:merge(Defaults, Overrides),
    case Known andalso Positive andalso
        maps:get(bucket_idle_ms, Limits) >= maps:get(bucket_capacity, Limits) * maps:get(refill_ms, Limits) of
        true -> #{limits => Limits, sessions => #{}, buckets => #{}};
        false -> error(badarg)
    end;
new(_) -> error(badarg).

bootstrap(Peer, Origin, Nonce, Now, State) ->
    case valid_peer(Peer) andalso valid_origin(Origin) andalso valid_nonce(Nonce) andalso is_integer(Now) of
        false -> {error, invalid_request, State};
        true ->
            Clean = sweep(Now, State),
            case take_credit(Peer, Now, Clean) of
                {error, Reason, Limited} -> {error, Reason, Limited};
                {ok, Limited} -> allocate(Peer, Origin, Nonce, Now, Limited)
            end
    end.

allocate(Peer, Origin, Nonce, Now, #{limits := Limits, sessions := Sessions} = State) ->
    Key = crypto:hash(sha256, Nonce),
    PeerCount = maps:fold(fun(_, #{peer := P}, N) ->
        case P =:= Peer of true -> N + 1; false -> N end
    end, 0, Sessions),
    case {maps:is_key(Key, Sessions), map_size(Sessions) >= maps:get(max_sessions, Limits),
          PeerCount >= maps:get(max_per_peer, Limits)} of
        {true, _, _} -> {error, nonce_collision, State};
        {_, true, _} -> {error, session_capacity, State};
        {_, _, true} -> {error, peer_capacity, State};
        {false, false, false} ->
            Session = #{peer => Peer, origin => Origin, expires_at => Now + maps:get(ttl_ms, Limits)},
            {ok, State#{sessions := Sessions#{Key => Session}}}
    end.

authorize(Nonce, Origin, Now, #{sessions := Sessions}) ->
    case valid_nonce(Nonce) andalso valid_origin(Origin) andalso is_integer(Now) of
        false -> {error, unauthorized};
        true ->
            case maps:find(crypto:hash(sha256, Nonce), Sessions) of
                {ok, #{origin := Origin, expires_at := Expiry}} when Now < Expiry ->
                    {ok, #{expires_at => Expiry}};
                _ -> {error, unauthorized}
            end
    end.

disconnect(Nonce, Origin, Now, #{sessions := Sessions} = State) ->
    case authorize(Nonce, Origin, Now, State) of
        {ok, _} -> {ok, State#{sessions := maps:remove(crypto:hash(sha256, Nonce), Sessions)}};
        {error, unauthorized} -> {error, unauthorized, State}
    end.

sweep(Now, #{limits := Limits, sessions := Sessions, buckets := Buckets} = State) when is_integer(Now) ->
    Idle = maps:get(bucket_idle_ms, Limits),
    State#{sessions := maps:filter(fun(_, #{expires_at := Expiry}) -> Now < Expiry end, Sessions),
        buckets := maps:filter(fun(_, #{last_seen := Seen}) -> Now - Seen < Idle end, Buckets)}.

stats(#{sessions := Sessions, buckets := Buckets}) ->
    #{sessions => map_size(Sessions), buckets => map_size(Buckets)}.

take_credit(Peer, Now, #{limits := Limits, buckets := Buckets} = State) ->
    Refill = maps:get(refill_ms, Limits),
    Capacity = maps:get(bucket_capacity, Limits) * Refill,
    case maps:find(Peer, Buckets) of
        error when map_size(Buckets) >= map_get(max_buckets, Limits) ->
            {error, bucket_capacity, State};
        Found ->
            Initial = case Found of
                error -> #{credits => Capacity, updated_at => Now, last_seen => Now};
                {ok, B} -> B
            end,
            %% Integer millisecond credits retain fractional-token refill without drift.
            Updated = max(Now, maps:get(updated_at, Initial)),
            Credits = min(Capacity, maps:get(credits, Initial) + Updated - maps:get(updated_at, Initial)),
            Bucket = Initial#{credits := Credits, updated_at := Updated,
                last_seen := max(Now, maps:get(last_seen, Initial))},
            case Credits >= Refill of
                true -> {ok, State#{buckets := Buckets#{Peer => Bucket#{credits := Credits - Refill}}}};
                false -> {error, rate_limited, State#{buckets := Buckets#{Peer => Bucket}}}
            end
    end.

valid_nonce(N) -> is_binary(N) andalso byte_size(N) =:= 32.
valid_origin(O) -> is_binary(O) andalso byte_size(O) > 0 andalso byte_size(O) =< 1024.
valid_peer(P) when is_tuple(P), tuple_size(P) =:= 4 -> valid_address(P, 255);
valid_peer(P) when is_tuple(P), tuple_size(P) =:= 8 -> valid_address(P, 65535);
valid_peer(_) -> false.
valid_address(P, Max) -> lists:all(fun(N) -> is_integer(N) andalso N >= 0 andalso N =< Max end, tuple_to_list(P)).
