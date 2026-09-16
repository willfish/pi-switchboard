-module(bus_operator_updates).
-behaviour(gen_server).
%% Payload-free invalidations. One pending wake per subscriber; producers never
%% call an owner or queue work when nobody is subscribed.
-export([start_link/0, subscribe/1, unsubscribe/1, ack/1, publish/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).
-define(TAB, bus_operator_update_watches).
-define(INDEX, bus_operator_update_keys).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
subscribe(Key) ->
    case whereis(?MODULE) of
        undefined -> {error, unavailable};
        Pid ->
            try gen_server:call(Pid, {subscribe, self(), Key}, 5000)
            catch exit:_ -> {error, unavailable} end
    end.
unsubscribe({Pid, Ref, _Tab}) -> gen_server:cast(Pid, {unsubscribe, self(), Ref});
unsubscribe(_) -> ok.
ack({_Pid, Ref, Tab}) ->
    try ets:update_element(Tab, Ref, {4, false}) catch error:badarg -> false end.
publish(Key) ->
    try
        Tab = ets:whereis(?TAB),
        Index = ets:whereis(?INDEX),
        Rows = [Row || {_, Ref0} <- ets:lookup(Index, Key),
            Row = {_, _, _, false} <- ets:lookup(Tab, Ref0)],
        lists:foreach(fun({Ref, _, Pid, false} = Row) ->
            case ets:select_replace(Tab, [{Row, [], [{{Ref, Key, Pid, true}}]}]) of
                1 -> Pid ! {operator_update, Ref};
                0 -> ok
            end
        end, Rows), ok
    catch error:badarg -> ok end.
init([]) ->
    Tab = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}, {write_concurrency, true}]),
    Index = ets:new(?INDEX, [named_table, public, bag, {read_concurrency, true}]),
    {ok, #{tab => Tab, index => Index, watches => #{}, keys => #{}, browser => 0, native => 0}}.
handle_call({subscribe, Pid, Key}, _From, #{tab := Tab, watches := Watches, keys := Keys} = State) ->
    Kind = case Key of browser -> browser; _ -> native end,
    Valid = Key =:= browser orelse (is_binary(Key) andalso bus_protocol:is_uuid(Key)),
    Limit = case Kind of browser -> 32; native -> 5000 end,
    case Valid andalso is_process_alive(Pid) andalso maps:get(Kind, State) < Limit
         andalso (Key =:= browser orelse not maps:is_key(Key, Keys)) of
        false -> {reply, {error, capacity}, State};
        true ->
            Ref = monitor(process, Pid),
            ets:insert(Tab, {Ref, Key, Pid, true}),
            ets:insert(maps:get(index, State), {Key, Ref}), Pid ! {operator_update, Ref},
            {reply, {ok, {self(), Ref, Tab}}, State#{watches := Watches#{Ref => {Pid, Key, Kind}},
                keys := Keys#{Key => Ref}, Kind := maps:get(Kind, State) + 1}}
    end;
handle_call(_, _, State) -> {reply, {error, invalid_request}, State}.
handle_cast({unsubscribe, Pid, Ref}, #{watches := Watches} = State) ->
    case maps:get(Ref, Watches, undefined) of
        {Pid, _, _} -> {noreply, remove(Ref, State)};
        _ -> {noreply, State}
    end;
handle_cast(_, State) -> {noreply, State}.
handle_info({'DOWN', Ref, process, _, _}, State) -> {noreply, remove(Ref, State)};
handle_info(_, State) -> {noreply, State}.
remove(Ref, #{tab := Tab, watches := Watches, keys := Keys} = State) ->
    case maps:take(Ref, Watches) of
        error -> State;
        {{_, Key, Kind}, Rest} ->
            demonitor(Ref, [flush]), ets:delete(Tab, Ref),
            ets:delete_object(maps:get(index, State), {Key, Ref}),
            State#{watches := Rest, keys := maps:remove(Key, Keys), Kind := maps:get(Kind, State) - 1}
    end.
terminate(_, _) -> ok.
format_status(Status) -> maps:map(fun(log, _) -> []; (_, _) -> redacted end, Status).
