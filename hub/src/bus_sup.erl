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
            {"/v1/agents", bus_http_h, list},
            {"/v1/agents/:agent_id", bus_http_h, agent},
            {"/v1/messages", bus_http_h, messages},
            {"/v1/events", bus_events_h, []}
        ]}
    ]),
    TransOpts = #{
        logger => bus_log,
        num_acceptors => 16,
        num_conns_sups => 16,
        %% Ranch applies this soft ceiling per connection supervisor, not globally.
        %% Nominal 8,192 leaves headroom for the unbenchmarked 5,000-idle target.
        max_connections => 512,
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
    {ok, {#{strategy => rest_for_one, intensity => 10, period => 10}, [Store, Listener]}}.
