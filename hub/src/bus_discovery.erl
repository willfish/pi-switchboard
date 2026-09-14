-module(bus_discovery).
-export([new/0, record/4, page/6, pull/6, expire/2]).
-define(BYTES, 1048576).
-define(BUDGET, 268435456).

new() -> #{epoch => uuid(), revision => 0, http => undefined, baseline => undefined,
    journal => queue:new(), journal_index => #{}, journal_bytes => 0, journal_count => 0}.

expire(Now,D) ->
    D1 = trim(Now,D),
    lists:foldl(fun(Key,Acc) ->
        case maps:get(Key,Acc) of
            #{expires := E} when E =< Now -> Acc#{Key := undefined};
            _ -> Acc
        end
    end,D1,[http,baseline]).

record(Change, Now, _Wall, D0) ->
    R = maps:get(revision, D0) + 1,
    true = R =< 18446744073709551615,
    B = iolist_size(json:encode(Change)),
    Index = maps:get(journal_index,D0),
    %% The queue owns eviction order and scalar accounting; the revision index
    %% owns immutable changes and permits bounded direct delta selection.
    trim(Now, D0#{revision := R, journal := queue:in({R, Now, B}, maps:get(journal, D0)),
        journal_index := Index#{R => {R,Now,B,Change}},
        journal_bytes := maps:get(journal_bytes, D0) + B, journal_count := maps:get(journal_count,D0)+1}).

trim(Now, D) ->
    Q = maps:get(journal, D),
    case queue:peek(Q) of
        {value, {R, T, B}} ->
            case T + 30 =< Now orelse maps:get(journal_count,D) > 8192 orelse maps:get(journal_bytes, D) > 67108864 of
                true ->
                    {_, Q1} = queue:out(Q),
                    trim(Now, D#{journal := Q1,
                        journal_index := maps:remove(R,maps:get(journal_index,D)),
                        journal_bytes := maps:get(journal_bytes,D)-B,
                        journal_count := maps:get(journal_count,D)-1});
                false -> D
            end;
        empty -> D
    end.

page(Cursor, Agents, Now, Wall, Deadline, D) ->
    try
        check(Deadline),
        case Cursor of
            first ->
                S0 = maps:get(http,D),
                S = case valid(S0, Now, D) of true -> S0; false -> capture(http, Agents, Now, Wall, Deadline, D) end,
                check(Deadline),
                {{ok, element(1,maps:get(frames,S))}, D#{http := S}};
            _ ->
                {Id, Index} = decode_cursor(Cursor),
                S = maps:get(http,D),
                case valid(S,Now,D) andalso maps:get(id,S) =:= Id of
                    false -> throw(discovery_reset);
                    true ->
                        Frames = maps:get(frames,S),
                        case Index > 0 andalso Index < tuple_size(Frames) of
                            true -> {{ok,element(Index+1,Frames)},D};
                            false -> throw(invalid_cursor)
                        end
                end
        end
    catch throw:Reason -> {{error,Reason},D} end.

valid(undefined, _, _) -> false;
valid(S, Now, D) -> maps:get(expires,S) > Now andalso maps:get(revision,S) =:= maps:get(revision,D).

capture(Kind, Source, Now, Wall, Deadline, D) ->
    check(Deadline),
    Agents = case is_function(Source,0) of true -> Source(); false -> Source end,
    check(Deadline),
    case length(Agents) =< 5000 of true -> ok; false -> throw(capacity) end,
    Sorted = lists:sort(fun(A,B) -> maps:get(<<"agentId">>,A) < maps:get(<<"agentId">>,B) end,Agents),
    Id = uuid(),
    Base = #{<<"epoch">> => maps:get(epoch,D), <<"revision">> => integer_to_binary(maps:get(revision,D)),
        <<"snapshotId">> => Id, <<"capturedAt">> => Wall, <<"total">> => length(Agents)},
    Frames = pack(Kind, Sorted, Base, Id, 0, Deadline, [], 0),
    check(Deadline),
    #{id => Id, revision => maps:get(revision,D), expires => Now+30, frames => list_to_tuple(Frames)}.

pack(Kind, Agents, Base, Id, N, Deadline, Acc, Bytes) ->
    check(Deadline),
    {Take, Rest} = take_agents(Agents, Deadline, [], 0, 0),
    {B, Remaining} = fit(Kind, Take, Rest, Base, Id, N, Deadline),
    Total = Bytes + byte_size(B),
    case Total =< ?BUDGET of true -> ok; false -> throw(capacity) end,
    case Remaining of [] -> lists:reverse([B|Acc]); _ -> pack(Kind,Remaining,Base,Id,N+1,Deadline,[B|Acc],Total) end.

%% Reserve bounded envelope space before encoding a candidate page. This
%% avoids repeatedly constructing oversized prefixes for large records.
take_agents([], _Deadline, Acc, _Count, _Bytes) -> {lists:reverse(Acc),[]};
take_agents(Rest, _Deadline, Acc, 128, _Bytes) -> {lists:reverse(Acc),Rest};
take_agents([A|Rest] = All, Deadline, Acc, Count, Bytes) ->
    check(Deadline),
    Size = iolist_size(json:encode(A))+1,
    case Count > 0 andalso Bytes+Size > ?BYTES-1024 of
        true -> {lists:reverse(Acc),All};
        false -> take_agents(Rest,Deadline,[A|Acc],Count+1,Bytes+Size)
    end.

fit(Kind, Take, Rest, Base, Id, N, Deadline) ->
    check(Deadline),
    Doc = case Kind of
        http -> Base#{<<"page">> => N, <<"agents">> => Take, <<"nextCursor">> => case Rest of [] -> null; _ -> cursor(Id,N+1) end};
        baseline -> Base#{<<"chunk">> => N, <<"agents">> => Take, <<"final">> => Rest =:= []}
    end,
    B = iolist_to_binary(json:encode(Doc)),
    Limit = case Kind of http -> ?BYTES; baseline -> ?BYTES - 34 end,
    case byte_size(B) =< Limit of
        true -> {B,Rest};
        false when length(Take) > 1 -> {Init,[Last]} = lists:split(length(Take)-1,Take), fit(Kind,Init,[Last|Rest],Base,Id,N,Deadline);
        false -> throw(capacity)
    end.

pull(Progress, Agents, Now, Wall, Deadline, D0) ->
    D = trim(Now,D0),
    try
        check(Deadline),
        Result = pull1(Progress,Agents,Now,Wall,Deadline,D),
        %% Publish progress and candidate state only within the caller's budget.
        check(Deadline),
        Result
    catch throw:Reason -> {{error,Reason},Progress,D0} end.

pull1(start, Agents, Now, Wall, Deadline, D) ->
    S0 = maps:get(baseline,D),
    S = case S0 =/= undefined andalso maps:get(expires,S0) > Now andalso covered(maps:get(revision,S0),D) of
        true -> S0; false -> capture(baseline,Agents,Now,Wall,Deadline,D)
    end,
    check(Deadline),
    pull1({snapshot,maps:get(id,S),0},Agents,Now,Wall,Deadline,D#{baseline := S});
pull1({snapshot,Id,N}, _Agents, Now, _Wall, _Deadline, D) ->
    S = maps:get(baseline,D),
    case S =/= undefined andalso maps:get(id,S) =:= Id andalso maps:get(expires,S) > Now of
        false -> reset(<<"snapshot_expired">>,D);
        true ->
            case covered(maps:get(revision,S),D) of
                false -> reset(<<"history_lost">>,D);
                true ->
                    Frames = maps:get(frames,S),
                    Next = case N+1 =:= tuple_size(Frames) of true -> {delta,maps:get(revision,S),true}; false -> {snapshot,Id,N+1} end,
                    {{frame,<<"presence_snapshot">>,element(N+1,Frames),true},Next,D}
            end
    end;
pull1({delta,R,Force}, _Agents, _Now, _Wall, Deadline, D) ->
    case covered(R,D) of
        false -> reset(<<"history_lost">>,D);
        true ->
            Current = maps:get(revision,D),
            case R =:= Current andalso not Force of
                true -> {empty,{delta,R,false},D};
                false ->
                    Index = maps:get(journal_index,D),
                    Entries = [maps:get(Rev,Index) || Rev <- lists:seq(R+1,min(R+128,Current))],
                    {B,To} = delta_fit(Entries,R,D,Deadline),
                    {{frame,<<"presence_delta">>,B,To < Current},{delta,To,false},D}
            end
    end.

covered(R,D) ->
    case queue:peek(maps:get(journal,D)) of
        empty -> R =:= maps:get(revision,D);
        {value,{First,_,_}} -> R >= First-1
    end.

reset(Reason,D) ->
    B = iolist_to_binary(json:encode(#{<<"epoch">> => maps:get(epoch,D), <<"reason">> => Reason})),
    {{frame,<<"presence_reset">>,B,true},start,D}.

delta_fit(Entries,R,D,Deadline) ->
    check(Deadline),
    Changes = lists:foldl(fun({Rev,_,_,C},Acc) ->
        Id = case C of #{<<"agentId">> := X} -> X; #{<<"agent">> := A} -> maps:get(<<"agentId">>,A) end,
        Acc#{Id => {Rev,C}}
    end,#{},Entries),
    To = case Entries of [] -> R; _ -> element(1,lists:last(Entries)) end,
    B = iolist_to_binary(json:encode(#{<<"epoch">> => maps:get(epoch,D), <<"fromRevision">> => integer_to_binary(R),
        <<"toRevision">> => integer_to_binary(To), <<"caughtUp">> => To =:= maps:get(revision,D),
        <<"changes">> => [C || {_,C} <- lists:sort(maps:values(Changes))]})),
    check(Deadline),
    case byte_size(B)+31 =< ?BYTES of
        true -> {B,To};
        false when length(Entries)>1 -> delta_fit(lists:droplast(Entries),R,D,Deadline);
        false -> throw(capacity)
    end.

cursor(Id,N) -> base64:encode(<<Id/binary,":",(integer_to_binary(N))/binary>>,#{mode => urlsafe,padding => false}).
decode_cursor(C) when is_binary(C), byte_size(C) =< 64 ->
    try
        Raw = base64:decode(C,#{mode => urlsafe,padding => false}),
        [Id,Num] = binary:split(Raw,<<":">>),
        true = bus_protocol:is_uuid(Id),
        N = binary_to_integer(Num),
        true = N > 0 andalso N < 5000,
        C = cursor(Id,N),
        {Id,N}
    catch _:_ -> throw(invalid_cursor) end;
decode_cursor(_) -> throw(invalid_cursor).

check(Deadline) -> case erlang:monotonic_time(millisecond) < Deadline of true -> ok; false -> throw(timeout) end.
uuid() ->
    <<A:32,B:16,_:4,C:12,_:2,E:14,F:48>> = crypto:strong_rand_bytes(16),
    iolist_to_binary(io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",[A,B,C bor 16#4000,E bor 16#8000,F])).
