defmodule Web.GovernorPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.AbortableGovernor
  alias Web.CountingGovernor
  alias Web.Governor.Token
  alias Web.Promise

  @clients [:a, :b, :c]

  # ---------------------------------------------------------------------------
  # The model: a counter and a queue
  # ---------------------------------------------------------------------------

  defp new_model(capacity) do
    %{
      capacity: capacity,
      in_use: 0,
      # The clients that wait, the oldest first. A client can be in the queue
      # more than one time.
      queue: [],
      clients: Map.new(@clients, &{&1, %{alive: true, held: 0, waiting: 0}})
    }
  end

  defp apply_command(model, {command, client}) do
    if model.clients[client].alive do
      model |> apply_alive(command, client) |> grant_next()
    else
      model
    end
  end

  defp apply_alive(model, :acquire, client) do
    model
    |> Map.update!(:queue, &(&1 ++ [client]))
    |> update_in([:clients, client, :waiting], &(&1 + 1))
  end

  defp apply_alive(model, :release, client) do
    if model.clients[client].held > 0 do
      model
      |> Map.update!(:in_use, &(&1 - 1))
      |> update_in([:clients, client, :held], &(&1 - 1))
    else
      model
    end
  end

  # The client aborts its oldest acquisition that waits.
  defp apply_alive(model, :abort, client) do
    if model.clients[client].waiting > 0 do
      model
      |> Map.update!(:queue, &List.delete(&1, client))
      |> update_in([:clients, client, :waiting], &(&1 - 1))
    else
      model
    end
  end

  # The governor takes back the tokens of the client, and removes the client
  # from the queue.
  defp apply_alive(model, :stop, client) do
    model
    |> Map.update!(:in_use, &(&1 - model.clients[client].held))
    |> Map.update!(:queue, &Enum.reject(&1, fn waiting -> waiting == client end))
    |> put_in([:clients, client], %{alive: false, held: 0, waiting: 0})
  end

  defp grant_next(%{in_use: in_use, capacity: capacity, queue: [client | queue]} = model)
       when in_use < capacity do
    model
    |> Map.merge(%{in_use: in_use + 1, queue: queue})
    |> update_in([:clients, client, :waiting], &(&1 - 1))
    |> update_in([:clients, client, :held], &(&1 + 1))
    |> grant_next()
  end

  defp grant_next(model), do: model

  # ---------------------------------------------------------------------------
  # The real system: one governor, and one process for each client
  # ---------------------------------------------------------------------------

  defp client_loop(governor, pending, held) do
    {pending, held} = refresh(pending, held)

    receive do
      :acquire ->
        client_loop(governor, pending ++ [AbortableGovernor.acquire_abortable(governor)], held)

      :release ->
        case held do
          [token | rest] ->
            :ok = Token.release(token)
            client_loop(governor, pending, rest)

          [] ->
            client_loop(governor, pending, held)
        end

      :abort ->
        case pending do
          [acquisition | rest] ->
            :ok = acquisition.abort.()
            {:rejected, %Web.DOMException{name: "AbortError"}} = Promise.wait(acquisition.promise)
            client_loop(governor, rest, held)

          [] ->
            client_loop(governor, pending, held)
        end

      {:status, from, ref} ->
        send(from, {ref, %{held: length(held), waiting: length(pending)}})
        client_loop(governor, pending, held)
    end
  end

  # Moves each acquisition that has its token to the list of the tokens.
  defp refresh(pending, held) do
    Enum.reduce(pending, {[], held}, fn acquisition, {still_pending, held} ->
      case Promise.peek(acquisition.promise) do
        {:fulfilled, %Token{} = token} -> {still_pending, held ++ [token]}
        :pending -> {still_pending ++ [acquisition], held}
      end
    end)
  end

  defp status(pid) do
    ref = make_ref()
    send(pid, {:status, self(), ref})

    # A client that waits with no end gives no status. A machine that is
    # busy can make a client slow, thus the limit is large.
    receive do
      {^ref, status} -> status
    after
      5_000 -> flunk("a client gave no status")
    end
  end

  defp run_command(clients, {:stop, client}) do
    pid = clients[client]

    if Process.alive?(pid) do
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
    end
  end

  defp run_command(clients, {command, client}) do
    if Process.alive?(clients[client]), do: send(clients[client], command)
  end

  # The real state, in the form of the model.
  defp real_state(governor, clients, model) do
    state = :sys.get_state(governor.pid)

    %{
      model
      | in_use: state.in_use,
        queue: :queue.len(state.queue),
        clients:
          Map.new(clients, fn {name, pid} ->
            if Process.alive?(pid) do
              {name, Map.put(status(pid), :alive, true)}
            else
              {name, %{alive: false, held: 0, waiting: 0}}
            end
          end)
    }
  end

  defp assert_same(governor, clients, model, attempts \\ 200) do
    expected = %{model | queue: length(model.queue)}
    real = real_state(governor, clients, model)

    cond do
      real == expected ->
        :ok

      attempts == 0 ->
        flunk("the governor has #{inspect(real)}, but the model has #{inspect(expected)}")

      true ->
        Process.sleep(2)
        assert_same(governor, clients, model, attempts - 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(2) && wait_until(fun, attempts - 1)
    end
  end

  defp command do
    tuple({
      frequency([
        {5, constant(:acquire)},
        {4, constant(:release)},
        {2, constant(:abort)},
        {1, constant(:stop)}
      ]),
      member_of(@clients)
    })
  end

  property "the governor gives its tokens as a counter with a first-in, first-out queue" do
    check all(
            capacity <- integer(0..3),
            commands <- list_of(command(), max_length: 40),
            max_runs: 60
          ) do
      governor = CountingGovernor.new(capacity)
      clients = Map.new(@clients, &{&1, spawn(fn -> client_loop(governor, [], []) end)})

      try do
        final =
          Enum.reduce(commands, new_model(capacity), fn command, model ->
            run_command(clients, command)
            model = apply_command(model, command)

            # The number of the tokens in use is never more than the capacity.
            assert model.in_use <= capacity
            assert_same(governor, clients, model)
            model
          end)

        # When all the clients stop, the governor has all its capacity, and
        # keeps no data about them.
        for client <- @clients, do: run_command(clients, {:stop, client})
        stopped = Enum.reduce(@clients, final, &apply_command(&2, {:stop, &1}))
        assert stopped.in_use == 0
        assert_same(governor, clients, stopped)

        state = :sys.get_state(governor.pid)
        assert state.active_tokens == %{}
        assert state.holder_monitors == %{}
        assert state.waiting == %{}
        assert state.waiter_monitors == %{}
      after
        for {_name, pid} <- clients, do: Process.exit(pid, :kill)
        Process.exit(governor.pid, :kill)
      end
    end
  end

  property "Governor.with/2 never runs more work at one time than the capacity" do
    check all(
            capacity <- integer(1..4),
            durations <- list_of(integer(0..5), min_length: 1, max_length: 20),
            max_runs: 30
          ) do
      governor = CountingGovernor.new(capacity)
      counter = :counters.new(2, [])

      work = fn duration ->
        Web.Governor.with(governor, fn ->
          :counters.add(counter, 1, 1)
          now = :counters.get(counter, 1)
          if now > :counters.get(counter, 2), do: :counters.put(counter, 2, now)
          Process.sleep(duration)
          :counters.sub(counter, 1, 1)
          duration
        end)
      end

      results = durations |> Enum.map(work) |> Promise.all() |> Promise.await()

      assert results == durations
      assert :counters.get(counter, 2) <= capacity
      assert :counters.get(counter, 1) == 0

      # The promise settles before the work releases its token.
      wait_until(fn -> :sys.get_state(governor.pid).in_use == 0 end)
      Process.exit(governor.pid, :kill)
    end
  end
end
