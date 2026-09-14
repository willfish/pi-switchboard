-module(bus_sse_client_tests).
-include_lib("eunit/include/eunit.hrl").

fragmented_transfer_and_frames_test() ->
    Body = iolist_to_binary(cow_sse:events([
        #{comment => <<"keepalive">>},
        #{event => <<"message">>,data => <<"{\"id\":\"fixture\"}">>},
        #{comment => <<"keepalive">>}])),
    %% Split every HTTP chunk header, payload, CRLF and SSE delimiter across
    %% separate inputs, and separately split SSE frames across HTTP chunks.
    lists:foreach(fun(Wire) ->
        State = lists:foldl(fun(Byte,S) -> bus_sse_client:feed(<<Byte>>,S) end,
            bus_sse_client:new(),binary_to_list(Wire)),
        2 = bus_sse_client:comments(State),
        true = bus_sse_client:has_message(State,<<"fixture">>),
        ?assertEqual([#{<<"id">> => <<"fixture">>}], bus_sse_client:json_events(State, <<"message">>))
    end,[iolist_to_binary(cow_http_te:chunk(Body)),
        iolist_to_binary([cow_http_te:chunk(<<Byte>>) || Byte <- binary_to_list(Body)])]).

incomplete_json_event_test() ->
    Partial = <<"event: message\ndata: {\"id\":\"fixture\"}">>,
    S = bus_sse_client:feed(iolist_to_binary(cow_http_te:chunk(Partial)), bus_sse_client:new()),
    ?assertEqual([], bus_sse_client:json_events(S, <<"message">>)),
    Complete = bus_sse_client:feed(iolist_to_binary(cow_http_te:chunk(<<"\n\n">>)), S),
    ?assertEqual([#{<<"id">> => <<"fixture">>}], bus_sse_client:json_events(Complete, <<"message">>)).

coalesced_frames_test() ->
    Body = cow_sse:events([#{comment => <<"keepalive">>},#{comment => <<"keepalive">>}]),
    S = bus_sse_client:feed(iolist_to_binary(cow_http_te:chunk(Body)),bus_sse_client:new()),
    ?assertEqual(2,bus_sse_client:comments(S)).
