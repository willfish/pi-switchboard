-module(bus_operator_ingress).

%% Bounded producer buffer. CAS copies at most 128 records, never the journal.
%% Loss uses an independent monotonic ETS counter pinned to the table owner.
%% Producers must not call the journal owner. Overflow returns `dropped`
%% without throwing.
%%
%% Drop-only arming sets the drain flag; it is not a sent wake. A future owner
%% must periodically sample `dropped/1` independently of `drain/1`, including
%% after a failed one-shot arm CAS. Owner reads use a separate CAS that never
%% accounts producer loss.
-export([table/0, tid/1, init/1, limit/0, byte_limit/0, record_limit/0,
         try_in/3, try_in/4, take/2, dropped/1, occupied/1, drain/1,
         encoded_size/2]).

-ifdef(TEST).
-export([force_loss/1, force_owner_contention/1]).
-endif.

-define(TABLE, bus_operator_ingress).
-define(LIMIT, 128).
-define(BYTES, 1048576).
-define(RECORD, 98304).

table() -> ?TABLE.
limit() -> ?LIMIT.
byte_limit() -> ?BYTES.
record_limit() -> ?RECORD.

tid(OwnerPid) when is_pid(OwnerPid) ->
    case ets:info(?TABLE, owner) of
        OwnerPid -> ets:info(?TABLE, id);
        _ -> undefined
    end;
tid(_) -> undefined.

init(Tab) ->
    true = ets:insert(Tab, {state, 0, empty()}),
    true = ets:insert(Tab, {lost, 0}),
    ok.

empty() ->
    #{pending => [], pending_bytes => 0, drain => false}.

try_in(Tab, OwnerPid, Rec) -> try_in(Tab, OwnerPid, Rec, #{}).

try_in(Tab, OwnerPid, Rec, Opts) when is_pid(OwnerPid), is_map(Opts) ->
    case bus_operator_events:candidate(Rec, Opts) of
        {error, invalid_event} -> {error, invalid_record};
        {ok, Canonical} ->
            case encoded_bytes(Canonical) of
                {error, invalid_record} -> {error, invalid_record};
                Size -> insert(Tab, OwnerPid, Canonical, Size)
            end
    end;
try_in(_, _, _, _) -> {error, invalid_record}.

encoded_bytes(Canonical) ->
    try iolist_size(json:encode(Canonical))
    catch
        _:_ -> {error, invalid_record}
    end.

insert(Tab, OwnerPid, Canonical, Size) ->
    %% Owner death can remove the table after the identity check. Observation
    %% failure must not escape into the core mail producer.
    try producer_cas(Tab, OwnerPid, fun(State) -> put_rec(State, Canonical, Size) end) of
        {ok, lost} -> dropped;
        {ok, Wake} -> {ok, Wake};
        {error, Reason} -> {error, Reason}
    catch
        error:badarg -> {error, unavailable}
    end.

take(Tab, OwnerPid) when is_pid(OwnerPid) ->
    case {ets:info(Tab, owner), self()} of
        {OwnerPid, OwnerPid} ->
            try
                case owner_cas(Tab, OwnerPid, fun take_pending/1) of
                    {ok, Recs} when is_list(Recs) -> {ok, Recs, dropped(Tab)};
                    {error, Reason} -> {error, Reason};
                    {ok, _} -> {error, unavailable}
                end
            catch
                error:badarg -> {error, unavailable}
            end;
        _ -> {error, unavailable}
    end;
take(_, _) -> {error, unavailable}.

dropped(Tab) ->
    try
        case ets:lookup(Tab, lost) of
            [{lost, N}] when is_integer(N), N >= 0 -> N;
            _ -> 0
        end
    catch
        error:badarg -> 0
    end.

occupied(Tab) ->
    case lookup(Tab) of
        #{pending := Pending} -> length(Pending);
        _ -> 0
    end.

drain(Tab) ->
    case lookup(Tab) of
        #{drain := Flag} -> Flag;
        _ -> false
    end.

encoded_size(Rec, Opts) ->
    case bus_operator_events:candidate(Rec, Opts) of
        {ok, Canonical} -> iolist_size(json:encode(Canonical));
        {error, invalid_event} -> error(invalid_record)
    end.

-ifdef(TEST).
force_loss(true) -> persistent_term:put({?MODULE, force_loss}, true);
force_loss(false) -> persistent_term:erase({?MODULE, force_loss}).
force_owner_contention(true) ->
    persistent_term:put({?MODULE, force_owner_contention}, true);
force_owner_contention(false) ->
    persistent_term:erase({?MODULE, force_owner_contention}).
producer_forced() -> persistent_term:get({?MODULE, force_loss}, false).
owner_forced() -> persistent_term:get({?MODULE, force_owner_contention}, false).
-else.
producer_forced() -> false.
owner_forced() -> false.
-endif.

lookup(Tab) ->
    try
        case ets:lookup(Tab, state) of
            [{state, _, State}] -> State;
            _ -> undefined
        end
    catch
        error:badarg -> undefined
    end.

put_rec(#{pending := Pending, pending_bytes := Bytes, drain := Drain} = State,
        Canonical, Size) ->
    Overflow = Size > ?RECORD orelse Bytes + Size > ?BYTES
        orelse length(Pending) >= ?LIMIT,
    case Overflow of
        true ->
            {ok, State#{drain := true}, lost};
        false ->
            Wake = case Drain of false -> wake; true -> armed end,
            {ok, State#{
                pending := Pending ++ [{Size, Canonical}],
                pending_bytes := Bytes + Size,
                drain := true
            }, Wake}
    end.

take_pending(#{pending := Pending} = State) ->
    Recs = [Rec || {_, Rec} <- Pending],
    {ok, State#{pending := [], pending_bytes := 0, drain := false}, Recs}.

producer_cas(Tab, OwnerPid, Fun) ->
    case producer_forced() of
        true -> account_loss(Tab, OwnerPid);
        false -> cas(Tab, OwnerPid, Fun, 0, producer)
    end.

owner_cas(Tab, OwnerPid, Fun) ->
    case owner_forced() of
        true -> {error, unavailable};
        false -> cas(Tab, OwnerPid, Fun, 0, owner)
    end.

cas(Tab, OwnerPid, _Fun, N, Kind) when N > ?LIMIT ->
    case Kind of
        producer -> account_loss(Tab, OwnerPid);
        owner -> {error, unavailable}
    end;
cas(Tab, OwnerPid, Fun, N, Kind) ->
    case ets:info(Tab, owner) of
        OwnerPid when is_pid(OwnerPid) ->
            case ets:lookup(Tab, state) of
                [{state, V, Map}] ->
                    case Fun(Map) of
                        {error, Reason} -> {error, Reason};
                        {ok, New, Result} ->
                            case ets:select_replace(Tab, [{{state, V, Map}, [],
                                    [{const, {state, V + 1, New}}]}]) of
                                1 -> finish_cas(Tab, OwnerPid, Kind, Result);
                                0 -> cas(Tab, OwnerPid, Fun, N + 1, Kind)
                            end
                    end;
                _ -> {error, unavailable}
            end;
        _ -> {error, unavailable}
    end.

finish_cas(Tab, OwnerPid, producer, lost) ->
    account_loss(Tab, OwnerPid);
finish_cas(_Tab, _OwnerPid, _Kind, Result) ->
    {ok, Result}.

account_loss(Tab, OwnerPid) ->
    case ets:info(Tab, owner) of
        OwnerPid when is_pid(OwnerPid) ->
            try
                _ = ets:update_counter(Tab, lost, {2, 1}),
                arm_drain(Tab, OwnerPid),
                {ok, lost}
            catch
                error:badarg -> {error, unavailable}
            end;
        _ -> {error, unavailable}
    end.

arm_drain(Tab, OwnerPid) ->
    case ets:info(Tab, owner) of
        OwnerPid ->
            case ets:lookup(Tab, state) of
                [{state, V, #{drain := false} = Map}] ->
                    New = Map#{drain := true},
                    _ = ets:select_replace(Tab, [{{state, V, Map}, [],
                            [{const, {state, V + 1, New}}]}]),
                    ok;
                _ -> ok
            end;
        _ -> ok
    end.
