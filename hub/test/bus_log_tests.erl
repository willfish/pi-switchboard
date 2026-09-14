-module(bus_log_tests).
-include_lib("eunit/include/eunit.hrl").

structural_redaction_test() ->
    Marker = <<"fixture-log-payload-73d57">>,
    Reports = [
        #{label => {gen_server, terminate}, reason => {badmatch, Marker},
          state => Marker, message => Marker},
        #{label => {proc_lib, crash}, report => [[{dictionary, [{secret, Marker}]},
          {messages, [Marker]}, {error_info, {error, Marker, []}}], []]},
        #{label => {supervisor, child_terminated}, report => [{reason, Marker},
          {offender, [{mfargs, {fixture, start_link, [Marker]}}]}]}
    ],
    lists:foreach(fun(Report) ->
        Event = #{level => error, msg => {report, Report},
                  meta => #{secret => Marker, report_cb => fun(_) -> Marker end}},
        Safe = bus_log:filter(Event, none),
        Rendered = iolist_to_binary(logger_formatter:format(Safe, #{})),
        ?assertEqual(nomatch, binary:match(Rendered, Marker)),
        ?assertEqual(nomatch, binary:match(term_to_binary(Safe), Marker))
    end, Reports).

unknown_events_fail_closed_test() ->
    Marker = <<"fixture-unknown-log-cfa62">>,
    lists:foreach(fun(Msg) ->
        Safe = bus_log:filter(#{level => warning, msg => Msg,
                               meta => #{input => Marker}}, none),
        ?assertEqual(nomatch, binary:match(term_to_binary(Safe), Marker))
    end, [{string, Marker}, {"~p", [Marker]}, {report, #{input => Marker}}]).

status_redacts_every_field_test() ->
    Marker = <<"fixture-status-unknown-field-81ca">>,
    Status = maps:from_list([{K, Marker} || K <-
        [state, message, reason, log, future_otp_field]]),
    Safe = bus_store:format_status(Status),
    ?assertEqual(lists:sort(maps:keys(Status)), lists:sort(maps:keys(Safe))),
    ?assertEqual(nomatch, binary:match(term_to_binary(Safe), Marker)).
