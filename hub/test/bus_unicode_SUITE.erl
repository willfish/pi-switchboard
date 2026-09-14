-module(bus_unicode_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1, single_line_metadata/1]).

all() -> [single_line_metadata].
init_per_suite(Config) -> bus_http_SUITE:init_per_suite(Config).
end_per_suite(Config) -> bus_http_SUITE:end_per_suite(Config).

single_line_metadata(Config) ->
    Id = <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>,
    {204, _} = bus_http_SUITE:put_agent(Config, Id, false),
    {ok, [Public]} = bus_store:list_agents(),
    Base = maps:without([<<"updatedAt">>, <<"receiving">>], Public),
    {ok, _} = bus_protocol:decode_register(Base),
    lists:foreach(fun({C, Escape}) ->
        Value = <<"a", C/utf8, "b">>,
        lists:foreach(fun(Agent) ->
            Literal = bus_protocol:encode_map(Agent),
            Escaped = binary:replace(Literal, <<C/utf8>>, Escape, [global]),
            lists:foreach(fun(Json) ->
                400 = put(Config, Id, Json)
            end, [Literal, Escaped])
        end, [Base#{<<"label">> := Value}, Base#{<<"sessionName">> := Value},
              Base#{<<"model">> := #{<<"provider">> => Value, <<"id">> => <<"m">>}},
              Base#{<<"model">> := #{<<"provider">> => <<"p">>, <<"id">> => Value}}])
    end, [{16#2028, <<"\\u2028">>}, {16#2029, <<"\\u2029">>}]).

put(Config, Id, Json) ->
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, proplists:get_value(port, Config),
        [binary, {active,false}, {packet,http_bin}]),
    try
        ok = gen_tcp:send(Socket, ["PUT /v1/agents/", Id, " HTTP/1.1\r\n",
            "Host: localhost\r\nAuthorization: Bearer ct-token\r\n",
            "Content-Type: application/json\r\nConnection: close\r\nContent-Length: ",
            integer_to_binary(byte_size(Json)), "\r\n\r\n", Json]),
        {ok, {http_response, _, Status, _}} = gen_tcp:recv(Socket, 0, 5000),
        Status
    after gen_tcp:close(Socket) end.
