-module(bus_operator_work).

%% Pure WorkSnapshot codec. Later transport (not this module):
%% bindingId is stable across identical heartbeats; rotate only on
%% registration, runtimeGeneration, sessionId, sessionGeneration, branchId,
%% capability, or permission change.
%% Reject same-runtime older sessionGeneration; sessionId must match the
%% live registration.
%% Digest-skip of identical work must not suppress a bounded heartbeat
%% announce probe after storeEpoch loss (hub restart).
-export([keys/0, decode/1, decode_bin/1, encode/1, valid/1]).

-define(MAX_ENVELOPE, 32768).
-define(MAX_TEXT, 2048).
-define(MAX_OWNER, 200).
-define(MAX_REF, 512).
-define(MAX_EVIDENCE, 8).

keys() ->
    [<<"workId">>, <<"objective">>, <<"phase">>, <<"currentStep">>, <<"nextStep">>,
     <<"owner">>, <<"blocker">>, <<"project">>, <<"repository">>, <<"branch">>,
     <<"worktree">>, <<"parentWorkId">>, <<"delegatedWorkId">>, <<"evidence">>].

decode_bin(Bin) when is_binary(Bin), byte_size(Bin) =< ?MAX_ENVELOPE ->
    case bus_protocol:decode_json(Bin) of
        {ok, Map} -> decode(Map);
        {error, {duplicate_key, _}} -> {error, duplicate_key};
        {error, _} -> {error, invalid_work}
    end;
decode_bin(Bin) when is_binary(Bin) -> {error, envelope};
decode_bin(_) -> {error, invalid_work}.

decode(Map) when is_map(Map) ->
    try {ok, decode_map(Map)}
    catch
        throw:invalid_work -> {error, invalid_work};
        error:_ -> {error, invalid_work}
    end;
decode(_) -> {error, invalid_work}.

encode(Map) ->
    case decode(Map) of
        {ok, Canonical} ->
            Bin = iolist_to_binary(json:encode(Canonical)),
            case byte_size(Bin) =< ?MAX_ENVELOPE of
                true -> {ok, Bin};
                false -> {error, envelope}
            end;
        Error -> Error
    end.

valid(Value) ->
    case decode(Value) of
        {ok, _} -> true;
        _ -> false
    end.

decode_map(Map) ->
    case extra_or_missing(Map, keys()) of
        ok -> ok;
        _ -> throw(invalid_work)
    end,
    case maps:is_key(<<"body">>, Map) of
        true -> throw(invalid_work);
        false -> ok
    end,
    Canonical = #{
        <<"workId">> => optional_uuid(maps:get(<<"workId">>, Map)),
        <<"objective">> => optional_text(maps:get(<<"objective">>, Map), ?MAX_TEXT),
        <<"phase">> => optional_phase(maps:get(<<"phase">>, Map)),
        <<"currentStep">> => optional_text(maps:get(<<"currentStep">>, Map), ?MAX_TEXT),
        <<"nextStep">> => optional_text(maps:get(<<"nextStep">>, Map), ?MAX_TEXT),
        <<"owner">> => optional_text(maps:get(<<"owner">>, Map), ?MAX_OWNER),
        <<"blocker">> => optional_blocker(maps:get(<<"blocker">>, Map)),
        <<"project">> => optional_text(maps:get(<<"project">>, Map), ?MAX_TEXT),
        <<"repository">> => optional_text(maps:get(<<"repository">>, Map), ?MAX_TEXT),
        <<"branch">> => optional_text(maps:get(<<"branch">>, Map), ?MAX_TEXT),
        <<"worktree">> => optional_text(maps:get(<<"worktree">>, Map), ?MAX_TEXT),
        <<"parentWorkId">> => optional_uuid(maps:get(<<"parentWorkId">>, Map)),
        <<"delegatedWorkId">> => optional_uuid(maps:get(<<"delegatedWorkId">>, Map)),
        <<"evidence">> => evidence_list(maps:get(<<"evidence">>, Map))
    },
    Encoded = iolist_to_binary(json:encode(Canonical)),
    case byte_size(Encoded) =< ?MAX_ENVELOPE of
        true -> Canonical;
        false -> throw(invalid_work)
    end.

extra_or_missing(Map, Required) ->
    Keys = maps:keys(Map),
    case {Required -- Keys, Keys -- Required} of
        {[], []} -> ok;
        _ -> error
    end.

optional_uuid(null) -> null;
optional_uuid(Id) ->
    case bus_protocol:is_uuid(Id) of
        true -> Id;
        false -> throw(invalid_work)
    end.

optional_phase(null) -> null;
optional_phase(Phase) ->
    case lists:member(Phase, [<<"planning">>, <<"implementing">>, <<"verifying">>,
                              <<"waiting">>, <<"completed">>, <<"failed">>]) of
        true -> Phase;
        false -> throw(invalid_work)
    end.

optional_text(null, _) -> null;
optional_text(Bin, Max) when is_binary(Bin), byte_size(Bin) > 0, byte_size(Bin) =< Max ->
    utf8(Bin);
optional_text(_, _) -> throw(invalid_work).

optional_blocker(null) -> null;
optional_blocker(Map) when is_map(Map) ->
    case extra_or_missing(Map, [<<"kind">>, <<"reason">>]) of
        ok -> ok;
        _ -> throw(invalid_work)
    end,
    Kind = maps:get(<<"kind">>, Map),
    case Kind =:= <<"blocked">> orelse Kind =:= <<"decision">> of
        true -> ok;
        false -> throw(invalid_work)
    end,
    #{<<"kind">> => Kind,
      <<"reason">> => optional_text(maps:get(<<"reason">>, Map), ?MAX_TEXT)};
optional_blocker(_) -> throw(invalid_work).

evidence_list(List) when is_list(List), length(List) =< ?MAX_EVIDENCE ->
    [evidence_item(Item) || Item <- List];
evidence_list(_) -> throw(invalid_work).

evidence_item(Map) when is_map(Map) ->
    case extra_or_missing(Map, [<<"kind">>, <<"ref">>]) of
        ok -> ok;
        _ -> throw(invalid_work)
    end,
    Kind = maps:get(<<"kind">>, Map),
    case lists:member(Kind, [<<"file">>, <<"test">>, <<"commit">>, <<"artifact">>]) of
        true -> ok;
        false -> throw(invalid_work)
    end,
    #{<<"kind">> => Kind,
      <<"ref">> => optional_text(maps:get(<<"ref">>, Map), ?MAX_REF)};
evidence_item(_) -> throw(invalid_work).

utf8(Bin) ->
    case unicode:characters_to_binary(Bin) of
        Bin -> Bin;
        _ -> throw(invalid_work)
    end.
