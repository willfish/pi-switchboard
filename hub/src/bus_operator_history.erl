-module(bus_operator_history).

%% Protected collection policy. Native owner writes. Producers may read
%% without calling the native process. Missing table or mismatch is false.
-export([table/0, init/1, granted/3, current/1, put/4, delete/1, reset/0, limit/0]).

-define(TABLE, bus_operator_history).
-define(LIMIT, 5000).

table() -> ?TABLE.
limit() -> ?LIMIT.

init(Tab) ->
    true = ets:info(Tab, owner) =:= self(),
    ok.

granted(StorePid, AgentId, Gen)
  when is_pid(StorePid), is_binary(AgentId), is_integer(Gen), Gen >= 0 ->
    try
        case ets:lookup(?TABLE, AgentId) of
            [{AgentId, {StorePid, Gen}}] -> true;
            _ -> false
        end
    catch
        _:_ -> false
    end;
granted(_, _, _) -> false.

current(AgentId) when is_binary(AgentId) ->
    try
        case ets:lookup(?TABLE, AgentId) of
            [{AgentId, {Pid, Gen}}] when is_pid(Pid), is_integer(Gen) -> true;
            _ -> false
        end
    catch
        _:_ -> false
    end;
current(_) -> false.

put(StorePid, AgentId, Gen, true)
  when is_pid(StorePid), is_binary(AgentId), is_integer(Gen), Gen >= 0 ->
    owner_write(fun() ->
        case ets:member(?TABLE, AgentId) orelse ets:info(?TABLE, size) < ?LIMIT of
            true -> ets:insert(?TABLE, {AgentId, {StorePid, Gen}});
            false -> true
        end
    end);
put(StorePid, AgentId, Gen, false)
  when is_pid(StorePid), is_binary(AgentId), is_integer(Gen) ->
    delete(AgentId);
put(_, _, _, _) -> ok.

delete(AgentId) when is_binary(AgentId) ->
    owner_write(fun() -> ets:delete(?TABLE, AgentId) end);
delete(_) -> ok.

reset() ->
    owner_write(fun() -> ets:delete_all_objects(?TABLE) end).

owner_write(Fun) ->
    try
        case ets:info(?TABLE, owner) of
            Pid when Pid =:= self() -> Fun(), ok;
            _ -> ok
        end
    catch
        _:_ -> ok
    end.
