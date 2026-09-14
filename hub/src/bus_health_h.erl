-module(bus_health_h).

-export([init/2]).

init(#{method := Method} = Req, State) when Method =/= <<"GET">> ->
    {ok, cowboy_req:reply(405, #{<<"allow">> => <<"GET">>}, <<>>, Req), State};
init(Req, State) ->
    Body = <<"{\"ok\":true}">>,
    Req2 = cowboy_req:reply(
        200,
        #{
            <<"content-type">> => <<"application/json">>,
            <<"cache-control">> => <<"no-store">>
        },
        Body,
        Req
    ),
    {ok, Req2, State}.
