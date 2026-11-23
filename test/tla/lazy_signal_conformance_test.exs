defmodule Web.TLA.LazySignalConformanceTest do
  # Compares the lazy signal of a real `Web.Request` with the specification
  # `tla/LazySignal.tla`.
  #
  # The first property makes a random list of commands. A command is the
  # operation of a copy of the struct in a different process (a listener),
  # a read of a copy, the stop of a copy, the signal E of
  # `Web.AbortSignal.any/1`, the abort of the source, or a pause longer than
  # the linger time. The test does each command on the real system and on
  # the specification, and it compares the two states. An operation of a
  # copy is one call of the real code: the specification does all the steps
  # of the copy and of the process of the signal.
  #
  # The second property lets copies do their operations at the same time,
  # while the source aborts. The test cannot control the steps of the
  # processes, thus it checks the properties of the specification on the
  # results: one process, and each listener that a copy added before it
  # saw the abort runs.
  #
  # The test sets the linger time for the application. Thus it cannot run
  # at the same time as other tests.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Web.AbortController
  alias Web.AbortSignal
  alias Web.EventTarget
  alias Web.Internal.EventTarget.Listeners
  alias Web.Test.SpecModel

  @copies ["c1", "c2", "c3"]
  @linger 15
  @config [
    {~s(Copies = {"c1", "c2"}), ~s(Copies = {"c1", "c2", "c3"})},
    {"MaxGen = 2", "MaxGen = 3"}
  ]

  setup do
    previous = Application.get_env(:web, :linger)
    Application.put_env(:web, :linger, @linger)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:web, :linger)
      else
        Application.put_env(:web, :linger, previous)
      end
    end)
  end

  defp command do
    copy = member_of(@copies)

    frequency([
      {6, tuple({constant(:op), copy})},
      {3, tuple({constant(:read), copy})},
      {2, tuple({constant(:stop), copy})},
      {2, constant(:make_e)},
      {2, constant(:abort)},
      {2, constant(:pause)}
    ])
  end

  property "the signal does each step as the specification permits" do
    check all(commands <- list_of(command(), max_length: 12), max_runs: 100) do
      run_commands(commands)
    end
  end

  # Lists of commands that the random lists do not often give.
  test "the signal does the steps of known lists of commands as the specification permits" do
    for commands <- [
          # The process of a copy that stopped expires, and a different copy
          # starts a new one.
          [{:op, "c1"}, {:stop, "c1"}, :pause, {:op, "c2"}, :abort],
          # The signal E is made before the process of the lazy signal.
          [:make_e, {:op, "c1"}, {:op, "c2"}, :abort],
          # An operation after the abort starts a process that stops at once.
          [:abort, {:op, "c1"}, {:read, "c2"}],
          # A copy that stops removes its listener; the owner stays.
          [{:op, "c1"}, {:op, "c2"}, {:stop, "c2"}, :pause, :abort]
        ] do
      run_commands(commands)
    end
  end

  # Copies do their operations at the same time, and the test aborts the
  # source at a random moment between them. A copy that reads the signal
  # not aborted after its operation added its listener before the abort:
  # its listener must run.
  property "copies that start the process at the same time get one process" do
    check all(count <- integer(2..6), abort_at <- integer(0..6), max_runs: 50) do
      controller = AbortController.new()
      signal = Web.Request.new("https://example.com/", signal: controller.signal).signal
      test = self()

      copies =
        for index <- 1..count do
          spawn_link(fn ->
            receive do
              :go -> :ok
            end

            listener = fn -> send(test, {:fired, index}) end
            EventTarget.add_event_listener(signal, "abort", listener)

            send(
              test,
              {:done, index, AbortSignal.__listener_pid__(signal), AbortSignal.aborted?(signal)}
            )

            receive do
              :stop -> :ok
            end
          end)
        end

      Enum.each(copies, &send(&1, :go))
      if abort_at < count, do: wait_done(abort_at)
      :ok = AbortController.abort(controller, :why)
      results = for index <- 1..count, do: receive_done(index)

      # The copies that found the signal not aborted after their operation
      # used one process, and their listeners ran one time each.
      before = for {index, pid, false} <- results, do: {index, pid}
      assert before |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() <= 1

      for {index, _pid} <- before do
        assert_received {:fired, ^index}
        refute_received {:fired, ^index}
      end

      # Each process stops: the source aborted.
      for {_index, pid, _aborted} <- results, is_pid(pid), do: assert_down(pid)
      eventually(fn -> AbortSignal.__listener_pid__(signal) == nil end)
      Enum.each(copies, &send(&1, :stop))
      flush_fired()
    end
  end

  defp wait_done(0), do: :ok

  defp wait_done(count) do
    assert_receive {:done, _index, _pid, _aborted} = message
    send(self(), {:early, message})
    wait_done(count - 1)
  end

  defp receive_done(index) do
    receive do
      {:early, {:done, ^index, pid, aborted}} -> {index, pid, aborted}
      {:done, ^index, pid, aborted} -> {index, pid, aborted}
    after
      2_000 -> flunk("the copy #{index} did not end its operation")
    end
  end

  defp flush_fired do
    receive do
      {:fired, _index} -> flush_fired()
    after
      0 -> :ok
    end
  end

  defp run_commands(commands) do
    system = start_system()
    model = SpecModel.start("LazySignal", @config)

    try do
      Enum.reduce(commands, model, fn command, model ->
        model = follow_expire(model, system)
        model = run(command, model, system)
        model = follow_expire(model, system)
        assert_same_state(model, system)
        model
      end)
    after
      stop_system(system)
    end
  end

  # ---------------------------------------------------------------------------
  # The real system: the owner of the source, the copies, and the maker of
  # the signal E. A process table keeps the real process of each process of
  # the specification.
  # ---------------------------------------------------------------------------

  defp start_system do
    test = self()

    owner =
      spawn(fn ->
        send(test, {:controller, AbortController.new()})
        Process.sleep(:infinity)
      end)

    assert_receive {:controller, controller}
    signal = Web.Request.new("https://example.com/", signal: controller.signal).signal
    copies = Map.new(@copies, &{&1, spawn(fn -> copy(&1, signal, test) end)})
    table = :ets.new(:lazy_signal_processes, [:public])

    %{owner: owner, controller: controller, signal: signal, copies: copies, table: table}
  end

  defp stop_system(system) do
    for pid <- [system.owner | Map.values(system.copies)], do: Process.exit(pid, :kill)

    case maker(system) do
      nil -> :ok
      {maker, _e} -> Process.exit(maker, :kill)
    end

    :ets.delete(system.table)
  end

  defp copy(name, signal, test) do
    receive do
      {:op, from} ->
        EventTarget.add_event_listener(signal, "abort", fn -> send(test, {:event, "L", name}) end)
        send(from, {:reply, self(), AbortSignal.__listener_pid__(signal)})

      {:read, from} ->
        reply =
          {AbortSignal.aborted?(signal), AbortSignal.reason(signal), AbortSignal.onabort(signal)}

        send(from, {:reply, self(), reply})
    end

    copy(name, signal, test)
  end

  defp request(system, name, request) do
    pid = system.copies[name]
    send(pid, {request, self()})

    receive do
      {:reply, ^pid, reply} -> reply
    after
      2_000 -> flunk("the copy #{name} gave no reply to #{inspect(request)}")
    end
  end

  defp real_pid(system, gen) do
    case :ets.lookup(system.table, gen) do
      [{^gen, pid}] -> pid
      [] -> nil
    end
  end

  defp maker(system) do
    case :ets.lookup(system.table, :maker) do
      [{:maker, maker, e}] -> {maker, e}
      [] -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # One command, on the real system and on the specification
  # ---------------------------------------------------------------------------

  defp run({:op, name}, model, system) do
    state = SpecModel.to_map(model)

    if name in state["live"] and state["pc"][name] == "idle" do
      started = started(state)
      reply = request(system, name, :op)

      model =
        model
        |> SpecModel.step!("Begin", [name])
        |> SpecModel.settle(copy_actions(name))

      state = SpecModel.to_map(model)
      assert state["pc"][name] == "done"

      # A new process of the specification: the real copy found it.
      Enum.each(started(state) -- started, &record(system, state, &1, reply))
      model
    else
      model
    end
  end

  defp run({:read, name}, model, system) do
    if name in SpecModel.get(model, "live") do
      before = AbortSignal.__listener_pid__(system.signal)
      aborted = SpecModel.get(model, "src") == "aborted"

      # The store keeps the reason of a signal whose process stopped for the
      # linger time: after that time, the reason is the default reason. See
      # `tla/AbortSignal.tla`.
      reasons = if aborted, do: [:why, AbortSignal.default_reason()], else: [nil]

      assert {^aborted, reason, nil} = request(system, name, :read)
      assert reason in reasons
      # A read starts no process.
      assert AbortSignal.__listener_pid__(system.signal) == before
    end

    model
  end

  defp run({:stop, name}, model, system) do
    if name in SpecModel.get(model, "live") do
      pid = system.copies[name]
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
      SpecModel.step!(model, "CopyStop", [name])
    else
      model
    end
  end

  defp run(:make_e, model, system) do
    if SpecModel.enabled?(model, "MakeE") do
      {maker, e} = start_maker(system.controller.signal)
      :ets.insert(system.table, {:maker, maker, e})
      SpecModel.step!(model, "MakeE")
    else
      model
    end
  end

  defp run(:abort, model, system) do
    if SpecModel.enabled?(model, "Abort") do
      state = SpecModel.to_map(model)
      fired = state["fired"]

      marked =
        for gen <- gens(state), at(state, "pstate", gen) == "run", do: real_pid(system, gen)

      monitors = Enum.map(marked, &Process.monitor/1)

      assert AbortController.abort(system.controller, :why) == :ok
      model = model |> SpecModel.step!("Abort") |> SpecModel.settle([{"Fire", []}])
      state = SpecModel.to_map(model)

      # The listeners ran in this process before the abort returned, in the
      # sequence of the dependent signals.
      events = events()
      names = for {:event, "L", name} <- events, into: MapSet.new(), do: name
      assert names == MapSet.difference(state["fired"], fired)

      expected = Enum.reject(state["log"], &(&1 == "L" and names == MapSet.new()))
      assert events |> Enum.map(&elem(&1, 1)) |> Enum.dedup() == expected

      # The marked processes stop after their event.
      for monitor <- monitors, do: assert_receive({:DOWN, ^monitor, :process, _pid, _reason})
      model
    else
      model
    end
  end

  # The test waits for more than the linger time. After that time, a process
  # with no use has stopped, if, and only if, the specification permits the
  # step.
  defp run(:pause, model, system) do
    Process.sleep(3 * @linger)

    model
    |> SpecModel.to_map()
    |> gens()
    |> Enum.reduce(model, fn gen, model ->
      if SpecModel.enabled?(model, "Expire", [gen]) do
        assert_down(real_pid(system, gen))
        SpecModel.step!(model, "Expire", [gen])
      else
        model
      end
    end)
  end

  defp record(system, state, gen, reply) do
    if alive?(state, gen) do
      assert is_pid(reply)
      :ets.insert(system.table, {gen, reply})
    else
      assert reply == nil
    end
  end

  # The maker of the signal E keeps it, with a listener that tells the test.
  defp start_maker(source) do
    test = self()

    maker =
      spawn(fn ->
        e = AbortSignal.any([source])
        EventTarget.add_event_listener(e, "abort", fn -> send(test, {:event, "E"}) end)
        send(test, {:e, e})
        Process.sleep(:infinity)
      end)

    assert_receive {:e, e}
    {maker, e}
  end

  defp copy_actions(name) do
    ready = for gen <- 1..length(@copies), do: {"Ready", [gen]}

    Enum.map(~w(Look Start), &{&1, [name]}) ++
      ready ++ Enum.map(~w(Keep Add Release), &{&1, [name]})
  end

  defp events do
    receive do
      {:event, _type, _name} = event -> [event | events()]
      {:event, _type} = event -> [event | events()]
    after
      0 -> []
    end
  end

  # A process with no use stops after the linger time, at each moment: the
  # specification permits the step at each time when it is possible. Thus
  # the model does it when the real process stopped.
  defp follow_expire(model, system) do
    model
    |> SpecModel.to_map()
    |> gens()
    |> Enum.reduce(model, fn gen, model ->
      pid = real_pid(system, gen)

      if at(SpecModel.to_map(model), "pstate", gen) == "run" and not Process.alive?(pid) do
        SpecModel.step!(model, "Expire", [gen])
      else
        model
      end
    end)
  end

  defp assert_down(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 2_000
  end

  # ---------------------------------------------------------------------------
  # The comparison of the two states
  # ---------------------------------------------------------------------------

  defp assert_same_state(model, system) do
    state = SpecModel.to_map(model)

    assert AbortSignal.aborted?(system.controller.signal) == (state["src"] == "aborted")

    alive = for gen <- gens(state), alive?(state, gen), do: gen
    assert length(alive) <= 1

    Enum.each(started(state), &assert_same_process(model, state, system, &1))

    if state["src"] == "open" do
      expected = state["deps"]
      eventually(fn -> real_deps(system, state) == expected end)
    end

    with {_maker, e} <- maker(system) do
      eventually(fn -> Process.alive?(e.pid) == state["e"] in ["run", "aborted"] end)
    end
  end

  defp assert_same_process(model, state, system, gen) do
    pid = real_pid(system, gen)

    cond do
      not alive?(state, gen) ->
        if pid, do: assert_down(pid)

      # A process with no use can stop at each time: the test examines it
      # only after the stop.
      SpecModel.enabled?(model, "Expire", [gen]) ->
        :ok

      true ->
        real = :sys.get_state(pid)
        assert real.keepers == %{}
        assert owner_names(system, real) == at(state, "listeners", gen)
    end
  end

  defp owner_names(system, real) do
    owners = Listeners.owners(real.listeners)
    for {name, pid} <- system.copies, MapSet.member?(owners, pid), into: MapSet.new(), do: name
  end

  # The dependent signals of the source, as the numbers of the specification.
  defp real_deps(system, state) do
    e = maker(system)

    for dependent <- :sys.get_state(system.controller.signal.pid).dependents do
      if e && dependent.pid == elem(e, 1).pid,
        do: 0,
        else: Enum.find(started(state), &(real_pid(system, &1) == dependent.pid))
    end
  end

  defp gens(state), do: state["pstate"] |> indexed() |> Map.keys()
  defp started(state), do: for({gen, value} <- indexed(state["pstate"]), value != "none", do: gen)
  defp alive?(state, gen), do: at(state, "pstate", gen) in ["init", "run", "aborted"]

  defp at(state, variable, gen), do: indexed(state[variable])[gen]

  # A function with the domain 1..n can come as a list.
  defp indexed(list) when is_list(list),
    do: list |> Enum.with_index(1) |> Map.new(fn {v, i} -> {i, v} end)

  defp indexed(map), do: map

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end
end
