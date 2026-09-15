-module(bus_operator_http_gate).
-behaviour(gen_server).

%% HTTP-lifetime operator admission. Distinct ETS table from owner-RPC slots.
%% Callers acquire before owner work; permits are held until the connection PID
%% dies, not until the auth RPC returns. A restarted gate does not bound old
%% live connections: handlers must treat a stale slot ref as unavailable and
%% must not reacquire. Production supervision must keep operator admission
%% unavailable after gate-state loss until transport recovery has closed those
%% connections. Dependency-free init. Owner-RPC admission does not bound this
%% layer.
-export([start_link/0, table/0, acquire/2, checkout/2, occupied/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).

-define(TABLE, bus_operator_http_slots).
-define(EXPIRY_MS, 1000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

table() -> ?TABLE.

acquire(ConnPid, Key) when is_pid(ConnPid) ->
    case whereis(?MODULE) of
        undefined -> {error, unavailable};
        Pid ->
            case tid(Pid) of
                undefined -> {error, unavailable};
                Tab ->
                    try bus_operator_admission:acquire(Tab, Pid, ConnPid, Key) of
                        {error, Reason} -> {error, Reason};
                        {ok, Ref} ->
                            Pid ! {admit, Ref, ConnPid},
                            {ok, Ref}
                    catch
                        _:_ -> {error, unavailable}
                    end
            end
    end;
acquire(_, _) -> {error, unavailable}.

checkout(Ref, ConnPid) ->
    case tid(whereis(?MODULE)) of
        undefined -> stale;
        Tab -> bus_operator_admission:checkout(Tab, Ref, ConnPid)
    end.

occupied() ->
    case tid(whereis(?MODULE)) of
        undefined -> 0;
        Tab -> bus_operator_admission:occupied(Tab)
    end.

tid(OwnerPid) when is_pid(OwnerPid) ->
    case ets:info(?TABLE, owner) of
        OwnerPid -> ets:info(?TABLE, id);
        _ -> undefined
    end;
tid(_) -> undefined.

init([]) ->
    Tab = ets:new(?TABLE, [named_table, set, public,
        {read_concurrency, true}, {write_concurrency, true}]),
    ok = bus_operator_admission:init(Tab),
    erlang:send_after(?EXPIRY_MS, self(), expire),
    {ok, #{tab => Tab, mons => #{}}}.

handle_call(_Request, _From, State) ->
    {reply, {error, invalid_request}, State}.

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
