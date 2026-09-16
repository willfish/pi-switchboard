-module(bus_operator_activity).
-behaviour(gen_server).

%% Bearer activity reports. Best-effort observation. Never pops mail or
%% renews the agent lease. Capture no replacement store; validate via native
%% lookup of the current binding.
-export([start_link/0, report/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         format_status/1]).

-define(EXPIRY_MS, 1000).
-define(SLOTS, bus_operator_activity_slots).
-define(MAX_EVENTS, 32).
-define(MAX_SEEN, 4096).
-define(MAX_REPLY, 2048).
-define(MAX_UINT, 18446744073709551615).
-define(DOC_KEYS, [
    <<"schemaVersion">>, <<"agentId">>, <<"bindingId">>,
    <<"runtimeGeneration">>, <<"sessionGeneration">>, <<"events">>,
    <<"dropped">>
]).
-define(EVENT_KEYS, [
    <<"id">>, <<"toolCallId">>, <<"toolName">>, <<"state">>, <<"occurredAt">>
]).
-define(STATES, [<<"started">>, <<"ended">>, <<"failed">>]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

report(ConnPid, Doc, Deadline)
  when is_pid(ConnPid), is_map(Doc), is_integer(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Remaining when Remaining =< 0 -> {error, timeout};
        _ ->
            case agent_key(Doc) of
                {error, Reason} -> {error, Reason};
                {ok, Key} -> call(ConnPid, Key, {report, Doc}, Deadline)
            end
    end;
report(_, _, _) -> {error, invalid_schema}.

agent_key(#{<<"agentId">> := Id}) ->
    case bus_protocol:is_uuid(Id) of
        true -> {ok, {session, Id}};
        false -> {error, invalid_schema}
    end;
agent_key(_) -> {error, invalid_schema}.

call(ConnPid, Key, Op, Deadline) ->
    case whereis(?MODULE) of
        undefined -> {error, unavailable};
        Pid -> admit(Pid, ConnPid, Key, Op, Deadline)
    end.

admit(Pid, ConnPid, Key, Op, Deadline) ->
    case slots_tid(Pid) of
        undefined -> {error, unavailable};
        Tab ->
            try bus_operator_admission:acquire(Tab, Pid, ConnPid, Key) of
                {error, Reason} -> {error, Reason};
                {ok, SlotRef} ->
                    Pid ! {admit, SlotRef, ConnPid},
                    Remaining = Deadline - erlang:monotonic_time(millisecond),
                    Timeout = case Remaining of R when R > 0 -> R; _ -> 0 end,
                    try gen_server:call(Pid, {op, Deadline, SlotRef, ConnPid, Op}, Timeout)
                    catch
                        exit:{timeout, _} -> {error, timeout};
                        exit:_ -> {error, unavailable}
                    end
            catch
                _:_ -> {error, unavailable}
            end
    end.

slots_tid(OwnerPid) when is_pid(OwnerPid) ->
    case ets:info(?SLOTS, owner) of
        OwnerPid -> ets:info(?SLOTS, id);
        _ -> undefined
    end;
slots_tid(_) -> undefined.

init([]) ->
    Tab = ets:new(?SLOTS, [named_table, set, public,
        {read_concurrency, true}, {write_concurrency, true}]),
    ok = bus_operator_admission:init(Tab),
    erlang:send_after(?EXPIRY_MS, self(), expire),
    {ok, #{slots => Tab, seen => #{}, mons => #{}}}.

handle_call({op, Deadline, SlotRef, ConnPid, Op}, _From, #{slots := Tab} = State0) ->
    _ = bus_operator_admission:reclaim_dead(Tab),
    case bus_operator_admission:checkout(Tab, SlotRef, ConnPid) of
        stale -> {reply, {error, stale_slot}, State0};
        ok ->
            {Reply, State1} = case is_process_alive(ConnPid) of
                false -> {{error, stale_slot}, State0};
                true ->
                    case erlang:monotonic_time(millisecond) >= Deadline of
                        true -> {{error, timeout}, State0};
                        false -> run_op(Op, State0, Deadline, ConnPid)
                    end
            end,
            {reply, Reply, finish_slot(Tab, SlotRef, State1)}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, invalid_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({admit, SlotRef, ConnPid}, #{slots := Tab, mons := Mons} = State) ->
    case bus_operator_admission:checkout(Tab, SlotRef, ConnPid) of
        ok ->
            Mon = monitor(process, ConnPid),
            {noreply, State#{mons := Mons#{Mon => SlotRef}}};
        stale -> {noreply, State}
    end;
handle_info({'DOWN', Mon, process, _Pid, _Reason}, #{slots := Tab, mons := Mons} = State) ->
    case maps:take(Mon, Mons) of
        {SlotRef, Rest} ->
            bus_operator_admission:release(Tab, SlotRef),
            {noreply, State#{mons := Rest}};
        error -> {noreply, State}
    end;
handle_info(expire, #{slots := Tab} = State) ->
    _ = bus_operator_admission:reclaim_dead(Tab),
    erlang:send_after(?EXPIRY_MS, self(), expire),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

format_status(Status) ->
    maps:map(fun(log, _) -> [];
                (_, _) -> redacted
             end, Status).

finish_slot(Tab, SlotRef, #{mons := Mons} = State) ->
    bus_operator_admission:release(Tab, SlotRef),
    State#{mons := drop_mon(SlotRef, Mons)}.

drop_mon(SlotRef, Mons) ->
    maps:fold(fun(Mon, Ref, Acc) ->
        case Ref =:= SlotRef of
            true -> demonitor(Mon, [flush]), Acc;
            false -> Acc#{Mon => Ref}
        end
    end, #{}, Mons).

run_op({report, Doc}, State, Deadline, ConnPid) ->
    try
        Parsed = decode_doc(Doc),
        AgentId = maps:get(agent_id, Parsed),
        case bus_operator_native:lookup(ConnPid, AgentId, Deadline) of
            {error, Reason} -> {{error, Reason}, State};
            {ok, View} ->
                case erlang:monotonic_time(millisecond) >= Deadline of
                    true -> {{error, timeout}, State};
                    false -> accept(Parsed, View, State)
                end
        end
    catch
        throw:Thrown -> {{error, Thrown}, State};
        error:_ -> {{error, invalid_schema}, State}
    end;
run_op(_, State, _, _) ->
    {{error, invalid_request}, State}.

accept(Parsed, View, State) ->
    Binding = maps:get(binding, View),
    true = maps:get(<<"bindingId">>, Binding) =:= maps:get(binding_id, Parsed)
        orelse throw(stale_generation),
    true = binary_to_integer(maps:get(<<"runtimeGeneration">>, Binding))
        =:= maps:get(runtime, Parsed) orelse throw(stale_generation),
    true = binary_to_integer(maps:get(<<"sessionGeneration">>, Binding))
        =:= maps:get(session_gen, Parsed) orelse throw(stale_generation),
    Caps = maps:get(<<"capabilities">>, Binding),
    true = lists:member(<<"activity.report.v1">>, Caps) orelse throw(forbidden),
    BindingId = maps:get(binding_id, Parsed),
    Seen0 = maps:get(BindingId, maps:get(seen, State), {[], #{}}),
    {Accepted, Seen1} = ingest(maps:get(events, Parsed), Binding, Seen0, 0),
    Reply = #{<<"schemaVersion">> => 1, <<"accepted">> => Accepted},
    Enc = iolist_to_binary(json:encode(Reply)),
    true = byte_size(Enc) =< ?MAX_REPLY orelse throw(envelope),
    {{ok, Reply}, State#{seen := (maps:get(seen, State))#{BindingId => Seen1}}}.

ingest([], _Binding, Seen, N) -> {N, Seen};
ingest([Ev | Rest], Binding, Seen, N) ->
    Id = maps:get(id, Ev),
    {Order, Set} = Seen,
    case maps:is_key(Id, Set) of
        true -> ingest(Rest, Binding, Seen, N);
        false ->
            observe(Ev, Binding),
            {Order1, Set1} = remember(Id, Order, Set),
            ingest(Rest, Binding, {Order1, Set1}, N + 1)
    end.

remember(Id, Order, Set) ->
    case map_size(Set) >= ?MAX_SEEN of
        false -> {Order ++ [Id], Set#{Id => true}};
        true ->
            case Order of
                [Old | Rest] -> {Rest ++ [Id], maps:remove(Old, Set#{Id => true})};
                [] -> {[Id], #{Id => true}}
            end
    end.

observe(Ev, Binding) ->
    Ms = maps:get(occurred_at, Ev),
    bus_operator_journal:offer(#{
        <<"kind">> => <<"tool_reported">>,
        <<"source">> => <<"client_reported">>,
        <<"agentId">> => maps:get(<<"agentId">>, Binding),
        <<"sessionId">> => maps:get(<<"sessionId">>, Binding),
        <<"occurredAt">> => integer_to_binary(Ms div 1000),
        <<"payload">> => #{
            <<"toolCallId">> => maps:get(tool_call_id, Ev),
            <<"toolName">> => maps:get(tool_name, Ev),
            <<"state">> => maps:get(state, Ev)
        }
    }).

decode_doc(Map) when is_map(Map) ->
    check_keys(Map, ?DOC_KEYS),
    1 = maps:get(<<"schemaVersion">>, Map),
    AgentId = uuid(maps:get(<<"agentId">>, Map)),
    BindingId = uuid(maps:get(<<"bindingId">>, Map)),
    Runtime = uint(maps:get(<<"runtimeGeneration">>, Map)),
    SessionGen = uint(maps:get(<<"sessionGeneration">>, Map)),
    _Dropped = uint(maps:get(<<"dropped">>, Map)),
    Events = decode_events(maps:get(<<"events">>, Map), []),
    #{agent_id => AgentId, binding_id => BindingId, runtime => Runtime,
      session_gen => SessionGen, events => Events};
decode_doc(_) -> throw(invalid_schema).

decode_events(List, Acc) when is_list(List), length(List) =< ?MAX_EVENTS ->
    decode_events1(List, Acc, #{});
decode_events(_, _) -> throw(invalid_schema).

decode_events1([], Acc, _) -> lists:reverse(Acc);
decode_events1([Map | Rest], Acc, Seen) when is_map(Map) ->
    Ev = decode_event(Map),
    Id = maps:get(id, Ev),
    case maps:is_key(Id, Seen) of
        true -> throw(invalid_schema);
        false -> decode_events1(Rest, [Ev | Acc], Seen#{Id => true})
    end;
decode_events1(_, _, _) -> throw(invalid_schema).

decode_event(Map) ->
    check_keys(Map, ?EVENT_KEYS),
    Id = uuid(maps:get(<<"id">>, Map)),
    CallId = bounded(maps:get(<<"toolCallId">>, Map), 1, 256),
    Name = bounded(maps:get(<<"toolName">>, Map), 1, 128),
    State = maps:get(<<"state">>, Map),
    true = lists:member(State, ?STATES) orelse throw(invalid_schema),
    Occurred = uint(maps:get(<<"occurredAt">>, Map)),
    #{id => Id, tool_call_id => CallId, tool_name => Name,
      state => State, occurred_at => Occurred}.

bounded(Bin, Min, Max) when is_binary(Bin), byte_size(Bin) >= Min,
        byte_size(Bin) =< Max ->
    case unicode:characters_to_binary(Bin) of
        Bin -> Bin;
        _ -> throw(invalid_schema)
    end;
bounded(_, _, _) -> throw(invalid_schema).

check_keys(Map, Required) when is_map(Map) ->
    Keys = maps:keys(Map),
    case {Required -- Keys, Keys -- Required} of
        {[], []} -> ok;
        _ -> throw(invalid_schema)
    end;
check_keys(_, _) -> throw(invalid_schema).

uuid(Id) ->
    case bus_protocol:is_uuid(Id) of
        true -> Id;
        false -> throw(invalid_schema)
    end.

uint(Bin) when is_binary(Bin) ->
    try
        N = binary_to_integer(Bin),
        true = N >= 0 andalso N =< ?MAX_UINT andalso Bin =:= integer_to_binary(N),
        N
    catch _:_ -> throw(invalid_schema)
    end;
uint(_) -> throw(invalid_schema).
