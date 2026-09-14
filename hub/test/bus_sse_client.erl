%% Test-only incremental SSE reader. OTP parses HTTP headers and Cowlib
%% decodes chunk framing. Neither TCP reads nor chunk boundaries delimit SSE.
-module(bus_sse_client).
-export([new/0, open/2, feed/2, until/4, comments/1, has_event/2, has_message/2, json_events/2]).

new() -> #{transfer => {0,0}, pending => <<>>, frame => <<>>, frames => []}.
open(Socket,Deadline) ->
    ok = inet:setopts(Socket,[{packet,http_bin}]),
    {ok,{http_response,_,200,_}} = gen_tcp:recv(Socket,0,left(Deadline)),
    headers(Socket,Deadline),
    ok = inet:setopts(Socket,[{packet,raw}]),
    new().
headers(Socket,Deadline) ->
    case gen_tcp:recv(Socket,0,left(Deadline)) of
        {ok,http_eoh} -> ok;
        {ok,{http_header,_,_,_,_}} -> headers(Socket,Deadline);
        Other -> error({invalid_sse_headers,Other})
    end.
feed(Data,#{transfer := Transfer,pending := Pending} = State) ->
    Input = <<Pending/binary,Data/binary>>,
    case cow_http_te:stream_chunked(Input,Transfer) of
        more -> State#{pending := Input};
        {more,Body,Next} -> frames(Body,State#{pending := <<>>,transfer := Next});
        {more,Body,Rest,Next} when is_binary(Rest) ->
            frames(Body,State#{pending := Rest,transfer := Next});
        {more,Body,Remaining,Next} when is_integer(Remaining) ->
            frames(Body,State#{pending := <<>>,transfer := Next});
        End -> error({sse_ended,End})
    end.
frames(Body,#{frame := Pending,frames := Old} = State) ->
    %% Cowboy emits LF-delimited SSE; retain incomplete delimiters/frames.
    Parts = binary:split(<<Pending/binary,Body/binary>>,<<"\n\n">>,[global]),
    [Tail|Complete] = lists:reverse(Parts),
    State#{frame := Tail,frames := Old ++ lists:reverse(Complete)}.
until(Socket,State,Predicate,Deadline) ->
    case Predicate(State) of
        true -> State;
        false ->
            {ok,Data} = gen_tcp:recv(Socket,0,left(Deadline)),
            until(Socket,feed(Data,State),Predicate,Deadline)
    end.
comments(#{frames := Frames}) -> length([ok || <<": keepalive">> <- Frames]).
has_event(#{frames := Frames},Type) ->
    lists:any(fun(F) ->
        case event(F) of #{event_type := Type} -> true; _ -> false end
    end,Frames).
has_message(#{frames := Frames},Id) ->
    lists:any(fun(F) ->
        case event(F) of
            #{event_type := <<"message">>,data := Data} ->
                case bus_protocol:decode_json(iolist_to_binary(Data)) of
                    {ok,#{<<"id">> := Id}} -> true;
                    _ -> false
                end;
            _ -> false
        end
    end,Frames).
json_events(#{frames := Frames}, Type) ->
    [begin
        {ok, Value} = bus_protocol:decode_json(iolist_to_binary(Data)),
        Value
    end || Frame <- Frames,
           #{event_type := EventType, data := Data} <- [event(Frame)],
           EventType =:= Type].
event(Frame) ->
    case cow_sse:parse(<<Frame/binary,"\n\n">>,cow_sse:init()) of
        {event,Event,_} -> Event;
        {more,_} -> undefined
    end.
left(Deadline) ->
    case Deadline-erlang:monotonic_time(millisecond) of
        N when N > 0 -> N;
        _ -> error(sse_deadline)
    end.
