-module(bus_operator_admission).

%% Owner-RPC admission only. This does not bound whole HTTP or observer
%% lifetime; that remains a later gate. One versioned ETS row holds at most
%% 128 reservations. Session occupancy is derived from that map. Callers
%% occupy a reservation before any owner RPC and never remove. Release and
%% reclaim run only on the owner process. Competing callers can only add, so
%% a CAS loses to at most 128 inserts; cleanup therefore cannot spin. Caller
%% timeout must not release while the call may still be queued. Never follow a
%% replaced named table with a stale owner PID: capture the TID and check ets
%% owner on each CAS.
-export([table/0, tid/1, limit/0, session_limit/0, init/1,
         acquire/4, release/2, checkout/3, reclaim_dead/1, occupied/1]).

-define(TABLE, bus_operator_auth_slots).
-define(GLOBAL, 128).
-define(SESSION, 4).

table() -> ?TABLE.
limit() -> ?GLOBAL.
session_limit() -> ?SESSION.

tid(OwnerPid) when is_pid(OwnerPid) ->
    case ets:info(?TABLE, owner) of
        OwnerPid -> ets:info(?TABLE, id);
        _ -> undefined
    end;
tid(_) -> undefined.

init(Tab) ->
    true = ets:insert(Tab, {state, 0, #{}}),
    ok.

acquire(Tab, OwnerPid, ConnPid, Key) when is_pid(OwnerPid), is_pid(ConnPid) ->
    case is_process_alive(ConnPid) of
        false -> {error, unavailable};
        true ->
            try cas(Tab, OwnerPid, fun(Map) -> insert_res(Map, ConnPid, Key) end)
            catch error:badarg -> {error, unavailable}
            end
    end;
acquire(_, _, _, _) -> {error, unavailable}.

release(Tab, Ref) ->
    case ets:info(Tab, owner) of
        Owner when Owner =:= self() ->
            try cas(Tab, Owner, fun(Map) -> drop_res(Map, Ref) end)
            catch error:badarg -> ok
            end;
        _ -> ok
    end,
    ok.

checkout(Tab, Ref, Pid) ->
    try
        case ets:lookup(Tab, state) of
            [{state, _, #{Ref := {Pid, _}}}] -> ok;
            _ -> stale
        end
    catch
        error:badarg -> stale
    end.

reclaim_dead(Tab) ->
    case ets:info(Tab, owner) of
        Owner when Owner =:= self() ->
            try cas(Tab, Owner, fun drop_dead/1) of
                {ok, N} when is_integer(N) -> N;
                _ -> 0
            catch
                error:badarg -> 0
            end;
        _ -> 0
    end.

occupied(Tab) ->
    try
        case ets:lookup(Tab, state) of
            [{state, _, Map}] -> map_size(Map);
            _ -> 0
        end
    catch
        error:badarg -> 0
    end.

cas(Tab, OwnerPid, Fun) -> cas(Tab, OwnerPid, Fun, 0).
cas(_Tab, _OwnerPid, _Fun, N) when N > ?GLOBAL -> {error, overloaded};
cas(Tab, OwnerPid, Fun, N) ->
    case ets:info(Tab, owner) of
        OwnerPid when is_pid(OwnerPid) ->
            case ets:lookup(Tab, state) of
                [{state, V, Map}] ->
                    case Fun(Map) of
                        {error, Reason} -> {error, Reason};
                        unchanged -> {ok, 0};
                        {ok, New, Result} ->
                            case ets:select_replace(Tab, [{{state, V, Map}, [],
                                    [{const, {state, V + 1, New}}]}]) of
                                1 -> {ok, Result};
                                0 -> cas(Tab, OwnerPid, Fun, N + 1)
                            end
                    end;
                _ -> {error, unavailable}
            end;
        _ -> {error, unavailable}
    end.

insert_res(Map, ConnPid, Key) ->
    case map_size(Map) >= ?GLOBAL orelse session_full(Map, Key) of
        true -> {error, overloaded};
        false ->
            Ref = make_ref(),
            {ok, Map#{Ref => {ConnPid, Key}}, Ref}
    end.

drop_res(Map, Ref) ->
    case maps:take(Ref, Map) of
        error -> unchanged;
        {_, New} -> {ok, New, ok}
    end.

drop_dead(Map) ->
    Dead = [Ref || Ref := {Pid, _} <- Map, not is_process_alive(Pid)],
    case Dead of
        [] -> unchanged;
        _ -> {ok, maps:without(Dead, Map), length(Dead)}
    end.

session_full(_Map, bootstrap) -> false;
session_full(Map, {session, Digest}) ->
    maps:fold(fun(_, {_, {session, D}}, N) when D =:= Digest -> N + 1;
                 (_, _, N) -> N
              end, 0, Map) >= ?SESSION;
session_full(_, _) -> true.
