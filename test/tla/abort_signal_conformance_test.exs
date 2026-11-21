defmodule Web.TLA.AbortSignalConformanceTest do
  # Compares the real `Web.AbortSignal` with the specification
  # `tla/AbortSignal.tla`.
  #
  # The test makes a random list of operations. It does each operation on a
  # real signal and on the specification, and it compares the two states.
  #
  # The test sets the linger time for the application. Thus it cannot run at
  # the same time as other tests.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Web.AbortController
  alias Web.AbortSignal
  alias Web.EventTarget
  alias Web.Internal.EventTarget.Listeners
  alias Web.Test.SpecModel

  @clients [:c1, :c2]
  @linger 15

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
    client = member_of(@clients)

    frequency([
      {6, tuple({constant(:subscribe), client})},
      {4, tuple({constant(:unsubscribe), client})},
      {3, tuple({constant(:use), client, member_of([:listener, :algorithm])})},
      {2, tuple({constant(:unuse), client})},
      {3, constant(:depend)},
      {1, constant(:maker_stop)},
      {1, constant(:abort)},
      {3, constant(:owner_stop)},
      {1, tuple({constant(:client_stop), client})},
      {2, constant(:pause)}
    ])
  end

  property "the signal does each step as the specification permits" do
    check all(commands <- list_of(command(), max_length: 16), max_runs: 100) do
      run_commands(commands)
    end
  end

  # Lists of operations that the random lists do not often give: each one
  # needs a rule of the lifetime.
  test "the signal does the steps of known lists of operations as the specification permits" do
    for commands <- [
          [:depend, :owner_stop, :pause],
          [{:use, :c1, :listener}, :owner_stop, :pause, {:unuse, :c1}, :pause],
          [{:use, :c2, :algorithm}, :owner_stop, :pause, {:client_stop, :c2}, :pause],
          [:depend, :maker_stop, :owner_stop, :pause, :pause],
          [{:subscribe, :c1}, :depend, {:use, :c2, :listener}, :abort]
        ] do
      run_commands(commands)
    end
  end

  defp run_commands(commands) do
    system = start_system()

    try do
      Enum.reduce(commands, {SpecModel.start("AbortSignal"), system}, fn command,
                                                                         {model, system} ->
        {model, system} = run(command, model, system)
        model = follow_timers(model, system)
        assert_same_state(model, system)
        {model, system}
      end)
    after
      stop_system(system)
    end
  end

  # ---------------------------------------------------------------------------
  # The real system: an owner that makes the signal, two clients, and the
  # maker of the dependent signal
  # ---------------------------------------------------------------------------

  defp start_system do
    test = self()

    owner =
      spawn(fn ->
        send(test, {:controller, AbortController.new()})
        Process.sleep(:infinity)
      end)

    assert_receive {:controller, controller}
    signal = controller.signal

    clients =
      Map.new(@clients, fn name -> {name, spawn(fn -> client(name, signal, [], nil) end)} end)

    %{
      owner: owner,
      controller: controller,
      signal: signal,
      clients: clients,
      maker: nil,
      dep: nil
    }
  end

  defp stop_system(system) do
    Process.exit(system.owner, :kill)
    Enum.each(system.clients, fn {_name, pid} -> Process.exit(pid, :kill) end)
    if system.maker, do: Process.exit(system.maker, :kill)
  end

  # A client keeps its subscriptions and its use, and does one request at a
  # time. The listener and the abort algorithm send a message to the test.
  defp client(name, signal, subscriptions, use) do
    receive do
      {:subscribe, from} ->
        case AbortSignal.subscribe(signal) do
          {:ok, subscription} ->
            send(from, {:reply, self(), :ok})
            client(name, signal, [subscription | subscriptions], use)

          {:error, :aborted} ->
            send(from, {:reply, self(), :aborted})
            client(name, signal, subscriptions, use)
        end

      {:unsubscribe, from} ->
        [subscription | rest] = subscriptions
        :ok = AbortSignal.unsubscribe(subscription)
        send(from, {:reply, self(), :ok})
        client(name, signal, rest, use)

      {{:use, :listener}, from} ->
        listener = fn -> send(from, {:used, name}) end
        EventTarget.add_event_listener(signal, "abort", listener)
        send(from, {:reply, self(), :ok})
        client(name, signal, subscriptions, {:listener, listener})

      {{:use, :algorithm}, from} ->
        :ok = AbortSignal.__add_algorithm__(signal, {Kernel, :send, [from, {:used, name}]})
        send(from, {:reply, self(), :ok})
        client(name, signal, subscriptions, :algorithm)

      {:unuse, from} ->
        {:listener, listener} = use
        EventTarget.remove_event_listener(signal, "abort", listener)
        send(from, {:reply, self(), :ok})
        client(name, signal, subscriptions, nil)

      {:use_kind, from} ->
        send(from, {:reply, self(), use})
        client(name, signal, subscriptions, use)

      {:abort_seen, from} ->
        results = Enum.map(subscriptions, &AbortSignal.receive_abort(&1, 500, true))
        send(from, {:reply, self(), results})
        client(name, signal, [], use)
    end
  end

  defp request(system, client, request) do
    pid = system.clients[client]
    send(pid, {request, self()})

    receive do
      {:reply, ^pid, reply} -> reply
    after
      2_000 -> flunk("the client #{client} gave no reply to #{inspect(request)}")
    end
  end

  # ---------------------------------------------------------------------------
  # One operation, on the real signal and on the specification
  # ---------------------------------------------------------------------------

  defp run({:subscribe, client}, model, system) do
    state = SpecModel.to_map(model)

    cond do
      to_string(client) not in state["live"] ->
        {model, system}

      SpecModel.enabled?(model, "Subscribe", [client]) ->
        assert request(system, client, :subscribe) == :ok
        {SpecModel.step!(model, "Subscribe", [client]), system}

      not state["running"] or state["aborted"] ->
        # A signal that stopped or aborted is an aborted signal.
        assert request(system, client, :subscribe) == :aborted
        {model, system}

      true ->
        # The client has the largest number of subscriptions of the model.
        {model, system}
    end
  end

  defp run({:unsubscribe, client}, model, system) do
    if SpecModel.enabled?(model, "Unsubscribe", [client]) do
      assert request(system, client, :unsubscribe) == :ok
      {SpecModel.step!(model, "Unsubscribe", [client]), system}
    else
      {model, system}
    end
  end

  defp run({:use, client, kind}, model, system) do
    if SpecModel.enabled?(model, "Use", [client]) do
      assert request(system, client, {:use, kind}) == :ok
      {SpecModel.step!(model, "Use", [client]), system}
    else
      {model, system}
    end
  end

  # An abort algorithm has no remove: only a listener is removed.
  defp run({:unuse, client}, model, system) do
    if SpecModel.enabled?(model, "Unuse", [client]) and
         match?({:listener, _}, request(system, client, :use_kind)) do
      assert request(system, client, :unuse) == :ok
      {SpecModel.step!(model, "Unuse", [client]), system}
    else
      {model, system}
    end
  end

  defp run(:depend, model, system) do
    if SpecModel.enabled?(model, "Depend") and SpecModel.get(model, "maker_alive") do
      test = self()

      maker =
        spawn(fn ->
          send(test, {:dependent, AbortSignal.any([system.signal])})
          Process.sleep(:infinity)
        end)

      assert_receive {:dependent, dep}
      {SpecModel.step!(model, "Depend"), %{system | maker: maker, dep: dep}}
    else
      {model, system}
    end
  end

  defp run(:maker_stop, model, system) do
    if system.maker && SpecModel.enabled?(model, "MakerStop") do
      monitor = Process.monitor(system.maker)
      Process.exit(system.maker, :kill)
      assert_receive {:DOWN, ^monitor, :process, _pid, :killed}
      {SpecModel.step!(model, "MakerStop"), system}
    else
      {model, system}
    end
  end

  defp run(:abort, model, system) do
    if SpecModel.enabled?(model, "Abort") do
      signal_monitor = Process.monitor(system.signal.pid)
      dep_monitor = system.dep && Process.monitor(system.dep.pid)
      users = SpecModel.get(model, "users")
      subscriptions = SpecModel.get(model, "subs")
      dep = SpecModel.get(model, "dep")

      started = System.monotonic_time(:millisecond)
      assert AbortController.abort(system.controller, :my_reason) == :ok
      reason = AbortSignal.Reasons.get(system.signal.ref)
      elapsed = System.monotonic_time(:millisecond) - started

      # The steps ran before the abort returned: each listener and each
      # abort algorithm of a client sent its message.
      for name <- users, name = String.to_existing_atom(name), do: assert_received({:used, ^name})

      # The store has the reason immediately after the abort. The store can
      # remove it only after the linger time.
      if elapsed < @linger, do: assert(reason == :my_reason)

      # Each client that is subscribed gets the abort, one time for each of
      # its subscriptions.
      for {name, count} <- subscriptions, count > 0 do
        results = request(system, String.to_existing_atom(name), :abort_seen)
        assert results == List.duplicate({:error, :aborted, :my_reason}, count)
      end

      # The processes stop after the steps of the abort.
      assert_receive {:DOWN, ^signal_monitor, :process, _pid, _reason}, 2_000
      model = model |> SpecModel.step!("Abort") |> SpecModel.step!("StepsEnd")
      model = model |> SpecModel.step!("SignalStop") |> stop_dependent(dep, dep_monitor)
      {model, system}
    else
      {model, system}
    end
  end

  defp run(:owner_stop, model, system) do
    if SpecModel.enabled?(model, "OwnerStop") do
      Process.exit(system.owner, :kill)
      {SpecModel.step!(model, "OwnerStop"), system}
    else
      {model, system}
    end
  end

  defp run({:client_stop, client}, model, system) do
    if SpecModel.enabled?(model, "ClientStop", [client]) do
      pid = system.clients[client]
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
      {model |> SpecModel.step!("ClientStop", [client]) |> await_users(system), system}
    else
      {model, system}
    end
  end

  # The test waits for more than the linger time. After that time, a signal
  # with no use has stopped, if, and only if, the specification permits the
  # step.
  defp run(:pause, model, system) do
    Process.sleep(3 * @linger)

    model =
      if SpecModel.enabled?(model, "DepExpire") do
        assert_down(system.dep.pid, "the dependent signal did not stop after the linger time")
        SpecModel.step!(model, "DepExpire")
      else
        model
      end

    model =
      if SpecModel.enabled?(model, "Expire") do
        assert_down(system.signal.pid, "the signal did not stop after the linger time")
        SpecModel.step!(model, "Expire")
      else
        model
      end

    {model, system}
  end

  # The signal gets the stop of the client from the system: the test waits
  # until the signal removed the client.
  defp await_users(model, system) do
    if SpecModel.get(model, "running"),
      do: eventually(fn -> real_users(system) == SpecModel.get(model, "users") end)

    model
  end

  # A dependent signal that runs stops after the steps of the abort.
  defp stop_dependent(model, "running", monitor) do
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 2_000
    SpecModel.step!(model, "DepStop")
  end

  defp stop_dependent(model, _dep, monitor) do
    if monitor, do: Process.demonitor(monitor, [:flush])
    model
  end

  defp assert_down(pid, message) do
    # The stop can come late on a busy machine: the test waits for it.
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 2_000, message
  end

  # The linger time can be complete at this moment, and the store can remove
  # a reason at this moment. The specification permits those steps at each
  # time when they are possible. Thus the model does them when the real
  # system did them.
  defp follow_timers(model, system) do
    model
    |> follow(not Process.alive?(system.signal.pid) and SpecModel.get(model, "running"), "Expire")
    |> follow(
      system.dep != nil and not Process.alive?(system.dep.pid) and
        SpecModel.get(model, "dep") == "running",
      "DepExpire"
    )
    |> follow(not stored?(system) and SpecModel.get(model, "stored"), "Sweep")
  end

  defp follow(model, true, action) do
    if SpecModel.enabled?(model, action), do: SpecModel.step!(model, action), else: model
  end

  defp follow(model, false, _action), do: model

  defp stored?(system), do: AbortSignal.Reasons.get(system.signal.ref) != nil

  # ---------------------------------------------------------------------------
  # The comparison of the two states
  # ---------------------------------------------------------------------------

  defp assert_same_state(model, system) do
    state = SpecModel.to_map(model)
    pid = system.signal.pid

    assert Process.alive?(pid) == state["running"],
           "the signal is #{if Process.alive?(pid), do: "alive", else: "stopped"}, " <>
             "but the specification has #{inspect(state)}"

    assert stored?(system) == state["stored"],
           "the store #{if stored?(system), do: "has", else: "does not have"} the reason, " <>
             "but the specification has #{inspect(state)}"

    if system.dep do
      assert Process.alive?(system.dep.pid) == state["dep"] in ["running", "aborted"]
    end

    if state["running"] do
      real = :sys.get_state(pid)
      assert subscriptions(system, real) == state["subs"]
      assert real_users(system) == state["users"]
      assert real.aborted != nil == state["aborted"]

      assert Enum.map(real.dependents, & &1.pid) ==
               if(state["dep"] == "running", do: [system.dep.pid], else: [])
    end
  end

  # The number of subscriptions that the signal has for each client.
  defp subscriptions(system, real) do
    Map.new(system.clients, fn {name, pid} ->
      count =
        case real.subscribers do
          %{^pid => {_monitor, count}} -> count
          _ -> 0
        end

      {to_string(name), count}
    end)
  end

  # The clients with a listener or an abort algorithm on the signal.
  defp real_users(system) do
    real = :sys.get_state(system.signal.pid)

    owners =
      MapSet.union(Listeners.owners(real.listeners), MapSet.new(real.algorithms, &elem(&1, 0)))

    for {name, pid} <- system.clients,
        MapSet.member?(owners, pid),
        into: MapSet.new(),
        do: to_string(name)
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end
end
