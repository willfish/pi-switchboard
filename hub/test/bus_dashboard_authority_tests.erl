-module(bus_dashboard_authority_tests).
-include_lib("eunit/include/eunit.hrl").

req(Host, Port, Headers) ->
    #{host => Host, port => Port, scheme => <<"http">>,
      sock => {{192, 0, 2, 10}, 7420}, headers => Headers}.

host_test() ->
    {ok, Kernel} = inet:gethostname(),
    lists:foreach(fun(Host) ->
        ?assert(bus_dashboard_authority:allowed_host(req(Host, 7420, #{})))
    end, [list_to_binary(Kernel), <<"LOCALHOST.">>, <<"127.1.2.3">>,
          <<"[::1]">>, <<"192.0.2.10">>]),
    lists:foreach(fun(Host) ->
        ?assertNot(bus_dashboard_authority:allowed_host(req(Host, 7420,
            #{<<"x-forwarded-host">> => <<"localhost:7420">>})))
    end, [<<"localhost.attacker.test">>, <<"localhost..">>, <<"0.0.0.0">>,
          <<"[::]">>, <<"192.0.2.11">>, <<"attacker.test">>]),
    ?assertNot(bus_dashboard_authority:allowed_host(req(<<"localhost">>, 80, #{}))).

origin_test() ->
    R = req(<<"LOCALHOST">>, 7420, #{}),
    ?assert(bus_dashboard_authority:allowed_origin(R)),
    ?assert(bus_dashboard_authority:allowed_origin(R#{headers =>
        #{<<"origin">> => <<"http://localhost:7420">>}})),
    lists:foreach(fun(Origin) ->
        ?assertNot(bus_dashboard_authority:allowed_origin(R#{headers =>
            #{<<"origin">> => Origin}}))
    end, [<<"null">>, <<"http://localhost">>, <<"https://localhost:7420">>,
          <<"http://localhost:7420/">>, <<"http://localhost:7420?x">>,
          <<"http://localhost:7420#x">>, <<"http://user@localhost:7420">>,
          <<"http://localhost:7420 http://localhost:7420">>,
          <<"http://attacker.test:7420">>]).

origin_dot_and_default_port_test() ->
    lists:foreach(fun({Host, OriginHost}) ->
        R = req(Host, 80, #{<<"origin">> => <<"http://", OriginHost/binary>>}),
        ?assertNot(bus_dashboard_authority:allowed_origin(R))
    end, [{<<"localhost.">>, <<"localhost">>}, {<<"localhost">>, <<"localhost.">>}]),
    lists:foreach(fun({Scheme, Port}) ->
        lists:foreach(fun(Host) ->
            Origin = <<Scheme/binary, "://", Host/binary>>,
            R = (req(Host, Port, #{<<"origin">> => Origin}))#{scheme := Scheme},
            ?assert(bus_dashboard_authority:allowed_origin(R)),
            ?assert(bus_dashboard_authority:allowed_origin(R#{headers :=
                #{<<"origin">> => <<Origin/binary, ":", (integer_to_binary(Port))/binary>>}})),
            ?assertNot(bus_dashboard_authority:allowed_origin(R#{port := Port + 1}))
        end, [<<"localhost">>, <<"localhost.">>])
    end, [{<<"http">>, 80}, {<<"https">>, 443}]).

fetch_metadata_test() ->
    lists:foreach(fun(Value) ->
        ?assertNot(bus_dashboard_authority:allowed_read(req(<<"localhost">>, 7420,
            #{<<"sec-fetch-site">> => Value})))
    end, [<<"cross-site">>, <<"same-site">>, <<"bogus">>]),
    lists:foreach(fun(Headers) ->
        ?assert(bus_dashboard_authority:allowed_read(req(<<"localhost">>, 7420, Headers)))
    end, [#{}, #{<<"sec-fetch-site">> => <<"same-origin">>},
          #{<<"sec-fetch-site">> => <<"none">>}]).

mutation_requires_origin_without_changing_read_contract_test() ->
    R = req(<<"localhost">>, 7420, #{}),
    ?assert(bus_dashboard_authority:allowed_read(R)),
    ?assertNot(bus_dashboard_authority:allowed_mutation(R)),
    ?assert(bus_dashboard_authority:allowed_mutation(R#{headers :=
        #{<<"origin">> => <<"http://localhost:7420">>}})).

mutation_rejects_foreign_or_ambiguous_authority_test() ->
    R = req(<<"localhost">>, 7420, #{}),
    lists:foreach(fun(Headers) ->
        ?assertNot(bus_dashboard_authority:allowed_mutation(R#{headers := Headers}))
    end, [#{<<"origin">> => <<"null">>},
          #{<<"origin">> => <<"http://localhost.:7420">>},
          #{<<"origin">> => <<"http://localhost:7420, http://localhost:7420">>},
          #{<<"origin">> => <<"http://localhost:7420">>, <<"sec-fetch-site">> => <<"cross-site">>},
          #{<<"origin">> => <<"http://localhost:7420">>, <<"sec-fetch-site">> => <<"same-site">>}]),
    ?assertNot(bus_dashboard_authority:allowed_mutation(req(<<"foreign.invalid">>, 7420,
        #{<<"origin">> => <<"http://foreign.invalid:7420">>}))),
    ?assertNot(bus_dashboard_authority:allowed_mutation(#{headers => #{<<"origin">> => <<"http://localhost:7420">>}})).
