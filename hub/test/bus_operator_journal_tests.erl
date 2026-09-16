-module(bus_operator_journal_tests).
-include_lib("eunit/include/eunit.hrl").

-define(FROM, <<"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa">>).
-define(TO, <<"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb">>).
-define(MSG, <<"cccccccc-cccc-4ccc-8ccc-cccccccccccc">>).

journal_test_() ->
    {setup, fun setup/0, fun cleanup/1, {inorder, [
        fun init_does_not_lookup_interfaces/0,
        fun empty_page_bootstraps/0,
        fun first_pull_sends_empty_observation/0,
        fun offer_is_ingested_without_producer_call/0,
        fun unavailable_without_owner/0,
        fun restart_fresh_epoch/0,
        fun output_redaction/0,
        {timeout, 15, fun timeout_does_not_release_queued_read/0},
        {timeout, 15, fun per_session_and_global_slots/0},
        {timeout, 15, fun periodic_loss_without_wake/0},
        {timeout, 15, fun history_gap_after_expiry/0},
        fun expired_page_skips_journal_expire/0,
        fun sequence_exhausted_resets_epoch/0,
        fun subscribe_rejects_duplicate_until_dead/0
    ]}}.

setup() ->
    application:ensure_all_started(crypto),
    stop_named(),
    {ok, Pid} = bus_operator_journal:start_link(),
    unlink(Pid),
    Pid.

cleanup(Pid) ->
    catch sys:resume(Pid),
    catch gen_server:stop(Pid),
    stop_named(),
    ok.

stop_named() ->
    case whereis(bus_operator_journal) of
        undefined -> ok;
        Pid -> catch gen_server:stop(Pid)
    end.

digest() -> crypto:hash(sha256, <<1:256>>).
other_digest() -> crypto:hash(sha256, <<2:256>>).
deadline() -> erlang:monotonic_time(millisecond) + 5000.
occupied() -> bus_operator_admission:occupied(bus_operator_journal:slots()).

mail_event() ->
    #{<<"kind">> => <<"mail_accepted">>,
      <<"source">> => <<"relay_observed">>,
      <<"agentId">> => ?TO,
      <<"occurredAt">> => 1,
      <<"payload">> => #{
          <<"id">> => ?MSG,
          <<"from">> => ?FROM,
          <<"to">> => ?TO,
          <<"kind">> => <<"notice">>,
          <<"acceptedAt">> => 1,
          <<"receiving">> => false,
          <<"bodyBytes">> => 5}}.

page() -> bus_operator_journal:page(first, self(), digest(), deadline()).

ingest_now() ->
    Pid = whereis(bus_operator_journal),
    Pid ! drain,
    sys:get_state(Pid),
    {ok, Bin} = page(),
    json:decode(Bin).

await_event() ->
    bus_operator_journal:offer(mail_event()),
    ingest_now().

init_does_not_lookup_interfaces() ->
    _ = erlang:trace_pattern({net, getifaddrs, 0}, true, [call_count]),
    try
        catch gen_server:stop(whereis(bus_operator_journal)),
        {ok, Pid} = bus_operator_journal:start_link(),
        unlink(Pid),
        Count = case erlang:trace_info({net, getifaddrs, 0}, call_count) of
            {call_count, undefined} -> 0;
            {call_count, N} -> N
        end,
        ?assertEqual(0, Count)
    after
        erlang:trace_pattern({net, getifaddrs, 0}, false, [call_count])
    end.

empty_page_bootstraps() ->
    {ok, Bin} = page(),
    Doc = json:decode(Bin),
    ?assertEqual([], maps:get(<<"events">>, Doc)),
    ?assertEqual(<<"empty">>, maps:get(<<"coverage">>, Doc)),
    ?assertEqual(true, maps:get(<<"caughtUp">>, Doc)).

offer_is_ingested_without_producer_call() ->
    1 = erlang:trace_pattern({gen_server, call, 3}, true, [call_count]),
    try
        ok = bus_operator_journal:offer(mail_event()),
        {call_count, N} = erlang:trace_info({gen_server, call, 3}, call_count),
        ?assertEqual(0, N)
    after
        erlang:trace_pattern({gen_server, call, 3}, false, [call_count])
    end,
    Doc = ingest_now(),
    [Ev] = maps:get(<<"events">>, Doc),
    ?assertEqual(<<"mail_accepted">>, maps:get(<<"kind">>, Ev)),
    ?assertEqual(false, maps:is_key(<<"body">>, maps:get(<<"payload">>, Ev))).

unavailable_without_owner() ->
    Pid = whereis(bus_operator_journal),
    gen_server:stop(Pid),
    ?assertEqual({error, unavailable}, page()),
    ?assertEqual(ok, bus_operator_journal:offer(mail_event())),
    {ok, New} = bus_operator_journal:start_link(),
    unlink(New).

restart_fresh_epoch() ->
    _ = await_event(),
    {ok, First} = page(),
    Epoch = maps:get(<<"epoch">>, json:decode(First)),
    Pid = whereis(bus_operator_journal),
    Mon = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Mon, process, Pid, _} -> ok end,
    {ok, New} = bus_operator_journal:start_link(),
    unlink(New),
    {ok, Bin} = page(),
    Doc = json:decode(Bin),
    ?assertEqual([], maps:get(<<"events">>, Doc)),
    ?assert(maps:get(<<"epoch">>, Doc) =/= Epoch).

output_redaction() ->
    Marker = <<"operator-journal-redact-7f3a">>,
    Status = maps:from_list([{K, Marker} || K <- [state, message, reason, log, future_otp_field]]),
    Safe = bus_operator_journal:format_status(Status),
    ?assertEqual(lists:sort(maps:keys(Status)), lists:sort(maps:keys(Safe))),
    ?assertEqual(nomatch, binary:match(term_to_binary(Safe), Marker)).

timeout_does_not_release_queued_read() ->
    Journal = whereis(bus_operator_journal),
    ok = sys:suspend(Journal),
    Parent = self(),
    spawn(fun() ->
        Parent ! {page_result, bus_operator_journal:page(first, self(), digest(),
            erlang:monotonic_time(millisecond) + 80)}
    end),
    await_occupied(1),
    receive {page_result, {error, timeout}} -> ok after 2000 -> error(no_timeout) end,
    ?assertEqual(1, occupied()),
    ok = sys:resume(Journal),
    await_occupied(0).

per_session_and_global_slots() ->
    Journal = whereis(bus_operator_journal),
    ok = sys:suspend(Journal),
    Parent = self(),
    Limit = bus_operator_admission:session_limit(),
    lists:foreach(fun(_) ->
        spawn(fun() ->
            Parent ! {page_result, bus_operator_journal:page(first, self(), digest(), deadline())}
        end)
    end, lists:seq(1, Limit)),
    await_occupied(Limit),
    ?assertEqual({error, overloaded},
        bus_operator_journal:page(first, self(), digest(), deadline())),
    spawn(fun() ->
        Parent ! {page_result, bus_operator_journal:page(first, self(), other_digest(), deadline())}
    end),
    await_occupied(Limit + 1),
    ok = sys:resume(Journal),
    drain_results(Limit + 1),
    await_occupied(0).

periodic_loss_without_wake() ->
    ok = bus_operator_ingress:force_loss(true),
    try
        ok = bus_operator_journal:offer(mail_event()),
        Pid = whereis(bus_operator_journal),
        ?assertEqual(1, bus_operator_ingress:dropped(bus_operator_ingress:tid(Pid))),
        Pid ! expire,
        sys:get_state(Pid),
        {ok, Bin} = page(),
        [Ev] = maps:get(<<"events">>, json:decode(Bin)),
        ?assertEqual(<<"observation_lost">>, maps:get(<<"kind">>, Ev))
    after
        bus_operator_ingress:force_loss(false)
    end.

history_gap_after_expiry() ->
    Doc = await_event(),
    C0 = cursor_for(maps:get(<<"epoch">>, Doc), 0),
    Pid = whereis(bus_operator_journal),
    Events = maps:get(events, sys:get_state(Pid)),
    T = case queue:peek(maps:get(journal, Events)) of
        {value, {_, When, _}} -> When;
        empty -> 0
    end,
    Aged = bus_operator_events:expire(T + 86400, Events),
    sys:replace_state(Pid, fun(S) -> S#{events := Aged, last_expiry := T + 86400} end),
    ?assertEqual({error, history_lost},
        bus_operator_journal:page(C0, self(), digest(), deadline())).

expired_page_skips_journal_expire() ->
    _ = await_event(),
    Pid = whereis(bus_operator_journal),
    State0 = sys:get_state(Pid),
    Past = erlang:monotonic_time(millisecond) - 1,
    1 = erlang:trace_pattern({bus_operator_events, expire, 2}, true, [call_count]),
    try
        {reply, Reply, Next} = bus_operator_journal:handle_call_at(
            {op, Past, make_ref(), self(), {page, first}},
            {self(), tag}, State0#{last_expiry => undefined}, {0, 0}),
        {call_count, N} = erlang:trace_info({bus_operator_events, expire, 2}, call_count),
        ?assertEqual(0, N),
        ?assert(Reply =:= {error, timeout} orelse Reply =:= {error, stale_slot}),
        ?assert(bus_operator_events:journal_count(maps:get(events, Next)) > 0)
    after
        erlang:trace_pattern({bus_operator_events, expire, 2}, false, [call_count])
    end.

subscribe_rejects_duplicate_until_dead() ->
    flush_journal(),
    {ok, Pid, Ref} = bus_operator_journal:subscribe(self(), digest(), deadline()),
    ?assertEqual({error, conflict},
        bus_operator_journal:subscribe(self(), digest(), deadline())),
    bus_operator_journal:unsubscribe(Pid, Ref),
    sys:get_state(Pid),
    {ok, Pid2, Ref2} = bus_operator_journal:subscribe(self(), digest(), deadline()),
    bus_operator_journal:unsubscribe(Pid2, Ref2),
    sys:get_state(Pid2),
    flush_journal().

flush_journal() ->
    receive {journal, _, _} -> flush_journal() after 0 -> ok end.

first_pull_sends_empty_observation() ->
    flush_journal(),
    {ok, Pid, Ref} = bus_operator_journal:subscribe(self(), digest(), deadline()),
    receive {journal, Ref, wake} -> ok after 1000 -> error(no_wake) end,
    {frame, Bin, false, Size} = bus_operator_journal:pull(Pid, Ref, self(), deadline()),
    ?assertEqual(iolist_size(cow_sse:events([#{event => <<"observation">>, data => Bin}])), Size),
    ?assert(Size > byte_size(Bin)),
    ?assertEqual(empty, bus_operator_journal:pull(Pid, Ref, self(), deadline())),
    bus_operator_journal:release(Pid, Ref, Size + 1),
    ?assertEqual(Size, maps:get(inflight, sys:get_state(Pid))),
    Doc = json:decode(Bin),
    ?assertEqual([], maps:get(<<"events">>, Doc)),
    ?assertEqual(<<"empty">>, maps:get(<<"coverage">>, Doc)),
    bus_operator_journal:release(Pid, Ref, Size),
    ?assertEqual(0, maps:get(inflight, sys:get_state(Pid))),
    bus_operator_journal:unsubscribe(Pid, Ref).

sequence_exhausted_resets_epoch() ->
    Doc = await_event(),
    OldEpoch = maps:get(<<"epoch">>, Doc),
    Pid = whereis(bus_operator_journal),
    Events = maps:get(events, sys:get_state(Pid)),
    Maxed = bus_operator_events:set_sequence(Events, bus_operator_events:max_sequence()),
    sys:replace_state(Pid, fun(S) -> S#{events := Maxed} end),
    ok = bus_operator_journal:offer(mail_event()),
    ok = bus_operator_journal:offer(mail_event()),
    After = ingest_now(),
    Ev = maps:get(<<"events">>, After),
    ?assertEqual(2, length(Ev)),
    ?assert(maps:get(<<"epoch">>, After) =/= OldEpoch).

await_occupied(N) -> await_occupied(N, 40).
await_occupied(N, 0) -> error({occupied, occupied(), expected, N});
await_occupied(N, Tries) ->
    case occupied() of
        N -> ok;
        _ -> timer:sleep(25), await_occupied(N, Tries - 1)
    end.

drain_results(0) -> ok;
drain_results(N) ->
    receive {page_result, _} -> drain_results(N - 1)
    after 2000 -> error(missing_result) end.

cursor_for(Epoch, Seq) ->
    Raw = <<Epoch/binary, $:, (integer_to_binary(Seq))/binary>>,
    base64:encode(Raw, #{mode => urlsafe, padding => false}).
