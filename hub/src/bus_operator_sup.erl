-module(bus_operator_sup).
-behaviour(supervisor).

%% Operator subtree. Init does not query interfaces or other recoverable
%% dependencies. Auth may restart within a bounded budget. The HTTP-lifetime
%% gate is temporary: a fresh quota table must not appear beside old
%% connections. Gate recovery is listener/service recovery that closes those
%% connections and reconstructs this subtree.
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Auth = #{id => bus_operator_auth,
        start => {bus_operator_auth, start_link, []},
        restart => permanent, shutdown => 5000, type => worker,
        modules => [bus_operator_auth]},
    Updates = #{id => bus_operator_updates,
        start => {bus_operator_updates, start_link, []},
        restart => permanent, shutdown => 5000, type => worker,
        modules => [bus_operator_updates]},
    Journal = #{id => bus_operator_journal,
        start => {bus_operator_journal, start_link, []},
        restart => permanent, shutdown => 5000, type => worker,
        modules => [bus_operator_journal]},
    Native = #{id => bus_operator_native,
        start => {bus_operator_native, start_link, []},
        restart => permanent, shutdown => 5000, type => worker,
        modules => [bus_operator_native]},
    Ops = #{id => bus_operator_ops,
        start => {bus_operator_ops, start_link, []},
        restart => permanent, shutdown => 5000, type => worker,
        modules => [bus_operator_ops]},
    Activity = #{id => bus_operator_activity,
        start => {bus_operator_activity, start_link, []},
        restart => permanent, shutdown => 5000, type => worker,
        modules => [bus_operator_activity]},
    Gate = #{id => bus_operator_http_gate,
        start => {bus_operator_http_gate, start_link, []},
        restart => temporary, shutdown => 5000, type => worker,
        modules => [bus_operator_http_gate]},
    {ok, {#{strategy => one_for_one, intensity => 3, period => 5},
          [Auth, Updates, Journal, Native, Ops, Activity, Gate]}}.
