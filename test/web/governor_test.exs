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

  describe "the life of a governor from new/1" do
    @linger 60

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

    # Makes a governor in a process, and returns after that process stopped.
    defp governor_of_stopped_owner(capacity, exit_reason \\ :normal) do
      parent = self()

      {owner, monitor} =
        spawn_monitor(fn ->
          send(parent, {:governor, CountingGovernor.new(capacity)})
          if exit_reason != :normal, do: exit(exit_reason)
        end)

      assert_receive {:governor, governor}, 500
      assert_receive {:DOWN, ^monitor, :process, ^owner, _reason}, 500
      governor
    end

    defp assert_stops(governor, timeout \\ 1_000) do
      monitor = Process.monitor(governor.pid)
      # The reason is `:noproc` if the governor stopped before this monitor.
      assert_receive {:DOWN, ^monitor, :process, _pid, reason}, timeout
      assert reason in [:normal, :noproc]
    end

    defp refute_stops(governor, time) do
      monitor = Process.monitor(governor.pid)
      refute_receive {:DOWN, ^monitor, :process, _pid, _reason}, time
      Process.demonitor(monitor, [:flush])
    end

    test "stays while its owner is alive" do
      governor = CountingGovernor.new(1)
      refute_stops(governor, 4 * @linger)

      token = await(Governor.acquire(governor))
      assert :ok = Token.release(token)
      refute_stops(governor, 4 * @linger)
    end

    test "stops after the linger time when its owner stopped and it has no use" do
      governor = governor_of_stopped_owner(1)
      assert Process.alive?(governor.pid)
      assert_stops(governor)
    end

    test "stops with no linger time when its owner stopped with a failure" do
      Application.put_env(:web, :linger, 60_000)
      governor = governor_of_stopped_owner(1, :failure)
      assert_stops(governor, 500)
    end

    test "can be used by a different process in the linger time" do
      governor = governor_of_stopped_owner(1)

      token = await(Governor.acquire(governor))
      assert %Token{} = token

      # A token in use keeps the governor.
      refute_stops(governor, 4 * @linger)

      assert :ok = Token.release(token)
      assert_stops(governor)
    end

    test "stays while an acquisition waits" do
      governor = governor_of_stopped_owner(0)
      waiting = Governor.acquire(governor)

      refute_stops(governor, 4 * @linger)
      assert Promise.peek(waiting) == :pending
    end

    test "starts the linger time again for each message" do
      governor = governor_of_stopped_owner(1)

      for _ <- 1..6 do
        Process.sleep(div(@linger, 2))
        token = await(Governor.acquire(governor))
        assert :ok = Token.release(token)
      end

      assert Process.alive?(governor.pid)
      assert_stops(governor)
    end

    test "stops after its owner stopped when its last token comes back from a stopped holder" do
      governor = governor_of_stopped_owner(1)

      {holder, monitor} = spawn_monitor(fn -> await(Governor.acquire(governor)) end)
      assert_receive {:DOWN, ^monitor, :process, ^holder, _reason}, 500
      assert_stops(governor)
    end

    test "rejects an acquisition after it stopped" do
      governor = governor_of_stopped_owner(1)
      assert_stops(governor)

      assert %Web.TypeError{message: message} = catch_exit(await(Governor.acquire(governor)))
      assert message =~ "The governor is not available"
    end

    test "uses the handoff time when the linger time is :infinity" do
      Application.put_env(:web, :linger, :infinity)
      governor = governor_of_stopped_owner(1)

      assert {:noreply, _state, 5_000} =
               CountingGovernor.handle_cast({:release, make_ref()}, governor_state(governor))
    end
  end

  describe "a governor from start_link/1" do
    test "has no owner and does not stop" do
      Application.put_env(:web, :linger, 20)
      on_exit(fn -> Application.delete_env(:web, :linger) end)
      parent = self()

      # The process that starts the governor traps exits, as a supervisor.
      starter =
        spawn(fn ->
          Process.flag(:trap_exit, true)
          {:ok, pid} = CountingGovernor.start_link(capacity: 2)
          send(parent, {:started, pid})
          Process.sleep(:infinity)
        end)

      assert_receive {:started, pid}
      governor = CountingGovernor.get(pid)
      assert governor == %CountingGovernor{pid: pid, capacity: 2}

      token = await(Governor.acquire(governor))
      assert :ok = Token.release(token)
      Process.sleep(100)
      assert Process.alive?(pid)

      Process.exit(starter, :kill)
    end

    test "can have a name and a place in a supervision tree" do
      name = :"governor_#{System.unique_integer([:positive])}"

      # The supervisor of the test has the governor as its child.
      start_supervised!({CountingGovernor, capacity: 1, name: name})

      governor = CountingGovernor.get(name)
      assert governor == %CountingGovernor{pid: name, capacity: 1}

      assert await(Governor.with(governor, fn -> :work end)) == :work

      # A waiter gets its token after a release, also with a name.
      token = await(Governor.acquire(governor))
      waiting = Governor.acquire(governor)
      eventually(fn -> queue_length(governor) == 1 end)
      assert :ok = Token.release(token)
      assert %Token{} = second = await(waiting)
      assert :ok = Token.release(second)

      # The supervisor starts the governor again after a failure.
      first_pid = Process.whereis(name)
      Process.exit(first_pid, :kill)
      eventually(fn -> is_pid(Process.whereis(name)) and Process.whereis(name) != first_pid end)
      assert await(Governor.with(governor, fn -> :again end)) == :again
    end

    test "validates its options" do
      assert_raise KeyError, fn -> CountingGovernor.start_link(name: :no_capacity) end
      assert_raise ArgumentError, fn -> CountingGovernor.start_link(capacity: -1) end
    end

    test "ignores a message that is not for it" do
      {:ok, pid} = CountingGovernor.start(capacity: 1)
      before = :sys.get_state(pid)
      send(pid, :not_for_the_governor)
      assert :sys.get_state(pid) == before
      Process.exit(pid, :kill)
    end
  end

  describe "a governor from start/1" do
    test "has no owner and no link, and stays after the process that started it" do
      Application.put_env(:web, :linger, 20)
      on_exit(fn -> Application.delete_env(:web, :linger) end)
      parent = self()

      {starter, monitor} =
        spawn_monitor(fn ->
          {:ok, pid} = CountingGovernor.start(capacity: 3)
          send(parent, {:started, pid})
          exit(:failure)
        end)

      assert_receive {:started, pid}
      assert_receive {:DOWN, ^monitor, :process, ^starter, :failure}

      Process.sleep(100)
      assert Process.alive?(pid)
      governor = CountingGovernor.get(pid)
      assert governor.capacity == 3
      assert await(Governor.with(governor, fn -> :work end)) == :work
      Process.exit(pid, :kill)
    end
  end

  # A process that acquires one token, gives it to the test, and stays alive.
  # The token belongs to this process, thus the process must not stop before
  # the release.
  defp start_holder(governor, label) do
    parent = self()

    spawn_link(fn ->
      token = await(Governor.acquire(governor))
      send(parent, {:acquired, label, token})

      receive do
        :stop -> :ok
      end
    end)
  end

  test "queued acquisitions are granted in FIFO order" do
    governor = CountingGovernor.new(1)
    token = await(Governor.acquire(governor))

    _second = start_holder(governor, :second)
    eventually(fn -> queue_length(governor) == 1 end)
    _third = start_holder(governor, :third)
    eventually(fn -> queue_length(governor) == 2 end)

    assert governor_state(governor).in_use == 1
    assert :ok = Token.release(token)

    assert_receive {:acquired, :second, second_token}, 500
    refute_receive {:acquired, :third, _token}, 50

    assert :ok = Token.release(second_token)
    assert_receive {:acquired, :third, third_token}, 500
    assert :ok = Token.release(third_token)
  end

  test "release/1 is idempotent and wakes exactly one waiter" do
    governor = CountingGovernor.new(1)
    token = await(Governor.acquire(governor))

    for index <- 1..2, do: start_holder(governor, index)
    eventually(fn -> queue_length(governor) == 2 end)

    assert :ok = Token.release(token)
    assert :ok = Token.release(token)

    assert_receive {:acquired, first_index, first}, 500
    assert first_index in [1, 2]
    refute_receive {:acquired, _index, _token}, 50
    assert governor_state(governor).in_use == 1

    assert :ok = Token.release(first)
    assert_receive {:acquired, second_index, second}, 500
    assert second_index in [1, 2]
    assert second_index != first_index

    assert :ok = Token.release(second)
    eventually(fn -> governor_state(governor).in_use == 0 end)
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

    assert %Web.DOMException{name: "AbortError"} =
             catch_exit(await(acquisition.promise))

    assert map_size(governor_state(governor).waiting) == 0
    assert :queue.is_empty(governor_state(governor).queue)

    assert :ok = Token.release(token)
  end

  test "Governor.with/2 rejects when acquisition fails" do
    governor = CountingGovernor.new(1)
    Process.unlink(governor.pid)
    Process.exit(governor.pid, :kill)
    Process.sleep(10)

    assert %Web.TypeError{message: message} =
             catch_exit(await(Governor.with(governor, fn -> :ok end)))

    assert message =~ "The governor is not available"
  end

  test "Governor.with/2 gives the rejection of a promise that the callback returns" do
    governor = CountingGovernor.new(1)

    assert :callback_rejected ==
             catch_exit(
               await(
                 Governor.with(governor, fn ->
                   Promise.new(fn _resolve, reject -> reject.(:callback_rejected) end)
                 end)
               )
             )

    assert :settled_rejection ==
             catch_exit(
               await(Governor.with(governor, fn -> Promise.reject(:settled_rejection) end))
             )

    eventually(fn -> governor_state(governor).in_use == 0 end)
  end

  test "Governor.with/2 limits pending promises to the capacity" do
    governor = CountingGovernor.new(2)
    counter = :counters.new(2, [])

    work = fn ->
      Promise.new(fn resolve, _reject ->
        :counters.add(counter, 1, 1)
        active = :counters.get(counter, 1)
        if active > :counters.get(counter, 2), do: :counters.put(counter, 2, active)
        Process.sleep(20)
        :counters.sub(counter, 1, 1)
        resolve.(active)
      end)
    end

    promises = for _ <- 1..8, do: Governor.with(governor, work)
    results = await(Promise.all(promises))

    assert length(results) == 8
    assert :counters.get(counter, 2) == 2
    eventually(fn -> governor_state(governor).in_use == 0 end)
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

  # The message that the process of an acquisition sends to the governor.
  defp acquire_message(waiter_ref, flag \\ :atomics.new(1, signed: false)) do
    {:acquire, self(), waiter_ref, self(), flag}
  end

  defp empty_state do
    %{
      owner: nil,
      linger: nil,
      capacity: 1,
      in_use: 0,
      queue: :queue.new(),
      active_tokens: %{},
      holder_monitors: %{},
      waiting: %{},
      waiter_monitors: %{}
    }
  end

  test "dead waiting processes are cleaned up before the next grant" do
    governor = CountingGovernor.new(1)
    token = await(Governor.acquire(governor))

    waiter =
      spawn(fn ->
        GenServer.cast(governor.pid, acquire_message(make_ref()))
        Process.sleep(:infinity)
      end)

    eventually(fn -> map_size(governor_state(governor).waiting) == 1 end)

    Process.exit(waiter, :kill)
    eventually(fn -> map_size(governor_state(governor).waiting) == 0 end)
    assert queue_length(governor) == 0

    assert :ok = Token.release(token)
    eventually(fn -> governor_state(governor).in_use == 0 end)
  end

  test "internal no-op paths tolerate unrelated signals and stale queue entries" do
    governor = CountingGovernor.new(1)
    token = await(Governor.acquire(governor))
    stale_waiter_ref = make_ref()

    GenServer.cast(governor.pid, acquire_message(stale_waiter_ref))

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

  test "an acquisition that was aborted before it came to the governor is rejected" do
    waiter_ref = make_ref()
    flag = :atomics.new(1, signed: false)
    :atomics.put(flag, 1, 1)

    assert {:noreply, next_state} =
             CountingGovernor.handle_cast(acquire_message(waiter_ref, flag), empty_state())

    assert_receive {:governor_rejected, ^waiter_ref, %Web.DOMException{name: "AbortError"}}
    assert next_state == empty_state()
  end

  test "an abort, a release, and a DOWN message that are not known do not change the state" do
    state = empty_state()

    assert {:noreply, ^state} = CountingGovernor.handle_cast({:abort_waiter, make_ref()}, state)
    assert {:noreply, ^state} = CountingGovernor.handle_cast({:release, make_ref()}, state)

    assert {:noreply, ^state} =
             CountingGovernor.handle_info({:DOWN, make_ref(), :process, self(), :normal}, state)
  end

  test "an abort of a registered waiter removes it and rejects its acquisition" do
    waiter_ref = make_ref()
    monitor_ref = Process.monitor(self())

    try do
      waiter = %{waiter_ref: waiter_ref, pid: self(), holder: self(), monitor_ref: monitor_ref}

      state = %{
        empty_state()
        | in_use: 1,
          queue: :queue.from_list([waiter_ref]),
          waiting: %{waiter_ref => waiter},
          waiter_monitors: %{monitor_ref => waiter_ref}
      }

      assert {:noreply, next_state} =
               CountingGovernor.handle_cast({:abort_waiter, waiter_ref}, state)

      assert_receive {:governor_rejected, ^waiter_ref, %Web.DOMException{name: "AbortError"}}
      refute Map.has_key?(next_state.waiting, waiter_ref)
      refute Map.has_key?(next_state.waiter_monitors, monitor_ref)
      assert :queue.is_empty(next_state.queue)
    after
      Process.demonitor(monitor_ref, [:flush])
    end
  end

  test "an abort after the grant keeps no data in the governor" do
    governor = CountingGovernor.new(1)
    before = governor_state(governor)

    for _ <- 1..50 do
      acquisition = AbortableGovernor.acquire_abortable(governor)
      token = await(acquisition.promise)
      assert :ok = acquisition.abort.()
      assert :ok = Token.release(token)
    end

    eventually(fn -> governor_state(governor) == before end)
  end

  test "release and abort are harmless after the governor process stops" do
    governor = CountingGovernor.new(1)
    token = await(Governor.acquire(governor))

    Process.exit(governor.pid, :kill)
    Process.sleep(10)

    acquisition = AbortableGovernor.acquire_abortable(governor)

    assert :ok = Token.release(token)
    assert :ok = acquisition.abort.()
    assert %Web.TypeError{} = catch_exit(await(acquisition.promise))
  end

  test "acquire/1 rejects when the governor process is gone" do
    governor = CountingGovernor.new(1)
    Process.exit(governor.pid, :kill)
    Process.sleep(10)

    assert %Web.TypeError{message: message} = catch_exit(await(Governor.acquire(governor)))
    assert message =~ "The governor is not available"
  end

  test "acquire/1 rejects when the governor process stops during the wait" do
    governor = CountingGovernor.new(1)
    _token = await(Governor.acquire(governor))

    waiting = Governor.acquire(governor)
    eventually(fn -> queue_length(governor) == 1 end)
    Process.exit(governor.pid, :kill)

    assert %Web.TypeError{} = catch_exit(await(waiting))
  end

  describe "the holder of a token" do
    # Runs `fun` in a process, and returns after that process stopped.
    defp in_stopped_process(fun, exit_reason \\ :normal) do
      {pid, monitor} =
        spawn_monitor(fn ->
          fun.()
          if exit_reason != :normal, do: exit(exit_reason)
        end)

      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
    end

    test "is the process that acquired it: the token comes back when the process stops" do
      for exit_reason <- [:normal, :failure, :kill] do
        governor = CountingGovernor.new(1)
        in_stopped_process(fn -> await(Governor.acquire(governor)) end, exit_reason)

        eventually(fn -> governor_state(governor).in_use == 0 end)
        assert governor_state(governor).active_tokens == %{}
        assert governor_state(governor).holder_monitors == %{}

        # The capacity is not lost.
        assert %Token{} = token = await(Governor.acquire(governor))
        assert :ok = Token.release(token)
      end
    end

    test "gives its token to the next waiter when it stops" do
      governor = CountingGovernor.new(1)
      first = start_holder(governor, :first)
      assert_receive {:acquired, :first, _token}, 500

      _second = start_holder(governor, :second)
      eventually(fn -> queue_length(governor) == 1 end)

      Process.unlink(first)
      Process.exit(first, :kill)
      assert_receive {:acquired, :second, token}, 500
      assert governor_state(governor).in_use == 1
      assert :ok = Token.release(token)
    end

    test "is not the process of a promise: the token stays after that process stopped" do
      governor = CountingGovernor.new(1)

      # The acquisition runs in the process of the promise. The owner of that
      # process is the test process.
      promise =
        Promise.new(fn resolve, _reject -> resolve.(await(Governor.acquire(governor))) end)

      token = await(promise)
      Process.sleep(50)
      assert governor_state(governor).in_use == 1

      assert :ok = Token.release(token)
      eventually(fn -> governor_state(governor).in_use == 0 end)
    end

    test "can release a token after the governor took it back, with no effect" do
      governor = CountingGovernor.new(2)
      parent = self()

      in_stopped_process(fn -> send(parent, {:token, await(Governor.acquire(governor))}) end)
      assert_receive {:token, stale}
      eventually(fn -> governor_state(governor).in_use == 0 end)

      current = await(Governor.acquire(governor))
      assert :ok = Token.release(stale)
      Process.sleep(20)
      assert governor_state(governor).in_use == 1
      assert :ok = Token.release(current)
    end

    test "of Governor.with/2 is the owner: the token comes back when the owner stops" do
      governor = CountingGovernor.new(1)
      parent = self()

      in_stopped_process(fn ->
        Governor.with(governor, fn ->
          send(parent, {:work, self()})
          Promise.new(fn _resolve, _reject -> Process.sleep(:infinity) end)
        end)

        receive do
          :never -> :ok
        after
          50 -> :ok
        end
      end)

      # The work stopped with its owner, and the governor has its capacity.
      assert_receive {:work, work}
      eventually(fn -> not Process.alive?(work) end)
      eventually(fn -> governor_state(governor).in_use == 0 end)
      assert await(Governor.with(governor, fn -> :next end)) == :next
    end

    test "of Governor.with/2 keeps the token for the full time of the work" do
      governor = CountingGovernor.new(1)

      slow =
        Governor.with(governor, fn ->
          Promise.new(fn resolve, _reject ->
            Process.sleep(100)
            resolve.(:slow)
          end)
        end)

      eventually(fn -> governor_state(governor).in_use == 1 end)
      Process.sleep(50)
      assert governor_state(governor).in_use == 1
      assert await(slow) == :slow
      eventually(fn -> governor_state(governor).in_use == 0 end)
    end
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
