-module(bus_store).
-behaviour(gen_server).

-export([
    start_link/0,
    put_agent/1, put_agent/2,
    delete_agent/1, delete_agent/2,
    list_agents/0, list_agents/1, list_agents_page/2,
    accept_mail/1, accept_mail/2,
    pop_mail/2, pop_mail/3,
    subscribe/2, subscribe/3,
    unsubscribe/2,
    pull_presence/2, pull_presence/3
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    format_status/1
]).

%% Exact-clock transition seam for boundary tests, absent from production exports.
-ifdef(TEST).
-export([handle_call_at/4]).
-endif.

-define(CALL_TIMEOUT_MS, 5000).
-define(SOFT_QUEUE_LIMIT, 4096).
-define(EXPIRY_MS, 1000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Explicit deadlines are absolute erlang:monotonic_time(millisecond) values.
put_agent(Agent) -> put_agent(Agent, deadline()).
put_agent(Agent, Deadline) -> call({put_agent, Agent}, Deadline).

delete_agent(AgentId) -> delete_agent(AgentId, deadline()).
delete_agent(AgentId, Deadline) -> call({delete_agent, AgentId}, Deadline).

list_agents() -> list_agents(deadline()).
list_agents(Deadline) -> call(list_agents, Deadline).
list_agents_page(Cursor, Deadline) -> call({list_agents_page, Cursor}, Deadline).

accept_mail(Msg) -> accept_mail(Msg, deadline()).
accept_mail(Msg, Deadline) -> call({accept_mail, Msg}, Deadline).

pop_mail(AgentId, Ref) -> pop_mail(AgentId, Ref, deadline()).
pop_mail(AgentId, Ref, Deadline) ->
    call({subscription, AgentId, Ref, pop_mail}, Deadline).

subscribe(AgentId, Pid) -> subscribe(AgentId, Pid, deadline()).
subscribe(AgentId, Pid, Deadline) -> call({subscribe, AgentId, Pid}, Deadline).

unsubscribe(AgentId, Ref) ->
    %% Cleanup casts and monitor DOWNs bypass admission: dropping a cast could
    %% strand readiness while its subscriber remains alive. These can overshoot
    %% the soft call threshold, as can concurrent callers and internal messages.
    gen_server:cast(?MODULE, {unsubscribe, AgentId, Ref}).

pull_presence(AgentId, Ref) -> pull_presence(AgentId, Ref, deadline()).
pull_presence(AgentId, Ref, Deadline) ->
    call({subscription, AgentId, Ref, pull_presence}, Deadline).

deadline() -> erlang:monotonic_time(millisecond) + ?CALL_TIMEOUT_MS.

call(Op, Deadline) when is_integer(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Remaining when Remaining =< 0 ->
            {error, timeout};
        _ ->
            case whereis(?MODULE) of
                undefined -> {error, unavailable};
                Pid -> admit(Pid, Op, Deadline)
            end
    end.

admit(Pid, Op, Deadline) ->
    %% Sampling is deliberately not a semaphore. Pin the sampled generation:
    %% its death must fail this operation, never retarget a replacement store.
    case process_info(Pid, message_queue_len) of
        undefined -> {error, unavailable};
        {message_queue_len, N} when N >= ?SOFT_QUEUE_LIMIT -> {error, overloaded};
        {message_queue_len, _} -> call_pid(Pid, Op, Deadline)
    end.

call_pid(Pid, Op, Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Remaining when Remaining =< 0 -> {error, timeout};
        Remaining ->
            try gen_server:call(Pid, {op, Deadline, Op}, Remaining)
            catch
                exit:{timeout, _} -> {error, timeout};
                %% Store termination/restart reasons can contain the request.
                %% Do not propagate or log them, and never replay the operation.
                exit:_ -> {error, unavailable}
            end
    end.

init([]) ->
    erlang:send_after(?EXPIRY_MS, self(), expire),
    {ok, #{
        model => bus_model:new(),
        subs => #{}, discovery => bus_discovery:new(),
        last_expiry => undefined, presence_dispatch => false
    }}.

handle_call(Request, From, State) ->
    handle_call_at(Request, From, State, clock()).

handle_call_at({op, Deadline, Op}, {Pid, _Tag}, State0, Clock) ->
    State = expire_state(State0, Clock),
    {Reply, State1} = run_op(Deadline, Op, Pid, State, Clock),
    {reply, Reply, State1}.

handle_cast({unsubscribe, AgentId, Ref}, State) ->
    Clock = clock(),
    {noreply, drop_sub(expire_state(State, Clock), AgentId, Ref, Clock)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(presence_dispatch, State) ->
    {noreply, dispatch_presence(State#{presence_dispatch := false})};
handle_info(expire, State) ->
    State1 = expire_state(State, clock()),
    erlang:send_after(?EXPIRY_MS, self(), expire),
    {noreply, State1};
handle_info({'DOWN', MRef, process, _Pid, _Reason}, State) ->
    Clock = clock(),
    {noreply, drop_sub_by_mon(expire_state(State, Clock), MRef, Clock)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% OTP may add status fields. Preserve keys, never their input-bearing values.
%% The outer sys status dictionary is outside this callback's contract.
format_status(Status) ->
    maps:map(fun(log, _) -> [];
                (_, _) -> redacted
             end, Status).

expire_state(State, {Now, _Wall} = Clock) ->
    case maps:get(last_expiry, State) =:= Now of
        true -> State;
        false ->
            Model0 = maps:get(model, State),
            Model1 = bus_model:expire(Model0, Now),
            Live = maps:get(agents, Model1),
            Dead = lists:sort([Id || Id <- maps:keys(maps:get(agents,Model0)), not maps:is_key(Id,Live)]),
            D = bus_discovery:expire(Now,maps:get(discovery,State)),
            State1 = lists:foldl(fun drop_sub_any/2, State#{model := Model1, last_expiry := Now, discovery := D}, Dead),
            lists:foldl(fun(Id, Acc) -> changed(Id, Acc, Clock) end, State1, Dead)
    end.

run_op(Deadline, Op, Pid, State, Clock) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            {{error, timeout}, State};
        false ->
            run_caller_op(Op, Pid, Deadline, State, Clock)
    end.

run_caller_op({subscription, AgentId, Ref, Op}, Pid, Deadline, State, Clock) ->
    case maps:get(AgentId, maps:get(subs, State), undefined) of
        #{pid := Pid, ref := Ref} ->
            do_sub_op(Op, AgentId, Deadline, State, Clock);
        _ ->
            {{error, stale_subscription}, State}
    end;
run_caller_op({list_agents_page, Cursor}, _Pid, Deadline, State, {Mono, Wall}) ->
    {Reply, D} = bus_discovery:page(Cursor, fun() -> bus_model:list_agents(maps:get(model,State),Mono,Wall) end,
        Mono, Wall, Deadline, maps:get(discovery,State)),
    {Reply, State#{discovery := D}};
run_caller_op(Op, _Pid, _Deadline, State, Clock) ->
    do_op(Op, State, Clock).

do_sub_op(pop_mail, AgentId, _Deadline, State, {Mono, _Wall}) ->
    case bus_model:pop_mail(maps:get(model, State), AgentId, Mono) of
        {empty, Model1} ->
            %% Empty observation and rearm must share this store transition.
            {{empty, undefined}, clear_wake(State#{model := Model1}, AgentId, mail_wake)};
        {ok, Model1, Msg} ->
            {{ok, bus_model:public_mail(Msg)}, State#{model := Model1}}
    end;
do_sub_op(pull_presence, AgentId, Deadline, State, {Mono, Wall}) ->
    Subs = maps:get(subs,State),
    Sub = maps:get(AgentId,Subs),
    Agents = fun() -> bus_model:list_agents(maps:get(model,State),Mono,Wall) end,
    {Reply, Progress, D} = bus_discovery:pull(maps:get(progress,Sub), Agents, Mono,Wall,Deadline,maps:get(discovery,State)),
    State1 = State#{discovery := D, subs := Subs#{AgentId := Sub#{progress := Progress}}},
    case Reply of
        empty -> {empty,clear_wake(State1,AgentId,presence_wake)};
        {frame,_,_,false} -> {Reply,clear_wake(State1,AgentId,presence_wake)};
        _ -> {Reply,State1}
    end.

do_op({put_agent, Agent}, State, {Mono, Wall} = Clock) ->
    Model0 = maps:get(model, State),
    case bus_model:put_agent(Model0, Agent, Mono, Wall) of
        {ok, Model1} ->
            Id = maps:get(<<"agentId">>, Agent),
            Old = maps:get(Id, maps:get(agents, Model0), #{}),
            New = maps:get(Id, maps:get(agents, Model1)),
            Changed = maps:without([last_mono, last_wall], Old) =/=
                maps:without([last_mono, last_wall], New),
            {ok, case Changed of true -> changed(Id, State#{model := Model1}, Clock); false -> State#{model := Model1} end};
        {error, Reason} ->
            {{error, Reason}, State}
    end;
do_op({delete_agent, AgentId}, State, {Mono, _Wall} = Clock) ->
    Existed = bus_model:has_agent(maps:get(model, State), AgentId, Mono),
    Model1 = bus_model:delete_agent(maps:get(model, State), AgentId),
    State1 = drop_sub_any(AgentId, State#{model := Model1}),
    {ok, case Existed of true -> changed(AgentId,State1,Clock); false -> State1 end};
do_op(list_agents, State, {Mono, Wall}) ->
    Agents = bus_model:list_agents(maps:get(model, State), Mono, Wall),
    {{ok, Agents}, State};
do_op({accept_mail, Msg}, State, {Mono, Wall}) ->
    case bus_model:accept_mail(maps:get(model, State), Msg, Mono, Wall) of
        {ok, Model1, Result} ->
            To = maps:get(<<"to">>, Msg),
            State1 = notify_mail(State#{model := Model1}, To),
            {{ok, Result}, State1};
        {error, Reason} ->
            {{error, Reason}, State}
    end;
do_op({subscribe, AgentId, Pid}, State, {Mono, _Wall} = Clock) ->
    case bus_model:has_agent(maps:get(model, State), AgentId, Mono) of
        false ->
            {{error, not_found}, State};
        true ->
            Ref = make_ref(),
            MRef = monitor(process, Pid),
            State1 = replace_sub(State, AgentId, Pid, MRef, Ref),
            Model1 = bus_model:set_receiving(maps:get(model, State1), AgentId, true),
            State2 = notify_mail(State1#{model := Model1}, AgentId),
            State3 = case maps:is_key(AgentId,maps:get(receiving,maps:get(model,State))) of
                true -> State2; false -> changed(AgentId,State2,Clock)
            end,
            {{ok, Ref}, notify_presence(State3, AgentId)}
    end.

replace_sub(State, AgentId, Pid, MRef, Ref) ->
    Subs0 = maps:get(subs, State),
    case maps:get(AgentId, Subs0, undefined) of
        undefined ->
            ok;
        #{pid := OldPid, mon := OldMon, ref := OldRef} ->
            demonitor(OldMon, [flush]),
            OldPid ! {bus, OldRef, replaced}
    end,
    Sub = #{pid => Pid, mon => MRef, ref => Ref, mail_wake => false, presence_wake => false, progress => start},
    State#{subs := Subs0#{AgentId => Sub}}.

drop_sub(State, AgentId, Ref, Clock) ->
    Subs = maps:get(subs, State),
    case maps:get(AgentId, Subs, undefined) of
        #{ref := Ref, mon := MRef} ->
            demonitor(MRef, [flush]),
            Model1 = bus_model:set_receiving(maps:get(model, State), AgentId, false),
            changed(AgentId, State#{subs := maps:remove(AgentId, Subs), model := Model1}, Clock);
        _ ->
            State
    end.

drop_sub_any(AgentId, State) ->
    Subs = maps:get(subs, State),
    case maps:get(AgentId, Subs, undefined) of
        undefined ->
            State;
        #{pid := Pid, mon := MRef, ref := Ref} ->
            demonitor(MRef, [flush]),
            Pid ! {bus, Ref, replaced},
            Model1 = bus_model:set_receiving(maps:get(model, State), AgentId, false),
            State#{subs := maps:remove(AgentId, Subs), model := Model1}
    end.

drop_sub_by_mon(State, MRef, Clock) ->
    Subs = maps:get(subs, State),
    case
        [
            Id
         || Id := #{mon := Mon} <- Subs,
            Mon =:= MRef
        ]
    of
        [AgentId] ->
            changed(AgentId, drop_sub_any(AgentId, State), Clock);
        _ ->
            State
    end.

clear_wake(State, AgentId, Key) ->
    Subs = maps:get(subs, State),
    case maps:get(AgentId, Subs, undefined) of
        undefined ->
            State;
        Sub ->
            State#{subs := Subs#{AgentId => Sub#{Key => false}}}
    end.

notify_mail(State, AgentId) ->
    Subs = maps:get(subs, State),
    case maps:get(AgentId, Subs, undefined) of
        #{mail_wake := false, pid := Pid, ref := Ref} = Sub ->
            Pid ! {bus, Ref, mail},
            State#{subs := Subs#{AgentId => Sub#{mail_wake => true}}};
        _ ->
            State
    end.

maybe_presence(State, false) ->
    State;
maybe_presence(#{presence_dispatch := true} = State, true) -> State;
maybe_presence(State, true) ->
    self() ! presence_dispatch,
    State#{presence_dispatch := true}.

changed(Id, State, {Mono, Wall}) ->
    Model = maps:get(model,State),
    Change = case maps:get(Id,maps:get(agents,Model),undefined) of
        undefined -> #{<<"op">> => <<"remove">>, <<"agentId">> => Id};
        Agent -> #{<<"op">> => <<"upsert">>, <<"agent">> => bus_model:public_agent(Agent,maps:is_key(Id,maps:get(receiving,Model)))}
    end,
    D = bus_discovery:record(Change,Mono,Wall,maps:get(discovery,State)),
    maybe_presence(State#{discovery := D},true).

notify_presence(State, AgentId) ->
    Subs = maps:get(subs,State),
    Sub = maps:get(AgentId,Subs),
    State#{subs := Subs#{AgentId := wake_presence(Sub)}}.

wake_presence(#{presence_wake := true} = Sub) -> Sub;
wake_presence(#{pid := Pid, ref := Ref} = Sub) ->
    Pid ! {bus,Ref,presence},
    Sub#{presence_wake := true}.

dispatch_presence(State) ->
    State#{subs := maps:map(fun(_,Sub) -> wake_presence(Sub) end,maps:get(subs,State))}.

%% TTL, display time and discovery revisions share one operation instant.
%% Absolute request deadlines deliberately continue to sample real milliseconds.
clock() -> {mono(), wall()}.

mono() ->
    erlang:monotonic_time(second).

wall() ->
    erlang:system_time(second).
