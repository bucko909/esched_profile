-module(esched_profile).

-behaviour(gen_server).

-export([
		 start_link/0,
		 init/1,
		 handle_info/2,
		 handle_call/3,
		 burn/1,
		 burnn/2
		]).

-define(SERVER, ?MODULE).

-record(state,
		{
		 current=empty_current() :: tuple(),
		 sched_stats=empty_sched_stats() :: tuple(),
		 sched_switches=empty_sched_stats() :: tuple(),
		 stats=#{} :: maps:map(pid() | port(), integer()),
		 out=element(2, {ok, _} = file:open("out", [write]))
		}).

start_link() ->
	gen_server:start_link({local, ?SERVER}, ?MODULE, [], [{scheduler, 3}]).

init([]) ->
	erlang:send_after(1000, self(), {output_stats, erlang:system_time(microsecond)}),
	erlang:trace(all, true, [exiting, running, running_procs, running_ports, scheduler_id, timestamp, cpu_timestamp, {tracer, self()}]),
	ets:new(x, [named_table, ordered_set]),
	ets:new(y, [public, named_table, ordered_set]),
	InitState = #state{},
	{ok, InitState}.

ets_lastn(E, N) ->
	lists:reverse(ets_lastn(E, ets:last(E), N)).

ets_lastn(_, _, 0) -> [];
ets_lastn(E, R, N) ->
	[element(2, hd(ets:lookup(E, R)))|ets_lastn(E, ets:prev(E, R), N - 1)].

handle_call(cleanup, _From, State) ->
	ets:foldl(fun ({_, Msg}, _) -> file:write(State#state.out, io_lib:format("~100000000p~n", [Msg])) end, ok, x),
	{stop, normal, ok, State}.

handle_info({long_gc, _, _, _, _} = Msg, State) ->
	%ok = file:write(State#state.out, io_lib:format("~100000000p~n", [Msg])),
	ets:insert(x, {ets:info(x, size), Msg}),
	{noreply, State};
handle_info({trace_ts, _, _, _, 0, _} = Msg, State) ->
	%ok = file:write(State#state.out, io_lib:format("~100000000p~n", [Msg])),
	ets:insert(x, {ets:info(x, size), Msg}),
	{noreply, State};
handle_info({trace_ts, Pid, In, MFA, SchedulerId, Ts} = Msg, State) when In =:= in; In =:= in_exiting ->
	case State#state.out of
		Pid -> ok;
		_ -> ok%ets:insert(x, {ets:info(x, size), Msg})
			 %ok% = file:write(State#state.out, io_lib:format("~100000000p~n", [Msg]))
	end,
	OldSchedState = erlang:element(SchedulerId, State#state.current),
	NewCurrent = erlang:setelement(SchedulerId, State#state.current, [{Pid, MFA, Ts}|OldSchedState]),
	NewSwitches = erlang:setelement(SchedulerId, State#state.sched_switches, erlang:element(SchedulerId, State#state.sched_switches) + 1),
	{noreply, State#state{current=NewCurrent, sched_switches=NewSwitches}};
handle_info(Msg={trace_ts, Pid, Out, MFA, SchedulerId, OutTs}, State) when Out =:= out; Out =:= out_exiting; Out =:= out_exited ->
	case State#state.out of
		Pid -> ok;
		_ -> ok%ets:insert(x, {ets:info(x, size), Msg})
		%_ -> ok% = file:write(State#state.out, io_lib:format("~100000000p~n", [Msg]))
	end,
	OldSchedState = erlang:element(SchedulerId, State#state.current),
	case OldSchedState of
		[{Pid, _OldMFA, InTs}|NewSchedState=[]] ->
			OldTotal = maps:get(Pid, State#state.stats, 0),
			OldSchedTotal = erlang:element(SchedulerId, State#state.sched_stats),
			Used = timer:now_diff(OutTs, InTs),
			NewStats = maps:put(Pid, Used + OldTotal, State#state.stats),
			NewSchedStats = erlang:setelement(SchedulerId, State#state.sched_stats, Used + OldSchedTotal);
		[{Pid, _OldMFA, InTs}|NewSchedState] ->
			io:format("Transition out of stack: ~100000000p (was: ~100000000p)~n", [Msg, NewSchedState]),
			OldTotal = maps:get(Pid, State#state.stats, 0),
			OldSchedTotal = erlang:element(SchedulerId, State#state.sched_stats),
			Used = timer:now_diff(OutTs, InTs),
			NewStats = maps:put(Pid, Used + OldTotal, State#state.stats),
			NewSchedStats = erlang:setelement(SchedulerId, State#state.sched_stats, Used + OldSchedTotal);
		[] ->
			io:format("Transition out of nowhere: ~100000000p~n", [Msg]),
			NewStats = State#state.stats,
			NewSchedState = [],
			NewSchedStats = State#state.sched_stats;
		Other ->
			case lists:keytake(Pid, 1, Other) of
				{value, {Pid, _OldMFA, InTs}, NewSchedState} ->
					io:format("Transition out of order: ~100000000p (was: ~100000000p)~n", [Msg, Other]),
					OldTotal = maps:get(Pid, State#state.stats, 0),
					OldSchedTotal = erlang:element(SchedulerId, State#state.sched_stats),
					Used = timer:now_diff(OutTs, InTs),
					NewStats = maps:put(Pid, Used + OldTotal, State#state.stats),
					NewSchedStats = erlang:setelement(SchedulerId, State#state.sched_stats, Used + OldSchedTotal);
				_ ->
					io:format("Transition out of somewhere daft: ~100000000p (was: ~100000000p)~n", [Msg, Other]),
					NewStats = State#state.stats,
					NewSchedState = [],
					NewSchedStats = State#state.sched_stats
			end
	end,
	NewCurrent = erlang:setelement(SchedulerId, State#state.current, NewSchedState),
	{noreply, State#state{current=NewCurrent, stats=NewStats, sched_stats=NewSchedStats}};
handle_info({output_stats, FromTs}, State) ->
	NowTs = erlang:system_time(microsecond),
	erlang:send_after(1000, self(), {output_stats, NowTs}),
	SchedulerId = erlang:system_info(scheduler_id),
	{message_queue_len, QueueLen} = erlang:process_info(self(), message_queue_len),
	io:format("Stats (on ~p; queue len ~p; covering ~p):~n~p~n~p~n~p~n", [SchedulerId, QueueLen, NowTs - FromTs, State#state.stats, State#state.sched_stats, State#state.sched_switches]),
	{noreply, State#state{stats=#{}, sched_stats=empty_sched_stats(), sched_switches=empty_sched_stats()}}.

empty_current() ->
	list_to_tuple(lists:duplicate(erlang:system_info(schedulers), [])).

empty_sched_stats() ->
	list_to_tuple(lists:duplicate(erlang:system_info(schedulers), 0)).

burn(0) -> io:format("finished~n");
burn(N) -> burn(N - 1).

burnn(0, _) -> ok;
burnn(N, M) -> erlang:spawn(fun () -> burn(M) end), timer:sleep(100), burnn(N - 1, M).

flush_to_file(F) ->
	receive {trace_ts, F, _, _, _, _} -> flush_to_file(F); Msg -> file:write(F, io_lib:format("~100000000p~n", [Msg])), flush_to_file(F)
	after 0 -> ok
	end.
