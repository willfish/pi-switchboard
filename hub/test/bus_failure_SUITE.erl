-module(bus_failure_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([listener_crash_preserves_store/1]).

-define(A, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(S1, <<"11111111-1111-4111-8111-111111111111">>).
-define(TOKEN, <<"ct-token">>).

all() ->
    [listener_crash_preserves_store].

init_per_suite(Config) ->
    case whereis(bus_store) of
        undefined ->
            bus_http_SUITE:init_per_suite(Config);
        _ ->
            [{port, ranch:get_port(bus_http)} | Config]
    end.

end_per_suite(Config) ->
    bus_http_SUITE:end_per_suite(Config).

listener_crash_preserves_store(Config) ->
    {204, _} = bus_http_SUITE:put_agent(Config, ?A, false),
    {200, Before} = bus_http_SUITE:get(Config, "/v1/agents", bus_http_SUITE:auth()),
    {ok, #{<<"agents">> := Agents0}} = bus_protocol:decode_json(Before),
    true = Agents0 =/= [],
    Store = whereis(bus_store),
    Children = supervisor:which_children(bus_sup),
    [{ListenerId, Listener}] = [
        {Id, P} || {Id, P, _, _} <- Children, Id =/= bus_store, is_pid(P)
    ],
    Monitor = monitor(process, Listener),
    exit(Listener, kill),
    receive {'DOWN', Monitor, process, Listener, killed} -> ok
    after 1000 -> error(listener_did_not_exit)
    end,
    ok = wait_replacement(ListenerId, Listener, 40),
    Store = whereis(bus_store),
    Port = ranch:get_port(bus_http),
    Config1 = [{port, Port} | Config],
    {200, After} = bus_http_SUITE:get(Config1, "/v1/agents", bus_http_SUITE:auth()),
    {ok, #{<<"agents">> := Agents1}} = bus_protocol:decode_json(After),
    Agents0 = Agents1.

wait_replacement(_Id, _Old, 0) ->
    {error, timeout};
wait_replacement(Id, Old, N) ->
    case lists:keyfind(Id, 1, supervisor:which_children(bus_sup)) of
        {Id, New, _, _} when is_pid(New), New =/= Old ->
            Port = ranch:get_port(bus_http),
            true = is_integer(Port) andalso Port > 0,
            ok;
        _ ->
            timer:sleep(25),
            wait_replacement(Id, Old, N - 1)
    end.
