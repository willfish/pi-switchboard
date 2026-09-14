-module(bus_store_tests).
-include_lib("eunit/include/eunit.hrl").

subscription_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun(_) -> fun replaced_pull/0 end,
        fun(_) -> fun wrong_caller/0 end,
        fun(_) -> fun empty_pull_rearms/0 end,
        fun(_) -> fun stale_ack/0 end,
        fun(_) -> fun presence_pull_rearms/0 end,
        fun(_) -> fun heartbeat_is_quiet/0 end,
        fun(_) -> fun meaningful_changes/0 end,
        fun(_) -> fun subscriber_down/0 end,
        fun(_) -> fun readiness_changes/0 end,
        fun(_) -> fun discovery_progress/0 end
    ]}.

discovery_progress() ->
    DL = erlang:monotonic_time(millisecond)+5000,
    {ok,B} = bus_store:list_agents_page(first,DL),
    Doc = json:decode(B),
    ok = bus_store:put_agent(agent(<<"a">>)),
    {ok,B2} = bus_store:list_agents_page(first,DL),
    ?assertEqual(Doc,json:decode(B2)),
    {ok,Ref} = bus_store:subscribe(<<"b">>,self()),
    expect_wake(Ref,presence),
    {frame,<<"presence_snapshot">>,S,true} = bus_store:pull_presence(<<"b">>,Ref,DL),
    ?assertEqual(true,maps:get(<<"final">>,json:decode(S))),
    ?assertEqual(true,flag(presence_wake)),
    {frame,<<"presence_delta">>,Equal,false} = bus_store:pull_presence(<<"b">>,Ref,DL),
    ?assertEqual([],maps:get(<<"changes">>,json:decode(Equal))),
    ?assertEqual(false,flag(presence_wake)),
    State = sys:get_state(bus_store),
    #{progress := {delta,Rev,false}} = maps:get(<<"b">>,maps:get(subs,State)),
    ?assert(is_integer(Rev)),
    ok = bus_store:put_agent((agent(<<"a">>))#{<<"label">> := <<"later">>}),
    expect_wake(Ref,presence),
    {frame,<<"presence_delta">>,Delta,false} = bus_store:pull_presence(<<"b">>,Ref,DL),
    [#{<<"op">> := <<"upsert">>, <<"agent">> := #{<<"label">> := <<"later">>}}] = maps:get(<<"changes">>,json:decode(Delta)),
    ?assertEqual(empty,bus_store:pull_presence(<<"b">>,Ref,DL)),
    Before = maps:get(revision,maps:get(discovery,sys:get_state(bus_store))),
    {ok,Ref2} = bus_store:subscribe(<<"b">>,self()),
    ?assertEqual(Before,maps:get(revision,maps:get(discovery,sys:get_state(bus_store)))),
    ?assertEqual({error,stale_subscription},bus_store:pull_presence(<<"b">>,Ref,DL)),
    ?assertMatch({frame,<<"presence_snapshot">>,_,true},bus_store:pull_presence(<<"b">>,Ref2,DL)).

captured_clock_once_test() ->
    {State,Ref,Mon} = boundary_state(),
    try
        lists:foreach(fun(Op) ->
            1 = erlang:trace_pattern({bus_store,mono,0},true,[call_count]),
            1 = erlang:trace_pattern({bus_store,wall,0},true,[call_count]),
            try
                _ = bus_store:handle_call({op,deadline_ms(),Op},{self(),tag},State),
                ?assertEqual({call_count,1},erlang:trace_info({bus_store,mono,0},call_count)),
                ?assertEqual({call_count,1},erlang:trace_info({bus_store,wall,0},call_count))
            after
                erlang:trace_pattern({bus_store,mono,0},false,[call_count]),
                erlang:trace_pattern({bus_store,wall,0},false,[call_count])
            end
        end,[{put_agent,agent(<<"b">>)},{delete_agent,<<"b">>}, list_agents,
            {accept_mail,mail()},{subscribe,<<"b">>,self()},
            {list_agents_page,first},{subscription,<<"b">>,Ref,pull_presence},
            {subscription,<<"b">>,Ref,pop_mail}]),
        lists:foreach(fun(Callback) ->
            1 = erlang:trace_pattern({bus_store,mono,0},true,[call_count]),
            1 = erlang:trace_pattern({bus_store,wall,0},true,[call_count]),
            try
                _ = Callback(),
                ?assertEqual({call_count,1},erlang:trace_info({bus_store,mono,0},call_count)),
                ?assertEqual({call_count,1},erlang:trace_info({bus_store,wall,0},call_count))
            after
                erlang:trace_pattern({bus_store,mono,0},false,[call_count]),
                erlang:trace_pattern({bus_store,wall,0},false,[call_count])
            end
        end,[fun() -> bus_store:handle_cast({unsubscribe,<<"b">>,Ref},State) end,
            fun() -> bus_store:handle_info({'DOWN',Mon,process,self(),normal},State) end,
            fun() -> bus_store:handle_info(expire,State) end])
    after demonitor(Mon,[flush]), flush() end.

put_clock_boundary_test() ->
    {State,Ref,Mon} = boundary_state(),
    try
        {reply,ok,Before} = at({put_agent,agent(<<"b">>)},State,114),
        ModelBefore = maps:get(model,Before),
        ?assertEqual(Ref,maps:get(ref,maps:get(<<"b">>,maps:get(subs,Before)))),
        ?assert(maps:is_key(<<"b">>,maps:get(receiving,ModelBefore))),
        ?assertEqual(maps:get(mail,maps:get(model,State)),maps:get(mail,ModelBefore)),
        ?assertEqual(maps:get(queued_bytes,maps:get(model,State)),maps:get(queued_bytes,ModelBefore)),
        ?assertEqual(revision(State),revision(Before)),
        %% The same input lease, evaluated exactly at expiry, is a removal
        %% followed by a fresh join, never a retained old receive reference.
        {reply,ok,After} = at({put_agent,agent(<<"b">>)},State,115),
        ModelAfter = maps:get(model,After),
        ?assertNot(maps:is_key(<<"b">>,maps:get(subs,After))),
        ?assertNot(maps:is_key(<<"b">>,maps:get(receiving,ModelAfter))),
        ?assertEqual(#{},maps:get(mail,ModelAfter)),
        ?assertEqual(0,maps:get(queued_bytes,ModelAfter)),
        ?assertEqual(revision(State)+2,revision(After)),
        #{last_mono := 115,last_wall := 1115} = maps:get(<<"b">>,maps:get(agents,ModelAfter)),
        Changes = maps:values(maps:get(journal_index,maps:get(discovery,After))),
        ?assertEqual([115,115],[T || {_,T,_,_} <- Changes]),
        ?assertEqual(maps:get(dedup,maps:get(model,State)),maps:get(dedup,ModelAfter)),
        expect_wake(Ref,replaced)
    after demonitor(Mon,[flush]), flush() end.

delete_clock_boundary_test() ->
    lists:foreach(fun(Now) ->
        {State,Ref,Mon} = boundary_state(),
        try
            {reply,{ok,OldPage},Cached} = at({list_agents_page,first},State,114),
            {reply,ok,Deleted} = at({delete_agent,<<"b">>},Cached,Now),
            ?assertEqual(revision(Cached)+1,revision(Deleted)),
            ?assertNot(maps:is_key(<<"b">>,maps:get(subs,Deleted))),
            expect_wake(Ref,replaced),
            {reply,{ok,NewPage},_} = at({list_agents_page,first},Deleted,115),
            Old = json:decode(OldPage), New = json:decode(NewPage),
            ?assertEqual(1114,maps:get(<<"capturedAt">>,Old)),
            ?assertEqual(1115,maps:get(<<"capturedAt">>,New)),
            ?assert(maps:get(<<"snapshotId">>,Old) =/= maps:get(<<"snapshotId">>,New)),
            ?assertEqual([<<"a">>],[maps:get(<<"agentId">>,A) || A <- maps:get(<<"agents">>,New)])
        after demonitor(Mon,[flush]), flush() end
    end,[114,115]).

operation_clock_does_not_extend_deadline_test() ->
    {State,_,Mon} = boundary_state(),
    try
        {reply,{error,timeout},Next} = bus_store:handle_call_at(
            {op,erlang:monotonic_time(millisecond)-1,{put_agent,agent(<<"b">>)}},
            {self(),tag},State,{114,1114}),
        ?assertEqual(maps:get(model,State),maps:get(model,Next)),
        ?assertEqual(maps:get(subs,State),maps:get(subs,Next)),
        ?assertEqual(revision(State),revision(Next))
    after demonitor(Mon,[flush]), flush() end.

boundary_state() ->
    {ok,M0} = bus_model:put_agent(bus_model:new(),agent(<<"a">>),110,10),
    {ok,M1} = bus_model:put_agent(M0,agent(<<"b">>),100,10),
    M2 = bus_model:set_receiving(M1,<<"b">>,true),
    {ok,Model,_} = bus_model:accept_mail(M2,mail(),114,20),
    Ref = make_ref(), Mon = monitor(process,self()),
    {#{model => Model, discovery => bus_discovery:new(), last_expiry => undefined,
        presence_dispatch => false, subs => #{<<"b">> =>
            #{pid => self(),ref => Ref,mon => Mon,mail_wake => false,presence_wake => false,progress => start}}},Ref,Mon}.

at(Op,State,Mono) ->
    bus_store:handle_call_at({op,deadline_ms(),Op},{self(),tag},State,{Mono,1000+Mono}).

deadline_ms() -> erlang:monotonic_time(millisecond)+5000.
revision(State) -> maps:get(revision,maps:get(discovery,State)).

setup() ->
    {ok, Store} = bus_store:start_link(),
    ok = bus_store:put_agent(agent(<<"a">>)),
    ok = bus_store:put_agent(agent(<<"b">>)),
    Store.

cleanup(Store) ->
    gen_server:stop(Store),
    flush().

replaced_pull() ->
    %% The old subscriber only processes its pull command, leaving replaced queued.
    Old = spawn_link(fun worker/0),
    try
        {ok, OldRef} = bus_store:subscribe(<<"b">>, Old),
        {ok, Ref} = bus_store:subscribe(<<"b">>, self()),
        {ok, _} = bus_store:accept_mail(mail()),
        ?assertEqual({error, stale_subscription}, remote(Old, fun() -> pop(OldRef) end)),
        ?assertMatch({ok, _}, pop(Ref))
    after
        Old ! stop
    end.

wrong_caller() ->
    {ok, Ref} = bus_store:subscribe(<<"b">>, self()),
    Other = spawn_link(fun worker/0),
    try
        {ok, _} = bus_store:accept_mail(mail()),
        Before = sys:get_state(bus_store),
        ?assertEqual({error, stale_subscription}, remote(Other, fun() -> pop(Ref) end)),
        ?assertEqual({error, stale_subscription}, remote(Other, fun() -> presence(Ref) end)),
        ?assertEqual(Before, sys:get_state(bus_store)),
        ?assertMatch({ok, _}, pop(Ref))
    after
        Other ! stop
    end.

empty_pull_rearms() ->
    {ok, Ref} = bus_store:subscribe(<<"b">>, self()),
    expect_wake(Ref, mail),
    ?assertEqual({empty, undefined}, pop(Ref)),
    {ok, _} = bus_store:accept_mail(mail()),
    %% The accept call is a barrier: the wake must already have been sent.
    expect_wake(Ref, mail),
    ?assertMatch({ok, _}, pop(Ref)),
    ?assertEqual({empty, undefined}, pop(Ref)),
    ?assertEqual(false, flag(mail_wake)).

stale_ack() ->
    {ok, OldRef} = bus_store:subscribe(<<"b">>, self()),
    {ok, Ref} = bus_store:subscribe(<<"b">>, self()),
    %% Queued legacy casts must not mutate the replacement's wake flags.
    gen_server:cast(bus_store, {ack_mail, <<"b">>}),
    gen_server:cast(bus_store, {ack_presence, <<"b">>}),
    ?assertEqual(true, flag(mail_wake)),
    ?assertEqual(true, flag(presence_wake)),
    ?assertEqual({error, stale_subscription}, pop(OldRef)),
    ?assertEqual({error, stale_subscription}, presence(OldRef)),
    ?assertEqual(true, flag(mail_wake)),
    ?assertEqual(true, flag(presence_wake)),
    ?assertMatch({ok, _}, presence(Ref)).

presence_pull_rearms() ->
    {ok, Ref} = bus_store:subscribe(<<"b">>, self()),
    expect_wake(Ref, presence),
    ?assertMatch({ok, [_, _]}, presence(Ref)),
    ?assertEqual(false, flag(presence_wake)),
    ok = bus_store:put_agent((agent(<<"a">>))#{<<"label">> => <<"changed">>}),
    expect_wake(Ref, presence),
    ?assertEqual(true, flag(presence_wake)).

heartbeat_is_quiet() ->
    {ok, Ref} = bus_store:subscribe(<<"b">>, self()),
    expect_wake(Ref, presence),
    {ok, _} = presence(Ref),
    Before = erlang:system_time(second),
    ok = bus_store:put_agent(agent(<<"a">>)),
    After = erlang:system_time(second),
    ?assertEqual(false, flag(presence_wake)),
    receive {bus, Ref, presence} -> ?assert(false) after 0 -> ok end,
    {ok, Agents} = bus_store:list_agents(),
    [A] = [Doc || #{<<"agentId">> := <<"a">>} = Doc <- Agents],
    Updated = maps:get(<<"updatedAt">>, A),
    ?assert(Updated >= Before andalso Updated =< After).

meaningful_changes() ->
    {ok, Ref} = bus_store:subscribe(<<"b">>, self()),
    expect_wake(Ref, presence),
    lists:foldl(fun({Key, Value}, Agent) ->
        {ok, _} = presence(Ref),
        Changed = Agent#{Key => Value},
        ok = bus_store:put_agent(Changed),
        expect_wake(Ref, presence),
        ?assertEqual(true, flag(presence_wake)),
        Changed
    end, agent(<<"a">>), [
        {<<"model">>, #{<<"provider">> => <<"test">>, <<"id">> => <<"new">>}},
        {<<"label">>, <<"new">>},
        {<<"status">>, <<"working">>},
        {<<"acceptsControl">>, true}
    ]).

readiness_changes() ->
    {ok, Ref} = bus_store:subscribe(<<"b">>, self()),
    expect_wake(Ref, presence),
    {ok, _} = presence(Ref),
    {ok, ARef} = bus_store:subscribe(<<"a">>, self()),
    expect_wake(Ref, presence),
    {ok, Ready} = presence(Ref),
    ?assert(lists:any(fun(Doc) ->
        maps:get(<<"agentId">>, Doc) =:= <<"a">> andalso maps:get(<<"receiving">>, Doc)
    end, Ready)),
    bus_store:unsubscribe(<<"a">>, ARef),
    {ok, NotReady} = bus_store:list_agents(),
    expect_wake(Ref, presence),
    [A] = [Doc || #{<<"agentId">> := <<"a">>} = Doc <- NotReady],
    ?assertEqual(false, maps:get(<<"receiving">>, A)).

subscriber_down() ->
    {ok, Ref} = bus_store:subscribe(<<"b">>, self()),
    Other = spawn(fun worker/0),
    try
        {ok, OtherRef} = bus_store:subscribe(<<"a">>, Other),
        expect_wake(Ref, presence),
        {ok, _} = presence(Ref),
        %% Signal from the monitored process, then wait for the store's broadcast.
        Other ! stop,
        receive {bus, Ref, presence} -> ok after 1000 -> ?assert(false) end,
        {ok, Agents} = presence(Ref),
        [A] = [Doc || #{<<"agentId">> := <<"a">>} = Doc <- Agents],
        ?assertEqual(false, maps:get(<<"receiving">>, A)),
        ?assertEqual({error, stale_subscription},
            bus_store:pull_presence(<<"a">>, OtherRef))
    after
        exit(Other, kill)
    end.

%% Exercise the real callback with an already-expired model, without sleeps or
%% a clock override in the production server. No registered store is needed.
operation_expiry_test_() ->
    [?_test(expired_operation(Op)) || Op <- [
        {put_agent, agent(<<"b">>)}, list_agents,
        {accept_mail, mail()}, {subscribe, <<"b">>, self()},
        {subscription, <<"b">>, old_ref, pop_mail},
        {subscription, <<"b">>, old_ref, pull_presence},
        {delete_agent, <<"a">>}
    ]].

expired_operation(Op0) ->
    Mono = erlang:monotonic_time(second),
    {ok, M0} = bus_model:put_agent(bus_model:new(), agent(<<"a">>), Mono - 100, 50),
    {ok, M1} = bus_model:put_agent(M0, agent(<<"b">>), Mono - 100, 50),
    M2 = bus_model:set_receiving(M1, <<"b">>, true),
    {ok, M3, Accepted} = bus_model:accept_mail(M2, mail(), Mono - 100, 50),
    Ref = make_ref(),
    Op = case Op0 of
        {subscription, Id, old_ref, Action} -> {subscription, Id, Ref, Action};
        _ -> Op0
    end,
    State = #{model => M3, discovery => bus_discovery:new(), last_expiry => undefined,
        presence_dispatch => false, subs => #{<<"b">> =>
        #{pid => self(), ref => Ref, mon => monitor(process, self()),
          presence_wake => false, mail_wake => false}}},
    Deadline = erlang:monotonic_time(millisecond) + 5000,
    {reply, Reply, Next} = bus_store:handle_call({op, Deadline, Op}, {self(), tag}, State),
    expect_wake(Ref, replaced),
    ?assertEqual(#{}, maps:get(subs, Next)),
    Model = maps:get(model, Next),
    ?assertEqual(#{}, maps:get(mail, Model)),
    ?assertEqual(#{}, maps:get(receiving, Model)),
    ?assertEqual({ok, Model, Accepted}, bus_model:accept_mail(Model, mail(), Mono, 999)),
    case Op of
        {put_agent, _} -> ?assertEqual(ok, Reply), ?assert(bus_model:has_agent(Model, <<"b">>, Mono));
        {accept_mail, _} -> ?assertEqual({ok, Accepted}, Reply);
        {subscribe, _, _} -> ?assertEqual({error, not_found}, Reply);
        {subscription, _, _, _} -> ?assertEqual({error, stale_subscription}, Reply);
        _ -> ok
    end.

deadline_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun(_) -> fun expired_deadlines/0 end,
        fun(_) -> fun suspended_deadlines/0 end,
        fun(_) -> fun unavailable_store/0 end
    ]}.

deadline_ops(Ref) ->
    [{put_agent, (agent(<<"a">>))#{<<"label">> => <<"late">>}},
     {delete_agent, <<"a">>}, {accept_mail, (mail())#{<<"id">> => <<"late">>}},
     {subscribe, <<"b">>, self()},
     {subscription, <<"b">>, Ref, pop_mail},
     {subscription, <<"b">>, Ref, pull_presence}, {list_agents_page,first}, list_agents].

explicit_call({put_agent, A}, D) -> bus_store:put_agent(A, D);
explicit_call({delete_agent, A}, D) -> bus_store:delete_agent(A, D);
explicit_call({accept_mail, M}, D) -> bus_store:accept_mail(M, D);
explicit_call({subscribe, A, P}, D) -> bus_store:subscribe(A, P, D);
explicit_call({subscription, A, R, pop_mail}, D) -> bus_store:pop_mail(A, R, D);
explicit_call({subscription, A, R, pull_presence}, D) -> bus_store:pull_presence(A, R, D);
explicit_call({list_agents_page,C},D) -> bus_store:list_agents_page(C,D);
explicit_call(list_agents, D) -> bus_store:list_agents(D).

expired_deadlines() ->
    {ok, Ref} = bus_store:subscribe(<<"b">>, self()),
    {ok, _} = bus_store:accept_mail(mail()),
    Before = sys:get_state(bus_store),
    D = erlang:monotonic_time(millisecond),
    lists:foreach(fun(Op) ->
        ?assertEqual({error, timeout}, explicit_call(Op, D)),
        %% Also exercise the server guard, bypassing the client's early check.
        ?assertEqual({reply, {error, timeout}, Before},
            bus_store:handle_call({op, D, Op}, {self(), tag}, Before))
    end, deadline_ops(Ref)),
    ?assertEqual(Before, sys:get_state(bus_store)).

suspended_deadlines() ->
    {ok, Ref} = bus_store:subscribe(<<"b">>, self()),
    {ok, _} = bus_store:accept_mail(mail()),
    lists:foreach(fun(Op) ->
        Before = sys:get_state(bus_store),
        ok = sys:suspend(bus_store),
        try
            D = erlang:monotonic_time(millisecond) + 30,
            ?assertEqual({error, timeout}, explicit_call(Op, D)),
            %% The call's timeout is the barrier, not an arbitrary sleep.
            ?assert(erlang:monotonic_time(millisecond) >= D),
            {messages, Queued} = process_info(whereis(bus_store), messages),
            ?assert(lists:any(fun
                ({'$gen_call', _, {op, Original, QueuedOp}}) ->
                    Original =:= D andalso QueuedOp =:= Op;
                (_) -> false
            end, Queued))
        after
            ok = sys:resume(bus_store)
        end,
        ?assertEqual(maps:remove(last_expiry,Before), maps:remove(last_expiry,sys:get_state(bus_store)))
    end, deadline_ops(Ref)).

unavailable_store() ->
    %% A pending caller sees shutdown as unavailable, without propagating the
    %% exit reason (which may carry a request body). Keep the fixture alive.
    Store = whereis(bus_store),
    true = unregister(bus_store),
    try
        ?assertEqual({error, unavailable}, bus_store:list_agents()),
        Dying = spawn(fun() ->
            receive {'$gen_call', _, _} -> exit({shutdown, <<"private body">>}) end
        end),
        true = register(bus_store, Dying),
        ?assertEqual({error, unavailable}, bus_store:accept_mail(mail()))
    after
        true = register(bus_store, Store)
    end.

pop(Ref) ->
    bus_store:pop_mail(<<"b">>, Ref).

presence(Ref) ->
    case bus_store:pull_presence(<<"b">>, Ref) of
        {frame, Name, B, More} ->
            ?assert(lists:member(Name,[<<"presence_snapshot">>,<<"presence_delta">>,<<"presence_reset">>])),
            ?assert(is_map(json:decode(B))),
            case More of true -> presence(Ref); false -> bus_store:list_agents() end;
        empty -> bus_store:list_agents();
        Error -> Error
    end.

flag(Key) ->
    State = sys:get_state(bus_store),
    maps:get(Key, maps:get(<<"b">>, maps:get(subs, State))).

expect_wake(Ref, Kind) ->
    receive {bus, Ref, Kind} -> ok after 0 -> ?assert(false) end.

worker() ->
    receive
        {run, From, Tag, Fun} ->
            From ! {Tag, Fun()},
            worker();
        stop -> ok
    end.

remote(Pid, Fun) ->
    Tag = make_ref(),
    Pid ! {run, self(), Tag, Fun},
    receive {Tag, Result} -> Result after 1000 -> error(worker_timeout) end.

flush() ->
    receive {bus, _, _} -> flush() after 0 -> ok end.

agent(Id) ->
    #{<<"agentId">> => Id, <<"sessionId">> => Id, <<"host">> => <<"test">>,
      <<"cwd">> => <<"/tmp">>, <<"sessionName">> => <<"test">>,
      <<"label">> => <<"test">>, <<"model">> => null, <<"status">> => <<"idle">>,
      <<"pid">> => 1, <<"acceptsControl">> => false}.

mail() ->
    #{<<"id">> => <<"mail-1">>, <<"from">> => <<"a">>, <<"to">> => <<"b">>,
      <<"kind">> => <<"notice">>, <<"body">> => <<"hello">>}.
