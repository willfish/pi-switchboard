-module(bus_operator_operations).

%% Pure operation ledger. No processes, no mail, no warehouse.
%% Duplicate operationId with the same create digest is idempotent and does
%% not replay. A different digest is conflict. Cancel after native receipt
%% cannot withdraw an SDK effect. Guidance attempted is not queued/consumed.
%% Interrupt is not process kill. Session cancel drops assembly only.
-export([new/0, create/5, requests/4, content/4, result/4, status/2, status/3,
         cancel/3, cancel/4, list/3, expire/2, size/1, bytes/1]).

-define(LIST_LIMIT, 128).
-define(LIST_BYTES, 1048576).
-define(MAX_LABEL_UTF8, 800).

-define(MAX_UINT, 18446744073709551615).
-define(MAX_TEXT, 16384).
-define(MAX_LABEL, 200).
-define(MAX_REASON, 512).
-define(MAX_HANDLE, 128).
-define(DESC, 8).
-define(DESC_EACH, 2048).
-define(DESC_TOTAL, 16384).
-define(FRAG, 32).
-define(FRAG_RAW, 16384).
-define(PAGE_BYTES, 524288).
-define(PAGE_RECORDS, 64).
-define(STAGE_BYTES, 67108864).
-define(OUT_SESSION, 4).
-define(MAX_NOTICES, 32).
-define(CONTENT_GET, 32768).
-define(TTL_MS, 30000).
-define(TOMB_MS, 30000).
-define(MAX_OPS, 4096).
-define(KINDS, [
    <<"notice">>, <<"work">>, <<"guidance">>, <<"label">>,
    <<"interrupt">>, <<"sessionRead">>, <<"workAssign">>
]).
-define(CREATE_KEYS, [
    <<"schemaVersion">>, <<"operationId">>, <<"kind">>, <<"agentId">>,
    <<"bindingId">>, <<"runtimeGeneration">>, <<"sessionGeneration">>,
    <<"branchId">>, <<"runId">>, <<"workId">>, <<"deadline">>, <<"payload">>
]).
-define(PAGE_KEYS, [
    <<"schemaVersion">>, <<"sessionId">>, <<"leafId">>, <<"nextLeafId">>,
    <<"records">>, <<"omitted">>, <<"truncated">>
]).
-define(RECORD_KEYS, [<<"entryId">>, <<"role">>, <<"text">>]).
-define(ROLES, [<<"user">>, <<"assistant">>, <<"custom">>, <<"tool-summary">>]).

new() ->
    #{by_id => #{}, by_agent => #{}, bytes => 0}.

size(#{by_id := M}) -> map_size(M).
bytes(#{bytes := N}) -> N.

create(Doc, View, Digest, Now, State)
  when is_map(Doc), is_map(View), is_binary(Digest), byte_size(Digest) =:= 32,
       is_integer(Now), is_map(State) ->
    try create1(Doc, View, Digest, Now, State)
    catch
        throw:Reason -> {error, Reason};
        error:_ -> {error, invalid_schema}
    end;
create(_, _, _, _, _) -> {error, invalid_schema}.

requests(AgentId, CurrentWorkId, Now, State)
  when is_binary(AgentId), is_integer(Now), is_map(State) ->
    try {ok, poll(AgentId, CurrentWorkId, Now, State), State}
    catch throw:Reason -> {error, Reason}
    end;
requests(_, _, _, _) -> {error, invalid_schema}.

content(OpId, ContentId, CurrentWorkId, State)
  when is_binary(OpId), is_binary(ContentId) ->
    case maps:find(OpId, maps:get(by_id, State)) of
        error -> {error, not_found};
        {ok, Op} ->
            case maps:get(content_id, Op) =:= ContentId
                    andalso maps:get(state, Op) =/= <<"cancelled">>
                    andalso maps:get(state, Op) =/= <<"expired">> of
                false -> {error, not_found};
                true ->
                    case maps:get(offered, Op) =:= true
                            orelse maps:get(work_id, Op) =:= CurrentWorkId of
                        true -> {ok, maps:get(body, Op), State};
                        false -> {error, stale_generation}
                    end
            end
    end;
content(_, _, _, _) -> {error, invalid_schema}.

result(Doc, View, Now, State) when is_map(Doc), is_map(View), is_integer(Now) ->
    try result1(Doc, View, Now, State)
    catch
        throw:Reason -> {error, Reason};
        error:_ -> {error, invalid_schema}
    end;
result(_, _, _, _) -> {error, invalid_schema}.

status(OpId, State) when is_binary(OpId), is_map(State) ->
    case maps:find(OpId, maps:get(by_id, State)) of
        error -> {error, not_found};
        {ok, Op} -> {ok, public(Op)}
    end;
status(_, _) -> {error, invalid_schema}.

status(OpId, Digest, State)
  when is_binary(OpId), is_binary(Digest), is_map(State) ->
    case maps:find(OpId, maps:get(by_id, State)) of
        error -> {error, not_found};
        {ok, Op} ->
            case maps:get(digest, Op) =:= Digest of
                true -> {ok, public(Op)};
                false -> {error, forbidden}
            end
    end;
status(_, _, _) -> {error, invalid_schema}.

list(AgentId, Digest, State)
  when is_binary(AgentId), is_binary(Digest), is_map(State) ->
    _ = Digest,
    Ids = maps:get(AgentId, maps:get(by_agent, State), []),
    Ops = [maps:get(Id, maps:get(by_id, State)) || Id <- Ids,
        maps:is_key(Id, maps:get(by_id, State))],
    Sorted = lists:sort(fun(A, B) -> maps:get(created, A) >= maps:get(created, B) end, Ops),
    Items = fit_list(Sorted, []),
    {ok, #{<<"schemaVersion">> => 1, <<"operations">> => Items}};
list(_, _, _) -> {error, invalid_schema}.

fit_list([], Acc) -> lists:reverse(Acc);
fit_list(_, Acc) when length(Acc) >= ?LIST_LIMIT -> lists:reverse(Acc);
fit_list([Op | Rest], Acc) ->
    Item = maps:put(<<"page">>, null, public(Op)),
    Cand = lists:reverse([Item | Acc]),
    Doc = #{<<"schemaVersion">> => 1, <<"operations">> => Cand},
    case iolist_size(json:encode(Doc)) =< ?LIST_BYTES of
        true -> fit_list(Rest, [Item | Acc]);
        false -> lists:reverse(Acc)
    end.

cancel(OpId, Digest, Now, State)
  when is_binary(OpId), is_binary(Digest), is_integer(Now), is_map(State) ->
    case maps:find(OpId, maps:get(by_id, State)) of
        error -> {error, not_found};
        {ok, Op} ->
            case maps:get(digest, Op) =:= Digest of
                false -> {error, forbidden};
                true -> cancel1(Op, Now, State)
            end
    end;
cancel(_, _, _, _) -> {error, invalid_schema}.

%% Exported cancel/3 kept for status-only callers that already authorized.
cancel(OpId, Now, State) ->
    case maps:find(OpId, maps:get(by_id, State)) of
        error -> {error, not_found};
        {ok, Op} -> cancel1(Op, Now, State)
    end.

expire(Now, #{by_id := By} = State) when is_integer(Now) ->
    maps:fold(fun(Id, Op, {Acc, Ev}) ->
        {Acc1, Extra} = expire_one(Now, Id, Op, Acc),
        {Acc1, Extra ++ Ev}
    end, {State, []}, By);
expire(_, State) -> {State, []}.

create1(Doc, View, Digest, Now, State) ->
    check_keys(Doc, ?CREATE_KEYS),
    1 = maps:get(<<"schemaVersion">>, Doc),
    OpId = uuid(maps:get(<<"operationId">>, Doc)),
    Kind = kind(maps:get(<<"kind">>, Doc)),
    AgentId = uuid(maps:get(<<"agentId">>, Doc)),
    BindingId = uuid(maps:get(<<"bindingId">>, Doc)),
    Runtime = uint(maps:get(<<"runtimeGeneration">>, Doc)),
    SessionGen = uint(maps:get(<<"sessionGeneration">>, Doc)),
    Branch = branch(maps:get(<<"branchId">>, Doc)),
    RunId = uuid_opt(maps:get(<<"runId">>, Doc)),
    WorkId = uuid_opt(maps:get(<<"workId">>, Doc)),
    Deadline = uint(maps:get(<<"deadline">>, Doc)),
    Payload = maps:get(<<"payload">>, Doc),
    Binding = maps:get(binding, View),
    Perms = maps:get(permissions, View),
    true = maps:get(<<"agentId">>, Binding) =:= AgentId orelse throw(not_found),
    true = maps:get(<<"bindingId">>, Binding) =:= BindingId orelse throw(stale_generation),
    true = binary_to_integer(maps:get(<<"runtimeGeneration">>, Binding)) =:= Runtime
        orelse throw(stale_generation),
    true = binary_to_integer(maps:get(<<"sessionGeneration">>, Binding)) =:= SessionGen
        orelse throw(stale_generation),
    true = maps:get(<<"branchId">>, Binding) =:= Branch orelse throw(stale_generation),
    Cap = cap_of(Kind),
    Perm = perm_of(Kind),
    true = lists:member(Cap, maps:get(<<"capabilities">>, Binding)) orelse throw(forbidden),
    true = maps:get(Perm, Perms) =:= true orelse throw(forbidden),
    case Kind of
        <<"sessionRead">> ->
            true = maps:get(<<"content">>, Perms) =:= true orelse throw(forbidden);
        <<"interrupt">> ->
            Active = maps:get(<<"activeRunId">>, Binding, null),
            true = is_binary(RunId) orelse throw(invalid_schema),
            true = is_binary(Active) orelse throw(stale_generation),
            true = RunId =:= Active orelse throw(stale_generation);
        _ -> ok
    end,
    CurrentWork = snapshot_work_id(View),
    true = WorkId =:= CurrentWork orelse throw(stale_generation),
    true = Deadline > Now orelse throw(invalid_schema),
    true = Deadline - Now =< ?TTL_MS orelse throw(invalid_schema),
    Body = payload_body(Kind, Payload),
    Canon = iolist_to_binary(json:encode(Doc)),
    case maps:find(OpId, maps:get(by_id, State)) of
        {ok, Existing} ->
            case maps:get(canon, Existing) =:= Canon of
                true -> {ok, public(Existing), duplicate, State};
                false -> throw(conflict)
            end;
        error ->
            true = byte_size(Body) =< ?MAX_TEXT orelse throw(envelope),
            ContentId = content_uuid(OpId),
            true = content_get_size(OpId, ContentId, Body) =< ?CONTENT_GET
                orelse throw(envelope),
            admit_new(Kind, AgentId, Digest, Now, byte_size(Body), State),
            Expires = min(Deadline, Now + ?TTL_MS),
            Op = #{
                id => OpId, kind => Kind, agent_id => AgentId,
                session_id => maps:get(<<"sessionId">>, Binding),
                binding_id => BindingId, runtime => Runtime,
                session_gen => SessionGen, branch => Branch,
                run_id => RunId, work_id => WorkId,
                digest => Digest, canon => Canon, body => Body,
                content_id => ContentId, state => <<"queued">>,
                offered => false, unsupported_withdrawal => false,
                fragments => #{}, frag_count => undefined, assembled => undefined,
                page_digest => undefined,
                created => Now, deadline => Deadline, expires => Expires,
                notes => notes(Kind)
            },
            {ok, public(Op), created, put_op(Op, State)}
    end.

admit_new(Kind, AgentId, Digest, _Now, BodyBytes, State) ->
    By = maps:get(by_id, State),
    true = map_size(By) < ?MAX_OPS orelse throw(capacity),
    Live = [Op || Op <- maps:values(By), not terminal(maps:get(state, Op))],
    Sess = [Op || Op <- Live, maps:get(digest, Op) =:= Digest],
    true = length(Sess) < ?OUT_SESSION orelse throw(capacity),
    AgentLive = [Op || Op <- Live, maps:get(agent_id, Op) =:= AgentId],
    case Kind of
        <<"sessionRead">> ->
            Traversals = [Op || Op <- AgentLive, maps:get(kind, Op) =:= <<"sessionRead">>],
            true = Traversals =:= [] orelse throw(capacity);
        <<"notice">> ->
            Notices = [Op || Op <- AgentLive, maps:get(kind, Op) =:= <<"notice">>],
            true = length(Notices) < ?MAX_NOTICES orelse throw(capacity);
        _ ->
            Mut = [Op || Op <- AgentLive, mutating(maps:get(kind, Op))],
            true = Mut =:= [] orelse throw(capacity)
    end,
    true = maps:get(bytes, State) + BodyBytes =< ?STAGE_BYTES orelse throw(capacity),
    ok.

poll(AgentId, CurrentWorkId, Now, State) ->
    Ops = [Op || Op <- maps:values(maps:get(by_id, State)),
        maps:get(agent_id, Op) =:= AgentId,
        maps:get(state, Op) =:= <<"queued">>,
        maps:get(expires, Op) > Now,
        maps:get(work_id, Op) =:= CurrentWorkId],
    Sorted = lists:sort(fun(A, B) -> maps:get(created, A) =< maps:get(created, B) end, Ops),
    take_desc(Sorted, 0, 0, []).

take_desc([], _, _, Acc) -> lists:reverse(Acc);
take_desc(_, N, _, Acc) when N >= ?DESC -> lists:reverse(Acc);
take_desc([Op | Rest], N, Bytes, Acc) ->
    Desc = descriptor(Op),
    Enc = iolist_to_binary(json:encode(Desc)),
    case byte_size(Enc) > ?DESC_EACH orelse Bytes + byte_size(Enc) > ?DESC_TOTAL of
        true -> lists:reverse(Acc);
        false -> take_desc(Rest, N + 1, Bytes + byte_size(Enc), [Desc | Acc])
    end.

descriptor(Op) ->
    #{
        <<"schemaVersion">> => 1,
        <<"operationId">> => maps:get(id, Op),
        <<"kind">> => maps:get(kind, Op),
        <<"agentId">> => maps:get(agent_id, Op),
        <<"sessionId">> => maps:get(session_id, Op),
        <<"bindingId">> => maps:get(binding_id, Op),
        <<"runtimeGeneration">> => integer_to_binary(maps:get(runtime, Op)),
        <<"sessionGeneration">> => integer_to_binary(maps:get(session_gen, Op)),
        <<"branchId">> => maps:get(branch, Op),
        <<"runId">> => maps:get(run_id, Op),
        <<"workId">> => maps:get(work_id, Op),
        <<"deadline">> => integer_to_binary(maps:get(deadline, Op)),
        <<"content">> => #{
            <<"encoding">> => <<"handle">>,
            <<"contentId">> => maps:get(content_id, Op),
            <<"bytes">> => integer_to_binary(byte_size(maps:get(body, Op)))
        }
    }.

result1(Doc, View, Now, State) ->
    OpId = uuid(maps:get(<<"operationId">>, Doc)),
    AgentId = uuid(maps:get(<<"agentId">>, Doc)),
    BindingId = uuid(maps:get(<<"bindingId">>, Doc)),
    Runtime = uint(maps:get(<<"runtimeGeneration">>, Doc)),
    SessionGen = uint(maps:get(<<"sessionGeneration">>, Doc)),
    Kind = maps:get(<<"kind">>, Doc),
    Binding = maps:get(binding, View),
    case maps:find(OpId, maps:get(by_id, State)) of
        error -> throw(not_found);
        {ok, Op} ->
            true = maps:get(expires, Op) > Now orelse throw(expired),
            admit_native(Kind, #{agent => AgentId, binding => BindingId,
                runtime => Runtime, session => SessionGen}, View, Binding, Op),
            apply_result(Kind, Doc, Op, Now, State)
    end.

%% Results record facts only. They never execute or replay the original body.
admit_native(<<"result">>, Ids, _View, Binding, Op) ->
    true = maps:get(agent_id, Op) =:= maps:get(agent, Ids) orelse throw(stale_generation),
    true = maps:get(binding_id, Op) =:= maps:get(binding, Ids) orelse throw(stale_generation),
    true = maps:get(runtime, Op) =:= maps:get(runtime, Ids) orelse throw(stale_generation),
    true = maps:get(session_gen, Op) =:= maps:get(session, Ids) orelse throw(stale_generation),
    true = maps:get(<<"agentId">>, Binding) =:= maps:get(agent_id, Op)
        orelse throw(stale_generation),
    true = binary_to_integer(maps:get(<<"runtimeGeneration">>, Binding))
        =:= maps:get(runtime, Op) orelse throw(stale_generation),
    ok;
admit_native(Kind, Ids, View, Binding, Op)
  when Kind =:= <<"receipt">>; Kind =:= <<"fragment">> ->
    true = maps:get(<<"agentId">>, Binding) =:= maps:get(agent, Ids)
        orelse throw(stale_generation),
    true = maps:get(<<"bindingId">>, Binding) =:= maps:get(binding, Ids)
        orelse throw(stale_generation),
    true = binary_to_integer(maps:get(<<"runtimeGeneration">>, Binding))
        =:= maps:get(runtime, Ids) orelse throw(stale_generation),
    true = binary_to_integer(maps:get(<<"sessionGeneration">>, Binding))
        =:= maps:get(session, Ids) orelse throw(stale_generation),
    true = maps:get(agent_id, Op) =:= maps:get(agent, Ids) orelse throw(stale_generation),
    true = maps:get(binding_id, Op) =:= maps:get(binding, Ids) orelse throw(stale_generation),
    true = maps:get(runtime, Op) =:= maps:get(runtime, Ids) orelse throw(stale_generation),
    true = maps:get(session_gen, Op) =:= maps:get(session, Ids) orelse throw(stale_generation),
    Perms = maps:get(permissions, View),
    true = maps:get(perm_of(maps:get(kind, Op)), Perms) =:= true orelse throw(forbidden),
    case Kind of
        <<"fragment">> ->
            true = maps:get(<<"content">>, Perms) =:= true orelse throw(forbidden),
            ok;
        _ -> ok
    end;
admit_native(_, _, _, _, _) -> throw(invalid_schema).

apply_result(<<"receipt">>, Doc, Op, Now, State) ->
    Status = maps:get(<<"status">>, Doc),
    Next = case {maps:get(state, Op), Status} of
        {<<"queued">>, <<"received">>} -> offer(Op, received_state(Op), Now);
        {<<"queued">>, <<"rejected">>} -> offer(Op, <<"rejected">>, Now);
        {State, Status} when State =:= <<"received">>; State =:= <<"context_reserved">>;
                State =:= <<"accepted">>; State =:= <<"assembling">> -> Op;
        {<<"rejected">>, <<"rejected">>} -> Op;
        _ -> throw(conflict)
    end,
    {ok, ack(Next), maps:get(state, Op) =/= maps:get(state, Next), put_op(Next, State)};
apply_result(<<"result">>, Doc, Op, Now, State) ->
    Status = maps:get(<<"status">>, Doc),
    Allowed = result_states(maps:get(kind, Op)),
    true = lists:member(Status, Allowed) orelse throw(invalid_schema),
    true = maps:get(offered, Op) orelse maps:get(state, Op) =/= <<"queued">>
        orelse throw(conflict),
    case Status of
        <<"settled">> ->
            true = maps:get(state, Op) =:= <<"abort_requested">> orelse throw(conflict);
        _ -> ok
    end,
    Next = case maps:get(state, Op) of
        S when S =:= <<"cancelled">>; S =:= <<"expired">> -> throw(conflict);
        _ -> Op#{state := Status, expires := max(maps:get(deadline, Op), Now)}
    end,
    {ok, ack(Next), maps:get(state, Op) =/= maps:get(state, Next), put_op(Next, State)};
apply_result(<<"fragment">>, Doc, Op, Now, State) ->
    true = maps:get(kind, Op) =:= <<"sessionRead">> orelse throw(invalid_schema),
    case maps:get(state, Op) of
        <<"assembling">> -> fragment_assembling(Doc, Op, Now, State);
        <<"completed">> -> fragment_completed(Doc, Op, State);
        S when S =:= <<"cancelled">>; S =:= <<"expired">> ->
            {ok, ack(Op), false, State};
        _ -> throw(conflict)
    end;
apply_result(_, _, _, _, _) -> throw(invalid_schema).

received_state(#{kind := <<"sessionRead">>}) -> <<"assembling">>;
received_state(#{kind := <<"notice">>}) -> <<"received">>;
received_state(_) -> <<"accepted">>.

mutating(<<"sessionRead">>) -> false;
mutating(<<"notice">>) -> false;
mutating(_) -> true.

result_states(<<"notice">>) -> [<<"attempted">>, <<"observed">>, <<"context_reserved">>, <<"unknown">>];
result_states(<<"workAssign">>) -> [<<"work_assigned">>, <<"unknown">>];
result_states(<<"work">>) -> [<<"attempted">>, <<"observed">>, <<"unknown">>];
result_states(<<"guidance">>) -> [<<"attempted">>, <<"observed">>, <<"unknown">>];
result_states(<<"label">>) -> [<<"labelled">>, <<"unknown">>];
result_states(<<"interrupt">>) -> [<<"abort_requested">>, <<"settled">>, <<"unknown">>];
result_states(<<"sessionRead">>) -> [<<"completed">>, <<"unknown">>];
result_states(_) -> [].

fragment_assembling(Doc, Op, Now, State) ->
    Index = int_field(maps:get(<<"index">>, Doc)),
    Count = int_field(maps:get(<<"count">>, Doc)),
    Data = maps:get(<<"data">>, Doc),
    true = is_binary(Data) orelse throw(invalid_schema),
    true = Count >= 1 andalso Count =< ?FRAG orelse throw(invalid_schema),
    true = Index >= 0 andalso Index < Count orelse throw(invalid_schema),
    Raw = b64(Data),
    true = byte_size(Raw) =< ?FRAG_RAW orelse throw(envelope),
    Frags0 = maps:get(fragments, Op),
    Count0 = maps:get(frag_count, Op),
    true = Count0 =:= undefined orelse Count0 =:= Count orelse throw(conflict),
    case maps:find(Index, Frags0) of
        {ok, Raw} -> {ok, ack(Op), false, State};
        {ok, _} -> throw(conflict);
        error ->
            Frags1 = Frags0#{Index => Raw},
            Staged = maps:get(bytes, State) - frag_bytes(Frags0) + frag_bytes(Frags1),
            true = Staged =< ?STAGE_BYTES orelse throw(capacity),
            Op1 = Op#{fragments := Frags1, frag_count := Count},
            Op2 = case map_size(Frags1) =:= Count of
                false -> Op1;
                true -> assemble(Op1, Doc, Now)
            end,
            Changed = maps:get(state, Op) =/= maps:get(state, Op2),
            {ok, ack(Op2), Changed, put_op(Op2, State#{bytes := Staged})}
    end.

fragment_completed(Doc, Op, State) ->
    Stored = maps:get(page_digest, Op, undefined),
    Expect = maps:get(<<"digest">>, Doc, undefined),
    case is_binary(Stored) andalso is_binary(Expect)
            andalso string:lowercase(Expect) =:= Stored of
        true -> {ok, ack(Op), false, State};
        false -> throw(conflict)
    end.

offer(Op, StateName, Now) ->
    Op#{state := StateName, offered := true, expires := Now + ?TTL_MS}.

assemble(Op, Doc, Now) ->
    Count = maps:get(frag_count, Op),
    Parts = [maps:get(I, maps:get(fragments, Op)) || I <- lists:seq(0, Count - 1)],
    Bin = iolist_to_binary(Parts),
    true = byte_size(Bin) =< ?PAGE_BYTES orelse throw(envelope),
    Expect = maps:get(<<"digest">>, Doc, undefined),
    case Expect of
        undefined -> throw(invalid_schema);
        Hex when is_binary(Hex) ->
            Got = string:lowercase(binary:encode_hex(crypto:hash(sha256, Bin))),
            true = string:lowercase(Hex) =:= Got orelse throw(conflict);
        _ -> throw(invalid_schema)
    end,
    Page = case bus_protocol:decode_json(Bin) of
        {ok, Map} when is_map(Map) -> decode_page(Map);
        _ -> throw(invalid_schema)
    end,
    Digest = string:lowercase(maps:get(<<"digest">>, Doc)),
    Op#{assembled := Page, state := <<"completed">>,
        expires := max(maps:get(deadline, Op), Now), fragments := #{},
        page_digest := Digest}.

decode_page(Map) ->
    check_keys(Map, ?PAGE_KEYS),
    1 = maps:get(<<"schemaVersion">>, Map),
    _ = uuid(maps:get(<<"sessionId">>, Map)),
    Leaf = maps:get(<<"leafId">>, Map),
    true = Leaf =:= null orelse is_binary(Leaf) orelse throw(invalid_schema),
    Next = maps:get(<<"nextLeafId">>, Map),
    true = Next =:= null orelse is_binary(Next) orelse throw(invalid_schema),
    Omitted = maps:get(<<"omitted">>, Map),
    true = is_integer(Omitted) andalso Omitted >= 0 andalso Omitted =< 2048
        orelse throw(invalid_schema),
    true = is_boolean(maps:get(<<"truncated">>, Map)) orelse throw(invalid_schema),
    Recs = maps:get(<<"records">>, Map),
    true = is_list(Recs) andalso length(Recs) =< ?PAGE_RECORDS orelse throw(envelope),
    lists:foreach(fun decode_record/1, Recs),
    Map.

decode_record(Map) when is_map(Map) ->
    check_keys(Map, ?RECORD_KEYS),
    Entry = maps:get(<<"entryId">>, Map),
    true = is_binary(Entry) andalso byte_size(Entry) >= 1
        andalso byte_size(Entry) =< 128 orelse throw(invalid_schema),
    Role = maps:get(<<"role">>, Map),
    true = lists:member(Role, ?ROLES) orelse throw(invalid_schema),
    Text = maps:get(<<"text">>, Map),
    true = is_binary(Text) andalso byte_size(Text) =< ?MAX_TEXT
        andalso utf8(Text) orelse throw(invalid_schema),
    ok;
decode_record(_) -> throw(invalid_schema).

cancel1(Op, Now, State) ->
    case maps:get(state, Op) of
        <<"queued">> ->
            Next = Op#{state := <<"cancelled">>, expires := Now + ?TOMB_MS,
                       fragments := #{}, assembled := undefined,
                       page_digest => undefined, offered := false},
            {ok, public(Next), true, put_op(Next, State)};
        <<"assembling">> ->
            Next = Op#{state := <<"cancelled">>, expires := Now + ?TOMB_MS,
                       fragments := #{}, assembled := undefined,
                       page_digest => undefined, offered := false,
                       unsupported_withdrawal := false},
            {ok, public(Next), true, put_op(Next, State)};
        S when S =:= <<"cancelled">>; S =:= <<"expired">> ->
            {ok, public(Op), false, State};
        _ ->
            Was = maps:get(unsupported_withdrawal, Op),
            Next = Op#{unsupported_withdrawal := true},
            {ok, public(Next), Was =:= false, put_op(Next, State)}
    end.

expire_one(Now, Id, Op, State) ->
    Created = maps:get(created, Op),
    Deadline = maps:get(deadline, Op),
    case Now < Created of
        true -> {State, []};
        false ->
            case terminal(maps:get(state, Op)) of
                true when Now > Deadline -> {drop_op(Id, Op, State), []};
                true -> {State, []};
                false ->
                    case maps:get(expires, Op) =< Now orelse Deadline =< Now of
                        true ->
                            Next = Op#{state := <<"expired">>, fragments := #{},
                                       assembled := undefined, page_digest => undefined,
                                       offered := false, expires := Deadline},
                            {put_op(Next, State), [public(Next)]};
                        false -> {State, []}
                    end
            end
    end.

terminal(<<"rejected">>) -> true;
terminal(<<"cancelled">>) -> true;
terminal(<<"expired">>) -> true;
terminal(<<"completed">>) -> true;
terminal(<<"labelled">>) -> true;
terminal(<<"abort_requested">>) -> false;
terminal(<<"settled">>) -> true;
terminal(<<"context_reserved">>) -> false;
terminal(<<"attempted">>) -> true;
terminal(<<"observed">>) -> true;
terminal(<<"unknown">>) -> true;
terminal(<<"received">>) -> true;
terminal(<<"work_assigned">>) -> true;
terminal(_) -> false.

put_op(Op, #{by_id := By, by_agent := Agents, bytes := Bytes} = State) ->
    Id = maps:get(id, Op),
    AgentId = maps:get(agent_id, Op),
    Old = maps:get(Id, By, undefined),
    OldB = case Old of undefined -> 0; _ -> op_bytes(Old) end,
    NewB = op_bytes(Op),
    Set0 = maps:get(AgentId, Agents, []),
    Set1 = [Id | lists:delete(Id, Set0)],
    State#{by_id := By#{Id => Op}, by_agent := Agents#{AgentId => Set1},
           bytes := Bytes - OldB + NewB}.

drop_op(Id, Op, #{by_id := By, by_agent := Agents, bytes := Bytes} = State) ->
    AgentId = maps:get(agent_id, Op),
    Set = lists:delete(Id, maps:get(AgentId, Agents, [])),
    Agents1 = case Set of [] -> maps:remove(AgentId, Agents); _ -> Agents#{AgentId => Set} end,
    State#{by_id := maps:remove(Id, By), by_agent := Agents1,
           bytes := Bytes - op_bytes(Op)}.

op_bytes(Op) ->
    byte_size(maps:get(body, Op)) + frag_bytes(maps:get(fragments, Op))
        + iolist_size(json:encode(public(Op))).

frag_bytes(Map) ->
    maps:fold(fun(_, B, Acc) -> Acc + byte_size(B) end, 0, Map).

public(Op) ->
    #{
        <<"schemaVersion">> => 1,
        <<"operationId">> => maps:get(id, Op),
        <<"kind">> => maps:get(kind, Op),
        <<"agentId">> => maps:get(agent_id, Op),
        <<"sessionId">> => maps:get(session_id, Op),
        <<"bindingId">> => maps:get(binding_id, Op),
        <<"runtimeGeneration">> => integer_to_binary(maps:get(runtime, Op)),
        <<"sessionGeneration">> => integer_to_binary(maps:get(session_gen, Op)),
        <<"branchId">> => maps:get(branch, Op),
        <<"runId">> => maps:get(run_id, Op),
        <<"workId">> => maps:get(work_id, Op),
        <<"state">> => maps:get(state, Op),
        <<"createdAt">> => integer_to_binary(maps:get(created, Op)),
        <<"deadline">> => integer_to_binary(maps:get(deadline, Op)),
        <<"expiresAt">> => integer_to_binary(maps:get(expires, Op)),
        <<"unsupportedWithdrawal">> => maps:get(unsupported_withdrawal, Op),
        <<"unsupported">> => maps:get(notes, Op),
        <<"page">> => case {maps:get(kind, Op), maps:get(state, Op), maps:get(assembled, Op)} of
            {<<"sessionRead">>, <<"completed">>, Page} when is_map(Page) -> Page;
            _ -> null
        end
    }.

ack(Op) ->
    #{<<"schemaVersion">> => 1,
      <<"operationId">> => maps:get(id, Op),
      <<"state">> => maps:get(state, Op)}.

notes(<<"notice">>) ->
    [<<"message_starts_or_steers">>, <<"attempted_not_consumed">>,
     <<"no_auto_resend">>];
notes(<<"work">>) ->
    [<<"work_request_not_run_start_proof">>, <<"attempted_not_queued">>, <<"sdk_void_not_queued">>];
notes(<<"guidance">>) ->
    [<<"sdk_void_not_queued">>, <<"attempted_not_consumed">>, <<"no_auto_resend">>];
notes(<<"label">>) ->
    [<<"label_requires_client_ack">>, <<"presence_observed_separately">>];
notes(<<"interrupt">>) ->
    [<<"interrupt_not_process_kill">>, <<"no_rollback">>, <<"no_causal_rollback">>, <<"no_message_withdrawal">>, <<"settled_not_rollback">>];
notes(<<"sessionRead">>) ->
    [<<"current_session_only">>, <<"no_compaction_reconstruction">>,
     <<"no_filesystem_paths">>, <<"cancel_drops_assembly_only">>];
notes(<<"workAssign">>) ->
    [<<"typed_metadata_only">>, <<"client_applies_assignment">>,
     <<"not_run_start_proof">>].

payload_body(<<"notice">>, Map) -> text_payload(Map, <<"text">>, ?MAX_TEXT);
payload_body(<<"work">>, Map) -> text_payload(Map, <<"text">>, ?MAX_TEXT);
payload_body(<<"guidance">>, Map) -> text_payload(Map, <<"text">>, ?MAX_TEXT);
payload_body(<<"label">>, Map) ->
    check_keys(Map, [<<"label">>]),
    label_text(maps:get(<<"label">>, Map));
payload_body(<<"interrupt">>, Map) ->
    check_keys(Map, [<<"reason">>]),
    case maps:get(<<"reason">>, Map) of
        null -> <<>>;
        Bin -> bounded_text(Bin, ?MAX_REASON)
    end;
payload_body(<<"workAssign">>, Map) ->
    check_keys(Map, [<<"work">>]),
    case bus_operator_work:decode(maps:get(<<"work">>, Map)) of
        {ok, Canonical} ->
            case bus_operator_work:encode(Canonical) of
                {ok, Bin} -> Bin;
                {error, envelope} -> throw(envelope);
                _ -> throw(invalid_schema)
            end;
        {error, envelope} -> throw(envelope);
        _ -> throw(invalid_schema)
    end;
payload_body(<<"sessionRead">>, Map) ->
    check_keys(Map, [<<"leafId">>, <<"limit">>]),
    Leaf = case maps:get(<<"leafId">>, Map) of
        null -> null;
        Bin when is_binary(Bin), byte_size(Bin) >= 1, byte_size(Bin) =< ?MAX_HANDLE ->
            true = re:run(Bin, <<"^[A-Za-z0-9._-]+$">>, [{capture, none}]) =:= match
                orelse throw(invalid_schema),
            Bin;
        _ -> throw(invalid_schema)
    end,
    Limit = uint(maps:get(<<"limit">>, Map)),
    true = Limit >= 1 andalso Limit =< ?PAGE_RECORDS orelse throw(invalid_schema),
    iolist_to_binary(json:encode(#{<<"leafId">> => Leaf, <<"limit">> => Limit}));
payload_body(_, _) -> throw(invalid_schema).

text_payload(Map, Key, Max) ->
    check_keys(Map, [Key]),
    bounded_text(maps:get(Key, Map), Max).

bounded_text(Bin, Max) when is_binary(Bin), byte_size(Bin) >= 1, byte_size(Bin) =< Max ->
    true = utf8(Bin) orelse throw(invalid_schema),
    Bin;
bounded_text(_, _) -> throw(invalid_schema).

label_text(Bin) when is_binary(Bin) ->
    Trimmed = string:trim(Bin),
    true = byte_size(Trimmed) > 0 orelse throw(invalid_schema),
    true = byte_size(Trimmed) =< ?MAX_LABEL_UTF8 orelse throw(envelope),
    true = utf8(Trimmed) orelse throw(invalid_schema),
    List = unicode:characters_to_list(Trimmed),
    true = is_list(List) orelse throw(invalid_schema),
    true = length(List) =< ?MAX_LABEL orelse throw(invalid_schema),
    true = lists:all(fun(C) -> C >= 32 andalso (C < 127 orelse C > 159) end, List)
        orelse throw(invalid_schema),
    true = binary:match(Trimmed, [<<"\n">>, <<"\r">>, <<16#2028/utf8>>, <<16#2029/utf8>>]) =:= nomatch
        orelse throw(invalid_schema),
    Trimmed;
label_text(_) -> throw(invalid_schema).

kind(K) ->
    case lists:member(K, ?KINDS) of true -> K; false -> throw(invalid_schema) end.

cap_of(<<"notice">>) -> <<"notice.receive.v1">>;
cap_of(<<"work">>) -> <<"work.enqueue.v1">>;
cap_of(<<"guidance">>) -> <<"guidance.attempt.v1">>;
cap_of(<<"label">>) -> <<"label.set.v1">>;
cap_of(<<"interrupt">>) -> <<"run.interrupt.active.v1">>;
cap_of(<<"sessionRead">>) -> <<"session.current.read.v1">>;
cap_of(<<"workAssign">>) -> <<"work.assign.v1">>.

perm_of(<<"notice">>) -> <<"notice">>;
perm_of(<<"work">>) -> <<"work">>;
perm_of(<<"guidance">>) -> <<"guidance">>;
perm_of(<<"label">>) -> <<"label">>;
perm_of(<<"interrupt">>) -> <<"interrupt">>;
perm_of(<<"sessionRead">>) -> <<"sessionRead">>;
perm_of(<<"workAssign">>) -> <<"workAssign">>.

check_keys(Map, Required) when is_map(Map) ->
    Keys = maps:keys(Map),
    case {Required -- Keys, Keys -- Required} of
        {[], []} -> ok;
        _ -> throw(invalid_schema)
    end;
check_keys(_, _) -> throw(invalid_schema).

content_get_size(OpId, ContentId, Body) ->
    iolist_size(json:encode(#{
        <<"schemaVersion">> => 1,
        <<"operationId">> => OpId,
        <<"contentId">> => ContentId,
        <<"body">> => Body
    })).

uuid_opt(null) -> null;
uuid_opt(Id) -> uuid(Id).

snapshot_work_id(#{work := Work}) when is_map(Work) ->
    maps:get(<<"workId">>, Work, null);
snapshot_work_id(_) -> null.

uuid(Id) ->
    case bus_protocol:is_uuid(Id) of
        true -> Id;
        false -> throw(invalid_schema)
    end.

uint(Bin) when is_binary(Bin) ->
    case re:run(Bin, <<"^(0|[1-9][0-9]{0,19})$">>, [{capture, none}]) of
        match ->
            N = binary_to_integer(Bin),
            case N =< ?MAX_UINT of true -> N; false -> throw(invalid_schema) end;
        nomatch -> throw(invalid_schema)
    end;
uint(_) -> throw(invalid_schema).

int_field(N) when is_integer(N), N >= 0 -> N;
int_field(Bin) when is_binary(Bin) -> uint(Bin);
int_field(_) -> throw(invalid_schema).

branch(null) -> null;
branch(Bin) when is_binary(Bin), byte_size(Bin) >= 1, byte_size(Bin) =< 128 ->
    case re:run(Bin, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}]) of
        match -> Bin;
        nomatch -> throw(invalid_schema)
    end;
branch(_) -> throw(invalid_schema).

utf8(Bin) ->
    try unicode:characters_to_binary(Bin, utf8, utf8) of
        Bin -> true;
        _ -> false
    catch _:_ -> false
    end.

b64(Bin) ->
    try base64:decode(Bin) of
        Raw when is_binary(Raw) -> Raw;
        _ -> throw(invalid_schema)
    catch _:_ -> throw(invalid_schema)
    end.

content_uuid(OpId) ->
    <<A:32, B:16, _:4, C:12, _:2, E:14, F:48, _/binary>> = crypto:hash(sha256, OpId),
    iolist_to_binary(io_lib:format(
        "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
        [A, B, C bor 16#4000, E bor 16#8000, F])).
