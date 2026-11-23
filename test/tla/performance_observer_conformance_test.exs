defmodule Web.TLA.PerformanceObserverConformanceTest do
  # Compares the real `Web.PerformanceObserver` with the specification
  # `tla/PerformanceObserver.tla`.
  #
  # The test makes a random list of commands. It does each command on a
  # real observer and on the specification. After each command it lets the
  # server, and the specification, do their work. Then it compares the
  # states.
  #
  # The test controls the callback process: it suspends the process, and
  # resumes it only for the command `:run`. Thus a task waits in the
  # mailbox of the callback process until the test runs it, and the
  # commands between can take the entries of the task.
  #
  # The observed processes and the owner are helper processes of the test.
  # A helper that makes an entry asks the server for its state after the
  # entry: the messages of one process arrive in their sequence, thus the
  # server has the entry when the helper continues.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Performance
  alias Web.PerformanceObserver
  alias Web.Test.SpecModel

  @procs [:p1, :p2]
  @types ["mark", "measure"]

  @constants [
    {"Procs = {p1}", "Procs = {p1, p2}"},
    {~s(Types = {"mark"}), ~s(Types = {"mark", "measure"})},
    {"MaxEntries = 2", "MaxEntries = 8"},
    {"MaxObserves = 2", "MaxObserves = 8"}
  ]

  # The steps that the server does with no command. The command `:run`
  # does the step of the callback process.
  @internal [
    {"Receive", [:p1]},
    {"Receive", [:p2]},
    {"Down", [:p1]},
    {"Down", [:p2]},
    {"ServerStop", []}
  ]

  defp command do
    proc = member_of(@procs)

    frequency([
      {6, tuple({constant(:make), proc, member_of(@types)})},
      {3, tuple({constant(:observe), proc, member_of(@types), boolean()})},
      {4, constant(:run)},
      {2, tuple({constant(:take_records), proc})},
      {1, tuple({constant(:disconnect), proc})},
      {1, tuple({constant(:stop), proc})},
      {1, constant(:stop_owner)}
    ])
  end

  property "the observer does each step as the specification permits" do
    check all(commands <- list_of(command(), max_length: 25), max_runs: 100) do
      system = start_system()

      try do
        Enum.reduce(commands, {SpecModel.start("PerformanceObserver", @constants), system}, fn
          command, {model, system} ->
            {model, system} = run(command, model, system)
            model = SpecModel.settle(model, @internal)
            system = settle(system, model)
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

    owner = start_helper()

    observer =
      call(owner, fn ->
        PerformanceObserver.new(fn list, _observer, options ->
          send(test, {run, :callback, list.entries, options})
        end)
      end)

    server = observer.address
    %{runner: runner} = :sys.get_state(server)
    true = :erlang.suspend_process(runner)

    %{
      run: run,
      observer: observer,
      server: server,
      server_monitor: Process.monitor(server),
      runner: runner,
      owner: owner,
      procs: Map.new(@procs, &{&1, start_helper()})
    }
  end

  defp stop_system(system) do
    resume(system.runner)

    for {pid, _monitor} = helper <- [system.owner | Map.values(system.procs)],
        Process.alive?(pid),
        do: stop_helper(helper)
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

  # A process that made an entry waits until the server has it.
  defp sync(server) do
    :sys.get_state(server)
  catch
    :exit, _reason -> nil
  end

  defp run({:make, proc, type}, model, system) do
    if SpecModel.enabled?(model, "Make", [proc, type]) do
      n = length(SpecModel.get(model, "timeline")[to_string(proc)]) + 1
      name = "#{proc}-#{n}"

      call(system.procs[proc], fn -> make(type, name, system.server) end)

      {SpecModel.step!(model, "Make", [proc, type]), system}
    else
      # The process stopped, or the specification has no more entries.
      {model, system}
    end
  end

  defp run({:observe, proc, type, buffered}, model, system) do
    cond do
      SpecModel.enabled?(model, "Observe", [proc, type, buffered]) ->
        :ok = observe(system, proc, type, buffered)
        {SpecModel.step!(model, "Observe", [proc, type, buffered]), system}

      alive?(model, proc) and not SpecModel.get(model, "server") ->
        # The observer stopped: the call has no effect.
        :ok = observe(system, proc, type, buffered)
        {model, system}

      true ->
        {model, system}
    end
  end

  defp run({:take_records, proc}, model, system) do
    cond do
      SpecModel.enabled?(model, "TakeRecords", [proc]) ->
        expected = SpecModel.get(model, "buffer")

        records =
          call(system.procs[proc], fn -> PerformanceObserver.take_records(system.observer) end)

        assert entries(records) == copies(expected), "take_records returned #{inspect(records)}"
        {SpecModel.step!(model, "TakeRecords", [proc]), system}

      alive?(model, proc) ->
        # The observer stopped.
        assert call(system.procs[proc], fn ->
                 PerformanceObserver.take_records(system.observer)
               end) ==
                 []

        {model, system}

      true ->
        {model, system}
    end
  end

  defp run({:disconnect, proc}, model, system) do
    if alive?(model, proc) do
      :ok = call(system.procs[proc], fn -> PerformanceObserver.disconnect(system.observer) end)
    end

    {step_if_enabled(model, "Disconnect", [proc]), system}
  end

  defp run({:stop, proc}, model, system) do
    if alive?(model, proc) do
      stop_helper(system.procs[proc])
      {SpecModel.step!(model, "Stop", [proc]), system}
    else
      {model, system}
    end
  end

  defp run(:stop_owner, model, system) do
    if SpecModel.enabled?(model, "StopOwner") do
      stop_helper(system.owner)
      monitor = system.server_monitor
      server = system.server

      receive do
        {:DOWN, ^monitor, :process, ^server, _reason} -> :ok
      end

      {SpecModel.step!(model, "StopOwner"), system}
    else
      {model, system}
    end
  end

  # The callback process takes its task, and the test suspends it again.
  defp run(:run, model, system) do
    expected =
      if SpecModel.get(model, "server") and SpecModel.get(model, "tasks") > 0 and
           copies(SpecModel.get(model, "buffer")) != [] do
        count = if SpecModel.get(model, "requires"), do: %{dropped_entries_count: 0}, else: %{}
        [{copies(SpecModel.get(model, "buffer")), count}]
      else
        []
      end

    resume(system.runner)
    sync(system.runner)
    if Process.alive?(system.runner), do: true = :erlang.suspend_process(system.runner)

    assert callbacks(system.run) == expected
    {step_if_enabled(model, "Task", []), system}
  end

  defp make("mark", name, server) do
    Performance.mark(name)
    sync(server)
  end

  defp make("measure", name, server) do
    Performance.measure(name)
    sync(server)
  end

  defp observe(system, proc, type, buffered) do
    call(system.procs[proc], fn ->
      PerformanceObserver.observe(system.observer, type: type, buffered: buffered)
    end)
  end

  defp step_if_enabled(model, action, args) do
    if SpecModel.enabled?(model, action, args),
      do: SpecModel.step!(model, action, args),
      else: model
  end

  defp alive?(model, proc), do: SpecModel.get(model, "alive")[to_string(proc)]

  defp resume(runner) do
    :erlang.resume_process(runner)
  catch
    # The process stopped, or it does not wait.
    :error, :badarg -> true
  end

  defp callbacks(run) do
    receive do
      {^run, :callback, entries, options} -> [{entries(entries), options} | callbacks(run)]
    after
      0 -> []
    end
  end

  # The server removes the options of a process that stopped, when its
  # monitor tells it. The test waits for that step, as the specification
  # does it with no command.
  defp settle(system, model) do
    if SpecModel.get(model, "server") do
      wait_for_down(system, 500)
    end

    system
  end

  defp wait_for_down(system, attempts) do
    stopped =
      for {proc, {pid, _monitor}} <- system.procs, not Process.alive?(pid), do: {proc, pid}

    %{registrations: registrations} = :sys.get_state(system.server)

    cond do
      not Enum.any?(stopped, fn {_proc, pid} -> Map.has_key?(registrations, pid) end) ->
        :ok

      attempts > 0 ->
        Process.sleep(1)
        wait_for_down(system, attempts - 1)

      true ->
        flunk("the server did not remove the options of #{inspect(stopped)}")
    end
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

    for proc <- @procs, state["alive"][to_string(proc)] do
      {pid, _monitor} = system.procs[proc]
      {:dictionary, dictionary} = Process.info(pid, :dictionary)

      observers =
        case List.keyfind(dictionary, {Web.Internal.PerformanceObserver, :observers}, 0) do
          {_key, observers} -> observers
          nil -> []
        end

      listed = List.keymember?(observers, system.server, 0)

      assert listed == state["listed"][to_string(proc)],
             "after #{inspect(command)}: #{proc} lists"
    end

    if state["server"] do
      real = :sys.get_state(system.server)

      assert entries(Enum.reverse(real.buffer)) == copies(state["buffer"]),
             "after #{inspect(command)}: the buffer"

      assert real.task_queued == state["queued"], "after #{inspect(command)}: the flag"
      assert real.requires_dropped_entries == state["requires"], "after #{inspect(command)}"

      {:message_queue_len, tasks} = Process.info(system.runner, :message_queue_len)
      assert tasks == state["tasks"], "after #{inspect(command)}: the tasks"

      assert registered(real, system) == state["registered"], "after #{inspect(command)}"
    end
  end

  # The types of the options of each process.
  defp registered(real, system) do
    Map.new(@procs, fn proc ->
      {pid, _monitor} = system.procs[proc]

      types =
        case real.registrations do
          %{^pid => %{options: options}} -> MapSet.new(options, & &1.type)
          _none -> MapSet.new()
        end

      {to_string(proc), types}
    end)
  end
end
