-module(bus_http_SUITE).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    put_agent/3,
    get/3,
    auth/0
]).
-export([
    health_ok/1,
    auth_required/1,
    invalid_delete_id/1,
    register_and_list/1,
    message_sse/1,
    self_send/1,
    control_rejected/1,
    duplicate_post/1,
    global_queue_budget/1,
    store_restart_loses_state/1,
    channel_roundtrip/1
]).

-define(A, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(B, <<"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb">>).
-define(S1, <<"11111111-1111-4111-8111-111111111111">>).
-define(S2, <<"22222222-2222-4222-8222-222222222222">>).
-define(MID, <<"33333333-3333-4333-8333-333333333333">>).
-define(TOKEN, <<"ct-token">>).

all() ->
    [
        health_ok,
        auth_required,
        invalid_delete_id,
        register_and_list,
        message_sse,
        self_send,
        control_rejected,
        duplicate_post,
        global_queue_budget,
        store_restart_loses_state,
        channel_roundtrip
    ].

init_per_suite(Config) ->
    Name = "pi-agent-bus-ct-" ++ os:getpid() ++ "-" ++
        integer_to_list(erlang:unique_integer([positive, monotonic])),
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"), Name),
    ok = file:make_dir(Dir),
    TokenFile = filename:join(Dir, "token"),
    Fixture = [{token_file, TokenFile}, {fixture_dir, Dir} | Config],
    try
        ok = file:change_mode(Dir, 8#700),
        ok = file:write_file(TokenFile, ?TOKEN, [exclusive]),
        ok = file:change_mode(TokenFile, 8#600),
        true = os:putenv("PI_AGENT_BUS_TOKEN_FILE", TokenFile),
        true = os:putenv("PI_AGENT_BUS_BIND_HOST", "127.0.0.1"),
        true = os:putenv("PI_AGENT_BUS_PORT", "0"),
        {ok, _} = application:ensure_all_started(pi_agent_bus),
        Port = ranch:get_port(bus_http),
        [{port, Port} | Fixture]
    catch Class:Reason:Stack ->
        end_per_suite(Fixture),
        erlang:raise(Class, Reason, Stack)
    end.

end_per_suite(Config) ->
    application:stop(pi_agent_bus),
    application:stop(cowboy),
    application:stop(ranch),
    file:delete(proplists:get_value(token_file, Config)),
    file:del_dir(proplists:get_value(fixture_dir, Config)),
    Config.

health_ok(Config) ->
    {200, Body} = get(Config, "/health", []),
    {ok, #{<<"ok">> := true}} = bus_protocol:decode_json(Body).

auth_required(Config) ->
    Routes = [
        {get, "/v1/agents", <<>>},
        {put, "/v1/agents/" ++ binary_to_list(?A), bus_protocol:encode_map(agent(?A, false))},
        {delete, "/v1/agents/" ++ binary_to_list(?A), <<>>},
        {post, "/v1/messages", bus_protocol:encode_map(notice(?A, ?B, ?MID, <<"auth fixture">>))},
        {get, "/v1/events?agentId=" ++ binary_to_list(?B), <<>>}
    ],
    lists:foreach(fun(Headers) ->
        lists:foreach(fun({Method, Path, Body}) ->
            {401, _} = request(Method, Config, Path, Headers ++ content(), Body)
        end, Routes)
    end, [[], [{"Authorization", "Bearer wrong"}],
          [{"Authorization", <<"Bearer ", 255>>}]]).

invalid_delete_id(Config) ->
    lists:foreach(fun(Id) ->
        Path = "/v1/agents/" ++ Id,
        {400, Body} = request(delete, Config, Path, auth(), <<>>),
        {ok, #{<<"error">> := #{<<"code">> := <<"invalid_schema">>}}} =
            bus_protocol:decode_json(Body),
        {401, _} = request(delete, Config, Path, [], <<>>)
    end, ["invalid", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaag", "%ff"]).

register_and_list(Config) ->
    {204, _} = put_agent(Config, ?A, false),
    {200, Body} = get(Config, "/v1/agents", auth()),
    {ok, #{<<"agents">> := Agents}} = bus_protocol:decode_json(Body),
    true = lists:any(fun(A) -> maps:get(<<"agentId">>, A) =:= ?A end, Agents).

message_sse(Config) ->
    {204, _} = put_agent(Config, ?A, false),
    {204, _} = put_agent(Config, ?B, false),
    {ok, Sock} = sse_open(Config, ?B),
    try
        Deadline = erlang:monotonic_time(millisecond) + 5000,
        Reader = bus_sse_client:open(Sock, Deadline),
        Presence = bus_sse_client:until(Sock, Reader,
            fun(S) -> bus_sse_client:has_event(S, <<"presence_snapshot">>) end, Deadline),
        [#{<<"agents">> := [_, _], <<"final">> := true} | _] =
            bus_sse_client:json_events(Presence, <<"presence_snapshot">>),
        {202, Acc} = post_notice(Config, ?A, ?B, ?MID, <<"hello from ct">>),
        {ok, #{<<"state">> := <<"accepted">>}} = bus_protocol:decode_json(Acc),
        Messages = bus_sse_client:until(Sock, Presence,
            fun(S) -> bus_sse_client:has_message(S, ?MID) end, Deadline),
        [Msg] = bus_sse_client:json_events(Messages, <<"message">>),
        <<"hello from ct">> = maps:get(<<"body">>, Msg),
        <<"notice">> = maps:get(<<"kind">>, Msg)
    after
        gen_tcp:close(Sock)
    end.

self_send(Config) ->
    {204, _} = put_agent(Config, ?A, false),
    {400, Body} = post_notice(Config, ?A, ?A, <<"55555555-5555-4555-8555-555555555555">>, <<"loop">>),
    {ok, #{<<"error">> := #{<<"code">> := <<"self_send">>}}} = bus_protocol:decode_json(Body).

control_rejected(Config) ->
    {204, _} = put_agent(Config, ?A, false),
    {204, _} = put_agent(Config, ?B, false),
    Msg = (notice(?A, ?B, <<"66666666-6666-4666-8666-666666666666">>, <<"do it">>))#{
        <<"kind">> => <<"prompt">>
    },
    {403, Body} = post(Config, "/v1/messages", bus_protocol:encode_map(Msg)),
    {ok, #{<<"error">> := #{<<"code">> := <<"control_disabled">>}}} = bus_protocol:decode_json(Body).

duplicate_post(Config) ->
    {204, _} = put_agent(Config, ?A, false),
    {204, _} = put_agent(Config, ?B, false),
    Id = <<"44444444-4444-4444-8444-444444444444">>,
    {202, First} = post_notice(Config, ?A, ?B, Id, <<"same">>),
    {202, Second} = post_notice(Config, ?A, ?B, Id, <<"same">>),
    {ok, A1} = bus_protocol:decode_json(First),
    {ok, A2} = bus_protocol:decode_json(Second),
    A1 = A2,
    {409, _} = post_notice(Config, ?A, ?B, Id, <<"different">>).

global_queue_budget(Config) ->
    %% Small internal fixture limit exercises the production HTTP/store path
    %% without allocating gigabytes or adding a runtime quota interface.
    ok = bus_store:delete_agent(?A),
    ok = bus_store:delete_agent(?B),
    {204, _} = put_agent(Config, ?A, false),
    {204, _} = put_agent(Config, ?B, false),
    Id = <<"77777777-7777-4777-8777-777777777777">>,
    NextId = <<"88888888-8888-4888-8888-888888888888">>,
    {202, Accepted} = post_notice(Config, ?A, ?B, Id, <<"budget">>),
    #{model := Model} = sys:get_state(bus_store),
    Bytes = maps:get(queued_bytes, Model),
    true = Bytes > 0,
    sys:replace_state(bus_store, fun(State) ->
        M = maps:get(model, State),
        State#{model := M#{queue_byte_limit := Bytes}}
    end),
    try
        %% Duplicate acceptance remains valid even at the exact byte ceiling.
        {202, Accepted} = post_notice(Config, ?A, ?B, Id, <<"budget">>),
        {503, Rejected} = post_notice(Config, ?A, ?B, NextId, <<"budget">>),
        {ok, #{<<"error">> := #{<<"code">> := <<"capacity">>}}} =
            bus_protocol:decode_json(Rejected),
        #{model := Full} = sys:get_state(bus_store),
        Bytes = maps:get(queued_bytes, Full),
        ok = bus_store:delete_agent(?B),
        #{model := Empty} = sys:get_state(bus_store),
        0 = maps:get(queued_bytes, Empty),
        {204, _} = put_agent(Config, ?B, false),
        {202, _} = post_notice(Config, ?A, ?B, NextId, <<"budget">>)
    after
        sys:replace_state(bus_store, fun(State) ->
            M = maps:get(model, State),
            State#{model := M#{queue_byte_limit := 5_000_000_000}}
        end)
    end.

store_restart_loses_state(Config) ->
    {204, _} = put_agent(Config, ?A, false),
    Old = whereis(bus_store),
    true = is_pid(Old),
    exit(Old, kill),
    ok = wait_new_store(Old, 50),
    ok = wait_listener(50),
    Config1 = [{port, ranch:get_port(bus_http)} | Config],
    {200, Body} = get(Config1, "/v1/agents", auth()),
    {ok, #{<<"agents">> := []}} = bus_protocol:decode_json(Body).

channel_roundtrip(Config) ->
    {204, _} = put_agent(Config, ?A, false),
    {200, Listed} = get(Config, "/v1/channels", auth()),
    {ok, #{<<"channels">> := Channels}} = bus_protocol:decode_json(Listed),
    true = lists:any(fun(#{<<"name">> := Name}) -> Name =:= <<"general">> end, Channels),
    Body = bus_protocol:encode_map(#{<<"id">> => ?MID, <<"from">> => ?A, <<"body">> => <<"checking in">>}),
    {202, Posted} = post(Config, "/v1/channels/general/messages", Body),
    {ok, First} = bus_protocol:decode_json(Posted),
    #{<<"state">> := <<"accepted">>, <<"sequence">> := <<"1">>} = First,
    {202, Again} = post(Config, "/v1/channels/general/messages", Body),
    {ok, First} = bus_protocol:decode_json(Again),
    {200, Page} = get(Config, "/v1/channels/general/messages", auth()),
    {ok, #{<<"window">> := <<"recent">>, <<"messages">> := [Message]}} = bus_protocol:decode_json(Page),
    <<"checking in">> = maps:get(<<"body">>, Message),
    Status = bus_protocol:encode_map(#{<<"from">> => ?A, <<"summary">> => <<"checking in">>,
        <<"label">> => <<"ct-agent">>, <<"project">> => <<"suite">>, <<"area">> => <<"general">>}),
    {200, _} = put(Config, "/v1/channels/general/status", Status),
    {200, _} = put(Config, "/v1/channels/general/status", Status),
    {200, After} = get(Config, "/v1/channels/general/messages?after=1", auth()),
    {ok, #{<<"messages">> := Tail, <<"caughtUp">> := true}} = bus_protocol:decode_json(After),
    true = length(Tail) >= 1,
    {401, _} = get(Config, "/v1/channels", []).

put_agent(Config, Id, Control) ->
    put(
        Config,
        "/v1/agents/" ++ binary_to_list(Id),
        bus_protocol:encode_map(agent(Id, Control))
    ).

post_notice(Config, From, To, Id, Body) ->
    post(Config, "/v1/messages", bus_protocol:encode_map(notice(From, To, Id, Body))).

get(Config, Path, Headers) ->
    request(get, Config, Path, Headers, []).

put(Config, Path, Body) ->
    request(put, Config, Path, auth() ++ content(), Body).

post(Config, Path, Body) ->
    request(post, Config, Path, auth() ++ content(), Body).

request(Method, Config, Path, Headers, Body0) ->
    Port = proplists:get_value(port, Config),
    Body =
        case Body0 of
            [] -> <<>>;
            Bin when is_binary(Bin) -> Bin;
            List when is_list(List) -> iolist_to_binary(List)
        end,
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1},
        Port,
        [binary, {active, false}, {packet, http_bin}]
    ),
    MethodBin = method_bin(Method),
    PathBin = iolist_to_binary(Path),
    CL = integer_to_binary(byte_size(Body)),
    Head = [
        MethodBin,
        <<" ">>,
        PathBin,
        <<" HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n">>,
        [[H, ": ", V, "\r\n"] || {H, V} <- Headers],
        case Body of
            <<>> -> <<>>;
            _ -> [<<"Content-Length: ">>, CL, <<"\r\n">>]
        end,
        <<"\r\n">>
    ],
    ok = gen_tcp:send(Sock, Head),
    case Body of
        <<>> -> ok;
        _ ->
            inet:setopts(Sock, [{packet, raw}]),
            ok = gen_tcp:send(Sock, Body),
            inet:setopts(Sock, [{packet, http_bin}])
    end,
    {ok, {http_response, _, Status, _}} = gen_tcp:recv(Sock, 0, 5000),
    Len = recv_headers(Sock, undefined),
    Resp = recv_body(Sock, Len),
    gen_tcp:close(Sock),
    {Status, Resp}.

method_bin(get) -> <<"GET">>;
method_bin(put) -> <<"PUT">>;
method_bin(post) -> <<"POST">>;
method_bin(delete) -> <<"DELETE">>.

recv_headers(Sock, Len) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, http_eoh} ->
            Len;
        {ok, {http_header, _, 'Content-Length', _, Value}} ->
            recv_headers(Sock, list_to_integer(binary_to_list(iolist_to_binary(Value))));
        {ok, {http_header, _, _, _, _}} ->
            recv_headers(Sock, Len);
        {ok, _} ->
            recv_headers(Sock, Len)
    end.

recv_body(_Sock, undefined) ->
    <<>>;
recv_body(_Sock, 0) ->
    <<>>;
recv_body(Sock, Len) ->
    inet:setopts(Sock, [{packet, raw}]),
    {ok, Body} = gen_tcp:recv(Sock, Len, 5000),
    Body.

auth() ->
    [{"Authorization", "Bearer " ++ binary_to_list(?TOKEN)}].

content() ->
    [{"Content-Type", "application/json"}].

agent(Id, Control) ->
    #{
        <<"agentId">> => Id,
        <<"sessionId">> =>
            case Id of
                ?A -> ?S1;
                _ -> ?S2
            end,
        <<"host">> => <<"foundation">>,
        <<"cwd">> => <<"/tmp">>,
        <<"sessionName">> => <<"ct">>,
        <<"label">> => <<"ct-agent">>,
        <<"model">> => null,
        <<"status">> => <<"idle">>,
        <<"pid">> => 1,
        <<"acceptsControl">> => Control
    }.

notice(From, To, Id, Body) ->
    #{
        <<"id">> => Id,
        <<"from">> => From,
        <<"to">> => To,
        <<"kind">> => <<"notice">>,
        <<"body">> => Body
    }.

sse_open(Config, AgentId) ->
    Port = proplists:get_value(port, Config),
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1},
        Port,
        [binary, {active, false}, {packet, raw}, {nodelay, true}]
    ),
    Req = [
        <<"GET /v1/events?agentId=">>,
        AgentId,
        <<" HTTP/1.1\r\n">>,
        <<"Host: 127.0.0.1\r\n">>,
        <<"Authorization: Bearer ">>,
        ?TOKEN,
        <<"\r\n">>,
        <<"Accept: text/event-stream\r\n">>,
        <<"\r\n">>
    ],
    ok = gen_tcp:send(Sock, Req),
    {ok, Sock}.

wait_new_store(_Old, 0) ->
    {error, timeout};
wait_new_store(Old, N) ->
    case whereis(bus_store) of
        Pid when is_pid(Pid), Pid =/= Old ->
            ok;
        _ ->
            timer:sleep(20),
            wait_new_store(Old, N - 1)
    end.

wait_listener(0) ->
    {error, timeout};
wait_listener(N) ->
    try ranch:get_port(bus_http) of
        Port when is_integer(Port), Port > 0 ->
            ok
    catch
        _:_ ->
            timer:sleep(20),
            wait_listener(N - 1)
    end.
