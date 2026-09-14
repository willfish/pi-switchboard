-module(bus_watchdog).
-behaviour(gen_server).
-export([start_link/2, start/3, handshake/1, arm/2, complete/2, send_start/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link(Owner, Deadline) ->
    {ok, Pid} = gen_server:start_link(?MODULE, {Owner, Deadline}, []),
    Pid.
start(Owner, Deadline, Supervisor) ->
    {ok, Pid} = gen_server:start(?MODULE, {Owner, Deadline, Supervisor}, []),
    Pid.
handshake(Pid) -> gen_server:call(Pid, handshake).
arm(Pid, Deadline) -> gen_server:call(Pid, {arm, Deadline}).
complete(Pid, Ref) -> gen_server:call(Pid, {complete, Ref}).
send_start(Pid) -> gen_server:call(Pid, send_start).

init({Owner, Deadline, Supervisor}) ->
    {ok, State} = init({Owner, Deadline}),
    {ok, State#{supervisor_monitor => monitor(process, Supervisor)}};
init({Owner, Deadline}) ->
    Monitor = monitor(process, Owner),
    {ok, #{owner => Owner, monitor => Monitor, request => timer(Deadline), write => undefined}}.
handle_call(Request, From, State) ->
    ensure_live(State),
    call(Request, From, State).

call(handshake, _, State) ->
    cancel(maps:get(request, State)),
    {reply, ok, State#{request := undefined}};
call(send_start, From, #{write := undefined} = State) ->
    call({arm, erlang:monotonic_time(millisecond) + 5000}, From, State);
call(send_start, _, State) ->
    {reply, borrowed, State};
call({arm, Deadline}, _, #{write := undefined} = State) ->
    {Ref, _, _} = Timer = timer(Deadline),
    {reply, Ref, State#{write := Timer}};
call({complete, Ref}, _, #{write := {Ref, _, _} = Timer} = State) ->
    cancel(Timer),
    {reply, ok, State#{write := undefined}};
call({complete, _Stale}, _, State) ->
    {reply, ok, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info({expire, Ref}, #{owner := Owner, request := Request, write := Write} = State) ->
    case matches(Ref, Request) orelse matches(Ref, Write) of
        true -> exit(Owner, kill), {stop, normal, State};
        false -> {noreply, State}
    end;
handle_info({'DOWN', M, process, _, _}, #{supervisor_monitor := M, owner := Owner} = State) ->
    exit(Owner, kill),
    {stop, normal, State};
handle_info({'DOWN', M, process, _, _}, #{monitor := M} = State) ->
    {stop, normal, State};
handle_info(_, State) -> {noreply, State}.

timer(Deadline) ->
    Ref = make_ref(),
    Timer = erlang:send_after(max(0, Deadline-erlang:monotonic_time(millisecond)), self(), {expire,Ref}),
    {Ref,Timer,Deadline}.
cancel(undefined) -> ok;
cancel({_,Timer,_}) -> erlang:cancel_timer(Timer), ok.
matches(Ref, {Ref,_,_}) -> true;
matches(_, _) -> false.

%% A completion queued before a delayed timer signal must not revive an
%% operation whose absolute deadline has already elapsed.
ensure_live(#{owner := Owner, request := Request, write := Write}) ->
    Now = erlang:monotonic_time(millisecond),
    case expired(Request, Now) orelse expired(Write, Now) of
        true -> exit(Owner, kill), exit(normal);
        false -> ok
    end.
expired(undefined, _) -> false;
expired({_,_,Deadline}, Now) -> Now >= Deadline.
