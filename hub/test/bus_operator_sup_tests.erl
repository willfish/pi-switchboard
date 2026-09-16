-module(bus_operator_sup_tests).
-include_lib("eunit/include/eunit.hrl").

listener_id() -> {ranch_embedded_sup, bus_http}.

tree_test_() ->
    {inorder, [
        {setup, fun setup_disabled/0, fun cleanup/1, {timeout, 10, {inorder, [
            fun default_disabled_topology/0,
            fun invalid_mode_keeps_core_topology/0,
            fun malformed_tailnet_name_keeps_core_topology/0
        ]}}},
        {setup, fun setup_tailnet/0, fun cleanup/1, {timeout, 10,
            fun tailnet_topology/0}},
        {setup, fun setup_enabled/0, fun cleanup/1, {timeout, 20, {inorder, [
            fun operator_init_does_not_query_interfaces/0,
            fun children_include_transient_operator_after_listener/0,
            fun auth_recovers_gate_stays/0,
            fun gate_loss_stays_unavailable/0,
            fun mail_preserved_on_operator_failure/0,
            fun subtree_budget_exhaustion_does_not_take_core/0,
            fun listener_recovery_reconstructs_operator/0,
            fun store_loss_clears_operator_state/0,
            fun invalid_operator_config_is_disabled/0
        ]}}}
    ]}.

setup_disabled() -> start_tree(default).
setup_tailnet() -> start_tree({tailnet, "tailscale0"}).
setup_enabled() -> start_tree(loopback).

tailnet_topology() ->
    Children = supervisor:which_children(bus_sup),
    Ids = lists:sort([Id || {Id, _, _, _} <- Children]),
    ?assertEqual(lists:sort([bus_store, listener_id(), bus_operator_sup]), Ids),
    ?assert(is_pid(whereis(bus_operator_sup))).

start_tree(Access) ->
    application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(cowboy),
    ?assertEqual(undefined, whereis(bus_sup)),
    ?assertEqual(undefined, whereis(bus_store)),
    ?assertEqual(undefined, whereis(bus_operator_sup)),
    OldAccess = application:get_env(pi_agent_bus, operator_access),
    OldToken = application:get_env(pi_agent_bus, token),
    case Access of
        default -> application:unset_env(pi_agent_bus, operator_access);
        _ -> application:set_env(pi_agent_bus, operator_access, Access)
    end,
    application:set_env(pi_agent_bus, token, <<"ct-token">>),
    {ok, Pid} = bus_sup:start_link(#{bind_host => "127.0.0.1", port => 0}),
    unlink(Pid),
    #{pid => Pid, old_access => OldAccess, old_token => OldToken}.

cleanup(#{pid := Pid, old_access := OldAccess, old_token := OldToken}) ->
    catch supervisor:terminate_child(Pid, bus_operator_sup),
    catch gen_server:stop(Pid),
    catch ranch:stop_listener(bus_http),
    case whereis(bus_store) of undefined -> ok; S -> catch gen_server:stop(S) end,
    case whereis(bus_operator_auth) of undefined -> ok; A -> catch gen_server:stop(A) end,
    case whereis(bus_operator_http_gate) of undefined -> ok; G -> catch gen_server:stop(G) end,
    case whereis(bus_operator_journal) of undefined -> ok; J -> catch gen_server:stop(J) end,
    case whereis(bus_operator_native) of undefined -> ok; N -> catch gen_server:stop(N) end,
    case whereis(bus_operator_ops) of undefined -> ok; O -> catch gen_server:stop(O) end,
    case whereis(bus_operator_activity) of undefined -> ok; Act -> catch gen_server:stop(Act) end,
    restore_env(operator_access, OldAccess),
    restore_env(token, OldToken),
    ok.

restore_env(Key, undefined) -> application:unset_env(pi_agent_bus, Key);
restore_env(Key, {ok, Value}) -> application:set_env(pi_agent_bus, Key, Value).

default_disabled_topology() ->
    Children = supervisor:which_children(bus_sup),
    Ids = lists:sort([Id || {Id, _, _, _} <- Children]),
    ?assertEqual(lists:sort([bus_store, listener_id()]), Ids),
    ?assertEqual(undefined, whereis(bus_operator_sup)),
    {403, _, Body} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    ?assertEqual(<<"disabled">>, error_code(Body)),
    {200, _, _} = get("/v1/agents", bearer()).

invalid_mode_keeps_core_topology() ->
    #{old_access := OldAccess, old_token := OldToken} =
        cleanup_running_tree(),
    application:set_env(pi_agent_bus, operator_access, not_a_mode),
    application:set_env(pi_agent_bus, token, <<"ct-token">>),
    {ok, New} = bus_sup:start_link(#{bind_host => "127.0.0.1", port => 0}),
    unlink(New),
    Children = supervisor:which_children(bus_sup),
    Ids = lists:sort([Id || {Id, _, _, _} <- Children]),
    ?assertEqual(lists:sort([bus_store, listener_id()]), Ids),
    ?assertEqual(undefined, whereis(bus_operator_sup)),
    catch gen_server:stop(New),
    catch ranch:stop_listener(bus_http),
    restore_env(operator_access, OldAccess),
    restore_env(token, OldToken),
    ok.

malformed_tailnet_name_keeps_core_topology() ->
    case whereis(bus_sup) of
        undefined -> ok;
        Pid -> catch gen_server:stop(Pid), catch ranch:stop_listener(bus_http)
    end,
    Names = ["../bad", "bad name", "tailscale0;", "eth0/0", "", lists:duplicate(65, $x)],
    try
        lists:foreach(fun(Name) ->
            application:set_env(pi_agent_bus, operator_access, {tailnet, Name}),
            application:set_env(pi_agent_bus, token, <<"ct-token">>),
            {ok, New} = bus_sup:start_link(#{bind_host => "127.0.0.1", port => 0}),
            unlink(New),
            Ids = lists:sort([Id || {Id, _, _, _} <- supervisor:which_children(bus_sup)]),
            ?assertEqual(lists:sort([bus_store, listener_id()]), Ids),
            ?assertEqual(undefined, whereis(bus_operator_sup)),
            catch gen_server:stop(New),
            catch ranch:stop_listener(bus_http)
        end, Names)
    after
        case whereis(bus_sup) of undefined -> ok; P -> catch gen_server:stop(P) end,
        catch ranch:stop_listener(bus_http)
    end.

cleanup_running_tree() ->
    Pid = whereis(bus_sup),
    OldAccess = application:get_env(pi_agent_bus, operator_access),
    OldToken = application:get_env(pi_agent_bus, token),
    catch gen_server:stop(Pid),
    catch ranch:stop_listener(bus_http),
    #{pid => Pid, old_access => OldAccess, old_token => OldToken}.

operator_init_does_not_query_interfaces() ->
    _ = erlang:trace_pattern({net, getifaddrs, 0}, true, [call_count]),
    try
        catch supervisor:terminate_child(bus_sup, bus_operator_sup),
        {ok, _} = supervisor:restart_child(bus_sup, bus_operator_sup),
        Count = case erlang:trace_info({net, getifaddrs, 0}, call_count) of
            {call_count, undefined} -> 0;
            {call_count, N} -> N
        end,
        ?assertEqual(0, Count)
    after
        erlang:trace_pattern({net, getifaddrs, 0}, false, [call_count])
    end.

children_include_transient_operator_after_listener() ->
    Children = supervisor:which_children(bus_sup),
    Ids = lists:sort([Id || {Id, _, _, _} <- Children]),
    ?assertEqual(lists:sort([bus_store, listener_id(), bus_operator_sup]), Ids),
    {ok, #{restart := transient}} = supervisor:get_childspec(bus_sup, bus_operator_sup),
    {bus_operator_sup, Op, supervisor, _} = lists:keyfind(bus_operator_sup, 1, Children),
    ?assert(is_pid(Op)),
    ListenerId = listener_id(),
    {ListenerId, Listener, supervisor, _} = lists:keyfind(ListenerId, 1, Children),
    ?assert(is_pid(Listener)),
    ?assert(is_pid(whereis(bus_operator_auth))),
    ?assert(is_pid(whereis(bus_operator_journal))),
    ?assert(is_pid(whereis(bus_operator_native))),
    ?assert(is_pid(whereis(bus_operator_ops))),
    ?assert(is_pid(whereis(bus_operator_activity))),
    ?assert(is_pid(whereis(bus_operator_http_gate))).

auth_recovers_gate_stays() ->
    Gate = whereis(bus_operator_http_gate),
    Auth = whereis(bus_operator_auth),
    Mon = monitor(process, Auth),
    exit(Auth, kill),
    receive {'DOWN', Mon, process, Auth, _} -> ok end,
    New = wait_pid(bus_operator_auth, Auth, 40),
    ?assert(is_pid(New)),
    ?assertEqual(Gate, whereis(bus_operator_http_gate)).

gate_loss_stays_unavailable() ->
    Gate = whereis(bus_operator_http_gate),
    Mon = monitor(process, Gate),
    exit(Gate, kill),
    receive {'DOWN', Mon, process, Gate, _} -> ok end,
    timer:sleep(50),
    ?assertEqual(undefined, whereis(bus_operator_http_gate)),
    ?assert(is_pid(whereis(bus_operator_auth))),
    {503, _, Body} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    ?assertEqual(<<"capacity">>, error_code(Body)).

mail_preserved_on_operator_failure() ->
    Id = <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>,
    Other = <<"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb">>,
    ok = bus_store:put_agent(agent(Id)),
    ok = bus_store:put_agent(agent(Other)),
    {ok, _} = bus_store:accept_mail(#{
        <<"id">> => <<"33333333-3333-4333-8333-333333333333">>,
        <<"from">> => Other, <<"to">> => Id, <<"kind">> => <<"notice">>,
        <<"body">> => <<"operator failure mail fixture">>}),
    Before = maps:get(mail, maps:get(model, sys:get_state(bus_store))),
    case whereis(bus_operator_http_gate) of
        undefined -> ok;
        Gate -> exit(Gate, kill), timer:sleep(50)
    end,
    After = maps:get(mail, maps:get(model, sys:get_state(bus_store))),
    ?assertEqual(Before, After),
    {200, _, Listed} = get("/v1/agents", bearer()),
    {ok, #{<<"agents">> := Agents}} = bus_protocol:decode_json(Listed),
    ?assert(Agents =/= []).

subtree_budget_exhaustion_does_not_take_core() ->
    Store = whereis(bus_store),
    Parent = whereis(bus_sup),
    exhaust_operator_auth(20),
    wait_until(fun() -> whereis(bus_operator_sup) =:= undefined end, 40),
    ?assertEqual(Parent, whereis(bus_sup)),
    ?assertEqual(Store, whereis(bus_store)),
    {503, _, Body} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    ?assertEqual(<<"capacity">>, error_code(Body)),
    {200, _, _} = get("/v1/agents", bearer()).

listener_recovery_reconstructs_operator() ->
    {ListenerId, Listener, _, _} =
        lists:keyfind(listener_id(), 1, supervisor:which_children(bus_sup)),
    ?assertEqual(listener_id(), ListenerId),
    Mon = monitor(process, Listener),
    exit(Listener, kill),
    receive {'DOWN', Mon, process, Listener, _} -> ok end,
    wait_until(fun() ->
        case lists:keyfind(listener_id(), 1, supervisor:which_children(bus_sup)) of
            {_, New, _, _} when is_pid(New), New =/= Listener ->
                is_pid(whereis(bus_operator_sup)) andalso
                    is_pid(whereis(bus_operator_http_gate)) andalso
                    is_pid(whereis(bus_operator_auth));
            _ -> false
        end
    end, 40),
    {200, _, Body} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    ?assertMatch(#{<<"session">> := <<_:64/binary>>}, json_map(Body)).

store_loss_clears_operator_state() ->
    {200, _, Body} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    Hex = maps:get(<<"session">>, json_map(Body)),
    Store = whereis(bus_store),
    Mon = monitor(process, Store),
    exit(Store, kill),
    receive {'DOWN', Mon, process, Store, _} -> ok end,
    wait_until(fun() ->
        New = whereis(bus_store),
        is_pid(New) andalso New =/= Store andalso
            is_pid(whereis(bus_operator_auth))
    end, 40),
    {401, _, _} = get("/dashboard/api/v1/presence",
        [{<<"x-switchboard-session">>, Hex} | origin_h()]),
    {200, _, Body2} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    Hex2 = maps:get(<<"session">>, json_map(Body2)),
    ?assertNotEqual(Hex, Hex2).

invalid_operator_config_is_disabled() ->
    SavedA = os:getenv("PI_AGENT_BUS_OPERATOR_ACCESS"),
    SavedI = os:getenv("PI_AGENT_BUS_OPERATOR_INTERFACE"),
    try
        true = os:putenv("PI_AGENT_BUS_OPERATOR_ACCESS", "not-a-mode"),
        ?assertEqual(disabled, bus_app:operator_access()),
        true = os:putenv("PI_AGENT_BUS_OPERATOR_ACCESS", "tailnet"),
        true = os:putenv("PI_AGENT_BUS_OPERATOR_INTERFACE", lists:duplicate(65, $x)),
        ?assertEqual(disabled, bus_app:operator_access()),
        true = os:putenv("PI_AGENT_BUS_OPERATOR_INTERFACE", "../bad"),
        ?assertEqual(disabled, bus_app:operator_access()),
        true = os:putenv("PI_AGENT_BUS_OPERATOR_ACCESS", "tailnet"),
        true = os:putenv("PI_AGENT_BUS_OPERATOR_INTERFACE", "tailscale0"),
        ?assertEqual({tailnet, "tailscale0"}, bus_app:operator_access()),
        true = os:putenv("PI_AGENT_BUS_OPERATOR_ACCESS", "loopback"),
        ?assertEqual(loopback, bus_app:operator_access())
    after
        restore_os("PI_AGENT_BUS_OPERATOR_ACCESS", SavedA),
        restore_os("PI_AGENT_BUS_OPERATOR_INTERFACE", SavedI)
    end.

restore_os(Key, false) -> os:unsetenv(Key);
restore_os(Key, Value) -> os:putenv(Key, Value).

exhaust_operator_auth(0) -> ok;
exhaust_operator_auth(N) ->
    case whereis(bus_operator_sup) of
        undefined -> ok;
        _ ->
            case whereis(bus_operator_auth) of
                Pid when is_pid(Pid) ->
                    Mon = monitor(process, Pid),
                    exit(Pid, kill),
                    receive {'DOWN', Mon, process, Pid, _} -> ok
                    after 1000 -> error(auth_alive) end;
                undefined -> timer:sleep(20)
            end,
            exhaust_operator_auth(N - 1)
    end.

wait_pid(Name, Old, 0) -> error({no_replacement, Name, Old});
wait_pid(Name, Old, N) ->
    case whereis(Name) of
        Pid when is_pid(Pid), Pid =/= Old -> Pid;
        _ -> timer:sleep(25), wait_pid(Name, Old, N - 1)
    end.

wait_until(_F, 0) -> error(timeout);
wait_until(F, N) ->
    case F() of
        true -> ok;
        false -> timer:sleep(25), wait_until(F, N - 1)
    end.

agent(Id) ->
    #{<<"agentId">> => Id, <<"sessionId">> => Id, <<"host">> => <<"test">>,
      <<"cwd">> => <<"/tmp">>, <<"sessionName">> => <<"test">>, <<"label">> => <<"test">>,
      <<"model">> => null, <<"status">> => <<"idle">>, <<"pid">> => 1,
      <<"acceptsControl">> => false}.

port() -> ranch:get_port(bus_http).
host() -> iolist_to_binary(["localhost:", integer_to_list(port())]).
origin() -> <<"http://", (host())/binary>>.
origin_h() -> [{<<"origin">>, origin()}].
json() -> [{<<"content-type">>, <<"application/json">>}].
bearer() -> [{<<"authorization">>, <<"Bearer ct-token">>}].

error_code(Body) ->
    {ok, #{<<"error">> := #{<<"code">> := Code}}} = bus_protocol:decode_json(Body),
    Code.

json_map(Body) ->
    {ok, Map} = bus_protocol:decode_json(Body),
    Map.

post(Path, Headers, Body) -> request("POST", Path, Headers, Body).
get(Path, Headers) -> request("GET", Path, Headers, <<>>).

request(Method, Path, Headers, Body) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, port(),
        [binary, {active, false}, {packet, raw}], 5000),
    try
        Extra = case Body of
            <<>> -> [];
            _ -> [[<<"content-length: ">>, integer_to_binary(byte_size(Body)), <<"\r\n">>]]
        end,
        ok = gen_tcp:send(Sock, [Method, " ", Path, " HTTP/1.1\r\nHost: ", host(),
            "\r\nConnection: close\r\n",
            [[K, ": ", V, "\r\n"] || {K, V} <- Headers], Extra, "\r\n", Body]),
        Raw = recv_all(Sock, []),
        [Head | Rest] = binary:split(Raw, <<"\r\n\r\n">>),
        RespBody = case Rest of [] -> <<>>; [B] -> B end,
        [StatusLine | Lines] = binary:split(Head, <<"\r\n">>, [global]),
        [_, Status | _] = binary:split(StatusLine, <<" ">>, [global]),
        H = maps:from_list([begin
            case binary:split(Line, <<": ">>) of
                [K, V] -> {K, V};
                _ -> {Line, <<>>}
            end
        end || Line <- Lines, Line =/= <<>>]),
        {binary_to_integer(Status), H, strip_chunk(RespBody)}
    after gen_tcp:close(Sock) end.

recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_all(Sock, [Data | Acc]);
        {error, closed} -> iolist_to_binary(lists:reverse(Acc))
    end.

strip_chunk(Body) ->
    case binary:split(Body, <<"\r\n">>) of
        [Len, Rest] ->
            try binary_to_integer(Len, 16) of
                _ ->
                    case binary:split(Rest, <<"\r\n">>) of
                        [Content | _] -> Content;
                        _ -> Body
                    end
            catch _:_ -> Body end;
        _ -> Body
    end.
