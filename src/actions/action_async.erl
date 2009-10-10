% Nitrogen Web Framework for Erlang
% Copyright (c) 2008-2009 Rusty Klophaus
% See MIT-LICENSE for licensing information.

-module (action_async).
-include ("wf.inc").
-compile(export_all).
-define (COMET_INTERVAL, 10 * 1000).
-define (TEN_SECONDS, 10 * 1000).

% Comet and polling/continuations are now handled using Nitrogen's asynchronous
% processing scheme. This allows you to fire up an asynchronous process with the
% #async { fun=AsyncFunction } action.
%
% TERMINOLOGY:

% AsyncFunction - An Erlang function that executes in the background. The function
% generates Actions that are then sent to the browser via the accumulator. In addition
% each AsyncFunction is part of one (and only one) pool. The pool name provides a way
% to identify previously spawned processes, much like a Pid. Messages sent to the pool
% are distributed to all AsyncFunction processes in that pool.
%
% Pool - A pool contains one or more running AsyncFunctions. Any messages sent to the pool
% are distributed to all processes within the pool. Pools can either have a local
% or global scope. Local scope means that the pool applies only to the current
% series of page requests by a user. Global means that the pool applies to
% the entire system. Global pools provide the foundation for chat applets and 
% other interactive/multi-user software.
%
% Series - A series of requests to a Nitrogen resource. A series consists of 
% the first request plus any postbacks by the same visitor in the same browser
% window.
% 
% Accumulator - There is one accumulator per series. The accumulator holds
% Nitrogen actions generated by AsyncFunctions, and is checked at the end
% of each Nitrogen request for anything that should be sent to the browser.
%
% AsyncGuardian - There is one AsyncGuardian for each AsyncFunction. The
% Guardian is responsible for informing the Accumulator when an AsyncFunction
% dies, and vice versa.

render_action(Record) -> 
	% This will immediately trigger a postback to event/1 below.
	#event {
		type=system,
		delay=0,
		delegate=?MODULE,
		postback={spawn_async_function, Record}
	}.
	
% This event is called to start a Nitrogen async loop.
% In the process of starting the function, it will create
% an accumulator and a pool if they don't already exist.
event({spawn_async_function, Record}) ->
	?PRINT(Record),
	% Some values...
	SeriesID = wf_context:series_id(),
	Pool = Record#async.pool,
	Scope = Record#async.scope,

	% Get or start the accumulator process, which is used to hold any Nitrogen Actions 
	% that are generated by async processes.
	{ok, AccumulatorPid} = get_accumulator_pid(SeriesID),
	
	% Get or start the pool process, which is a distributor that sends Erlang messages
	% to the running async function.
	{ok, PoolPid} = get_pool_pid(SeriesID, Pool, Scope), 
	
	% Create a process for the AsyncFunction...
	AsyncFunction = Record#async.function,
	Context = wf_context:context(),
	FunctionPid = erlang:spawn(fun() -> wf_context:context(Context), AsyncFunction(), flush() end),
	
	% Create a process for the AsyncGuardian...
	DyingMessage = Record#async.dying_message,
	GuardianPid = erlang:spawn(fun() -> guardian_process(FunctionPid, AccumulatorPid, PoolPid, DyingMessage) end),
	
	% Register the function with the accumulator and the pool.
	AccumulatorPid!{add_guardian, GuardianPid},
	PoolPid!{add_process, FunctionPid},

	wf:wire(start_async_event());
		
% This clause is the heart of async functions. It
% is first triggered by the event/1 function above,
% and then continues to trigger itself in a loop,
% but in different ways depending on whether the
% page is doing comet-based or polling-based
% background updates.
%
% To update the page, the function gathers actions 
% in the accumulator and wires both the actions and
% the looping event.
event(start_async) ->
	case wf_context:async_mode() of
		comet ->
			% Tell the accumulator to stay alive until
			% we call back, with some padding...
			set_lease(?COMET_INTERVAL + ?TEN_SECONDS),
			
			% Start the polling postback...
			Actions = get_actions_blocking(?COMET_INTERVAL),
			Event = start_async_event(),
			wf:wire([Actions, Event]),
			
			% Renew the lease, because the blocking call
			% could have used up a significant amount of time.
			set_lease(?COMET_INTERVAL + ?TEN_SECONDS);

			
		{poll, Interval} ->
			% Tell the accumulator to stay alive until
			% we call back, with some padding.
			set_lease(Interval + ?TEN_SECONDS),

			% Start the polling postback...
			Actions = get_actions(),
			Event = start_async_event(Interval),
			wf:wire([Actions, Event])
	end.


	
%% - POOL - %%

% Retrieve a Pid from the process_cabinet for the specified pool.
% A pool can either be local or global. In a local pool, messages sent
% to the pool are only sent to async processes for one browser window.
% In a global pool, messages sent to the pool are sent to all processes
% in the pool across the entire system. This is useful for multi-user applications.
get_pool_pid(SeriesID, Pool, Scope) ->
	PoolID = case Scope of
		local  -> {Pool, SeriesID};
		global -> {Pool, global}
	end,
	{ok, _Pid} = process_cabinet_handler:get_pid({async_pool, PoolID}, fun() -> pool_loop([]) end).

% The pool loop keeps track of the AsyncFunction processes in a pool, 
% and is responsible for distributing messages to all processes in the pool.
pool_loop(Processes) -> 
	receive
		{add_process, Pid} ->
			erlang:monitor(process, Pid), 
			pool_loop([Pid|Processes]);
			
		{'DOWN', _, process, Pid, _} ->
			pool_loop(Processes -- [Pid]);
			
		Message ->
			?PRINT(Message),
			?PRINT(Processes),
			[Pid!Message || Pid <- Processes],
			pool_loop(Processes)
	end.



%% - ACCUMULATOR - %%

% Retrieve a Pid from the process cabinet for the specified Series.
get_accumulator_pid(SeriesID) ->
	{ok, _Pid} = process_cabinet_handler:get_pid({async_accumulator, SeriesID}, fun() -> accumulator_loop([], [], none, undefined) end).

% The accumulator_loop keeps track of guardian processes within a pool,
% and gathers actions from the various AsyncFunctions in order 
% to send it the page when the actions are requested.
%
accumulator_loop(Guardians, Actions, Waiting, TimerRef) ->
	receive
		{add_guardian, Pid} ->
			erlang:monitor(process, Pid),
			accumulator_loop([Pid|Guardians], Actions, Waiting, TimerRef);
		
		{'DOWN', _, process, Pid, _} ->
			accumulator_loop(Guardians -- [Pid], Actions, Waiting, TimerRef);
		
		{add_actions, NewActions} ->
			case is_remote_process_alive(Waiting) of
				true -> 
					Waiting!{actions, [NewActions|Actions]},
					accumulator_loop(Guardians, [], none, TimerRef);
				false ->
					accumulator_loop(Guardians, [NewActions|Actions], none, TimerRef)
			end;
			
		{get_actions_blocking, Pid} when Actions == [] ->
			accumulator_loop(Guardians, [], Pid, TimerRef);
			
		{get_actions_blocking, Pid} when Actions /= [] ->
			Pid!{actions, Actions},
			accumulator_loop(Guardians, [], none, TimerRef);

		{get_actions, Pid} ->
			Pid!{actions, Actions},
			accumulator_loop(Guardians, [], none, TimerRef);
			
		{set_lease, LengthInMS} ->
			timer:cancel(TimerRef),
			{ok, NewTimerRef} = timer:send_after(LengthInMS, die),
			accumulator_loop(Guardians, Actions, Waiting, NewTimerRef);
									
		die -> 
			% Nothing to do here. guardian_process will detect that
			% we've died and update the pool.
			ok;
			
		Other ->
			?PRINT({accumulator_loop, unhandled_event, Other})
	end.

% The guardian process monitors the running AsyncFunction and
% the running Accumulator. If either one dies, then send 
% DyingMessage to the pool, and end.
guardian_process(FunctionPid, AccumulatorPid, PoolPid, DyingMessage) ->
	erlang:monitor(process, FunctionPid),
	erlang:monitor(process, AccumulatorPid),
	erlang:monitor(process, PoolPid),	
	receive
		{'DOWN', _, process, FunctionPid, _} ->
			% The AsyncFunction process has died. 
			% Communicate dying_message to the pool and exit.
			PoolPid!DyingMessage;
			
		{'DOWN', _, process, AccumulatorPid, _} -> 
			% The accumulator process has died. 
			% Communicate dying_message to the pool, 
			% kill the AsyncFunction process, and exit.
			PoolPid!DyingMessage,
			erlang:exit(FunctionPid, async_die);
		
		{'DOWN', _, process, PoolPid, _} ->
			% The pool should never die on us.
			?PRINT(unexpected_pool_death);
			
		Other ->
			?PRINT({FunctionPid, AccumulatorPid, PoolPid}),
			?PRINT({guardian_process, unhandled_event, Other})
	end.
	
%% @doc Convenience method to start a comet process.
comet(F) -> 
	comet(F, default).
	
%% @doc Convenience method to start a comet process.
comet(F, Pool) ->
	SeriesID = wf_context:series_id(),
	wf:wire(#async { function=F, pool=Pool, scope=local }),
	{ok, PoolPid} = get_pool_pid(SeriesID, Pool, local),
	PoolPid.
	
%% @doc Convenience method to start a comet process with global pool.
comet_global(F, Pool) ->
	SeriesID = wf_context:series_id(),
	wf:wire(#async { function=F, pool=Pool, scope=global }),
	{ok, PoolPid} = get_pool_pid(SeriesID, Pool, global),
	PoolPid.
			
%% @doc Gather all wired actions, and send to the accumulator.
flush() ->
	SeriesID = wf_context:series_id(),
	{ok, AccumulatorPid} = get_accumulator_pid(SeriesID),
	Actions = wf_context:actions(),
	wf_context:clear_actions(),
	AccumulatorPid!{add_actions, Actions},
	ok.
	
%% @doc Send a message to all processes in the specified local pool.
send(Pool, Message) ->
	inner_send(Pool, local, Message).
	
%% @doc Send a message to all processes in the specified global pool.
send_global(Pool, Message) ->
	inner_send(Pool, global, Message).

%%% PRIVATE FUNCTIONS %%%

inner_send(Pool, Scope, Message) ->
	?PRINT({Pool, Scope, Message}),
	SeriesID = wf_context:series_id(),
	{ok, PoolPid} = get_pool_pid(SeriesID, Pool, Scope),
	PoolPid!Message,
	ok.

% Get actions from accumulator. If there are no actions currently in the
% accumulator, then [] is immediately returned.
get_actions() ->
	SeriesID = wf_context:series_id(),
	{ok, AccumulatorPid} = get_accumulator_pid(SeriesID),
	AccumulatorPid!{get_actions, self()},
	receive
		{actions, X} -> X;
		Other -> ?PRINT({unhandled_event, Other}), []
	end.
	
% Get actions from accumulator in a blocking fashion. If there are no actions
% currently in the accumulator, then this blocks for up to Timeout milliseconds.
% This works by telling Erlang to send a dummy 'add_actions' command to the accumulator
% that will be executed when the timeout expires.
get_actions_blocking(Timeout) ->
	SeriesID = wf_context:series_id(),
	{ok, AccumulatorPid} = get_accumulator_pid(SeriesID),
	TimerRef = erlang:send_after(Timeout, AccumulatorPid, {add_actions, []}),
	AccumulatorPid!{get_actions_blocking, self()},
	receive 
		{actions, X} -> erlang:cancel_timer(TimerRef), X;			
		Other -> ?PRINT({unhandled_event, Other}), []
	end.
	
set_lease(LengthInMS) ->
	SeriesID = wf_context:series_id(),
	{ok, AccumulatorPid} = get_accumulator_pid(SeriesID),
	AccumulatorPid!{set_lease, LengthInMS}.

% Convenience function to return an #event that will call event(start_async) above.
start_async_event() ->
	#event { type=system, delay=0, delegate=?MODULE, postback=start_async }.
	
% Convenience function to return an #event that will call event(start_async) above.
start_async_event(Interval) ->
	#event { type=system, delay=Interval, delegate=?MODULE, postback=start_async }.
		

% Return true if the process is alive, accounting for processes on other nodes.	
is_remote_process_alive(Pid) ->
	is_pid(Pid) andalso
	pong == net_adm:ping(node(Pid)) andalso
	rpc:call(node(Pid), erlang, is_process_alive, [Pid]).