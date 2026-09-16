-module(bus_operator_SUITE).
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2]).
-define(A, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(OP, <<"aaaaaaaa-bbbb-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(OPS, <<"22222222-2222-4222-8222-222222222222">>).
-export([disabled_keeps_legacy_token/1, loopback_session_and_presence/1,
         push_invalidation_streams/1, gate_loss_stays_503/1, announce_activity_and_search/1, observation_stream_delivers_and_invalidates/1, observer_capacity_preserves_core/1, slow_observer_does_not_block_core/1]).

all() -> [{group, disabled}, {group, enabled}, {group, gate_dead}].
groups() ->
    %% Gate is temporary and does not restart. Killing it must not share a
    %% group with later dashboard session/search/stream cases.
    [{disabled, [], [disabled_keeps_legacy_token]},
     {enabled, [], [loopback_session_and_presence, announce_activity_and_search, push_invalidation_streams, observation_stream_delivers_and_invalidates, observer_capacity_preserves_core, slow_observer_does_not_block_core]},
     {gate_dead, [], [gate_loss_stays_503]}].

init_per_suite(Config) ->
    Old = os:getenv("PI_AGENT_BUS_OPERATOR_ACCESS"),
    [{suite_old_access, Old} | bus_http_SUITE:init_per_suite(Config)].

end_per_suite(Config) ->
    restore_access(proplists:get_value(suite_old_access, Config, false)),
    bus_http_SUITE:end_per_suite(Config).

init_per_group(disabled, Config) ->
    Config;
init_per_group(Group, Config) when Group =:= enabled; Group =:= gate_dead ->
    Old = os:getenv("PI_AGENT_BUS_OPERATOR_ACCESS"),
    application:stop(pi_agent_bus),
    true = os:putenv("PI_AGENT_BUS_OPERATOR_ACCESS", "loopback"),
    {ok, _} = application:ensure_all_started(pi_agent_bus),
    true = is_pid(whereis(bus_operator_http_gate)),
    true = is_pid(whereis(bus_operator_activity)),
    true = is_pid(whereis(bus_operator_native)),
    [{port, ranch:get_port(bus_http)}, {old_operator_access, Old} | Config].

end_per_group(disabled, Config) ->
    Config;
end_per_group(_, Config) ->
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

announce_activity_and_search(Config) ->
    {204, _} = bus_http_SUITE:put_agent(Config, ?OP, false),
    Doc = announce_doc(),
    {200, RecBody} = operator_request("POST", Config, "/v1/operator/announce",
        [{<<"content-type">>, <<"application/json">>} | bus_http_SUITE:auth()],
        bus_protocol:encode_map(Doc)),
    {ok, Rec} = bus_protocol:decode_json(RecBody),
    Binding = maps:get(<<"bindingId">>, Rec),
    true = maps:is_key(<<"activeRunId">>, Rec),
    Act = #{<<"schemaVersion">> => 1, <<"agentId">> => ?OP, <<"bindingId">> => Binding,
            <<"runtimeGeneration">> => <<"1">>, <<"sessionGeneration">> => <<"1">>,
            <<"events">> => [], <<"dropped">> => <<"0">>},
    {403, Forbid} = operator_request("POST", Config, "/v1/operator/activity",
        [{<<"content-type">>, <<"application/json">>} | bus_http_SUITE:auth()],
        bus_protocol:encode_map(Act)),
    {ok, #{<<"error">> := #{<<"code">> := <<"forbidden">>}}} =
        bus_protocol:decode_json(Forbid),
    {200, Sess} = operator_post(Config, "/dashboard/api/v1/session", origin(Config), <<"{}">>),
    {ok, #{<<"session">> := Hex}} = bus_protocol:decode_json(Sess),
    H = [{<<"x-switchboard-session">>, Hex} | origin(Config)],
    {200, Search} = operator_get(Config, "/dashboard/api/v1/search?q=nope", H),
    {ok, Page} = bus_protocol:decode_json(Search),
    true = is_list(maps:get(<<"events">>, Page)),
    {400, _} = operator_get(Config, "/dashboard/api/v1/stream?x=1", H).

push_invalidation_streams(Config) ->
    {204, _} = bus_http_SUITE:put_agent(Config, ?A, false),
    {200, Sess} = operator_post(Config, "/dashboard/api/v1/session", origin(Config), <<"{}">>),
    {ok, #{<<"session">> := Hex}} = bus_protocol:decode_json(Sess),
    Port = proplists:get_value(port, Config),
    Open = fun(Path, Header) ->
        {ok, S} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active,false}, {packet,raw}], 2000),
        ok = gen_tcp:send(S, ["GET ", Path, " HTTP/1.1\r\nHost: localhost:", integer_to_list(Port),
            "\r\nX-Switchboard-Updates: 1\r\n", Header, "\r\nConnection: close\r\n\r\n"]), S
    end,
    Native = Open(["/v1/events?agentId=", ?A], "Authorization: Bearer ct-token"),
    Browser = Open("/dashboard/api/v1/stream", ["X-Switchboard-Session: ", Hex]),
    End = fun() -> erlang:monotonic_time(millisecond) + 3000 end,
    try
        _ = until_contains(Native, <<>>, <<"event: operator_update">>, End()),
        _ = until_contains(Browser, <<>>, <<"event: update">>, End()),
        bus_operator_updates:publish(?A), bus_operator_updates:publish(browser),
        _ = until_contains(Native, <<>>, <<"event: operator_update">>, End()),
        _ = until_contains(Browser, <<>>, <<"event: update">>, End()),
        {204, _} = operator_post(Config, "/dashboard/api/v1/disconnect",
            [{<<"x-switchboard-session">>, Hex} | origin(Config)], <<"{}">>),
        ok = until_closed(Browser, erlang:monotonic_time(millisecond) + 7000)
    after gen_tcp:close(Native), gen_tcp:close(Browser) end.

observation_stream_delivers_and_invalidates(Config) ->
    {200, Sess} = operator_post(Config, "/dashboard/api/v1/session", origin(Config), <<"{}">>),
    {ok, #{<<"session">> := Hex}} = bus_protocol:decode_json(Sess),
    Port = proplists:get_value(port, Config),
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active,false}, {packet,raw}], 2000),
    try
        Request = ["GET /dashboard/api/v1/stream HTTP/1.1\r\nHost: localhost:", integer_to_list(Port),
            "\r\nX-Switchboard-Session: ", Hex, "\r\nConnection: close\r\n\r\n"],
        ok = gen_tcp:send(Sock, Request),
        Data = until_contains(Sock, <<>>, <<"event: observation">>, erlang:monotonic_time(millisecond) + 2000),
        true = binary:match(Data, <<"200">>) =/= nomatch,
        {204, _} = operator_post(Config, "/dashboard/api/v1/disconnect",
            [{<<"x-switchboard-session">>, Hex} | origin(Config)], <<"{}">>),
        ok = until_closed(Sock, erlang:monotonic_time(millisecond) + 7000)
    after gen_tcp:close(Sock) end.

observer_capacity_preserves_core(Config) ->
    Port = proplists:get_value(port, Config),
    Bound = <<"http://localhost:", (integer_to_binary(Port))/binary>>,
    StartMemory = erlang:memory(total), StartProcesses = erlang:system_info(process_count),
    End = fun() -> erlang:monotonic_time(millisecond) + 5000 end,
    Nonces = [begin
        {ok, Nonce} = bus_operator_auth:bootstrap({127,0,1,N}, Bound, self(), End()),
        bus_operator_http:encode_nonce(Nonce)
    end || N <- lists:seq(1, 33)],
    Open = fun(Hex) ->
        {ok, Sock} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active,false}, {packet,raw}], 2000),
        ok = gen_tcp:send(Sock, ["GET /dashboard/api/v1/stream HTTP/1.1\r\nHost: localhost:", integer_to_list(Port),
            "\r\nX-Switchboard-Session: ", Hex, "\r\nConnection: close\r\n\r\n"]), Sock
    end,
    Sockets = [begin Sock = Open(Hex), _ = until_contains(Sock, <<>>, <<"event: observation">>, End()), Sock end || Hex <- lists:sublist(Nonces, 32)],
    try
        Full = Open(lists:last(Nonces)),
        try
            Data = until_contains(Full, <<>>, <<"\r\n\r\n">>, End()),
            true = binary:match(Data, <<"503">>) =/= nomatch
        after gen_tcp:close(Full) end,
        Duplicate = Open(hd(Nonces)),
        try
            DuplicateData = until_contains(Duplicate, <<>>, <<"\r\n\r\n">>, End()),
            true = binary:match(DuplicateData, <<"409">>) =/= nomatch
        after gen_tcp:close(Duplicate) end,
        {200, _} = operator_get(Config, "/health", []),
        ct:pal("operator_observers=32 memory_delta=~p process_delta=~p", [erlang:memory(total) - StartMemory,
            erlang:system_info(process_count) - StartProcesses])
    after lists:foreach(fun gen_tcp:close/1, Sockets) end,
    wait_observers_gone(End()).

slow_observer_does_not_block_core(Config) ->
    Port = proplists:get_value(port, Config),
    Bound = <<"http://localhost:", (integer_to_binary(Port))/binary>>,
    End = fun() -> erlang:monotonic_time(millisecond) + 5000 end,
    {ok, Nonce} = bus_operator_auth:bootstrap({127,0,2,1}, Bound, self(), End()),
    Hex = bus_operator_http:encode_nonce(Nonce),
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active,false}, {packet,raw}, {recbuf,1024}], 2000),
    Journal = whereis(bus_operator_journal), Ingress = bus_operator_ingress:tid(Journal),
    Body = binary:copy(<<"x">>, 16384),
    Event = #{<<"kind">> => <<"mail_accepted">>, <<"source">> => <<"relay_observed">>,
        <<"agentId">> => ?OP, <<"payload">> => #{<<"id">> => ?OP, <<"from">> => ?A,
        <<"to">> => ?OP, <<"kind">> => <<"notice">>, <<"acceptedAt">> => <<"1">>,
        <<"receiving">> => true, <<"bodyBytes">> => 16384, <<"body">> => Body}},
    try
        ok = gen_tcp:send(Sock, ["GET /dashboard/api/v1/stream HTTP/1.1\r\nHost: localhost:", integer_to_list(Port),
            "\r\nX-Switchboard-Session: ", Hex, "\r\nConnection: close\r\n\r\n"]),
        _ = until_contains(Sock, <<>>, <<"event: observation">>, End()),
        Start = erlang:monotonic_time(millisecond),
        lists:foreach(fun(_) ->
            lists:foreach(fun(_) ->
                case bus_operator_ingress:try_in(Ingress, Journal, Event, #{enroll_bodies => true}) of
                    {ok, wake} -> Journal ! drain;
                    _ -> ok
                end
            end, lists:seq(1, 32)),
            timer:sleep(10)
        end, lists:seq(1, 128)),
        {200, _} = operator_get(Config, "/health", []),
        {ok, _} = bus_store:list_agents(),
        wait_observers_gone(erlang:monotonic_time(millisecond) + 10000),
        ct:pal("slow_operator_observer_closed_ms=~p core_remained_available=true", [erlang:monotonic_time(millisecond) - Start])
    after gen_tcp:close(Sock) end.

wait_observers_gone(End) ->
    State = sys:get_state(bus_operator_journal),
    case map_size(maps:get(observers, State)) of
        0 -> 0 = maps:get(inflight, State), ok;
        _ -> true = erlang:monotonic_time(millisecond) < End, timer:sleep(10), wait_observers_gone(End)
    end.

until_contains(Sock, Buffer, Needle, End) ->
    case binary:match(Buffer, Needle) of
        nomatch ->
            true = byte_size(Buffer) < 1048576,
            {ok, Data} = gen_tcp:recv(Sock, 0, max(1, End - erlang:monotonic_time(millisecond))),
            until_contains(Sock, <<Buffer/binary, Data/binary>>, Needle, End);
        _ -> Buffer
    end.

until_closed(Sock, End) ->
    case gen_tcp:recv(Sock, 0, max(1, End - erlang:monotonic_time(millisecond))) of
        {error, closed} -> ok;
        {ok, _} -> until_closed(Sock, End);
        Other -> error({stream_not_closed, Other})
    end.

announce_doc() ->
    Work = #{<<"workId">> => null, <<"objective">> => null, <<"phase">> => null,
             <<"currentStep">> => null, <<"nextStep">> => null, <<"owner">> => null,
             <<"blocker">> => null, <<"project">> => null, <<"repository">> => null,
             <<"branch">> => null, <<"worktree">> => null, <<"parentWorkId">> => null,
             <<"delegatedWorkId">> => null, <<"evidence">> => []},
    #{<<"schemaVersion">> => 1, <<"agentId">> => ?OP, <<"sessionId">> => ?OPS,
      <<"runtimeGeneration">> => <<"1">>, <<"sessionGeneration">> => <<"1">>,
      <<"branchId">> => null, <<"registration">> => null,
      <<"permissionRevision">> => <<"0">>, <<"reportRevision">> => <<"1">>,
      <<"capabilities">> => [<<"work.report.v1">>],
      <<"permissions">> => #{
          <<"notice">> => false, <<"work">> => false, <<"guidance">> => false,
          <<"sessionRead">> => false, <<"label">> => false, <<"interrupt">> => false,
          <<"content">> => false, <<"workAssign">> => false, <<"history">> => false},
      <<"work">> => Work, <<"activeRunId">> => null}.

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
