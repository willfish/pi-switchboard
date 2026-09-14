-module(bus_pressure_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1, suspended_http_capacity/1]).

all() -> [suspended_http_capacity].
init_per_suite(Config) -> bus_http_SUITE:init_per_suite(Config).
end_per_suite(Config) -> bus_http_SUITE:end_per_suite(Config).

suspended_http_capacity(Config) ->
    P = whereis(bus_store),
    ok = bus_pressure_tests:suspend(P),
    try
        Callers = bus_pressure_tests:fill(4096, fun bus_store:list_agents/1),
        Results = bus_pressure_tests:collect(Callers),
        true = lists:all(fun(R) -> R =:= {error, timeout} end, Results),
        4096 = bus_pressure_tests:queue_len(P),
        {memory, Before} = process_info(P, memory),
        Start = erlang:monotonic_time(millisecond),
        lists:foreach(fun(_) ->
            {503, Body} = bus_http_SUITE:get(Config, "/v1/agents", bus_http_SUITE:auth()),
            {ok, #{<<"error">> := #{<<"code">> := <<"capacity">>}}} = bus_protocol:decode_json(Body),
            {200, Health} = bus_http_SUITE:get(Config, "/health", []),
            {ok, #{<<"ok">> := true}} = bus_protocol:decode_json(Health)
        end, lists:seq(1, 20)),
        Elapsed = erlang:monotonic_time(millisecond) - Start,
        true = Elapsed < 3000,
        4096 = bus_pressure_tests:queue_len(P),
        {memory, After} = process_info(P, memory),
        Before = After,
        ct:pal("suspended HTTP: 20 capacity503 + 20 unauth health200 in ~pms; queue=4096 memory_before=~p memory_after=~p",
               [Elapsed, Before, After])
    after
        ok = sys:resume(P)
    end,
    #{model := #{queued_bytes := 0}} = sys:get_state(P),
    {200, _} = bus_http_SUITE:get(Config, "/v1/agents", bus_http_SUITE:auth()).
