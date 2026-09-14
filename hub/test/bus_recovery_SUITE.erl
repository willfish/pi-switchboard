%% Recovery and loss-boundary integration fixtures. Never part of the release.
-module(bus_recovery_SUITE).
-export([all/0, init_per_testcase/2, end_per_testcase/2,
    timer_only_expiry/1, sweep_under_traffic/1, coalesced_wakes/1,
    lost_post_response/1, interrupted_pop_write/1, failure_state_boundaries/1]).
%% The suite also supplies a gated transport for the real production routes.
-export([start_link/3, name/0, secure/0, messages/0, peername/1, sockname/1,
    setopts/2, send/2, shutdown/2, close/1]).

-define(A, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(B, <<"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb">>).
-define(C, <<"cccccccc-cccc-4ccc-8ccc-cccccccccccc">>).
-define(GATE, {?MODULE, send_gate}).

all() -> [timer_only_expiry, sweep_under_traffic, coalesced_wakes,
          lost_post_response, interrupted_pop_write, failure_state_boundaries].

init_per_testcase(_, C) ->
    Config = bus_http_SUITE:init_per_suite(C),
    try
        lists:foreach(fun(Id) -> {204, _} = bus_http_SUITE:put_agent(Config, Id, false) end,
                      [?A, ?B, ?C]),
        Config
    catch Class:Reason:Stack ->
        end_per_testcase(undefined, Config),
        erlang:raise(Class, Reason, Stack)
    end.
end_per_testcase(_, C) ->
    persistent_term:erase(?GATE),
    catch ranch:stop_listener(bus_recovery),
    catch erlang:trace(whereis(bus_store), false, [call]),
    erlang:trace_pattern({bus_store, handle_info, 2}, false, [local]),
    bus_http_SUITE:end_per_suite(C).

now_ms() -> erlang:monotonic_time(millisecond).
await(F) -> await(F, now_ms() + 2500).
await(F, D) ->
    case F() of
        true -> ok;
        false ->
            case now_ms() < D of
                true -> timer:sleep(5), await(F, D);
                false -> error(recovery_condition_deadline)
            end
    end.
state() -> sys:get_state(bus_store).
model() -> maps:get(model, state()).
queue(Id) -> maps:get(Id, maps:get(mail, model()), []).
ids(Entries) -> [maps:get(<<"id">>, M) || M <- Entries].
sub(Id) -> maps:get(Id, maps:get(subs, state())).
id(N) -> iolist_to_binary(io_lib:format("99999999-9999-4999-8999-~12.16.0b", [N])).
mail(N, To) ->
    #{<<"id">> => id(N), <<"from">> => ?A, <<"to">> => To,
      <<"kind">> => <<"notice">>, <<"body">> => <<"synthetic recovery fixture">>}.
accept(N, To) -> {ok, R} = bus_store:accept_mail(mail(N, To)), R.

%% Only arity is traced, and only the expiry clause matches. No state, request,
%% credential, or message body is copied to trace output.
trace_sweeps(P) ->
    1 = erlang:trace_pattern({bus_store, handle_info, 2},
                            [{[expire, '_'], [], []}], [local]),
    1 = erlang:trace(P, true, [call, arity]),
    ok.
sweep(P) ->
    receive {trace, P, call, {bus_store, handle_info, 2}} -> now_ms()
    after 1800 -> error(expiry_sweep_missing)
    end.
stop_trace(P) ->
    erlang:trace(P, false, [call]),
    erlang:trace_pattern({bus_store, handle_info, 2}, false, [local]),
    ok.

timer_only_expiry(C) ->
    {S, _Reader} = open_stream(C, ?B),
    #{pid := Handler} = sub(?B),
    HM = monitor(process, Handler),
    %% Offline C retains mail. B supplies a real stream to close on presence
    %% expiry. Injection only ages timestamps; it does not call expire/2.
    _ = accept(1, ?C),
    #{queued_bytes := Bytes} = model(),
    true = Bytes > 0,
    P = whereis(bus_store),
    trace_sweeps(P),
    try
        sys:replace_state(P, fun(#{model := M} = St) ->
            Agents = maps:get(agents, M),
            B = maps:get(?B, Agents),
            Mail = maps:get(mail, M),
            Old = erlang:monotonic_time(second) - 100,
            Expired = [(E#{<<"expires_mono">> := Old}) || E <- maps:get(?C, Mail)],
            St#{model := M#{agents := Agents#{?B := B#{last_mono := Old}},
                           mail := Mail#{?C := Expired}}}
        end),
        %% No application/store operation between injection and sweep. sys
        %% inspection below does not run the store's operation expiry guard.
        _ = sweep(P),
        await(fun() ->
            #{model := M, subs := Subs} = state(),
            not maps:is_key(?B, maps:get(agents, M)) andalso
                maps:get(?C, maps:get(mail, M), []) =:= [] andalso
                maps:get(queued_bytes, M) =:= 0 andalso not maps:is_key(?B, Subs)
        end),
        receive {'DOWN', HM, process, Handler, _} -> ok
        after 1500 -> error(expired_stream_survived) end,
        %% Agent C remains live: its queue was removed by mail TTL, not by
        %% recipient expiry. Dedup survives both independent expiry paths.
        #{agents := Agents1, dedup := Dedup} = model(),
        true = maps:is_key(?C, Agents1),
        true = maps:is_key({?A, id(1)}, Dedup)
    after
        stop_trace(P), demonitor(HM, [flush]), gen_tcp:close(S)
    end.

sweep_under_traffic(_C) ->
    P = whereis(bus_store),
    trace_sweeps(P),
    Parent = self(),
    Traffic = spawn(fun() -> traffic(Parent, 0) end),
    try
        T1 = sweep(P), T2 = sweep(P), T3 = sweep(P),
        true = T2 - T1 >= 500 andalso T2 - T1 < 1500,
        true = T3 - T2 >= 500 andalso T3 - T2 < 1500,
        Traffic ! stop,
        Count = receive {traffic_stopped, Traffic, N} -> N
            after 1000 -> error(traffic_stuck) end,
        true = Count > 100,
        ct:pal("Expiry under ~p store calls: consecutive sweep gaps ~p and ~p ms",
               [Count, T2 - T1, T3 - T2])
    after
        exit(Traffic, kill), stop_trace(P)
    end.
traffic(Parent, N) ->
    receive stop -> Parent ! {traffic_stopped, self(), N}
    after 1 ->
        {ok, _} = bus_store:list_agents(),
        traffic(Parent, N + 1)
    end.

coalesced_wakes(_C) ->
    %% The subscriber stays alive but selectively receives only fixture commands,
    %% leaving all store wakes untouched during the burst.
    Slow = spawn(fun slow/0),
    try
        {ok, Ref} = bus_store:subscribe(?B, Slow),
        lists:foreach(fun(N) ->
            _ = accept(N, ?B),
            set_label(integer_to_binary(N))
        end, lists:seq(1, 32)),
        {messages, Wakes} = process_info(Slow, messages),
        [{bus, Ref, mail}, {bus, Ref, presence}] = lists:sort(Wakes),
        32 = length(queue(?B)),
        {message_queue_len, 2} = process_info(Slow, message_queue_len),
        remote(Slow, fun() ->
            receive {bus, Ref, mail} -> ok end,
            receive {bus, Ref, presence} -> ok end,
            Latest = presence_frames(?B, Ref),
            assert_label(Latest, <<"32">>),
            Popped = [begin {ok, Msg} = bus_store:pop_mail(?B, Ref), Msg end
                      || _ <- lists:seq(1, 32)],
            Expected = [id(N) || N <- lists:seq(1, 32)],
            Expected = ids(Popped),
            {empty, undefined} = bus_store:pop_mail(?B, Ref)
        end),
        {message_queue_len, 0} = process_info(Slow, message_queue_len),
        lists:foreach(fun(N) -> set_label(<<"rearmed-", (integer_to_binary(N))/binary>>) end,
            lists:seq(1, 32)),
        {messages, [{bus, Ref, presence}]} = process_info(Slow, messages),
        remote(Slow, fun() ->
            receive {bus, Ref, presence} -> ok end,
            Latest = presence_frames(?B, Ref),
            [{<<"presence_delta">>, #{<<"changes">> := [_]}}] = Latest,
            assert_label(Latest, <<"rearmed-32">>)
        end),
        {message_queue_len, 0} = process_info(Slow, message_queue_len),
        _ = accept(33, ?B),
        {messages, [{bus, Ref, mail}]} = process_info(Slow, messages),
        ct:pal("32 retained messages and 32 presence changes: subscriber wake mailbox=2; drained/rearmed=0; next mail wake=1")
    after exit(Slow, kill) end.
set_label(Value) ->
    {ok, Agents} = bus_store:list_agents(),
    [A] = [X || #{<<"agentId">> := I} = X <- Agents, I =:= ?A],
    Doc = maps:without([<<"updatedAt">>, <<"receiving">>], A),
    ok = bus_store:put_agent(Doc#{<<"label">> := Value}).
presence_frames(AgentId, Ref) ->
    case bus_store:pull_presence(AgentId, Ref) of
        {frame, Event, Data, More} ->
            {ok, Value} = bus_protocol:decode_json(Data),
            [{Event, Value} | case More of
                true -> presence_frames(AgentId, Ref);
                false -> []
            end];
        empty -> []
    end.
assert_label(Frames, Expected) ->
    Agents = lists:append([case Event of
        <<"presence_snapshot">> -> maps:get(<<"agents">>, Value);
        <<"presence_delta">> -> [A || #{<<"op">> := <<"upsert">>, <<"agent">> := A}
            <- maps:get(<<"changes">>, Value)]
    end || {Event, Value} <- Frames]),
    [Expected] = [L || #{<<"agentId">> := ?A, <<"label">> := L} <- Agents],
    ok.
slow() ->
    receive {run, From, Ref, F} -> From ! {ran, Ref, F()}, slow() end.
remote(P, F) ->
    Ref = make_ref(), P ! {run, self(), Ref, F},
    receive {ran, Ref, R} -> R after 2000 -> error(slow_subscriber_stuck) end.

lost_post_response(C) ->
    FC = fault_listener(C),
    Msg = mail(101, ?B),
    gate(id(101)),
    {ok, S} = connect(FC),
    try
        send_post(S, Msg),
        Conn = blocked(),
        %% The response is gated before ranch_tcp:send, after real acceptance.
        #{dedup := D0, queued_bytes := Bytes} = model(),
        #{result := Accepted} = maps:get({?A, id(101)}, D0),
        [Only] = queue(?B),
        true = maps:get(<<"id">>, Only) =:= id(101),
        true = Bytes > 0,
        exit(Conn, kill),
        persistent_term:erase(?GATE),
        gen_tcp:close(S),
        {202, Body} = post(C, Msg),
        {ok, Accepted} = bus_protocol:decode_json(Body),
        [Only] = queue(?B),
        #{dedup := D0, queued_bytes := Bytes} = model(),
        %% Pop the sole entry, then retry once more. The identical original
        %% result must not create a second delivery even after the first pop.
        {ok, Ref} = bus_store:subscribe(?B, self()),
        {ok, _} = bus_store:pop_mail(?B, Ref),
        {202, Again} = post(C, Msg),
        {ok, Accepted} = bus_protocol:decode_json(Again),
        {empty, undefined} = bus_store:pop_mail(?B, Ref),
        ok = bus_store:unsubscribe(?B, Ref)
    after gen_tcp:close(S), persistent_term:erase(?GATE) end.

interrupted_pop_write(C) ->
    FC = fault_listener(C),
    FirstAcceptance = accept(201, ?B),
    _ = accept(202, ?B), _ = accept(203, ?B),
    gate(id(201)),
    {ok, S} = connect(FC),
    try
        send_stream(S, ?B),
        _ = bus_sse_client:open(S, now_ms() + 1000),
        Conn = blocked(),
        %% This is a real bus_events_h pop followed by an interrupted transport
        %% send. Nothing containing the first frame reached the socket.
        Remaining = [id(202), id(203)],
        Remaining = ids(queue(?B)),
        exit(Conn, kill),
        persistent_term:erase(?GATE),
        gen_tcp:close(S),
        await(fun() -> not maps:is_key(?B, maps:get(subs, state())) end),
        {202, Retry} = post(C, mail(201, ?B)),
        {ok, FirstAcceptance} = bus_protocol:decode_json(Retry),
        Remaining = ids(queue(?B)),
        {S2, R0} = open_stream(C, ?B),
        try
            R1 = bus_sse_client:until(S2, R0,
                fun(R) -> bus_sse_client:has_message(R, id(203)) end, now_ms() + 1000),
            await(fun() -> queue(?B) =:= [] end),
            #{pid := H} = sub(?B), H ! keepalive,
            R2 = bus_sse_client:until(S2, R1,
                fun(R) -> bus_sse_client:comments(R) > bus_sse_client:comments(R1) end,
                now_ms() + 1000),
            Remaining = frame_ids(R2),
            false = bus_sse_client:has_message(R2, id(201)),
            #{queued_bytes := 0} = model()
        after gen_tcp:close(S2) end
    after gen_tcp:close(S), persistent_term:erase(?GATE) end.

failure_state_boundaries(C) ->
    Acceptance = accept(301, ?B),
    _ = accept(302, ?B),
    #{mail := Mail, dedup := Dedup, queued_bytes := Bytes} = model(),
    Slow = spawn(fun slow/0),
    try
        {ok, _} = bus_store:subscribe(?B, Slow)
    after exit(Slow, kill) end,
    await(fun() -> not maps:is_key(?B, maps:get(subs, state())) end),
    #{mail := Mail, dedup := Dedup, queued_bytes := Bytes} = model(),
    OldStore = whereis(bus_store),
    OldListener = maps:get(pid, ranch:info(bus_http)),
    exit(OldListener, kill),
    await_listener(OldListener),
    OldStore = whereis(bus_store),
    #{mail := Mail, dedup := Dedup, queued_bytes := Bytes} = model(),
    C1 = current_port(C),
    {202, Body} = post(C1, mail(301, ?B)),
    {ok, Acceptance} = bus_protocol:decode_json(Body),
    #{mail := Mail, dedup := Dedup, queued_bytes := Bytes} = model(),
    Listener = maps:get(pid, ranch:info(bus_http)),
    exit(OldStore, kill),
    await_listener(Listener),
    true = whereis(bus_store) =/= OldStore,
    #{agents := #{}, mail := #{}, dedup := #{}, queued_bytes := 0} = model(),
    %% Map patterns above permit extra keys; assert truly empty maps explicitly.
    #{agents := As, mail := Ms, dedup := Ds} = model(),
    0 = map_size(As), 0 = map_size(Ms), 0 = map_size(Ds),
    C2 = current_port(C),
    {204, _} = bus_http_SUITE:put_agent(C2, ?A, false),
    {204, _} = bus_http_SUITE:put_agent(C2, ?B, false),
    {202, _} = post(C2, mail(301, ?B)),
    [Fresh] = queue(?B),
    true = maps:get(<<"id">>, Fresh) =:= id(301),
    1 = map_size(maps:get(dedup, model())).

await_listener(Old) ->
    await(fun() ->
        case catch ranch:info(bus_http) of
            #{pid := New, status := running, port := Port} ->
                New =/= Old andalso is_integer(Port) andalso Port > 0;
            _ -> false
        end
    end, now_ms() + 7000).
current_port(C) -> [{port, ranch:get_port(bus_http)} | C].
connect(C) -> gen_tcp:connect({127, 0, 0, 1}, proplists:get_value(port, C),
                             [binary, {active, false}], 1000).
send_stream(S, Id) ->
    gen_tcp:send(S, ["GET /v1/events?agentId=", Id,
        " HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ct-token\r\n\r\n"]).
open_stream(C, Id) ->
    {ok, S} = connect(C),
    try
        ok = send_stream(S, Id),
        D = now_ms() + 1500,
        R = bus_sse_client:until(S, bus_sse_client:open(S, D),
            fun(X) -> bus_sse_client:has_event(X, <<"presence_snapshot">>) end, D),
        {S, R}
    catch Class:Reason:Stack -> gen_tcp:close(S), erlang:raise(Class, Reason, Stack) end.
frame_ids(Reader) ->
    [maps:get(<<"id">>, Msg) || Msg <- bus_sse_client:json_events(Reader, <<"message">>)].

send_post(S, Msg) ->
    Body = bus_protocol:encode_map(Msg),
    gen_tcp:send(S, ["POST /v1/messages HTTP/1.1\r\nHost: localhost\r\n",
        "Authorization: Bearer ct-token\r\nContent-Type: application/json\r\n",
        "Connection: close\r\nContent-Length: ", integer_to_binary(byte_size(Body)),
        "\r\n\r\n", Body]).
post(C, Msg) ->
    {ok, S} = connect(C),
    try
        ok = send_post(S, Msg),
        ok = inet:setopts(S, [{packet, http_bin}]),
        {ok, {http_response, _, Status, _}} = gen_tcp:recv(S, 0, 2000),
        Length = response_headers(S, undefined),
        true = is_integer(Length),
        ok = inet:setopts(S, [{packet, raw}]),
        {ok, Body} = gen_tcp:recv(S, Length, 2000),
        {Status, Body}
    after gen_tcp:close(S) end.
response_headers(S, Length) ->
    case gen_tcp:recv(S, 0, 2000) of
        {ok, http_eoh} -> Length;
        {ok, {http_header, _, 'Content-Length', _, Value}} ->
            response_headers(S, binary_to_integer(iolist_to_binary(Value)));
        {ok, {http_header, _, _, _, _}} -> response_headers(S, Length);
        Other -> error({invalid_response_header, Other})
    end.

fault_listener(C) ->
    {ok, _} = ranch:start_listener(bus_recovery, ranch_tcp,
        #{connection_type => supervisor, num_acceptors => 1, num_conns_sups => 1,
          socket_opts => [{ip, {127, 0, 0, 1}}, {port, 0},
                         {send_timeout, 5000}, {send_timeout_close, true}]},
        ?MODULE, ranch:get_protocol_options(bus_http)),
    [{port, ranch:get_port(bus_recovery)} | C].
gate(Marker) -> persistent_term:put(?GATE, {self(), Marker}).
blocked() -> receive {recovery_send_blocked, Conn} -> Conn
    after 2000 -> error(send_gate_not_reached) end.
start_link(Ref, _Transport, Opts) -> bus_connection:start_link(Ref, ?MODULE, Opts).
name() -> tcp.
secure() -> false.
messages() -> ranch_tcp:messages().
peername(S) -> ranch_tcp:peername(S).
sockname(S) -> ranch_tcp:sockname(S).
setopts(S, O) -> ranch_tcp:setopts(S, O).
shutdown(S, H) -> ranch_tcp:shutdown(S, H).
close(S) -> ranch_tcp:close(S).
send(S, Data) ->
    %% Marker matching selects a synthetic send to interrupt, not an HTTP/SSE
    %% response assertion. All received SSE is decoded incrementally above.
    case persistent_term:get(?GATE, undefined) of
        {Observer, Marker} ->
            case binary:match(iolist_to_binary(Data), Marker) of
                nomatch -> ranch_tcp:send(S, Data);
                _ ->
                    Observer ! {recovery_send_blocked, self()},
                    receive release_recovery_send -> ranch_tcp:send(S, Data) end
            end;
        undefined -> ranch_tcp:send(S, Data)
    end.
