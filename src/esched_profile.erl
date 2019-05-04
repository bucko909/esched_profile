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
	gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
	erlang:send_after(1000, self(), {output_stats, erlang:system_time(microsecond)}),
	erlang:trace(all, true, [running, running_procs, running_ports, scheduler_id, timestamp, {tracer, self()}]),
	erlang:system_monitor(self(), [{long_gc, 0}]),
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
handle_info({trace_ts, Pid, in, MFA, SchedulerId, Ts} = Msg, State) ->
	case State#state.out of
		Pid -> ok;
		_ -> ets:insert(x, {ets:info(x, size), Msg})
			 %ok% = file:write(State#state.out, io_lib:format("~100000000p~n", [Msg]))
	end,
	OldSchedState = erlang:element(SchedulerId, State#state.current),
	case OldSchedState of
		undefined ->
			SaneState = State;
		{OldPid, _OldMFA, _InTs} = Other ->
			timer:sleep(10),
			ets:insert(y, {ets:info(y, size), {"Transition in -> in: ~10000000p (was: ~1000000000p) ~10000000p~nI am: ~p~n", [Msg, Other, erlang:process_info(OldPid, status), {erlang:system_info(scheduler_id), ets_lastn(x, 10) ++ ['HERE'] ++ lists:sublist(element(2, erlang:process_info(self(), messages)), 10)}]}}),
			%receive
			%	{trace_ts, OldPid, out, _OutMFA, SchedulerId, _OutTs} = OutMsg -> {noreply, SaneState} = handle_info(OutMsg, State)
			%after 100 -> flush_to_file(State#state.out), exit({mismatched_in, Msg, Other}), SaneState = undefined
			%end
			{noreply, SaneState} = handle_info({trace_ts, OldPid, out, meh, SchedulerId, Ts}, State)
	end,
	NewCurrent = erlang:setelement(SchedulerId, SaneState#state.current, {Pid, MFA, Ts}),
	NewSwitches = erlang:setelement(SchedulerId, SaneState#state.sched_switches, erlang:element(SchedulerId, SaneState#state.sched_switches) + 1),
	{noreply, SaneState#state{current=NewCurrent, sched_switches=NewSwitches}};
handle_info(Msg={trace_ts, Pid, out, MFA, SchedulerId, OutTs}, State) ->
	case State#state.out of
		Pid -> ok;
		_ -> ets:insert(x, {ets:info(x, size), Msg})
		%_ -> ok% = file:write(State#state.out, io_lib:format("~100000000p~n", [Msg]))
	end,
	OldSchedState = erlang:element(SchedulerId, State#state.current),
	case OldSchedState of
		{Pid, _OldMFA, InTs} ->
			OldTotal = maps:get(Pid, State#state.stats, 0),
			OldSchedTotal = erlang:element(SchedulerId, State#state.sched_stats),
			Used = timer:now_diff(OutTs, InTs),
			NewStats = maps:put(Pid, Used + OldTotal, State#state.stats),
			NewSchedStats = erlang:setelement(SchedulerId, State#state.sched_stats, Used + OldSchedTotal);
		undefined ->
			io:format("Transition out of nowhere: ~100000000p~n", [Msg]),
			NewStats = State#state.stats,
			NewSchedStats = State#state.sched_stats;
		Other ->
			io:format("Transition out of somewhere daft: ~100000000p (was: ~100000000p)~n", [Msg, Other]),
			NewStats = State#state.stats,
			NewSchedStats = State#state.sched_stats
	end,
	NewCurrent = erlang:setelement(SchedulerId, State#state.current, undefined),
	{noreply, State#state{current=NewCurrent, stats=NewStats, sched_stats=NewSchedStats}};
handle_info({output_stats, FromTs}, State) ->
	NowTs = erlang:system_time(microsecond),
	erlang:send_after(1000, self(), {output_stats, NowTs}),
	SchedulerId = erlang:system_info(scheduler_id),
	{message_queue_len, QueueLen} = erlang:process_info(self(), message_queue_len),
	io:format("Stats (on ~p; queue len ~p; covering ~p):~n~p~n~p~n~p~n", [QueueLen, SchedulerId, NowTs - FromTs, State#state.stats, State#state.sched_stats, State#state.sched_switches]),
	{noreply, State#state{stats=#{}, sched_stats=empty_sched_stats(), sched_switches=empty_sched_stats()}}.

empty_current() ->
	list_to_tuple(lists:duplicate(erlang:system_info(schedulers), undefined)).

empty_sched_stats() ->
	list_to_tuple(lists:duplicate(erlang:system_info(schedulers), 0)).

burn(0) -> io:format("finished~n");
burn(N) -> burn(N - 1).

burnn(0, _) -> ok;
burnn(N, M) -> erlang:spawn(fun () -> burn(M) end), burnn(N - 1, M).

flush_to_file(F) ->
	receive {trace_ts, F, _, _, _, _} -> flush_to_file(F); Msg -> file:write(F, io_lib:format("~100000000p~n", [Msg])), flush_to_file(F)
	after 0 -> ok
	end.
