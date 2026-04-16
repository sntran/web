defmodule Web.GovernorTest do
  use ExUnit.Case, async: false

  import Web, only: [await: 1]

  alias Web.AbortableGovernor
  alias Web.AsyncContext.Variable
  alias Web.CountingGovernor
  alias Web.Governor
  alias Web.Governor.Token
  alias Web.Promise

  defmodule TrackingDispatcher do
    @behaviour Web.Dispatcher

    def fetch(%Web.Request{} = request) do
      tracker = Keyword.fetch!(request.options, :tracker)
      test_pid = Keyword.fetch!(request.options, :test_pid)
      label = Keyword.fetch!(request.options, :label)

      current =
        Agent.get_and_update(tracker, fn %{current: current, max: max} = state ->
          next = current + 1
          {next, %{state | current: next, max: Kernel.max(max, next)}}
        end)

      send(test_pid, {:dispatcher_started, label, current})
      Process.sleep(40)

      Agent.update(tracker, fn %{current: current} = state ->
        %{state | current: max(current - 1, 0)}
      end)

      send(test_pid, {:dispatcher_finished, label})

      {:ok, Web.Response.new(status: 200, body: ["ok"], url: Web.URL.href(request.url))}
    end
  end

  test "new/1 validates capacity" do
    assert_raise ArgumentError, ~r/non-negative integer/, fn ->
      CountingGovernor.new(-1)
    end

    assert_raise ArgumentError, ~r/non-negative integer/, fn ->
      CountingGovernor.new("2")
    end
  end

  test "acquire/1 resolves immediately under capacity" do
    governor = CountingGovernor.new(1)
    token = await(Governor.acquire(governor))

    assert %Token{} = token
    assert token.governor == governor
    assert governor_state(governor).in_use == 1

    assert :ok = Token.release(token)
    eventually(fn -> governor_state(governor).in_use == 0 end)
  end

  test "governors remain alive after the creating process exits" do
    parent = self()

    creator =
      spawn(fn ->
        send(parent, {:created_governor, CountingGovernor.new(1)})
      end)

    assert_receive {:created_governor, governor}, 500
    creator_ref = Process.monitor(creator)

    assert_receive {:DOWN, ^creator_ref, :process, ^creator, reason}, 500
    assert reason in [:normal, :noproc]

    token = await(Governor.acquire(governor))
    assert %Token{} = token

    assert :ok = Token.release(token)
    eventually(fn -> governor_state(governor).in_use == 0 end)
  end

  test "queued acquisitions are granted in FIFO order" do
    governor = CountingGovernor.new(1)
    token = await(Governor.acquire(governor))
    parent = self()

    second =
      Task.async(fn ->
        second_token = await(Governor.acquire(governor))
        send(parent, {:acquired, :second})
        second_token
      end)

    eventually(fn -> queue_length(governor) == 1 end)

    third =
      Task.async(fn ->
        third_token = await(Governor.acquire(governor))
        send(parent, {:acquired, :third})
        third_token
      end)

    Process.sleep(20)
    assert governor_state(governor).in_use == 1

    assert :ok = Token.release(token)

    assert_receive {:acquired, :second}, 500
    refute_receive {:acquired, :third}, 50

    second_token = Task.await(second, 500)
    assert :ok = Token.release(second_token)

    assert_receive {:acquired, :third}, 500
    third_token = Task.await(third, 500)
    assert :ok = Token.release(third_token)
  end

  test "release/1 is idempotent and wakes exactly one waiter" do
    governor = CountingGovernor.new(1)
    token = await(Governor.acquire(governor))
    parent = self()

    queued =
      Enum.map(1..2, fn index ->
        Task.async(fn ->
          acquired = await(Governor.acquire(governor))
          send(parent, {:queued_token, index, acquired})
          acquired
        end)
      end)

    Process.sleep(20)
    assert :ok = Token.release(token)
    assert :ok = Token.release(token)

    assert_receive {:queued_token, first_index, first}, 500
    assert first_index in [1, 2]
    Process.sleep(20)
    assert governor_state(governor).in_use == 1

    assert :ok = Token.release(first)
    assert_receive {:queued_token, second_index, second}, 500
    assert second_index in [1, 2]
    assert second_index != first_index

    assert :ok = Token.release(second)
    Enum.each(queued, &Task.await(&1, 500))
  end

  test "Governor.with/2 releases the token on success" do
    governor = CountingGovernor.new(1)

    assert :ok = await(Governor.with(governor, fn -> :ok end))
    eventually(fn -> governor_state(governor).in_use == 0 end)
  end

  test "Governor.with/2 adopts nested promises and releases on rejection" do
    governor = CountingGovernor.new(1)

    assert :boom == catch_exit(await(Governor.with(governor, fn -> Promise.reject(:boom) end)))
    eventually(fn -> governor_state(governor).in_use == 0 end)
  end

  test "Governor.with/2 releases on exception" do
    governor = CountingGovernor.new(1)
    result = catch_exit(await(Governor.with(governor, fn -> raise "broken" end)))

    assert %RuntimeError{message: "broken"} = result
    eventually(fn -> governor_state(governor).in_use == 0 end)
  end

  test "Governor.with/2 may receive the acquired token" do
    governor = CountingGovernor.new(1)

    token_ref =
      governor
      |> Governor.with(fn token -> token.ref end)
      |> await()

    assert is_reference(token_ref)
  end

  test "Governor.wrap/2 forwards arguments and returns a promise" do
    governor = CountingGovernor.new(1)
    wrapped = Governor.wrap(governor, fn a, b -> a + b end)

    promise = wrapped.(2, 3)
    assert %Promise{} = promise
    assert 5 == await(promise)
  end

  test "Governor.wrap/2 supports arities 0 and 3 through 8" do
    governor = CountingGovernor.new(1)

    assert :zero == governor |> Governor.wrap(fn -> :zero end) |> apply_fun(& &1.()) |> await()

    assert 6 ==
             governor
             |> Governor.wrap(fn a, b, c -> a + b + c end)
             |> apply_fun(& &1.(1, 2, 3))
             |> await()

    assert 10 ==
             governor
             |> Governor.wrap(fn a, b, c, d -> a + b + c + d end)
             |> apply_fun(& &1.(1, 2, 3, 4))
             |> await()

    assert 15 ==
             governor
             |> Governor.wrap(fn a, b, c, d, e -> a + b + c + d + e end)
             |> apply_fun(& &1.(1, 2, 3, 4, 5))
             |> await()

    assert 21 ==
             governor
             |> Governor.wrap(fn a, b, c, d, e, f -> a + b + c + d + e + f end)
             |> apply_fun(& &1.(1, 2, 3, 4, 5, 6))
             |> await()

    assert 28 ==
             governor
             |> Governor.wrap(fn a, b, c, d, e, f, g -> a + b + c + d + e + f + g end)
             |> apply_fun(& &1.(1, 2, 3, 4, 5, 6, 7))
             |> await()

    assert 36 ==
             governor
             |> Governor.wrap(fn a, b, c, d, e, f, g, h -> a + b + c + d + e + f + g + h end)
             |> apply_fun(& &1.(1, 2, 3, 4, 5, 6, 7, 8))
             |> await()
  end

  test "Governor.wrap/2 supports arity 1" do
    governor = CountingGovernor.new(1)
    wrapped = Governor.wrap(governor, fn value -> value * 2 end)

    assert 8 == wrapped.(4) |> await()
  end

  test "Governor.wrap/2 rejects unsupported arities" do
    long_fun = fn _a, _b, _c, _d, _e, _f, _g, _h, _i -> :ok end

    assert_raise ArgumentError, ~r/arities 0..8/, fn ->
      Governor.wrap(CountingGovernor.new(1), long_fun)
    end
  end

  test "acquire_abortable/1 rejects when aborted before grant and removes the waiter" do
    governor = CountingGovernor.new(1)
    token = await(Governor.acquire(governor))

    acquisition = AbortableGovernor.acquire_abortable(governor)
    assert :ok = acquisition.abort.()
    assert :aborted == catch_exit(await(acquisition.promise))

    assert map_size(governor_state(governor).waiting) == 0
    assert :queue.is_empty(governor_state(governor).queue)

    assert :ok = Token.release(token)
  end

  test "Governor.with/2 rejects when acquisition fails" do
    governor = CountingGovernor.new(1)
    Process.unlink(governor.pid)
    Process.exit(governor.pid, :kill)
    Process.sleep(10)

    assert :closed == catch_exit(await(Governor.with(governor, fn -> :ok end)))
  end

  test "Governor.with/2 propagates task exits returned as promise tasks" do
    governor = CountingGovernor.new(1)

    assert :task_shutdown ==
             catch_exit(
               await(
                 Governor.with(governor, fn ->
                   %Promise{
                     task:
                       Task.Supervisor.async_nolink(Web.TaskSupervisor, fn ->
                         exit({:shutdown, :task_shutdown})
                       end)
                   }
                 end)
               )
             )

    assert {:task_exit, {Task, :await, _}} =
             catch_exit(
               await(
                 Governor.with(governor, fn ->
                   %Promise{
                     task:
                       Task.Supervisor.async_nolink(Web.TaskSupervisor, fn ->
                         exit(:task_exit)
                       end)
                   }
                 end)
               )
             )
  end

  test "acquire_abortable/1 is best-effort after grant" do
    governor = CountingGovernor.new(1)
    acquisition = AbortableGovernor.acquire_abortable(governor)
    token = await(acquisition.promise)

    assert :ok = acquisition.abort.()
    assert governor_state(governor).in_use == 1

    assert :ok = Token.release(token)
    eventually(fn -> governor_state(governor).in_use == 0 end)
  end

  test "queued work preserves async context values" do
    governor = CountingGovernor.new(1)
    token = await(Governor.acquire(governor))

    task =
      Task.async(fn ->
        request_id = Variable.new("request_id")

        Variable.run(request_id, "req-42", fn ->
          await(Governor.with(governor, fn -> Variable.get(request_id) end))
        end)
      end)

    Process.sleep(20)
    assert :ok = Token.release(token)
    assert Task.await(task, 500) == "req-42"
  end

  test "dead waiting processes are cleaned up before the next grant" do
    governor = CountingGovernor.new(1)
    token = await(Governor.acquire(governor))

    waiter =
      spawn(fn ->
        :ok = GenServer.call(governor.pid, {:acquire, self(), make_ref()}, :infinity)
        Process.sleep(:infinity)
      end)

    Process.sleep(20)
    assert map_size(governor_state(governor).waiting) == 1

    Process.exit(waiter, :kill)
    eventually(fn -> map_size(governor_state(governor).waiting) == 0 end)

    assert :ok = Token.release(token)
    eventually(fn -> governor_state(governor).in_use == 0 end)
  end

  test "internal no-op paths tolerate unrelated signals and stale queue entries" do
    governor = CountingGovernor.new(1)
    token = await(Governor.acquire(governor))
    stale_waiter_ref = make_ref()

    :ok = GenServer.call(governor.pid, {:acquire, self(), stale_waiter_ref}, :infinity)

    eventually(fn -> queue_length(governor) == 1 end)
    send(governor.pid, {:DOWN, make_ref(), :process, self(), :normal})
    Process.sleep(10)

    :sys.replace_state(governor.pid, fn state ->
      %{state | waiting: Map.delete(state.waiting, stale_waiter_ref)}
    end)

    GenServer.cast(governor.pid, {:abort_waiter, make_ref()})
    assert :ok = Token.release(token)
    Process.sleep(10)
    assert queue_length(governor) == 0
  end

  test "callback branches handle pre-canceled waiters directly" do
    waiter_ref = make_ref()

    state = %{
      capacity: 1,
      in_use: 0,
      queue: :queue.new(),
      active_tokens: %{},
      waiting: %{},
      canceled_waiters: MapSet.new([waiter_ref]),
      waiter_monitors: %{}
    }

    assert {:reply, :ok, next_state} =
             CountingGovernor.handle_call({:acquire, self(), waiter_ref}, self(), state)

    assert_receive {:governor_rejected, ^waiter_ref, :aborted}
    refute MapSet.member?(next_state.canceled_waiters, waiter_ref)
  end

  test "callback branches keep state stable for unknown abort/release/down signals" do
    state = %{
      capacity: 1,
      in_use: 0,
      queue: :queue.new(),
      active_tokens: %{},
      waiting: %{},
      canceled_waiters: MapSet.new(),
      waiter_monitors: %{}
    }

    unknown_waiter_ref = make_ref()
    unknown_token_ref = make_ref()
    unknown_monitor_ref = make_ref()

    assert {:noreply, abort_state} =
             CountingGovernor.handle_cast({:abort_waiter, unknown_waiter_ref}, state)

    assert MapSet.member?(abort_state.canceled_waiters, unknown_waiter_ref)

    assert {:noreply, ^abort_state} =
             CountingGovernor.handle_cast({:release, unknown_token_ref}, abort_state)

    assert {:noreply, down_state} =
             CountingGovernor.handle_info(
               {:DOWN, unknown_monitor_ref, :process, self(), :normal},
               abort_state
             )

    assert down_state.waiter_monitors == %{}
  end

  test "callback branches abort registered waiters directly" do
    waiter_ref = make_ref()
    monitor_ref = Process.monitor(self())

    try do
      state = %{
        capacity: 1,
        in_use: 1,
        queue: :queue.from_list([waiter_ref]),
        active_tokens: %{},
        waiting: %{waiter_ref => %{waiter_ref: waiter_ref, pid: self(), monitor_ref: monitor_ref}},
        canceled_waiters: MapSet.new(),
        waiter_monitors: %{monitor_ref => waiter_ref}
      }

      assert {:noreply, next_state} =
               CountingGovernor.handle_cast({:abort_waiter, waiter_ref}, state)

      assert_receive {:governor_rejected, ^waiter_ref, :aborted}
      refute Map.has_key?(next_state.waiting, waiter_ref)
      refute Map.has_key?(next_state.waiter_monitors, monitor_ref)
      assert :queue.is_empty(next_state.queue)
    after
      Process.demonitor(monitor_ref, [:flush])
    end
  end

  test "pre-aborted waiter refs are rejected on acquisition" do
    governor = CountingGovernor.new(1)
    waiter_ref = make_ref()

    GenServer.cast(governor.pid, {:abort_waiter, waiter_ref})
    eventually(fn -> MapSet.member?(governor_state(governor).canceled_waiters, waiter_ref) end)
    :ok = GenServer.call(governor.pid, {:acquire, self(), waiter_ref}, :infinity)

    assert_receive {:governor_rejected, ^waiter_ref, :aborted}, 200
    assert map_size(governor_state(governor).waiting) == 0
  end

  test "release and abort are harmless after the governor process stops" do
    governor = CountingGovernor.new(1)
    token = await(Governor.acquire(governor))

    Process.unlink(governor.pid)
    Process.exit(governor.pid, :kill)
    Process.sleep(10)

    acquisition = AbortableGovernor.acquire_abortable(governor)

    assert :ok = Token.release(token)
    assert :ok = acquisition.abort.()
    assert :closed == catch_exit(await(acquisition.promise))
  end

  test "acquire/1 rejects when the governor process is gone" do
    governor = CountingGovernor.new(1)
    Process.unlink(governor.pid)
    Process.exit(governor.pid, :kill)
    Process.sleep(10)

    assert :closed == catch_exit(await(Governor.acquire(governor)))
  end

  test "governor-limited fetch usage caps concurrent dispatcher work" do
    {:ok, tracker} = Agent.start_link(fn -> %{current: 0, max: 0} end)
    governor = CountingGovernor.new(2)
    parent = self()

    requests =
      for label <- 1..5 do
        Governor.with(governor, fn ->
          Web.fetch("mock://#{label}",
            dispatcher: TrackingDispatcher,
            tracker: tracker,
            test_pid: parent,
            label: label
          )
        end)
      end

    responses = await(Promise.all(requests))

    assert length(responses) == 5
    assert Enum.all?(responses, &match?(%Web.Response{status: 200}, &1))
    assert Agent.get(tracker, & &1.max) == 2
  end

  defp governor_state(governor) do
    :sys.get_state(governor.pid)
  end

  defp queue_length(governor) do
    governor
    |> governor_state()
    |> Map.fetch!(:queue)
    |> :queue.len()
  end

  defp apply_fun(value, fun), do: fun.(value)

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, 0) do
    assert fun.()
  end

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
