-module(bus_operator_native).
-behaviour(gen_server).

%% Native operator owner. Bindings and frozen fleet snapshots. Init does not
%% call the store. Capture one store PID and never follow a replacement.
%% view_revision ticks on binding, work, and removal, not identical heartbeats.
-export([start_link/0, announce/3, lookup/3, page/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         format_status/1]).

-ifdef(TEST).
-export([handle_call_at/4, slots/0]).
-endif.

-define(EXPIRY_MS, 1000).
-define(CLEAN_BATCH, 32).
-define(SLOTS, bus_operator_native_slots).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

announce(ConnPid, Doc, Deadline)
  when is_pid(ConnPid), is_integer(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Remaining when Remaining =< 0 -> {error, timeout};
        _ ->
            case agent_key(Doc) of
                {error, Reason} -> {error, Reason};
                {ok, Key} -> call(ConnPid, Key, {announce, Doc}, Deadline)
            end
    end;
announce(_, _, _) -> {error, invalid_schema}.

lookup(ConnPid, AgentId, Deadline)
  when is_pid(ConnPid), is_binary(AgentId), is_integer(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Remaining when Remaining =< 0 -> {error, timeout};
        _ ->
            case bus_protocol:is_uuid(AgentId) of
                false -> {error, invalid_schema};
                true -> call(ConnPid, {session, AgentId}, {lookup, AgentId}, Deadline)
            end
    end;
lookup(_, _, _) -> {error, invalid_schema}.

page(ConnPid, Digest, Cursor, Deadline)
  when is_pid(ConnPid), is_binary(Digest), byte_size(Digest) =:= 32,
       is_integer(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Remaining when Remaining =< 0 -> {error, timeout};
        _ -> call(ConnPid, {session, Digest}, {page, Cursor, Digest}, Deadline)
    end;
page(_, _, _, _) -> {error, invalid_request}.

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
                    call_pid(Pid, {op, Deadline, SlotRef, ConnPid, Op}, Deadline)
            catch
                _:_ -> {error, unavailable}
            end
    end.

call_pid(Pid, Op, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    Timeout = case Remaining of R when R > 0 -> R; _ -> 0 end,
    try gen_server:call(Pid, Op, Timeout)
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:_ -> {error, unavailable}
    end.

slots_tid(OwnerPid) when is_pid(OwnerPid) ->
    case ets:info(?SLOTS, owner) of
        OwnerPid -> ets:info(?SLOTS, id);
        _ -> undefined
    end;
slots_tid(_) -> undefined.

-ifdef(TEST).
slots() -> ?SLOTS.
-endif.

init([]) ->
    Tab = ets:new(?SLOTS, [named_table, set, public,
        {read_concurrency, true}, {write_concurrency, true}]),
    ok = bus_operator_admission:init(Tab),
    History = ets:new(bus_operator_history:table(), [named_table, set, protected,
        {read_concurrency, true}]),
    ok = bus_operator_history:init(History),
    erlang:send_after(?EXPIRY_MS, self(), expire),
    {ok, empty_state(Tab)}.

empty_state(Tab) ->
    #{slots => Tab, bindings => bus_operator_bindings:new(),
      fleet => bus_operator_fleet:new(), view_revision => 0,
      core_epoch => undefined, store => undefined, cursor => <<>>, mons => #{}}.

handle_call({op, _, _, _, _} = Request, From, State) ->
    handle_call_at(Request, From, State, erlang:monotonic_time(millisecond));
handle_call(_Request, _From, State) ->
    {reply, {error, invalid_request}, State}.

handle_call_at({op, Deadline, SlotRef, ConnPid, Op}, _From, #{slots := Tab} = State0,
               Now) ->
    _ = bus_operator_admission:reclaim_dead(Tab),
    case bus_operator_admission:checkout(Tab, SlotRef, ConnPid) of
        stale -> {reply, {error, stale_slot}, State0};
        ok ->
            {Reply, State1} = case is_process_alive(ConnPid) of
                false -> {{error, stale_slot}, State0};
                true ->
                    case Now >= Deadline of
                        true -> {{error, timeout}, State0};
                        false ->
                            State = pin_store(State0#{
                                fleet := bus_operator_fleet:expire(Now, maps:get(fleet, State0))}),
                            run_op(Op, State, Deadline, Now)
                    end
            end,
            {reply, Reply, finish_slot(Tab, SlotRef, State1)}
    end.

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
handle_info(expire, #{slots := Tab} = State0) ->
    Now = erlang:monotonic_time(millisecond),
    State1 = clean_batch(pin_store(State0#{
        fleet := bus_operator_fleet:expire(Now, maps:get(fleet, State0))})),
    _ = bus_operator_admission:reclaim_dead(Tab),
    erlang:send_after(?EXPIRY_MS, self(), expire),
    {noreply, State1};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

format_status(Status) ->
    maps:map(fun(log, _) -> [];
                (_, _) -> redacted
             end, Status).

run_op({announce, Doc}, State, Deadline, _Now) ->
    case maps:get(store, State) of
        undefined -> {{error, unavailable}, State};
        Pid ->
            case agent_key(Doc) of
                {error, Reason} -> {{error, Reason}, State};
                {ok, {session, AgentId}} ->
                    case bus_store:operator_registration(Pid, AgentId, Deadline) of
                        {error, Reason} -> {{error, Reason}, State};
                        {ok, Auth} ->
                            case past(Deadline) of
                                true -> {{error, timeout}, State};
                                false -> announce_bound(Doc, Auth, State, Deadline)
                            end
                    end
            end
    end;
run_op({lookup, AgentId}, State, Deadline, _Now) ->
    case maps:get(store, State) of
        undefined -> {{error, unavailable}, State};
        Pid -> revalidate(AgentId, Pid, Deadline, State)
    end;
run_op({page, Cursor, Digest}, State, Deadline, Now) ->
    case maps:get(store, State) of
        undefined -> {{error, unavailable}, State};
        _ ->
            case past(Deadline) of
                true -> {{error, timeout}, State};
                false ->
                    case Cursor of
                        first -> first_page(Digest, State, Deadline, Now);
                        _ -> continue_page(Cursor, Digest, State, Deadline, Now)
                    end
            end
    end;
run_op(_, State, _, _) ->
    {{error, invalid_request}, State}.

announce_bound(Doc, Auth, State, Deadline) ->
    case candidate_uuid() of
        {error, Reason} -> {{error, Reason}, State};
        {ok, Candidate} ->
            case bus_operator_bindings:announce(Doc, Auth, Candidate,
                    maps:get(bindings, State)) of
                {error, Reason} -> {{error, Reason}, State};
                {ok, Receipt, Bindings} ->
                    case past(Deadline) of
                        true -> {{error, timeout}, State};
                        false ->
                            State1 = assign_bindings(Bindings,
                                note_epoch(maps:get(epoch, Auth), State)),
                            history_sync(State1, Receipt),
                            {{ok, Receipt}, State1}
                    end
            end
    end.

first_page(Digest, State, Deadline, Now) ->
    Fleet = maps:get(fleet, State),
    Bound = maps:is_key(Digest, maps:get(by_session, Fleet, #{})),
    case Bound orelse bus_operator_fleet:can_capture(Fleet, Now) of
        false -> {{error, capacity}, State};
        true ->
            case maps:get(store, State) of
                undefined -> {{error, unavailable}, State};
                Pid ->
                    case bus_store:operator_registrations(Pid, Deadline) of
                        {error, Reason} -> {{error, Reason}, State};
                        {ok, Bulk} ->
                            case past(Deadline) of
                                true -> {{error, timeout}, State};
                                false -> freeze_or_reuse(Digest, Bulk, State, Deadline, Now)
                            end
                    end
            end
    end.

freeze_or_reuse(Digest, Bulk, State, Deadline, Now) ->
    Epoch = maps:get(epoch, Bulk),
    StoreRev = maps:get(revision, Bulk),
    ViewRev = maps:get(view_revision, State),
    State1 = note_epoch(Epoch, State),
    case bus_operator_fleet:bound(Digest, maps:get(fleet, State1), Now, ViewRev,
            StoreRev, Epoch, Deadline) of
        {ok, Encoded, Fleet1} -> {{ok, Encoded}, State1#{fleet := Fleet1}};
        {error, Reason} -> {{error, Reason}, State};
        none -> freeze(Digest, Bulk, State1, Deadline, Now)
    end.

freeze(Digest, Bulk, State, Deadline, Now) ->
    case bus_operator_fleet:can_capture(maps:get(fleet, State), Now) of
        false -> {{error, capacity}, State};
        true ->
            Views = live_views(bus_operator_bindings:views(maps:get(bindings, State)),
                maps:get(registrations, Bulk)),
            case past(Deadline) of
                true -> {{error, timeout}, State};
                false ->
                    case candidate_uuid() of
                        {error, Reason} -> {{error, Reason}, State};
                        {ok, Id} ->
                            case bus_operator_fleet:capture(Views, maps:get(epoch, Bulk),
                                    maps:get(view_revision, State), maps:get(revision, Bulk),
                                    Now, maps:get(capturedAt, Bulk), Deadline, Digest,
                                    maps:get(fleet, State), Id) of
                                {error, Reason} -> {{error, Reason}, State};
                                {ok, Encoded, Fleet1} ->
                                    case past(Deadline) of
                                        true -> {{error, timeout}, State};
                                        false -> {{ok, Encoded}, State#{fleet := Fleet1}}
                                    end
                            end
                    end
            end
    end.

continue_page(Cursor, Digest, State, Deadline, Now) ->
    case maps:get(core_epoch, State) of
        undefined -> {{error, epoch_reset}, State};
        Epoch ->
            case bus_operator_fleet:continue(Cursor, Digest, Now,
                    maps:get(view_revision, State), Epoch, Deadline,
                    maps:get(fleet, State)) of
                {ok, Encoded, Fleet1} -> {{ok, Encoded}, State#{fleet := Fleet1}};
                {error, Reason} -> {{error, Reason}, State}
            end
    end.

revalidate(AgentId, Pid, Deadline, #{bindings := Bindings} = State) ->
    case bus_store:operator_registration(Pid, AgentId, Deadline) of
        {error, not_found} ->
            case past(Deadline) of
                true -> {{error, timeout}, State};
                false ->
                    bus_operator_history:delete(AgentId),
                    {{error, not_found},
                     assign_bindings(bus_operator_bindings:remove(AgentId, Bindings), State)}
            end;
        {error, Reason} ->
            {{error, Reason}, State};
        {ok, Auth} ->
            case past(Deadline) of
                true -> {{error, timeout}, State};
                false ->
                    case bus_operator_bindings:lookup(AgentId, Bindings) of
                        {error, not_found} -> {{error, not_found}, State};
                        {ok, View} ->
                            case matches_auth(View, Auth) of
                                true -> {{ok, View}, State};
                                false ->
                                    bus_operator_history:delete(AgentId),
                                    {{error, not_found},
                                     assign_bindings(bus_operator_bindings:remove(AgentId, Bindings),
                                         State)}
                            end
                    end
            end
    end.

live_views(Views, Regs) ->
    [V || V <- Views, live_view(V, Regs)].

live_view(#{<<"binding">> := Rec}, Regs) ->
    Id = maps:get(<<"agentId">>, Rec),
    case maps:find(Id, Regs) of
        {ok, Auth} -> matches_json_auth(Rec, Auth);
        error -> false
    end;
live_view(_, _) -> false.

matches_auth(#{binding := Rec}, Auth) ->
    matches_json_auth(Rec, Auth).

matches_json_auth(Rec, Auth) ->
    Reg = maps:get(<<"registration">>, Rec),
    maps:get(<<"epoch">>, Reg) =:= maps:get(epoch, Auth)
        andalso binary_to_integer(maps:get(<<"generation">>, Reg))
            =:= maps:get(registrationGeneration, Auth)
        andalso maps:get(<<"sessionId">>, Rec) =:= maps:get(sessionId, Auth).

assign_bindings(Bindings, #{bindings := Bindings} = State) ->
    State;
assign_bindings(Bindings, #{view_revision := Rev} = State) ->
    bus_operator_updates:publish(browser),
    State#{bindings := Bindings, view_revision := Rev + 1}.

note_epoch(Epoch, #{core_epoch := Epoch} = State) -> State;
note_epoch(Epoch, State) ->
    State#{core_epoch := Epoch, fleet := bus_operator_fleet:new()}.

past(Deadline) ->
    erlang:monotonic_time(millisecond) >= Deadline.

pin_store(#{store := Pid} = State) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> State;
        false -> adopt_store(State, whereis(bus_store))
    end;
pin_store(State) ->
    adopt_store(State, whereis(bus_store)).

adopt_store(#{store := Pid} = State, Pid) -> State;
adopt_store(#{slots := Tab}, New) ->
    bus_operator_history:reset(),
    (empty_state(Tab))#{store := New}.

clean_batch(#{store := undefined} = State) -> State;
clean_batch(#{store := Pid, bindings := Bindings, cursor := Cursor} = State) ->
    Ids = binding_ids(Bindings),
    Sorted = lists:sort(Ids),
    Rest = [Id || Id <- Sorted, Id > Cursor],
    Take = lists:sublist(case Rest of [] -> Sorted; _ -> Rest end, ?CLEAN_BATCH),
    Deadline = erlang:monotonic_time(millisecond) + 1000,
    Bindings1 = lists:foldl(fun(Id, Acc) -> clean_one(Pid, Id, Deadline, Acc) end,
        Bindings, Take),
    Next = case Take of
        [] -> <<>>;
        _ -> lists:last(Take)
    end,
    NextCursor = case Rest =:= [] orelse length(Take) < ?CLEAN_BATCH of
        true -> <<>>;
        false -> Next
    end,
    assign_bindings(Bindings1, State#{cursor := NextCursor}).

binding_ids(Bindings) ->
    case maps:get(by_agent, Bindings, undefined) of
        Map when is_map(Map) -> maps:keys(Map);
        _ -> []
    end.

clean_one(Pid, Id, Deadline, Bindings) ->
    case bus_store:operator_registration(Pid, Id, Deadline) of
        {error, not_found} ->
            bus_operator_history:delete(Id),
            bus_operator_bindings:remove(Id, Bindings);
        {ok, Auth} ->
            case bus_operator_bindings:lookup(Id, Bindings) of
                {error, not_found} -> Bindings;
                {ok, View} ->
                    case matches_auth(View, Auth) of
                        true -> Bindings;
                        false ->
                            bus_operator_history:delete(Id),
                            bus_operator_bindings:remove(Id, Bindings)
                    end
            end;
        _ -> Bindings
    end.

history_sync(#{store := StorePid, bindings := Bindings}, Receipt)
  when is_pid(StorePid), is_map(Receipt) ->
    AgentId = maps:get(<<"agentId">>, Receipt),
    case bus_operator_bindings:lookup(AgentId, Bindings) of
        {ok, View} ->
            Binding = maps:get(binding, View),
            Gen = binary_to_integer(maps:get(<<"generation">>,
                maps:get(<<"registration">>, Binding))),
            Flag = maps:get(<<"history">>, maps:get(permissions, View), false) =:= true,
            bus_operator_history:put(StorePid, AgentId, Gen, Flag);
        _ -> bus_operator_history:delete(AgentId)
    end;
history_sync(_, _) -> ok.

candidate_uuid() ->
    try
        <<A:32, B:16, _:4, C:12, _:2, E:14, F:48>> = crypto:strong_rand_bytes(16),
        {ok, iolist_to_binary(io_lib:format(
            "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
            [A, B, C bor 16#4000, E bor 16#8000, F]))}
    catch
        _:_ -> {error, unavailable}
    end.

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
