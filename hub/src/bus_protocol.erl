-module(bus_protocol).

-export([
    decode_json/1,
    decode_register/1,
    decode_message/1,
    encode_health/0,
    encode_error/2,
    encode_map/1,
    is_uuid/1
]).

-define(MAX_HOST, 255).
-define(MAX_CWD_BYTES, 4096).
-define(MAX_LABEL, 200).
-define(MAX_PROVIDER, 200).
-define(MAX_MODEL_ID, 512).
-define(MAX_BODY_BYTES, 16 * 1024).

decode_json(Bin) when is_binary(Bin) ->
    Decoders = #{
        object_push => fun object_push/3
    },
    try json:decode(Bin, ok, Decoders) of
        {Value, ok, <<>>} ->
            {ok, Value};
        {_, _, Rest} when Rest =/= <<>> ->
            {error, trailing_data}
    catch
        error:unexpected_end ->
            {error, invalid_json};
        error:{invalid_byte, _} ->
            {error, invalid_json};
        error:{unexpected_sequence, _} ->
            {error, invalid_json};
        error:{duplicate_key, Key} ->
            {error, {duplicate_key, Key}};
        error:_ ->
            {error, invalid_json}
    end;
decode_json(_) ->
    {error, invalid_json}.

object_push(Key, Value, Acc) ->
    case lists:keymember(Key, 1, Acc) of
        true ->
            error({duplicate_key, Key});
        false ->
            [{Key, Value} | Acc]
    end.

decode_register(Map) when is_map(Map) ->
    Required = [
        <<"agentId">>,
        <<"sessionId">>,
        <<"host">>,
        <<"cwd">>,
        <<"sessionName">>,
        <<"label">>,
        <<"model">>,
        <<"status">>,
        <<"pid">>,
        <<"acceptsControl">>
    ],
    case extra_or_missing(Map, Required) of
        ok ->
            collect([
                fun() -> field_uuid(Map, <<"agentId">>) end,
                fun() -> field_uuid(Map, <<"sessionId">>) end,
                fun() -> field_host(Map, <<"host">>) end,
                fun() -> field_cwd(Map, <<"cwd">>) end,
                fun() -> field_label(Map, <<"sessionName">>) end,
                fun() -> field_label(Map, <<"label">>) end,
                fun() -> field_model(Map, <<"model">>) end,
                fun() -> field_status(Map, <<"status">>) end,
                fun() -> field_pid(Map, <<"pid">>) end,
                fun() -> field_bool(Map, <<"acceptsControl">>) end
            ]);
        Error ->
            Error
    end;
decode_register(_) ->
    {error, invalid_schema}.

decode_message(Map) when is_map(Map) ->
    Required = [<<"id">>, <<"from">>, <<"to">>, <<"kind">>, <<"body">>],
    case extra_or_missing(Map, Required) of
        ok ->
            collect([
                fun() -> field_uuid(Map, <<"id">>) end,
                fun() -> field_uuid(Map, <<"from">>) end,
                fun() -> field_uuid(Map, <<"to">>) end,
                fun() -> field_kind(Map, <<"kind">>) end,
                fun() -> field_body(Map, <<"body">>) end
            ]);
        Error ->
            Error
    end;
decode_message(_) ->
    {error, invalid_schema}.

encode_health() ->
    <<"{\"ok\":true}">>.

encode_error(Code, Message) when is_binary(Code), is_binary(Message) ->
    iolist_to_binary(
        json:encode(#{
            <<"error">> => #{
                <<"code">> => Code,
                <<"message">> => Message
            }
        })
    ).

encode_map(Map) when is_map(Map) ->
    iolist_to_binary(json:encode(Map)).

extra_or_missing(Map, Required) ->
    Keys = maps:keys(Map),
    Missing = Required -- Keys,
    Extra = Keys -- Required,
    case {Missing, Extra} of
        {[], []} -> ok;
        {[_ | _], _} -> {error, missing_fields};
        {[], _} -> {error, extra_fields}
    end.

collect(Funs) ->
    collect(Funs, #{}).

collect([], Acc) ->
    {ok, Acc};
collect([Fun | Rest], Acc) ->
    case Fun() of
        {ok, Key, Value} ->
            collect(Rest, Acc#{Key => Value});
        {error, _} = Error ->
            Error
    end.

field_uuid(Map, Key) ->
    case maps:get(Key, Map) of
        Bin when is_binary(Bin) ->
            case is_uuid(Bin) of
                true -> {ok, Key, Bin};
                false -> {error, {invalid_field, Key}}
            end;
        _ ->
            {error, {invalid_field, Key}}
    end.

field_host(Map, Key) ->
    case maps:get(Key, Map) of
        Bin when is_binary(Bin) ->
            case is_ascii_host(Bin) of
                true -> {ok, Key, Bin};
                false -> {error, {invalid_field, Key}}
            end;
        _ ->
            {error, {invalid_field, Key}}
    end.

field_cwd(Map, Key) ->
    case maps:get(Key, Map) of
        Bin when is_binary(Bin) ->
            case unicode:characters_to_binary(Bin) of
                Bin when byte_size(Bin) =< ?MAX_CWD_BYTES, byte_size(Bin) > 0 ->
                    case has_controls(Bin) of
                        true -> {error, {invalid_field, Key}};
                        false -> {ok, Key, Bin}
                    end;
                _ ->
                    {error, {invalid_field, Key}}
            end;
        _ ->
            {error, {invalid_field, Key}}
    end.

field_label(Map, Key) ->
    case maps:get(Key, Map) of
        Bin when is_binary(Bin) ->
            case codepoints(Bin) of
                N when is_integer(N), N =< ?MAX_LABEL, N > 0 ->
                    case is_single_line(Bin) andalso not has_controls(Bin) of
                        true -> {ok, Key, Bin};
                        false -> {error, {invalid_field, Key}}
                    end;
                _ ->
                    {error, {invalid_field, Key}}
            end;
        _ ->
            {error, {invalid_field, Key}}
    end.

field_model(Map, Key) ->
    case maps:get(Key, Map) of
        null ->
            {ok, Key, null};
        Model when is_map(Model) ->
            case extra_or_missing(Model, [<<"provider">>, <<"id">>]) of
                ok ->
                    case {model_string(maps:get(<<"provider">>, Model), ?MAX_PROVIDER),
                          model_string(maps:get(<<"id">>, Model), ?MAX_MODEL_ID)} of
                        {{ok, Provider}, {ok, Id}} ->
                            {ok, Key, #{<<"provider">> => Provider, <<"id">> => Id}};
                        _ ->
                            {error, {invalid_field, Key}}
                    end;
                _ ->
                    {error, {invalid_field, Key}}
            end;
        _ ->
            {error, {invalid_field, Key}}
    end.

field_status(Map, Key) ->
    case maps:get(Key, Map) of
        <<"idle">> -> {ok, Key, <<"idle">>};
        <<"busy">> -> {ok, Key, <<"busy">>};
        _ -> {error, {invalid_field, Key}}
    end.

field_pid(Map, Key) ->
    case maps:get(Key, Map) of
        N when is_integer(N), N > 0 -> {ok, Key, N};
        _ -> {error, {invalid_field, Key}}
    end.

field_bool(Map, Key) ->
    case maps:get(Key, Map) of
        true -> {ok, Key, true};
        false -> {ok, Key, false};
        _ -> {error, {invalid_field, Key}}
    end.

field_kind(Map, Key) ->
    case maps:get(Key, Map) of
        <<"notice">> -> {ok, Key, <<"notice">>};
        <<"prompt">> -> {ok, Key, <<"prompt">>};
        <<"steer">> -> {ok, Key, <<"steer">>};
        _ -> {error, {invalid_field, Key}}
    end.

field_body(Map, Key) ->
    case maps:get(Key, Map) of
        Bin when is_binary(Bin) ->
            case unicode:characters_to_binary(Bin) of
                Bin when byte_size(Bin) > ?MAX_BODY_BYTES ->
                    {error, payload_too_large};
                Bin when byte_size(Bin) > 0 ->
                    {ok, Key, Bin};
                _ ->
                    {error, {invalid_field, Key}}
            end;
        _ ->
            {error, {invalid_field, Key}}
    end.

model_string(Bin, Max) when is_binary(Bin) ->
    case codepoints(Bin) of
        N when is_integer(N), N > 0, N =< Max ->
            case is_single_line(Bin) andalso not has_controls(Bin) of
                true -> {ok, Bin};
                false -> error
            end;
        _ ->
            error
    end;
model_string(_, _) ->
    error.

is_uuid(
    <<A:8/binary, $-, B:4/binary, $-, C:4/binary, $-, D:4/binary, $-, E:12/binary>>
) ->
    lists:all(fun is_hex/1, binary_to_list(<<A/binary, B/binary, C/binary, D/binary, E/binary>>));
is_uuid(_) ->
    false.

is_hex(C) when C >= $0, C =< $9 -> true;
is_hex(C) when C >= $a, C =< $f -> true;
is_hex(C) when C >= $A, C =< $F -> true;
is_hex(_) -> false.

is_ascii_host(Bin) when byte_size(Bin) > 0, byte_size(Bin) =< ?MAX_HOST ->
    lists:all(fun(C) -> C >= 32 andalso C =< 126 end, binary_to_list(Bin)) andalso
        is_single_line(Bin);
is_ascii_host(_) ->
    false.

is_single_line(Bin) ->
    binary:match(Bin, [<<"\n">>, <<"\r">>, <<16#2028/utf8>>, <<16#2029/utf8>>]) =:= nomatch.

has_controls(Bin) ->
    lists:any(fun(C) -> C < 32 orelse (C >= 127 andalso C =< 159) end,
        unicode:characters_to_list(Bin)).

codepoints(Bin) ->
    case unicode:characters_to_list(Bin) of
        List when is_list(List) -> length(List);
        _ -> error
    end.
