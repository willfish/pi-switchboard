%% Observe genuine loopback sends without delaying, replacing or acknowledging
%% them. The production bus_socket adapter remains outside this transport.
-module(bus_slow_transport).
-export([start_link/3, name/0, secure/0, messages/0, peername/1, sockname/1,
    setopts/2, send/2, shutdown/2, close/1]).
start_link(Ref, _Transport, Opts) -> bus_connection:start_link(Ref, ?MODULE, Opts).
name() -> tcp.
secure() -> false.
messages() -> ranch_tcp:messages().
peername(S) -> ranch_tcp:peername(S).
sockname(S) -> ranch_tcp:sockname(S).
setopts(S,O) -> ranch_tcp:setopts(S,O).
shutdown(S,H) -> ranch_tcp:shutdown(S,H).
close(S) -> ranch_tcp:close(S).
send(S,Data) ->
    Ref = make_ref(),
    bus_slow_observer ! {send_started,self(),Ref,
        erlang:monotonic_time(millisecond),iolist_size(Data)},
    Result = ranch_tcp:send(S,Data),
    bus_slow_observer ! {send_returned,self(),Ref,Result},
    Result.
