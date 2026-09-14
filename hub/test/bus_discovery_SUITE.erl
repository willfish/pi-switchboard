-module(bus_discovery_SUITE).
-export([all/0, init_per_testcase/2, end_per_testcase/2,
    page_shape/1, paged_traversal/1, changed_traversal/1, heartbeat_traversal/1,
    invalid_queries/1, incremental_presence/1, chunked_barriers/1]).

-define(A, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
all() -> [page_shape, paged_traversal, changed_traversal, heartbeat_traversal,
          invalid_queries, incremental_presence, chunked_barriers].
init_per_testcase(_, C) -> bus_http_SUITE:init_per_suite(C).
end_per_testcase(_, C) -> bus_http_SUITE:end_per_suite(C).

page_shape(C) ->
    {200, Empty} = page(C, first),
    [<<"agents">>, <<"capturedAt">>, <<"epoch">>, <<"nextCursor">>, <<"page">>,
     <<"revision">>, <<"snapshotId">>, <<"total">>] = lists:sort(maps:keys(Empty)),
    #{<<"agents">> := [], <<"page">> := 0, <<"total">> := 0,
      <<"nextCursor">> := null, <<"revision">> := <<"0">>} = Empty,
    true = bus_protocol:is_uuid(maps:get(<<"epoch">>, Empty)),
    true = bus_protocol:is_uuid(maps:get(<<"snapshotId">>, Empty)).

paged_traversal(C) ->
    _ = populate(C, 150),
    {200, First} = page(C, first),
    #{<<"agents">> := Agents, <<"page">> := 0, <<"total">> := 151,
      <<"nextCursor">> := Cursor} = First,
    128 = length(Agents), true = is_binary(Cursor), true = byte_size(Cursor) =< 64,
    {200, Last} = page(C, Cursor),
    #{<<"agents">> := Rest, <<"page">> := 1, <<"nextCursor">> := null} = Last,
    lists:foreach(fun(K) ->
        V = maps:get(K, First), V = maps:get(K, Last)
    end, [<<"epoch">>, <<"revision">>, <<"snapshotId">>, <<"capturedAt">>, <<"total">>]),
    Ids = [maps:get(<<"agentId">>, A) || A <- Agents ++ Rest],
    151 = length(Ids), Ids = lists:usort(Ids).

changed_traversal(C) ->
    A = populate(C, 150),
    {200, First} = page(C, first),
    ok = bus_store:put_agent(A#{<<"label">> := <<"changed while reading">>}),
    {409, #{<<"error">> := #{<<"code">> := <<"discovery_reset">>}}} =
        page(C, maps:get(<<"nextCursor">>, First)),
    {200, New} = page(C, first),
    true = maps:get(<<"snapshotId">>, New) =/= maps:get(<<"snapshotId">>, First).

heartbeat_traversal(C) ->
    A = populate(C, 150),
    {ok, All} = bus_store:list_agents(),
    [Before] = [X || #{<<"agentId">> := ?A} = X <- All],
    {200, First} = page(C, first),
    timer:sleep(1100),
    ok = bus_store:put_agent(A),
    {200, Last} = page(C, maps:get(<<"nextCursor">>, First)),
    Revision = maps:get(<<"revision">>, First), Revision = maps:get(<<"revision">>, Last),
    [Frozen] = [X || #{<<"agentId">> := ?A} = X <- maps:get(<<"agents">>, Last)],
    Stamp = maps:get(<<"updatedAt">>, Before), Stamp = maps:get(<<"updatedAt">>, Frozen).

invalid_queries(C) ->
    lists:foreach(fun(Path) ->
        {400, _} = bus_http_SUITE:get(C, Path, bus_http_SUITE:auth()),
        {401, _} = bus_http_SUITE:get(C, Path, [])
    end, ["/v1/agents?unknown=x", "/v1/agents?cursor=one&cursor=two",
          "/v1/agents?cursor=", "/v1/agents?cursor=%00",
          "/v1/agents?cursor=" ++ lists:duplicate(65, $x),
          "/v1/events?agentId=invalid", "/v1/events?agentId=%ff",
          "/v1/events?agentId=" ++ binary_to_list(?A) ++ "&agentId=" ++ binary_to_list(?A),
          "/v1/events?agentId=" ++ binary_to_list(?A) ++ "&unknown=x"]).

incremental_presence(C) ->
    A = populate(C, 1),
    Port = proplists:get_value(port, C),
    {ok, S} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active,false}]),
    try
        ok = gen_tcp:send(S, ["GET /v1/events?agentId=", ?A,
            " HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ct-token\r\n\r\n"]),
        D = erlang:monotonic_time(millisecond) + 5000,
        R0 = bus_sse_client:open(S, D),
        R1 = bus_sse_client:until(S, R0, fun(R) ->
            lists:any(fun(M) -> maps:get(<<"caughtUp">>, M) end,
                bus_sse_client:json_events(R, <<"presence_delta">>))
        end, D),
        [#{<<"final">> := true, <<"agents">> := [_, _]}] =
            bus_sse_client:json_events(R1, <<"presence_snapshot">>),
        Deltas = bus_sse_client:json_events(R1, <<"presence_delta">>),
        Previous = maps:get(<<"toRevision">>, lists:last(Deltas)),
        Count = length(Deltas),
        ok = bus_store:put_agent(A#{<<"label">> := <<"incremental change">>}),
        R2 = bus_sse_client:until(S, R1, fun(R) ->
            length(bus_sse_client:json_events(R, <<"presence_delta">>)) > Count
        end, D),
        [Delta] = lists:nthtail(Count, bus_sse_client:json_events(R2, <<"presence_delta">>)),
        Previous = maps:get(<<"fromRevision">>, Delta),
        [#{<<"op">> := <<"upsert">>, <<"agent">> :=
            #{<<"agentId">> := ?A, <<"label">> := <<"incremental change">>}}] =
            maps:get(<<"changes">>, Delta),
        1 = length(bus_sse_client:json_events(R2, <<"presence_snapshot">>))
    after gen_tcp:close(S) end.

chunked_barriers(C) ->
    _ = populate(C, 130),
    {ok, All} = bus_store:list_agents(),
    Cwd = <<"/", (binary:copy(<<"\\">>, 4095))/binary>>,
    lists:foreach(fun(Public) ->
        Doc = (maps:without([<<"updatedAt">>, <<"receiving">>], Public))#{<<"cwd">> := Cwd},
        {ok, Valid} = bus_protocol:decode_register(Doc),
        ok = bus_store:put_agent(Valid)
    end, All),
    {200, First} = page(C, first),
    true = length(maps:get(<<"agents">>, First)) < 128,
    {200, Last} = page(C, maps:get(<<"nextCursor">>, First)),
    null = maps:get(<<"nextCursor">>, Last),
    131 = length(maps:get(<<"agents">>, First)) + length(maps:get(<<"agents">>, Last)),
    erlang:trace_pattern({bus_deadline_stream, events, 2}, true, [local]),
    erlang:trace(new, true, [call, {tracer, self()}]),
    try
        with_stream(C, fun(S, R0, D) ->
            R = bus_sse_client:until(S, R0, fun(X) ->
                bus_sse_client:has_event(X, <<"presence_delta">>)
            end, D),
            [#{<<"chunk">> := 0, <<"final">> := false} = One,
             #{<<"chunk">> := 1, <<"final">> := true} = Two] =
                bus_sse_client:json_events(R, <<"presence_snapshot">>),
            lists:foreach(fun(K) -> V = maps:get(K, One), V = maps:get(K, Two) end,
                [<<"epoch">>, <<"revision">>, <<"snapshotId">>, <<"capturedAt">>, <<"total">>]),
            131 = length(maps:get(<<"agents">>, One)) + length(maps:get(<<"agents">>, Two)),
            lists:foreach(fun(Frame) -> true = byte_size(Frame) + 2 =< 1048576 end,
                maps:get(frames, R)),
            Ref = erlang:trace_delivered(all),
            receive {trace_delivered, all, Ref} -> ok after 1000 -> error(trace_timeout) end,
            [<<"presence_snapshot">>, <<"presence_snapshot">>, <<"presence_delta">>] =
                barrier_calls([])
        end)
    after
        erlang:trace(new, false, [call]),
        erlang:trace(all, false, [call]),
        erlang:trace_pattern({bus_deadline_stream, events, 2}, false, [local])
    end.

barrier_calls(Acc) ->
    receive
        {trace, _, call, {bus_deadline_stream, events, [#{event := Event}, _]}} ->
            barrier_calls([Event | Acc]);
        {trace, _, call, {bus_deadline_stream, events, _}} ->
            error(unexpected_event_batch)
    after 0 -> lists:reverse(Acc) end.

with_stream(C, Fun) ->
    {ok, S} = gen_tcp:connect({127,0,0,1}, proplists:get_value(port, C),
        [binary, {active,false}]),
    try
        ok = gen_tcp:send(S, ["GET /v1/events?agentId=", ?A,
            " HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ct-token\r\n\r\n"]),
        D = erlang:monotonic_time(millisecond) + 5000,
        Fun(S, bus_sse_client:open(S, D), D)
    after gen_tcp:close(S) end.

populate(C, N) ->
    {204, _} = bus_http_SUITE:put_agent(C, ?A, false),
    {ok, [Public]} = bus_store:list_agents(),
    A = maps:without([<<"updatedAt">>, <<"receiving">>], Public),
    lists:foreach(fun(I) ->
        Id = iolist_to_binary(io_lib:format("00000000-0000-4000-8000-~12.16.0b", [I])),
        ok = bus_store:put_agent(A#{<<"agentId">> := Id})
    end, lists:seq(1, N)),
    A.

page(C, Cursor) ->
    Path = case Cursor of first -> "/v1/agents";
        _ -> "/v1/agents?cursor=" ++ binary_to_list(Cursor) end,
    {Status, Body} = bus_http_SUITE:get(C, Path, bus_http_SUITE:auth()),
    true = byte_size(Body) =< 1048576,
    {ok, Page} = bus_protocol:decode_json(Body),
    {Status, Page}.
