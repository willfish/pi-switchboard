-module(bus_events_h).

-export([init/2, info/3, terminate/3]).

init(Req0, _State) ->
    case bus_http_h:authorize(Req0) of
        false ->
            Req = cowboy_req:reply(
                401,
                #{<<"content-type">> => <<"application/json">>},
                bus_protocol:encode_error(<<"unauthorized">>, <<"invalid token">>),
                Req0
            ),
            {ok, Req, undefined};
        true ->
            authorized(Req0)
    end.

authorized(#{method := Method} = Req) when Method =/= <<"GET">> ->
    {ok, cowboy_req:reply(405, #{<<"allow">> => <<"GET">>}, <<>>, Req), undefined};
authorized(#{has_body := true} = Req) ->
    {ok, cowboy_req:reply(400, #{<<"content-type">> => <<"application/json">>},
        bus_protocol:encode_error(<<"invalid_schema">>, <<"events requests must not have a body">>),
        Req), undefined};
authorized(Req0) ->
    case event_agent_id(Req0) of
        error ->
            Req = cowboy_req:reply(
                400,
                #{<<"content-type">> => <<"application/json">>},
                bus_protocol:encode_error(<<"invalid_schema">>, <<"agentId required">>),
                Req0
            ),
            {ok, Req, undefined};
        {ok, AgentId} ->
            start_stream(Req0, AgentId)
    end.

event_agent_id(Req) ->
    try cowboy_req:parse_qs(Req) of
        [{<<"agentId">>, AgentId}] ->
            case bus_protocol:is_uuid(AgentId) of
                true -> {ok, AgentId};
                false -> error
            end;
        _ -> error
    catch _:_ -> error end.

start_stream(Req0, AgentId) ->
    Deadline = maps:get(bus_deadline, Req0, erlang:monotonic_time(millisecond) + 5000),
    case bus_store:subscribe(AgentId, self(), Deadline) of
        {error, not_found} ->
            Req = cowboy_req:reply(
                404,
                #{<<"content-type">> => <<"application/json">>},
                bus_protocol:encode_error(<<"not_found">>, <<"unknown runtime">>),
                Req0
            ),
            {ok, Req, undefined};
        {error, _Reason} ->
            Req = cowboy_req:reply(
                503,
                #{<<"content-type">> => <<"application/json">>},
                bus_protocol:encode_error(<<"capacity">>, <<"receive unavailable">>),
                Req0
            ),
            {ok, Req, undefined};
        {ok, Ref} ->
            Req1 = cowboy_req:stream_reply(
                200,
                #{
                    <<"content-type">> => <<"text/event-stream">>,
                    <<"cache-control">> => <<"no-cache">>
                },
                Req0
            ),
            ok = bus_deadline_stream:handshake(Req1),
            erlang:send_after(10000, self(), keepalive),
            State = #{agent_id => AgentId, ref => Ref},
            %% subscribe/3 already queued both initial wakes.
            {cowboy_loop, Req1, State, hibernate}
    end.

info(keepalive, Req, State) ->
    bus_deadline_stream:events(#{comment => <<"keepalive">>}, Req),
    erlang:send_after(10000, self(), keepalive),
    {ok, Req, State, hibernate};
info({bus, Ref, replaced}, Req, #{ref := Ref} = State) ->
    {stop, Req, State};
info({bus, Ref, presence}, Req, #{ref := Ref, agent_id := AgentId} = State) ->
    case bus_store:pull_presence(AgentId, Ref) of
        {frame, Event, Data, More} ->
            %% One actual-send barrier per bounded frame. Continue only after
            %% completion, allowing queued mail and keepalives between chunks.
            bus_deadline_stream:events(#{event => Event, data => Data}, Req),
            case More of
                true -> self() ! {bus, Ref, presence};
                false -> ok
            end,
            {ok, Req, State, hibernate};
        empty ->
            {ok, Req, State, hibernate};
        {error, _} ->
            %% The consumed wake may not be rearmed after an uncertain pull.
            %% Close so the client can register and subscribe afresh.
            {stop, Req, State}
    end;
info({bus, Ref, mail}, Req, #{ref := Ref, agent_id := AgentId} = State) ->
    case bus_store:pop_mail(AgentId, Ref) of
        {empty, _} ->
            {ok, Req, State, hibernate};
        {ok, Msg} ->
            Data = bus_protocol:encode_map(Msg),
            bus_deadline_stream:events(
                #{event => <<"message">>, data => Data}, Req
            ),
            self() ! {bus, Ref, mail},
            {ok, Req, State};
        {error, _} ->
            {stop, Req, State}
    end;
info({bus, _Old, _}, Req, State) ->
    {ok, Req, State, hibernate};
info(_Info, Req, State) ->
    {ok, Req, State, hibernate}.

terminate(_Reason, _Req, #{agent_id := AgentId, ref := Ref}) ->
    bus_store:unsubscribe(AgentId, Ref),
    ok;
terminate(_Reason, _Req, _) ->
    ok.
