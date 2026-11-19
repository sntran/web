defmodule Web.AbortSignalLifetimeTest do
  # These tests set the linger time for the application and count the
  # processes of the VM. Thus they cannot run at the same time as other tests.
  use ExUnit.Case, async: false

  use Web

  alias Web.AbortSignal.Reasons

  @linger 100
  @count 200
  @tolerance 20

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

  defp assert_down(pid, timeout \\ 2_000) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, timeout
  end

  defp refute_down(pid, time) do
    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, time
    Process.demonitor(ref, [:flush])
  end

  defp in_short_process(fun) do
    parent = self()
    pid = spawn(fn -> send(parent, {:result, self(), fun.()}) end)
    assert_receive {:result, ^pid, result}
    assert_down(pid)
    result
  end

  defp process_count, do: :erlang.system_info(:process_count)

  defp settle(baseline, attempts \\ 150) do
    difference = process_count() - baseline

    if difference <= @tolerance or attempts == 0 do
      difference
    else
      Process.sleep(20)
      settle(baseline, attempts - 1)
    end
  end

  defp subscribers(signal), do: :sys.get_state(signal.pid).subscribers

  defp wait_for_no_subscribers(signal, attempts \\ 150) do
    current = subscribers(signal)

    if current == %{} or attempts == 0 do
      current
    else
      Process.sleep(20)
      wait_for_no_subscribers(signal, attempts - 1)
    end
  end

  describe "a signal that is not aborted" do
    test "stays while its owner is alive" do
      controller = AbortController.new()
      refute_down(controller.signal.pid, 4 * @linger)
    end

    test "stops after the linger time when its owner stops" do
      controller = in_short_process(fn -> AbortController.new() end)
      assert_down(controller.signal.pid)

      # A signal that stopped is the same as an aborted signal.
      assert AbortSignal.aborted?(controller.signal)
      assert AbortSignal.subscribe(controller.signal) == {:error, :aborted}
    end

    test "stays while a process is subscribed, and stops after the last one goes" do
      controller = in_short_process(fn -> AbortController.new() end)
      signal = controller.signal

      assert {:ok, subscription} = AbortSignal.subscribe(signal)
      refute_down(signal.pid, 4 * @linger)

      assert AbortSignal.unsubscribe(subscription) == :ok
      assert_down(signal.pid)
    end

    test "can abort after its owner stops, while a process is subscribed" do
      controller = in_short_process(fn -> AbortController.new() end)
      assert {:ok, subscription} = AbortSignal.subscribe(controller.signal)

      assert AbortController.abort(controller, :late_abort) == :ok

      assert AbortSignal.receive_abort(subscription, 1_000, true) ==
               {:error, :aborted, :late_abort}
    end

    test "with a timeout stops with no abort when its owner stops" do
      signal = in_short_process(fn -> AbortSignal.timeout(60_000) end)
      assert_down(signal.pid)
    end
  end

  describe "a subscription" do
    test "is removed by unsubscribe" do
      signal = AbortController.new().signal

      assert {:ok, first} = AbortSignal.subscribe(signal)
      assert {:ok, second} = AbortSignal.subscribe(signal)
      assert %{} = subscribers(signal)
      assert {_monitor, 2} = subscribers(signal)[self()]

      assert AbortSignal.unsubscribe(first) == :ok
      assert {_monitor, 1} = subscribers(signal)[self()]

      assert AbortSignal.unsubscribe(second) == :ok
      assert subscribers(signal) == %{}

      # One more unsubscribe has no effect.
      assert AbortSignal.unsubscribe(second) == :ok
      assert subscribers(signal) == %{}
    end

    test "is removed when the subscribed process stops" do
      signal = AbortController.new().signal

      in_short_process(fn -> AbortSignal.subscribe(signal) end)
      Process.sleep(20)
      assert subscribers(signal) == %{}
    end
  end

  describe "the reason of an aborted signal" do
    test "is available after the abort, and is removed after the linger time" do
      controller = AbortController.new()
      signal = controller.signal

      assert AbortController.abort(controller, :my_reason) == :ok
      assert_down(signal.pid)
      assert AbortSignal.reason(signal) == :my_reason

      # The store removes old reasons one time each second.
      Process.sleep(@linger + 1_300)
      assert %DOMException{name: "AbortError"} = AbortSignal.reason(signal)
    end

    test "stays when the linger time is :infinity" do
      Application.put_env(:web, :linger, :infinity)

      controller = AbortController.new()
      assert AbortController.abort(controller, :kept_reason) == :ok
      assert_down(controller.signal.pid)

      Process.sleep(1_300)
      assert AbortSignal.reason(controller.signal) == :kept_reason
    end

    test "a signal with no use stays for the handoff time when the linger time is :infinity" do
      Application.put_env(:web, :linger, :infinity)

      signal = in_short_process(fn -> AbortController.new().signal end)

      # The owner stopped, and no process is subscribed. The signal waits
      # for a process that got it in a message.
      refute_down(signal.pid, 300)
      assert {:ok, subscription} = AbortSignal.subscribe(signal)
      assert AbortSignal.unsubscribe(subscription) == :ok
      Process.exit(signal.pid, :kill)
    end

    test "is not kept, and gives no error, when the store of the reasons does not run" do
      # The application stops the store before the other processes.
      :ok = Supervisor.terminate_child(Web.Supervisor, Reasons)

      try do
        ref = make_ref()
        assert Reasons.put(ref, :not_kept) == :ok
        assert Reasons.get(ref) == nil
      after
        {:ok, _pid} = Supervisor.restart_child(Web.Supervisor, Reasons)
      end

      controller = AbortController.new()
      assert AbortController.abort(controller, :kept_again) == :ok
      assert_down(controller.signal.pid)
      assert AbortSignal.reason(controller.signal) == :kept_again
    end

    test "does not stay in persistent_term" do
      before = length(:persistent_term.get())

      for index <- 1..@count do
        controller = AbortController.new()
        assert AbortController.abort(controller, index) == :ok
      end

      assert length(:persistent_term.get()) == before
    end
  end

  describe "processes" do
    test "do not stay for signals whose owner stopped" do
      baseline = process_count()

      for _ <- 1..@count do
        in_short_process(fn -> AbortController.new() end)
        in_short_process(fn -> AbortSignal.timeout(60_000) end)
      end

      assert settle(baseline) <= @tolerance
    end

    test "do not stay for AbortSignal.any/1 when the owner stopped" do
      baseline = process_count()

      for _ <- 1..div(@count, 4) do
        in_short_process(fn ->
          first = AbortController.new().signal
          second = AbortSignal.timeout(60_000)
          AbortSignal.any([first, second])
        end)
      end

      assert settle(baseline) <= @tolerance
    end

    test "do not stay for streams that have an ambient signal" do
      controller = AbortController.new()
      baseline = process_count()

      for _ <- 1..@count do
        stream =
          AsyncContext.with_signal(controller.signal, fn -> ReadableStream.from(["a", "b"]) end)

        assert Enum.to_list(stream) == ["a", "b"]
      end

      assert settle(baseline) <= @tolerance

      # The count of processes has a tolerance, thus some streams can be in
      # their last step at this time. The signal removes each stream that
      # stops.
      assert wait_for_no_subscribers(controller.signal) == %{}
    end
  end
end
