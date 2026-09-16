-module(bus_operator_h_tests).
-include_lib("eunit/include/eunit.hrl").

stale_owner_slot_is_unavailable_test() ->
    Req = #{pid => self(), streamid => 777, method => <<"GET">>},
    _ = bus_operator_h:store_error(Req, stale_slot),
    receive
        {{_, 777}, {response, Status, Headers, Body}} ->
            ?assertEqual(503, Status),
            ?assertEqual(<<"1">>, maps:get(<<"retry-after">>, Headers)),
            ?assertEqual(<<"capacity">>, error_code(Body))
    after 1000 -> error(missing_response)
    end.

http_test_() ->
    {setup, fun setup/0, fun cleanup/1, {timeout, 30, {inorder, [
        fun disabled_mode/0,
        fun bootstrap_and_presence_roundtrip/0,
        fun events_access_and_reset/0,
        fun absent_origin_read_and_case/0,
        fun mutation_query_rejected_before_gate/0,
        fun origin_matrix/0,
        fun form_and_schema_rejected/0,
        fun wrong_authority/0,
        fun bad_nonce_and_no_ambient_auth/0,
        fun expiry_and_disconnect/0,
        fun http_quota_and_unavailable/0,
        fun stale_gate_after_partial_body/0,
        fun legacy_token_isolation/0,
        fun security_headers_and_no_cors/0,
        fun no_mailbox_interference/0,
        fun selected_runtime_work_read/0,
        fun fleet_work_snapshot_read/0
    ]}}}.

setup() ->
    application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(cowboy),
    assert_clean_fixture(),
    OldAccess = application:get_env(pi_agent_bus, operator_access),
    OldToken = application:get_env(pi_agent_bus, token),
    application:set_env(pi_agent_bus, operator_access, loopback),
    application:set_env(pi_agent_bus, token, bearer()),
    ?assertEqual(undefined, ets:info(owned())),
    ets:new(owned(), [named_table, public, set]),
    {ok, Auth} = bus_operator_auth:start_link(),
    unlink(Auth),
    ets:insert(owned(), {auth, Auth}),
    {ok, Gate} = bus_operator_http_gate:start_link(),
    unlink(Gate),
    ets:insert(owned(), {gate, Gate}),
    {ok, Store} = bus_store:start_link(),
    unlink(Store),
    ets:insert(owned(), {store, Store}),
    {ok, Native} = bus_operator_native:start_link(),
    unlink(Native),
    ets:insert(owned(), {native, Native}),
    {ok, _} = ranch:start_listener(listener(), ranch_tcp, trans_opts(),
        bus_connection, proto_opts()),
    Port = ranch:get_port(listener()),
    #{port => Port, auth => Auth, gate => Gate, store => Store,
      old_access => OldAccess, old_token => OldToken}.

cleanup(#{old_access := OldAccess, old_token := OldToken}) ->
    catch ranch:stop_listener(listener()),
    lists:foreach(fun(Key) ->
        case ets:info(owned()) of
            undefined -> ok;
            _ ->
                case ets:lookup(owned(), Key) of
                    [{Key, Pid}] -> stop_pid(Pid);
                    [] -> ok
                end
        end
    end, [auth, gate, native, store]),
    catch ets:delete(owned()),
    restore_env(operator_access, OldAccess),
    restore_env(token, OldToken),
    ok.

assert_clean_fixture() ->
    lists:foreach(fun(Name) ->
        ?assertEqual(undefined, whereis(Name))
    end, [bus_operator_auth, bus_operator_http_gate, bus_operator_native, bus_store]),
    ?assertEqual(undefined, listener_port()),
    ?assertEqual(undefined, ets:info(owned())).

owned() -> operator_http_eunit_owned.
listener() -> operator_http_eunit.
listener_port() ->
    try ranch:get_port(listener()) of
        Port when is_integer(Port) -> Port
    catch
        _:_ -> undefined
    end.

stop_pid(Pid) when is_pid(Pid) -> catch gen_server:stop(Pid);
stop_pid(_) -> ok.

restore_env(Key, undefined) -> application:unset_env(pi_agent_bus, Key);
restore_env(Key, {ok, Value}) -> application:set_env(pi_agent_bus, Key, Value).

replace_auth(Opts) ->
    Old = case ets:lookup(owned(), auth) of [{auth, Pid}] -> Pid; [] -> undefined end,
    stop_pid(Old),
    wait_unregistered(bus_operator_auth),
    {ok, Auth} = bus_operator_auth:start_link(Opts),
    unlink(Auth),
    ets:insert(owned(), {auth, Auth}),
    Auth.

replace_gate() ->
    Old = case ets:lookup(owned(), gate) of [{gate, Pid}] -> Pid; [] -> undefined end,
    stop_pid(Old),
    wait_unregistered(bus_operator_http_gate),
    {ok, Gate} = bus_operator_http_gate:start_link(),
    unlink(Gate),
    ets:insert(owned(), {gate, Gate}),
    Gate.

wait_unregistered(Name) ->
    Until = erlang:monotonic_time(millisecond) + 1000,
    wait_unregistered(Name, Until).
wait_unregistered(Name, Until) ->
    case whereis(Name) of
        undefined -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) < Until of
                true -> timer:sleep(1), wait_unregistered(Name, Until);
                false -> error({still_registered, Name})
            end
    end.

trans_opts() ->
    #{logger => bus_log, num_acceptors => 16, num_conns_sups => 1,
      max_connections => 8192, connection_type => supervisor,
      socket_opts => [{ip, {127, 0, 0, 1}}, {port, 0},
          {send_timeout, 5000}, {send_timeout_close, true}]}.

proto_opts() ->
    Dispatch = cowboy_router:compile([{'_', [
        {"/dashboard/api/v1/session", bus_operator_h, session},
        {"/dashboard/api/v1/disconnect", bus_operator_h, disconnect},
        {"/dashboard/api/v1/presence", bus_operator_h, presence},
        {"/dashboard/api/v1/events", bus_operator_h, events},
        {"/dashboard/api/v1/work", bus_operator_h, work_fleet},
        {"/dashboard/api/v1/work/:agent_id", bus_operator_h, work},
        {"/v1/agents", bus_http_h, list},
        {"/v1/agents/:agent_id", bus_http_h, agent},
        {"/v1/messages", bus_http_h, messages},
        {"/v1/events", bus_events_h, []}
    ]}]),
    #{logger => bus_log, env => #{dispatch => Dispatch}, protocols => [http],
      max_keepalive => 1, stream_handlers => [bus_deadline_stream, cowboy_stream_h],
      reset_idle_timeout_on_send => true, max_request_line_length => 8192,
      max_header_name_length => 256, max_header_value_length => 4096,
      max_headers => 32, request_timeout => 5000, shutdown_timeout => 1000,
      idle_timeout => 30000}.

port() -> ranch:get_port(listener()).
host() -> iolist_to_binary(["localhost:", integer_to_list(port())]).
origin() -> <<"http://", (host())/binary>>.
json() -> [{<<"content-type">>, <<"application/json">>}].

disabled_mode() ->
    application:set_env(pi_agent_bus, operator_access, disabled),
    {403, H, Body} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    application:set_env(pi_agent_bus, operator_access, loopback),
    ?assertEqual(<<"disabled">>, error_code(Body)),
    security(H).

bootstrap_and_presence_roundtrip() ->
    {200, H, Body} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    {ok, #{<<"session">> := Hex}} = bus_protocol:decode_json(Body),
    ?assertEqual(64, byte_size(Hex)),
    ?assertEqual(false, maps:is_key(<<"token">>, json_map(Body))),
    ?assertEqual(false, maps:is_key(<<"set-cookie">>, H)),
    {200, _, Presence} = get("/dashboard/api/v1/presence", session_h(Hex) ++ origin_h()),
    {ok, #{<<"agents">> := _}} = bus_protocol:decode_json(Presence),
    security(H).

events_access_and_reset() ->
    {200, _, Bootstrap} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    Hex = maps:get(<<"session">>, json_map(Bootstrap)),
    {401, _, _} = get("/dashboard/api/v1/events", []),
    {503, _, _} = get("/dashboard/api/v1/events", session_h(Hex)),
    {ok, Journal} = bus_operator_journal:start_link(),
    unlink(Journal),
    try
        {200, Headers, Body} = get("/dashboard/api/v1/events", session_h(Hex)),
        security(Headers),
        Page = json_map(Body),
        ?assertEqual([], maps:get(<<"events">>, Page)),
        ?assertEqual(<<"empty">>, maps:get(<<"coverage">>, Page)),
        Epoch = maps:get(<<"epoch">>, Page),
        {400, _, _} = get("/dashboard/api/v1/events?cursor=bad", session_h(Hex)),
        {400, _, _} = get("/dashboard/api/v1/events?x=1", session_h(Hex)),
        {400, _, _} = get("/dashboard/api/v1/events?cursor=" ++ lists:duplicate(129, $a), session_h(Hex)),
        {403, _, _} = get("/dashboard/api/v1/events", session_h(Hex) ++
            [{<<"origin">>, <<"http://attacker.invalid">>}]),
        Other = <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>,
        ?assertNotEqual(Other, Epoch),
        Cursor = base64:encode(<<Other/binary, ":0">>, #{mode => urlsafe, padding => false}),
        {409, _, Gap} = get("/dashboard/api/v1/events?cursor=" ++ binary_to_list(Cursor), session_h(Hex)),
        ?assertEqual(<<"epoch_reset">>, error_code(Gap)),
        {204, _, _} = post("/dashboard/api/v1/disconnect", json() ++ origin_h() ++ session_h(Hex), <<"{}">>),
        {401, _, _} = get("/dashboard/api/v1/events", session_h(Hex))
    after stop_pid(Journal) end.

absent_origin_read_and_case() ->
    Port = integer_to_binary(port()),
    Mixed = <<"http://LocalHost:", Port/binary>>,
    {200, _, Body} = post("/dashboard/api/v1/session",
        json() ++ [{<<"origin">>, Mixed}], <<"{}">>),
    Hex = maps:get(<<"session">>, json_map(Body)),
    {200, _, Presence} = get("/dashboard/api/v1/presence", session_h(Hex)),
    {ok, #{<<"agents">> := _}} = bus_protocol:decode_json(Presence),
    {204, _, _} = post("/dashboard/api/v1/disconnect",
        json() ++ origin_h() ++ session_h(Hex), <<"{}">>),
    {401, _, _} = get("/dashboard/api/v1/presence", session_h(Hex)).

mutation_query_rejected_before_gate() ->
    {400, _, Query} = post("/dashboard/api/v1/session?x=1", json() ++ origin_h(), <<"{}">>),
    ?assertEqual(<<"invalid_schema">>, error_code(Query)),
    {200, _, Body} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    Hex = maps:get(<<"session">>, json_map(Body)),
    {400, _, Disc} = post("/dashboard/api/v1/disconnect?x=1",
        json() ++ origin_h() ++ session_h(Hex), <<"{}">>),
    ?assertEqual(<<"invalid_schema">>, error_code(Disc)),
    Conns = [spawn(fun() -> receive stop -> ok end end)
             || _ <- lists:seq(1, bus_operator_admission:limit())],
    lists:foreach(fun(C) ->
        {ok, _} = bus_operator_http_gate:acquire(C, bootstrap)
    end, Conns),
    {400, _, Still} = post("/dashboard/api/v1/session?x=1", json() ++ origin_h(), <<"{}">>),
    ?assertEqual(<<"invalid_schema">>, error_code(Still)),
    {503, _, Full} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    ?assertEqual(<<"capacity">>, error_code(Full)),
    [exit(C, kill) || C <- Conns],
    await_gate_free().

origin_matrix() ->
    lists:foreach(fun(Headers) ->
        {403, H, _} = post("/dashboard/api/v1/session", json() ++ Headers, <<"{}">>),
        security(H)
    end, [[], [{<<"origin">>, <<"null">>}],
          [{<<"origin">>, <<"http://attacker.invalid">>}],
          origin_h() ++ [{<<"origin">>, <<"null">>}],
          origin_h() ++ [{<<"sec-fetch-site">>, <<"cross-site">>}]]),
    {200, _, _} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>).

form_and_schema_rejected() ->
    Form = [{<<"content-type">>, <<"application/x-www-form-urlencoded">>}] ++ origin_h(),
    {400, _, Body} = post("/dashboard/api/v1/session", Form, <<"a=b">>),
    ?assertEqual(<<"invalid_schema">>, error_code(Body)),
    {400, _, Extra} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{\"x\":1}">>),
    ?assertEqual(<<"invalid_schema">>, error_code(Extra)),
    {413, _, _} = post("/dashboard/api/v1/session", json() ++ origin_h(),
        binary:copy(<<"a">>, 300)).

wrong_authority() ->
    {403, H, _} = request("POST", "/dashboard/api/v1/session", <<"attacker.invalid">>,
        json() ++ [{<<"origin">>, <<"http://attacker.invalid">>}], <<"{}">>),
    security(H).

bad_nonce_and_no_ambient_auth() ->
    {200, _, Body} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    Hex = maps:get(<<"session">>, json_map(Body)),
    {401, _, _} = get("/dashboard/api/v1/presence", origin_h()),
    {401, _, _} = get("/dashboard/api/v1/presence",
        origin_h() ++ [{<<"cookie">>, <<"X-Switchboard-Session=", Hex/binary>>}]),
    {401, _, _} = get("/dashboard/api/v1/presence?session=" ++ binary_to_list(Hex), origin_h()),
    {401, _, _} = get("/dashboard/api/v1/presence",
        origin_h() ++ [{<<"x-switchboard-session">>, <<"not-a-nonce">>}]),
    {401, _, _} = get("/dashboard/api/v1/presence",
        origin_h() ++ [{<<"x-switchboard-session">>, Hex},
                       {<<"x-switchboard-session">>, Hex}]).

expiry_and_disconnect() ->
    Auth = replace_auth(#{ttl_ms => 40}),
    {200, _, Body} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    Hex = maps:get(<<"session">>, json_map(Body)),
    {204, _, _} = post("/dashboard/api/v1/disconnect",
        json() ++ origin_h() ++ session_h(Hex), <<"{}">>),
    {401, _, _} = get("/dashboard/api/v1/presence", session_h(Hex) ++ origin_h()),
    {200, _, Body2} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    Hex2 = maps:get(<<"session">>, json_map(Body2)),
    timer:sleep(50),
    Auth ! expire,
    sys:get_state(Auth),
    {401, _, _} = get("/dashboard/api/v1/presence", session_h(Hex2) ++ origin_h()).

http_quota_and_unavailable() ->
    Conns = [spawn(fun() -> receive stop -> ok end end)
             || _ <- lists:seq(1, bus_operator_admission:limit())],
    lists:foreach(fun(C) ->
        {ok, _} = bus_operator_http_gate:acquire(C, bootstrap)
    end, Conns),
    {503, _, Body} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    ?assertEqual(<<"capacity">>, error_code(Body)),
    [exit(C, kill) || C <- Conns],
    await_gate_free(),
    [{auth, Old}] = ets:lookup(owned(), auth),
    stop_pid(Old),
    ets:delete(owned(), auth),
    wait_unregistered(bus_operator_auth),
    ?assertEqual(undefined, whereis(bus_operator_auth)),
    {503, _, Down} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    ?assertEqual(<<"capacity">>, error_code(Down)),
    replace_auth(#{}).

stale_gate_after_partial_body() ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, port(),
        [binary, {active, false}, {packet, raw}], 5000),
    try
        Head = ["POST /dashboard/api/v1/session HTTP/1.1\r\nHost: ", host(),
            "\r\nConnection: close\r\ncontent-type: application/json\r\n",
            "content-length: 2\r\norigin: ", origin(), "\r\n\r\n"],
        ok = gen_tcp:send(Sock, Head),
        await_gate_occupied(1),
        replace_gate(),
        ?assertEqual(0, bus_operator_http_gate:occupied()),
        ok = gen_tcp:send(Sock, <<"{}">>),
        Raw = recv_all(Sock, []),
        {Status, _, Body} = decode_http(Raw),
        ?assertEqual(503, Status),
        ?assertEqual(<<"capacity">>, error_code(Body)),
        ?assertEqual(false, maps:is_key(<<"session">>, json_map_soft(Body))),
        {200, _, Ok} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
        ?assertMatch(#{<<"session">> := <<_:64/binary>>}, json_map(Ok))
    after
        gen_tcp:close(Sock)
    end.

legacy_token_isolation() ->
    Bearer = [{<<"authorization">>, <<"Bearer ", (bearer())/binary>>}],
    {401, _, _} = get("/dashboard/api/v1/presence", origin_h() ++ Bearer),
    {200, _, Body} = post("/dashboard/api/v1/session",
        json() ++ origin_h() ++ Bearer, <<"{}">>),
    Map = json_map(Body),
    Hex = maps:get(<<"session">>, Map),
    ?assertEqual(false, maps:is_key(<<"token">>, Map)),
    ?assertEqual(nomatch, binary:match(term_to_binary(Map), bearer())),
    {401, _, _} = get("/v1/agents", session_h(Hex) ++ origin_h()),
    {401, _, _} = get("/v1/agents",
        [{<<"cookie">>, <<"X-Switchboard-Session=", Hex/binary>>}]),
    {401, _, _} = put_legacy(agent_path(), session_h(Hex) ++ json(),
        bus_protocol:encode_map(agent(<<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>))),
    {200, _, Listed} = get("/v1/agents", Bearer),
    {ok, #{<<"agents">> := _}} = bus_protocol:decode_json(Listed),
    {204, _, <<>>} = put_legacy(agent_path(), Bearer ++ json(),
        bus_protocol:encode_map(agent(<<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>))),
    {200, _, After} = get("/v1/agents", Bearer),
    {ok, #{<<"agents">> := Agents}} = bus_protocol:decode_json(After),
    ?assert(lists:any(fun(A) ->
        maps:get(<<"agentId">>, A) =:= <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>
    end, Agents)).

security_headers_and_no_cors() ->
    {405, H, _} = request("OPTIONS", "/dashboard/api/v1/session", host(),
        origin_h() ++ [{<<"access-control-request-method">>, <<"POST">>}], <<>>),
    ?assertEqual(false, maps:is_key(<<"access-control-allow-origin">>, H)),
    security(H).

no_mailbox_interference() ->
    Id = <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>,
    Other = <<"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb">>,
    ok = bus_store:put_agent(agent(Id)),
    ok = bus_store:put_agent(agent(Other)),
    {ok, Ref} = bus_store:subscribe(Id, self()),
    {ok, _} = bus_store:accept_mail(#{
        <<"id">> => <<"33333333-3333-4333-8333-333333333333">>,
        <<"from">> => Other, <<"to">> => Id, <<"kind">> => <<"notice">>,
        <<"body">> => <<"operator presence fixture">>}),
    Before = sys:get_state(bus_store),
    {200, _, Body} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    Hex = maps:get(<<"session">>, json_map(Body)),
    {200, _, _} = get("/dashboard/api/v1/presence", session_h(Hex) ++ origin_h()),
    After = sys:get_state(bus_store),
    lists:foreach(fun(Key) ->
        ?assertEqual(maps:get(Key, Before), maps:get(Key, After))
    end, [model, subs]),
    bus_store:unsubscribe(Id, Ref).

selected_runtime_work_read() ->
    Id = <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>,
    Missing = <<"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb">>,
    Path = "/dashboard/api/v1/work/" ++ binary_to_list(Id),
    MissingPath = "/dashboard/api/v1/work/" ++ binary_to_list(Missing),
    {200, _, Body} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    Hex = maps:get(<<"session">>, json_map(Body)),
    Bearer = [{<<"authorization">>, <<"Bearer ", (bearer())/binary>>}],
    {401, _, _} = get(Path, origin_h()),
    {401, _, _} = get(Path, origin_h() ++ Bearer),
    {403, _, _} = get(Path, session_h(Hex) ++
        [{<<"origin">>, <<"http://attacker.invalid">>}]),
    {400, _, _} = get("/dashboard/api/v1/work/invalid", session_h(Hex) ++ origin_h()),
    {400, _, _} = get(Path ++ "?x=1", session_h(Hex) ++ origin_h()),
    {405, _, _} = post(Path, json() ++ origin_h() ++ session_h(Hex), <<"{}">>),
    ok = bus_store:put_agent(agent(Id)),
    {404, _, Unreported} = get(Path, session_h(Hex) ++ origin_h()),
    ?assertEqual(<<"not_found">>, error_code(Unreported)),
    {404, _, Unknown} = get(MissingPath, session_h(Hex) ++ origin_h()),
    ?assertEqual(<<"not_found">>, error_code(Unknown)),
    {ok, _} = bus_operator_native:announce(self(), announce_doc(Id, populated_work()),
        erlang:monotonic_time(millisecond) + 5000),
    Before = sys:get_state(bus_store),
    {200, H, WorkBody} = get(Path, session_h(Hex) ++ origin_h()),
    security(H),
    Page = json_map(WorkBody),
    ?assertEqual(true, maps:is_key(<<"binding">>, Page)),
    ?assertEqual(true, maps:is_key(<<"work">>, Page)),
    ?assertEqual(true, maps:is_key(<<"permissions">>, Page)),
    Work = maps:get(<<"work">>, Page),
    Binding = maps:get(<<"binding">>, Page),
    ?assertEqual(<<"implementing">>, maps:get(<<"phase">>, Work)),
    ?assertEqual(<<"Ship the operator work snapshot codec">>, maps:get(<<"objective">>, Work)),
    ?assertEqual(Id, maps:get(<<"workId">>, Work)),
    ?assertEqual([<<"work.report.v1">>], maps:get(<<"capabilities">>, Binding)),
    After = sys:get_state(bus_store),
    lists:foreach(fun(Key) ->
        ?assertEqual(maps:get(Key, Before), maps:get(Key, After))
    end, [model, subs]),
    {ok, _} = bus_operator_native:announce(self(), announce_doc(Id, null_work(), <<"2">>),
        erlang:monotonic_time(millisecond) + 5000),
    {200, _, NullBody} = get(Path, session_h(Hex) ++ origin_h()),
    NullWork = maps:get(<<"work">>, json_map(NullBody)),
    ?assertEqual(null, maps:get(<<"phase">>, NullWork)),
    ?assertEqual(null, maps:get(<<"objective">>, NullWork)),
    ok = bus_store:delete_agent(Id),
    {404, _, Stale} = get(Path, session_h(Hex) ++ origin_h()),
    ?assertEqual(<<"not_found">>, error_code(Stale)),
    stop_pid(whereis(bus_operator_native)),
    ets:delete(owned(), native),
    wait_unregistered(bus_operator_native),
    {503, _, Down} = get(Path, session_h(Hex) ++ origin_h()),
    ?assertEqual(<<"capacity">>, error_code(Down)),
    {ok, Native} = bus_operator_native:start_link(),
    unlink(Native),
    ets:insert(owned(), {native, Native}),
    {204, _, _} = post("/dashboard/api/v1/disconnect",
        json() ++ origin_h() ++ session_h(Hex), <<"{}">>),
    {401, _, _} = get(Path, session_h(Hex) ++ origin_h()).

fleet_work_snapshot_read() ->
    Id = <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>,
    Fleet = "/dashboard/api/v1/work",
    One = "/dashboard/api/v1/work/" ++ binary_to_list(Id),
    {200, _, Body} = post("/dashboard/api/v1/session", json() ++ origin_h(), <<"{}">>),
    Hex = maps:get(<<"session">>, json_map(Body)),
    Bearer = [{<<"authorization">>, <<"Bearer ", (bearer())/binary>>}],
    {401, _, _} = get(Fleet, origin_h()),
    {401, _, _} = get(Fleet, origin_h() ++ Bearer),
    {403, _, _} = get(Fleet, session_h(Hex) ++
        [{<<"origin">>, <<"http://attacker.invalid">>}]),
    {400, _, _} = get(Fleet ++ "?x=1", session_h(Hex) ++ origin_h()),
    {200, H, EmptyB} = get(Fleet, session_h(Hex) ++ origin_h()),
    security(H),
    Empty = json_map(EmptyB),
    lists:foreach(fun(K) -> ?assertEqual(true, maps:is_key(K, Empty)) end,
        [<<"epoch">>, <<"snapshotId">>, <<"revision">>, <<"capturedAt">>,
         <<"page">>, <<"total">>, <<"snapshots">>, <<"nextCursor">>]),
    ?assertEqual([], maps:get(<<"snapshots">>, Empty)),
    ?assertEqual(0, maps:get(<<"total">>, Empty)),
    ?assertEqual(null, maps:get(<<"nextCursor">>, Empty)),
    ok = bus_store:put_agent(agent(Id)),
    {ok, _} = bus_operator_native:announce(self(), announce_doc(Id, populated_work()),
        erlang:monotonic_time(millisecond) + 5000),
    Before = sys:get_state(bus_store),
    {200, _, PageB} = get(Fleet, session_h(Hex) ++ origin_h()),
    Page = json_map(PageB),
    [Snap] = maps:get(<<"snapshots">>, Page),
    ?assertEqual(true, maps:is_key(<<"binding">>, Snap)),
    ?assertEqual(true, maps:is_key(<<"work">>, Snap)),
    ?assertEqual(true, maps:is_key(<<"permissions">>, Snap)),
    ?assertEqual(<<"implementing">>, maps:get(<<"phase">>, maps:get(<<"work">>, Snap))),
    After = sys:get_state(bus_store),
    lists:foreach(fun(Key) ->
        ?assertEqual(maps:get(Key, Before), maps:get(Key, After))
    end, [model, subs]),
    {200, _, OneB} = get(One, session_h(Hex) ++ origin_h()),
    ?assertEqual(<<"implementing">>, maps:get(<<"phase">>, maps:get(<<"work">>, json_map(OneB)))),
    {204, _, _} = post("/dashboard/api/v1/disconnect",
        json() ++ origin_h() ++ session_h(Hex), <<"{}">>),
    {401, _, _} = get(Fleet, session_h(Hex) ++ origin_h()).

origin_h() -> [{<<"origin">>, origin()}].
session_h(Hex) -> [{<<"x-switchboard-session">>, Hex}].

security(H) ->
    ?assertEqual(<<"no-store">>, maps:get(<<"cache-control">>, H)),
    ?assertEqual(<<"no-referrer">>, maps:get(<<"referrer-policy">>, H)),
    ?assertEqual(<<"nosniff">>, maps:get(<<"x-content-type-options">>, H)),
    ?assertEqual(<<"DENY">>, maps:get(<<"x-frame-options">>, H)),
    ?assertNotEqual(nomatch, binary:match(maps:get(<<"content-security-policy">>, H),
        <<"frame-ancestors 'none'">>)),
    ?assertEqual(false, maps:is_key(<<"access-control-allow-origin">>, H)),
    ?assertEqual(false, maps:is_key(<<"set-cookie">>, H)).

error_code(Body) ->
    {ok, #{<<"error">> := #{<<"code">> := Code}}} = bus_protocol:decode_json(Body),
    Code.

json_map(Body) ->
    {ok, Map} = bus_protocol:decode_json(Body),
    Map.

json_map_soft(Body) ->
    case bus_protocol:decode_json(Body) of
        {ok, Map} when is_map(Map) -> Map;
        _ -> #{}
    end.

await_gate_free() -> await_gate_occupied(0).

await_gate_occupied(N) ->
    Until = erlang:monotonic_time(millisecond) + 2000,
    await_gate_occupied(N, Until).
await_gate_occupied(N, Until) ->
    case bus_operator_http_gate:occupied() of
        N -> ok;
        Other ->
            case erlang:monotonic_time(millisecond) < Until of
                true -> timer:sleep(1), await_gate_occupied(N, Until);
                false -> error({gate_occupied, Other, expected, N})
            end
    end.

agent(Id) ->
    #{<<"agentId">> => Id, <<"sessionId">> => Id, <<"host">> => <<"test">>,
      <<"cwd">> => <<"/tmp">>, <<"sessionName">> => <<"test">>, <<"label">> => <<"test">>,
      <<"model">> => null, <<"status">> => <<"idle">>, <<"pid">> => 1,
      <<"acceptsControl">> => false}.

announce_doc(Id, Work) ->
    announce_doc(Id, Work, <<"1">>).
announce_doc(Id, Work, Report) ->
    #{<<"schemaVersion">> => 1, <<"agentId">> => Id, <<"sessionId">> => Id,
      <<"runtimeGeneration">> => <<"1">>, <<"sessionGeneration">> => <<"1">>,
      <<"branchId">> => null, <<"registration">> => null,
      <<"permissionRevision">> => <<"0">>, <<"reportRevision">> => Report,
      <<"capabilities">> => [<<"work.report.v1">>],
      <<"permissions">> => #{
          <<"notice">> => false, <<"work">> => false, <<"guidance">> => false,
          <<"sessionRead">> => false, <<"label">> => false, <<"interrupt">> => false,
          <<"content">> => false, <<"workAssign">> => false, <<"history">> => false},
      <<"work">> => Work, <<"activeRunId">> => null}.

null_work() -> work_fixture(<<"allNull">>).
populated_work() -> work_fixture(<<"populated">>).
work_fixture(Key) ->
    {ok, Bin} = file:read_file("../tests/fixtures/operator-work.json"),
    maps:get(Key, json:decode(Bin)).

bearer() -> <<"ct-token">>.
agent_path() -> "/v1/agents/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa".
post(Path, Headers, Body) -> request("POST", Path, host(), Headers, Body).
get(Path, Headers) -> request("GET", Path, host(), Headers, <<>>).
put_legacy(Path, Headers, Body) -> request("PUT", Path, host(), Headers, Body).

request(Method, Path, Host, Headers, Body) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, port(),
        [binary, {active, false}, {packet, raw}], 5000),
    try
        Extra = case Body of
            <<>> -> [];
            _ -> [[<<"content-length: ">>, integer_to_binary(byte_size(Body)), <<"\r\n">>]]
        end,
        ok = gen_tcp:send(Sock, [Method, " ", Path, " HTTP/1.1\r\nHost: ", Host,
            "\r\nConnection: close\r\n",
            [[K, ": ", V, "\r\n"] || {K, V} <- Headers], Extra, "\r\n", Body]),
        Raw = recv_all(Sock, []),
        decode_http(Raw)
    after gen_tcp:close(Sock) end.

decode_http(Raw) ->
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
    {binary_to_integer(Status), H, strip_chunk(RespBody)}.

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
