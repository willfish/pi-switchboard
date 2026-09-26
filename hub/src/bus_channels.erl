-module(bus_channels).

%% One shared channel directory and message journal. Bodies are stored once.
%% Per-channel sequence indexes select a page without scanning other channels
%% or copying packets per reader. Agent reads are a recent tail or a forward
%% delta. Operator reads can walk every retained sequence. Retention is the
%% earliest of 24 hours, 20,000 messages or 32 MiB of canonical message JSON.
%% The directory survives empty channels and agent expiry; store restart drops it.
%% Do not log message bodies.

-export([
    new/1,
    expire/3,
    list/1,
    ensure/4,
    classify/6,
    post/7,
    put_status/5,
    statuses/2,
    read/3,
    decode_name/1,
    decode_ensure/1,
    decode_post/1,
    decode_status/1,
    parse_query/2
]).

-define(MAX_CHANNELS, 128).
-define(MAX_MESSAGES, 20000).
-define(MAX_BYTES, 33554432).
-define(RETENTION_S, 86400).
-define(MAX_BODY, 4096).
-define(MAX_SUMMARY, 280).
-define(MAX_DEDUP, 4096).
-define(DEDUP_TTL, 120).
-define(MAX_STATUS, 4096).
-define(AGENT_LIMIT, 32).
-define(OPERATOR_LIMIT, 64).
-define(AGENT_BYTES, 262144).
-define(OPERATOR_BYTES, 1048576).
-define(SEQ_MAX, 18446744073709551615).

new(Wall) when is_integer(Wall) ->
    Name = <<"general">>,
    #{
        epoch => uuid(),
        next_seq => 1,
        bytes => 0,
        messages => #{},
        order => gb_trees:empty(),
        channels => #{Name => meta(Name, <<"Fleet-wide status and coordination">>, Wall)},
        index => #{Name => gb_trees:empty()},
        status => #{},
        dedup => #{}
    }.

expire(State, Mono, Wall) when is_integer(Mono), is_integer(Wall) ->
    drop_expired(State#{
        dedup => expire_dedup(maps:get(dedup, State), Mono),
        status => expire_status(maps:get(status, State), Wall)
    }, Wall).

list(State) ->
    Channels = [
        #{
            <<"name">> => Name,
            <<"topic">> => maps:get(topic, Meta),
            <<"retained">> => maps:get(retained, Meta),
            <<"lastSequence">> => seq_text(maps:get(last_seq, Meta)),
            <<"updatedAt">> => maps:get(updated_at, Meta)
        }
     || {Name, Meta} <- lists:sort(maps:to_list(maps:get(channels, State)))
    ],
    #{<<"epoch">> => maps:get(epoch, State), <<"channels">> => Channels}.

ensure(State, Name, Topic, Wall) ->
    Channels = maps:get(channels, State),
    case maps:get(Name, Channels, undefined) of
        undefined ->
            case maps:size(Channels) >= ?MAX_CHANNELS of
                true -> {error, capacity};
                false ->
                    Meta = meta(Name, Topic, Wall),
                    {ok, State#{
                        channels => Channels#{Name => Meta},
                        index => (maps:get(index, State))#{Name => gb_trees:empty()}
                    }, true}
            end;
        Meta ->
            Topic1 = case Topic of <<>> -> maps:get(topic, Meta); _ -> Topic end,
            case Topic1 =:= maps:get(topic, Meta) of
                true -> {ok, State, false};
                false ->
                    {ok, State#{channels => Channels#{Name => Meta#{topic => Topic1, updated_at => Wall}}}, true}
            end
    end.

classify(State, Name, From, Id, Kind, Body) ->
    Key = {From, Id},
    Digest = digest(Name, Kind, Body),
    case maps:get(Key, maps:get(dedup, State), undefined) of
        #{digest := Digest, result := Result} -> {duplicate, Result};
        #{} -> {error, conflict};
        undefined ->
            case maps:size(maps:get(dedup, State)) >= ?MAX_DEDUP of
                true -> {error, dedup_full};
                false -> fresh
            end
    end.

post(State, Name, From, Id, Body, Mono, Wall) ->
    case ensure(State, Name, <<>>, Wall) of
        {error, Reason} -> {error, Reason};
        {ok, State1, _} ->
            case append(State1, Name, Id, From, <<"say">>, Body, Wall) of
                {error, Reason} -> {error, Reason};
                {ok, State2, Result} ->
                    Key = {From, Id},
                    Dedup = (maps:get(dedup, State2))#{Key => #{
                        digest => digest(Name, <<"say">>, Body),
                        result => Result,
                        expires => Mono + ?DEDUP_TTL
                    }},
                    {ok, State2#{dedup => Dedup}, Result}
            end
    end.

put_status(State, Name, Status, _Mono, Wall) ->
    case ensure(State, Name, <<>>, Wall) of
        {error, Reason} -> {error, Reason};
        {ok, State1, _} ->
            From = maps:get(<<"from">>, Status),
            Key = {Name, From},
            Board0 = maps:get(status, State1),
            Previous = maps:get(Key, Board0, undefined),
            Current = #{
                summary => maps:get(<<"summary">>, Status),
                label => maps:get(<<"label">>, Status),
                project => maps:get(<<"project">>, Status),
                area => maps:get(<<"area">>, Status),
                updated_at => Wall
            },
            Same = case Previous of
                undefined -> false;
                Old -> maps:without([updated_at], Old) =:= maps:without([updated_at], Current)
            end,
            case Same of
                true ->
                    {ok, touch(State1#{status => Board0#{Key => Current}}, Name, Wall),
                        receipt(Name, From, <<"current">>, null)};
                false ->
                    case room_for_status(Board0, Key) of
                        {error, capacity} -> {error, capacity};
                        {ok, Board1} ->
                            case append(State1, Name, uuid(), From, <<"status">>, maps:get(summary, Current), Wall) of
                                {error, Reason} -> {error, Reason};
                                {ok, State2, Result} ->
                                    {ok, State2#{status => Board1#{Key => Current}},
                                        receipt(Name, From, <<"noted">>, maps:get(<<"sequence">>, Result))}
                            end
                    end
            end
    end.

statuses(State, Name) ->
    case maps:is_key(Name, maps:get(channels, State)) of
        false -> {error, not_found};
        true ->
            Rows = [
                #{
                    <<"agentId">> => AgentId,
                    <<"summary">> => maps:get(summary, Row),
                    <<"label">> => maps:get(label, Row),
                    <<"project">> => maps:get(project, Row),
                    <<"area">> => maps:get(area, Row),
                    <<"updatedAt">> => maps:get(updated_at, Row)
                }
             || {{Channel, AgentId}, Row} <- lists:sort(maps:to_list(maps:get(status, State))),
                Channel =:= Name
            ],
            {ok, #{<<"epoch">> => maps:get(epoch, State), <<"channel">> => Name, <<"statuses">> => Rows}}
    end.

read(State, Name, Query) ->
    case maps:is_key(Name, maps:get(channels, State)) of
        false -> {error, not_found};
        true -> {ok, page(State, Name, Query)}
    end.

decode_name(Name) when is_binary(Name) ->
    case valid_name(Name) of true -> {ok, Name}; false -> {error, invalid_schema} end;
decode_name(_) -> {error, invalid_schema}.

decode_ensure(Map) when is_map(Map) ->
    case extra(Map, [<<"from">>, <<"topic">>]) of
        ok ->
            case {uuid_field(Map, <<"from">>), topic_field(Map)} of
                {{ok, From}, {ok, Topic}} -> {ok, From, Topic};
                _ -> {error, invalid_schema}
            end;
        Error -> Error
    end;
decode_ensure(_) -> {error, invalid_schema}.

decode_post(Map) when is_map(Map) ->
    case extra(Map, [<<"id">>, <<"from">>, <<"body">>]) of
        ok ->
            case {uuid_field(Map, <<"id">>), uuid_field(Map, <<"from">>)} of
                {{ok, Id}, {ok, From}} ->
                    case body_field(Map) of
                        {ok, Body} -> {ok, Id, From, Body};
                        {error, Reason} -> {error, Reason};
                        error -> {error, invalid_schema}
                    end;
                _ -> {error, invalid_schema}
            end;
        Error -> Error
    end;
decode_post(_) -> {error, invalid_schema}.

decode_status(Map) when is_map(Map) ->
    case extra(Map, [<<"from">>, <<"summary">>, <<"label">>, <<"project">>, <<"area">>]) of
        ok ->
            case {uuid_field(Map, <<"from">>), summary_field(Map), optional_text(Map, <<"label">>, 200),
                    optional_text(Map, <<"project">>, 200), optional_area(Map)} of
                {{ok, From}, {ok, Summary}, {ok, Label}, {ok, Project}, {ok, Area}} ->
                    {ok, #{<<"from">> => From, <<"summary">> => Summary, <<"label">> => Label,
                        <<"project">> => Project, <<"area">> => Area}};
                _ -> {error, invalid_schema}
            end;
        Error -> Error
    end;
decode_status(_) -> {error, invalid_schema}.

parse_query(Pairs, Audience) when Audience =:= agent; Audience =:= operator ->
    try query(Pairs, Audience) catch throw:invalid_schema -> {error, invalid_schema} end;
parse_query(_, _) -> {error, invalid_schema}.

query(Pairs, Audience) ->
    Allowed = case Audience of
        agent -> [<<"after">>, <<"limit">>];
        operator -> [<<"after">>, <<"before">>, <<"limit">>]
    end,
    Map = lists:foldl(fun({Key, Value}, Acc) ->
        case lists:member(Key, Allowed) andalso not maps:is_key(Key, Acc) andalso is_binary(Value) of
            true -> Acc#{Key => Value};
            false -> throw(invalid_schema)
        end
    end, #{}, Pairs),
    Limit = limit(Map, Audience),
    After = maps:is_key(<<"after">>, Map),
    Before = maps:is_key(<<"before">>, Map),
    Query = case {Audience, After, Before} of
        {agent, false, false} -> #{audience => agent, mode => tail, limit => Limit};
        {agent, true, false} ->
            case seq(maps:get(<<"after">>, Map)) of
                0 -> #{audience => agent, mode => tail, limit => Limit};
                AfterSeq -> #{audience => agent, mode => forward, after_seq => AfterSeq, limit => Limit}
            end;
        {operator, false, false} -> #{audience => operator, mode => tail, limit => Limit};
        {operator, true, false} -> #{audience => operator, mode => forward, after_seq => seq(maps:get(<<"after">>, Map)), limit => Limit};
        {operator, false, true} -> #{audience => operator, mode => backward, before => seq(maps:get(<<"before">>, Map)), limit => Limit};
        _ -> throw(invalid_schema)
    end,
    {ok, Query}.

meta(Name, Topic, Wall) ->
    #{name => Name, topic => Topic, created_at => Wall, updated_at => Wall, retained => 0, last_seq => 0}.

touch(State, Name, Wall) ->
    Channels = maps:get(channels, State),
    Meta = maps:get(Name, Channels),
    State#{channels => Channels#{Name => Meta#{updated_at => Wall}}}.

receipt(Name, From, StateName, Sequence) ->
    #{<<"channel">> => Name, <<"agentId">> => From, <<"state">> => StateName, <<"sequence">> => Sequence}.

append(State, Name, Id, From, Kind, Body, Wall) ->
    Seq = maps:get(next_seq, State),
    case Seq > ?SEQ_MAX of
        true -> {error, capacity};
        false ->
            Msg = #{seq => Seq, channel => Name, id => Id, from => From, kind => Kind, body => Body, posted_at => Wall},
            Public = public_message(Msg),
            Bytes = byte_size(iolist_to_binary(json:encode(Public))),
            Msg1 = Msg#{bytes => Bytes},
            case admit(State, Bytes) of
                {error, Reason} -> {error, Reason};
                {ok, State1} ->
                    Index = maps:get(index, State1),
                    Tree = gb_trees:insert(Seq, true, maps:get(Name, Index)),
                    Channels = maps:get(channels, State1),
                    Meta = maps:get(Name, Channels),
                    Meta1 = Meta#{retained => maps:get(retained, Meta) + 1, last_seq => Seq, updated_at => Wall},
                    {ok, State1#{
                        next_seq => Seq + 1,
                        bytes => maps:get(bytes, State1) + Bytes,
                        messages => (maps:get(messages, State1))#{Seq => Msg1},
                        order => gb_trees:insert(Seq, Name, maps:get(order, State1)),
                        index => Index#{Name => Tree},
                        channels => Channels#{Name => Meta1}
                    }, acceptance(Name, Id, Seq, Wall)}
            end
    end.

acceptance(Name, Id, Seq, Wall) ->
    #{<<"id">> => Id, <<"channel">> => Name, <<"sequence">> => seq_text(Seq),
        <<"state">> => <<"accepted">>, <<"postedAt">> => Wall}.

admit(State, Extra) ->
    State1 = make_room(State, Extra),
    case map_size(maps:get(messages, State1)) >= ?MAX_MESSAGES orelse maps:get(bytes, State1) + Extra > ?MAX_BYTES of
        true -> {error, capacity};
        false -> {ok, State1}
    end.

make_room(State, Extra) ->
    Over = map_size(maps:get(messages, State)) >= ?MAX_MESSAGES orelse maps:get(bytes, State) + Extra > ?MAX_BYTES,
    case Over andalso not gb_trees:is_empty(maps:get(order, State)) of
        true -> make_room(drop_oldest(State), Extra);
        false -> State
    end.

drop_expired(State, Wall) ->
    case gb_trees:is_empty(maps:get(order, State)) of
        true -> State;
        false ->
            {Seq, _Name} = gb_trees:smallest(maps:get(order, State)),
            Msg = maps:get(Seq, maps:get(messages, State)),
            case maps:get(posted_at, Msg) + ?RETENTION_S =< Wall of
                true -> drop_expired(drop_oldest(State), Wall);
                false -> State
            end
    end.

drop_oldest(State) ->
    {Seq, Name, Order} = gb_trees:take_smallest(maps:get(order, State)),
    Msg = maps:get(Seq, maps:get(messages, State)),
    Index = maps:get(index, State),
    Tree = gb_trees:delete(Seq, maps:get(Name, Index)),
    Last = case gb_trees:is_empty(Tree) of
        true -> 0;
        false -> element(1, gb_trees:largest(Tree))
    end,
    Channels = maps:get(channels, State),
    Meta = maps:get(Name, Channels),
    Meta1 = Meta#{retained => maps:get(retained, Meta) - 1, last_seq => Last},
    State#{
        order => Order,
        messages => maps:remove(Seq, maps:get(messages, State)),
        bytes => maps:get(bytes, State) - maps:get(bytes, Msg),
        index => Index#{Name => Tree},
        channels => Channels#{Name => Meta1}
    }.

expire_dedup(Dedup, Mono) ->
    maps:filter(fun(_Key, #{expires := Exp}) -> Mono < Exp end, Dedup).

expire_status(Board, Wall) ->
    maps:filter(fun(_Key, #{updated_at := At}) -> At + ?RETENTION_S > Wall end, Board).

room_for_status(Board, Key) ->
    case maps:is_key(Key, Board) orelse map_size(Board) < ?MAX_STATUS of
        true -> {ok, Board};
        false -> {ok, drop_oldest_status(Board)}
    end.

drop_oldest_status(Board) ->
    {Oldest, _} = maps:fold(fun(Key, Row, undefined) -> {Key, Row};
                               (Key, Row, {_, Old}) ->
            case maps:get(updated_at, Row) < maps:get(updated_at, Old) of
                true -> {Key, Row};
                false -> {Key, Old}
            end
        end, undefined, Board),
    maps:remove(Oldest, Board).

page(State, Name, Query) ->
    Tree = maps:get(Name, maps:get(index, State)),
    RetainedFrom = first_seq(Tree),
    RetainedTo = maps:get(last_seq, maps:get(Name, maps:get(channels, State))),
    Limit = maps:get(limit, Query),
    {Seqs, Gap} = select(Tree, Query, RetainedFrom, Limit),
    Budget = case maps:get(audience, Query) of agent -> ?AGENT_BYTES; operator -> ?OPERATOR_BYTES end,
    Messages = take_budget(Seqs, maps:get(messages, State), Budget),
    frame(State, Name, Messages, RetainedFrom, RetainedTo, Gap, maps:get(audience, Query)).

select(Tree, #{mode := tail, limit := Limit}, _From, _Limit) ->
    {tail_seqs(Tree, Limit), false};
select(Tree, #{audience := agent, mode := forward, after_seq := After, limit := Limit}, From, _Limit) ->
    case From > 0 andalso After + 1 < From of
        true -> {tail_seqs(Tree, Limit), true};
        false -> {forward_seqs(Tree, After, Limit), false}
    end;
select(Tree, #{audience := operator, mode := forward, after_seq := After, limit := Limit}, From, _Limit) ->
    Start = case From > 0 andalso After + 1 < From of true -> From - 1; false -> After end,
    Gap = Start =/= After,
    {forward_seqs(Tree, Start, Limit), Gap};
select(Tree, #{mode := backward, before := Before, limit := Limit}, _From, _Limit) ->
    {backward_seqs(Tree, Before, Limit), false}.

frame(State, Name, Messages, RetainedFrom, RetainedTo, Gap, Audience) ->
    FromSeq = case Messages of [] -> 0; [First | _] -> binary_to_integer(maps:get(<<"seq">>, First)) end,
    ToSeq = case Messages of [] -> 0; _ -> binary_to_integer(maps:get(<<"seq">>, lists:last(Messages))) end,
    Earlier = Messages =/= [] andalso FromSeq > RetainedFrom,
    CaughtUp = Messages =:= [] orelse ToSeq =:= RetainedTo,
    #{
        <<"epoch">> => maps:get(epoch, State),
        <<"channel">> => Name,
        <<"window">> => case Audience of agent -> <<"recent">>; operator -> <<"history">> end,
        <<"fromSequence">> => seq_text(FromSeq),
        <<"toSequence">> => seq_text(ToSeq),
        <<"retainedFrom">> => seq_text(RetainedFrom),
        <<"retainedTo">> => seq_text(RetainedTo),
        <<"coverage">> => coverage(Messages, Gap),
        <<"caughtUp">> => CaughtUp,
        <<"earlier">> => Earlier,
        <<"nextCursor">> => case CaughtUp of true -> null; false -> seq_text(ToSeq) end,
        <<"earlierCursor">> => case Earlier of true -> seq_text(FromSeq); false -> null end,
        <<"messages">> => Messages
    }.

coverage([], true) -> <<"gap">>;
coverage([], false) -> <<"empty">>;
coverage(_, true) -> <<"gap">>;
coverage(_, false) -> <<"complete">>.

take_budget(Seqs, Messages, Max) ->
    take_budget(Seqs, Messages, Max, 0, []).

take_budget([], _Messages, _Max, _Used, Acc) ->
    lists:reverse(Acc);
take_budget([Seq | Rest], Messages, Max, Used, Acc) ->
    Msg = maps:get(Seq, Messages),
    Size = maps:get(bytes, Msg),
    case Acc =/= [] andalso Used + Size > Max of
        true -> lists:reverse(Acc);
        false -> take_budget(Rest, Messages, Max, Used + Size, [public_message(Msg) | Acc])
    end.

forward_seqs(Tree, After, Limit) ->
    collect_forward(gb_trees:iterator_from(After + 1, Tree), Limit, []).

collect_forward(_Iter, 0, Acc) ->
    lists:reverse(Acc);
collect_forward(Iter, Limit, Acc) ->
    case gb_trees:next(Iter) of
        none -> lists:reverse(Acc);
        {Seq, _, Next} -> collect_forward(Next, Limit - 1, [Seq | Acc])
    end.

backward_seqs(Tree, Before, Limit) ->
    queue:to_list(keep_last(gb_trees:iterator(Tree), Before, Limit, queue:new())).

keep_last(Iter, Before, Limit, Acc) ->
    case gb_trees:next(Iter) of
        none -> Acc;
        {Seq, _, _Next} when Seq >= Before -> Acc;
        {Seq, _, Next} ->
            Acc1 = queue:in(Seq, Acc),
            Acc2 = case queue:len(Acc1) > Limit of true -> queue:drop(Acc1); false -> Acc1 end,
            keep_last(Next, Before, Limit, Acc2)
    end.

tail_seqs(Tree, Limit) ->
    queue:to_list(keep_tail(gb_trees:iterator(Tree), Limit, queue:new())).

keep_tail(Iter, Limit, Acc) ->
    case gb_trees:next(Iter) of
        none -> Acc;
        {Seq, _, Next} ->
            Acc1 = queue:in(Seq, Acc),
            Acc2 = case queue:len(Acc1) > Limit of true -> queue:drop(Acc1); false -> Acc1 end,
            keep_tail(Next, Limit, Acc2)
    end.

first_seq(Tree) ->
    case gb_trees:is_empty(Tree) of
        true -> 0;
        false -> element(1, gb_trees:smallest(Tree))
    end.

public_message(Msg) ->
    #{
        <<"seq">> => seq_text(maps:get(seq, Msg)),
        <<"id">> => maps:get(id, Msg),
        <<"channel">> => maps:get(channel, Msg),
        <<"from">> => maps:get(from, Msg),
        <<"kind">> => maps:get(kind, Msg),
        <<"body">> => maps:get(body, Msg),
        <<"postedAt">> => maps:get(posted_at, Msg)
    }.

seq_text(0) -> <<"0">>;
seq_text(N) when is_integer(N), N > 0 -> integer_to_binary(N).

digest(Name, Kind, Body) ->
    crypto:hash(sha256, <<Name/binary, 0, Kind/binary, 0, Body/binary>>).

limit(Map, Audience) ->
    Max = case Audience of agent -> ?AGENT_LIMIT; operator -> ?OPERATOR_LIMIT end,
    Default = case Audience of agent -> 24; operator -> ?OPERATOR_LIMIT end,
    case maps:get(<<"limit">>, Map, undefined) of
        undefined -> Default;
        Bin ->
            N = seq(Bin),
            case N >= 1 andalso N =< Max of true -> N; false -> throw(invalid_schema) end
    end.

seq(<<"0">>) -> 0;
seq(Bin) when is_binary(Bin), byte_size(Bin) > 0, byte_size(Bin) =< 20 ->
    case binary:first(Bin) =/= $0 andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Bin)) of
        true ->
            N = binary_to_integer(Bin),
            case N > 0 andalso N =< ?SEQ_MAX of true -> N; false -> throw(invalid_schema) end;
        false -> throw(invalid_schema)
    end;
seq(_) -> throw(invalid_schema).

extra(Map, Required) ->
    Keys = maps:keys(Map),
    case {Required -- Keys, Keys -- Required} of
        {[], []} -> ok;
        _ -> {error, invalid_schema}
    end.

uuid_field(Map, Key) ->
    case maps:get(Key, Map, undefined) of
        Bin when is_binary(Bin) ->
            case bus_protocol:is_uuid(Bin) of true -> {ok, Bin}; false -> error end;
        _ -> error
    end.

body_field(Map) ->
    case maps:get(<<"body">>, Map, undefined) of
        Bin when is_binary(Bin) ->
            case unicode:characters_to_binary(Bin) of
                Bin when byte_size(Bin) > ?MAX_BODY -> {error, payload_too_large};
                Bin when byte_size(Bin) > 0 -> {ok, Bin};
                _ -> error
            end;
        _ -> error
    end.

topic_field(Map) ->
    case maps:get(<<"topic">>, Map, undefined) of
        <<>> -> {ok, <<>>};
        Bin when is_binary(Bin) -> text(Bin, 200);
        _ -> error
    end.

summary_field(Map) ->
    case maps:get(<<"summary">>, Map, undefined) of
        Bin when is_binary(Bin) -> text(Bin, ?MAX_SUMMARY);
        _ -> error
    end.

optional_text(Map, Key, Max) ->
    case maps:get(Key, Map, undefined) of
        <<>> -> {ok, <<>>};
        Bin when is_binary(Bin) -> text(Bin, Max);
        _ -> error
    end.

optional_area(Map) ->
    case maps:get(<<"area">>, Map, undefined) of
        <<>> -> {ok, <<>>};
        Bin when is_binary(Bin), byte_size(Bin) =< 32 ->
            case valid_name(Bin) of true -> {ok, Bin}; false -> error end;
        _ -> error
    end.

text(Bin, Max) ->
    case unicode:characters_to_list(Bin) of
        List when is_list(List), length(List) > 0, length(List) =< Max ->
            case controls(List) orelse binary:match(Bin, [<<"\n">>, <<"\r">>, <<16#2028/utf8>>, <<16#2029/utf8>>]) =/= nomatch of
                true -> error;
                false -> {ok, Bin}
            end;
        _ -> error
    end.

controls(List) ->
    lists:any(fun(C) -> C < 32 orelse (C >= 127 andalso C =< 159) end, List).

valid_name(Name) ->
    byte_size(Name) >= 1 andalso byte_size(Name) =< 32 andalso
        binary:first(Name) >= $a andalso binary:first(Name) =< $z andalso
        lists:all(fun(C) -> (C >= $a andalso C =< $z) orelse (C >= $0 andalso C =< $9) orelse C =:= $- end,
            binary_to_list(Name)).

uuid() ->
    <<A:32, B:16, _:4, C:12, _:2, E:14, F:48>> = crypto:strong_rand_bytes(16),
    iolist_to_binary(io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
        [A, B, C bor 16#4000, E bor 16#8000, F])).
