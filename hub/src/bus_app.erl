-module(bus_app).
-behaviour(application).

-export([start/2, stop/1, operator_access/0, valid_interface_name/1]).

start(_StartType, _StartArgs) ->
    ok = bus_log:install(),
    case load_config() of
        {ok, #{bind_host := Host, port := Port, token := Token}} ->
            ok = application:set_env(pi_agent_bus, token, Token),
            ok = application:set_env(pi_agent_bus, operator_access, operator_access()),
            bus_sup:start_link(#{bind_host => Host, port => Port});
        {error, Reason} ->
            io:format(standard_error, "pi_agent_bus failed to start: ~p~n", [sanitize(Reason)]),
            erlang:halt(1)
    end.

stop(_State) ->
    ok.

load_config() ->
    case bind_host() of
        {error, _} = Error ->
            Error;
        Host ->
            case port() of
                {error, _} = Error ->
                    Error;
                Port ->
                    case token() of
                        {error, _} = Error ->
                            Error;
                        Token ->
                            {ok, #{bind_host => Host, port => Port, token => Token}}
                    end
            end
    end.

bind_host() ->
    case os:getenv("PI_AGENT_BUS_BIND_HOST") of
        false -> "127.0.0.1";
        "" -> "127.0.0.1";
        Host ->
            case inet:parse_address(Host) of
                {ok, _} -> Host;
                {error, _} -> {error, invalid_bind_host}
            end
    end.

port() ->
    case os:getenv("PI_AGENT_BUS_PORT") of
        false -> 7420;
        "" -> 7420;
        Value ->
            case string:to_integer(Value) of
                {N, []} when is_integer(N), N >= 0, N =< 65535 -> N;
                _ -> {error, invalid_port}
            end
    end.

token() ->
    case os:getenv("PI_AGENT_BUS_TOKEN_FILE") of
        false ->
            {error, missing_token_file};
        "" ->
            {error, missing_token_file};
        Path ->
            case filename:pathtype(Path) of
                absolute -> read_token(Path);
                _ -> {error, invalid_token_file_path}
            end
    end.

read_token(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> decode_token(Bin);
        {error, enoent} -> {error, missing_token_file};
        {error, Reason} -> {error, {token_file, Reason}}
    end.

decode_token(Bin) ->
    %% Validate the entire credential before trimming. Invalid or incomplete
    %% UTF-8 must never become an input-bearing boot exception.
    try
        case unicode:characters_to_binary(Bin, utf8, utf8) of
            Valid when is_binary(Valid) ->
                case string:trim(Valid) of
                    <<>> -> {error, empty_token};
                    Token -> Token
                end;
            _ -> {error, invalid_token_encoding}
        end
    catch
        _:_ -> {error, invalid_token_encoding}
    end.

sanitize(invalid_bind_host) -> invalid_bind_host;
sanitize(invalid_port) -> invalid_port;
sanitize(missing_token_file) -> missing_token_file;
sanitize(empty_token) -> empty_token;
sanitize(invalid_token_file_path) -> invalid_token_file_path;
sanitize(invalid_token_encoding) -> invalid_token_encoding;
sanitize({token_file, eacces}) -> {token_file, eacces};
sanitize({token_file, eperm}) -> {token_file, eperm};
sanitize({token_file, eisdir}) -> {token_file, eisdir};
sanitize({token_file, _}) -> token_file_unreadable;
sanitize(_) -> configuration_error.

%% Optional. Unknown values fail closed to disabled and never log the raw env.
operator_access() ->
    case os:getenv("PI_AGENT_BUS_OPERATOR_ACCESS") of
        false -> disabled;
        "" -> disabled;
        "disabled" -> disabled;
        "loopback" -> loopback;
        "tailnet" ->
            case operator_interface() of
                {ok, Name} -> {tailnet, Name};
                error -> disabled
            end;
        _ -> disabled
    end.

valid_interface_name(Name) when is_list(Name), length(Name) > 0, length(Name) =< 64 ->
    lists:all(fun interface_char/1, Name);
valid_interface_name(_) -> false.

operator_interface() ->
    case os:getenv("PI_AGENT_BUS_OPERATOR_INTERFACE") of
        false -> {ok, "tailscale0"};
        "" -> {ok, "tailscale0"};
        Name ->
            case valid_interface_name(Name) of
                true -> {ok, Name};
                false -> error
            end
    end.

interface_char(C) when C >= $a, C =< $z -> true;
interface_char(C) when C >= $A, C =< $Z -> true;
interface_char(C) when C >= $0, C =< $9 -> true;
interface_char($.) -> true;
interface_char($_) -> true;
interface_char($-) -> true;
interface_char(_) -> false.
