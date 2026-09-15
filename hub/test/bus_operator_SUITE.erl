-module(bus_operator_SUITE).
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2]).
-export([disabled_keeps_legacy_token/1, loopback_session_and_presence/1,
         gate_loss_stays_503/1]).

all() -> [{group, disabled}, {group, enabled}].
groups() ->
    [{disabled, [], [disabled_keeps_legacy_token]},
     {enabled, [], [loopback_session_and_presence, gate_loss_stays_503]}].

init_per_suite(Config) ->
    Old = os:getenv("PI_AGENT_BUS_OPERATOR_ACCESS"),
    [{suite_old_access, Old} | bus_http_SUITE:init_per_suite(Config)].

end_per_suite(Config) ->
    restore_access(proplists:get_value(suite_old_access, Config, false)),
    bus_http_SUITE:end_per_suite(Config).

init_per_group(disabled, Config) ->
    Config;
init_per_group(enabled, Config) ->
    Old = os:getenv("PI_AGENT_BUS_OPERATOR_ACCESS"),
    application:stop(pi_agent_bus),
    true = os:putenv("PI_AGENT_BUS_OPERATOR_ACCESS", "loopback"),
    {ok, _} = application:ensure_all_started(pi_agent_bus),
    [{port, ranch:get_port(bus_http)}, {old_operator_access, Old} | Config].

end_per_group(disabled, Config) ->
    Config;
end_per_group(enabled, Config) ->
    restore_access(proplists:get_value(old_operator_access, Config, false)),
    Config.

restore_access(false) -> os:unsetenv("PI_AGENT_BUS_OPERATOR_ACCESS");
restore_access(Value) -> os:putenv("PI_AGENT_BUS_OPERATOR_ACCESS", Value).

disabled_keeps_legacy_token(Config) ->
    Ids = lists:sort([Id || {Id, _, _, _} <- supervisor:which_children(bus_sup)]),
    Ids = lists:sort([bus_store, {ranch_embedded_sup, bus_http}]),
    undefined = whereis(bus_operator_sup),
    {403, Body} = operator_post(Config, "/dashboard/api/v1/session", [], <<"{}">>),
    {ok, #{<<"error">> := #{<<"code">> := <<"disabled">>}}} = bus_protocol:decode_json(Body),
    {401, _} = bus_http_SUITE:get(Config, "/v1/agents", []),
    {200, _} = bus_http_SUITE:get(Config, "/v1/agents", bus_http_SUITE:auth()).

loopback_session_and_presence(Config) ->
    true = is_pid(whereis(bus_operator_sup)),
    {200, Body} = operator_post(Config, "/dashboard/api/v1/session", origin(Config), <<"{}">>),
    {ok, #{<<"session">> := Hex}} = bus_protocol:decode_json(Body),
    true = byte_size(Hex) =:= 64,
    {200, Presence} = operator_get(Config, "/dashboard/api/v1/presence",
        [{<<"x-switchboard-session">>, Hex} | origin(Config)]),
    {ok, #{<<"agents">> := _}} = bus_protocol:decode_json(Presence).

gate_loss_stays_503(Config) ->
    Gate = whereis(bus_operator_http_gate),
    true = is_pid(Gate),
    exit(Gate, kill),
    ok = wait_gone(bus_operator_http_gate, 40),
    {503, Body} = operator_post(Config, "/dashboard/api/v1/session", origin(Config), <<"{}">>),
    {ok, #{<<"error">> := #{<<"code">> := <<"capacity">>}}} = bus_protocol:decode_json(Body),
    undefined = whereis(bus_operator_http_gate),
    {200, _} = bus_http_SUITE:get(Config, "/v1/agents", bus_http_SUITE:auth()).

wait_gone(_Name, 0) -> {error, timeout};
wait_gone(Name, N) ->
    case whereis(Name) of
        undefined -> ok;
        _ -> timer:sleep(25), wait_gone(Name, N - 1)
    end.

origin(Config) ->
    Port = integer_to_binary(proplists:get_value(port, Config)),
    [{<<"origin">>, <<"http://localhost:", Port/binary>>}].

operator_post(Config, Path, Headers, Body) ->
    operator_request("POST", Config, Path,
        [{<<"content-type">>, <<"application/json">>} | Headers], Body).

operator_get(Config, Path, Headers) ->
    operator_request("GET", Config, Path, Headers, <<>>).

operator_request(Method, Config, Path, Headers, Body) ->
    Port = proplists:get_value(port, Config),
    Host = iolist_to_binary(["localhost:", integer_to_list(Port)]),
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port,
        [binary, {active, false}, {packet, raw}], 5000),
    Extra = case Body of
        <<>> -> [];
        _ -> ["content-length: ", integer_to_binary(byte_size(Body)), "\r\n"]
    end,
    ok = gen_tcp:send(Sock, [Method, " ", Path, " HTTP/1.1\r\nHost: ", Host,
        "\r\nConnection: close\r\n",
        [[K, ": ", V, "\r\n"] || {K, V} <- Headers], Extra, "\r\n", Body]),
    Raw = recv_all(Sock, []),
    gen_tcp:close(Sock),
    [Head | Rest] = binary:split(Raw, <<"\r\n\r\n">>),
    RespBody = case Rest of [] -> <<>>; [B] -> B end,
    [StatusLine | _] = binary:split(Head, <<"\r\n">>, [global]),
    [_, Status | _] = binary:split(StatusLine, <<" ">>, [global]),
    {binary_to_integer(Status), strip_chunk(RespBody)}.

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
