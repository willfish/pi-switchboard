-module(bus_deadline_tests).
-include_lib("eunit/include/eunit.hrl").

%% Exercise Cowboy's real request API with a controlled connection mailbox.
%% These are handler tests, not socket-completion or connection-start tests.
http_deadline_test_() ->
    {setup, fun() ->
        {ok, _} = application:ensure_all_started(cowboy),
        Old = application:get_env(pi_agent_bus, token),
        application:set_env(pi_agent_bus, token, <<"deadline-test">>),
        Old
    end, fun(Old) ->
        case Old of
            undefined -> application:unset_env(pi_agent_bus, token);
            {ok, Value} -> application:set_env(pi_agent_bus, token, Value)
        end
    end, [
        ?_test(expired_routes()),
        ?_test(partial_timeout()),
        ?_test(total_size()),
        ?_test(complete_oversize()),
        ?_test(exact_size()),
        ?_test(fallback_deadline()),
        ?_test(store_deadline_forwarding())
    ]}.

request(Method, Deadline) ->
    #{method => Method, bus_deadline => Deadline, pid => self(), streamid => 1,
      has_body => true, qs => <<>>, bindings => #{agent_id => <<"a">>},
      headers => #{<<"authorization">> => <<"Bearer deadline-test">>,
                   <<"content-length">> => <<"32768">>}}.

start(Req, Route) ->
    Parent = self(),
    spawn_monitor(fun() ->
        Result = bus_http_h:init(Req, Route),
        Parent ! {handler_result, self(), Result}
    end).

finish({Pid, Mon}, Status) ->
    receive
        {{_, 1}, {response, Actual, _, Body}} ->
            ?assertEqual(Status, Actual),
            case Status of
                503 -> ?assertNotEqual(nomatch, binary:match(iolist_to_binary(Body), <<"timeout">>));
                _ -> ok
            end
    after 1000 -> error(no_response)
    end,
    Req = receive {handler_result, Pid, {ok, R, []}} -> R
        after 1000 -> error(no_handler_result) end,
    receive {'DOWN', Mon, process, Pid, normal} -> ok
        after 1000 -> error(handler_failed) end,
    Req.

expired_routes() ->
    D = erlang:monotonic_time(millisecond),
    lists:foreach(fun({Method, Route}) ->
        Req = finish(start(request(Method, D), Route), 503),
        ?assertEqual(D, maps:get(bus_deadline, Req)),
        receive {{_, 1}, {read_body, _, _, _, _}} -> ?assert(false)
            after 0 -> ok end
    end, [{<<"PUT">>, agent}, {<<"DELETE">>, agent},
          {<<"POST">>, messages}, {<<"GET">>, list}]).

read_request() ->
    receive {{_, 1}, {read_body, Pid, Ref, Length, Period}} ->
        {Pid, Ref, Length, Period}
    after 1000 -> error(no_body_read) end.

partial_timeout() ->
    D = erlang:monotonic_time(millisecond) + 100,
    H = start(request(<<"POST">>, D), messages),
    {Pid, Ref, _, Period} = read_request(),
    ?assert(Period > 0 andalso Period =< 100),
    Pid ! {request_body, Ref, nofin, <<"{">>},
    {Pid, _, _, NextPeriod} = read_request(),
    ?assert(NextPeriod =< Period),
    %% No final chunk: read_body's timeout must use the same remaining budget,
    %% not Cowboy's default extra second or a fresh five seconds.
    Req = finish(H, 503),
    ?assertEqual(D, maps:get(bus_deadline, Req)).

total_size() ->
    H = start(request(<<"POST">>, erlang:monotonic_time(millisecond) + 5000), messages),
    {Pid, Ref, _, _} = read_request(),
    Pid ! {request_body, Ref, nofin, binary:copy(<<" ">>, 16000)},
    {Pid, Ref2, Length, _} = read_request(),
    ?assertEqual(32768 - 16000 + 1, Length),
    Pid ! {request_body, Ref2, fin, 32769, binary:copy(<<" ">>, 16769)},
    finish(H, 413).

complete_oversize() ->
    H = start(request(<<"POST">>, erlang:monotonic_time(millisecond) + 5000), messages),
    {Pid, Ref, _, _} = read_request(),
    Pid ! {request_body, Ref, fin, 32769, binary:copy(<<" ">>, 32769)},
    finish(H, 413).

exact_size() ->
    H = start(request(<<"POST">>, erlang:monotonic_time(millisecond) + 5000), messages),
    {Pid, Ref, _, _} = read_request(),
    Pid ! {request_body, Ref, fin, 32768, binary:copy(<<" ">>, 32768)},
    %% Size is accepted, then invalid JSON is rejected.
    finish(H, 400).

store_deadline_forwarding() ->
    A = <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>,
    B = <<"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb">>,
    Agent = #{<<"agentId">> => A, <<"sessionId">> => A, <<"host">> => <<"test">>,
        <<"cwd">> => <<"/tmp">>, <<"sessionName">> => <<"test">>,
        <<"label">> => <<"test">>, <<"model">> => null, <<"status">> => <<"idle">>,
        <<"pid">> => 1, <<"acceptsControl">> => false},
    Mail = #{<<"id">> => A, <<"from">> => A, <<"to">> => B,
        <<"kind">> => <<"notice">>, <<"body">> => <<"test">>},
    %% Register a mailbox endpoint to inspect the actual gen_server envelope.
    true = register(bus_store, self()),
    try
        lists:foreach(fun({Method, Route, Document, ExpectedOp}) ->
            D = erlang:monotonic_time(millisecond) + 2000,
            Req = (request(Method, D))#{bindings => #{agent_id => A}},
            H = start(Req, Route),
            case Document of
                undefined -> ok;
                _ ->
                    {Pid, Ref, _, _} = read_request(),
                    Body = bus_protocol:encode_map(Document),
                    Pid ! {request_body, Ref, fin, byte_size(Body), Body}
            end,
            receive
                {'$gen_call', From, {op, Forwarded, Op}} ->
                    ?assertEqual(D, Forwarded),
                    ?assertEqual(ExpectedOp, Op),
                    gen_server:reply(From, {error, timeout})
            after 1000 -> error(no_store_call)
            end,
            finish(H, 503)
        end, [{<<"GET">>, list, undefined, {list_agents_page, first}},
              {<<"DELETE">>, agent, undefined, {delete_agent, A}},
              {<<"PUT">>, agent, Agent, {put_agent, Agent}},
              {<<"POST">>, messages, Mail, {accept_mail, Mail}}])
    after
        unregister(bus_store)
    end.

fallback_deadline() ->
    Before = erlang:monotonic_time(millisecond),
    H = start(maps:remove(bus_deadline, request(<<"POST">>, 0)), messages),
    {Pid, Ref, _, Period} = read_request(),
    ?assert(Period > 0 andalso Period =< 5000),
    Pid ! {request_body, Ref, fin, 2, <<"{}">>},
    Req = finish(H, 400),
    D = maps:get(bus_deadline, Req),
    ?assert(D >= Before + 5000),
    ?assert(D =< erlang:monotonic_time(millisecond) + 5000).
