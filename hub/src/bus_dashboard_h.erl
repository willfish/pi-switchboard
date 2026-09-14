-module(bus_dashboard_h).

-export([init/2]).

init(Req, Asset) ->
    Headers = #{
        <<"cache-control">> => <<"no-store">>,
        <<"referrer-policy">> => <<"no-referrer">>,
        <<"x-content-type-options">> => <<"nosniff">>,
        <<"x-frame-options">> => <<"DENY">>,
        <<"content-security-policy">> => <<"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'">>
    },
    Reply = case bus_dashboard_authority:allowed_host(Req) andalso
            bus_dashboard_authority:allowed_origin(Req) of
        false -> cowboy_req:reply(403, Headers, <<"Forbidden">>, Req);
        true ->
            case lists:member(cowboy_req:path(Req), paths()) of
                false -> cowboy_req:reply(404, Headers, <<"Not found">>, Req);
                true -> case cowboy_req:method(Req) of
                <<"GET">> -> serve(Req, Asset, Headers);
                <<"HEAD">> -> serve(Req, Asset, Headers);
                _ -> cowboy_req:reply(405, Headers#{<<"allow">> => <<"GET, HEAD">>}, <<>>, Req)
                end
            end
    end,
    {ok, Reply, []}.

%% Cowboy removes dot segments and decodes route tokens before dispatch.
%% Accept only canonical raw paths, even when an alias resolves to this handler.
paths() -> [<<"/">>, <<"/dashboard">>, <<"/dashboard/">>,
    <<"/dashboard/dashboard.css">>, <<"/dashboard/dashboard.js">>,
    <<"/dashboard/protocol.js">>].

serve(Req, redirect, Headers) ->
    cowboy_req:reply(302, Headers#{<<"location">> => <<"/dashboard/">>}, <<>>, Req);
serve(Req, index, Headers) ->
    case cowboy_req:path(Req) of
        <<"/dashboard">> -> serve(Req, redirect, Headers);
        _ -> serve_asset(Req, index, Headers)
    end;
serve(Req, Asset, Headers) ->
    serve_asset(Req, Asset, Headers).

serve_asset(Req, Asset, Headers) ->
    {Name, Type} = asset(Asset),
    %% Release assets are independent of cwd and never derived from request paths.
    Path = filename:join([code:priv_dir(pi_agent_bus), "dashboard", Name]),
    case file:read_file(Path) of
        {ok, Body} -> cowboy_req:reply(200, Headers#{<<"content-type">> => Type}, Body, Req);
        {error, _} -> cowboy_req:reply(404, Headers, <<"Not found">>, Req)
    end.

asset(index) -> {"index.html", <<"text/html; charset=utf-8">>};
asset(css) -> {"dashboard.css", <<"text/css; charset=utf-8">>};
asset(dashboard) -> {"dashboard.js", <<"text/javascript; charset=utf-8">>};
asset(protocol) -> {"protocol.js", <<"text/javascript; charset=utf-8">>}.
