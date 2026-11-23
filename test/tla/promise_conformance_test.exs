defmodule Web.TLA.PromiseConformanceTest do
  # Compares the real `Web.Promise` with the specification `tla/Promise.tla`.
  #
  # The test makes a random list of operations. It does each operation on a
  # real promise and on the specification, and it compares what the clients
  # see. A difference shows that the code and the specification do not agree.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Promise
  alias Web.Test.SpecModel

  @clients [:c1, :c2, :c3]
  @linger 15

  defp command do
    frequency([
      {3, tuple({constant(:settle), member_of(["fulfilled", "rejected"])})},
      {6, tuple({constant(:await), member_of(@clients)})},
      {1, constant(:owner_stop)},
      {1, constant(:pause)}
    ])
  end

  property "the promise does each step as the specification permits" do
    check all(commands <- list_of(command(), max_length: 14), max_runs: 120) do
      system = start_system()

      try do
        Enum.reduce(commands, SpecModel.start("Promise"), fn command, model ->
          model = run(command, model, system)
          assert_same_state(model, system)
          model
        end)
      after
        stop_system(system)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The real system: an owner that makes the promise, and three clients
  # ---------------------------------------------------------------------------

  defp start_system do
    test = self()

    owner =
      spawn(fn ->
        send(test, {:promise, Promise.__with_resolvers__(linger: @linger)})
        Process.sleep(:infinity)
      end)

    assert_receive {:promise, {promise, resolve, reject}}

    # The messages of the clients have the reference of this run. Thus a
    # message of a run that failed does not go to the next run.
    run = make_ref()
    clients = Map.new(@clients, fn name -> {name, spawn(fn -> client(name, {test, run}) end)} end)

    %{
      run: run,
      owner: owner,
      promise: promise,
      resolve: resolve,
      reject: reject,
      clients: clients,
      monitor: Process.monitor(promise.pid)
    }
  end

  defp stop_system(system) do
    Process.exit(system.owner, :kill)
    Enum.each(system.clients, fn {_name, pid} -> Process.exit(pid, :kill) end)
  end

  defp client(name, {test, run} = target) do
    receive do
      {:await, promise} ->
        send(test, {:seen, run, name, seen(Promise.wait(promise))})
        client(name, target)
    end
  end

  defp seen({:fulfilled, :value}), do: "fulfilled"
  defp seen({:rejected, :reason}), do: "rejected"
  defp seen({:rejected, %Web.TypeError{}}), do: "released"

  # ---------------------------------------------------------------------------
  # One operation, on the real promise and on the specification
  # ---------------------------------------------------------------------------

  defp run({:settle, outcome}, model, system) do
    case outcome do
      "fulfilled" -> system.resolve.(:value)
      "rejected" -> system.reject.(:reason)
    end

    if SpecModel.enabled?(model, "Settle", [outcome]) do
      # Each client that waits gets the outcome.
      for client <- SpecModel.get(model, "waiting") do
        assert_seen(system, client, outcome)
      end

      SpecModel.step!(model, "Settle", [outcome])
    else
      SpecModel.step!(model, "SettleAgain", [outcome])
    end
  end

  defp run({:await, client}, model, system) do
    if to_string(client) in SpecModel.get(model, "waiting") do
      # The client waits already. It cannot await a second time.
      model
    else
      send(system.clients[client], {:await, system.promise})
      observed = observe_await(client, system)

      # The linger time can be complete at this moment. Then the
      # specification does the step Expire before the await.
      [model, expire(model)]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&SpecModel.step!(&1, "Await", [client]))
      |> Enum.find(&(expected_await(&1, client) == observed)) ||
        flunk(
          "the await of #{client} gave #{inspect(observed)}, in #{inspect(SpecModel.to_map(model))}"
        )
    end
  end

  defp run(:owner_stop, model, system) do
    if SpecModel.enabled?(model, "OwnerStop") do
      waiting = SpecModel.get(model, "waiting")
      Process.exit(system.owner, :kill)
      assert_stopped(system)

      for client <- waiting do
        assert_seen(system, client, "released")
      end

      SpecModel.step!(model, "OwnerStop")
    else
      model
    end
  end

  # The test waits for more than the linger time. After that time, the
  # promise is stopped if, and only if, the specification permits the step
  # Expire.
  defp run(:pause, model, system) do
    Process.sleep(3 * @linger)

    if SpecModel.enabled?(model, "Expire") do
      assert_stopped(system)
      SpecModel.step!(model, "Expire")
    else
      model
    end
  end

  defp assert_seen(%{run: run}, client, result) do
    name = String.to_existing_atom(client)
    assert_receive {:seen, ^run, ^name, ^result}, 1_000
  end

  defp expire(model) do
    if SpecModel.enabled?(model, "Expire"), do: SpecModel.step!(model, "Expire")
  end

  # What the client sees after the await: the result, or `:waits`.
  defp expected_await(model, client) do
    name = to_string(client)

    if name in SpecModel.get(model, "waiting") do
      :waits
    else
      SpecModel.get(model, "seen")[name]
    end
  end

  defp observe_await(client, system, attempts \\ 2_000) do
    run = system.run

    receive do
      {:seen, ^run, ^client, result} -> result
    after
      0 ->
        cond do
          waits?(system.clients[client], system.promise.pid) -> :waits
          attempts == 0 -> flunk("the await of #{client} gave no result")
          true -> pause_and(fn -> observe_await(client, system, attempts - 1) end)
        end
    end
  end

  defp pause_and(fun) do
    Process.sleep(1)
    fun.()
  end

  # The client is in the receive of `Promise.wait/1` and has no message to
  # read. The promise has no message to read. Thus the promise has the
  # subscription of the client and gave no answer.
  #
  # The test examines the client before and after the promise. An answer that
  # the promise sent between the two examinations is thus not missed.
  defp waits?(client, promise_pid) do
    in_wait?(client) and idle?(promise_pid) and in_wait?(client)
  end

  defp in_wait?(client) do
    Process.info(client, [:current_function, :message_queue_len, :status]) ==
      [current_function: {Promise, :wait, 1}, message_queue_len: 0, status: :waiting]
  end

  defp idle?(pid) do
    Process.info(pid, [:message_queue_len, :status]) == [message_queue_len: 0, status: :waiting]
  end

  defp assert_stopped(system) do
    monitor = system.monitor
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 2_000
    # Put the message back for a second call.
    send(self(), {:DOWN, monitor, :process, system.promise.pid, :seen})
  end

  # ---------------------------------------------------------------------------
  # The comparison of the two states
  # ---------------------------------------------------------------------------

  defp assert_same_state(model, system) do
    state = SpecModel.to_map(model)

    # A promise that the specification stopped is stopped. A promise that the
    # specification keeps can be stopped only if the step Expire is possible:
    # then the linger time was complete at this moment.
    if state["alive"] do
      assert Process.alive?(system.promise.pid) or SpecModel.enabled?(model, "Expire"),
             "the promise stopped, but the specification keeps it: #{inspect(state)}"
    else
      refute Process.alive?(system.promise.pid),
             "the promise is alive, but the specification stopped it: #{inspect(state)}"
    end

    # No client has a result that the test did not read.
    run = system.run
    refute_received {:seen, ^run, _client, _result}
  end
end
