-module(bus_operator_access_tests).
-include_lib("eunit/include/eunit.hrl").

peer() -> {100, 80, 1, 2}.
local() -> {100, 80, 1, 1}.
iface(Name, Flags, Family, Ip) -> #{name => Name, flags => Flags, addr => #{family => Family, addr => Ip}}.
lookup() -> fun() -> {ok, [iface("tailscale0", [up, running], inet, local())]} end.

modes_and_loopback_test() ->
    Fail = fun() -> error(should_not_query_interfaces) end,
    ?assertEqual({error, disabled}, bus_operator_access:admit(disabled, peer(), local(), Fail)),
    ?assertEqual(ok, bus_operator_access:admit(loopback, {127, 0, 0, 2}, {127, 0, 0, 1}, Fail)),
    ?assertEqual(ok, bus_operator_access:admit(loopback, {0,0,0,0,0,0,0,1}, {0,0,0,0,0,0,0,1}, Fail)),
    ?assertEqual({error, forbidden}, bus_operator_access:admit(loopback, peer(), {127,0,0,1}, Fail)),
    ?assertEqual({error, forbidden}, bus_operator_access:admit(loopback, {127,0,0,1}, local(), Fail)).

exact_interface_destination_test() ->
    ?assertEqual(ok, bus_operator_access:admit({tailnet, "tailscale0"}, peer(), local(), lookup())),
    ?assertEqual({error, forbidden}, bus_operator_access:admit({tailnet, "tailscale0"}, peer(), {100,80,9,9}, lookup())),
    ?assertEqual({error, forbidden}, bus_operator_access:admit({tailnet, "tailscale0"}, peer(), {192,168,1,1}, lookup())).

interface_name_is_not_a_namespace_or_suffix_test() ->
    Other = fun() -> {ok, [iface("eth0", [up], inet, local()), iface("tailscale0.fake", [up], inet, local())]} end,
    ?assertEqual({error, unavailable}, bus_operator_access:admit({tailnet, "tailscale0"}, peer(), local(), Other)).

missing_down_failed_and_malformed_interfaces_test() ->
    lists:foreach(fun(Lookup) ->
        ?assertEqual({error, unavailable}, bus_operator_access:admit({tailnet, "tailscale0"}, peer(), local(), Lookup))
    end, [fun() -> {ok, []} end,
          fun() -> {ok, [iface("tailscale0", [], inet, local())]} end,
          fun() -> {error, eperm} end,
          fun() -> error(unavailable_dependency) end,
          fun() -> {ok, malformed} end,
          fun() -> {ok, [iface("tailscale0", [up], packet, local())]} end]).

loopback_does_not_depend_on_tailnet_discovery_test() ->
    ?assertEqual(ok, bus_operator_access:admit({tailnet, "tailscale0"}, {127,0,0,1}, {127,0,0,1}, fun() -> error(no_interface) end)).

ipv6_and_mapped_addresses_test() ->
    V6 = {16#fd7a,16#115c,16#a1e0,0,0,0,0,1},
    F = fun() -> {ok, [iface("tailscale0", [up], inet6, V6)]} end,
    ?assertEqual(ok, bus_operator_access:admit({tailnet, "tailscale0"}, peer(), V6, F)),
    ?assertEqual(ok, bus_operator_access:admit(loopback, {0,0,0,0,0,16#ffff,16#7f00,1}, {127,0,0,1}, F)).

invalid_socket_metadata_is_rejected_test() ->
    lists:foreach(fun(Peer) ->
        ?assertEqual({error, forbidden}, bus_operator_access:admit({tailnet, "tailscale0"}, Peer, local(), lookup()))
    end, [undefined, <<"100.80.1.2">>, {127,0,0,999}, {0,0,0,0,0,0,0,-1},
          {0,0,0,0}, {224,0,0,1}, {0,0,0,0,0,0,0,0}, {16#ff02,0,0,0,0,0,0,1},
          {0,0,0,0,0,16#ffff,16#e000,1}]),
    ?assertEqual({error, forbidden}, bus_operator_access:admit(unknown, peer(), local(), lookup())).

routed_peer_does_not_turn_destination_check_into_ingress_proof_test() ->
    %% Actual ingress must also be enforced by the deployment firewall. Source
    %% address shape is not proof of (or a substitute for) the receiving interface.
    ?assertEqual(ok, bus_operator_access:admit({tailnet, "tailscale0"}, {192,168,8,2}, local(), lookup())).
