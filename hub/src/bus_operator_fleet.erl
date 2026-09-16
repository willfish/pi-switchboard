-module(bus_operator_fleet).

%% Frozen fleet work pages. Shared snapshots, per-session cursor binding.
%% No live binding eviction. Capture capacity is checked before encoding.
-export([new/0, expire/2, can_capture/2, bound/7, capture/10, continue/7,
         snapshot_count/1, snapshot_bytes/1, max_snaps/0, max_bytes/0,
         page_limit/0, page_bytes/0, cursor_limit/0, max_total/0, ttl_ms/0]).

-define(PAGE, 128).
-define(PAGE_BYTES, 1048576).
-define(MAX_TOTAL, 5000).
-define(MAX_SNAPS, 8).
-define(MAX_BYTES, 67108864).
-define(TTL_MS, 30000).
-define(CURSOR, 128).

new() ->
    #{snaps => #{}, by_session => #{}, bytes => 0}.

expire(Now, #{snaps := Snaps, by_session := Sess, bytes := Bytes} = F)
  when is_integer(Now) ->
    Dead = [Id || Id := S <- Snaps, maps:get(expires, S) =< Now],
    Snaps1 = maps:without(Dead, Snaps),
    Dropped = lists:sum([maps:get(bytes, maps:get(Id, Snaps)) || Id <- Dead]),
    Sess1 = maps:filter(fun(_, Id) -> not lists:member(Id, Dead) end, Sess),
    F#{snaps := Snaps1, by_session := Sess1, bytes := Bytes - Dropped};
expire(_, F) -> F.

can_capture(F, Now) ->
    E = expire(Now, F),
    snapshot_count(E) < ?MAX_SNAPS andalso snapshot_bytes(E) < ?MAX_BYTES.

bound(Digest, F, Now, Rev, StoreRev, Epoch, Deadline)
  when is_binary(Digest), byte_size(Digest) =:= 32, is_integer(Now),
       is_integer(Rev), is_integer(StoreRev), is_binary(Epoch) ->
    try
        check(Deadline),
        E = expire(Now, F),
        case maps:find(Digest, maps:get(by_session, E)) of
            error -> none;
            {ok, Id} ->
                case maps:find(Id, maps:get(snaps, E)) of
                    {ok, S} ->
                        case maps:get(expires, S) > Now
                                andalso maps:get(revision, S) =:= Rev
                                andalso maps:get(store_revision, S) =:= StoreRev
                                andalso maps:get(epoch, S) =:= Epoch of
                            true ->
                                check(Deadline),
                                {ok, element(1, maps:get(frames, S)), E};
                            false -> none
                        end;
                    error -> none
                end
        end
    catch throw:Reason -> {error, Reason}
    end;
bound(_, _, _, _, _, _, _) -> {error, invalid_request}.

capture(Views, Epoch, Rev, StoreRev, Now, Wall, Deadline, Digest, F0, Id)
  when is_list(Views), is_binary(Epoch), is_integer(Rev), is_integer(StoreRev),
       is_integer(Now), is_integer(Wall), is_integer(Deadline), is_binary(Digest),
       byte_size(Digest) =:= 32, is_binary(Id) ->
    try
        check(Deadline),
        F = expire(Now, F0),
        case can_capture(F, Now) of
            false -> throw(capacity);
            true ->
                case length(Views) =< ?MAX_TOTAL of
                    false -> throw(capacity);
                    true ->
                        Sorted = lists:sort(fun(A, B) -> view_id(A) < view_id(B) end, Views),
                        check(Deadline),
                        TotalN = length(Sorted),
                        Frames = pack(Sorted, TotalN, Epoch, Id, Rev, Wall, 0, Deadline, [], 0),
                        check(Deadline),
                        Bytes = lists:sum([byte_size(B) || B <- Frames]),
                        Used = maps:get(bytes, F) + Bytes,
                        case Used =< ?MAX_BYTES of
                            false -> throw(capacity);
                            true ->
                                Snap = #{id => Id, epoch => Epoch, revision => Rev,
                                    store_revision => StoreRev,
                                    expires => Now + ?TTL_MS, frames => list_to_tuple(Frames),
                                    bytes => Bytes},
                                F1 = F#{snaps := (maps:get(snaps, F))#{Id => Snap},
                                        by_session := (maps:get(by_session, F))#{Digest => Id},
                                        bytes := Used},
                                {ok, hd(Frames), F1}
                        end
                end
        end
    catch throw:Reason -> {error, Reason}
    end;
capture(_, _, _, _, _, _, _, _, _, _) -> {error, invalid_request}.

continue(Cursor, Digest, Now, Rev, Epoch, Deadline, F0)
  when is_binary(Cursor), is_binary(Digest), byte_size(Digest) =:= 32 ->
    try
        check(Deadline),
        F = expire(Now, F0),
        {Id, Index} = decode_cursor(Cursor),
        case maps:find(Digest, maps:get(by_session, F)) of
            {ok, Id} -> ok;
            _ -> throw(epoch_reset)
        end,
        case maps:find(Id, maps:get(snaps, F)) of
            error -> throw(epoch_reset);
            {ok, S} ->
                case maps:get(expires, S) > Now
                        andalso maps:get(revision, S) =:= Rev
                        andalso maps:get(epoch, S) =:= Epoch of
                    false -> throw(epoch_reset);
                    true ->
                        Frames = maps:get(frames, S),
                        case Index > 0 andalso Index < tuple_size(Frames) of
                            true ->
                                check(Deadline),
                                {ok, element(Index + 1, Frames), F};
                            false -> throw(invalid_cursor)
                        end
                end
        end
    catch throw:Reason -> {error, Reason}
    end;
continue(_, _, _, _, _, _, _) -> {error, invalid_request}.

snapshot_count(#{snaps := S}) -> map_size(S).
snapshot_bytes(#{bytes := N}) -> N.
max_snaps() -> ?MAX_SNAPS.
max_bytes() -> ?MAX_BYTES.
page_limit() -> ?PAGE.
page_bytes() -> ?PAGE_BYTES.
cursor_limit() -> ?CURSOR.
max_total() -> ?MAX_TOTAL.
ttl_ms() -> ?TTL_MS.

view_id(#{<<"binding">> := #{<<"agentId">> := Id}}) when is_binary(Id) -> Id;
view_id(_) -> throw(invalid_schema).

pack(Views, TotalN, Epoch, Id, Rev, Wall, N, Deadline, Acc, Bytes) ->
    check(Deadline),
    {Take, Rest} = take_views(Views, Deadline, [], 0, 0),
    {B, Remaining} = fit(Take, Rest, TotalN, Epoch, Id, Rev, Wall, N, Deadline),
    Used = Bytes + byte_size(B),
    case Used =< ?MAX_BYTES of true -> ok; false -> throw(capacity) end,
    case Remaining of
        [] -> lists:reverse([B | Acc]);
        _ -> pack(Remaining, TotalN, Epoch, Id, Rev, Wall, N + 1, Deadline, [B | Acc], Used)
    end.

take_views([], _Deadline, Acc, _Count, _Bytes) -> {lists:reverse(Acc), []};
take_views(Rest, _Deadline, Acc, 128, _Bytes) -> {lists:reverse(Acc), Rest};
take_views([A | Rest] = All, Deadline, Acc, Count, Bytes) ->
    check(Deadline),
    Size = iolist_size(json:encode(A)) + 1,
    case Count > 0 andalso Bytes + Size > ?PAGE_BYTES - 1024 of
        true -> {lists:reverse(Acc), All};
        false -> take_views(Rest, Deadline, [A | Acc], Count + 1, Bytes + Size)
    end.

fit(Take, Rest, TotalN, Epoch, Id, Rev, Wall, N, Deadline) ->
    check(Deadline),
    Doc = #{
        <<"epoch">> => Epoch,
        <<"snapshotId">> => Id,
        <<"revision">> => integer_to_binary(Rev),
        <<"capturedAt">> => Wall,
        <<"page">> => N,
        <<"total">> => TotalN,
        <<"snapshots">> => Take,
        <<"nextCursor">> => case Rest of [] -> null; _ -> cursor(Id, N + 1) end
    },
    Encoded = iolist_to_binary(json:encode(Doc)),
    case byte_size(Encoded) =< ?PAGE_BYTES of
        true -> {Encoded, Rest};
        false when length(Take) > 1 ->
            {Init, [Last]} = lists:split(length(Take) - 1, Take),
            fit(Init, [Last | Rest], TotalN, Epoch, Id, Rev, Wall, N, Deadline);
        false -> throw(capacity)
    end.

cursor(Id, N) ->
    base64:encode(<<Id/binary, $:, (integer_to_binary(N))/binary>>,
        #{mode => urlsafe, padding => false}).

decode_cursor(C) when is_binary(C), byte_size(C) =< ?CURSOR, byte_size(C) > 0 ->
    try
        Raw = base64:decode(C, #{mode => urlsafe, padding => false}),
        case binary:split(Raw, <<$:>>) of
            [Id, Num] ->
                true = bus_protocol:is_uuid(Id),
                N = binary_to_integer(Num),
                true = N > 0 andalso N < 5000,
                true = Num =:= integer_to_binary(N),
                true = C =:= cursor(Id, N),
                {Id, N};
            _ -> throw(invalid_cursor)
        end
    catch
        throw:Reason -> throw(Reason);
        _:_ -> throw(invalid_cursor)
    end;
decode_cursor(_) -> throw(invalid_cursor).

check(Deadline) when is_integer(Deadline) ->
    case erlang:monotonic_time(millisecond) < Deadline of
        true -> ok;
        false -> throw(timeout)
    end;
check(_) -> throw(timeout).
