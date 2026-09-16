-module(bus_operator_events).

%% Pure volatile observation journal. No mailbox, no process, no producer CAS
%% of this structure. Sequence is a canonical uint64 decimal on the wire.
-export([new/0, epoch/1, sequence/1, dropped_seen/1, retained_from/1,
         max_events/0, max_bytes/0, max_age_s/0, max_sequence/0,
         page_limit/0, page_bytes/0, stream_bytes/0, cursor_limit/0,
         journal_count/1, journal_bytes/1,
         candidate/2, record/4, record/5, ingest/4, apply_drops/4, expire/2, page/4,
         observer/0, signal/1, rearm/1, pull/4, search/5]).

-ifdef(TEST).
-export([set_sequence/2]).
-endif.

-define(MAX_EVENTS, 100000).
-define(MAX_BYTES, 134217728).
-define(MAX_AGE, 86400).
-define(PAGE_EVENTS, 128).
-define(PAGE_BYTES, 1048576).
-define(STREAM_BYTES, 524288).
-define(CURSOR, 128).
-define(MAX_SEQ, 18446744073709551615).
-define(MAX_BODY, 16384).
-define(MAX_TEXT, 2048).
-define(ENVELOPE, 2048).
-define(SEARCH_HITS, 128).
-define(SEARCH_BYTES, 1048576).
-define(SEARCH_SCAN, 2048).

new() ->
    #{epoch => uuid(), sequence => 0, dropped_seen => 0,
      journal => queue:new(), journal_index => #{},
      journal_bytes => 0, journal_count => 0}.

epoch(#{epoch := Epoch}) -> Epoch.
sequence(#{sequence := Seq}) -> Seq.
dropped_seen(#{dropped_seen := Seen}) -> Seen.
journal_count(#{journal_count := N}) -> N.
journal_bytes(#{journal_bytes := N}) -> N.

retained_from(J) ->
    case queue:peek(maps:get(journal, J)) of
        empty -> maps:get(sequence, J);
        {value, {First, _, _}} -> First
    end.

max_events() -> ?MAX_EVENTS.
max_bytes() -> ?MAX_BYTES.
max_age_s() -> ?MAX_AGE.
max_sequence() -> ?MAX_SEQ.
page_limit() -> ?PAGE_EVENTS.
page_bytes() -> ?PAGE_BYTES.
stream_bytes() -> ?STREAM_BYTES.
cursor_limit() -> ?CURSOR.

-ifdef(TEST).
set_sequence(J, N) when is_map(J), is_integer(N), N >= 0, N =< ?MAX_SEQ ->
    J#{sequence := N}.
-endif.

candidate(Event, Opts) ->
    try {ok, canonicalize(Event, Opts)}
    catch
        throw:invalid_event -> {error, invalid_event};
        error:_ -> {error, invalid_event}
    end.

record(Event, Now, Wall, J) -> record(Event, Now, Wall, J, #{}).

record(Event, Now, Wall, J, Opts)
  when is_integer(Now), is_integer(Wall), Wall >= 0, Wall =< ?MAX_SEQ,
       is_map(J), is_map(Opts) ->
    case candidate(Event, Opts) of
        {error, invalid_event} -> {error, invalid_event, J};
        {ok, Canonical} ->
            try {ok, append(Canonical, Now, Wall, J)}
            catch
                throw:sequence_exhausted -> {error, sequence_exhausted, J};
                throw:invalid_event -> {error, invalid_event, J};
                error:_ -> {error, invalid_event, J}
            end
    end;
record(_, _, _, J, _) -> {error, invalid_event, J}.

%% Ingress already canonicalized, including enrolled bodies.
ingest(Canonical, Now, Wall, J)
  when is_map(Canonical), is_integer(Now), is_integer(Wall),
       Wall >= 0, Wall =< ?MAX_SEQ, is_map(J) ->
    try {ok, append(Canonical, Now, Wall, J)}
    catch
        throw:sequence_exhausted -> {error, sequence_exhausted, J};
        throw:invalid_event -> {error, invalid_event, J};
        error:_ -> {error, invalid_event, J}
    end;
ingest(_, _, _, J) -> {error, invalid_event, J}.

apply_drops(Dropped, Now, Wall, J)
  when is_integer(Dropped), Dropped >= 0, is_map(J) ->
    Seen = maps:get(dropped_seen, J),
    if
        Dropped < Seen -> {error, coverage_wrap, J};
        Dropped =:= Seen -> {ok, J};
        true ->
            Event = #{<<"kind">> => <<"observation_lost">>,
                      <<"source">> => <<"relay_observed">>,
                      <<"payload">> => #{<<"count">> => integer_to_binary(Dropped - Seen)}},
            case record(Event, Now, Wall, J) of
                {ok, J1} -> {ok, J1#{dropped_seen := Dropped}};
                Error -> Error
            end
    end;
apply_drops(_, _, _, J) -> {error, invalid_event, J}.

expire(Now, J) when is_integer(Now), is_map(J) -> trim(Now, J).

page(Cursor, Now, Deadline, J0) when is_map(J0) ->
    read(Cursor, Now, Deadline, ?PAGE_BYTES, J0).

search(Filter, Cursor, Now, Deadline, J0) when is_map(Filter), is_map(J0) ->
    try
        check(Deadline),
        J = trim(Now, J0),
        Hash = filter_hash(Filter),
        {Epoch, High, After} = search_progress(Cursor, Hash, J),
        case Epoch =:= maps:get(epoch, J) of
            false -> throw(epoch_reset);
            true -> ok
        end,
        case covered(After, J) of
            false -> throw(history_lost);
            true -> ok
        end,
        {Hits, Scanned} = scan(Filter, After, High, Deadline, J),
        check(Deadline),
        Doc = search_doc(J, Hits, Scanned, High, Hash),
        Enc = iolist_to_binary(json:encode(Doc)),
        case byte_size(Enc) =< ?SEARCH_BYTES of
            true -> {{ok, Enc}, J};
            false -> throw(capacity)
        end
    catch
        throw:timeout -> {{error, timeout}, J0};
        throw:Reason -> {{error, Reason}, J0}
    end;
search(_, _, _, _, J) -> {{error, invalid_schema}, J}.

observer() -> #{wake => false, seq => 0, epoch => undefined}.

signal(#{wake := true} = Obs) -> {quiet, Obs};
signal(Obs) when is_map(Obs) -> {wake, Obs#{wake := true}}.

rearm(Obs) when is_map(Obs) -> Obs#{wake := false}.

pull(Obs, Now, Deadline, J0) when is_map(Obs), is_map(J0) ->
    Cursor = case maps:get(epoch, Obs) of
        undefined -> first;
        Epoch -> encode_cursor(Epoch, maps:get(seq, Obs))
    end,
    case read(Cursor, Now, Deadline, ?STREAM_BYTES, J0) of
        {{error, timeout}, J} -> {error, timeout, Obs, J};
        {{error, Reason}, J} -> {error, Reason, Obs, J};
        {{ok, Bin}, J} ->
            Doc = json:decode(Bin),
            To = binary_to_integer(maps:get(<<"toSequence">>, Doc)),
            More = maps:get(<<"caughtUp">>, Doc) =:= false,
            Baseline = maps:get(epoch, Obs) =:= undefined,
            Obs1 = Obs#{epoch => maps:get(epoch, J), seq => To},
            case maps:get(<<"events">>, Doc) =:= [] andalso not Baseline of
                true ->
                    {empty, rearm(Obs1), J};
                false ->
                    {frame, Bin, More,
                     case More of true -> Obs1; false -> rearm(Obs1) end, J}
            end
    end.

read(Cursor, Now, Deadline, Limit, J0) ->
    try check(Deadline) of
        ok -> read_ready(Cursor, Now, Limit, Deadline, J0)
    catch
        throw:timeout -> {{error, timeout}, J0}
    end.

read_ready(Cursor, Now, Limit, Deadline, J0) ->
    J = trim(Now, J0),
    try
        {Epoch, After} = progress(Cursor, J),
        case Epoch =:= maps:get(epoch, J) of
            false -> throw(epoch_reset);
            true -> ok
        end,
        case After > maps:get(sequence, J) of
            true -> throw(invalid_cursor);
            false -> ok
        end,
        case covered(After, J) of
            false -> throw(history_lost);
            true -> {{ok, encode_frame(After, Limit, Deadline, J)}, J}
        end
    catch
        throw:timeout -> {{error, timeout}, J0};
        throw:Reason -> {{error, Reason}, J}
    end.

progress(first, J) ->
    case queue:peek(maps:get(journal, J)) of
        empty -> {maps:get(epoch, J), maps:get(sequence, J)};
        {value, {First, _, _}} -> {maps:get(epoch, J), First - 1}
    end;
progress(Cursor, _J) ->
    decode_cursor(Cursor).

append(Canonical, Now, Wall, J0) ->
    case maps:get(sequence, J0) of
        Seq0 when Seq0 >= ?MAX_SEQ -> throw(sequence_exhausted);
        Seq0 ->
            Seq = Seq0 + 1,
            Event = Canonical#{
                <<"schemaVersion">> => 1,
                <<"epoch">> => maps:get(epoch, J0),
                <<"sequence">> => integer_to_binary(Seq),
                <<"eventId">> => uuid(),
                <<"observedAt">> => integer_to_binary(Wall)
            },
            Encoded = iolist_to_binary(json:encode(Event)),
            B = byte_size(Encoded),
            trim(Now, J0#{
                sequence := Seq,
                journal := queue:in({Seq, Now, B}, maps:get(journal, J0)),
                journal_index := (maps:get(journal_index, J0))#{
                    Seq => {Seq, Now, B, Event}},
                journal_bytes := maps:get(journal_bytes, J0) + B,
                journal_count := maps:get(journal_count, J0) + 1
            })
    end.

trim(Now, J) ->
    case queue:peek(maps:get(journal, J)) of
        {value, {R, T, B}} ->
            Over = T + ?MAX_AGE =< Now
                orelse maps:get(journal_count, J) > ?MAX_EVENTS
                orelse maps:get(journal_bytes, J) > ?MAX_BYTES,
            case Over of
                true ->
                    {_, Q1} = queue:out(maps:get(journal, J)),
                    trim(Now, J#{
                        journal := Q1,
                        journal_index := maps:remove(R, maps:get(journal_index, J)),
                        journal_bytes := maps:get(journal_bytes, J) - B,
                        journal_count := maps:get(journal_count, J) - 1
                    });
                false -> J
            end;
        empty -> J
    end.

covered(After, J) ->
    case queue:peek(maps:get(journal, J)) of
        empty -> After =:= maps:get(sequence, J);
        {value, {First, _, _}} -> After >= First - 1
    end.

%% Cached event sizes plus ENVELOPE leave room for page keys/cursor.
%% One encode of the selected prefix; a second pass is unreachable if the
%% reserve holds. A single event larger than Limit still throws capacity.
encode_frame(After, Limit, Deadline, J) ->
    check(Deadline),
    Events = select_prefix(After, Limit, Deadline, J),
    check(Deadline),
    Bin = iolist_to_binary(json:encode(page_doc(Events, After, J))),
    case byte_size(Bin) =< Limit of
        true -> Bin;
        false -> throw(capacity)
    end.

select_prefix(After, Limit, Deadline, J) ->
    Current = maps:get(sequence, J),
    Last = min(After + ?PAGE_EVENTS, Current),
    Index = maps:get(journal_index, J),
    take_prefix(After + 1, Last, Index, Limit, Deadline, [], 0).

take_prefix(Seq, Last, _Index, _Limit, _Deadline, Acc, _Used) when Seq > Last ->
    lists:reverse(Acc);
take_prefix(Seq, Last, Index, Limit, Deadline, Acc, Used) ->
    check(Deadline),
    case maps:get(Seq, Index, undefined) of
        undefined ->
            take_prefix(Seq + 1, Last, Index, Limit, Deadline, Acc, Used);
        {Seq, _, B, Event} ->
            case Acc =/= [] andalso Used + B + 1 > Limit - ?ENVELOPE of
                true -> lists:reverse(Acc);
                false ->
                    take_prefix(Seq + 1, Last, Index, Limit, Deadline,
                        [Event | Acc], Used + B + 1)
            end
    end.

page_doc(Events, After, J) ->
    To = case Events of
        [] -> After;
        _ -> binary_to_integer(maps:get(<<"sequence">>, lists:last(Events)))
    end,
    Caught = To =:= maps:get(sequence, J),
    #{<<"epoch">> => maps:get(epoch, J),
      <<"fromSequence">> => integer_to_binary(After),
      <<"toSequence">> => integer_to_binary(To),
      <<"retainedFrom">> => integer_to_binary(retained_from(J)),
      <<"coverage">> => coverage(J),
      <<"caughtUp">> => Caught,
      <<"nextCursor">> => case Caught of
          true -> null;
          false -> encode_cursor(maps:get(epoch, J), To)
      end,
      <<"events">> => Events}.

coverage(J) ->
    case queue:peek(maps:get(journal, J)) of
        empty -> <<"empty">>;
        {value, {1, _, _}} -> <<"live">>;
        {value, _} -> <<"truncated">>
    end.

filter_hash(Filter) ->
    Pairs = lists:sort(maps:to_list(Filter)),
    crypto:hash(sha256, term_to_binary(Pairs)).

search_progress(first, _Hash, J) ->
    High = maps:get(sequence, J),
    After = case queue:peek(maps:get(journal, J)) of
        empty -> High;
        {value, {First, _, _}} -> First - 1
    end,
    {maps:get(epoch, J), High, After};
search_progress(Cursor, Hash, J) ->
    {Epoch, High, Through, Got} = decode_search_cursor(Cursor),
    true = Got =:= Hash orelse throw(epoch_reset),
    true = High =< maps:get(sequence, J) orelse throw(epoch_reset),
    {Epoch, High, Through}.

scan(Filter, After, High, Deadline, J) ->
    Index = maps:get(journal_index, J),
    Last = min(After + ?SEARCH_SCAN, High),
    scan_seq(After + 1, Last, High, Index, Filter, Deadline, [], 0).

scan_seq(Seq, Last, _High, _Index, _Filter, _Deadline, Hits, _Used) when Seq > Last ->
    {lists:reverse(Hits), Last};
scan_seq(Seq, Last, High, Index, Filter, Deadline, Hits, Used) ->
    check(Deadline),
    case maps:get(Seq, Index, undefined) of
        undefined when Seq =< High -> throw(history_lost);
        undefined -> scan_seq(Seq + 1, Last, High, Index, Filter, Deadline, Hits, Used);
        {Seq, _, B, Event} ->
            case match_event(Filter, Event) of
                false -> scan_seq(Seq + 1, Last, High, Index, Filter, Deadline, Hits, Used);
                true ->
                    case length(Hits) >= ?SEARCH_HITS
                            orelse (Hits =/= [] andalso Used + B + 1 > ?SEARCH_BYTES - ?ENVELOPE) of
                        true -> {lists:reverse(Hits), Seq - 1};
                        false -> scan_seq(Seq + 1, Last, High, Index, Filter, Deadline,
                                [Event | Hits], Used + B + 1)
                    end
            end
    end.

match_event(Filter, Event) ->
    match_q(maps:get(q, Filter, undefined), Event)
        andalso match_id(maps:get(participant, Filter, undefined), Event, participant)
        andalso match_id(maps:get(workId, Filter, undefined), Event, workId)
        andalso match_id(maps:get(threadId, Filter, undefined), Event, threadId)
        andalso match_outcome(maps:get(outcome, Filter, undefined), Event)
        andalso match_source(maps:get(source, Filter, undefined), Event)
        andalso match_category(maps:get(category, Filter, undefined), Event)
        andalso match_range(maps:get(from, Filter, undefined), maps:get(to, Filter, undefined), Event).

match_q(undefined, _) -> true;
match_q(Q, Event) when is_binary(Q) ->
    haystack_match(Q, Event).

haystack_match(Q, Event) ->
    Pay = maps:get(<<"payload">>, Event, #{}),
    Bins = [maps:get(<<"kind">>, Event, <<>>),
            maps:get(<<"action">>, Pay, <<>>),
            maps:get(<<"state">>, Pay, <<>>),
            maps:get(<<"objective">>, Pay, <<>>),
            maps:get(<<"reason">>, Pay, <<>>),
            maps:get(<<"toolName">>, Pay, <<>>),
            maps:get(<<"toolCallId">>, Pay, <<>>),
            maps:get(<<"text">>, Pay, <<>>),
            maps:get(<<"body">>, Pay, <<>>),
            maps:get(<<"label">>, Pay, <<>>)],
    lists:any(fun(B) -> is_binary(B) andalso binary:match(B, Q) =/= nomatch end, Bins).

match_id(undefined, _, _) -> true;
match_id(Id, Event, participant) ->
    Pay = maps:get(<<"payload">>, Event, #{}),
    Id =:= maps:get(<<"agentId">>, Event, null)
        orelse Id =:= maps:get(<<"from">>, Pay, undefined)
        orelse Id =:= maps:get(<<"to">>, Pay, undefined);
match_id(Id, Event, workId) -> Id =:= maps:get(<<"workId">>, Event, null);
match_id(Id, Event, threadId) -> Id =:= maps:get(<<"threadId">>, Event, null).

match_outcome(undefined, _) -> true;
match_outcome(Outcome, Event) when Outcome =:= <<"completed">>; Outcome =:= <<"failed">> ->
    Kind = maps:get(<<"kind">>, Event, undefined),
    Pay = maps:get(<<"payload">>, Event, #{}),
    (Kind =:= <<"outcome_reported">> andalso maps:get(<<"outcome">>, Pay, undefined) =:= Outcome)
        orelse (Kind =:= <<"operator_result">> andalso maps:get(<<"state">>, Pay, undefined) =:= Outcome);
match_outcome(Outcome, Event) ->
    Kind = maps:get(<<"kind">>, Event, undefined),
    Pay = maps:get(<<"payload">>, Event, #{}),
    (Kind =:= <<"operator_requested">> orelse Kind =:= <<"operator_result">>)
        andalso maps:get(<<"state">>, Pay, undefined) =:= Outcome.

match_source(undefined, _) -> true;
match_source(Src, Event) -> maps:get(<<"source">>, Event, undefined) =:= Src.

match_category(undefined, _) -> true;
match_category(<<"communications">>, Event) ->
    lists:member(maps:get(<<"kind">>, Event), [<<"mail_accepted">>, <<"mail_dispatched">>]);
match_category(<<"work">>, Event) ->
    lists:member(maps:get(<<"kind">>, Event), [<<"work_reported">>, <<"work_snapshot">>,
        <<"run_reported">>, <<"blocker_reported">>, <<"outcome_reported">>]);
match_category(<<"activity">>, Event) ->
    maps:get(<<"kind">>, Event) =:= <<"tool_reported">>;
match_category(<<"operations">>, Event) ->
    lists:member(maps:get(<<"kind">>, Event), [<<"operator_requested">>, <<"operator_result">>]);
match_category(<<"observation">>, Event) ->
    maps:get(<<"kind">>, Event) =:= <<"observation_lost">>;
match_category(_, _) -> false.

match_range(From, To, Event) ->
    T = event_time(Event),
    (From =:= undefined orelse T >= From) andalso (To =:= undefined orelse T =< To).

event_time(Event) ->
    case maps:get(<<"occurredAt">>, Event, null) of
        null -> bin_int(maps:get(<<"observedAt">>, Event, <<"0">>));
        Bin -> bin_int(Bin)
    end.

bin_int(Bin) when is_binary(Bin) -> binary_to_integer(Bin);
bin_int(N) when is_integer(N) -> N.

search_doc(J, Hits, Scanned, High, Hash) ->
    Epoch = maps:get(epoch, J),
    Next = case Scanned >= High of
        true -> null;
        false -> encode_search_cursor(Epoch, High, Scanned, Hash)
    end,
    #{
        <<"epoch">> => Epoch,
        <<"events">> => Hits,
        <<"nextCursor">> => Next,
        <<"scannedThrough">> => integer_to_binary(Scanned),
        <<"throughSequence">> => integer_to_binary(High),
        <<"coverage">> => coverage(J)
    }.

encode_search_cursor(Epoch, High, Through, Hash)
  when byte_size(Hash) =:= 32 ->
    Raw = <<Epoch/binary, $|, High:64, Through:64, Hash/binary>>,
    C = base64:encode(Raw, #{mode => urlsafe, padding => false}),
    true = byte_size(C) =< ?CURSOR orelse throw(invalid_cursor),
    C.

decode_search_cursor(C) when is_binary(C), byte_size(C) =< ?CURSOR, byte_size(C) > 0 ->
    try
        Raw = base64:decode(C, #{mode => urlsafe, padding => false}),
        case binary:split(Raw, <<$|>>) of
            [Epoch, <<High:64, Through:64, Hash:32/binary>>] ->
                true = bus_protocol:is_uuid(Epoch),
                true = C =:= encode_search_cursor(Epoch, High, Through, Hash),
                {Epoch, High, Through, Hash};
            _ -> throw(invalid_cursor)
        end
    catch
        throw:Reason -> throw(Reason);
        _:_ -> throw(invalid_cursor)
    end;
decode_search_cursor(_) -> throw(invalid_cursor).

encode_cursor(Epoch, Seq) when is_integer(Seq) ->
    Raw = <<Epoch/binary, $:, (integer_to_binary(Seq))/binary>>,
    base64:encode(Raw, #{mode => urlsafe, padding => false}).

decode_cursor(C) when is_binary(C), byte_size(C) =< ?CURSOR ->
    try
        Raw = base64:decode(C, #{mode => urlsafe, padding => false}),
        case binary:split(Raw, <<$:>>) of
            [Epoch, Num] ->
                true = bus_protocol:is_uuid(Epoch),
                N = binary_to_integer(Num),
                true = N >= 0 andalso N =< ?MAX_SEQ,
                true = Num =:= integer_to_binary(N),
                true = C =:= encode_cursor(Epoch, N),
                {Epoch, N};
            _ -> throw(invalid_cursor)
        end
    catch
        throw:invalid_cursor -> throw(invalid_cursor);
        _:_ -> throw(invalid_cursor)
    end;
decode_cursor(_) -> throw(invalid_cursor).

check(Deadline) when is_integer(Deadline) ->
    case erlang:monotonic_time(millisecond) < Deadline of
        true -> ok;
        false -> throw(timeout)
    end;
check(_) -> throw(timeout).

canonicalize(Event, Opts) when is_map(Event), is_map(Opts) ->
    Enroll = maps:get(enroll_bodies, Opts, false),
    case Enroll =:= true orelse Enroll =:= false of
        false -> throw(invalid_event);
        true -> ok
    end,
    Forbidden = [<<"epoch">>, <<"sequence">>, <<"schemaVersion">>,
                 <<"eventId">>, <<"observedAt">>],
    case lists:any(fun(K) -> maps:is_key(K, Event) end, Forbidden) of
        true -> throw(invalid_event);
        false -> ok
    end,
    Required = [<<"kind">>, <<"source">>, <<"payload">>],
    Optional = [<<"agentId">>, <<"sessionId">>, <<"workId">>,
                <<"threadId">>, <<"operationId">>, <<"occurredAt">>],
    Keys = maps:keys(Event),
    case {Required -- Keys, Keys -- (Required ++ Optional)} of
        {[], []} -> ok;
        _ -> throw(invalid_event)
    end,
    Kind = maps:get(<<"kind">>, Event),
    Source = maps:get(<<"source">>, Event),
    pair(Kind, Source),
    Payload = payload(Kind, maps:get(<<"payload">>, Event), Enroll),
    #{<<"kind">> => Kind,
      <<"source">> => Source,
      <<"occurredAt">> => timestamp(maps:get(<<"occurredAt">>, Event, null)),
      <<"agentId">> => optional_id(maps:get(<<"agentId">>, Event, null)),
      <<"sessionId">> => optional_id(maps:get(<<"sessionId">>, Event, null)),
      <<"workId">> => work_id(Kind, maps:get(<<"workId">>, Event, null)),
      <<"threadId">> => optional_id(maps:get(<<"threadId">>, Event, null)),
      <<"operationId">> => optional_id(maps:get(<<"operationId">>, Event, null)),
      <<"payload">> => Payload};
canonicalize(_, _) -> throw(invalid_event).

pair(<<"mail_accepted">>, <<"relay_observed">>) -> ok;
pair(<<"mail_dispatched">>, <<"relay_observed">>) -> ok;
pair(<<"observation_lost">>, <<"relay_observed">>) -> ok;
pair(<<"work_reported">>, <<"client_reported">>) -> ok;
pair(<<"work_snapshot">>, <<"client_reported">>) -> ok;
pair(<<"run_reported">>, <<"client_reported">>) -> ok;
pair(<<"blocker_reported">>, <<"client_reported">>) -> ok;
pair(<<"outcome_reported">>, <<"client_reported">>) -> ok;
pair(<<"operator_requested">>, <<"operator_requested">>) -> ok;
pair(<<"operator_result">>, <<"client_reported">>) -> ok;
pair(<<"operator_result">>, <<"relay_observed">>) -> ok;
pair(<<"operator_result">>, <<"operator_requested">>) -> ok;
pair(<<"tool_reported">>, <<"client_reported">>) -> ok;
pair(_, _) -> throw(invalid_event).

work_id(Kind, Id) when Kind =:= <<"work_reported">>;
                       Kind =:= <<"blocker_reported">>;
                       Kind =:= <<"outcome_reported">> ->
    case optional_id(Id) of
        null -> throw(invalid_event);
        Uuid -> Uuid
    end;
work_id(_, Id) -> optional_id(Id).

payload(<<"mail_accepted">>, Map, Enroll) ->
    Base = [<<"id">>, <<"from">>, <<"to">>, <<"kind">>, <<"acceptedAt">>,
            <<"receiving">>, <<"bodyBytes">>],
    exact(Map, Base, body_keys(Enroll), fun mail_field/3, Enroll);
payload(<<"mail_dispatched">>, Map, Enroll) ->
    exact(Map, [<<"id">>, <<"from">>, <<"to">>, <<"kind">>],
        [<<"bodyBytes">> | body_keys(Enroll)], fun mail_field/3, Enroll);
payload(<<"observation_lost">>, Map, _Enroll) ->
    exact(Map, [<<"count">>], [], fun lost_field/3, false);
payload(<<"work_reported">>, Map, _Enroll) ->
    exact(Map, [<<"objective">>, <<"phase">>], [], fun work_field/3, false);
payload(<<"blocker_reported">>, Map, _Enroll) ->
    exact(Map, [<<"reason">>], [], fun work_field/3, false);
payload(<<"outcome_reported">>, Map, _Enroll) ->
    exact(Map, [<<"outcome">>], [], fun work_field/3, false);
payload(<<"work_snapshot">>, Map, _Enroll) ->
    case bus_operator_work:decode(Map) of
        {ok, Canonical} -> Canonical;
        _ -> throw(invalid_event)
    end;
payload(<<"run_reported">>, Map, _Enroll) ->
    exact(Map, [<<"activeRunId">>], [], fun run_field/3, false);
payload(<<"operator_requested">>, Map, Enroll) ->
    exact(Map, [<<"action">>, <<"state">>], body_keys(Enroll), fun op_field/3, Enroll);
payload(<<"operator_result">>, Map, _Enroll) ->
    exact(Map, [<<"action">>, <<"state">>], [], fun op_field/3, false);
payload(<<"tool_reported">>, Map, _Enroll) ->
    exact(Map, [<<"toolCallId">>, <<"toolName">>, <<"state">>], [],
        fun tool_field/3, false);
payload(_, _, _) -> throw(invalid_event).

body_keys(true) -> [<<"body">>];
body_keys(false) -> [].

exact(Map, Required, Optional, Field, Enroll) when is_map(Map) ->
    Keys = maps:keys(Map),
    case {Required -- Keys, Keys -- (Required ++ Optional)} of
        {[], []} ->
            maps:from_list([{K, Field(K, maps:get(K, Map), Enroll)} || K <- Keys]);
        _ -> throw(invalid_event)
    end;
exact(_, _, _, _, _) -> throw(invalid_event).

mail_field(<<"id">>, V, _) -> uuid_bin(V);
mail_field(<<"from">>, V, _) -> uuid_bin(V);
mail_field(<<"to">>, V, _) -> uuid_bin(V);
mail_field(<<"kind">>, <<"notice">>, _) -> <<"notice">>;
mail_field(<<"kind">>, <<"prompt">>, _) -> <<"prompt">>;
mail_field(<<"kind">>, <<"steer">>, _) -> <<"steer">>;
mail_field(<<"acceptedAt">>, V, _) -> timestamp(V);
mail_field(<<"receiving">>, true, _) -> true;
mail_field(<<"receiving">>, false, _) -> false;
mail_field(<<"bodyBytes">>, N, _) when is_integer(N), N >= 0, N =< 32768 -> N;
mail_field(<<"body">>, Bin, true)
  when is_binary(Bin), byte_size(Bin) > 0, byte_size(Bin) =< ?MAX_BODY -> utf8(Bin);
mail_field(_, _, _) -> throw(invalid_event).

lost_field(<<"count">>, Bin, _) -> decimal(Bin);
lost_field(_, _, _) -> throw(invalid_event).

work_field(<<"objective">>, Bin, _) -> text(Bin);
work_field(<<"reason">>, Bin, _) -> text(Bin);
work_field(<<"phase">>, Phase, _) ->
    case lists:member(Phase, [<<"planning">>, <<"implementing">>, <<"verifying">>,
                              <<"waiting">>, <<"completed">>, <<"failed">>]) of
        true -> Phase;
        false -> throw(invalid_event)
    end;
work_field(<<"outcome">>, <<"completed">>, _) -> <<"completed">>;
work_field(<<"outcome">>, <<"failed">>, _) -> <<"failed">>;
work_field(_, _, _) -> throw(invalid_event).

run_field(<<"activeRunId">>, null, _) -> null;
run_field(<<"activeRunId">>, Id, _) -> uuid_bin(Id);
run_field(_, _, _) -> throw(invalid_event).

op_field(<<"action">>, Action, _) ->
    case lists:member(Action, [<<"notice">>, <<"work">>, <<"guidance">>,
            <<"label">>, <<"interrupt">>, <<"sessionRead">>, <<"workAssign">>]) of
        true -> Action;
        false -> throw(invalid_event)
    end;
op_field(<<"state">>, State, _) when is_binary(State), byte_size(State) >= 1,
        byte_size(State) =< 32 -> utf8(State);
op_field(<<"body">>, Bin, true)
  when is_binary(Bin), byte_size(Bin) > 0, byte_size(Bin) =< ?MAX_BODY -> utf8(Bin);
op_field(_, _, _) -> throw(invalid_event).

tool_field(<<"toolCallId">>, Bin, _) when is_binary(Bin), byte_size(Bin) >= 1,
        byte_size(Bin) =< 256 -> utf8(Bin);
tool_field(<<"toolName">>, Bin, _) when is_binary(Bin), byte_size(Bin) >= 1,
        byte_size(Bin) =< 128 -> utf8(Bin);
tool_field(<<"state">>, <<"started">>, _) -> <<"started">>;
tool_field(<<"state">>, <<"ended">>, _) -> <<"ended">>;
tool_field(<<"state">>, <<"failed">>, _) -> <<"failed">>;
tool_field(_, _, _) -> throw(invalid_event).

text(Bin) when is_binary(Bin), byte_size(Bin) > 0, byte_size(Bin) =< ?MAX_TEXT ->
    utf8(Bin);
text(_) -> throw(invalid_event).

utf8(Bin) ->
    case unicode:characters_to_binary(Bin) of
        Bin -> Bin;
        _ -> throw(invalid_event)
    end.

decimal(Bin) when is_binary(Bin), byte_size(Bin) > 0, byte_size(Bin) =< 20 ->
    N = binary_to_integer(Bin),
    true = N >= 0 andalso N =< ?MAX_SEQ,
    true = Bin =:= integer_to_binary(N),
    Bin;
decimal(_) -> throw(invalid_event).

%% Journal envelope times are UNIX seconds (decimal). Do not store milliseconds.
timestamp(null) -> null;
timestamp(Bin) when is_binary(Bin) -> decimal(Bin);
timestamp(N) when is_integer(N), N >= 0, N =< ?MAX_SEQ ->
    integer_to_binary(N);
timestamp(_) -> throw(invalid_event).

optional_id(null) -> null;
optional_id(Id) -> uuid_bin(Id).

uuid_bin(Id) ->
    case bus_protocol:is_uuid(Id) of
        true -> Id;
        false -> throw(invalid_event)
    end.

uuid() ->
    <<A:32, B:16, _:4, C:12, _:2, E:14, F:48>> = crypto:strong_rand_bytes(16),
    iolist_to_binary(io_lib:format(
        "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
        [A, B, C bor 16#4000, E bor 16#8000, F])).
