-module(bus_sup).
-behaviour(supervisor).

-export([start_link/1, init/1]).

start_link(Config) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

init(#{bind_host := Host, port := Port}) ->
    {ok, Ip} = inet:parse_address(Host),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/health", bus_health_h, []},
            {"/", bus_dashboard_h, redirect},
            {"/dashboard/", bus_dashboard_h, index},
            {"/dashboard/dashboard.css", bus_dashboard_h, css},
            {"/dashboard/dashboard.js", bus_dashboard_h, dashboard},
            {"/dashboard/protocol.js", bus_dashboard_h, protocol},
            {"/dashboard/operator-session.js", bus_dashboard_h, operator_session},
            {"/dashboard/api/v1/session", bus_operator_h, session},
            {"/dashboard/api/v1/disconnect", bus_operator_h, disconnect},
            {"/dashboard/api/v1/presence", bus_operator_h, presence},
            {"/v1/agents", bus_http_h, list},
            {"/v1/agents/:agent_id", bus_http_h, agent},
            {"/v1/messages", bus_http_h, messages},
            {"/v1/events", bus_events_h, []}
        ]}
    ]),
    TransOpts = #{
        logger => bus_log,
        num_acceptors => 16,
        %% Connections stop concurrently within a group; multiple groups stop
        %% sequentially and multiply the per-connection linger allowance.
        num_conns_sups => 1,
        %% Ranch applies this soft ceiling per connection supervisor, not globally.
        %% Nominal 8,192 leaves headroom for the unbenchmarked 5,000-idle target.
        max_connections => 8192,
        connection_type => supervisor,
        socket_opts => [{ip, Ip}, {port, Port},
            {send_timeout, 5000}, {send_timeout_close, true}]
    },
    ProtoOpts = #{
        logger => bus_log,
        env => #{dispatch => Dispatch},
        protocols => [http],
        max_keepalive => 1,
        stream_handlers => [bus_deadline_stream, cowboy_stream_h],
        reset_idle_timeout_on_send => true,
        max_request_line_length => 8192,
        max_header_name_length => 256,
        max_header_value_length => 4096,
        max_headers => 32,
        request_timeout => 5000,
        shutdown_timeout => 1000,
        idle_timeout => 30000
    },
    Store = #{
        id => bus_store,
        start => {bus_store, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [bus_store]
    },
    Listener = ranch:child_spec(bus_http, ranch_tcp, TransOpts, bus_connection, ProtoOpts),
    Core = [Store, Listener],
    Children = case operator_enabled() of
        false -> Core;
        true ->
            Operator = #{id => bus_operator_sup,
                start => {bus_operator_sup, start_link, []},
                restart => transient, shutdown => 5000, type => supervisor,
                modules => [bus_operator_sup]},
            Core ++ [Operator]
    end,
    {ok, {#{strategy => rest_for_one, intensity => 10, period => 10}, Children}}.

operator_enabled() ->
    case application:get_env(pi_agent_bus, operator_access, disabled) of
        loopback -> true;
        {tailnet, Name} -> bus_app:valid_interface_name(Name);
        _ -> false
    end.
