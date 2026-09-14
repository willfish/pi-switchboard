-module(bus_discovery_tests).
-include_lib("eunit/include/eunit.hrl").

pages_test() ->
    D = bus_discovery:new(),
    Agents = [#{<<"agentId">> => integer_to_binary(N)} || N <- lists:seq(1, 129)],
    Deadline = erlang:monotonic_time(millisecond) + 5000,
    {{ok, B}, D1} = bus_discovery:page(first, Agents, 0, 10, Deadline, D),
    P = json:decode(B),
    ?assertEqual(128, length(maps:get(<<"agents">>, P))),
    C = maps:get(<<"nextCursor">>, P),
    {{ok, B2}, _} = bus_discovery:page(C, Agents, 0, 11, Deadline, D1),
    ?assertEqual(1, length(maps:get(<<"agents">>, json:decode(B2)))),
    ?assertMatch({{error, discovery_reset}, _}, bus_discovery:page(C, Agents, 30, 11, Deadline, D1)),
    ?assertMatch({{error, invalid_cursor}, _}, bus_discovery:page(<<"bad">>, Agents, 0, 11, Deadline, D1)).

journal_and_baseline_test() ->
    DL = erlang:monotonic_time(millisecond)+5000,
    A = #{<<"agentId">> => <<"a">>, <<"label">> => <<"original">>},
    Up = fun(Agent) -> #{<<"op">> => <<"upsert">>, <<"agent">> => Agent} end,
    D = bus_discovery:record(Up(A),0,0,bus_discovery:new()),
    {{frame,<<"presence_snapshot">>,B,true},P,D1} = bus_discovery:pull(start,[A],0,7,DL,D),
    ?assertEqual([A],maps:get(<<"agents">>,json:decode(B))),
    {{frame,<<"presence_delta">>,Equal,false},P1,D2} = bus_discovery:pull(P,[],0,7,DL,D1),
    ?assertEqual([],maps:get(<<"changes">>,json:decode(Equal))),
    ?assertMatch({empty,_,_},bus_discovery:pull(P1,[],0,7,DL,D2)),
    New = A#{<<"label">> := <<"new">>},
    D3 = bus_discovery:record(Up(New),1,8,D2),
    D4 = bus_discovery:record(#{<<"op">> => <<"remove">>, <<"agentId">> => <<"a">>},2,9,D3),
    {{frame,<<"presence_delta">>,Delta,false},_,_} = bus_discovery:pull(P1,[],2,9,DL,D4),
    Doc = json:decode(Delta),
    ?assertEqual(<<"3">>,maps:get(<<"toRevision">>,Doc)),
    ?assertEqual([#{<<"op">> => <<"remove">>, <<"agentId">> => <<"a">>}],maps:get(<<"changes">>,Doc)),
    {{frame,<<"presence_snapshot">>,Reused,true},_,_} = bus_discovery:pull(start,[],2,9,DL,D4),
    ?assertEqual(B,Reused),
    {{frame,<<"presence_reset">>,Reset,true},start,_} = bus_discovery:pull(P1,[],32,9,DL,D4),
    ?assertEqual(<<"history_lost">>,maps:get(<<"reason">>,json:decode(Reset))).

baseline_replacement_test() ->
    DL = erlang:monotonic_time(millisecond)+5000,
    Agents = [#{<<"agentId">> => integer_to_binary(N)} || N <- lists:seq(1,129)],
    {{frame,_,_,true},P,D} = bus_discovery:pull(start,Agents,0,0,DL,bus_discovery:new()),
    {{frame,_,_,true},_,D1} = bus_discovery:pull(start,Agents,30,0,DL,D),
    {{frame,<<"presence_reset">>,B,true},start,_} = bus_discovery:pull(P,[],30,0,DL,D1),
    ?assertEqual(<<"snapshot_expired">>,maps:get(<<"reason">>,json:decode(B))).

journal_limit_test() ->
    C = #{<<"op">> => <<"remove">>, <<"agentId">> => <<"a">>},
    D = lists:foldl(fun(_,Acc) -> bus_discovery:record(C,0,0,Acc) end,bus_discovery:new(),lists:seq(1,8193)),
    ?assertEqual(8192,queue:len(maps:get(journal,D))),
    DL = erlang:monotonic_time(millisecond)+5000,
    ?assertMatch({{frame,<<"presence_reset">>,_,true},start,_},bus_discovery:pull({delta,0,false},[],0,0,DL,D)),
    {{frame,<<"presence_delta">>,B,true},_,_} = bus_discovery:pull({delta,1,false},[],0,0,DL,D),
    ?assertEqual(<<"129">>,maps:get(<<"toRevision">>,json:decode(B))),
    ?assertEqual(1,length(maps:get(<<"changes">>,json:decode(B)))).

unfinished_snapshot_history_lost_test() ->
    DL = erlang:monotonic_time(millisecond)+5000,
    Agents = [#{<<"agentId">> => integer_to_binary(N)} || N <- lists:seq(1,129)],
    {{frame,<<"presence_snapshot">>,First,true},P,D0} =
        bus_discovery:pull(start,Agents,0,0,DL,bus_discovery:new()),
    ?assertEqual(false,maps:get(<<"final">>,json:decode(First))),
    C = #{<<"op">> => <<"remove">>, <<"agentId">> => <<"a">>},
    D = lists:foldl(fun(_,Acc) -> bus_discovery:record(C,1,1,Acc) end,D0,lists:seq(1,8193)),
    {{frame,Name,B,true},Next,D1} = bus_discovery:pull(P,[],1,1,DL,D),
    ?assertEqual(<<"presence_reset">>,Name),
    ?assertEqual(start,Next),
    ?assertEqual(<<"history_lost">>,maps:get(<<"reason">>,json:decode(B))),
    {{frame,<<"presence_snapshot">>,New,true},_,_} = bus_discovery:pull(start,Agents,1,1,DL,D1),
    ?assertEqual(<<"8193">>,maps:get(<<"revision">>,json:decode(New))).

bounded_delta_selection_test() ->
    C = #{<<"op">> => <<"remove">>, <<"agentId">> => <<"a">>},
    D = lists:foldl(fun(_,Acc) -> bus_discovery:record(C,0,0,Acc) end,bus_discovery:new(),lists:seq(1,8192)),
    DL = erlang:monotonic_time(millisecond)+5000,
    %% Delta selection must not materialize the eviction queue, even when full.
    1 = erlang:trace_pattern({queue,to_list,1},true,[call_count]),
    try
        {{frame,<<"presence_delta">>,B,true},{delta,128,false},_} =
            bus_discovery:pull({delta,0,false},[],0,0,DL,D),
        ?assertEqual(<<"128">>,maps:get(<<"toRevision">>,json:decode(B))),
        ?assertEqual({call_count,0},erlang:trace_info({queue,to_list,1},call_count))
    after
        erlang:trace_pattern({queue,to_list,1},false,[call_count])
    end.

journal_index_eviction_test() ->
    C = #{<<"op">> => <<"remove">>, <<"agentId">> => <<"a">>},
    D = lists:foldl(fun(_,Acc) -> bus_discovery:record(C,0,0,Acc) end,bus_discovery:new(),lists:seq(1,8193)),
    Index = maps:get(journal_index,D,#{}),
    ?assertEqual(8192,map_size(Index)),
    ?assertNot(maps:is_key(1,Index)),
    ?assertEqual(lists:seq(2,8193),lists:sort(maps:keys(Index))),
    assert_journal_index(D),
    D1 = bus_discovery:record(C,29,29,D),
    D2 = bus_discovery:expire(30,D1),
    ?assertEqual([8194],maps:keys(maps:get(journal_index,D2))),
    assert_journal_index(D2),
    D3 = bus_discovery:expire(59,D2),
    ?assertEqual(#{},maps:get(journal_index,D3)),
    assert_journal_index(D3).

delta_encoding_deadline_test() ->
    %% A synthetic oversized value isolates the post-encoding deadline guard
    %% from the next byte-fit iteration. Public schema limits remain unchanged.
    C = #{<<"op">> => <<"upsert">>, <<"agent">> => #{<<"agentId">> => <<"a">>,
        <<"label">> => binary:copy(<<"x">>,32*1024*1024)}},
    D = bus_discovery:record(C,0,0,bus_discovery:new()),
    P = {delta,0,false},
    DL = erlang:monotonic_time(millisecond)+5,
    {Reply,Next,D1} = bus_discovery:pull(P,[],0,0,DL,D),
    ?assert(erlang:monotonic_time(millisecond) >= DL),
    ?assertEqual({error,timeout},Reply),
    ?assert(Next =:= P),
    ?assert(D1 =:= D).

byte_packing_test() ->
    DL = erlang:monotonic_time(millisecond)+5000,
    Agents = [#{<<"agentId">> => integer_to_binary(N), <<"label">> => binary:copy(<<"x">>,10000)} || N <- lists:seq(1,128)],
    {{ok,B},D} = bus_discovery:page(first,Agents,0,0,DL,bus_discovery:new()),
    ?assert(byte_size(B) =< 1048576),
    ?assert(length(maps:get(<<"agents">>,json:decode(B))) < 128),
    {{frame,Name,S,true},_,_} = bus_discovery:pull(start,Agents,0,0,DL,D),
    ?assert(byte_size(S)+byte_size(Name)+16 =< 1048576).

delta_byte_prefix_test() ->
    DL = erlang:monotonic_time(millisecond)+5000,
    D = lists:foldl(fun(N,Acc) ->
        bus_discovery:record(#{<<"op">> => <<"upsert">>, <<"agent">> => #{<<"agentId">> => integer_to_binary(N),
            <<"label">> => binary:copy(<<"x">>,10000)}},0,0,Acc)
    end,bus_discovery:new(),lists:seq(1,128)),
    {{frame,<<"presence_delta">>,B,true},{delta,To,false},_} = bus_discovery:pull({delta,0,false},[],0,0,DL,D),
    ?assert(To < 128),
    ?assert(byte_size(B)+30 =< 1048576),
    ?assertEqual(To,length(maps:get(<<"changes">>,json:decode(B)))).

journal_byte_limit_test() ->
    C = #{<<"op">> => <<"upsert">>, <<"agent">> => #{<<"agentId">> => <<"a">>, <<"label">> => binary:copy(<<"x">>,900000)}},
    D = lists:foldl(fun(_,Acc) -> bus_discovery:record(C,0,0,Acc) end,bus_discovery:new(),lists:seq(1,76)),
    ?assert(maps:get(journal_bytes,D) =< 67108864),
    ?assert(maps:get(journal_count,D) < 76),
    assert_journal_index(D),
    Expired = bus_discovery:expire(30,D),
    ?assertEqual(0,maps:get(journal_count,Expired)),
    assert_journal_index(Expired).

assert_journal_index(D) ->
    Entries = queue:to_list(maps:get(journal,D)),
    Index = maps:get(journal_index,D),
    ?assertEqual([R || {R,_,_} <- Entries],lists:sort(maps:keys(Index))),
    ?assertEqual(length(Entries),maps:get(journal_count,D)),
    ?assertEqual(lists:sum([B || {_,_,B} <- Entries]),maps:get(journal_bytes,D)),
    lists:foreach(fun({R,T,B}) ->
        {R,T,B,C} = maps:get(R,Index),
        ?assertEqual(B,iolist_size(json:encode(C)))
    end,Entries).

snapshot_aggregate_limit_test_() ->
    {timeout,30,fun() ->
        Payload = binary:copy(<<"x">>,900000),
        Agents = [#{<<"agentId">> => integer_to_binary(N), <<"label">> => Payload} || N <- lists:seq(1,300)],
        D = bus_discovery:new(),
        ?assertEqual({{error,capacity},D},bus_discovery:page(first,Agents,0,0,erlang:monotonic_time(millisecond)+25000,D))
    end}.

cursor_fencing_test() ->
    DL = erlang:monotonic_time(millisecond)+5000,
    Agents = [#{<<"agentId">> => integer_to_binary(N)} || N <- lists:seq(1,129)],
    {{ok,B},D} = bus_discovery:page(first,Agents,0,0,DL,bus_discovery:new()),
    C = maps:get(<<"nextCursor">>,json:decode(B)),
    D1 = bus_discovery:record(#{<<"op">> => <<"remove">>,<<"agentId">> => <<"1">>},0,0,D),
    ?assertMatch({{error,discovery_reset},_},bus_discovery:page(C,Agents,0,0,DL,D1)),
    ?assertMatch({{error,discovery_reset},_},bus_discovery:page(C,Agents,0,0,DL,bus_discovery:new())),
    lists:foreach(fun(Bad) -> ?assertMatch({{error,invalid_cursor},_},bus_discovery:page(Bad,Agents,0,0,DL,D)) end,
        [<<C/binary,"=">>,binary:copy(<<"x">>,65),<<"">>,<<"g2gCZAAEZXZpbA">>]).

capture_deadline_publication_test() ->
    D = bus_discovery:new(),
    Source = fun() -> timer:sleep(10), [] end,
    ?assertEqual({{error,timeout},D},bus_discovery:page(first,Source,0,0,erlang:monotonic_time(millisecond)+5,D)),
    ?assertEqual({{error,timeout},start,D},bus_discovery:pull(start,Source,0,0,erlang:monotonic_time(millisecond)+5,D)).

expired_capture_test() ->
    D = bus_discovery:new(),
    ?assertEqual({{error, timeout}, D}, bus_discovery:page(first, [], 0, 0, erlang:monotonic_time(millisecond)-1, D)).
