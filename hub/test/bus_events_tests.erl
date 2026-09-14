-module(bus_events_tests).
-include_lib("eunit/include/eunit.hrl").

%% A failed pull consumed its coalesced wake. Keeping the stream alive would
%% leave it apparently healthy but unable to receive further mail/presence.
failed_pull_closes_stream_test() ->
    ?assertEqual(undefined, whereis(bus_store)),
    Ref = make_ref(),
    State = #{agent_id => <<"recipient">>, ref => Ref},
    Req = #{},
    lists:foreach(
        fun(Kind) ->
            ?assertEqual({stop, Req, State}, bus_events_h:info({bus, Ref, Kind}, Req, State))
        end,
        [mail, presence]
    ).

stale_wake_does_not_close_replacement_test() ->
    Ref = make_ref(),
    State = #{agent_id => <<"recipient">>, ref => Ref},
    Req = #{},
    ?assertEqual(
        {ok, Req, State, hibernate},
        bus_events_h:info({bus, make_ref(), mail}, Req, State)
    ).
