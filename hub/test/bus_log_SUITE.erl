-module(bus_log_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1,
         otp_callback_crash/1, store_status/1, store_callback_crash/1, cowboy_request_crash/1,
         cowboy_stream_crash/1, ranch_protocol_crash/1, startup_diagnostics/1,
         default_cowboy_request_crash/1, default_cowboy_stream_crash/1,
         default_ranch_protocol_crash/1, filter_failure_closed/1,
         invalid_configuration/1]).
%% Test-only Logger handler and fault-injection callbacks.
-export([adding_handler/1, removing_handler/1, log/2,
         init/1, init/2, init/3, handle_call/3, handle_cast/2,
         start_link/0, start_link/3, protocol_init/3, filter_failure_fixture/1]).

all() -> [otp_callback_crash, store_status, store_callback_crash, cowboy_request_crash,
          cowboy_stream_crash, ranch_protocol_crash, startup_diagnostics,
          default_cowboy_request_crash, default_cowboy_stream_crash,
          default_ranch_protocol_crash, filter_failure_closed, invalid_configuration].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(cowboy),
    Primary = logger:get_primary_config(),
    ok = bus_log:install(),
    [{primary, Primary} | Config].

end_per_suite(Config) ->
    ok = logger:set_primary_config(proplists:get_value(primary, Config)).

adding_handler(Config) -> {ok, Config}.
removing_handler(_) -> ok.
log(Event, #{config := #{owner := Owner}}) ->
    Owner ! {rendered, iolist_to_binary(logger_formatter:format(Event, #{}))},
    ok.

capture(Fun, Expected) ->
    ok = logger:add_handler(bus_log_capture, ?MODULE,
                           #{level => all, config => #{owner => self()}}),
    try
        Fun(),
        Captures = collect([], 1500),
        %% Never include the raw captures in an assertion failure or CT output.
        true = Captures =/= [],
        Bytes = iolist_to_binary(Captures),
        nomatch = binary:match(Bytes, <<"PRIVATE_FIXTURE_">>),
        true = lists:all(fun(Category) ->
            binary:match(Bytes, Category) =/= nomatch
        end, Expected)
    after
        logger:remove_handler(bus_log_capture)
    end.

collect(Acc, Timeout) ->
    receive {rendered, Bytes} -> collect([Bytes | Acc], 100)
    after Timeout -> Acc
    end.

fixture() -> <<"PRIVATE_FIXTURE_body_token_presence_headers_dictionary_queue_reason_72fe">>.

start_link() -> gen_server:start_link(?MODULE, worker, []).
init(supervisor) ->
    {ok, {#{strategy => one_for_one},
          [#{id => fixture_worker, start => {?MODULE, start_link, []},
             restart => temporary}]}};
init(worker) ->
    put(secret, fixture()),
    {ok, fixture()}.
handle_call(crash, _From, State) ->
    self() ! {queued, fixture()},
    error({callback_input, State});
handle_call(_, _, State) -> {reply, ok, State}.
handle_cast(_, State) -> {noreply, State}.

otp_callback_crash(_) ->
    capture(fun() ->
        {ok, Sup} = supervisor:start_link(?MODULE, supervisor),
        unlink(Sup),
        try
            [{fixture_worker, Pid, _, _}] = supervisor:which_children(Sup),
            _ = catch gen_server:call(Pid, crash),
            timer:sleep(100)
        after gen_server:stop(Sup) end
    end, [<<"gen_server">>, <<"proc_lib">>, <<"supervisor">>]).

store_status(_) ->
    {ok, Pid} = bus_store:start_link(),
    unlink(Pid),
    try
        seed_store(),
        ok = sys:log(Pid, true),
        ok = sys:suspend(Pid),
        %% Queue a real input-bearing operation while sys messages remain live.
        Pid ! {'$gen_call', {self(), make_ref()},
                {op, erlang:monotonic_time(millisecond) + 5000,
                 {put_agent, agent(<<"a">>)}}},
        Pid ! {'$gen_call', {self(), make_ref()},
                {op, erlang:monotonic_time(millisecond) + 5000,
                 {list_agents_page, fixture()}}},
        Status = sys:get_status(Pid),
        nomatch = binary:match(term_to_binary(Status), <<"PRIVATE_FIXTURE_">>),
        ok = sys:resume(Pid),
        {ok, _} = bus_store:list_agents(),
        {status, Pid, {module, gen_server},
            [_Dictionary, _SysState, _Parent, Debug, Formatted]} = sys:get_status(Pid),
        %% Local sys:log opt-in exposes a raw outer debug ring, outside the
        %% callback. The callback's own logged-events section stays sanitized.
        true = binary:match(term_to_binary(Debug), <<"PRIVATE_FIXTURE_">>) =/= nomatch,
        nomatch = binary:match(term_to_binary(Formatted), <<"PRIVATE_FIXTURE_">>),
        ok = sys:log(Pid, false),
        nomatch = binary:match(term_to_binary(sys:get_status(Pid)), <<"PRIVATE_FIXTURE_">>)
    after gen_server:stop(Pid) end.

seed_store() ->
    ok = bus_store:put_agent(agent(<<"a">>)),
    ok = bus_store:put_agent(agent(<<"b">>)),
    {ok, _} = bus_store:accept_mail(#{<<"id">> => <<"fixture-mail">>,
        <<"from">> => <<"a">>, <<"to">> => <<"b">>,
        <<"kind">> => <<"notice">>, <<"body">> => fixture()}),
    {ok, Ref} = bus_store:subscribe(<<"b">>, self()),
    {frame, <<"presence_snapshot">>, Snapshot, true} = bus_store:pull_presence(<<"b">>, Ref),
    {ok, Page} = bus_store:list_agents_page(first, erlang:monotonic_time(millisecond) + 5000),
    true = binary:match(Snapshot, fixture()) =/= nomatch,
    true = binary:match(Page, fixture()) =/= nomatch,
    ok.

agent(Id) ->
    #{<<"agentId">> => Id, <<"sessionId">> => Id, <<"host">> => fixture(),
      <<"cwd">> => fixture(), <<"sessionName">> => fixture(),
      <<"label">> => fixture(), <<"model">> => null, <<"status">> => <<"idle">>,
      <<"pid">> => 1, <<"acceptsControl">> => false}.

store_callback_crash(_) ->
    capture(fun() ->
        {ok, Pid} = bus_store:start_link(),
        unlink(Pid),
        seed_store(),
        ok = sys:log(Pid, true),
        Monitor = monitor(process, Pid),
        ok = sys:suspend(Pid),
        Pid ! {'$gen_call', {self(), make_ref()}, {unsupported, fixture()}},
        gen_server:cast(Pid, {queued, fixture()}),
        ok = sys:resume(Pid),
        receive {'DOWN', Monitor, process, Pid, _} -> ok
        after 1000 -> error(store_did_not_crash)
        end
    end, [<<"gen_server">>, <<"proc_lib">>]).

%% Real Cowboy request callback exception includes the authenticated Req.
init(Req, _) -> error({request_input, fixture(), Req}).
%% Real Cowboy stream callback exception includes the Req and options.
init(_StreamID, Req, Opts) -> error({stream_input, fixture(), Req, Opts}).

cowboy_request_crash(_) ->
    Dispatch = cowboy_router:compile([{'_', [{"/", ?MODULE, []}]}]),
    cowboy_crash(#{env => #{dispatch => Dispatch}}, [<<"proc_lib">>]).

cowboy_stream_crash(_) ->
    cowboy_crash(#{stream_handlers => [?MODULE]}, [<<"cowboy">>]).

default_cowboy_request_crash(_) ->
    Dispatch = cowboy_router:compile([{'_', [{"/", ?MODULE, []}]}]),
    cowboy_crash(#{env => #{dispatch => Dispatch}}, [<<"proc_lib">>], #{}).

default_cowboy_stream_crash(_) ->
    cowboy_crash(#{stream_handlers => [?MODULE]}, [<<"cowboy">>], #{}).

cowboy_crash(Opts, Expected) ->
    cowboy_crash(Opts, Expected, #{logger => bus_log}).

cowboy_crash(Opts, Expected, LoggerOpts) ->
    capture(fun() ->
        {ok, _} = cowboy:start_clear(bus_log_fixture,
            LoggerOpts#{socket_opts => [{ip, {127,0,0,1}}, {port, 0}]},
            maps:merge(Opts#{protocols => [http]}, LoggerOpts)),
        try request(ranch:get_port(bus_log_fixture))
        after cowboy:stop_listener(bus_log_fixture) end
    end, Expected).

request(Port) ->
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}], 1000),
    try
        ok = gen_tcp:send(Socket, ["GET / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ",
                                  fixture(), "\r\nConnection: close\r\n\r\n"]),
        _ = gen_tcp:recv(Socket, 0, 1000),
        timer:sleep(100)
    after gen_tcp:close(Socket) end.

start_link(Ref, Transport, Opts) ->
    proc_lib:start_link(?MODULE, protocol_init, [Ref, Transport, Opts]).
protocol_init(Ref, _Transport, _Opts) ->
    proc_lib:init_ack({ok, self()}),
    {ok, _Socket} = ranch:handshake(Ref),
    put(secret, fixture()),
    self() ! {queued, fixture()},
    error({protocol_input, fixture()}).

startup_diagnostics(Config) ->
    TokenPath = filename:join(proplists:get_value(priv_dir, Config), "empty-token"),
    ok = file:write_file(TokenPath, <<>>),
    try
        startup_failure(TokenPath ++ ".missing", <<"missing_token_file">>),
        startup_failure(TokenPath, <<"empty_token">>)
    after file:delete(TokenPath) end.

startup_failure(TokenPath, Expected) ->
    startup_failure(TokenPath, Expected, #{}).

startup_failure(TokenPath, Expected, Overrides) ->
    {Status, Output} = dedicated_vm("bus_app:start(normal, []).",
        Overrides#{"PI_AGENT_BUS_TOKEN_FILE" => TokenPath}),
    %% Assert scalar results only, never raw subprocess captures.
    1 = Status,
    true = binary:match(Output, Expected) =/= nomatch,
    nomatch = binary:match(Output, <<"PRIVATE_FIXTURE_">>),
    nomatch = binary:match(Output, list_to_binary(TokenPath)).

invalid_configuration(Config) ->
    Root = proplists:get_value(priv_dir, Config),
    Path = filename:join(Root, "PRIVATE_FIXTURE_invalid-token"),
    Directory = filename:join(Root, "PRIVATE_FIXTURE_unreadable-token"),
    ok = file:make_dir(Directory),
    ok = file:write_file(Path, <<(fixture())/binary, 255>>),
    try
        startup_failure(Path, <<"invalid_bind_host">>,
            #{"PI_AGENT_BUS_BIND_HOST" => binary_to_list(fixture())}),
        startup_failure(Path, <<"invalid_port">>,
            #{"PI_AGENT_BUS_PORT" => binary_to_list(fixture())}),
        startup_failure(Path, <<"invalid_port">>, #{"PI_AGENT_BUS_PORT" => "65536"}),
        startup_failure("PRIVATE_FIXTURE_relative-token", <<"invalid_token_file_path">>),
        %% Reading a directory is deterministic even when tests run as root.
        startup_failure(Directory, <<"eisdir">>),
        startup_failure(Path, <<"invalid_token_encoding">>)
    after
        file:delete(Path),
        file:del_dir(Directory)
    end.

filter_failure_closed(_) ->
    lists:foreach(fun(Mode) ->
        Eval = "bus_log_SUITE:filter_failure_fixture(" ++ atom_to_list(Mode) ++ ").",
        {Status, Output} = dedicated_vm(Eval, #{}),
        0 = Status,
        true = binary:match(Output, <<"fixture_completed">>) =/= nomatch,
        nomatch = binary:match(Output, <<"PRIVATE_FIXTURE_">>)
    end, [startup, installed, startup_unavailable, installed_unavailable]).

filter_failure_fixture(Mode) ->
    case Mode of
        M when M =:= startup; M =:= startup_unavailable ->
            ok; % Exercise sys.config before bus_app:start installs the filter.
        _ ->
            ok = logger:set_primary_config(filter_default, log),
            ok = logger:add_primary_filter(fixture_permissive,
                {fun(Event, _) -> Event end, none}),
            ok = bus_log:install()
    end,
    #{filters := Filters} = logger:get_primary_config(),
    true = lists:keymember(bus_redaction, 1, Filters),
    FailFun = case Mode of
        M1 when M1 =:= startup_unavailable; M1 =:= installed_unavailable ->
            fun bus_log_missing_fixture:filter/2;
        _ -> fun(_, _) -> error(fixture_filter_failure) end
    end,
    Failing = {bus_redaction, {FailFun, none}},
    ok = logger:set_primary_config(filters,
        lists:keyreplace(bus_redaction, 1, Filters, Failing)),
    logger:error("~s", [fixture()]),
    #{filters := Remaining} = logger:get_primary_config(),
    false = lists:keymember(bus_redaction, 1, Remaining),
    %% Verify the triggering event and events after OTP removes the filter.
    logger:error("~s", [fixture()]),
    timer:sleep(100),
    io:format("fixture_completed~n"),
    erlang:halt(0).

dedicated_vm(Eval, Overrides) ->
    SysConfig = filename:join([filename:dirname(?FILE), "..", "config", "sys.config"]),
    Args = ["+S", "2", "-noshell", "-noinput", "-start_epmd", "false",
            "-pa", filename:dirname(code:which(bus_app)),
            filename:dirname(code:which(?MODULE)),
            "-config", filename:absname(SysConfig), "-eval", Eval],
    Env = maps:merge(#{"PI_AGENT_BUS_TOKEN_FILE" => false,
                      "PI_AGENT_BUS_BIND_HOST" => "127.0.0.1",
                      "PI_AGENT_BUS_PORT" => "0", "ERL_CRASH_DUMP" => "/dev/null",
                      "ERL_AFLAGS" => false, "ERL_FLAGS" => false,
                      "ERL_ZFLAGS" => false}, Overrides),
    Port = open_port({spawn_executable, os:find_executable("erl")},
        [binary, exit_status, stderr_to_stdout, {args, Args}, {env, maps:to_list(Env)}]),
    startup_output(Port, [], 0, erlang:monotonic_time(millisecond) + 10000).

startup_output(Port, Acc, Size, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Bytes}} when Size + byte_size(Bytes) =< 65536 ->
            startup_output(Port, [Bytes | Acc], Size + byte_size(Bytes), Deadline);
        {Port, {data, _}} -> port_close(Port), error(startup_output_limit);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Acc))}
    after Remaining -> port_close(Port), error(startup_timeout)
    end.

ranch_protocol_crash(_) -> ranch_crash(#{logger => bus_log}).
default_ranch_protocol_crash(_) -> ranch_crash(#{}).

ranch_crash(LoggerOpts) ->
    capture(fun() ->
        {ok, _} = ranch:start_listener(bus_log_fixture, ranch_tcp,
            LoggerOpts#{socket_opts => [{ip, {127,0,0,1}}, {port, 0}]},
            ?MODULE, #{}),
        try request(ranch:get_port(bus_log_fixture))
        after ranch:stop_listener(bus_log_fixture) end
    end, [<<"ranch">>, <<"proc_lib">>]).
