-module(bus_transport_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1,
    shared_budget/1, one_request/1, healthy_stream/1, watchdog_fencing/1,
    methods/1, stalled_before_ack/1, stalled_after_ack/1, replacement/1,
    handshake_budget/1, late_completion/1, kernel_backpressure/1,
    ranch_overshoot/1, withheld_sse_body/1, queued_mutation_budget/1,
    watchdog_failure/1, connection_supervision/1, listener_store_cleanup/1,
    blocked_helper_failure/1, supervisor_inspection/1, shutdown_cleanup/1]).

all() -> [shared_budget, one_request, healthy_stream, watchdog_fencing,
    methods, stalled_before_ack, stalled_after_ack, replacement,
    handshake_budget, late_completion, kernel_backpressure, ranch_overshoot,
    withheld_sse_body, queued_mutation_budget, watchdog_failure,
    connection_supervision, blocked_helper_failure, supervisor_inspection,
    listener_store_cleanup, shutdown_cleanup].
init_per_suite(C) -> bus_http_SUITE:init_per_suite(C).
end_per_suite(C) -> bus_http_SUITE:end_per_suite(C).

connect(C) ->
    gen_tcp:connect({127,0,0,1}, proplists:get_value(port,C),
        [binary, {active,false}], 1000).
shared_budget(C) ->
    {ok,S} = connect(C),
    Start = erlang:monotonic_time(millisecond),
    ok = gen_tcp:send(S, <<"PUT /v1/agents/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa HTTP/1.1\r\nHost: localhost\r\n">>),
    timer:sleep(3500),
    ok = gen_tcp:send(S, <<"Authorization: Bearer ct-token\r\nContent-Length: 100\r\n\r\n{">>),
    drain(S),
    Elapsed = erlang:monotonic_time(millisecond)-Start,
    true = Elapsed >= 4500 andalso Elapsed < 6000,
    {200,_} = bus_http_SUITE:get(C,"/health",[]).
one_request(C) ->
    {ok,S} = connect(C),
    ok = gen_tcp:send(S, binary:copy(<<"GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n">>,2)),
    Data = drain(S),
    1 = length(binary:matches(Data, <<"200 OK">>)).
healthy_stream(C) ->
    A = <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>,
    Store = whereis(bus_store), Listener = maps:get(pid,ranch:info(bus_http)),
    {204,_} = bus_http_SUITE:put_agent(C,A,false),
    {ok,S} = connect(C),
    try
        ok = gen_tcp:send(S,[<<"GET /v1/events?agentId=">>, A,
            <<" HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ct-token\r\n\r\n">>]),
        await(fun() -> receiving(A) andalso length(ranch:procs(bus_http,connections)) =:= 1 end,1000),
        [Conn] = protocol_connections(bus_http),
        W = watchdog(Conn),
        await(fun() -> handshake_complete(W) end,1000),
        Deadline = erlang:monotonic_time(millisecond)+35000,
        Reader = bus_sse_client:open(S,Deadline),
        lists:foreach(fun(_) ->
            timer:sleep(4000),
            {204,_} = bus_http_SUITE:put_agent(C,A,false)
        end, lists:seq(1,8)),
        Parsed = bus_sse_client:until(S,Reader,fun(R) ->
            bus_sse_client:comments(R) >= 3 andalso bus_sse_client:has_event(R,<<"presence_snapshot">>)
        end,Deadline),
        true = bus_sse_client:comments(Parsed) >= 3,
        true = is_process_alive(Conn), true = is_process_alive(W),
        {200,_} = bus_http_SUITE:get(C,"/health",[]),
        Store = whereis(bus_store), Listener = maps:get(pid,ranch:info(bus_http)),
        gen_tcp:close(S),
        await(fun() -> not is_process_alive(W) andalso not receiving(A) end,1000)
    after gen_tcp:close(S) end.
watchdog_fencing(_) ->
    Owner = spawn(fun() -> receive stop -> ok end end),
    M = monitor(process,Owner),
    W = bus_watchdog:start_link(Owner, erlang:monotonic_time(millisecond)+5000),
    ok = bus_watchdog:handshake(W),
    R1 = bus_watchdog:arm(W, erlang:monotonic_time(millisecond)+100),
    ok = bus_watchdog:complete(W,R1),
    R2 = bus_watchdog:arm(W, erlang:monotonic_time(millisecond)+250),
    W ! {expire,R1},
    ok = bus_watchdog:complete(W,R1),
    receive {'DOWN',M,process,Owner,_} -> error(stale_timer_killed_owner)
    after 150 -> ok end,
    receive {'DOWN',M,process,Owner,killed} -> ok
    after 500 -> error(watchdog_did_not_fire) end,
    true = is_reference(R2).
handshake_budget(C) ->
    A = <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>,
    {204,_} = bus_http_SUITE:put_agent(C,A,false),
    {ok,S} = connect(C),
    Start = erlang:monotonic_time(millisecond),
    ok = gen_tcp:send(S,["GET /v1/events?agentId=",A," HTTP/1.1\r\nHost: localhost\r\n"]),
    timer:sleep(3500),
    ok = sys:suspend(bus_store),
    try
        ok = gen_tcp:send(S,"Authorization: Bearer ct-token\r\n\r\n"),
        drain(S),
        Elapsed = erlang:monotonic_time(millisecond)-Start,
        true = Elapsed >= 4500 andalso Elapsed < 6000,
        {200,_} = bus_http_SUITE:get(C,"/health",[])
    after sys:resume(bus_store), gen_tcp:close(S) end,
    {ok,Agents} = bus_store:list_agents(),
    [#{<<"receiving">> := false}] = [X || #{<<"agentId">> := ID}=X <- Agents, ID =:= A].
late_completion(_) ->
    Owner = spawn(fun() -> receive stop -> ok end end),
    M = monitor(process,Owner),
    W = bus_watchdog:start_link(Owner,erlang:monotonic_time(millisecond)+5000),
    ok = bus_watchdog:handshake(W),
    R = bus_watchdog:arm(W,erlang:monotonic_time(millisecond)+100),
    ok = sys:suspend(W),
    %% Queue completion ahead of the timer message, but do not let the
    %% watchdog process it until the absolute deadline has elapsed.
    W ! {'$gen_call',{self(),make_ref()},{complete,R}},
    timer:sleep(150),
    ok = sys:resume(W),
    receive {'DOWN',M,process,Owner,killed} -> ok
    after 1000 -> error(late_completion_revived_write) end.
methods(C) ->
    lists:foreach(fun({Path,Auth}) ->
        {ok,S} = connect(C),
        ok = gen_tcp:send(S,["POST ",Path," HTTP/1.1\r\nHost: localhost\r\n",Auth,"\r\n"]),
        D = drain(S),
        true = binary:match(D, <<"405 Method Not Allowed">>) =/= nomatch
    end,[{"/health",[]},{"/v1/events?agentId=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "Authorization: Bearer ct-token\r\n"}]).
replacement(C) ->
    A = <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>,
    {204,_} = bus_http_SUITE:put_agent(C,A,false),
    Open = fun() ->
        {ok,S} = connect(C),
        ok = gen_tcp:send(S,["GET /v1/events?agentId=",A,
            " HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ct-token\r\n\r\n"]),
        {ok,_} = gen_tcp:recv(S,0,1000), S
    end,
    S1 = Open(),
    await(fun() -> length(ranch:procs(bus_http,connections)) =:= 1 end,1000),
    [Conn1] = protocol_connections(bus_http), W1 = watchdog(Conn1),
    S2 = Open(),
    drain(S1),
    await(fun() -> not is_process_alive(W1) end,1000),
    {200,Body} = bus_http_SUITE:get(C,"/v1/agents",bus_http_SUITE:auth()),
    {ok,#{<<"agents">> := Agents}} = bus_protocol:decode_json(Body),
    [#{<<"receiving">> := true}] = [X || #{<<"agentId">> := ID}=X <- Agents, ID =:= A],
    await(fun() -> length(ranch:procs(bus_http,connections)) =:= 1 end,1000),
    [Conn2] = protocol_connections(bus_http), W2 = watchdog(Conn2),
    gen_tcp:close(S2),
    await(fun() -> not is_process_alive(W2) andalso not receiving(A) end,1000),
    ok = bus_store:delete_agent(A).
stalled_before_ack(C) -> stalled(C,before_ack).
stalled_after_ack(C) -> stalled(C,after_ack).
stalled(C,Mode) -> stalled(C,Mode,timeout).
blocked_helper_failure(C) ->
    lists:foreach(fun({Mode,Failure}) -> stalled(C,Mode,Failure) end,
        [{Mode,Failure} || Mode <- [before_ack,after_ack], Failure <- [watchdog_normal,watchdog,supervisor,shutdown]]).
stalled(C,Mode,Failure) ->
    true = register(bus_transport_observer,self()),
    Opts = ranch:get_protocol_options(bus_http),
    Dispatch = cowboy_router:compile([{'_', [{"/stall",bus_transport_fixture,Mode},
        {"/v1/events",bus_events_h,[]},{"/health",bus_health_h,[]}]}]),
    %% A deterministic local transport fault, not a timing-dependent guess
    %% about kernel buffer occupancy. All non-stalled sends use ranch_tcp.
    {ok,_} = ranch:start_listener(bus_stall,ranch_tcp,
        #{connection_type => supervisor, num_acceptors => 1, num_conns_sups => 1,
          socket_opts => [{ip,{127,0,0,1}},{port,0},{send_timeout,5000},{send_timeout_close,true}]},
        bus_transport_fixture,Opts#{env := #{dispatch => Dispatch}}),
    try
        {204,_} = bus_http_SUITE:put_agent(C,lifecycle_b(),false),
        FC = [{port,ranch:get_port(bus_stall)}|C],
        with_stream(bus_stall,FC,lifecycle_b(),0,fun(HS,Healthy,Reader) ->
        Before = ranch:procs(bus_stall,connections),
        {ok,S} = connect(FC),
        try
        ok = gen_tcp:send(S,"GET /stall HTTP/1.1\r\nHost: localhost\r\n\r\n"),
        {Handler,Conn} = receive {ready,H,P} -> {H,P} after 1000 -> error(no_handler) end,
        W = watchdog(Conn),
        [Sup] = ranch:procs(bus_stall,connections) -- Before,
        {Conn,W} = bus_connection_sup:children(Sup),
        M = monitor(process,Conn), HM = monitor(process,Handler),
        case Mode of before_ack -> true = erlang:suspend_process(Conn); after_ack -> ok end,
        Start = erlang:monotonic_time(millisecond),
        Handler ! go,
        case Mode of after_ack -> receive send_blocked -> ok after 1000 -> error(no_block) end; _ -> ok end,
        {200,_} = bus_http_SUITE:get(C,"/health",[]),
        FailureStart = erlang:monotonic_time(millisecond),
        Bound = case Failure of
            timeout -> 6000;
            watchdog_normal -> gen_server:stop(W,normal,1000), 1000;
            watchdog -> exit(W,kill), 1000;
            supervisor -> exit(Sup,kill), 1000;
            shutdown -> spawn(fun() -> gen_server:stop(Sup,shutdown,4000) end), 3500
        end,
        receive {'DOWN',M,process,Conn,killed} -> ok after Bound -> error(connection_not_killed) end,
        Elapsed = erlang:monotonic_time(millisecond)-Start,
        case Failure of
            timeout -> true = Elapsed >= 4500 andalso Elapsed < 6000;
            shutdown ->
                ShutdownElapsed = erlang:monotonic_time(millisecond)-FailureStart,
                true = ShutdownElapsed >= 2900 andalso ShutdownElapsed < 3500;
            _ -> true = erlang:monotonic_time(millisecond)-FailureStart < 1000
        end,
        receive {'DOWN',HM,process,Handler,_} -> ok after 1000 -> error(handler_leaked) end,
        await(fun() -> not is_process_alive(W) andalso not is_process_alive(Sup) end,1000),
        receive incorrectly_completed -> error(ack_disarmed_watchdog) after 0 -> ok end,
        _ = keepalive_frame(lifecycle_b(),HS,Reader),
        assert_tree_alive(Healthy),
        {HealthySup,HealthyConn,HealthyW} = Healthy,
        {HealthyConn,HealthyW} = bus_connection_sup:children(HealthySup),
        false = is_process_alive(Handler)
        after gen_tcp:close(S) end
        end)
    after
        try stop_fixture(bus_stall)
        after bus_store:delete_agent(lifecycle_b()), unregister(bus_transport_observer) end
    end.
kernel_backpressure(C) ->
    A = <<"dddddddd-dddd-4ddd-8ddd-dddddddddddd">>,
    B = <<"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee">>,
    true = register(bus_slow_observer,self()),
    try
        %% Use the real routes, SSE handler, store and watchdog chain. Only
        %% socket buffer sizes differ; the observing transport does real sends.
        {ok,_} = ranch:start_listener(bus_slow,ranch_tcp,
            #{connection_type => supervisor, num_acceptors => 1, num_conns_sups => 1,
              socket_opts => [{ip,{127,0,0,1}},{port,0},{sndbuf,1024},
                  {send_timeout,5000},{send_timeout_close,true}]},
            bus_slow_transport,ranch:get_protocol_options(bus_http)),
        SlowC = [{port,ranch:get_port(bus_slow)}|C],
        {204,_} = bus_http_SUITE:put_agent(C,A,false),
        {204,_} = bus_http_SUITE:put_agent(C,B,false),
        Registered = erlang:monotonic_time(millisecond),
        with_stream(bus_slow,SlowC,A,0,fun(HS,Healthy,Reader) ->
        Before = ranch:procs(bus_slow,connections),
        {ok,S} = gen_tcp:connect({127,0,0,1},ranch:get_port(bus_slow),
            [binary,{active,false},{recbuf,1024}],1000),
        try
            ok = gen_tcp:send(S,["GET /v1/events?agentId=",B,
                " HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ct-token\r\n\r\n"]),
            await(fun() -> receiving(B) end,1000),
            {Sup,Conn,W} = new_tree(bus_slow,Before,2),
            await(fun() -> handshake_complete(W) end,1000),
            M = monitor(process,Conn),
            try
                %% Exactly one FIFO's worth, with fresh valid IDs and 16 KiB
                %% notices. No dedup/capacity policy overrides or retries.
                lists:foreach(fun(N) ->
                    Id = iolist_to_binary(io_lib:format("99999999-9999-4999-8999-~12.16.0b",[N])),
                    {ok,Msg} = bus_protocol:decode_message(#{
                        <<"id">> => Id, <<"from">> => A, <<"to">> => B,
                        <<"kind">> => <<"notice">>, <<"body">> => binary:copy(<<"x">>,16384)}),
                    {ok,_} = bus_store:accept_mail(Msg)
                end,lists:seq(1,32)),
                %% Do not recv from S, even to consume the response headers.
                %% A send still outstanding after 200 ms supplies evidence of
                %% real backpressure rather than assuming a buffer size did it.
                Start = await_kernel_stall(Conn,erlang:monotonic_time(millisecond)+2000),
                HealthyReader = deliver_notice(B,A,
                    <<"99999999-9999-4999-8999-000000000101">>,HS,Reader),
                assert_tree_alive(Healthy),
                {200,_} = bus_http_SUITE:get(SlowC,"/health",[]),
                receive {'DOWN',M,process,Conn,_} -> ok
                after 6000 -> error(slow_reader_connection_survived) end,
                await(fun() -> not receiving(B) andalso tree_dead({Sup,Conn,W}) end,500),
                Elapsed = erlang:monotonic_time(millisecond)-Start,
                true = Elapsed >= 4500 andalso Elapsed < 6000,
                %% Both entries must still be live. A 15-second lease expiry
                %% cannot satisfy this disconnect/readiness assertion.
                true = erlang:monotonic_time(millisecond)-Registered < 10000,
                {ok,Agents} = bus_store:list_agents(),
                [#{<<"receiving">> := false}] =
                    [X || #{<<"agentId">> := ID}=X <- Agents, ID =:= B],
                _ = deliver_notice(B,A,
                    <<"99999999-9999-4999-8999-000000000102">>,HS,HealthyReader),
                {HealthySup,HealthyConn,HealthyW} = Healthy,
                {HealthyConn,HealthyW} = bus_connection_sup:children(HealthySup),
                assert_tree_alive(Healthy),
                {200,_} = bus_http_SUITE:get(SlowC,"/health",[]),
                ct:pal("Real loopback stalled send and readiness cleanup: ~p ms",[Elapsed])
            after demonitor(M,[flush]) end
        after gen_tcp:close(S) end
        end)
    after
        try stop_fixture(bus_slow)
        after
            try bus_store:delete_agent(A), bus_store:delete_agent(B)
            after unregister(bus_slow_observer) end
        end
    end.

deliver_notice(From,To,Id,S,Reader) ->
    {ok,Msg} = bus_protocol:decode_message(#{<<"id">> => Id,<<"from">> => From,
        <<"to">> => To,<<"kind">> => <<"notice">>,<<"body">> => <<"healthy peer delivery">>}),
    {ok,_} = bus_store:accept_mail(Msg),
    bus_sse_client:until(S,Reader,fun(R) -> bus_sse_client:has_message(R,Id) end,
        erlang:monotonic_time(millisecond)+1000).

await_kernel_stall(Conn,Deadline) ->
    Left = max(0,Deadline-erlang:monotonic_time(millisecond)),
    receive
        {send_started,Conn,Ref,Start,Size} ->
            receive
                {send_returned,Conn,Ref,ok} -> await_kernel_stall(Conn,Deadline);
                {send_returned,Conn,Ref,Error} -> error({premature_send_error,Error})
            after 200 ->
                %% Initial headers/presence are smaller than a full notice.
                %% Stalling before those finish does not exercise SSE writes.
                case Size > 16384 of
                    true -> Start;
                    false -> error({handshake_stalled_instead_of_notice,Size})
                end
            end
    after Left -> error(kernel_backpressure_not_observed) end.

ranch_overshoot(C) ->
    %% Ranch 2.3 applies max_connections per connection supervisor and parks
    %% each acceptor only after its accepted connection starts. One supervisor,
    %% max 2 and four acceptors therefore admits 2 + 4 - 1 = 5, not 2.
    Limit = 2, Acceptors = 4, Expected = Limit + Acceptors - 1,
    try
        {ok,_} = ranch:start_listener(bus_saturation,ranch_tcp,
            #{connection_type => supervisor, num_acceptors => Acceptors,
              num_conns_sups => 1, max_connections => Limit,
              socket_opts => [{ip,{127,0,0,1}},{port,0},
                  {send_timeout,5000},{send_timeout_close,true}]},
            bus_connection,ranch:get_protocol_options(bus_http)),
        with_idle_sockets(ranch:get_port(bus_saturation),12,fun() ->
            %% Open TCP sockets are not all admitted Ranch connections: some
            %% stay in the kernel backlog. Measure the protocol processes.
            await(fun() -> length(ranch:procs(bus_saturation,connections)) >= Expected end,1000),
            Count = length(ranch:procs(bus_saturation,connections)),
            Expected = Count,
            true = Count > Limit,
            timer:sleep(100),
            Expected = length(ranch:procs(bus_saturation,connections)),
            {200,_} = bus_http_SUITE:get(C,"/health",[]),
            ct:pal("Ranch fixture: max/supervisor=~p, supervisors=1, acceptors=~p, admitted=~p",
                [Limit,Acceptors,Count])
        end)
    after stop_fixture(bus_saturation) end.

with_idle_sockets(_Port,0,Fun) -> Fun();
with_idle_sockets(Port,N,Fun) ->
    {ok,S} = gen_tcp:connect({127,0,0,1},Port,[binary,{active,false}],1000),
    try with_idle_sockets(Port,N-1,Fun)
    after gen_tcp:close(S) end.
stop_fixture(Name) ->
    case catch ranch:procs(Name,connections) of
        Pids when is_list(Pids) ->
            Children = lists:append([case catch bus_connection_sup:children(P) of
                {Conn,W} when is_pid(Conn), is_pid(W) -> [Conn,W];
                {'EXIT',_} -> []
            end || P <- Pids]),
            ok = ranch:stop_listener(Name),
            lists:foreach(fun(P) -> false = is_process_alive(P) end,Pids ++ Children);
        _ -> ok
    end.
receiving(Id) ->
    {ok,Agents} = bus_store:list_agents(),
    lists:any(fun(A) -> maps:get(<<"agentId">>,A) =:= Id andalso
        maps:get(<<"receiving">>,A) end,Agents).
await(Fun,Timeout) -> await_until(Fun,erlang:monotonic_time(millisecond)+Timeout).
await_until(Fun,Deadline) ->
    case Fun() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(10), await_until(Fun,Deadline);
                false -> error(condition_deadline)
            end
    end.

withheld_sse_body(C) ->
    A = <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>,
    {204,_} = bus_http_SUITE:put_agent(C,A,false),
    lists:foreach(fun(Header) ->
        {ok,S} = connect(C),
        try
            ok = gen_tcp:send(S,["GET /v1/events?agentId=",A,
                " HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ct-token\r\n",
                Header,"\r\n"]),
            Data = drain(S),
            true = binary:match(Data,<<"400 Bad Request">>) =/= nomatch,
            nomatch = binary:match(Data,<<"text/event-stream">>),
            false = receiving(A)
        after gen_tcp:close(S) end
    end,["Content-Length: 1\r\n","Transfer-Encoding: chunked\r\n"]).

queued_mutation_budget(C) ->
    A = <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>,
    {204,_} = bus_http_SUITE:put_agent(C,A,false),
    {ok,Before} = bus_store:list_agents(),
    [Agent] = [X || #{<<"agentId">> := ID}=X <- Before, ID =:= A],
    Body = bus_protocol:encode_map((maps:without([<<"receiving">>,<<"updatedAt">>],Agent))#{
        <<"label">> := <<"must-not-mutate-after-original-deadline">>}),
    {ok,S} = connect(C),
    try
        Start = erlang:monotonic_time(millisecond),
        ok = gen_tcp:send(S,["PUT /v1/agents/",A," HTTP/1.1\r\nHost: localhost\r\n"]),
        timer:sleep(3000),
        ok = sys:suspend(bus_store),
        try
            ok = gen_tcp:send(S,["Authorization: Bearer ct-token\r\nContent-Length: ",
                integer_to_binary(byte_size(Body)),"\r\n\r\n",Body]),
            await(fun() ->
                {messages,Messages} = process_info(whereis(bus_store),messages),
                lists:any(fun({'$gen_call',_,_}) -> true; (_) -> false end,Messages)
            end,1000),
            drain(S),
            Elapsed = erlang:monotonic_time(millisecond)-Start,
            true = Elapsed >= 4500 andalso Elapsed < 6000
        after sys:resume(bus_store) end,
        {ok,After} = bus_store:list_agents(),
        [Current] = [X || #{<<"agentId">> := ID}=X <- After, ID =:= A],
        true = maps:get(<<"label">>,Current) =:= maps:get(<<"label">>,Agent)
    after gen_tcp:close(S) end.

watchdog_failure(C) ->
    lists:foreach(fun({Stage,Reason}) ->
        lifecycle_fixture(C,fun(FC) ->
            with_lifecycle_stream(FC,lifecycle_b(),0,fun(HS,Healthy,Reader) ->
                Store = whereis(bus_store), Listener = maps:get(pid,ranch:info(bus_lifecycle)),
                Before = ranch:procs(bus_lifecycle,connections),
                {ok,S} = connect(FC),
                try
                    case Stage of
                        before_headers -> ok;
                        after_headers -> gen_tcp:send(S,
                            "PUT /v1/agents/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ct-token\r\nContent-Length: 100\r\n\r\n{");
                        stream -> gen_tcp:send(S,["GET /v1/events?agentId=",lifecycle_a(),
                            " HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ct-token\r\n\r\n"])
                    end,
                    Tree = new_tree(Before,2),
                    {_Sup,Conn,W} = Tree,
                    case Stage of
                        after_headers -> await(fun() -> supervisor:which_children(Conn) =/= [] end,1000);
                        stream -> await(fun() -> receiving(lifecycle_a()) andalso handshake_complete(W) end,1000);
                        _ -> ok
                    end,
                    case Reason of normal -> gen_server:stop(W,normal,1000); kill -> exit(W,kill) end,
                    await(fun() -> tree_dead(Tree) end,1000),
                    drain(S),
                    await(fun() -> not receiving(lifecycle_a()) end,1000),
                    assert_tree_alive(Healthy),
                    {200,_} = bus_http_SUITE:get(FC,"/health",[]),
                    Store = whereis(bus_store), Listener = maps:get(pid,ranch:info(bus_lifecycle)),
                    _ = keepalive_frame(lifecycle_b(),HS,Reader),
                    assert_tree_alive(Healthy)
                after gen_tcp:close(S) end
            end)
        end)
    end,[{Stage,Reason} || Stage <- [before_headers,after_headers,stream], Reason <- [normal,kill]]).

connection_supervision(C) ->
    lists:foreach(fun(Action) ->
        lifecycle_fixture(C,fun(FC) ->
            with_lifecycle_stream(FC,lifecycle_a(),0,fun(S,Tree={Sup,Conn,_},_Reader) ->
                case Action of
                    close -> gen_tcp:close(S);
                    protocol_death -> exit(Conn,kill);
                    supervisor_death -> exit(Sup,kill);
                    supervisor_shutdown ->
                        M = monitor(process,Conn),
                        1 = erlang:trace(Conn,true,['receive']),
                        {Stopper,SM} = spawn_monitor(fun() -> gen_server:stop(Sup,shutdown,7000) end),
                        try
                            %% Keep the client open: shutdown must cancel SSE,
                            %% not depend on the peer completing the last stream.
                            receive {trace,Conn,'receive',{'EXIT',Sup,{shutdown,bus_connection_stop}}} -> ok
                            after 1000 -> error(missing_parent_shutdown) end,
                            receive {'DOWN',M,process,Conn,{shutdown,{stop,{exit,{shutdown,bus_connection_stop}},_}}} -> ok
                            after 3500 -> error(not_cowboy_graceful_shutdown) end,
                            receive {'DOWN',SM,process,Stopper,normal} -> ok
                            after 1000 -> error(supervisor_did_not_finish) end
                        after
                            catch erlang:trace(Conn,false,['receive']),
                            exit(Stopper,kill), demonitor(SM,[flush]), demonitor(M,[flush])
                        end
                end,
                await(fun() -> tree_dead(Tree) andalso not receiving(lifecycle_a()) end,1000),
                [] = ranch:procs(bus_lifecycle,connections),
                {200,_} = bus_http_SUITE:get(FC,"/health",[])
            end)
        end)
    end,[close,protocol_death,supervisor_death,supervisor_shutdown]).

listener_store_cleanup(C) ->
    %% Exercise the actual bus_sup rest_for_one tree, not only a detached
    %% fixture listener. Refresh the port after every ephemeral-port restart.
    lists:foreach(fun(Action) ->
        MainC = [{port,ranch:get_port(bus_http)}|C],
        A = lifecycle_a(),
        {204,_} = bus_http_SUITE:put_agent(MainC,A,false),
        await(fun() -> ranch:procs(bus_http,connections) =:= [] end,1000),
        {ok,S} = connect(MainC),
        try
            ok = gen_tcp:send(S,["GET /v1/events?agentId=",A,
                " HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ct-token\r\n\r\n"]),
            await(fun() -> receiving(A) end,1000),
            [Sup] = ranch:procs(bus_http,connections),
            {Conn,W} = bus_connection_sup:children(Sup), Tree = {Sup,Conn,W},
            OldStore = whereis(bus_store), OldListener = maps:get(pid,ranch:info(bus_http)),
            case Action of
                listener -> exit(OldListener,kill);
                store -> exit(OldStore,kill)
            end,
            %% Active SSE is cancelled without client-assisted draining.
            await(fun() -> tree_dead(Tree) end,3500),
            await(fun() ->
                case catch ranch:info(bus_http) of
                    #{pid := P,status := running} -> P =/= OldListener;
                    _ -> false
                end
            end,2000),
            NewStore = whereis(bus_store),
            case Action of
                listener -> OldStore = NewStore;
                store -> true = OldStore =/= NewStore
            end,
            false = receiving(A),
            {200,_} = bus_http_SUITE:get([{port,ranch:get_port(bus_http)}|C],"/health",[])
        after gen_tcp:close(S) end
    end,[listener,store]).

lifecycle_a() -> <<"dddddddd-dddd-4ddd-8ddd-dddddddddddd">>.
lifecycle_b() -> <<"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee">>.
lifecycle_fixture(C,Fun) ->
    try
        {ok,_} = ranch:start_listener(bus_lifecycle,ranch_tcp,
            #{connection_type => supervisor, num_acceptors => 2, num_conns_sups => 1,
              logger => bus_log, socket_opts => [{ip,{127,0,0,1}},{port,0},
                  {send_timeout,5000},{send_timeout_close,true}]},
            bus_connection,ranch:get_protocol_options(bus_http)),
        FC = [{port,ranch:get_port(bus_lifecycle)}|C],
        {204,_} = bus_http_SUITE:put_agent(FC,lifecycle_a(),false),
        {204,_} = bus_http_SUITE:put_agent(FC,lifecycle_b(),false),
        await(fun() -> ranch:procs(bus_lifecycle,connections) =:= [] end,1000),
        Fun(FC)
    after
        try stop_fixture(bus_lifecycle)
        after bus_store:delete_agent(lifecycle_a()), bus_store:delete_agent(lifecycle_b()) end
    end.
with_lifecycle_stream(C,Id,Existing,Fun) ->
    with_stream(bus_lifecycle,C,Id,Existing,Fun).
with_stream(Name,C,Id,Existing,Fun) ->
    Before = ranch:procs(Name,connections),
    Existing = length(Before),
    {ok,S} = connect(C),
    try
        ok = gen_tcp:send(S,["GET /v1/events?agentId=",Id,
            " HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ct-token\r\n\r\n"]),
        await(fun() -> receiving(Id) end,1000),
        Tree = {_,_,W} = new_tree(Name,Before,Existing+1),
        await(fun() -> handshake_complete(W) end,1000),
        Deadline = erlang:monotonic_time(millisecond)+1000,
        Reader = bus_sse_client:until(S,bus_sse_client:open(S,Deadline),
            fun(R) -> bus_sse_client:has_event(R,<<"presence_snapshot">>) end,Deadline),
        Fun(S,Tree,Reader)
    after gen_tcp:close(S) end.
new_tree(Before,Count) -> new_tree(bus_lifecycle,Before,Count).
new_tree(Name,Before,Count) ->
    await(fun() -> length(ranch:procs(Name,connections)) =:= Count end,1000),
    [Sup] = ranch:procs(Name,connections) -- Before,
    {Conn,W} = bus_connection_sup:children(Sup),
    {Sup,Conn,W}.
tree_dead({Sup,Conn,W}) ->
    not is_process_alive(Sup) andalso not is_process_alive(Conn) andalso not is_process_alive(W).
assert_tree_alive({Sup,Conn,W}) ->
    true = is_process_alive(Sup), true = is_process_alive(Conn), true = is_process_alive(W).

protocol_connections(Name) ->
    [begin {Conn,_} = bus_connection_sup:children(Sup), Conn end
        || Sup <- ranch:procs(Name,connections)].
watchdog(Conn) ->
    {dictionary,Dict} = process_info(Conn,dictionary),
    {_,W} = proplists:get_value(bus_transport,Dict), W.
handshake_complete(W) -> maps:get(request,sys:get_state(W)) =:= undefined.
keepalive_frame(Id,S,Reader) ->
    #{subs := Subs} = sys:get_state(bus_store),
    #{pid := H} = maps:get(Id,Subs),
    H ! keepalive,
    Count = bus_sse_client:comments(Reader),
    bus_sse_client:until(S,Reader,fun(R) -> bus_sse_client:comments(R) > Count end,
        erlang:monotonic_time(millisecond)+1000).

supervisor_inspection(C) ->
    lifecycle_fixture(C,fun(FC) ->
        with_lifecycle_stream(FC,lifecycle_a(),0,fun(S,Tree={Sup,Conn,W},Reader) ->
            [{connection,Conn,supervisor,[cowboy_http]},
                {watchdog,W,worker,[bus_watchdog]}] = supervisor:which_children(Sup),
            [{specs,2},{active,2},{supervisors,1},{workers,1}] = supervisor:count_children(Sup),
            {error,one_shot_connection} = supervisor:restart_child(Sup,watchdog),
            {error,one_shot_connection} = gen_server:call(Sup,unsupported_inspection),
            _ = keepalive_frame(lifecycle_a(),S,Reader),
            {Conn,W} = bus_connection_sup:children(Sup),
            assert_tree_alive(Tree)
        end)
    end).

shutdown_cleanup(C) ->
    true = register(bus_transport_observer,self()),
    try
        lists:foreach(fun(Mode) ->
            Opts = ranch:get_protocol_options(bus_http),
            Dispatch = cowboy_router:compile([{'_', [{"/cleanup",bus_transport_fixture,Mode},
                {"/v1/agents/:agent_id",bus_http_h,agent}]}]),
            {ok,_} = ranch:start_listener(bus_cleanup,ranch_tcp,
                #{connection_type => supervisor, num_acceptors => 1, num_conns_sups => 1,
                  socket_opts => [{ip,{127,0,0,1}},{port,0}]},
                bus_connection,Opts#{env := #{dispatch => Dispatch},
                    stream_handlers := [bus_transport_fixture,bus_deadline_stream,cowboy_stream_h]}),
            {ok,S} = connect([{port,ranch:get_port(bus_cleanup)}|C]),
            try
                Request = case Mode of
                    headers -> "GET /cleanup HTTP/1.1\r\nHost: localhost\r\n";
                    body -> "PUT /v1/agents/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ct-token\r\nContent-Length: 100\r\n\r\n{";
                    _ -> "GET /cleanup HTTP/1.1\r\nHost: localhost\r\n\r\n"
                end,
                ok = gen_tcp:send(S,Request),
                await(fun() -> length(ranch:procs(bus_cleanup,connections)) =:= 1 end,1000),
                [Sup] = ranch:procs(bus_cleanup,connections),
                {Conn,W} = bus_connection_sup:children(Sup),
                Child = case Mode of
                    headers -> undefined;
                    body ->
                        await(fun() -> supervisor:which_children(Conn) =/= [] end,1000),
                        undefined;
                    _ -> receive {ready,H,Conn} -> H after 1000 -> error(no_cleanup_child) end
                end,
                HM = case Child of undefined -> undefined; _ -> monitor(process,Child) end,
                M = monitor(process,Conn),
                Start = erlang:monotonic_time(millisecond),
                ok = gen_server:stop(Sup,shutdown,3500),
                receive {'DOWN',M,process,Conn,{shutdown,{stop,{exit,{shutdown,bus_connection_stop}},_}}} -> ok
                after 100 -> error(connection_cleanup_bypassed) end,
                true = erlang:monotonic_time(millisecond)-Start < 3000,
                case Child of
                    undefined -> ok;
                    _ ->
                        receive {stream_terminated,Conn,{stop,{exit,{shutdown,bus_connection_stop}},_}} -> ok
                        after 0 -> error(no_stream_cleanup) end,
                        receive {child_shutdown,Child} -> ok after 0 -> error(no_child_shutdown) end,
                        Expected = case Mode of trap -> killed; cooperative -> normal end,
                        receive {'DOWN',HM,process,Child,Expected} -> ok;
                            {'DOWN',HM,process,Child,Other} -> error({child_cleanup_failed,Mode,Other})
                        after 100 -> error(child_cleanup_failed) end
                end,
                true = tree_dead({Sup,Conn,W}),
                [] = ranch:procs(bus_cleanup,connections),
                {200,_} = bus_http_SUITE:get([{port,ranch:get_port(bus_http)}|C],"/health",[])
            after gen_tcp:close(S), stop_fixture(bus_cleanup) end
        end,[headers,body,cooperative,trap])
    after unregister(bus_transport_observer) end.

drain(S) -> drain(S,<<>>).
drain(S,Acc) ->
    case gen_tcp:recv(S,0,6500) of
        {ok,D} -> drain(S,<<Acc/binary,D/binary>>);
        {error,closed} -> Acc;
        Other -> error({not_closed,Other})
    end.
