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
    frequency([
      {6, tuple({constant(:subscribe), member_of(@clients)})},
      {4, tuple({constant(:unsubscribe), member_of(@clients)})},
      {2, constant(:abort)},
      {2, constant(:owner_stop)},
      {1, tuple({constant(:client_stop), member_of(@clients)})},
      {1, constant(:pause)}
    ])
  end

  property "the signal does each step as the specification permits" do
    check all(commands <- list_of(command(), max_length: 16), max_runs: 100) do
      system = start_system()

      try do
        Enum.reduce(commands, SpecModel.start("AbortSignal"), fn command, model ->
          model = command |> run(model, system) |> follow_timers(system)
          assert_same_state(model, system)
          model
        end)
      after
        stop_system(system)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The real system: an owner that makes the signal, and two clients
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
    clients = Map.new(@clients, fn name -> {name, spawn(fn -> client(signal, []) end)} end)

    %{owner: owner, controller: controller, signal: signal, clients: clients}
  end

  defp stop_system(system) do
    Process.exit(system.owner, :kill)
    Enum.each(system.clients, fn {_name, pid} -> Process.exit(pid, :kill) end)
  end

  # A client keeps its subscriptions, and does one request at a time.
  defp client(signal, subscriptions) do
    receive do
      {:subscribe, from} ->
        case AbortSignal.subscribe(signal) do
          {:ok, subscription} ->
            send(from, {:reply, self(), :ok})
            client(signal, [subscription | subscriptions])

          {:error, :aborted} ->
            send(from, {:reply, self(), :aborted})
            client(signal, subscriptions)
        end

      {:unsubscribe, from} ->
        [subscription | rest] = subscriptions
        :ok = AbortSignal.unsubscribe(subscription)
        send(from, {:reply, self(), :ok})
        client(signal, rest)

      {:abort_seen, from} ->
        results = Enum.map(subscriptions, &AbortSignal.receive_abort(&1, 500, true))
        send(from, {:reply, self(), results})
        client(signal, [])
    end
  end

  defp request(system, client, request) do
    pid = system.clients[client]
    send(pid, {request, self()})

    receive do
      {:reply, ^pid, reply} -> reply
    after
      2_000 -> flunk("the client #{client} gave no reply to #{request}")
    end
  end

  # ---------------------------------------------------------------------------
  # One operation, on the real signal and on the specification
  # ---------------------------------------------------------------------------

  defp run({:subscribe, client}, model, system) do
    state = SpecModel.to_map(model)

    cond do
      to_string(client) not in state["live"] ->
        model

      SpecModel.enabled?(model, "Subscribe", [client]) ->
        assert request(system, client, :subscribe) == :ok
        SpecModel.step!(model, "Subscribe", [client])

      not state["running"] ->
        # A signal that stopped is the same as an aborted signal.
        assert request(system, client, :subscribe) == :aborted
        model

      true ->
        # The client has the largest number of subscriptions of the model.
        model
    end
  end

  defp run({:unsubscribe, client}, model, system) do
    if SpecModel.enabled?(model, "Unsubscribe", [client]) do
      assert request(system, client, :unsubscribe) == :ok
      SpecModel.step!(model, "Unsubscribe", [client])
    else
      model
    end
  end

  defp run(:abort, model, system) do
    monitor = Process.monitor(system.signal.pid)
    started = System.monotonic_time(:millisecond)
    assert AbortController.abort(system.controller, :my_reason) == :ok
    reason = AbortSignal.Reasons.get(system.signal.ref)
    elapsed = System.monotonic_time(:millisecond) - started

    if SpecModel.enabled?(model, "Abort") do
      # The process of the signal stops after its answer to the abort.
      assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 2_000

      # The store has the reason immediately after the abort. The store can
      # remove it only after the linger time.
      if elapsed < @linger, do: assert(reason == :my_reason)

      subscriptions = SpecModel.get(model, "subs")

      # Each client that is subscribed gets the abort, one time for each of
      # its subscriptions.
      for {name, count} <- subscriptions, count > 0 do
        results = request(system, String.to_existing_atom(name), :abort_seen)
        assert results == List.duplicate({:error, :aborted, :my_reason}, count)
      end

      SpecModel.step!(model, "Abort")
    else
      Process.demonitor(monitor, [:flush])
      model
    end
  end

  defp run(:owner_stop, model, system) do
    if SpecModel.enabled?(model, "OwnerStop") do
      Process.exit(system.owner, :kill)
      SpecModel.step!(model, "OwnerStop")
    else
      model
    end
  end

  defp run({:client_stop, client}, model, system) do
    if SpecModel.enabled?(model, "ClientStop", [client]) do
      pid = system.clients[client]
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
      SpecModel.step!(model, "ClientStop", [client])
    else
      model
    end
  end

  # The test waits for more than the linger time. After that time, the
  # signal is stopped if, and only if, the specification permits the step
  # Expire.
  defp run(:pause, model, system) do
    Process.sleep(3 * @linger)

    if SpecModel.enabled?(model, "Expire") do
      # The stop can come late on a busy machine: the test waits for it.
      monitor = Process.monitor(system.signal.pid)

      assert_receive {:DOWN, ^monitor, :process, _pid, _reason},
                     2_000,
                     "the signal did not stop after the linger time"

      SpecModel.step!(model, "Expire")
    else
      model
    end
  end

  # The linger time can be complete at this moment, and the store can remove
  # a reason at this moment. The specification permits those steps at each
  # time when they are possible. Thus the model does them when the real
  # system did them.
  defp follow_timers(model, system) do
    model
    |> follow(not Process.alive?(system.signal.pid) and SpecModel.get(model, "running"), "Expire")
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

    if state["running"], do: assert(subscriptions(system) == state["subs"])
  end

  # The number of subscriptions that the signal has for each client.
  defp subscriptions(system) do
    subscribers = :sys.get_state(system.signal.pid).subscribers

    Map.new(system.clients, fn {name, pid} ->
      count =
        case subscribers do
          %{^pid => {_monitor, count}} -> count
          _ -> 0
        end

      {to_string(name), count}
    end)
  end
end
