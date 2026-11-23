defmodule Web.TLA.PerformanceObserverConformanceTest do
  # Compares the real `Web.PerformanceObserver` with the specification
  # `tla/PerformanceObserver.tla`.
  #
  # The test makes a random list of commands. It does each command on a
  # real observer and on the specification. After each command it lets the
  # server, and the specification, do their work. Then it compares the
  # states.
  #
  # The global object is a helper process of the test: it makes the
  # observer. The callback of the observer tells the test that it runs, and
  # then does the functions that the test gives it, until the test tells it
  # to return. Thus the commands of the callback process (a mark, observe,
  # take_records, disconnect) run in the callback, with the global object
  # of the observer.
  #
  # The test controls the callback process with the system messages of
  # `:sys`. The process is suspended between the tasks: a task waits in its
  # mailbox until the command `:run`. The command sends "resume" and
  # "suspend" together, thus the process does one task and suspends again.
  # The end of a task is a call of the server: when the process takes the
  # message "suspend", the server has sent the next task.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Internal.PerformanceTimeline, as: Timeline
  alias Web.Performance
  alias Web.PerformanceObserver
  alias Web.Test.SpecModel

  @types ["mark", "measure"]
  @entries_key {Web.Internal.PerformanceTimeline, :entries}

  @constants [
    {~s(Types = {"mark"}), ~s(Types = {"mark", "measure"})},
    {"MaxEntries = 2", "MaxEntries = 8"},
    {"MaxObserves = 2", "MaxObserves = 8"}
  ]

  # The steps that the server does with no command.
  @internal [
    {"Receive", ["global"]},
    {"Receive", ["callback"]},
    {"ServerStop", []}
  ]

  # A command of the callback process has an effect only while a callback
  # runs: such commands come more often.
  defp command do
    proc = frequency([{1, constant(:global)}, {2, constant(:callback)}])

    frequency([
      {12, tuple({constant(:make), proc, member_of(@types)})},
      {4, tuple({constant(:read), proc})},
      {6, tuple({constant(:observe), proc, member_of(@types), boolean()})},
      {10, constant(:run)},
      {4, constant(:return)},
      {4, tuple({constant(:take_records), proc})},
      {2, tuple({constant(:disconnect), proc})},
      {1, constant(:stop)}
    ])
  end

  property "the observer does each step as the specification permits" do
    check all(commands <- list_of(command(), max_length: 40), max_runs: 150) do
      system = start_system()

      try do
        Enum.reduce(commands, {SpecModel.start("PerformanceObserver", @constants), system}, fn
          command, {model, system} ->
            {model, system} = run(command, model, system)
            model = SpecModel.settle(model, @internal)
            assert_same_state(model, system, command)
            {model, system}
        end)
      after
        stop_system(system)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The real system
  # ---------------------------------------------------------------------------

  defp start_system do
    test = self()
    run = make_ref()
    global = start_helper()

    observer =
      call(global, fn ->
        PerformanceObserver.new(fn list, _observer, options ->
          send(test, {run, :callback, self(), list.entries, options})
          callback_loop(run)
        end)
      end)

    server = observer.address
    %{runner: runner} = :sys.get_state(server)
    :ok = :sys.suspend(runner)

    %{
      run: run,
      observer: observer,
      server: server,
      server_monitor: Process.monitor(server),
      runner: runner,
      runner_monitor: Process.monitor(runner),
      global: global,
      # The callback that runs, and the reference of the message "suspend"
      # that the callback process takes at the end of the task.
      callback: nil,
      suspend: nil
    }
  end

  # The callback does the functions of the test until the test tells it to
  # return.
  defp callback_loop(run) do
    receive do
      {^run, :do, ref, fun, test} ->
        send(test, {ref, fun.()})
        callback_loop(run)

      {^run, :return} ->
        :ok
    end
  end

  # The callback process stops after the server: a callback that waits
  # returns, and the process drops the tasks that it did not start. The
  # system of the test is the system at the start: the callback runs in the
  # callback process.
  defp stop_system(system) do
    send(system.runner, {system.run, :return})

    {pid, _monitor} = system.global
    if Process.alive?(pid), do: stop_helper(system.global)
    wait_for_down(system.server, system.server_monitor)

    try do
      :sys.resume(system.runner)
    catch
      # The process stopped.
      :exit, _reason -> :ok
    end

    if Process.alive?(system.runner), do: wait_for_down(system.runner, system.runner_monitor)
  end

  defp wait_for_down(pid, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      # The test got the message before.
      0 -> if Process.alive?(pid), do: wait_for_down_now(pid, monitor), else: :ok
    end
  end

  defp wait_for_down_now(pid, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end
  end

  # A helper process does the functions that the test gives it.
  defp start_helper do
    test = self()
    pid = spawn(fn -> helper_loop(test) end)
    {pid, Process.monitor(pid)}
  end

  defp helper_loop(test) do
    receive do
      {:do, ref, fun} ->
        send(test, {ref, fun.()})
        helper_loop(test)

      :stop ->
        :ok
    end
  end

  defp call({pid, _monitor}, fun) do
    ref = make_ref()
    send(pid, {:do, ref, fun})

    receive do
      {^ref, result} -> result
    end
  end

  defp stop_helper({pid, monitor}) do
    send(pid, :stop)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end
  end

  # Does `fun` in the process of `proc`: the global object, or the callback
  # that runs now.
  defp call_in(:global, system, fun), do: call(system.global, fun)

  defp call_in(:callback, system, fun) do
    ref = make_ref()
    send(system.callback, {system.run, :do, ref, fun, self()})

    receive do
      {^ref, result} -> result
    end
  end

  # A process that made an entry waits until the server has it: the
  # messages of one process arrive in their sequence.
  defp sync(server) do
    :sys.get_state(server)
  catch
    :exit, _reason -> nil
  end

  defp runs?(model, :global), do: SpecModel.get(model, "alive")
  defp runs?(model, :callback), do: SpecModel.get(model, "phase") == "callback"

  # The process makes the entry and reads its timeline while the server
  # is suspended: the read sees the entry with no message to the server.
  # Then the server gets the entry.
  defp run({:make, proc, type}, model, system) do
    if SpecModel.enabled?(model, "Make", [to_string(proc), type]) do
      n = SpecModel.get(model, "made") + 1
      name = "#{proc}-#{n}"
      model = SpecModel.step!(model, "Make", [to_string(proc), type])
      suspended = suspend(system.server)
      seen = call_in(proc, system, fn -> make(type, name) end)
      if suspended, do: :erlang.resume_process(system.server)
      call_in(proc, system, fn -> sync(system.server) end)

      assert seen == in_timeline?(model, n),
             "the read after #{inspect(name)} saw #{inspect(seen)}"

      # The read of the global object can make a new copy.
      {read(model, proc), system}
    else
      # The process does not run, or the specification has no more entries.
      {model, system}
    end
  end

  # A read of the timeline: the copy of the global object, or the table
  # for the callback. The read gives the buffer in its sequence: the
  # functions of `Web.Performance` sort it by the start times.
  defp run({:read, proc}, model, system) do
    if runs?(model, proc) do
      names = call_in(proc, system, fn -> Enum.map(Timeline.entries(), & &1.name) end)
      model = read(model, proc)

      expected =
        if SpecModel.get(model, "server"),
          do: model |> SpecModel.get("timeline") |> rows_of() |> Enum.map(&elem(&1, 1)),
          else: []

      assert Enum.map(names, &(&1 |> String.split("-") |> List.last() |> String.to_integer())) ==
               expected

      {model, system}
    else
      {model, system}
    end
  end

  defp run({:observe, proc, type, buffered}, model, system) do
    cond do
      SpecModel.enabled?(model, "Observe", [to_string(proc), type, buffered]) ->
        :ok = observe(system, proc, type, buffered)
        {SpecModel.step!(model, "Observe", [to_string(proc), type, buffered]), system}

      runs?(model, proc) and not SpecModel.get(model, "server") ->
        # The observer stopped: the call has no effect.
        :ok = observe(system, proc, type, buffered)
        {model, system}

      true ->
        {model, system}
    end
  end

  defp run({:take_records, proc}, model, system) do
    cond do
      SpecModel.enabled?(model, "TakeRecords", [to_string(proc)]) ->
        expected = SpecModel.get(model, "buffer")

        records =
          call_in(proc, system, fn -> PerformanceObserver.take_records(system.observer) end)

        assert entries(records) == copies(expected), "take_records returned #{inspect(records)}"
        {SpecModel.step!(model, "TakeRecords", [to_string(proc)]), system}

      runs?(model, proc) ->
        # The observer stopped.
        assert call_in(proc, system, fn -> PerformanceObserver.take_records(system.observer) end) ==
                 []

        {model, system}

      true ->
        {model, system}
    end
  end

  defp run({:disconnect, proc}, model, system) do
    if runs?(model, proc) do
      :ok = call_in(proc, system, fn -> PerformanceObserver.disconnect(system.observer) end)
    end

    {step_if_enabled(model, "Disconnect", [to_string(proc)]), system}
  end

  defp run(:stop, model, system) do
    if SpecModel.enabled?(model, "Stop") do
      stop_helper(system.global)
      monitor = system.server_monitor
      server = system.server

      receive do
        {:DOWN, ^monitor, :process, ^server, _reason} -> :ok
      end

      {SpecModel.step!(model, "Stop"), system}
    else
      {model, system}
    end
  end

  # The callback process does one task. It suspends again at the end of the
  # task. A callback of the task tells the test that it runs, and waits.
  defp run(:run, model, system) do
    if SpecModel.enabled?(model, "Begin") do
      model = SpecModel.step!(model, "Begin")
      expected = SpecModel.get(model, "buffer")
      requires = SpecModel.get(model, "requires")
      model = step_if_enabled(model, "Take", [])
      suspend = resume_for_one_task(system.runner)

      if SpecModel.get(model, "phase") == "callback" do
        pid = assert_callback(system, copies(expected), requires)
        {model, %{system | callback: pid, suspend: suspend}}
      else
        wait_for_suspend(system, suspend)
        {step_if_enabled(model, "Done", []), system}
      end
    else
      {model, system}
    end
  end

  # The callback returns, and the task ends.
  defp run(:return, model, system) do
    if SpecModel.get(model, "phase") == "callback" do
      send(system.callback, {system.run, :return})
      wait_for_suspend(system, system.suspend)
      model = model |> SpecModel.step!("Return") |> SpecModel.step!("Done")
      {model, %{system | callback: nil, suspend: nil}}
    else
      {model, system}
    end
  end

  # A read of the global object makes a new copy when the counter changed.
  # The callback process reads the table: the specification has no step.
  defp read(model, :global), do: step_if_enabled(model, "Read", [])
  defp read(model, :callback), do: model

  defp suspend(server) do
    :erlang.suspend_process(server)
  catch
    # The server stopped.
    :error, :badarg -> false
  end

  defp in_timeline?(model, n) do
    model |> SpecModel.get("timeline") |> rows_of() |> Enum.any?(&(elem(&1, 1) == n))
  end

  # The callback runs: it got the copies, and the option of the dropped
  # entries count when the flag "requires dropped entries" was set.
  defp assert_callback(system, expected, requires) do
    run = system.run
    assert_receive {^run, :callback, pid, received, options}, 5_000
    assert entries(received) == expected, "the callback got #{inspect(received)}"
    assert options == if(requires, do: %{dropped_entries_count: 0}, else: %{})
    pid
  end

  # The callback process takes "resume" first, as a system message. Then
  # it takes its messages in their sequence: the task, then "suspend".
  defp resume_for_one_task(runner) do
    resume = make_ref()
    suspend = make_ref()
    true = :erlang.suspend_process(runner)
    send(runner, {:system, {self(), resume}, :resume})
    send(runner, {:system, {self(), suspend}, :suspend})
    true = :erlang.resume_process(runner)
    suspend
  catch
    # The callback process stopped after the server.
    :error, :badarg -> nil
  end

  # The end of the task, or the stop of the callback process: a process
  # whose server stopped drops the task, and stops.
  defp wait_for_suspend(system, suspend) do
    runner = system.runner
    monitor = system.runner_monitor

    receive do
      {^suspend, :ok} -> :ok
      {:DOWN, ^monitor, :process, ^runner, _reason} -> :ok
    end
  end

  # Makes the entry, and tells if a read of the timeline after it has it.
  defp make("mark", name) do
    Performance.mark(name)
    Enum.any?(Performance.get_entries_by_name(name))
  end

  defp make("measure", name) do
    Performance.measure(name)
    Enum.any?(Performance.get_entries_by_name(name))
  end

  defp observe(system, proc, type, buffered) do
    call_in(proc, system, fn ->
      PerformanceObserver.observe(system.observer, type: type, buffered: buffered)
    end)
  end

  defp step_if_enabled(model, action, args) do
    if SpecModel.enabled?(model, action, args),
      do: SpecModel.step!(model, action, args),
      else: model
  end

  # ---------------------------------------------------------------------------
  # The comparison
  # ---------------------------------------------------------------------------

  # An entry of the real system, with the process and the number of its
  # name.
  defp entries(entries) do
    Enum.map(entries, fn entry ->
      [proc, n] = String.split(entry.name, "-")
      {proc, String.to_integer(n), entry.entry_type}
    end)
  end

  # The checker can give a sequence as a map from its positions.
  defp copies(copies) when is_map(copies),
    do: copies |> Enum.sort() |> Enum.map(&elem(&1, 1)) |> copies()

  defp copies(copies), do: Enum.map(copies, &{&1["proc"], &1["n"], &1["type"]})

  defp assert_same_state(model, system, command) do
    state = SpecModel.to_map(model)
    assert Process.alive?(system.server) == state["server"], "after #{inspect(command)}"

    # The copy of the process of the global object, and the counter of the
    # writes of the callback process.
    if state["alive"] do
      {copy, version} = global_copy(system.global)
      assert copy == numbers(state["copy"]), "after #{inspect(command)}: the copy"
      assert version == state["seen"], "after #{inspect(command)}: the counter of the copy"
    end

    if state["server"] do
      %{counter: counter} = :sys.get_state(system.server)

      assert :atomics.get(counter, 1) == state["counter"],
             "after #{inspect(command)}: the counter"
    end

    # The callback process keeps no entries of its own: its entries go to
    # the timeline of the global object.
    assert entries(own_entries(system.runner)) == copies(state["own"]),
           "after #{inspect(command)}: the entries of the callback process"

    if state["server"] do
      real = :sys.get_state(system.server)
      observer = real.observers[system.observer.token]

      assert rows(real) == rows_of(state["timeline"]),
             "after #{inspect(command)}: the timeline"

      assert entries(Enum.reverse(observer.buffer)) == copies(state["buffer"]),
             "after #{inspect(command)}: the buffer"

      assert real.task_queued == state["queued"], "after #{inspect(command)}: the flag"
      assert real.task_running == state["running"], "after #{inspect(command)}: the task"
      assert observer.requires_dropped_entries == state["requires"], "after #{inspect(command)}"
      assert tasks(system.runner) == state["tasks"], "after #{inspect(command)}: the tasks"
      assert registered(real, system) == state["registered"], "after #{inspect(command)}"
    end
  end

  # The rows of the table: each entry, and if the server got it.
  defp rows(real) do
    for {key, entry, writer} <- :ets.tab2list(real.table) do
      [{proc, n, type}] = entries([entry])
      {proc, n, type, queued?(real, writer, key)}
    end
  end

  defp queued?(_real, nil, _key), do: true
  defp queued?(real, writer, key), do: Map.get(real.queued, writer, key - 1) >= key

  defp rows_of(timeline) when is_map(timeline),
    do: timeline |> Enum.sort() |> Enum.map(&elem(&1, 1)) |> rows_of()

  defp rows_of(timeline), do: Enum.map(timeline, &{&1["proc"], &1["n"], &1["type"], &1["queued"]})

  defp global_copy({pid, _monitor}) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    entries = value(dictionary, :entries, [])
    version = value(dictionary, :version, 0)
    {entries |> Enum.reverse() |> entries() |> Enum.map(&elem(&1, 1)), version}
  end

  defp value(dictionary, name, default) do
    case List.keyfind(dictionary, {Web.Internal.PerformanceTimeline, name}, 0) do
      {_key, value} -> value
      nil -> default
    end
  end

  # The checker can give a sequence as a map from its positions.
  defp numbers(sequence) when is_map(sequence),
    do: sequence |> Enum.sort() |> Enum.map(&elem(&1, 1))

  defp numbers(sequence), do: sequence

  defp own_entries(runner) do
    case Process.info(runner, :dictionary) do
      {:dictionary, dictionary} -> dictionary |> List.keyfind(@entries_key, 0) |> own_list()
      nil -> []
    end
  end

  defp own_list({_key, entries}), do: Enum.reverse(entries)
  defp own_list(nil), do: []

  # The tasks in the mailbox of the callback process.
  defp tasks(runner) do
    {:messages, messages} = Process.info(runner, :messages)
    Enum.count(messages, &match?({:"$gen_cast", {:task, _task}}, &1))
  end

  # The types of the options of the observer.
  defp registered(real, system) do
    case List.keyfind(real.registered, system.observer.token, 0) do
      {_token, options} -> MapSet.new(options, & &1.type)
      nil -> MapSet.new()
    end
  end
end
