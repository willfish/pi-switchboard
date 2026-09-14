-module(bus_capacity_SUITE).
-export([all/0, init_per_testcase/2, end_per_testcase/2,
    complete_population/1, shared_baseline_resync/1, replaced_baseline_resync/1]).

all() -> [complete_population, shared_baseline_resync, replaced_baseline_resync].
init_per_testcase(_, C) -> bus_http_SUITE:init_per_suite(C).
end_per_testcase(_, C) -> bus_http_SUITE:end_per_suite(C).

%% One receive connection and 5,000 valid records, not a connection benchmark.
complete_population(C) ->
    Docs = populate(5000),
    {Pages, HttpAgents} = traverse(C,first,undefined,0,[],[],0),
    true = Pages > 1,
    assert_population(Docs,HttpAgents),
    %% Refresh only timestamps before the separate SSE traversal.
    lists:foreach(fun(A) -> ok = bus_store:put_agent(A) end,Docs),
    with_stream(C,id(1),fun(S,R0) ->
        R = caught_up(S,R0),
        Snapshots = bus_sse_client:json_events(R,<<"presence_snapshot">>),
        true = length(Snapshots) > 1,
        assert_snapshot(Docs,Snapshots),
        assert_frames(R),
        assert_caught_up(Snapshots,R)
    end).

shared_baseline_resync(C) -> baseline_resync(C, both_reset_before_capture).
replaced_baseline_resync(C) -> baseline_resync(C, capture_before_second_reset).

baseline_resync(C, Schedule) ->
    Docs = populate(129),
    Parent = self(),
    Ids = [id(1),id(2)],
    %% Suspend callers, not the store: each pull completes but its reply cannot
    %% be consumed until the chosen schedule releases that exact handler.
    PauseCount = case Schedule of both_reset_before_capture -> 2; capture_before_second_reset -> 1 end,
    Hook = fun(Seen,{in,{'$gen_call',{Pid,_},{op,_,{subscription,Id,_,pull_presence}}}},_) ->
            N = maps:get(Id,Seen,0)+1,
            case lists:member(Id,Ids) andalso N =< PauseCount of
                true ->
                    true = erlang:suspend_process(Pid),
                    Parent ! {capacity_paused,Id,Pid},
                    Seen#{Id => N};
                false -> Seen
            end;
        (Seen,_,_) -> Seen
    end,
    put(capacity_paused,[]),
    ok = sys:install(bus_store,{Hook,#{}}),
    try
        with_stream(C,id(1),fun(S1,R1) ->
            P1 = paused(id(1)),
            with_stream(C,id(2),fun(S2,R2) ->
                P2 = paused(id(2)),
                State = sys:get_state(bus_store),
                Baseline = maps:get(baseline,maps:get(discovery,State)),
                BaselineId = maps:get(id,Baseline),
                Subs = maps:get(subs,State),
                lists:foreach(fun(Id) ->
                    Sub = maps:get(Id,Subs),
                    [mail_wake,mon,pid,presence_wake,progress,ref] = lists:sort(maps:keys(Sub)),
                    {snapshot,BaselineId,1} = maps:get(progress,Sub),
                    true = maps:get(presence_wake,Sub)
                end,Ids),
                {_,Http1} = page(C,first),
                Changed = (lists:nth(3,Docs))#{<<"label">> := <<"http replacement">>},
                ok = bus_store:put_agent(Changed),
                {_,Http2} = page(C,first),
                true = maps:get(<<"snapshotId">>,Http1) =/= maps:get(<<"snapshotId">>,Http2),
                AfterHttp = sys:get_state(bus_store),
                Baseline = maps:get(baseline,maps:get(discovery,AfterHttp)),
                %% Exceed the journal entry budget without waiting out presence
                %% TTL or baseline lifetime. Every update is meaningful.
                Start = erlang:monotonic_time(millisecond),
                lists:foreach(fun(N) ->
                    ok = bus_store:put_agent(Changed#{<<"label">> := integer_to_binary(N)})
                end,lists:seq(1,8193)),
                true = erlang:monotonic_time(millisecond)-Start < 10000,
                Lost = sys:get_state(bus_store),
                129 = map_size(maps:get(agents,maps:get(model,Lost))),
                {snapshot,BaselineId,1} = maps:get(progress,maps:get(id(1),maps:get(subs,Lost))),
                {snapshot,BaselineId,1} = maps:get(progress,maps:get(id(2),maps:get(subs,Lost))),
                %% No reconnect: both schedules retain the original streams.
                {End1,End2,Reason2} = case Schedule of
                    both_reset_before_capture ->
                        resume_handlers([P1,P2]),
                        P1 = paused(id(1)),
                        P2 = paused(id(2)),
                        %% The system call fences completion of both second
                        %% pulls. Neither caller can request a new baseline yet.
                        ResetState = sys:get_state(bus_store),
                        Baseline = maps:get(baseline,maps:get(discovery,ResetState)),
                        lists:foreach(fun(Id) ->
                            start = maps:get(progress,maps:get(Id,maps:get(subs,ResetState)))
                        end,Ids),
                        resume_handlers([P1,P2]),
                        {caught_up(S1,R1),caught_up(S2,R2),<<"history_lost">>};
                    capture_before_second_reset ->
                        resume_handlers([P1]),
                        Fresh1 = caught_up(S1,R1),
                        Replaced = sys:get_state(bus_store),
                        FreshBaseline = maps:get(baseline,maps:get(discovery,Replaced)),
                        true = maps:get(id,FreshBaseline) =/= BaselineId,
                        {snapshot,BaselineId,1} = maps:get(progress,
                            maps:get(id(2),maps:get(subs,Replaced))),
                        %% Only now let the old second cursor encounter the
                        %% replacement ID, rather than race the first reset.
                        resume_handlers([P2]),
                        {Fresh1,caught_up(S2,R2),<<"snapshot_expired">>}
                end,
                Expected = [case maps:get(<<"agentId">>,A) of
                    Id when Id =:= map_get(<<"agentId">>,Changed) -> A#{<<"label">> := <<"8193">>};
                    _ -> A
                end || A <- Docs],
                lists:foreach(fun({R,Reason}) ->
                    assert_frames(R),
                    [#{<<"reason">> := Reason}] =
                        bus_sse_client:json_events(R,<<"presence_reset">>),
                    %% The suspended first chunk precedes reset; only the new
                    %% generation after reset may constitute the committed list.
                    [Old|New] = bus_sse_client:json_events(R,<<"presence_snapshot">>),
                    BaselineId = maps:get(<<"snapshotId">>,Old),
                    false = maps:get(<<"final">>,Old),
                    true = maps:get(<<"snapshotId">>,hd(New)) =/= BaselineId,
                    assert_snapshot(Expected,New),
                    assert_caught_up(New,R),
                    [<<"presence_snapshot">>,<<"presence_reset">>,
                     <<"presence_snapshot">>,<<"presence_snapshot">>,<<"presence_delta">>] = event_names(R)
                end,[{End1,<<"history_lost">>},{End2,Reason2}]),
                FinalSubs = maps:get(subs,sys:get_state(bus_store)),
                P1 = maps:get(pid,maps:get(id(1),FinalSubs)),
                P2 = maps:get(pid,maps:get(id(2),FinalSubs))
            end)
        end)
    after
        catch sys:remove(bus_store,Hook),
        resume_safely(erase(capacity_paused)),
        resume_pending()
    end.

resume_handlers(Pids) ->
    _ = sys:replace_state(bus_store,fun(State) ->
        lists:foreach(fun(Pid) -> true = erlang:resume_process(Pid) end,Pids),
        State
    end),
    ok.

paused(Id) ->
    receive {capacity_paused,Id,Pid} ->
        put(capacity_paused,[Pid|get(capacity_paused)]), Pid
    after 5000 -> error(handler_pause_timeout) end.

resume_pending() ->
    receive {capacity_paused,_,Pid} -> resume_safely([Pid]), resume_pending()
    after 0 -> ok end.

resume_safely(Pids) ->
    %% Suspensions are owned by the store process that installed them.
    catch sys:replace_state(bus_store,fun(State) ->
        lists:foreach(fun(Pid) -> catch erlang:resume_process(Pid) end,Pids),
        State
    end),
    ok.

populate(N) ->
    Base = #{<<"agentId">> => id(1), <<"sessionId">> => id(1),
        <<"host">> => <<"capacity-fixture">>, <<"cwd">> => <<"/tmp/capacity-fixture">>,
        <<"sessionName">> => <<"Capacity fixture">>, <<"label">> => <<"Population traversal">>,
        <<"model">> => #{<<"provider">> => <<"test">>, <<"id">> => <<"test-model">>},
        <<"status">> => <<"idle">>, <<"pid">> => 1, <<"acceptsControl">> => false},
    [begin
        {ok,A} = bus_protocol:decode_register(Base#{<<"agentId">> := id(I)}),
        ok = bus_store:put_agent(A),
        A
    end || I <- lists:seq(1,N)].

id(I) -> iolist_to_binary(io_lib:format("00000000-0000-4000-8000-~12.16.0b",[I])).

page(C,Cursor) ->
    Path = case Cursor of first -> "/v1/agents"; _ -> "/v1/agents?cursor=" ++ binary_to_list(Cursor) end,
    {200,Body} = bus_http_SUITE:get(C,Path,bus_http_SUITE:auth()),
    true = byte_size(Body) =< 1048576,
    {ok,Doc} = bus_protocol:decode_json(Body),
    {byte_size(Body),Doc}.

traverse(C,Cursor,Base,N,Chunks,Seen,Bytes) ->
    {Size,P} = page(C,Cursor),
    [<<"agents">>,<<"capturedAt">>,<<"epoch">>,<<"nextCursor">>,<<"page">>,
     <<"revision">>,<<"snapshotId">>,<<"total">>] = lists:sort(maps:keys(P)),
    N = maps:get(<<"page">>,P),
    Agents = maps:get(<<"agents">>,P),
    true = length(Agents) =< 128,
    true = Bytes+Size =< 268435456,
    Fixed = maps:with([<<"epoch">>,<<"revision">>,<<"snapshotId">>,<<"capturedAt">>,<<"total">>],P),
    case Base of undefined -> ok; _ -> Base = Fixed end,
    case maps:get(<<"nextCursor">>,P) of
        null ->
            All = lists:append(lists:reverse([Agents|Chunks])),
            Total = length(All),
            Total = maps:get(<<"total">>,P),
            {N+1,All};
        Next ->
            true = is_binary(Next),
            true = byte_size(Next) =< 64,
            false = lists:member(Next,Seen),
            true = N < 5000,
            traverse(C,Next,Fixed,N+1,[Agents|Chunks],[Next|Seen],Bytes+Size)
    end.

with_stream(C,Id,Fun) ->
    {ok,S} = gen_tcp:connect({127,0,0,1},proplists:get_value(port,C),[binary,{active,false}]),
    try
        ok = gen_tcp:send(S,["GET /v1/events?agentId=",Id,
            " HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ct-token\r\n\r\n"]),
        R = bus_sse_client:open(S,erlang:monotonic_time(millisecond)+5000),
        Fun(S,R)
    after gen_tcp:close(S) end.

caught_up(S,R) ->
    bus_sse_client:until(S,R,fun(X) ->
        lists:any(fun(D) -> maps:get(<<"caughtUp">>,D) end,
            bus_sse_client:json_events(X,<<"presence_delta">>))
    end,erlang:monotonic_time(millisecond)+5000).

assert_population(Expected,Actual) ->
    Ids = [maps:get(<<"agentId">>,A) || A <- Actual],
    Ids = lists:usort(Ids),
    Ids = [maps:get(<<"agentId">>,A) || A <- Expected],
    Expected = [begin
        true = is_integer(maps:get(<<"updatedAt">>,A)),
        true = is_boolean(maps:get(<<"receiving">>,A)),
        {ok,Valid} = bus_protocol:decode_register(maps:without([<<"updatedAt">>,<<"receiving">>],A)),
        Valid
    end || A <- Actual].

assert_snapshot(Expected,Snapshots) ->
    Fixed = maps:with([<<"epoch">>,<<"revision">>,<<"snapshotId">>,<<"capturedAt">>,<<"total">>],hd(Snapshots)),
    Total = length(Expected),
    Total = maps:get(<<"total">>,Fixed),
    lists:foreach(fun({N,S}) ->
        [<<"agents">>,<<"capturedAt">>,<<"chunk">>,<<"epoch">>,<<"final">>,
         <<"revision">>,<<"snapshotId">>,<<"total">>] = lists:sort(maps:keys(S)),
        Fixed = maps:with(maps:keys(Fixed),S),
        N = maps:get(<<"chunk">>,S),
        true = length(maps:get(<<"agents">>,S)) =< 128,
        Final = N =:= length(Snapshots)-1,
        Final = maps:get(<<"final">>,S)
    end,lists:zip(lists:seq(0,length(Snapshots)-1),Snapshots)),
    assert_population(Expected,lists:append([maps:get(<<"agents">>,S) || S <- Snapshots])).

assert_frames(#{frames := Frames}) ->
    lists:foreach(fun(F) -> true = byte_size(F)+2 =< 1048576 end,Frames),
    true = lists:sum([byte_size(F)+2 || F <- Frames]) =< 268435456.

assert_caught_up(Snapshots,R) ->
    [Delta] = bus_sse_client:json_events(R,<<"presence_delta">>),
    true = maps:get(<<"caughtUp">>,Delta),
    Revision = maps:get(<<"revision">>,hd(Snapshots)),
    Revision = maps:get(<<"fromRevision">>,Delta),
    Revision = maps:get(<<"toRevision">>,Delta),
    [] = maps:get(<<"changes">>,Delta).

event_names(#{frames := Frames}) ->
    [maps:get(event_type,E) || F <- Frames,
        {event,E,_} <- [cow_sse:parse(<<F/binary,"\n\n">>,cow_sse:init())]].
