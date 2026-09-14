%% Ranch owns this one-shot connection supervisor; Cowboy owns its request
%% children. No child is restarted, and no request can be replayed.
-module(bus_connection_sup).
-behaviour(gen_server).
-export([start_link/3, children/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Ref, Transport, Opts) ->
    gen_server:start_link(?MODULE, {Ref, Transport, Opts}, []).
children(Pid) -> gen_server:call(Pid, children).

init({Ref, Transport, #{bus_deadline := Deadline} = Opts}) ->
    process_flag(trap_exit, true),
    Conn = proc_lib:spawn_link(bus_connection, connection_process,
        [self(), Ref, Transport, Opts]),
    CM = monitor(process, Conn),
    %% Monitor rather than link the watchdog. If this supervisor is killed,
    %% the watchdog must survive long enough to kill even a blocked Cowboy.
    W = bus_watchdog:start(Conn, Deadline, self()),
    WM = monitor(process, W),
    Conn ! {bus_bootstrap, self(), W},
    {ok, #{connection => Conn, connection_monitor => CM,
        watchdog => W, watchdog_monitor => WM}}.
handle_call(children, _, #{connection := Conn, watchdog := W} = State) ->
    {reply, {Conn, W}, State};
handle_call(which_children, _, #{connection := Conn, watchdog := W} = State) ->
    {reply, [{connection,Conn,supervisor,[cowboy_http]},
        {watchdog,W,worker,[bus_watchdog]}], State};
handle_call(count_children, _, State) ->
    {reply, [{specs,2},{active,2},{supervisors,1},{workers,1}], State};
handle_call(_, _, State) ->
    {reply, {error,one_shot_connection}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info({'DOWN', WM, process, W, _},
        #{watchdog_monitor := WM, watchdog := W, connection := Conn} = State) ->
    %% Normal helper exit is just as unsafe as a crash. Do not rely on a
    %% trapped EXIT reaching Cowboy's receive loop while a send is blocked.
    exit(Conn, kill),
    {stop, normal, State};
handle_info({'DOWN', CM, process, Conn, _},
        #{connection_monitor := CM, connection := Conn} = State) ->
    {stop, normal, State};
handle_info({'EXIT', Conn, _}, #{connection := Conn} = State) ->
    {stop, normal, State};
handle_info(_, State) -> {noreply, State}.

terminate(_, #{connection := Conn, connection_monitor := CM,
        watchdog := W, watchdog_monitor := WM}) ->
    Deadline = erlang:monotonic_time(millisecond) + 3000,
    %% Plain shutdown drains Cowboy's last stream indefinitely for SSE.
    %% A tagged exit from its actual parent runs stream/child cleanup and
    %% socket linger immediately. Keep the watchdog until Cowboy is gone.
    exit(Conn, {shutdown, bus_connection_stop}),
    await_connection(Conn, CM, W, WM, Deadline),
    case is_process_alive(W) of
        false -> ok;
        true ->
            exit(W, kill),
            receive {'DOWN', WM, process, W, _} -> ok end
    end.

await_connection(Conn, CM, W, WM, Deadline) ->
    Left = max(0, Deadline-erlang:monotonic_time(millisecond)),
    case is_process_alive(Conn) of
        false -> ok;
        true ->
            receive
                {'DOWN', CM, process, Conn, _} -> ok;
                {'DOWN', WM, process, W, _} ->
                    exit(Conn, kill),
                    await_connection(Conn, CM, W, WM, Deadline)
            after Left ->
                exit(Conn, kill),
                receive {'DOWN', CM, process, Conn, _} -> ok end
            end
    end.
