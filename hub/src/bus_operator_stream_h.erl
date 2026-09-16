-module(bus_operator_stream_h).

%% Dedicated operator observation SSE. Journal pull only. Never pops mail.
-export([init/2, info/3, terminate/3]).

-define(REQUEST_TIMEOUT_MS, 5000).
-define(KEEPALIVE_MS, 10000).
-define(REVALIDATE_MS, 5000).
-define(FRAME_BYTES, 524288).

init(Req0, _State) ->
    Deadline = maps:get(bus_deadline, Req0,
        erlang:monotonic_time(millisecond) + ?REQUEST_TIMEOUT_MS),
    Req = Req0#{bus_deadline => Deadline},
    case cowboy_req:method(Req) of
        <<"GET">> -> start(Req);
        _ ->
            {ok, cowboy_req:reply(405, headers(#{<<"allow">> => <<"GET">>}),
                bus_protocol:encode_error(<<"method_not_allowed">>, <<"GET required">>), Req),
                undefined}
    end.

start(Req) ->
    case remaining(Req) =< 0 of
        true -> reply(Req, 503, <<"capacity">>, <<"request timeout">>);
        false ->
            case mode() of
                disabled -> reply(Req, 403, <<"disabled">>, <<"operator api disabled">>);
                Mode -> admit(Req, Mode)
            end
    end.

mode() ->
    case application:get_env(pi_agent_bus, operator_access, disabled) of
        disabled -> disabled;
        loopback -> loopback;
        {tailnet, Name} -> {tailnet, Name};
        _ -> disabled
    end.

admit(Req, Mode) ->
    case bus_dashboard_authority:allowed_host(Req)
            andalso bus_dashboard_authority:allowed_read(Req) of
        false -> reply(Req, 403, <<"forbidden">>, <<"request rejected">>);
        true ->
            {Peer, _} = cowboy_req:peer(Req),
            {Local, _} = cowboy_req:sock(Req),
            case bus_operator_access:admit(Mode, Peer, Local) of
                {error, disabled} -> reply(Req, 403, <<"disabled">>, <<"operator api disabled">>);
                {error, forbidden} -> reply(Req, 403, <<"forbidden">>, <<"request rejected">>);
                {error, unavailable} -> reply(Req, 503, <<"capacity">>, <<"operator unavailable">>);
                ok -> authorize_stream(Req)
            end
    end.

authorize_stream(Req) ->
    case cowboy_req:qs(Req) of
        Bin when Bin =/= <<>> ->
            reply(Req, 400, <<"invalid_schema">>, <<"empty query required">>);
        <<>> ->
            case maps:get(has_body, Req, false) of
                true -> reply(Req, 400, <<"invalid_schema">>, <<"empty body required">>);
                false -> nonce_stream(Req)
            end
    end.

nonce_stream(Req) ->
    case bus_operator_http:session_header(Req) of
        undefined -> reply(Req, 401, <<"unauthorized">>, <<"invalid session">>);
        {error, unauthorized} -> reply(Req, 401, <<"unauthorized">>, <<"invalid session">>);
        {ok, Nonce} ->
            Conn = maps:get(pid, Req),
            Deadline = maps:get(bus_deadline, Req),
            Bound = bus_operator_http:canonical_origin(Req),
            case bus_operator_http_gate:acquire(Conn, {session, crypto:hash(sha256, Nonce)}) of
                {error, _} -> reply(Req, 503, <<"capacity">>, <<"operator unavailable">>);
                {ok, Permit} ->
                    case bus_operator_auth:authorize(Nonce, Bound, Conn, Deadline) of
                        {error, unauthorized} -> reply(Req, 401, <<"unauthorized">>, <<"invalid session">>);
                        {error, _} -> reply(Req, 503, <<"capacity">>, <<"operator unavailable">>);
                        {ok, _} -> subscribe(Req#{operator_http_permit => Permit}, Nonce, Bound)
                    end
            end
    end.

subscribe(Req0, Nonce, Bound) ->
    Digest = crypto:hash(sha256, Nonce),
    Deadline = maps:get(bus_deadline, Req0),
    Journal = whereis(bus_operator_journal),
    case Journal of
        undefined -> reply(Req0, 503, <<"capacity">>, <<"operator unavailable">>);
        _ ->
            case bus_operator_journal:subscribe(self(), Digest, Deadline) of
                {error, capacity} ->
                    reply(Req0, 503, <<"capacity">>, <<"observer capacity">>);
                {error, conflict} ->
                    reply(Req0, 409, <<"conflict">>, <<"observer already connected">>);
                {error, _} ->
                    reply(Req0, 503, <<"capacity">>, <<"operator unavailable">>);
                {ok, JournalPid, Ref} ->
                    Req1 = cowboy_req:stream_reply(200, headers(#{
                        <<"content-type">> => <<"text/event-stream">>
                    }), Req0),
                    ok = bus_deadline_stream:handshake(Req1),
                    erlang:send_after(?KEEPALIVE_MS, self(), keepalive),
                    erlang:send_after(?REVALIDATE_MS, self(), revalidate),
                    Mon = monitor(process, JournalPid),
                    {Peer, _} = cowboy_req:peer(Req0),
                    {Local, _} = cowboy_req:sock(Req0),
                    State = #{ref => Ref, digest => Digest, nonce => Nonce,
                              origin => Bound, journal => JournalPid,
                              journal_mon => Mon, peer => Peer, local => Local,
                              pulling => false, pending => false},
                    {cowboy_loop, Req1, State, hibernate}
            end
    end.

info(keepalive, Req, State) ->
    bus_deadline_stream:events(#{comment => <<"keepalive">>}, Req),
    erlang:send_after(?KEEPALIVE_MS, self(), keepalive),
    {ok, Req, State, hibernate};
info(revalidate, Req, State) ->
    case revalidate(Req, State) of
        ok ->
            erlang:send_after(?REVALIDATE_MS, self(), revalidate),
            {ok, Req, State, hibernate};
        stop -> {stop, Req, State}
    end;
info({journal, Ref, wake}, Req, #{ref := Ref, pulling := true} = State) ->
    {ok, Req, State#{pending := true}, hibernate};
info({journal, Ref, wake}, Req, #{ref := Ref} = State) ->
    pull_frame(Req, State#{pulling := true, pending := false});
info({journal, Ref, replaced}, Req, #{ref := Ref} = State) ->
    {stop, Req, State};
info({'DOWN', Mon, process, _, _}, Req, #{journal_mon := Mon} = State) ->
    {stop, Req, State};
info(_Info, Req, State) ->
    {ok, Req, State, hibernate}.

pull_frame(Req, #{ref := Ref, journal := Journal} = State) ->
    Deadline = erlang:monotonic_time(millisecond) + ?REQUEST_TIMEOUT_MS,
    case bus_operator_journal:pull(Journal, Ref, self(), Deadline) of
        empty ->
            after_pull(Req, State);
        {frame, Bin, More, Size} ->
            case Size > ?FRAME_BYTES of
                true ->
                    reset(Req, <<"capacity">>),
                    {stop, Req, State};
                false ->
                    bus_deadline_stream:events(
                        #{event => <<"observation">>, data => Bin}, Req),
                    bus_operator_journal:release(Journal, Ref, Size),
                    case More of
                        true -> self() ! {journal, Ref, wake};
                        false -> ok
                    end,
                    after_pull(Req, State)
            end;
        {error, epoch_reset} ->
            reset(Req, <<"epoch_reset">>),
            {stop, Req, State};
        {error, history_lost} ->
            reset(Req, <<"history_lost">>),
            {stop, Req, State};
        {error, overloaded} ->
            reset(Req, <<"capacity">>),
            {stop, Req, State};
        {error, _} ->
            {stop, Req, State}
    end.

after_pull(Req, #{ref := Ref, pending := true} = State) ->
    self() ! {journal, Ref, wake},
    {ok, Req, State#{pulling := false, pending := false}, hibernate};
after_pull(Req, State) ->
    {ok, Req, State#{pulling := false, pending := false}, hibernate}.

revalidate(Req, State) ->
    case bus_operator_http_gate:checkout(maps:get(operator_http_permit, Req), maps:get(pid, Req)) of
        ok -> revalidate_access(Req, State);
        stale -> stop
    end.

revalidate_access(Req, #{nonce := Nonce, origin := Bound, peer := Peer, local := Local}) ->
    case mode() of
        disabled -> stop;
        Mode ->
            case bus_dashboard_authority:allowed_host(Req)
                    andalso bus_dashboard_authority:allowed_read(Req) of
                false -> stop;
                true ->
                    case bus_operator_access:admit(Mode, Peer, Local) of
                        ok ->
                            Deadline = erlang:monotonic_time(millisecond) + ?REQUEST_TIMEOUT_MS,
                            case bus_operator_auth:authorize(Nonce, Bound,
                                    maps:get(pid, Req), Deadline) of
                                {ok, _} -> ok;
                                _ -> stop
                            end;
                        _ -> stop
                    end
            end
    end.

reset(Req, Reason) ->
    Data = bus_protocol:encode_map(#{<<"reason">> => Reason}),
    bus_deadline_stream:events(#{event => <<"reset">>, data => Data}, Req).

terminate(_Reason, _Req, #{ref := Ref, journal := Journal}) ->
    bus_operator_journal:unsubscribe(Journal, Ref),
    ok;
terminate(_Reason, _Req, _) ->
    ok.

reply(Req, Status, Code, Message) ->
    {ok, cowboy_req:reply(Status, headers(#{<<"content-type">> => <<"application/json">>}),
        bus_protocol:encode_error(Code, Message), Req), undefined}.

headers(Extra) ->
    maps:merge(#{
        <<"cache-control">> => <<"no-store">>,
        <<"referrer-policy">> => <<"no-referrer">>,
        <<"x-content-type-options">> => <<"nosniff">>,
        <<"x-frame-options">> => <<"DENY">>,
        <<"content-security-policy">> =>
            <<"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'">>
    }, Extra).

remaining(Req) ->
    maps:get(bus_deadline, Req) - erlang:monotonic_time(millisecond).
