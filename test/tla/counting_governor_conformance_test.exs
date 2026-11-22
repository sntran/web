defmodule Web.TLA.CountingGovernorConformanceTest do
  # Compares a real `Web.CountingGovernor` with the specification
  # `tla/ConnectionPool.tla`.
  #
  # A governor and the pool of the connections of an origin count their
  # slots with the same rules: a limit, a first-in, first-out queue, a cancel
  # of a wait, and the stop of a holder or of a process that waits. A
  # governor has no idle connections, thus the test uses the steps of the
  # specification that have no idle connection: a token is a slot, and a
  # release gives back the slot.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.AbortableGovernor
  alias Web.CountingGovernor
  alias Web.GovernorToken
  alias Web.Promise
  alias Web.Test.SpecModel

  @procs ["a", "b", "c"]
  @size 2
  @constants {"Size = 2", "Size = #{@size}"}

  defp command do
    proc = member_of(@procs)

    frequency([
      {5, tuple({constant("Checkout"), proc})},
      {3, tuple({constant("Release"), proc})},
      {2, tuple({constant("Cancel"), proc})},
      {2, tuple({constant("Stop"), proc})}
    ])
  end

  property "the governor does each step as the specification permits" do
    check all(commands <- list_of(command(), max_length: 24), max_runs: 60) do
      system = start_system()

      try do
        Enum.reduce(commands, {SpecModel.start("ConnectionPool", @constants), system}, fn
          command, {model, system} ->
            {model, system} = run(command, model, system)
            assert_same_state(model, system)
            {model, system}
        end)
      after
        stop_system(system)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The real system: a governor, and one client for each process
  # ---------------------------------------------------------------------------

  defp start_system do
    {:ok, pid} = CountingGovernor.start_link(capacity: @size)
    system = %{governor: CountingGovernor.get(pid), clients: %{}}
    Enum.reduce(@procs, system, &start_client(&2, &1))
  end

  defp stop_system(system) do
    for {_name, pid} <- system.clients, do: Process.exit(pid, :kill)
    GenServer.stop(system.governor.pid)
  end

  defp start_client(system, name) do
    test = self()
    state = %{holder: "none", acquisition: nil, token: nil}
    pid = spawn(fn -> client(test, system.governor, state) end)
    put_in(system.clients[name], pid)
  end

  # A client is the holder of its tokens: it acquires in its own process.
  defp client(test, governor, state) do
    receive do
      {:command, command} ->
        state = client_command(command, governor, state)
        send(test, {:client, self(), status(state)})
        client(test, governor, state)
    end
  end

  defp status(state), do: %{holder: state.holder, token: state.token && state.token.ref}

  # The governor knows the acquisition after this function: the promise of
  # the acquisition sends it to the governor.
  defp client_command("Checkout", governor, state) do
    acquisition = AbortableGovernor.acquire_abortable(governor)
    eventually(fn -> known?(governor, acquisition.promise) end)
    take_token(%{state | holder: "waiting", acquisition: acquisition})
  end

  defp client_command("Release", _governor, state) do
    :ok = GovernorToken.release(state.token)
    %{holder: "none", acquisition: nil, token: nil}
  end

  defp client_command("Cancel", _governor, state) do
    :ok = state.acquisition.abort.()

    assert {:rejected, %Web.DOMException{name: "AbortError"}} =
             Promise.wait(state.acquisition.promise)

    %{holder: "none", acquisition: nil, token: nil}
  end

  defp client_command(:status, _governor, state), do: take_token(state)

  # The client is the holder of the acquisition that waits.
  defp known?(governor, promise) do
    governor_state = :sys.get_state(governor.pid)

    Enum.any?(Map.values(governor_state.waiting), &(&1.holder == self())) or
      Promise.peek(promise) != :pending
  end

  # A client that waits has its token when its promise is fulfilled.
  defp take_token(%{holder: "waiting", acquisition: acquisition} = state) do
    case Promise.peek(acquisition.promise) do
      {:fulfilled, token} -> %{state | holder: "slot", token: token}
      :pending -> state
    end
  end

  defp take_token(state), do: state

  defp call(system, name, command) do
    pid = system.clients[name]
    send(pid, {:command, command})

    receive do
      {:client, ^pid, result} -> result
    after
      2_000 -> flunk("the client #{name} gave no answer")
    end
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  # ---------------------------------------------------------------------------
  # One operation, on the real governor and on the specification
  # ---------------------------------------------------------------------------

  # The governor gets the stop from its monitors: the comparison waits for
  # it.
  defp run({"Stop", name}, model, system) do
    if SpecModel.enabled?(model, "Stop", [name]) do
      pid = system.clients[name]
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
      {SpecModel.step!(model, "Stop", [name]), start_client(system, name)}
    else
      {model, system}
    end
  end

  defp run({action, name}, model, system) do
    if SpecModel.enabled?(model, action, [name]) do
      %{holder: holder} = call(system, name, action)
      model = SpecModel.step!(model, action, [name])
      assert holder == SpecModel.get(model, "holder")[name], "#{action} of #{name}"
      {model, system}
    else
      {model, system}
    end
  end

  # ---------------------------------------------------------------------------
  # The comparison
  # ---------------------------------------------------------------------------

  # A grant, and the stop of a holder or of a waiter, come to the clients
  # after some time: the comparison waits for them.
  defp assert_same_state(model, system, attempts \\ 200) do
    compare(model, system)
  rescue
    error in ExUnit.AssertionError ->
      if attempts == 0, do: reraise(error, __STACKTRACE__)
      Process.sleep(5)
      assert_same_state(model, system, attempts - 1)
  end

  defp compare(model, system) do
    statuses = Map.new(@procs, &{&1, call(system, &1, :status)})
    governor = :sys.get_state(system.governor.pid)

    holders = Map.new(statuses, fn {name, status} -> {name, status.holder} end)
    assert holders == SpecModel.get(model, "holder")

    # The slots of the specification are the tokens of the governor.
    names_of_tokens = Map.new(statuses, fn {name, status} -> {status.token, name} end)
    slots = governor.active_tokens |> Map.keys() |> MapSet.new(&Map.get(names_of_tokens, &1))
    assert slots == MapSet.new(SpecModel.get(model, "slots"))
    assert governor.in_use == map_size(governor.active_tokens)

    # The queue of the governor has the acquisitions, with their holders.
    names_of_pids = Map.new(system.clients, fn {name, pid} -> {pid, name} end)

    queue =
      for ref <- :queue.to_list(governor.queue),
          do: Map.get(names_of_pids, governor.waiting[ref].holder)

    assert queue == SpecModel.get(model, "queue")
    assert SpecModel.get(model, "idle") == 0
  end
end
