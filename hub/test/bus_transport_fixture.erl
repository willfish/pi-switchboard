%% Local fault-injection transport and handler. Never part of the release.
-module(bus_transport_fixture).
-export([start_link/3, init/2, name/0, secure/0, messages/0,
    peername/1, sockname/1, setopts/2, send/2, shutdown/2, close/1,
    init/3, data/4, info/3, terminate/3, early_error/5]).
%% Observe Cowboy's stream cleanup, independently of request-child death.
init(ID,Req,Opts) -> cowboy_stream:init(ID,Req,Opts).
data(ID,Fin,Data,State) -> cowboy_stream:data(ID,Fin,Data,State).
info(ID,Info,State) -> cowboy_stream:info(ID,Info,State).
terminate(_Reason,Req,_Mode) when is_map(Req) -> ok;
terminate(ID,Reason,State) ->
    case whereis(bus_transport_observer) of
        undefined -> ok;
        P -> P ! {stream_terminated,self(),Reason}
    end,
    cowboy_stream:terminate(ID,Reason,State).
early_error(ID,Reason,Req,Resp,Opts) -> cowboy_stream:early_error(ID,Reason,Req,Resp,Opts).
start_link(Ref, _Transport, Opts) -> bus_connection:start_link(Ref, ?MODULE, Opts).
init(Req, Mode) when Mode =:= trap; Mode =:= cooperative ->
    process_flag(trap_exit,true),
    Req1 = cowboy_req:stream_reply(200, #{<<"content-type">> => <<"text/event-stream">>}, Req),
    ok = bus_deadline_stream:handshake(Req1),
    Conn = maps:get(pid,Req),
    bus_transport_observer ! {ready,self(),Conn},
    receive {'EXIT',Conn,shutdown} ->
        bus_transport_observer ! {child_shutdown,self()},
        case Mode of cooperative -> {ok,Req1,Mode}; trap -> receive never -> ok end end
    end;
init(Req, Mode) ->
    Req1 = cowboy_req:stream_reply(200, #{<<"content-type">> => <<"text/event-stream">>}, Req),
    ok = bus_deadline_stream:handshake(Req1),
    bus_transport_observer ! {ready,self(),maps:get(pid,Req)},
    receive go -> ok end,
    Event = case Mode of
        before_ack -> #{comment => <<"before ack">>};
        after_ack -> #{comment => <<"stall-after-ack">>}
    end,
    ok = bus_deadline_stream:events(Event,Req1),
    bus_transport_observer ! incorrectly_completed,
    {ok,Req1,Mode}.
name() -> tcp.
secure() -> false.
messages() -> ranch_tcp:messages().
peername(S) -> ranch_tcp:peername(S).
sockname(S) -> ranch_tcp:sockname(S).
setopts(S,O) -> ranch_tcp:setopts(S,O).
shutdown(S,H) -> ranch_tcp:shutdown(S,H).
close(S) -> ranch_tcp:close(S).
send(S,Data) ->
    case binary:match(iolist_to_binary(Data), <<"stall-after-ack">>) of
        nomatch -> ranch_tcp:send(S,Data);
        _ ->
            bus_transport_observer ! send_blocked,
            receive release -> ranch_tcp:send(S,Data) end
    end.
