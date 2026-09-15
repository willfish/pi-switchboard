-module(bus_operator_http).

%% Operator HTTP codec only. Does not authenticate or admit.
-export([encode_nonce/1, decode_nonce/1, empty_object/1, session_header/1,
         canonical_origin/1, canonical_origin/3]).

encode_nonce(Raw) when is_binary(Raw), byte_size(Raw) =:= 32 ->
    string:lowercase(binary:encode_hex(Raw)).

decode_nonce(Hex) when is_binary(Hex), byte_size(Hex) =:= 64 ->
    case lowercase_hex(Hex) of
        true ->
            try binary:decode_hex(Hex) of
                Raw when byte_size(Raw) =:= 32 -> {ok, Raw};
                _ -> {error, unauthorized}
            catch
                _:_ -> {error, unauthorized}
            end;
        false -> {error, unauthorized}
    end;
decode_nonce(_) -> {error, unauthorized}.

empty_object(Map) when is_map(Map), map_size(Map) =:= 0 -> ok;
empty_object(_) -> {error, invalid_schema}.

session_header(Req) ->
    case cowboy_req:header(<<"x-switchboard-session">>, Req) of
        undefined -> undefined;
        Value -> decode_nonce(Value)
    end.

%% Bind sessions to scheme + host + effective port. Host trailing dots are kept.
%% Default ports 80/443 are omitted. IPv6 hosts are bracketed.
canonical_origin(Req) when is_map(Req) ->
    canonical_origin(cowboy_req:scheme(Req), cowboy_req:host(Req), cowboy_req:port(Req)).

canonical_origin(Scheme, Host, Port) when is_binary(Scheme), is_binary(Host), is_integer(Port) ->
    HostPart = origin_host(Host),
    case default_port(Scheme) =:= Port of
        true -> <<Scheme/binary, "://", HostPart/binary>>;
        false -> <<Scheme/binary, "://", HostPart/binary, ":", (integer_to_binary(Port))/binary>>
    end.

origin_host(Host) ->
    Lower = string:lowercase(Host),
    case {Lower, binary:match(Lower, <<":">>)} of
        {<<"[", _/binary>>, _} -> Lower;
        {_, nomatch} -> Lower;
        {_, _} -> <<"[", Lower/binary, "]">>
    end.

default_port(<<"http">>) -> 80;
default_port(<<"https">>) -> 443;
default_port(_) -> undefined.

lowercase_hex(<<>>) -> true;
lowercase_hex(<<C, Rest/binary>>) when C >= $0, C =< $9 -> lowercase_hex(Rest);
lowercase_hex(<<C, Rest/binary>>) when C >= $a, C =< $f -> lowercase_hex(Rest);
lowercase_hex(_) -> false.
