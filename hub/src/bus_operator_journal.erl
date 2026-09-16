-module(bus_operator_journal).
-behaviour(gen_server).

%% Single observation owner. Producers write local ETS only. Owner-RPC pages
%% use a private admission table. Init does not query interfaces.
-export([start_link/0, offer/1, page/4, search/5, subscribe/3, pull/4, release/3,
         unsubscribe/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         format_status/1]).

-ifdef(TEST).
-export([handle_call_at/4, slots/0]).
-endif.

-define(EXPIRY_MS, 1000).
-define(SLOTS, bus_operator_journal_slots).
-define(MAX_OBS, 32).
-define(MAX_INFLIGHT, 16777216).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Metadata observation. Never throws into a mail producer.
offer(Event) ->
    try offer_in(Event) of
        _ -> ok
    catch
        _:_ -> ok
    end.

offer_in(Event) when is_map(Event) ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid ->
            case bus_operator_ingress:tid(Pid) of
                undefined -> ok;
                Tab ->
                    {Event1, Opts} = enroll_offer(Event),
                    case bus_operator_ingress:try_in(Tab, Pid, Event1, Opts) of
                        {ok, wake} -> Pid ! drain, ok;
                        _ -> ok
                    end
            end
    end;
offer_in(_) -> ok.

enroll_offer(Event) ->
    Pay = maps:get(<<"payload">>, Event, #{}),
    case is_map(Pay) andalso maps:is_key(<<"body">>, Pay) of
        false -> {Event, #{}};
        true ->
            case enrolled(Event, Pay) of
                true -> {Event, #{enroll_bodies => true}};
                false ->
                    {Event#{<<"payload">> => maps:remove(<<"body">>, Pay)}, #{}}
            end
    end.

enrolled(#{<<"kind">> := <<"mail_accepted">>}, Pay) ->
    bus_operator_history:current(maps:get(<<"from">>, Pay, undefined))
        andalso bus_operator_history:current(maps:get(<<"to">>, Pay, undefined));
enrolled(#{<<"kind">> := <<"operator_requested">>, <<"agentId">> := AgentId}, _) ->
    bus_operator_history:current(AgentId);
enrolled(_, _) -> false.

page(Cursor, ConnPid, Digest, Deadline)
  when is_pid(ConnPid), is_integer(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Remaining when Remaining =< 0 -> {error, timeout};
        _ ->
            case valid_digest(Digest) of
                false -> {error, invalid_request};
                true -> call(ConnPid, {session, Digest}, {page, Cursor}, Deadline)
            end
    end;
page(_, _, _, _) -> {error, invalid_request}.

search(Filter, Cursor, ConnPid, Digest, Deadline)
  when is_map(Filter), is_pid(ConnPid), is_binary(Digest), byte_size(Digest) =:= 32,
       is_integer(Deadline) ->
    call(ConnPid, {session, Digest}, {search, Filter, Cursor}, Deadline);
search(_, _, _, _, _) -> {error, invalid_request}.

subscribe(ConnPid, Digest, Deadline)
  when is_pid(ConnPid), is_binary(Digest), byte_size(Digest) =:= 32,
       is_integer(Deadline) ->
    case whereis(?MODULE) of
        undefined -> {error, unavailable};
        Pid ->
            case admit(Pid, ConnPid, {session, Digest},
                    {subscribe, Digest, ConnPid}, Deadline) of
                {ok, Ref} -> {ok, Pid, Ref};
                Error -> Error
            end
    end;
subscribe(_, _, _) -> {error, invalid_request}.

pull(Pid, Ref, ConnPid, Deadline)
  when is_pid(Pid), is_reference(Ref), is_pid(ConnPid), is_integer(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Remaining when Remaining =< 0 -> {error, timeout};
        _ ->
            case ets:info(?SLOTS, owner) of
                Pid -> call_pid(Pid, {pull, Deadline, Ref, ConnPid}, Deadline);
                _ -> {error, unavailable}
            end
    end;
pull(_, _, _, _) -> {error, invalid_request}.

release(Pid, Ref, Bytes)
  when is_pid(Pid), is_reference(Ref), is_integer(Bytes), Bytes >= 0 ->
    case ets:info(?SLOTS, owner) of
        Pid -> gen_server:cast(Pid, {release, Ref, Bytes});
        _ -> ok
    end,
    ok;
release(_, _, _) -> ok.

unsubscribe(Pid, Ref) when is_pid(Pid), is_reference(Ref) ->
    case ets:info(?SLOTS, owner) of
        Pid -> gen_server:cast(Pid, {unsubscribe, Ref});
        _ -> ok
    end,
    ok;
unsubscribe(_, _) -> ok.

valid_digest(D) -> is_binary(D) andalso byte_size(D) =:= 32.

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
                    %% Caller timeout must not free a queued slot.
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
    Slots = ets:new(?SLOTS, [named_table, set, public,
        {read_concurrency, true}, {write_concurrency, true}]),
    ok = bus_operator_admission:init(Slots),
    Ingress = ets:new(bus_operator_ingress:table(), [named_table, set, public,
        {read_concurrency, true}, {write_concurrency, true}]),
    ok = bus_operator_ingress:init(Ingress),
    erlang:send_after(?EXPIRY_MS, self(), expire),
    {ok, #{slots => Slots, ingress => Ingress, events => bus_operator_events:new(),
           mons => #{}, obs_mons => #{}, observers => #{}, by_digest => #{},
           inflight => 0, last_expiry => undefined}}.

handle_call({op, _, _, _, _} = Request, From, State) ->
    handle_call_at(Request, From, State, clock());
handle_call({pull, Deadline, Ref, ConnPid}, _From, State0) ->
    Clock = clock(),
    case dispatch_time() >= Deadline of
        true -> {reply, {error, timeout}, State0};
        false ->
            State = expire_state(State0, Clock),
            {Reply, State1} = do_pull(Ref, ConnPid, Deadline, State, Clock),
            {reply, Reply, State1}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, invalid_request}, State}.

handle_call_at({op, Deadline, SlotRef, ConnPid, Op}, _From, #{slots := Tab} = State0,
               Clock) ->
    _ = bus_operator_admission:reclaim_dead(Tab),
    case bus_operator_admission:checkout(Tab, SlotRef, ConnPid) of
        stale -> {reply, {error, stale_slot}, State0};
        ok ->
            {Reply, State1} = case is_process_alive(ConnPid) of
                false -> {{error, stale_slot}, State0};
                true ->
                    case dispatch_time() >= Deadline of
                        true -> {{error, timeout}, State0};
                        false ->
                            State = expire_state(State0, Clock),
                            run_op(Op, State, Deadline, Clock)
                    end
            end,
            {reply, Reply, finish_slot(Tab, SlotRef, State1)}
    end.

handle_cast({release, Ref, Bytes}, State) ->
    {noreply, credit(Ref, Bytes, State)};
handle_cast({unsubscribe, Ref}, State) ->
    {noreply, drop_observer(Ref, State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({admit, SlotRef, ConnPid}, #{slots := Tab, mons := Mons} = State) ->
    case bus_operator_admission:checkout(Tab, SlotRef, ConnPid) of
        ok ->
            Mon = monitor(process, ConnPid),
            {noreply, State#{mons := Mons#{Mon => SlotRef}}};
        stale -> {noreply, State}
    end;
handle_info({'DOWN', Mon, process, _Pid, _Reason}, State0) ->
    #{slots := Tab, mons := Mons} = State0,
    case maps:take(Mon, Mons) of
        {SlotRef, Rest} ->
            bus_operator_admission:release(Tab, SlotRef),
            {noreply, State0#{mons := Rest}};
        error ->
            case maps:get(obs_mons, State0, #{}) of
                #{Mon := Ref} ->
                    {noreply, drop_observer(Ref, State0)};
                _ -> {noreply, State0}
            end
    end;
handle_info(drain, State) ->
    {noreply, wake(ingest(State, clock()))};
handle_info(expire, State0) ->
    Clock = clock(),
    State1 = expire_state(ingest(State0, Clock), Clock),
    State = reap_observers(State1),
    #{slots := Tab} = State,
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

run_op({page, Cursor}, #{events := Events} = State, Deadline, {Now, _Wall}) ->
    {Reply, Next} = bus_operator_events:page(Cursor, Now, Deadline, Events),
    case Reply of
        {ok, Bin} -> {{ok, Bin}, State#{events := Next}};
        {error, Reason} -> {{error, Reason}, State#{events := Next}}
    end;
run_op({search, Filter, Cursor}, #{events := Events} = State, Deadline, {Now, _Wall}) ->
    {Reply, Next} = bus_operator_events:search(Filter, Cursor, Now, Deadline, Events),
    case Reply of
        {ok, Bin} -> {{ok, Bin}, State#{events := Next}};
        {error, Reason} -> {{error, Reason}, State#{events := Next}}
    end;
run_op({subscribe, Digest, Pid}, State, _Deadline, _Clock) ->
    subscribe_obs(Digest, Pid, State);
run_op(_, State, _, _) ->
    {{error, invalid_request}, State}.

subscribe_obs(Digest, Pid, State0) ->
    By = maps:get(by_digest, State0),
    case maps:find(Digest, By) of
        {ok, OldRef} ->
            case maps:find(OldRef, maps:get(observers, State0)) of
                {ok, #{pid := OldPid}} ->
                    case is_process_alive(OldPid) of
                        true -> {{error, conflict}, State0};
                        false -> subscribe_fresh(Digest, Pid, drop_observer(OldRef, State0))
                    end;
                error -> subscribe_fresh(Digest, Pid, State0)
            end;
        error -> subscribe_fresh(Digest, Pid, State0)
    end.

subscribe_fresh(Digest, Pid, State) ->
    Observers = maps:get(observers, State),
    case map_size(Observers) >= ?MAX_OBS of
        true -> {{error, capacity}, State};
        false ->
            Ref = make_ref(),
            Mon = monitor(process, Pid),
            Rec = #{digest => Digest, pid => Pid, mon => Mon,
                    obs => bus_operator_events:observer(), inflight => 0,
                    pulling => false},
            Pid ! {journal, Ref, wake},
            {{ok, Ref}, State#{
                observers := Observers#{Ref => Rec},
                by_digest := (maps:get(by_digest, State))#{Digest => Ref},
                obs_mons := (maps:get(obs_mons, State))#{Mon => Ref}}}
    end.

do_pull(Ref, Pid, Deadline, #{observers := Observers} = State, {Now, _Wall}) ->
    case maps:find(Ref, Observers) of
        {ok, #{pid := Pid, pulling := true}} ->
            {empty, State};
        {ok, #{pid := Pid, obs := Obs, inflight := Local} = Rec} ->
            Events = maps:get(events, State),
            case bus_operator_events:pull(Obs, Now, Deadline, Events) of
                {empty, Obs1, Events1} ->
                    {empty, State#{events := Events1,
                        observers := Observers#{Ref => Rec#{obs := Obs1}}}};
                {error, Reason, Obs1, Events1} ->
                    {{error, Reason}, State#{events := Events1,
                        observers := Observers#{Ref => Rec#{obs := Obs1}}}};
                {frame, Bin, More, Obs1, Events1} ->
                    Size = iolist_size(cow_sse:events([#{event => <<"observation">>, data => Bin}])),
                    Total = maps:get(inflight, State) + Size,
                    case Size > 524288 orelse Total > ?MAX_INFLIGHT of
                        true -> {{error, overloaded}, State};
                        false ->
                            Rec1 = Rec#{obs := Obs1, inflight := Local + Size, pulling := true},
                            {{frame, Bin, More, Size}, State#{
                                events := Events1,
                                inflight := Total,
                                observers := Observers#{Ref => Rec1}}}
                    end
            end;
        _ -> {{error, stale_slot}, State}
    end.

wake(#{observers := Observers} = State) ->
    Observers1 = maps:map(fun(Ref, Rec) ->
        case bus_operator_events:signal(maps:get(obs, Rec)) of
            {quiet, _} -> Rec;
            {wake, Obs1} ->
                maps:get(pid, Rec) ! {journal, Ref, wake},
                Rec#{obs := Obs1}
        end
    end, Observers),
    State#{observers := Observers1}.

credit(Ref, Bytes, #{observers := Observers, inflight := Total} = State) ->
    case maps:find(Ref, Observers) of
        {ok, #{inflight := Bytes} = Rec} when Bytes > 0 ->
            State#{inflight := Total - Bytes,
                   observers := Observers#{Ref => Rec#{inflight := 0, pulling := false}}};
        _ -> State
    end.

drop_observer(Ref, State) -> drop_observer(Ref, State, gone).

drop_observer(Ref, #{observers := Observers} = State, Why) ->
    case maps:take(Ref, Observers) of
        error -> State;
        {Rec, Rest} ->
            case Why of replaced -> maps:get(pid, Rec) ! {journal, Ref, replaced}; _ -> ok end,
            demonitor(maps:get(mon, Rec), [flush]),
            Digest = maps:get(digest, Rec),
            Local = maps:get(inflight, Rec),
            By = maps:remove(Digest, maps:get(by_digest, State)),
            Mons = maps:remove(maps:get(mon, Rec), maps:get(obs_mons, State)),
            State#{observers := Rest, by_digest := By, obs_mons := Mons,
                   inflight := max(0, maps:get(inflight, State) - Local)}
    end.

reap_observers(#{observers := Observers} = State) ->
    maps:fold(fun(Ref, Rec, Acc) ->
        case is_process_alive(maps:get(pid, Rec)) of
            true -> Acc;
            false -> drop_observer(Ref, Acc)
        end
    end, State, Observers).

ingest(#{ingress := Tab, events := Events0} = State, {Now, Wall}) ->
    case bus_operator_ingress:take(Tab, self()) of
        {ok, Recs, Dropped} ->
            Events1 = lists:foldl(fun(Rec, Acc) ->
                ingest_record(Rec, Now, Wall, Acc)
            end, Events0, Recs),
            Events2 = case bus_operator_events:apply_drops(Dropped, Now, Wall, Events1) of
                {ok, E} -> E;
                {error, _, E} -> E;
                _ -> Events1
            end,
            State#{events := Events2};
        {error, _} -> State
    end.


ingest_record(Rec, Now, Wall, Acc) ->
    case bus_operator_events:ingest(Rec, Now, Wall, Acc) of
        {ok, Next} -> Next;
        {error, sequence_exhausted, _} ->
            Seen = bus_operator_events:dropped_seen(Acc),
            Fresh = maps:put(dropped_seen, Seen, bus_operator_events:new()),
            case bus_operator_events:ingest(Rec, Now, Wall, Fresh) of
                {ok, Next} -> Next;
                {error, _, Next} -> Next;
                _ -> Fresh
            end;
        {error, _, Next} -> Next;
        _ -> Acc
    end.

expire_state(#{events := Events, last_expiry := Last} = State, {Now, _Wall}) ->
    case Last =:= Now of
        true -> State;
        false -> State#{events := bus_operator_events:expire(Now, Events), last_expiry := Now}
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

%% Now = monotonic seconds (retention). Wall = UNIX seconds (observedAt).
clock() -> {erlang:monotonic_time(second), erlang:system_time(second)}.

dispatch_time() -> erlang:monotonic_time(millisecond).
