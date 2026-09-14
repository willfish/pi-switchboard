-module(bus_connection).
-behaviour(ranch_protocol).
-export([start_link/3, connection_process/4]).

%% Timestamp before Cowboy's handshake and header parsing. Keep Cowboy's
%% connection initialization, supervision and parser rather than duplicating it.
start_link(Ref, Transport, Opts) ->
    Deadline = erlang:monotonic_time(millisecond) + 5000,
    {ok, Sup} = bus_connection_sup:start_link(Ref, Transport, Opts#{bus_deadline => Deadline}),
    {Conn, _} = bus_connection_sup:children(Sup),
    {ok, Sup, Conn}.
connection_process(Parent, Ref, Transport, Opts) ->
    receive
        {bus_bootstrap, Parent, Watchdog} ->
            put(bus_transport, {Transport, Watchdog}),
            cowboy_clear:connection_process(Parent, Ref, bus_socket,
                Opts#{bus_watchdog => Watchdog})
    end.
