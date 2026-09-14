%% Cowboy-side transport adapter only. Ranch still accepts/owns real TCP
%% sockets. Guard every send, including parser errors and terminating chunks.
-module(bus_socket).
-export([name/0, secure/0, messages/0, peername/1, sockname/1,
    setopts/2, getopts/2, getstat/1, getstat/2, send/2, sendfile/4,
    shutdown/2, close/1]).
name() -> tcp.
secure() -> false.
messages() -> invoke(messages, []).
peername(S) -> invoke(peername, [S]).
sockname(S) -> invoke(sockname, [S]).
setopts(S,O) -> invoke(setopts, [S,O]).
getopts(S,O) -> invoke(getopts, [S,O]).
getstat(S) -> invoke(getstat, [S]).
getstat(S,O) -> invoke(getstat, [S,O]).
shutdown(S,H) -> invoke(shutdown, [S,H]).
close(S) -> invoke(close, [S]).
send(S,Data) -> guarded(send, [S,Data]).
sendfile(S,Path,Offset,Bytes) -> guarded(sendfile, [S,Path,Offset,Bytes]).
invoke(Function, Args) ->
    {Transport, _} = get(bus_transport),
    apply(Transport, Function, Args).
guarded(Function, Args) ->
    {_, W} = get(bus_transport),
    Ref = bus_watchdog:send_start(W),
    Result = invoke(Function, Args),
    %% Borrow an already armed handler operation without completing it. Its
    %% downstream stream barrier is responsible for the entire frame.
    case Ref of borrowed -> ok; _ -> bus_watchdog:complete(W, Ref) end,
    Result.
