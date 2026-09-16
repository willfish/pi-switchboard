-module(bus_operator_ops).
-behaviour(gen_server).

%% Operation owner. Volatile. Init does not call core. Native lookup is used
%% at create/result time; mail is never popped.
-export([start_link/0, create/4, status/4, cancel/4, list/4, requests/3, content/4,
         result/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         format_status/1]).

-define(EXPIRY_MS, 1000).
-define(SLOTS, bus_operator_ops_slots).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

create(ConnPid, Digest, Doc, Deadline)
  when is_pid(ConnPid), is_binary(Digest), is_map(Doc), is_integer(Deadline) ->
    call(ConnPid, {session, Digest}, {create, Digest, Doc}, Deadline);
create(_, _, _, _) -> {error, invalid_schema}.

status(ConnPid, Digest, OpId, Deadline)
  when is_pid(ConnPid), is_binary(Digest), is_binary(OpId), is_integer(Deadline) ->
    call(ConnPid, {session, Digest}, {status, Digest, OpId}, Deadline);
status(_, _, _, _) -> {error, invalid_schema}.

cancel(ConnPid, Digest, OpId, Deadline)
  when is_pid(ConnPid), is_binary(Digest), is_binary(OpId), is_integer(Deadline) ->
    call(ConnPid, {session, Digest}, {cancel, Digest, OpId}, Deadline);
cancel(_, _, _, _) -> {error, invalid_schema}.

list(ConnPid, Digest, AgentId, Deadline)
  when is_pid(ConnPid), is_binary(Digest), is_binary(AgentId), is_integer(Deadline) ->
    call(ConnPid, {session, Digest}, {list, Digest, AgentId}, Deadline);
list(_, _, _, _) -> {error, invalid_schema}.

requests(ConnPid, AgentId, Deadline)
  when is_pid(ConnPid), is_binary(AgentId), is_integer(Deadline) ->
    call(ConnPid, {session, AgentId}, {requests, AgentId}, Deadline);
requests(_, _, _) -> {error, invalid_schema}.

content(ConnPid, AgentId, OpId, ContentId, Deadline)
  when is_pid(ConnPid), is_binary(OpId), is_binary(ContentId), is_integer(Deadline) ->
    call(ConnPid, {session, AgentId}, {content, OpId, ContentId}, Deadline).

content(ConnPid, OpId, ContentId, Deadline) ->
    content(ConnPid, OpId, OpId, ContentId, Deadline).

result(ConnPid, Doc, Deadline)
  when is_pid(ConnPid), is_map(Doc), is_integer(Deadline) ->
    AgentId = maps:get(<<"agentId">>, Doc, <<>>),
    call(ConnPid, {session, AgentId}, {result, Doc}, Deadline);
result(_, _, _) -> {error, invalid_schema}.

call(ConnPid, Key, Op, Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Remaining when Remaining =< 0 -> {error, timeout};
        _ ->
            case whereis(?MODULE) of
                undefined -> {error, unavailable};
                Pid -> admit(Pid, ConnPid, Key, Op, Deadline)
            end
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
    {ok, #{slots => Tab, ops => bus_operator_operations:new(), mons => #{}}}.

handle_call({op, Deadline, SlotRef, ConnPid, Op}, _From, #{slots := Tab} = State0) ->
    Mono = erlang:monotonic_time(millisecond),
    Now = erlang:system_time(millisecond),
    _ = bus_operator_admission:reclaim_dead(Tab),
    case bus_operator_admission:checkout(Tab, SlotRef, ConnPid) of
        stale -> {reply, {error, stale_slot}, State0};
        ok ->
            {Reply, State1} = case is_process_alive(ConnPid) of
                false -> {{error, stale_slot}, State0};
                true when Mono >= Deadline -> {{error, timeout}, State0};
                true -> run_op(Op, State0, Deadline, Now, ConnPid)
            end,
            {reply, Reply, finish_slot(Tab, SlotRef, State1)}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, invalid_request}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

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
handle_info(expire, #{slots := Tab, ops := Ops} = State) ->
    Now = erlang:system_time(millisecond),
    _ = bus_operator_admission:reclaim_dead(Tab),
    erlang:send_after(?EXPIRY_MS, self(), expire),
    {Ops1, Expired} = bus_operator_operations:expire(Now, Ops),
    lists:foreach(fun(Public) ->
        observe(<<"operator_result">>, <<"relay_observed">>, Public)
    end, Expired),
    {noreply, State#{ops := Ops1}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.

format_status(Status) ->
    maps:map(fun(log, _) -> [];
                (_, _) -> redacted
             end, Status).

run_op({create, Digest, Doc}, State, Deadline, Now, ConnPid) ->
    AgentId = maps:get(<<"agentId">>, Doc, undefined),
    case bus_operator_native:lookup(ConnPid, AgentId, Deadline) of
        {error, Reason} -> {{error, Reason}, State};
        {ok, View} ->
            case past(Deadline) of
                true -> {{error, timeout}, State};
                false ->
                    case bus_operator_operations:create(Doc, View, Digest, Now,
                            maps:get(ops, State)) of
                        {error, Reason} -> {{error, Reason}, State};
                        {ok, Public, duplicate, Ops} ->
                            case past(Deadline) of
                                true -> {{error, timeout}, State};
                                false -> {{ok, Public}, State#{ops := Ops}}
                            end;
                        {ok, Public, created, Ops} ->
                            case past(Deadline) of
                                true -> {{error, timeout}, State};
                                false ->
                                    observe(<<"operator_requested">>, <<"operator_requested">>,
                                        Public, request_body(Public, Doc, View)),
                                    {{ok, Public}, State#{ops := Ops}}
                            end
                    end
            end
    end;
run_op({list, Digest, AgentId}, State, Deadline, _Now, _ConnPid) ->
    case past(Deadline) of
        true -> {{error, timeout}, State};
        false ->
            case bus_operator_operations:list(AgentId, Digest, maps:get(ops, State)) of
                {error, Reason} -> {{error, Reason}, State};
                {ok, Page} -> {{ok, Page}, State}
            end
    end;
run_op({status, Digest, OpId}, State, Deadline, _Now, _ConnPid) ->
    case past(Deadline) of
        true -> {{error, timeout}, State};
        false ->
            case bus_operator_operations:status(OpId, Digest, maps:get(ops, State)) of
                {error, Reason} -> {{error, Reason}, State};
                {ok, Public} -> {{ok, Public}, State}
            end
    end;
run_op({cancel, Digest, OpId}, State, Deadline, Now, _ConnPid) ->
    case past(Deadline) of
        true -> {{error, timeout}, State};
        false ->
            case bus_operator_operations:cancel(OpId, Digest, Now, maps:get(ops, State)) of
                {error, Reason} -> {{error, Reason}, State};
                {ok, Public, Changed, Ops} ->
                    case past(Deadline) of
                        true -> {{error, timeout}, State};
                        false ->
                            case Changed of
                                true -> observe(<<"operator_result">>, <<"operator_requested">>, Public);
                                false -> ok
                            end,
                            {{ok, Public}, State#{ops := Ops}}
                    end
            end
    end;
run_op({requests, AgentId}, State, Deadline, Now, ConnPid) ->
    case bus_operator_native:lookup(ConnPid, AgentId, Deadline) of
        {error, Reason} -> {{error, Reason}, State};
        {ok, View} ->
            case past(Deadline) of
                true -> {{error, timeout}, State};
                false ->
                    WorkId = snapshot_work_id(View),
                    case bus_operator_operations:requests(AgentId, WorkId, Now,
                            maps:get(ops, State)) of
                        {error, Reason} -> {{error, Reason}, State};
                        {ok, List, Ops} -> {{ok, List}, State#{ops := Ops}}
                    end
            end
    end;
run_op({content, OpId, ContentId}, State, Deadline, _Now, ConnPid) ->
    case past(Deadline) of
        true -> {{error, timeout}, State};
        false ->
            case bus_operator_operations:status(OpId, maps:get(ops, State)) of
                {error, Reason} -> {{error, Reason}, State};
                {ok, Public} ->
                    AgentId = maps:get(<<"agentId">>, Public),
                    WorkId = case bus_operator_native:lookup(ConnPid, AgentId, Deadline) of
                        {ok, View} -> snapshot_work_id(View);
                        {error, _} -> mismatch
                    end,
                    case bus_operator_operations:content(OpId, ContentId, WorkId,
                            maps:get(ops, State)) of
                        {error, Reason} -> {{error, Reason}, State};
                        {ok, Body, Ops} -> {{ok, Body}, State#{ops := Ops}}
                    end
            end
    end;
run_op({result, Doc}, State, Deadline, Now, ConnPid) ->
    AgentId = maps:get(<<"agentId">>, Doc, undefined),
    case bus_operator_native:lookup(ConnPid, AgentId, Deadline) of
        {error, Reason} -> {{error, Reason}, State};
        {ok, View} ->
            case past(Deadline) of
                true -> {{error, timeout}, State};
                false ->
                    case bus_operator_operations:result(Doc, View, Now, maps:get(ops, State)) of
                        {error, Reason} -> {{error, Reason}, State};
                        {ok, Ack, Changed, Ops} ->
                            case past(Deadline) of
                                true -> {{error, timeout}, State};
                                false ->
                                    case Changed of
                                        true ->
                                            case bus_operator_operations:status(
                                                    maps:get(<<"operationId">>, Ack), Ops) of
                                                {ok, Public} ->
                                                    observe(<<"operator_result">>, <<"client_reported">>, Public);
                                                _ -> ok
                                            end;
                                        false -> ok
                                    end,
                                    {{ok, Ack}, State#{ops := Ops}}
                            end
                    end
            end
    end;
run_op(_, State, _, _, _) ->
    {{error, invalid_request}, State}.

observe(Kind, Source, Public) -> observe(Kind, Source, Public, undefined).

observe(Kind, Source, Public, Body) when is_map(Public), is_binary(Source) ->
    Pay0 = #{
        <<"action">> => maps:get(<<"kind">>, Public),
        <<"state">> => maps:get(<<"state">>, Public)
    },
    Pay = case Body of
        Bin when is_binary(Bin), byte_size(Bin) > 0, byte_size(Bin) =< 16384 ->
            Pay0#{<<"body">> => Bin};
        _ -> Pay0
    end,
    bus_operator_updates:publish(browser),
    case Kind of
        <<"operator_requested">> -> bus_operator_updates:publish(maps:get(<<"agentId">>, Public, null));
        _ -> ok
    end,
    bus_operator_journal:offer(#{
        <<"kind">> => Kind,
        <<"source">> => Source,
        <<"agentId">> => maps:get(<<"agentId">>, Public, null),
        <<"sessionId">> => maps:get(<<"sessionId">>, Public, null),
        <<"operationId">> => maps:get(<<"operationId">>, Public, null),
        <<"threadId">> => maps:get(<<"operationId">>, Public, null),
        <<"occurredAt">> => erlang:system_time(second),
        <<"payload">> => Pay
    });
observe(_, _, _, _) -> ok.

request_body(Public, Doc, View) ->
    case maps:get(<<"history">>, maps:get(permissions, View, #{}), false) of
        true ->
            case maps:get(<<"kind">>, Public) of
                K when K =:= <<"notice">>; K =:= <<"work">>; K =:= <<"guidance">> ->
                    maps:get(<<"text">>, maps:get(<<"payload">>, Doc, #{}), undefined);
                _ -> undefined
            end;
        _ -> undefined
    end.

snapshot_work_id(#{work := Work}) when is_map(Work) ->
    maps:get(<<"workId">>, Work, null);
snapshot_work_id(_) -> null.

past(Deadline) ->
    erlang:monotonic_time(millisecond) >= Deadline.

finish_slot(Tab, SlotRef, #{mons := Mons} = State) ->
    bus_operator_admission:release(Tab, SlotRef),
    State#{mons := maps:fold(fun(Mon, Ref, Acc) ->
        case Ref =:= SlotRef of
            true -> demonitor(Mon, [flush]), Acc;
            false -> Acc#{Mon => Ref}
        end
    end, #{}, Mons)}.
