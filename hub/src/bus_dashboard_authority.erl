-module(bus_dashboard_authority).

-export([allowed_host/1, allowed_origin/1, allowed_read/1]).

allowed_host(Req) ->
    {LocalIp, LocalPort} = cowboy_req:sock(Req),
    Host = normalize(cowboy_req:host(Req)),
    {ok, KernelHost} = inet:gethostname(),
    cowboy_req:port(Req) =:= LocalPort andalso
        (Host =:= normalize(list_to_binary(KernelHost)) orelse
         Host =:= <<"localhost">> orelse allowed_ip(Host, LocalIp)).

allowed_ip(Host, LocalIp) ->
    case inet:parse_strict_address(binary_to_list(unbracket(Host))) of
        {ok, {127, _, _, _}} -> true;
        {ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true;
        {ok, Ip} when Ip =:= LocalIp ->
            Ip =/= {0, 0, 0, 0} andalso Ip =/= {0, 0, 0, 0, 0, 0, 0, 0};
        _ -> false
    end.

allowed_origin(Req) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined -> true;
        Origin ->
            try uri_string:parse(Origin) of
                #{scheme := Scheme, host := Host} = Parsed ->
                    lists:all(fun(Key) -> lists:member(Key, [scheme, host, port, path]) end,
                        maps:keys(Parsed)) andalso
                    maps:get(path, Parsed, <<>>) =:= <<>> andalso
                    Scheme =:= cowboy_req:scheme(Req) andalso
                    %% Browser origins distinguish terminal-dot DNS names.
                    string:lowercase(Host) =:=
                        string:lowercase(unbracket(cowboy_req:host(Req))) andalso
                    maps:get(port, Parsed, default_port(Scheme)) =:= cowboy_req:port(Req);
                _ -> false
            catch _:_ -> false end
    end.

allowed_read(Req) ->
    allowed_origin(Req) andalso
        case cowboy_req:header(<<"sec-fetch-site">>, Req) of
            undefined -> true;
            <<"same-origin">> -> true;
            <<"none">> -> true;
            _ -> false
        end.

default_port(<<"http">>) -> 80;
default_port(<<"https">>) -> 443;
default_port(_) -> undefined.

normalize(Host) ->
    Lower = string:lowercase(Host),
    case Lower of
        <<>> -> <<>>;
        _ ->
            case binary:last(Lower) of
                $. -> binary:part(Lower, 0, byte_size(Lower) - 1);
                _ -> Lower
            end
    end.

unbracket(<<"[", Rest/binary>>) ->
    case binary:last(Rest) of
        $] -> binary:part(Rest, 0, byte_size(Rest) - 1);
        _ -> Rest
    end;
unbracket(Host) -> Host.
