-module(bus_log).

-export([install/0, filter/2, emergency/2, alert/2, critical/2, error/2,
         warning/2, notice/2, info/2, debug/2]).

%% This release is a dedicated hub VM. Fail closed for every Logger event,
%% including unknown future OTP/dependency report shapes. Never invoke the
%% original report callback or retain arbitrary metadata, reasons or arguments.
install() ->
    %% Own the primary chain in this dedicated VM. A surviving permissive
    %% filter must not accept raw events after OTP removes a failed sanitizer.
    logger:update_primary_config(#{filter_default => stop,
        filters => [{bus_redaction, {fun ?MODULE:filter/2, none}}]}).

filter(#{level := Level} = Event, _) ->
    #{level => Level,
      msg => {"pi_agent_bus ~p", [category(Event)]},
      meta => #{time => erlang:system_time(microsecond)}}.

category(#{msg := {report, #{label := {gen_server, terminate}}}}) -> gen_server_failure;
category(#{msg := {report, #{label := {proc_lib, crash}}}}) -> proc_lib_crash;
category(#{msg := {report, #{label := {supervisor, child_terminated}}}}) -> supervisor_child_terminated;
category(#{msg := {report, #{label := {supervisor, start_error}}}}) -> supervisor_start_error;
category(#{msg := {report, #{label := {supervisor, shutdown_error}}}}) -> supervisor_shutdown_error;
category(#{msg := {report, #{label := {supervisor, shutdown}}}}) -> supervisor_shutdown;
category(#{msg := {report, #{label := {supervisor, progress}}}}) -> supervisor_progress;
category(#{meta := #{bus_category := cowboy_failure}}) -> cowboy_failure;
category(#{meta := #{bus_category := ranch_failure}}) -> ranch_failure;
category(#{meta := #{bus_category := transport_event}}) -> transport_event;
category(#{msg := {report, #{label := {error_logger, error_msg},
                            format := Format}}}) when is_list(Format) ->
    transport_category(Format);
category(#{msg := {Format, _Args}}) when is_list(Format) -> transport_category(Format);
category(_) -> runtime_event.

%% Only inspect the library's format template, never its input-bearing args.
%% The primary filter also covers Cowboy's default error_logger bridge and
%% Ranch's default logger, so safety does not depend on listener options.
transport_category("Ranch" ++ _) -> ranch_failure;
transport_category("Unhandled exception" ++ _) -> cowboy_failure;
transport_category("Error in cow" ++ _) -> cowboy_failure;
transport_category("CRASH " ++ _) -> cowboy_failure;
transport_category(_) -> transport_event.

emit(Level, Format, _Args) ->
    Category = case is_list(Format) of
        true -> transport_category(Format);
        false -> transport_event
    end,
    logger:log(Level, "pi_agent_bus transport event", [], #{bus_category => Category}).

emergency(F, A) -> emit(emergency, F, A).
alert(F, A) -> emit(alert, F, A).
critical(F, A) -> emit(critical, F, A).
error(F, A) -> emit(error, F, A).
warning(F, A) -> emit(warning, F, A).
notice(F, A) -> emit(notice, F, A).
info(F, A) -> emit(info, F, A).
debug(F, A) -> emit(debug, F, A).
