-module(bus_wire_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2,
    body_limit/1, outgoing_limit/1, request_limit/1, dedup_capacity/1,
    request_line_boundary/1, header_name_boundary/1, header_value_boundary/1,
    header_count_boundary/1, incomplete_parser_limits/1, fragmented_parser_limits/1, split_crlf_limits/1,
    duplicate_content_length/1, transfer_encoding/1, content_length_required/1,
    duplicate_count_complete/1, duplicate_count_fragmented/1,
    cookie_count_complete/1, cookie_count_fragmented/1,
    duplicate_value_complete/1, duplicate_value_fragmented/1,
    cookie_value_complete/1, cookie_value_fragmented/1]).

all() -> [body_limit, outgoing_limit, request_limit, dedup_capacity,
    request_line_boundary, header_name_boundary, header_value_boundary,
    header_count_boundary, incomplete_parser_limits, fragmented_parser_limits, split_crlf_limits,
    duplicate_content_length, transfer_encoding, content_length_required,
    duplicate_count_complete, duplicate_count_fragmented,
    cookie_count_complete, cookie_count_fragmented,
    duplicate_value_complete, duplicate_value_fragmented,
    cookie_value_complete, cookie_value_fragmented].
init_per_suite(Config) -> bus_http_SUITE:init_per_suite(Config).
end_per_suite(Config) -> bus_http_SUITE:end_per_suite(Config).
init_per_testcase(_, Config) ->
    sys:replace_state(bus_store, fun(State) -> State#{model := bus_model:new()} end),
    Config.

body_limit(Config) ->
    Msg = register_pair(Config),
    Good = Msg#{<<"body">> => binary:copy(<<16#1f642/utf8>>, 4096)},
    {202, _} = post(Config, Good),
    Bad = Good#{<<"body">> => <<(maps:get(<<"body">>, Good))/binary, "x">>},
    {413, Body} = post(Config, Bad),
    error_code(<<"payload_too_large">>, Body).

outgoing_limit(Config) ->
    Msg = register_pair(Config),
    Sender = (fixture("register-valid.json"))#{
        <<"host">> => binary:copy(<<92>>, 255),
        <<"label">> => binary:copy(<<16#1f642/utf8>>, 200)},
    {204, _} = put_agent(Config, Sender),
    Large = Msg#{<<"body">> => binary:copy(<<0>>, 5300)},
    true = byte_size(bus_protocol:encode_map(Large)) < 32768,
    {413, Body} = post(Config, Large),
    error_code(<<"payload_too_large">>, Body),
    #{model := Rejected} = sys:get_state(bus_store),
    0 = maps:get(queued_bytes, Rejected),
    0 = map_size(maps:get(dedup, Rejected)),
    %% Rejection must not consume the id or enqueue a partial entry.
    {202, _} = post(Config, Msg).

request_limit(Config) ->
    Msg = register_pair(Config),
    Json = bus_protocol:encode_map(Msg),
    Exact = <<Json/binary, (binary:copy(<<" ">>, 32768 - byte_size(Json)))/binary>>,
    {202, _} = request(Config, <<"POST">>, <<"/v1/messages">>, Exact),
    {413, Body} = request(Config, <<"POST">>, <<"/v1/messages">>, <<Exact/binary, " ">>),
    error_code(<<"payload_too_large">>, Body).

dedup_capacity(Config) ->
    Msg = register_pair(Config),
    {202, First} = post(Config, Msg),
    sys:replace_state(bus_store, fun(State) ->
        Model = maps:get(model, State),
        Dedup = maps:get(dedup, Model),
        [Record] = maps:values(Dedup),
        Filled = lists:foldl(fun(N, Acc) ->
            Acc#{{maps:get(<<"from">>, Msg), integer_to_binary(N)} => Record}
        end, Dedup, lists:seq(1, 4095)),
        State#{model := Model#{dedup := Filled}}
    end),
    {202, First} = post(Config, Msg),
    {409, _} = post(Config, Msg#{<<"body">> => <<"changed">>}),
    {503, Body} = post(Config, Msg#{<<"id">> => <<"99999999-9999-4999-8999-999999999999">>}),
    error_code(<<"dedup_full">>, Body).

request_line_boundary(Config) ->
    lists:foreach(fun(N) ->
        200 = raw_status(Config, [request_line(N), "\r\n", base_headers(), "\r\n"])
    end, [8191, 8192]),
    414 = raw_status(Config, [request_line(8193), "\r\n", base_headers(), "\r\n"]).

request_line(N) ->
    Prefix = <<"GET /health?padding=">>,
    Suffix = <<" HTTP/1.1">>,
    <<Prefix/binary, (binary:copy(<<"x">>, N - byte_size(Prefix) - byte_size(Suffix)))/binary,
        Suffix/binary>>.

header_name_boundary(Config) ->
    lists:foreach(fun(N) ->
        200 = raw_status(Config, health_request([[binary:copy(<<"x">>, N), ": ok\r\n"]]))
    end, [255, 256]),
    431 = raw_status(Config, health_request([[binary:copy(<<"x">>, 257), ": ok\r\n"]])).

header_value_boundary(Config) ->
    lists:foreach(fun(N) ->
        200 = raw_status(Config, health_request([["x-padding: ", binary:copy(<<"x">>, N), "\r\n"]]))
    end, [4095, 4096]),
    431 = raw_status(Config, health_request([["x-padding: ", binary:copy(<<"x">>, 4097), "\r\n"]])).

header_count_boundary(Config) ->
    %% Host and Connection are the two base headers. Use distinct names to
    %% exercise the configured total rather than duplicate-header merging.
    lists:foreach(fun(N) ->
        200 = raw_status(Config, health_request(numbered_headers(N - 2)))
    end, [31, 32]),
    431 = raw_status(Config, health_request(numbered_headers(31))).

numbered_headers(N) ->
    [["x-", integer_to_binary(I), ": ok\r\n"] || I <- lists:seq(1, N)].

incomplete_parser_limits(Config) ->
    %% No terminator is sent: rejection must come from the size limit,
    %% not from a malformed completed request or the request timeout.
    414 = raw_status(Config, request_line(8193)),
    431 = raw_status(Config, ["GET /health HTTP/1.1\r\n", base_headers(),
        binary:copy(<<"x">>, 257)]),
    431 = raw_status(Config, ["GET /health HTTP/1.1\r\n", base_headers(),
        "x-padding: ", binary:copy(<<"x">>, 4097)]).

fragmented_parser_limits(Config) ->
    %% Complete the token in a later read.
    lists:foreach(fun({N, Status}) ->
        Line = request_line(N),
        PrefixSize = N - 1,
        <<Prefix:PrefixSize/binary, Last/binary>> = Line,
        Status = fragmented_status(Config, Prefix,
            [Last, "\r\n", base_headers(), "\r\n"])
    end, [{8192, 200}, {8193, 414}]),
    lists:foreach(fun({N, Status}) ->
        Status = fragmented_status(Config,
            ["GET /health HTTP/1.1\r\n", base_headers(), binary:copy(<<"x">>, N - 1)],
            "x: ok\r\n\r\n")
    end, [{256, 200}, {257, 431}]),
    lists:foreach(fun({N, Status}) ->
        Status = fragmented_status(Config,
            ["GET /health HTTP/1.1\r\n", base_headers(), "x-padding: ",
                binary:copy(<<"x">>, N - 1)], "x\r\n\r\n")
    end, [{4096, 200}, {4097, 431}]).

split_crlf_limits(Config) ->
    200 = fragmented_status(Config, [request_line(8192), "\r"],
        ["\n", base_headers(), "\r\n"]),
    200 = fragmented_status(Config,
        ["GET /health HTTP/1.1\r\n", base_headers(), "x-padding: ",
            binary:copy(<<"x">>, 4096), "\r"], "\n\r\n"),
    414 = fragmented_status(Config, [request_line(8192), "\r"], "x"),
    431 = fragmented_status(Config,
        ["GET /health HTTP/1.1\r\n", base_headers(), "x-padding: ",
            binary:copy(<<"x">>, 4096), "\r"], "x").

fragmented_status(Config, Prefix, Suffix) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, proplists:get_value(port, Config),
        [binary, {active, false}, {packet, http_bin}]),
    try
        ok = gen_tcp:send(Sock, Prefix),
        {error, timeout} = gen_tcp:recv(Sock, 0, 50),
        ok = gen_tcp:send(Sock, Suffix),
        {ok, {http_response, _, Status, _}} = gen_tcp:recv(Sock, 0, 2000),
        Status
    after gen_tcp:close(Sock) end.

duplicate_count_complete(C) -> duplicate_count(C, <<"x-repeat">>, complete).
duplicate_count_fragmented(C) -> duplicate_count(C, <<"x-repeat">>, fragmented).
cookie_count_complete(C) -> duplicate_count(C, <<"cookie">>, complete).
cookie_count_fragmented(C) -> duplicate_count(C, <<"cookie">>, fragmented).
duplicate_value_complete(C) -> duplicate_value(C, <<"x-repeat">>, complete).
duplicate_value_fragmented(C) -> duplicate_value(C, <<"x-repeat">>, fragmented).
cookie_value_complete(C) -> duplicate_value(C, <<"cookie">>, complete).
cookie_value_fragmented(C) -> duplicate_value(C, <<"cookie">>, fragmented).

duplicate_count(Config, Name, Mode) ->
    lists:foreach(fun({Count, Expected}) ->
        %% Include Host and Connection. A duplicate is still a header line.
        Prefix = ["GET /health HTTP/1.1\r\n", base_headers(),
            lists:duplicate(Count - 3, [Name, ": a=b\r\n"])],
        %% Overflow must also reject before the header block is finished.
        Ends = case Expected of 200 -> ["\r\n"]; 431 -> ["\r\n", <<>>] end,
        lists:foreach(fun(End) ->
            Expected = duplicate_status(Config, Mode, Prefix, [Name, ": a=b\r\n", End])
        end, Ends)
    end, [{31, 200}, {32, 200}, {33, 431}]).

duplicate_value(Config, Name, Mode) ->
    %% Exercise both one merge and repeated growth up to the header-count cap.
    lists:foreach(fun(Sizes) ->
        MergedSize = lists:sum(Sizes) + 2 * (length(Sizes) - 1),
        lists:foreach(fun({Length, Expected}) ->
            %% Comma-space and Cookie semicolon-space both cost 2 bytes.
            Prefix = ["GET /health HTTP/1.1\r\n", base_headers(),
                [[Name, ": ", binary:copy(<<"x">>, N), "\r\n"] || N <- Sizes]],
            Ends = case Expected of 200 -> ["\r\n"]; 431 -> ["\r\n", <<>>] end,
            lists:foreach(fun(End) ->
                Expected = duplicate_status(Config, Mode, Prefix,
                    [Name, ": ", binary:copy(<<"y">>, Length - MergedSize - 2), "\r\n", End])
            end, Ends)
        end, [{4095, 200}, {4096, 200}, {4097, 431}])
    end, [[2047], lists:duplicate(29, 134)]).

duplicate_status(Config, complete, Prefix, Suffix) ->
    raw_status(Config, [Prefix, Suffix]);
duplicate_status(Config, fragmented, Prefix, Suffix) ->
    fragmented_status(Config, Prefix, Suffix).

duplicate_content_length(Config) ->
    lists:foreach(fun(Lengths) ->
        400 = raw_status(Config, ["POST /v1/messages HTTP/1.1\r\n", base_headers(),
            auth_header(), Lengths, "\r\n{}"])
    end, ["Content-Length: 2\r\nContent-Length: 3\r\n",
          "Content-Length: 2\r\ncOnTeNt-LeNgTh: 2\r\n",
          "Content-Length: 2, 3\r\n"]).

transfer_encoding(Config) ->
    lists:foreach(fun(Headers) ->
        400 = raw_status(Config, ["POST /v1/messages HTTP/1.1\r\n", base_headers(),
            auth_header(), Headers, "\r\n0\r\n\r\n"])
    end, ["Transfer-Encoding: gzip\r\n",
          "Transfer-Encoding: gzip, chunked\r\n",
          "Transfer-Encoding: chunked\r\nContent-Length: 5\r\n",
          %% Cowboy supports chunked, but this API requires Content-Length.
          "Transfer-Encoding: chunked\r\n"]).

content_length_required(Config) ->
    Agent = fixture("register-valid.json"),
    AgentPath = <<"/v1/agents/", (maps:get(<<"agentId">>, Agent))/binary>>,
    lists:foreach(fun({Method, Path}) ->
        400 = raw_status(Config, [Method, " ", Path, " HTTP/1.1\r\n",
            base_headers(), auth_header(), "\r\n"])
    end, [{<<"PUT">>, AgentPath}, {<<"POST">>, <<"/v1/messages">>}]),
    {204, _} = put_agent(Config, Agent),
    200 = raw_status(Config, ["GET /v1/agents HTTP/1.1\r\n", base_headers(), auth_header(), "\r\n"]),
    204 = raw_status(Config, ["DELETE ", AgentPath, " HTTP/1.1\r\n",
        base_headers(), auth_header(), "\r\n"]),
    {200, Listed} = bus_http_SUITE:get(Config, "/v1/agents", bus_http_SUITE:auth()),
    {ok, #{<<"agents">> := []}} = bus_protocol:decode_json(Listed).

base_headers() -> "Host: localhost\r\nConnection: close\r\n".
auth_header() -> "Authorization: Bearer ct-token\r\n".
health_request(Headers) ->
    ["GET /health HTTP/1.1\r\n", base_headers(), Headers, "\r\n"].

raw_status(Config, Bytes) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, proplists:get_value(port, Config),
        [binary, {active, false}, {packet, http_bin}]),
    try
        ok = gen_tcp:send(Sock, Bytes),
        {ok, {http_response, _, Status, _}} = gen_tcp:recv(Sock, 0, 2000),
        Status
    after gen_tcp:close(Sock) end.

register_pair(Config) ->
    Msg = fixture("message-notice.json"),
    Agent = fixture("register-valid.json"),
    {204, _} = put_agent(Config, Agent),
    {204, _} = put_agent(Config, Agent#{<<"agentId">> => maps:get(<<"to">>, Msg)}),
    Msg.
put_agent(Config, Agent) ->
    request(Config, <<"PUT">>, <<"/v1/agents/", (maps:get(<<"agentId">>, Agent))/binary>>,
        bus_protocol:encode_map(Agent)).
post(Config, Msg) ->
    request(Config, <<"POST">>, <<"/v1/messages">>, bus_protocol:encode_map(Msg)).
error_code(Code, Body) ->
    {ok, #{<<"error">> := #{<<"code">> := Code}}} = bus_protocol:decode_json(Body),
    ok.

%% CT changes cwd to its log directory; locate the canonical source fixtures
%% from the test beam rather than relying on the runner's current directory.
fixture(Name) ->
    Path = fixture_path(filename:dirname(filename:absname(code:which(?MODULE))), Name),
    {ok, Bin} = file:read_file(Path),
    {ok, Map} = bus_protocol:decode_json(Bin),
    Map.
fixture_path(Dir, Name) ->
    Path = filename:join([Dir, "tests", "fixtures", Name]),
    case filelib:is_regular(Path) of
        true -> Path;
        false ->
            Parent = filename:dirname(Dir),
            case Parent =:= Dir of
                true -> error({shared_fixture_not_found, Name});
                false -> fixture_path(Parent, Name)
            end
    end.

request(Config, Method, Path, Body) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, proplists:get_value(port, Config),
        [binary, {active, false}, {packet, http_bin}]),
    try
        ok = gen_tcp:send(Sock, [Method, " ", Path,
            " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n",
            "Authorization: Bearer ct-token\r\nContent-Type: application/json\r\n",
            "Content-Length: ", integer_to_binary(byte_size(Body)), "\r\n\r\n", Body]),
        {ok, {http_response, _, Status, _}} = gen_tcp:recv(Sock, 0, 5000),
        Len = headers(Sock, 0),
        ok = inet:setopts(Sock, [{packet, raw}]),
        Response = case Len of
            0 -> <<>>;
            _ -> {ok, Bin} = gen_tcp:recv(Sock, Len, 5000), Bin
        end,
        {Status, Response}
    after gen_tcp:close(Sock) end.
headers(Sock, Len) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, http_eoh} -> Len;
        {ok, {http_header, _, 'Content-Length', _, Value}} ->
            headers(Sock, binary_to_integer(Value));
        {ok, {http_header, _, _, _, _}} -> headers(Sock, Len)
    end.
