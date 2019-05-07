-module(esched_profile).

-export([test/0, permissive_test/0, no_multistack_test/0, no_bad_order_test/0, clean_test/0, no_no_out_test/0]).


-record(state,
		{
		 current=empty_current() :: tuple(),
		 allow_bad_order=false,
		 allow_no_out=false,
		 allow_multistack=false
		}).

test() ->
	Results = [run_test(F) || F <- [fun ?MODULE:permissive_test/0, fun ?MODULE:no_multistack_test/0, fun ?MODULE:no_bad_order_test/0, fun ?MODULE:clean_test/0, fun ?MODULE:no_no_out_test/0]],
	Results == [true, true, true, true] orelse exit(Results).

run_test(F) ->
	spawn_monitor(fun () -> F() end),
	receive {'DOWN', _, _, _, Reason} ->
			Reason =:= normal orelse {test_failed, erlang:fun_info(F, name)}
	end.

clean_test() ->
	Pid = setup(#state{}),
	burn(),
	erlang:trace_delivered(all),
	MRef = erlang:monitor(process, Pid),
	Pid ! exit,
	wait([{Pid, MRef}]),
	ok.

permissive_test() ->
	Pid = setup(#state{allow_bad_order=true, allow_no_out=true, allow_multistack=true}),
	burn(),
	erlang:trace_delivered(all),
	MRef = erlang:monitor(process, Pid),
	Pid ! exit,
	wait([{Pid, MRef}]),
	ok.

no_bad_order_test() ->
	Pid = setup(#state{allow_bad_order=false, allow_no_out=true, allow_multistack=true}),
	burn(),
	erlang:trace_delivered(all),
	MRef = erlang:monitor(process, Pid),
	Pid ! exit,
	wait([{Pid, MRef}]),
	ok.

no_multistack_test() ->
	Pid = setup(#state{allow_bad_order=true, allow_no_out=true, allow_multistack=false}),
	burn(),
	erlang:trace_delivered(all),
	MRef = erlang:monitor(process, Pid),
	Pid ! exit,
	wait([{Pid, MRef}]),
	ok.

no_no_out_test() ->
	Pid = setup(#state{allow_bad_order=true, allow_no_out=false, allow_multistack=true}),
	burn(),
	erlang:trace_delivered(all),
	MRef = erlang:monitor(process, Pid),
	Pid ! exit,
	wait([{Pid, MRef}]),
	ok.

setup(State) ->
	spawn_link(fun () -> init(), watcher(State) end).

init() ->
	erlang:trace(all, true, [exiting, running, running_procs, running_ports, scheduler_id, timestamp, cpu_timestamp, {tracer, self()}]) > 0.

watcher(State) ->
	receive
		exit ->
			io:format("Scheduler state:~n~p~n", [State#state.current]),
			ok;
		Msg ->
			{noreply, NewState} = handle_info(Msg, State),
			watcher(NewState)
	after 1000 ->
		      exit(no_msg)
	end.

handle_info({trace_ts, Pid, In, MFA, SchedulerId, Ts} = Msg, State) when In =:= in; In =:= in_exiting ->
	OldSchedState = erlang:element(SchedulerId + 1, State#state.current),
	case OldSchedState of
		[] -> ok;
		_ when State#state.allow_multistack -> ok
	end,
	NewCurrent = erlang:setelement(SchedulerId + 1, State#state.current, [{Pid, MFA, Ts}|OldSchedState]),
	{noreply, State#state{current=NewCurrent}};
handle_info(Msg={trace_ts, Pid, Out, MFA, SchedulerId, OutTs}, State) when Out =:= out; Out =:= out_exiting; Out =:= out_exited ->
	OldSchedState = erlang:element(SchedulerId + 1, State#state.current),
	case OldSchedState of
		[{Pid, _OldMFA, InTs}|NewSchedState] ->
			ok;
		[] when State#state.allow_no_out ->
			NewSchedState = [];
		Other when State#state.allow_bad_order ->
			case lists:keytake(Pid, 1, Other) of
				{value, {Pid, _OldMFA, InTs}, NewSchedState} ->
					ok
			end
	end,
	NewCurrent = erlang:setelement(SchedulerId + 1, State#state.current, NewSchedState),
	{noreply, State#state{current=NewCurrent}}.

empty_current() ->
	list_to_tuple(lists:duplicate(erlang:system_info(schedulers) + 1, [])).

burn(0) -> ok;
burn(N) -> burn(N - 1).

burnn(0, _) -> ok;
burnn(N, M) -> [erlang:spawn_monitor(fun () -> burn(M) end) || _ <- lists:seq(1, N)].

burn() ->
	wait(burnn(10, 10000000)).

wait([]) ->
	ok;
wait([{Pid, MRef}|Rest]) ->
	receive {'DOWN', MRef, process, Pid, normal} -> wait(Rest)
	after 1000 -> exit({no_DOWN, Pid, MRef, erlang:process_info(self(), messages)})
	end.
