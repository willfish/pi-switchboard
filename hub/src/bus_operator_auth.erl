-module(bus_operator_auth).
-behaviour(gen_server).

%% Dependency-independent session owner around bus_operator_sessions.
%% Cryptographic nonces, one monotonic instant per callback, redacted status.
%% No interface lookups in init. bus_operator_admission is owner-RPC admission
%% only; it does not bound whole HTTP or observer lifetime.
-export([start_link/0, start_link/1, bootstrap/4, authorize/4, disconnect/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).

-ifdef(TEST).
-export([handle_call_at/4]).
-endif.

-define(EXPIRY_MS, 1000).

start_link() -> start_link(#{}).
start_link(Overrides) when is_map(Overrides) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Overrides, []).

bootstrap(Peer, Origin, ConnPid, Deadline) ->
    call(ConnPid, bootstrap, {bootstrap, Peer, Origin}, Deadline).

authorize(Nonce, Origin, ConnPid, Deadline) ->
    case valid_nonce(Nonce) of
        false -> {error, unauthorized};
        true -> call(ConnPid, {session, crypto:hash(sha256, Nonce)},
            {authorize, Nonce, Origin}, Deadline)
    end.

disconnect(Nonce, Origin, ConnPid, Deadline) ->
    case valid_nonce(Nonce) of
        false -> {error, unauthorized};
        true -> call(ConnPid, {session, crypto:hash(sha256, Nonce)},
            {disconnect, Nonce, Origin}, Deadline)
    end.

valid_nonce(N) -> is_binary(N) andalso byte_size(N) =:= 32.

call(ConnPid, Key, Op, Deadline) when is_pid(ConnPid), is_integer(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Remaining when Remaining =< 0 -> {error, timeout};
        _ ->
            case whereis(?MODULE) of
                undefined -> {error, unavailable};
                Pid -> admit(Pid, ConnPid, Key, Op, Deadline)
            end
    end;
call(_, _, _, _) -> {error, invalid_request}.

admit(Pid, ConnPid, Key, Op, Deadline) ->
    case bus_operator_admission:tid(Pid) of
        undefined -> {error, unavailable};
        Tab ->
            try bus_operator_admission:acquire(Tab, Pid, ConnPid, Key) of
                {error, Reason} -> {error, Reason};
                {ok, SlotRef} ->
                    %% Slot stays occupied if this call times out: the owner may
                    %% still have the message queued. Release is owner-side only.
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

init(Overrides) ->
    Tab = ets:new(bus_operator_admission:table(), [named_table, set, public,
        {read_concurrency, true}, {write_concurrency, true}]),
    ok = bus_operator_admission:init(Tab),
    erlang:send_after(?EXPIRY_MS, self(), expire),
    {ok, #{tab => Tab, sessions => bus_operator_sessions:new(Overrides),
           mons => #{}, last_expiry => undefined}}.

handle_call({op, _, _, _, _} = Request, From, State) ->
    handle_call_at(Request, From, State, mono());
handle_call(_Request, _From, State) ->
    {reply, {error, invalid_request}, State}.

handle_call_at({op, Deadline, SlotRef, ConnPid, Op}, _From, #{tab := Tab} = State0, Now) ->
    %% Now is the single model-expiry sample. Dispatch uses a fresh monotonic
    %% read so cleanup/CAS cannot commit after the real deadline.
    State = expire_state(State0, Now),
    _ = bus_operator_admission:reclaim_dead(Tab),
    case bus_operator_admission:checkout(Tab, SlotRef, ConnPid) of
        stale -> {reply, {error, stale_slot}, State};
        ok ->
            {Reply, State1} = case is_process_alive(ConnPid) of
                false -> {{error, stale_slot}, State};
                true ->
                    case dispatch_time() >= Deadline of
                        true -> {{error, timeout}, State};
                        false -> run_op(Op, State, Now)
                    end
            end,
            {reply, Reply, finish_slot(Tab, SlotRef, State1)}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({admit, SlotRef, ConnPid}, #{tab := Tab, mons := Mons} = State) ->
    case bus_operator_admission:checkout(Tab, SlotRef, ConnPid) of
        ok ->
            Mon = monitor(process, ConnPid),
            {noreply, State#{mons := Mons#{Mon => SlotRef}}};
        stale -> {noreply, State}
    end;
handle_info({'DOWN', Mon, process, _Pid, _Reason}, #{tab := Tab, mons := Mons} = State) ->
    case maps:take(Mon, Mons) of
        {SlotRef, Rest} ->
            bus_operator_admission:release(Tab, SlotRef),
            {noreply, State#{mons := Rest}};
        error -> {noreply, State}
    end;
handle_info(expire, #{tab := Tab} = State) ->
    State1 = expire_state(State, mono()),
    _ = bus_operator_admission:reclaim_dead(Tab),
    erlang:send_after(?EXPIRY_MS, self(), expire),
    {noreply, State1};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% OTP may add status fields. Preserve keys, never their input-bearing values.
format_status(Status) ->
    maps:map(fun(log, _) -> [];
                (_, _) -> redacted
             end, Status).

expire_state(#{sessions := Sessions, last_expiry := Last} = State, Now) ->
    case Last =:= Now of
        true -> State;
        false -> State#{sessions := bus_operator_sessions:sweep(Now, Sessions), last_expiry := Now}
    end.

run_op({bootstrap, Peer, Origin}, #{sessions := Sessions} = State, Now) ->
    try crypto:strong_rand_bytes(32) of
        Nonce ->
            case bus_operator_sessions:bootstrap(Peer, Origin, Nonce, Now, Sessions) of
                {ok, Next} -> {{ok, Nonce}, State#{sessions := Next}};
                {error, Reason, Next} -> {{error, Reason}, State#{sessions := Next}}
            end
    catch
        _:_ -> {{error, unavailable}, State}
    end;
run_op({authorize, Nonce, Origin}, #{sessions := Sessions} = State, Now) ->
    {bus_operator_sessions:authorize(Nonce, Origin, Now, Sessions), State};
run_op({disconnect, Nonce, Origin}, #{sessions := Sessions} = State, Now) ->
    case bus_operator_sessions:disconnect(Nonce, Origin, Now, Sessions) of
        {ok, Next} -> {ok, State#{sessions := Next}};
        {error, unauthorized, Next} -> {{error, unauthorized}, State#{sessions := Next}}
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

mono() -> erlang:monotonic_time(millisecond).

dispatch_time() -> erlang:monotonic_time(millisecond).
