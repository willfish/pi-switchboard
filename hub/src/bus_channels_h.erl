-module(bus_channels_h).

-export([init/2]).

-define(MAX_BODY, 8192).
-define(REQUEST_TIMEOUT_MS, 5000).

init(Req0, Route) ->
    Deadline = maps:get(bus_deadline, Req0, erlang:monotonic_time(millisecond) + ?REQUEST_TIMEOUT_MS),
    Req = Req0#{bus_deadline => Deadline},
    Reply = within(Req, fun() ->
        case bus_http_h:authorize(Req) of
            false -> error_reply(Req, 401, <<"unauthorized">>, <<"invalid token">>);
            true -> dispatch(Req, Route)
        end
    end),
    {ok, Reply, []}.

dispatch(Req, list) ->
    case cowboy_req:method(Req) of
        <<"GET">> ->
            case cowboy_req:qs(Req) of
                <<>> -> list_channels(Req);
                _ -> error_reply(Req, 400, <<"invalid_schema">>, <<"empty query required">>)
            end;
        _ -> error_reply(Req, 405, <<"method_not_allowed">>, <<"GET required">>)
    end;
dispatch(Req, channel) ->
    case cowboy_req:method(Req) of
        <<"PUT">> -> mutate(Req, ensure);
        _ -> error_reply(Req, 405, <<"method_not_allowed">>, <<"PUT required">>)
    end;
dispatch(Req, messages) ->
    case cowboy_req:method(Req) of
        <<"GET">> -> read_messages(Req, agent);
        <<"POST">> -> mutate(Req, post);
        _ -> error_reply(Req, 405, <<"method_not_allowed">>, <<"GET or POST required">>)
    end;
dispatch(Req, status) ->
    case cowboy_req:method(Req) of
        <<"GET">> -> read_status(Req);
        <<"PUT">> -> mutate(Req, status);
        _ -> error_reply(Req, 405, <<"method_not_allowed">>, <<"GET or PUT required">>)
    end.

list_channels(Req) ->
    case bus_store:channels(maps:get(bus_deadline, Req)) of
        {ok, Doc} -> json_reply(Req, 200, Doc);
        {error, Reason} -> store_error(Req, Reason)
    end.

read_messages(Req, Audience) ->
    case name(Req) of
        {error, Reason} -> store_error(Req, Reason);
        {ok, Name} ->
            case query(Req, Audience) of
                {error, Reason} -> store_error(Req, Reason);
                {ok, Query} ->
                    case bus_store:channel_read(Name, Query, maps:get(bus_deadline, Req)) of
                        {ok, Page} -> json_reply(Req, 200, Page);
                        {error, Reason} -> store_error(Req, Reason)
                    end
            end
    end.

read_status(Req) ->
    case {name(Req), cowboy_req:qs(Req)} of
        {{ok, Name}, <<>>} ->
            case bus_store:channel_statuses(Name, maps:get(bus_deadline, Req)) of
                {ok, Doc} -> json_reply(Req, 200, Doc);
                {error, Reason} -> store_error(Req, Reason)
            end;
        {{error, Reason}, _} -> store_error(Req, Reason);
        {_, _} -> error_reply(Req, 400, <<"invalid_schema">>, <<"empty query required">>)
    end.

mutate(Req, Kind) ->
    case cowboy_req:qs(Req) of
        <<>> ->
            case name(Req) of
                {error, Reason} -> store_error(Req, Reason);
                {ok, Name} -> mutate_body(Req, Kind, Name)
            end;
        _ -> error_reply(Req, 400, <<"invalid_schema">>, <<"empty query required">>)
    end.

mutate_body(Req0, Kind, Name) ->
    case read_json(Req0) of
        {error, Status, Code, Message, Req} -> error_reply(Req, Status, Code, Message);
        {ok, Map, Req} ->
            case Kind of
                ensure -> ensure(Req, Name, Map);
                post -> post(Req, Name, Map);
                status -> status(Req, Name, Map)
            end
    end.

ensure(Req, Name, Map) ->
    case bus_channels:decode_ensure(Map) of
        {ok, From, Topic} ->
            case bus_store:channel_ensure(Name, Topic, From, maps:get(bus_deadline, Req)) of
                {ok, Doc} -> json_reply(Req, 200, Doc);
                {error, Reason} -> store_error(Req, Reason)
            end;
        {error, Reason} -> store_error(Req, Reason)
    end.

post(Req, Name, Map) ->
    case bus_channels:decode_post(Map) of
        {ok, Id, From, Body} ->
            case bus_store:channel_post(Name, {Id, From, Body}, maps:get(bus_deadline, Req)) of
                {ok, Doc} -> json_reply(Req, 202, Doc);
                {error, Reason} -> store_error(Req, Reason)
            end;
        {error, Reason} -> store_error(Req, Reason)
    end.

status(Req, Name, Map) ->
    case bus_channels:decode_status(Map) of
        {ok, Status} ->
            case bus_store:channel_status(Name, Status, maps:get(bus_deadline, Req)) of
                {ok, Doc} -> json_reply(Req, 200, Doc);
                {error, Reason} -> store_error(Req, Reason)
            end;
        {error, Reason} -> store_error(Req, Reason)
    end.

name(Req) ->
    case bus_channels:decode_name(cowboy_req:binding(name, Req)) of
        {ok, Name} -> {ok, Name};
        {error, Reason} -> {error, Reason}
    end.

query(Req, Audience) ->
    try bus_channels:parse_query(cowboy_req:parse_qs(Req), Audience)
    catch _:_ -> {error, invalid_schema} end.

read_json(Req0) ->
    case cowboy_req:header(<<"content-length">>, Req0) of
        undefined -> {error, 400, <<"invalid_schema">>, <<"Content-Length required">>, Req0};
        LengthBin ->
            case string:to_integer(binary_to_list(LengthBin)) of
                {N, []} when is_integer(N), N > ?MAX_BODY ->
                    {error, 413, <<"payload_too_large">>, <<"body too large">>, Req0};
                {N, []} when is_integer(N), N >= 0 -> read_chunks(Req0, [], 0);
                _ -> {error, 400, <<"invalid_schema">>, <<"invalid Content-Length">>, Req0}
            end
    end.

read_chunks(Req0, Chunks, Size) ->
    case remaining(Req0) of
        Remaining when Remaining =< 0 -> {error, 503, <<"capacity">>, <<"request timeout">>, Req0};
        Remaining ->
            try cowboy_req:read_body(Req0, #{length => ?MAX_BODY - Size + 1, period => Remaining, timeout => Remaining}) of
                {Status, Chunk, Req} ->
                    Total = Size + byte_size(Chunk),
                    case {remaining(Req) =< 0, Total > ?MAX_BODY, Status} of
                        {true, _, _} -> {error, 503, <<"capacity">>, <<"request timeout">>, Req};
                        {false, true, _} -> {error, 413, <<"payload_too_large">>, <<"body too large">>, Req};
                        {false, false, more} -> read_chunks(Req, [Chunk | Chunks], Total);
                        {false, false, ok} -> decode_body(iolist_to_binary(lists:reverse([Chunk | Chunks])), Req)
                    end
            catch exit:timeout -> {error, 503, <<"capacity">>, <<"request timeout">>, Req0};
                  exit:{timeout, _} -> {error, 503, <<"capacity">>, <<"request timeout">>, Req0}
            end
    end.

decode_body(Body, Req) ->
    case remaining(Req) =< 0 of
        true -> {error, 503, <<"capacity">>, <<"request timeout">>, Req};
        false ->
            case bus_protocol:decode_json(Body) of
                {ok, Map} when is_map(Map) -> {ok, Map, Req};
                {ok, _} -> {error, 400, <<"invalid_schema">>, <<"object required">>, Req};
                {error, {duplicate_key, _}} -> {error, 400, <<"invalid_schema">>, <<"duplicate keys">>, Req};
                {error, _} -> {error, 400, <<"invalid_schema">>, <<"invalid JSON">>, Req}
            end
    end.

within(Req, Fun) ->
    case remaining(Req) =< 0 of true -> store_error(Req, timeout); false -> Fun() end.

remaining(Req) -> maps:get(bus_deadline, Req) - erlang:monotonic_time(millisecond).

json_reply(Req, Status, Map) ->
    cowboy_req:reply(Status, headers(), bus_protocol:encode_map(Map), Req).

store_error(Req, payload_too_large) -> error_reply(Req, 413, <<"payload_too_large">>, <<"channel body too large">>);
store_error(Req, not_found) -> error_reply(Req, 404, <<"not_found">>, <<"unknown channel or runtime">>);
store_error(Req, conflict) -> error_reply(Req, 409, <<"conflict">>, <<"message id reused with different payload">>);
store_error(Req, dedup_full) -> retry_reply(Req, 503, <<"dedup_full">>, <<"deduplication cache full">>, 1);
store_error(Req, capacity) -> retry_reply(Req, 503, <<"capacity">>, <<"channel capacity exhausted">>, 2);
store_error(Req, overloaded) -> retry_reply(Req, 503, <<"capacity">>, <<"hub overloaded">>, 1);
store_error(Req, timeout) -> retry_reply(Req, 503, <<"capacity">>, <<"store timeout">>, 1);
store_error(Req, unavailable) -> retry_reply(Req, 503, <<"capacity">>, <<"store unavailable">>, 1);
store_error(Req, invalid_schema) -> error_reply(Req, 400, <<"invalid_schema">>, <<"invalid document">>);
store_error(Req, _) -> error_reply(Req, 400, <<"invalid_schema">>, <<"request rejected">>).

error_reply(Req, Status, Code, Message) ->
    cowboy_req:reply(Status, headers(), bus_protocol:encode_error(Code, Message), Req).

retry_reply(Req, Status, Code, Message, Seconds) ->
    cowboy_req:reply(Status, maps:put(<<"retry-after">>, integer_to_binary(Seconds), headers()),
        bus_protocol:encode_error(Code, Message), Req).

headers() ->
    #{<<"content-type">> => <<"application/json">>, <<"cache-control">> => <<"no-store">>}.
