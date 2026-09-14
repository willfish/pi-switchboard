-module(bus_deadline_stream).
-behaviour(cowboy_stream).
-export([init/3, data/4, info/3, terminate/3, early_error/5,
    handshake/1, events/2]).

init(ID, Req, #{bus_deadline := Deadline, bus_watchdog := Watchdog} = Opts) ->
    {Commands, Next} = cowboy_stream:init(ID,
        Req#{bus_deadline => Deadline, bus_watchdog => Watchdog}, Opts),
    {Commands, #{next => Next, watchdog => Watchdog}}.
data(ID, Fin, Data, #{next := Next} = State) ->
    {Commands, Next1} = cowboy_stream:data(ID, Fin, Data, Next),
    {Commands, State#{next := Next1}}.
info(_ID, {bus_barrier, From, Ref, Kind}, #{watchdog := W} = State) ->
    %% Cowboy processes stream messages serially, executing all preceding
    %% commands (including Transport:send) before entering this callback.
    %% data_ack is sent earlier by cowboy_stream_h and is NOT this barrier.
    ok = case Kind of
        handshake -> bus_watchdog:handshake(W);
        write -> bus_watchdog:complete(W, Ref)
    end,
    From ! {bus_completed, Ref},
    {[], State};
info(ID, Msg, #{next := Next} = State) ->
    {Commands, Next1} = cowboy_stream:info(ID, Msg, Next),
    {Commands, State#{next := Next1}}.
terminate(ID, Reason, #{next := Next}) -> cowboy_stream:terminate(ID, Reason, Next).
early_error(ID, Reason, Req, Resp, Opts) ->
    cowboy_stream:early_error(ID, Reason, Req, Resp, Opts).

handshake(Req) -> barrier(Req, make_ref(), handshake).
events(Event, #{bus_watchdog := W} = Req) ->
    Ref = bus_watchdog:arm(W, erlang:monotonic_time(millisecond) + 5000),
    cowboy_req:stream_events(Event, nofin, Req),
    barrier(Req, Ref, write).
barrier(#{pid := Conn} = Req, Ref, Kind) ->
    Monitor = monitor(process, Conn),
    cowboy_req:cast({bus_barrier, self(), Ref, Kind}, Req),
    receive
        {bus_completed, Ref} -> demonitor(Monitor, [flush]), ok;
        {'DOWN', Monitor, process, Conn, _} -> exit(connection_closed)
    end.
