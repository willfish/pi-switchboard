-module(bus_operator_bindings).

%% Pure announcement/binding state. No clocks or randomness.
%% bindingId is stable across identical heartbeats and work-only updates.
%% Rotate on runtime/session/branch/capability/permission transition.
%% Offered capability names rotate identity even when unimplemented.
%% Receipt/lookup capabilities are the intersection with ?IMPLEMENTED, hub
%% order, not a client echo. Operation-plane names are implemented; clients
%% still must offer them and set local permissions before they are usable.
%% New store epoch or registrationGeneration cannot reuse an old bindingId.
%% reportRevision orders full reports within a runtime. workRevision is a global
%% work-content clock: first retained work and later work-bytes changes bump it.
%% It does not track capability, permission, binding rotation, or removal.
-export([new/0, announce/4, lookup/2, remove/2, expire_registration/4, size/1, bytes/1,
         views/1]).

-define(MAX_ENVELOPE, 32768).
-define(MAX_BINDINGS, 5000).
-define(MAX_BYTES, 67108864).
-define(MAX_UINT, 18446744073709551615).
-define(CAPS, [
    <<"work.report.v1">>, <<"session.current.read.v1">>, <<"notice.receive.v1">>,
    <<"work.enqueue.v1">>, <<"guidance.attempt.v1">>, <<"label.set.v1">>,
    <<"run.interrupt.active.v1">>, <<"activity.report.v1">>,
    <<"work.assign.v1">>
]).
-define(IMPLEMENTED, [
    <<"work.report.v1">>, <<"notice.receive.v1">>, <<"work.enqueue.v1">>,
    <<"guidance.attempt.v1">>, <<"label.set.v1">>, <<"run.interrupt.active.v1">>,
    <<"session.current.read.v1">>, <<"activity.report.v1">>,
    <<"work.assign.v1">>
]).
-define(PERM_KEYS, [
    <<"notice">>, <<"work">>, <<"guidance">>, <<"sessionRead">>,
    <<"label">>, <<"interrupt">>, <<"content">>, <<"workAssign">>, <<"history">>
]).
-define(DOC_KEYS, [
    <<"schemaVersion">>, <<"agentId">>, <<"sessionId">>, <<"runtimeGeneration">>,
    <<"sessionGeneration">>, <<"branchId">>, <<"registration">>,
    <<"permissionRevision">>, <<"reportRevision">>, <<"capabilities">>,
    <<"permissions">>, <<"work">>, <<"activeRunId">>
]).

new() ->
    #{by_agent => #{}, by_binding => #{}, encoded_bytes => 0, next_work_revision => 1}.

size(#{by_agent := M}) -> map_size(M).
bytes(#{encoded_bytes := N}) -> N.

views(#{by_agent := By}) ->
    [json_view_map(view(E)) || {_, E} <- lists:keysort(1, maps:to_list(By))];
views(_) -> [].

lookup(AgentId, #{by_agent := By}) when is_binary(AgentId) ->
    case maps:find(AgentId, By) of
        error -> {error, not_found};
        {ok, Entry} -> {ok, view(Entry)}
    end;
lookup(_, _) -> {error, not_found}.

remove(AgentId, #{by_agent := By, by_binding := Bind, encoded_bytes := Bytes} = S)
  when is_binary(AgentId) ->
    case maps:take(AgentId, By) of
        error -> S;
        {Entry, By1} ->
            S#{by_agent := By1,
               by_binding := maps:remove(maps:get(binding_id, Entry), Bind),
               encoded_bytes := Bytes - maps:get(encoded, Entry)}
    end;
remove(_, S) -> S.

expire_registration(AgentId, Epoch, Generation, #{by_agent := By} = S)
  when is_binary(AgentId), is_binary(Epoch), is_integer(Generation) ->
    case maps:find(AgentId, By) of
        {ok, #{registration_epoch := Epoch, registration_generation := Generation}} ->
            remove(AgentId, S);
        _ -> S
    end;
expire_registration(_, _, _, S) -> S.

announce(Doc, Authority, Candidate, State) ->
    try announce1(Doc, Authority, Candidate, State)
    catch
        throw:Reason -> {error, Reason};
        error:_ -> {error, invalid_schema}
    end.

announce1(Doc0, Authority, Candidate, State) ->
    Doc = decode_doc(Doc0),
    true = bus_protocol:is_uuid(Candidate) orelse throw(invalid_schema),
    Auth = decode_authority(Authority),
    bind(Doc, Auth, Candidate, State).

decode_doc(Bin) when is_binary(Bin) ->
    case byte_size(Bin) > ?MAX_ENVELOPE of
        true -> throw(envelope);
        false ->
            case bus_protocol:decode_json(Bin) of
                {ok, Map} -> decode_doc(Map);
                {error, {duplicate_key, _}} -> throw(duplicate_key);
                {error, _} -> throw(invalid_schema)
            end
    end;
decode_doc(Map) when is_map(Map) ->
    Encoded = iolist_to_binary(json:encode(Map)),
    case byte_size(Encoded) > ?MAX_ENVELOPE of
        true -> throw(envelope);
        false -> decode_announcement(Map)
    end;
decode_doc(_) -> throw(invalid_schema).

decode_announcement(Map) ->
    case extra_or_missing(Map, ?DOC_KEYS) of
        ok -> ok;
        _ -> throw(invalid_schema)
    end,
    1 = maps:get(<<"schemaVersion">>, Map),
    AgentId = uuid(maps:get(<<"agentId">>, Map)),
    SessionId = uuid(maps:get(<<"sessionId">>, Map)),
    Runtime = uint(maps:get(<<"runtimeGeneration">>, Map)),
    SessionGen = uint(maps:get(<<"sessionGeneration">>, Map)),
    PermRev = uint(maps:get(<<"permissionRevision">>, Map)),
    ReportRev = uint(maps:get(<<"reportRevision">>, Map)),
    Branch = branch(maps:get(<<"branchId">>, Map)),
    Caps = capabilities(maps:get(<<"capabilities">>, Map)),
    Perms = permissions(maps:get(<<"permissions">>, Map)),
    Work = case bus_operator_work:decode(maps:get(<<"work">>, Map)) of
        {ok, W} -> W;
        {error, invalid_work} -> throw(invalid_work);
        {error, envelope} -> throw(envelope);
        _ -> throw(invalid_work)
    end,
    Registration = registration_opt(maps:get(<<"registration">>, Map)),
    ActiveRun = uuid_opt(maps:get(<<"activeRunId">>, Map)),
    #{schema_version => 1, agent_id => AgentId, session_id => SessionId,
      runtime_generation => Runtime, session_generation => SessionGen,
      permission_revision => PermRev, report_revision => ReportRev,
      branch_id => Branch, capabilities => Caps, permissions => Perms,
      work => Work, registration => Registration, active_run_id => ActiveRun,
      cap_set => lists:usort(Caps)}.

decode_authority(#{epoch := Epoch, registrationGeneration := Gen,
                   agentId := AgentId, sessionId := SessionId})
  when is_binary(Epoch), is_integer(Gen), Gen >= 0, Gen =< ?MAX_UINT,
       is_binary(AgentId), is_binary(SessionId) ->
    true = bus_protocol:is_uuid(Epoch) orelse throw(invalid_schema),
    true = bus_protocol:is_uuid(AgentId) orelse throw(invalid_schema),
    true = bus_protocol:is_uuid(SessionId) orelse throw(invalid_schema),
    #{epoch => Epoch, generation => Gen, agent_id => AgentId, session_id => SessionId};
decode_authority(_) -> throw(invalid_schema).

bind(Doc, Auth, Candidate, State) ->
    case maps:get(agent_id, Doc) =:= maps:get(agent_id, Auth) of
        true -> ok;
        false -> throw(not_found)
    end,
    case maps:get(session_id, Doc) =:= maps:get(session_id, Auth) of
        true -> ok;
        false -> throw(conflict)
    end,
    check_supplied_registration(maps:get(registration, Doc), Auth),
    case maps:find(maps:get(agent_id, Auth), maps:get(by_agent, State)) of
        error -> insert_new(Doc, Auth, Candidate, State);
        {ok, Entry} -> update_existing(Doc, Auth, Candidate, Entry, State)
    end.

check_supplied_registration(undefined, _) -> ok;
check_supplied_registration(null, _) -> ok;
check_supplied_registration(#{epoch := Epoch, generation := Gen}, Auth) ->
    case Epoch =:= maps:get(epoch, Auth) of
        false -> throw(epoch_reset);
        true ->
            case Gen =:= maps:get(generation, Auth) of
                true -> ok;
                false -> throw(stale_generation)
            end
    end.

insert_new(Doc, Auth, Candidate, State) ->
    By = maps:get(by_agent, State),
    case map_size(By) >= ?MAX_BINDINGS of
        true -> throw(capacity);
        false -> ok
    end,
    case maps:is_key(Candidate, maps:get(by_binding, State)) of
        true -> throw(conflict);
        false -> ok
    end,
    WorkRev = bump_work(State),
    Entry = entry(Doc, Auth, Candidate, WorkRev),
    install(Entry, undefined, State#{next_work_revision := WorkRev + 1}).

update_existing(Doc, Auth, Candidate, Entry, State) ->
    case registration_of(Entry) =:= {maps:get(epoch, Auth), maps:get(generation, Auth)} of
        false ->
            case maps:get(binding_id, Entry) =:= Candidate of
                true -> throw(conflict);
                false ->
                    State1 = remove(maps:get(agent_id, Auth), State),
                    insert_new(Doc, Auth, Candidate, State1)
            end;
        true ->
            check_generations(Doc, Entry),
            SameRuntime = maps:get(runtime_generation, Doc) =:= maps:get(runtime_generation, Entry),
            case SameRuntime andalso maps:get(report_revision, Doc) =:= maps:get(report_revision, Entry) of
                true -> same_report(Doc, Auth, Entry, State);
                false -> accept_update(Doc, Auth, Candidate, Entry, State)
            end
    end.

check_generations(Doc, Entry) ->
    older(maps:get(runtime_generation, Doc), maps:get(runtime_generation, Entry)),
    case maps:get(runtime_generation, Doc) =:= maps:get(runtime_generation, Entry) of
        false -> ok;
        true ->
            older(maps:get(session_generation, Doc), maps:get(session_generation, Entry)),
            older(maps:get(permission_revision, Doc), maps:get(permission_revision, Entry)),
            older(maps:get(report_revision, Doc), maps:get(report_revision, Entry))
    end.

older(New, Old) when New < Old -> throw(stale_generation);
older(_, _) -> ok.

same_report(Doc, Auth, Entry, State) ->
    case comparable(Doc) =:= comparable_entry(Entry) of
        true ->
            case maps:get(active_run_id, Doc) =:= maps:get(active_run_id, Entry) of
                true -> {ok, receipt(Entry, Auth), State};
                false ->
                    New = entry(Doc, Auth, maps:get(binding_id, Entry),
                        maps:get(work_revision, Entry)),
                    install(New, Entry, State)
            end;
        false -> throw(conflict)
    end.

accept_update(Doc, Auth, Candidate, Entry, State) ->
    Rotate = identity(Doc) =/= identity_entry(Entry),
    BindingId = case Rotate of
        false -> maps:get(binding_id, Entry);
        true ->
            case Candidate =:= maps:get(binding_id, Entry) of
                true -> throw(conflict);
                false ->
                    case maps:is_key(Candidate, maps:get(by_binding, State)) of
                        true -> throw(conflict);
                        false -> Candidate
                    end
            end
    end,
    WorkRev = case maps:get(work, Doc) =:= maps:get(work, Entry) of
        true -> maps:get(work_revision, Entry);
        false -> bump_work(State)
    end,
    NextState = case maps:get(work, Doc) =:= maps:get(work, Entry) of
        true -> State;
        false -> State#{next_work_revision := WorkRev + 1}
    end,
    NewEntry = entry(Doc, Auth, BindingId, WorkRev),
    State1 = case Rotate of
        true ->
            Bind0 = maps:get(by_binding, NextState),
            Bind1 = maps:remove(maps:get(binding_id, Entry), Bind0),
            NextState#{by_binding := Bind1};
        false -> NextState
    end,
    install(NewEntry, Entry, State1).

bump_work(#{next_work_revision := Next}) when Next > ?MAX_UINT -> throw(capacity);
bump_work(#{next_work_revision := Next}) -> Next.

install(Entry, Old, #{by_agent := By, by_binding := Bind, encoded_bytes := Bytes} = State) ->
    OldSize = case Old of undefined -> 0; _ -> maps:get(encoded, Old) end,
    NewBytes = Bytes - OldSize + maps:get(encoded, Entry),
    case NewBytes > ?MAX_BYTES of
        true -> throw(capacity);
        false ->
            AgentId = maps:get(agent_id, Entry),
            BindingId = maps:get(binding_id, Entry),
            State1 = State#{
                by_agent := By#{AgentId => Entry},
                by_binding := Bind#{BindingId => AgentId},
                encoded_bytes := NewBytes
            },
            {ok, receipt(Entry, #{epoch => maps:get(registration_epoch, Entry),
                                  generation => maps:get(registration_generation, Entry),
                                  agent_id => AgentId,
                                  session_id => maps:get(session_id, Entry)}), State1}
    end.

entry(Doc, Auth, BindingId, WorkRev) ->
    Entry0 = #{binding_id => BindingId,
      agent_id => maps:get(agent_id, Doc),
      session_id => maps:get(session_id, Doc),
      runtime_generation => maps:get(runtime_generation, Doc),
      session_generation => maps:get(session_generation, Doc),
      permission_revision => maps:get(permission_revision, Doc),
      report_revision => maps:get(report_revision, Doc),
      branch_id => maps:get(branch_id, Doc),
      capabilities => maps:get(capabilities, Doc),
      cap_set => maps:get(cap_set, Doc),
      permissions => maps:get(permissions, Doc),
      work => maps:get(work, Doc),
      active_run_id => maps:get(active_run_id, Doc),
      work_revision => WorkRev,
      registration_epoch => maps:get(epoch, Auth),
      registration_generation => maps:get(generation, Auth),
      encoded => 0},
    Size = iolist_size(json:encode(view(Entry0))),
    Entry0#{encoded := Size}.

identity(Doc) ->
    {maps:get(runtime_generation, Doc), maps:get(session_id, Doc),
     maps:get(session_generation, Doc), maps:get(branch_id, Doc),
     maps:get(cap_set, Doc), maps:get(permissions, Doc),
     maps:get(permission_revision, Doc)}.

identity_entry(E) ->
    {maps:get(runtime_generation, E), maps:get(session_id, E),
     maps:get(session_generation, E), maps:get(branch_id, E),
     maps:get(cap_set, E), maps:get(permissions, E),
     maps:get(permission_revision, E)}.

comparable(Doc) ->
    {identity(Doc), maps:get(report_revision, Doc), maps:get(work, Doc),
     maps:get(runtime_generation, Doc)}.

comparable_entry(E) ->
    {identity_entry(E), maps:get(report_revision, E), maps:get(work, E),
     maps:get(runtime_generation, E)}.

registration_of(E) ->
    {maps:get(registration_epoch, E), maps:get(registration_generation, E)}.

receipt(E, Auth) ->
    #{<<"schemaVersion">> => 1,
      <<"agentId">> => maps:get(agent_id, E),
      <<"sessionId">> => maps:get(session_id, E),
      <<"runtimeGeneration">> => integer_to_binary(maps:get(runtime_generation, E)),
      <<"sessionGeneration">> => integer_to_binary(maps:get(session_generation, E)),
      <<"branchId">> => maps:get(branch_id, E),
      <<"registration">> => #{
          <<"epoch">> => maps:get(epoch, Auth),
          <<"generation">> => integer_to_binary(maps:get(generation, Auth))
      },
      <<"permissionRevision">> => integer_to_binary(maps:get(permission_revision, E)),
      <<"reportRevision">> => integer_to_binary(maps:get(report_revision, E)),
      <<"capabilities">> => implemented(maps:get(capabilities, E)),
      <<"bindingId">> => maps:get(binding_id, E),
      <<"workRevision">> => integer_to_binary(maps:get(work_revision, E)),
      <<"activeRunId">> => maps:get(active_run_id, E)}.

implemented(Offered) ->
    [C || C <- ?IMPLEMENTED, lists:member(C, Offered)].

view(E) ->
    #{binding => receipt(E, #{epoch => maps:get(registration_epoch, E),
                              generation => maps:get(registration_generation, E),
                              agent_id => maps:get(agent_id, E),
                              session_id => maps:get(session_id, E)}),
      work => maps:get(work, E),
      permissions => maps:get(permissions, E)}.

json_view_map(#{binding := B, work := W, permissions := P}) ->
    #{<<"binding">> => B, <<"work">> => W, <<"permissions">> => P}.

extra_or_missing(Map, Required) ->
    Keys = maps:keys(Map),
    case {Required -- Keys, Keys -- Required} of
        {[], []} -> ok;
        _ -> error
    end.

uuid(Id) ->
    case bus_protocol:is_uuid(Id) of
        true -> Id;
        false -> throw(invalid_schema)
    end.

uuid_opt(null) -> null;
uuid_opt(Id) -> uuid(Id).

uint(Bin) when is_binary(Bin) ->
    case re:run(Bin, <<"^(0|[1-9][0-9]{0,19})$">>, [{capture, none}]) of
        match ->
            N = binary_to_integer(Bin),
            case N =< ?MAX_UINT of
                true -> N;
                false -> throw(invalid_schema)
            end;
        nomatch -> throw(invalid_schema)
    end;
uint(_) -> throw(invalid_schema).

branch(null) -> null;
branch(Bin) when is_binary(Bin), byte_size(Bin) >= 1, byte_size(Bin) =< 128 ->
    case re:run(Bin, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}]) of
        match -> Bin;
        nomatch -> throw(invalid_schema)
    end;
branch(_) -> throw(invalid_schema).

capabilities(List) when is_list(List), length(List) =< length(?CAPS) ->
    case lists:usort(List) =:= lists:sort(List) andalso
         lists:all(fun(C) -> lists:member(C, ?CAPS) end, List) of
        true -> List;
        false -> throw(invalid_schema)
    end;
capabilities(_) -> throw(invalid_schema).

permissions(Map) when is_map(Map) ->
    case extra_or_missing(Map, ?PERM_KEYS) of
        ok -> ok;
        _ -> throw(invalid_schema)
    end,
    maps:from_list([{K, bool(maps:get(K, Map))} || K <- ?PERM_KEYS]);
permissions(_) -> throw(invalid_schema).

bool(true) -> true;
bool(false) -> false;
bool(_) -> throw(invalid_schema).

registration_opt(null) -> null;
registration_opt(Map) when is_map(Map) ->
    case extra_or_missing(Map, [<<"epoch">>, <<"generation">>]) of
        ok -> ok;
        _ -> throw(invalid_schema)
    end,
    #{epoch => uuid(maps:get(<<"epoch">>, Map)),
      generation => uint(maps:get(<<"generation">>, Map))};
registration_opt(_) -> throw(invalid_schema).
