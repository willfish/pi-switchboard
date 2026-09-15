-module(bus_operator_access).

%% Destination verification is an additional check, not proof of ingress.
%% Deployments must independently restrict this listener to trusted ingress.
-export([admit/3, admit/4]).

admit(Mode, Peer, Local) -> admit(Mode, Peer, Local, fun net:getifaddrs/0).

admit(disabled, _, _, _) -> {error, disabled};
admit(Mode, Peer, Local, Lookup) ->
    case valid_ip(Peer) andalso valid_ip(Local) of
        false -> {error, forbidden};
        true ->
            P = normalize(Peer), L = normalize(Local),
            case usable_ip(P) andalso usable_ip(L) of
                true -> admit_valid(Mode, P, L, Lookup);
                false -> {error, forbidden}
            end
    end.

admit_valid(loopback, Peer, Local, _) ->
    case loopback(Peer) andalso loopback(Local) of
        true -> ok;
        false -> {error, forbidden}
    end;
admit_valid({tailnet, Name}, Peer, Local, Lookup) when is_list(Name), Name =/= [], length(Name) =< 64 ->
    case loopback(Peer) andalso loopback(Local) of
        true -> ok;
        false -> check_interface(Name, Local, Lookup)
    end;
admit_valid(_, _, _, _) -> {error, forbidden}.

check_interface(Name, Local, Lookup) ->
    %% net:getifaddrs/0 enumerates the current namespace. Passing an interface
    %% string to /1 would select a network namespace instead of filtering names.
    try Lookup() of
        {ok, Entries} when is_list(Entries) ->
            Addresses = [normalize(Ip) ||
                #{name := Seen, flags := Flags, addr := #{family := Family, addr := Ip}} <- Entries,
                Seen =:= Name, is_list(Flags), lists:member(up, Flags), compatible(Family, Ip),
                usable_ip(normalize(Ip))],
            case Addresses of
                [] -> {error, unavailable};
                _ ->
                    case lists:member(Local, Addresses) of
                        true -> ok;
                        false -> {error, forbidden}
                    end
            end;
        _ -> {error, unavailable}
    catch
        _:_ -> {error, unavailable}
    end.

compatible(inet, Ip) when is_tuple(Ip), tuple_size(Ip) =:= 4 -> valid_ip(Ip);
compatible(inet6, Ip) when is_tuple(Ip), tuple_size(Ip) =:= 8 -> valid_ip(Ip);
compatible(_, _) -> false.

valid_ip(Ip) when is_tuple(Ip), tuple_size(Ip) =:= 4 -> valid_components(Ip, 255);
valid_ip(Ip) when is_tuple(Ip), tuple_size(Ip) =:= 8 -> valid_components(Ip, 65535);
valid_ip(_) -> false.
valid_components(Ip, Max) ->
    lists:all(fun(N) -> is_integer(N) andalso N >= 0 andalso N =< Max end, tuple_to_list(Ip)).

normalize({0,0,0,0,0,16#ffff,A,B}) -> {A bsr 8, A band 255, B bsr 8, B band 255};
normalize(Ip) -> Ip.
usable_ip({A, _, _, _}) -> A > 0 andalso A < 224;
usable_ip({0,0,0,0,0,0,0,0}) -> false;
usable_ip({A,_,_,_,_,_,_,_}) -> A band 16#ff00 =/= 16#ff00.
loopback({127, _, _, _}) -> true;
loopback({0,0,0,0,0,0,0,1}) -> true;
loopback(_) -> false.
