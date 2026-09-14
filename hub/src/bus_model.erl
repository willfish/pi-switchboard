-module(bus_model).

-export([
    new/0,
    put_agent/4,
    delete_agent/2,
    expire/2,
    list_agents/3,
    accept_mail/4,
    pop_mail/3,
    set_receiving/3,
    public_mail/1,
    has_agent/3, public_agent/2
]).

-define(MAX_AGENTS, 5000).
-define(MAX_MAIL, 32).
-define(MAX_PUBLIC_MAIL_BYTES, 32768).
-define(MAX_QUEUED_BYTES, 5_000_000_000).
-define(PRESENCE_TTL, 15).
-define(MAIL_TTL, 60).
-define(DEDUP_TTL, 120).
-define(MAX_DEDUP, 4096).

new() ->
    #{
        agents => #{},
        mail => #{},
        queued_bytes => 0,
        %% Internal state only, not a runtime configuration interface.
        queue_byte_limit => ?MAX_QUEUED_BYTES,
        dedup => #{},
        receiving => #{}
    }.

put_agent(State, Agent, MonoNow, WallNow)
    when is_map(Agent), is_integer(MonoNow), is_integer(WallNow) ->
    Id = maps:get(<<"agentId">>, Agent),
    Agents0 = maps:get(agents, State),
    Exists = has_agent(State, Id, MonoNow),
    Full = not Exists andalso maps:size(Agents0) >= ?MAX_AGENTS andalso
        maps:size(live_agents(Agents0, MonoNow)) >= ?MAX_AGENTS,
    case (not Exists) andalso Full of
        true ->
            {error, capacity};
        false ->
            State1 =
                case Exists of
                    true -> State;
                    false -> delete_agent(State, Id)
                end,
            Stored = Agent#{last_mono => MonoNow, last_wall => WallNow},
            Agents1 = maps:get(agents, State1),
            {ok, State1#{agents => Agents1#{Id => Stored}}}
    end.

delete_agent(State, AgentId) when is_binary(AgentId) ->
    Agents = maps:remove(AgentId, maps:get(agents, State)),
    State1 = replace_queue(State, AgentId, []),
    Receiving = maps:remove(AgentId, maps:get(receiving, State)),
    State1#{agents := Agents, receiving := Receiving}.

expire(State, MonoNow) when is_integer(MonoNow) ->
    Agents0 = maps:get(agents, State),
    Dead = [
        Id
     || Id := Agent <- Agents0,
        not is_live(Agent, MonoNow)
    ],
    State1 = lists:foldl(
        fun(Id, Acc) -> delete_agent(Acc, Id) end, expire_dedup(State, MonoNow), Dead
    ),
    maps:fold(
        fun(Id, Queue, Acc) ->
            replace_queue(Acc, Id, drop_expired(Queue, MonoNow))
        end,
        State1,
        maps:get(mail, State1)
    ).

list_agents(State, MonoNow, WallNow) when is_integer(MonoNow), is_integer(WallNow) ->
    Receiving = maps:get(receiving, State),
    [
        public_agent(Agent, maps:is_key(Id, Receiving))
     || Id := Agent <- maps:get(agents, State),
        is_live(Agent, MonoNow)
    ].

accept_mail(State, Msg, MonoNow, WallNow) ->
    From = maps:get(<<"from">>, Msg),
    Id = maps:get(<<"id">>, Msg),
    DedupKey = {From, Id},
    Digest = digest(Msg),
    Dedup0 = maps:get(dedup, State),
    case maps:get(DedupKey, Dedup0, undefined) of
        #{digest := Digest, result := Result, expires_mono := Exp} when MonoNow < Exp ->
            {ok, State, Result};
        #{digest := Other, expires_mono := Exp} when Other =/= Digest, MonoNow < Exp ->
            {error, conflict};
        _ ->
            accept_new_mail(State, Msg, MonoNow, WallNow, DedupKey, Digest)
    end.

pop_mail(State, AgentId, MonoNow) ->
    case has_agent(State, AgentId, MonoNow) of
        false -> {empty, delete_agent(State, AgentId)};
        true -> pop_live_mail(State, AgentId, MonoNow)
    end.

pop_live_mail(State, AgentId, MonoNow) ->
    Mail0 = maps:get(mail, State),
    Queue = maps:get(AgentId, Mail0, []),
    case drop_expired(Queue, MonoNow) of
        [] ->
            {empty, replace_queue(State, AgentId, [])};
        [Head | Rest] ->
            {ok, replace_queue(State, AgentId, Rest), Head}
    end.

accept_new_mail(State, Msg, MonoNow, WallNow, DedupKey, Digest) ->
    From = maps:get(<<"from">>, Msg),
    To = maps:get(<<"to">>, Msg),
    Kind = maps:get(<<"kind">>, Msg),
    Agents = maps:get(agents, State),
    case From =:= To of
        true ->
            {error, self_send};
        false ->
            case {live_agent(From, Agents, MonoNow), live_agent(To, Agents, MonoNow)} of
                {undefined, _} ->
                    {error, not_found};
                {_, undefined} ->
                    {error, not_found};
                {Sender, Recipient} ->
                    ControlOk =
                        Kind =:= <<"notice">> orelse
                            maps:get(<<"acceptsControl">>, Recipient) =:= true,
                    case ControlOk of
                        false ->
                            {error, control_disabled};
                        true ->
                            enqueue(State, Msg, Sender, To, MonoNow, WallNow, DedupKey, Digest)
                    end
            end
    end.

enqueue(State, Msg, Sender, To, MonoNow, WallNow, DedupKey, Digest) ->
    Mail0 = maps:get(mail, State),
    Queue = maps:get(To, Mail0, []),
    LiveQueue = drop_expired(Queue, MonoNow),
    Dedup0 = maps:get(dedup, State),
    LiveDedup = maps:filter(
        fun(_, #{expires_mono := Exp}) -> MonoNow < Exp end,
        Dedup0
    ),
    case maps:size(LiveDedup) >= ?MAX_DEDUP andalso not maps:is_key(DedupKey, LiveDedup) of
        true ->
            {error, dedup_full};
        false ->
            case length(LiveQueue) >= ?MAX_MAIL of
                true ->
                    {error, mailbox_full};
                false ->
                    AcceptedAt = WallNow,
                    ExpiresAt = WallNow + ?MAIL_TTL,
                    Entry = Msg#{
                        <<"acceptedAt">> => AcceptedAt,
                        <<"expiresAt">> => ExpiresAt,
                        <<"expires_mono">> => MonoNow + ?MAIL_TTL,
                        <<"sender">> => sender_snapshot(Sender)
                    },
                    Result = #{
                        <<"id">> => maps:get(<<"id">>, Msg),
                        <<"to">> => To,
                        <<"state">> => <<"accepted">>,
                        <<"expiresAt">> => ExpiresAt,
                        <<"receiving">> => maps:is_key(To, maps:get(receiving, State))
                    },
                    Dedup1 = LiveDedup#{
                        DedupKey => #{
                            digest => Digest,
                            result => Result,
                            expires_mono => MonoNow + ?DEDUP_TTL
                        }
                    },
                    %% Charge the exact JSON payload, including its frozen sender
                    %% snapshot, but not SSE framing or internal expiry/accounting
                    %% metadata. Cache the size so removal never re-encodes mail.
                    Bytes = iolist_size(json:encode(public_mail(Entry))),
                    State1 = replace_queue(State, To, LiveQueue),
                    case {Bytes > ?MAX_PUBLIC_MAIL_BYTES,
                        maps:get(queued_bytes, State1) + Bytes >
                            maps:get(queue_byte_limit, State1)} of
                        {true, _} ->
                            {error, payload_too_large};
                        {false, true} ->
                            {error, capacity};
                        {false, false} ->
                            State2 = replace_queue(State1, To,
                                LiveQueue ++ [Entry#{wire_bytes => Bytes}]),
                            {ok, State2#{dedup := Dedup1}, Result}
                    end
            end
    end.

%% Update the global counter by the changed recipient's delta only. Each
%% queue has at most MAX_MAIL entries; sending never scans other mailboxes.
%% Expired entries elsewhere remain charged until the periodic sweep removes
%% them. Rejected transitions leave the original state (and charges) intact.
replace_queue(State, AgentId, Queue) ->
    Mail0 = maps:get(mail, State),
    Old = maps:get(AgentId, Mail0, []),
    Mail1 = case Queue of
        [] -> maps:remove(AgentId, Mail0);
        _ -> Mail0#{AgentId => Queue}
    end,
    State#{
        mail := Mail1,
        queued_bytes := maps:get(queued_bytes, State) + queue_bytes(Queue) - queue_bytes(Old)
    }.

queue_bytes(Queue) ->
    lists:sum([maps:get(wire_bytes, Entry) || Entry <- Queue]).

expire_dedup(State, MonoNow) ->
    Dedup = maps:filter(
        fun(_, #{expires_mono := Exp}) -> MonoNow < Exp end,
        maps:get(dedup, State)
    ),
    State#{dedup := Dedup}.

live_agents(Agents, MonoNow) ->
    maps:filter(fun(_, Agent) -> is_live(Agent, MonoNow) end, Agents).

is_live(#{last_mono := Last}, MonoNow) ->
    MonoNow - Last < ?PRESENCE_TTL.

drop_expired(Queue, MonoNow) ->
    [Item || Item <- Queue, maps:get(<<"expires_mono">>, Item) > MonoNow].

public_agent(Agent, Receiving) ->
    Public = maps:with(
        [
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
        Agent
    ),
    Public#{
        <<"updatedAt">> => maps:get(last_wall, Agent),
        <<"receiving">> => Receiving
    }.

set_receiving(State, AgentId, true) ->
    Rec = maps:get(receiving, State),
    State#{receiving := Rec#{AgentId => true}};
set_receiving(State, AgentId, false) ->
    Rec = maps:remove(AgentId, maps:get(receiving, State)),
    State#{receiving := Rec}.

has_agent(State, AgentId, MonoNow) ->
    live_agent(AgentId, maps:get(agents, State), MonoNow) =/= undefined.

live_agent(Id, Agents, Now) ->
    case maps:get(Id, Agents, undefined) of
        undefined -> undefined;
        Agent -> case is_live(Agent, Now) of true -> Agent; false -> undefined end
    end.

public_mail(Msg) ->
    maps:with(
        [
            <<"id">>,
            <<"from">>,
            <<"to">>,
            <<"kind">>,
            <<"body">>,
            <<"sender">>,
            <<"acceptedAt">>,
            <<"expiresAt">>
        ],
        Msg
    ).

sender_snapshot(Agent) ->
    #{
        <<"host">> => maps:get(<<"host">>, Agent),
        <<"label">> => maps:get(<<"label">>, Agent)
    }.

digest(Msg) ->
    crypto:hash(
        sha256,
        json:encode(#{
            <<"id">> => maps:get(<<"id">>, Msg),
            <<"from">> => maps:get(<<"from">>, Msg),
            <<"to">> => maps:get(<<"to">>, Msg),
            <<"kind">> => maps:get(<<"kind">>, Msg),
            <<"body">> => maps:get(<<"body">>, Msg)
        })
    ).
