-module(bus_dashboard_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1,
         static_security/1, read_security/1, noninterference/1,
         parser_boundaries/1, methods_and_paths/1]).

all() -> [static_security, read_security, noninterference, parser_boundaries, methods_and_paths].
init_per_suite(Config) -> bus_http_SUITE:init_per_suite(Config).
end_per_suite(Config) -> bus_http_SUITE:end_per_suite(Config).

static_security(Config) ->
    Host = authority(Config),
    lists:foreach(fun(Path) ->
        {200, Headers, Body} = get(Config, Path, Host, []),
        true = byte_size(Body) > 0,
        <<"no-store">> = maps:get(<<"cache-control">>, Headers),
        <<"no-referrer">> = maps:get(<<"referrer-policy">>, Headers),
        <<"nosniff">> = maps:get(<<"x-content-type-options">>, Headers),
        <<"DENY">> = maps:get(<<"x-frame-options">>, Headers),
        CSP = maps:get(<<"content-security-policy">>, Headers),
        true = nomatch =/= binary:match(CSP, <<"frame-ancestors 'none'">>),
        false = maps:is_key(<<"set-cookie">>, Headers),
        false = maps:is_key(<<"access-control-allow-origin">>, Headers),
        {403, _, _} = get(Config, Path, <<"attacker.test">>,
            [{<<"x-forwarded-host">>, Host}]),
        {403, _, _} = get(Config, Path, Host,
            [{<<"origin">>, <<"http://attacker.test">>}])
    end, ["/dashboard/", "/dashboard/dashboard.css", "/dashboard/dashboard.js",
          "/dashboard/protocol.js", "/dashboard/operator-session.js"]),
    lists:foreach(fun(Path) ->
        {302, H, <<>>} = get(Config, Path, Host, []),
        <<"/dashboard/">> = maps:get(<<"location">>, H)
    end, ["/", "/dashboard"]),
    {403, _, _} = get(Config, "/dashboard/", <<"localhost:1">>, []),
    {404, _, _} = get(Config, "/dashboard/unknown.js", Host, []),
    {200, _, _} = get(Config, "/dashboard/", Host,
        [{<<"origin">>, <<"http://", Host/binary>>}]).

read_security(Config) ->
    Host = authority(Config),
    Auth = [{<<"authorization">>, <<"Bearer ct-token">>}],
    lists:foreach(fun(H) ->
        {401, _, _} = get(Config, "/v1/agents", Host, H),
        {403, _, _} = get(Config, "/v1/agents", Host, Auth ++ H)
    end, [[{<<"origin">>, <<"null">>}],
          [{<<"origin">>, <<"http://attacker.test">>}],
          [{<<"sec-fetch-site">>, <<"cross-site">>}],
          [{<<"sec-fetch-site">>, <<"same-site">>}]]),
    {200, _, _} = get(Config, "/v1/agents", Host, Auth),
    {200, _, _} = get(Config, "/v1/agents", <<"native-alias.invalid">>, Auth),
    {200, _, _} = get(Config, "/v1/agents", Host,
        Auth ++ [{<<"origin">>, <<"http://", Host/binary>>}]),
    {401, _, _} = get(Config, "/v1/agents?token=ct-token", Host,
        [{<<"cookie">>, <<"token=ct-token">>}]).

noninterference(Config) ->
    %% Static reads do not even enter the state-owning store. Discovery reads
    %% leave mailbox/subscription ownership and queued mail unchanged.
    Id = <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>,
    {204, _} = bus_http_SUITE:put_agent(Config, Id, false),
    Other = <<"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb">>,
    {204, _} = bus_http_SUITE:put_agent(Config, Other, false),
    {ok, Ref} = bus_store:subscribe(Id, self()),
    {ok, _} = bus_store:accept_mail(#{
        <<"id">> => <<"33333333-3333-4333-8333-333333333333">>,
        <<"from">> => Other, <<"to">> => Id, <<"kind">> => <<"notice">>,
        <<"body">> => <<"pending dashboard fixture">>}),
    Before = sys:get_state(bus_store),
    {200, _, _} = get(Config, "/dashboard/", authority(Config), []),
    Before = sys:get_state(bus_store),
    {200, _, _} = get(Config, "/v1/agents", authority(Config),
        [{<<"authorization">>, <<"Bearer ct-token">>}]),
    {200, Body} = bus_http_SUITE:get(Config, "/v1/agents", bus_http_SUITE:auth()),
    {ok, #{<<"agents">> := Agents}} = bus_protocol:decode_json(Body),
    [Agent] = [A || A <- Agents, maps:get(<<"agentId">>, A) =:= Id],
    true = maps:get(<<"receiving">>, Agent),
    After = sys:get_state(bus_store),
    lists:foreach(fun(Key) ->
        Value = maps:get(Key, Before), Value = maps:get(Key, After)
    end, [model, subs]),
    bus_store:unsubscribe(Id, Ref).

parser_boundaries(Config) ->
    Host = authority(Config),
    Port = integer_to_binary(proplists:get_value(port, Config)),
    IPv6 = <<"[::1]:", Port/binary>>,
    {200, _, _} = get(Config, "/dashboard/", IPv6,
        [{<<"origin">>, <<"http://", IPv6/binary>>}]),
    Origin = <<"http://", Host/binary>>,
    Dotted = <<"localhost.:", Port/binary>>,
    lists:foreach(fun({H, O}) ->
        {403, _, <<"Forbidden">>} = get(Config, "/dashboard/", H, [{<<"origin">>, O}])
    end, [{Host, <<"http://", Dotted/binary>>}, {Dotted, Origin}]),
    lists:foreach(fun({Path, H, Extra, Expected}) ->
        {Status, _, Body} = get(Config, Path, H, Extra),
        Expected = Status,
        true = Body =:= <<>> orelse Body =:= <<"Forbidden">>
    end, [
        {"/dashboard/", <<"localhost">>, [], 403},
        {"/dashboard/", <<"localhost:1">>, [], 403},
        {"/dashboard/", Host, [{<<"host">>, Host}], 400},
        {"/dashboard/", Host, [{<<"host">>, <<"attacker.invalid">>}], 400},
        {"/dashboard/", Host, [{<<"origin">>, Origin}, {<<"origin">>, Origin}], 403},
        {"/dashboard/", Host, [{<<"origin">>, Origin}, {<<"origin">>, <<"null">>}], 403},
        {"/dashboard/", <<"[::1">>, [], 400},
        {"/dashboard/", <<"[nope]:", Port/binary>>, [], 400},
        {"/dashboard/", <<"user@", Host/binary>>, [], 400},
        {"/dashboard/", Host, [{<<"origin">>, <<"http://[::1">>}], 403},
        {"/dashboard/", Host, [{<<"origin">>, <<"http://user@", Host/binary>>}], 403},
        {<<"http://attacker.invalid/dashboard/">>, Host, [], 400},
        {<<"http://", Host/binary, "/dashboard/">>, <<"attacker.invalid">>, [], 400}
    ]),
    {200, _, _} = get(Config, <<"http://", Host/binary, "/dashboard/">>, Host, []).

methods_and_paths(Config) ->
    Host = authority(Config),
    {200, HeadHeaders, <<>>} = request(Config, "HEAD", "/dashboard/", Host, []),
    security_headers(HeadHeaders),
    lists:foreach(fun(Path) ->
        {302, H, <<>>} = get(Config, Path, Host, []), security_headers(H)
    end, ["/", "/dashboard"]),
    lists:foreach(fun(Method) ->
        {405, H, <<>>} = request(Config, Method, "/dashboard/", Host, []),
        <<"GET, HEAD">> = maps:get(<<"allow">>, H), security_headers(H)
    end, ["POST", "OPTIONS"]),
    {403, Denied, <<"Forbidden">>} = get(Config, "/dashboard/", <<"attacker.invalid">>, []),
    security_headers(Denied),
    lists:foreach(fun(Path) ->
        {404, _, Body} = get(Config, Path, Host, []),
        true = Body =:= <<>> orelse Body =:= <<"Not found">>
    end, ["/dashboard/../dashboard/", "/dashboard/%2e%2e/dashboard/",
          "/%64ashboard/", "/dashboard/../rebar.config", "/dashboard/index.html",
          "/dashboard/%2e%2e/src/bus_dashboard_h.erl"]),
    {404, NotFound, _} = get(Config, "/dashboard/../dashboard/", Host, []),
    security_headers(NotFound),
    lists:foreach(fun(Auth) ->
        {Status, H, _} = request(Config, "OPTIONS", "/v1/agents", Host, Auth ++ [
            {<<"origin">>, <<"http://attacker.invalid">>},
            {<<"access-control-request-method">>, <<"GET">>},
            {<<"access-control-request-headers">>, <<"authorization">>}]),
        Expected = case Auth of [] -> 401; _ -> 405 end,
        Expected = Status,
        false = maps:is_key(<<"access-control-allow-origin">>, H),
        false = maps:is_key(<<"access-control-allow-headers">>, H),
        <<"no-store">> = maps:get(<<"cache-control">>, H)
    end, [[], [{<<"authorization">>, <<"Bearer ct-token">>}]]).

security_headers(H) ->
    <<"no-store">> = maps:get(<<"cache-control">>, H),
    <<"no-referrer">> = maps:get(<<"referrer-policy">>, H),
    <<"nosniff">> = maps:get(<<"x-content-type-options">>, H),
    <<"DENY">> = maps:get(<<"x-frame-options">>, H),
    true = nomatch =/= binary:match(maps:get(<<"content-security-policy">>, H),
        <<"script-src 'self'">>),
    false = maps:is_key(<<"access-control-allow-origin">>, H).

authority(Config) ->
    iolist_to_binary(["localhost:", integer_to_list(proplists:get_value(port, Config))]).

get(Config, Path, Host, Headers) ->
    request(Config, "GET", Path, Host, Headers).

request(Config, Method, Path, Host, Headers) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, proplists:get_value(port, Config),
        [binary, {active, false}, {packet, raw}], 5000),
    try
        ok = gen_tcp:send(Sock, [Method, " ", Path, " HTTP/1.1\r\nHost: ", Host,
            "\r\nConnection: close\r\n",
            [[K, ": ", V, "\r\n"] || {K, V} <- Headers], "\r\n"]),
        Raw = receive_all(Sock, []),
        [Head, Body] = binary:split(Raw, <<"\r\n\r\n">>),
        [StatusLine | Lines] = binary:split(Head, <<"\r\n">>, [global]),
        [_, Status | _] = binary:split(StatusLine, <<" ">>, [global]),
        H = maps:from_list([begin
            [K, V] = binary:split(Line, <<": ">>), {K, V}
        end || Line <- Lines]),
        {binary_to_integer(Status), H, Body}
    after gen_tcp:close(Sock) end.

receive_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> receive_all(Sock, [Data | Acc]);
        {error, closed} -> iolist_to_binary(lists:reverse(Acc))
    end.
