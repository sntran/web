defmodule Web.AbortSignalTest do
  use ExUnit.Case, async: true

  test "child_spec exposes the signal starter" do
    assert %{start: {Web.AbortSignal, :start_link, []}} = Web.AbortSignal.child_spec(nil)
  end

  test "token subscriptions handle abort messages and idle checks" do
    assert :ok = Web.AbortSignal.receive_abort(%{type: :token, token: :token}, 0, true)

    send(self(), {:abort, :token, :boom})

    assert {:error, :aborted, :boom} =
             Web.AbortSignal.receive_abort(%{type: :token, token: :token}, 0, true)
  end

  test "pid subscriptions handle direct abort messages" do
    {:ok, subscription} = Web.AbortSignal.subscribe(self())

    send(self(), {:abort, self(), :boom})
    assert {:error, :aborted, :boom} = Web.AbortSignal.receive_abort(subscription, 0, true)

    assert :ok = Web.AbortSignal.unsubscribe(subscription)
  end

  test "receive_abort/3 preserves reasons for abort signal subscriptions" do
    controller = Web.AbortController.new()
    {:ok, subscription} = Web.AbortSignal.subscribe(controller.signal)

    assert :ok = Web.AbortController.abort(controller, :boom)
    assert {:error, :aborted, :boom} = Web.AbortSignal.receive_abort(subscription, 100, true)
    assert {:error, :aborted, :boom} = Web.AbortSignal.receive_abort(subscription, 100, true)
    assert :ok = Web.AbortSignal.unsubscribe(subscription)
  end

  test "receive_abort/3 preserves reasons for pid and token subscriptions" do
    {:ok, pid_subscription} = Web.AbortSignal.subscribe(self())
    send(self(), {:abort, self(), :pid_abort})

    assert {:error, :aborted, :pid_abort} =
             Web.AbortSignal.receive_abort(pid_subscription, 0, true)

    assert :ok = Web.AbortSignal.unsubscribe(pid_subscription)

    token_subscription = %{type: :token, token: :token}
    send(self(), {:abort, :token})

    assert {:error, :aborted, %Web.DOMException{name: "AbortError"}} =
             Web.AbortSignal.receive_abort(token_subscription, 0, true)

    send(self(), {:abort, :token, :token_abort})

    assert {:error, :aborted, :token_abort} =
             Web.AbortSignal.receive_abort(token_subscription, 0, true)
  end

  test "check!/1 throws custom token abort reasons" do
    send(self(), {:abort, :token, :token_abort})

    assert catch_throw(Web.AbortSignal.check!(:token)) == {:abort, :token_abort}
  end

  test "abort signal subscriptions observe both abort messages and process down" do
    controller = Web.AbortController.new()
    {:ok, subscription} = Web.AbortSignal.subscribe(controller.signal)

    assert :ok = Web.AbortController.abort(controller, :boom)
    assert {:error, :aborted, _reason} = Web.AbortSignal.receive_abort(subscription, 100, true)
    assert {:error, :aborted, _reason} = Web.AbortSignal.receive_abort(subscription, 100, true)
    assert :ok = Web.AbortSignal.unsubscribe(subscription)
  end

  test "subscribe returns aborted when given a live pid that is not a signal server" do
    # The process does not answer the call of subscribe/1. The sleep is part
    # of the scenario: the process stops after it, and then the call ends.
    pid = spawn(fn -> Process.sleep(100) end)
    signal = %Web.AbortSignal{pid: pid, ref: make_ref()}

    assert {:error, :aborted} = Web.AbortSignal.subscribe(signal)
  end

  test "abort/1 returns an already-aborted signal with the given reason" do
    signal = Web.AbortSignal.abort(:manual_cancel)

    assert signal.aborted
    assert signal.reason == :manual_cancel
    assert {:error, :aborted} = Web.AbortSignal.subscribe(signal)
  end

  test "timeout/1 gives a TimeoutError, as the DOM Standard specifies" do
    signal = Web.AbortSignal.timeout(1)
    # The process of the signal stops when the time limit aborts it.
    assert_down(signal.pid)

    assert %Web.DOMException{name: "TimeoutError", message: "signal timed out", code: 23} =
             Web.AbortSignal.reason(signal)
  end

  test "throw_if_aborted/1 raises the reason of the signal" do
    assert_raise RuntimeError, "my reason", fn ->
      Web.AbortSignal.throw_if_aborted(Web.AbortSignal.abort(%RuntimeError{message: "my reason"}))
    end

    assert_raise Web.DOMException, "signal is aborted without reason", fn ->
      Web.AbortSignal.throw_if_aborted(Web.AbortSignal.abort())
    end

    # A reason that is not an exception goes into an AbortError.
    assert_raise Web.DOMException, ":my_atom", fn ->
      Web.AbortSignal.throw_if_aborted(Web.AbortSignal.abort(:my_atom))
    end
  end

  test "abort/0 uses the default aborted reason" do
    signal = Web.AbortSignal.abort()

    assert signal.aborted
    assert %Web.DOMException{name: "AbortError"} = signal.reason
  end

  test "aborted?/1 and reason/1 helper fallbacks" do
    controller = Web.AbortController.new()

    assert Web.AbortSignal.aborted?(nil) == false
    assert Web.AbortSignal.aborted?(:not_a_signal) == false
    assert Web.AbortSignal.reason(nil) == nil
    assert Web.AbortSignal.reason(:not_a_signal) == nil
    assert Web.AbortSignal.aborted?(controller.signal) == false
    assert Web.AbortSignal.reason(controller.signal) == nil

    assert :ok = Web.AbortController.abort(controller, :boom)
    assert Web.AbortSignal.aborted?(controller.signal) == true
    assert Web.AbortSignal.reason(controller.signal) == :boom

    pre_aborted = Web.AbortSignal.abort(:manual)
    assert Web.AbortSignal.aborted?(pre_aborted) == true
    assert Web.AbortSignal.reason(pre_aborted) == :manual
  end

  test "reason/1 can read a queued reason from a live signal subscription" do
    controller = Web.AbortController.new()
    send(self(), {:abort, controller.signal.ref, :queued_reason})

    assert Web.AbortSignal.reason(controller.signal) == :queued_reason
  end

  test "timeout/1 aborts the signal after the requested delay" do
    signal = Web.AbortSignal.timeout(10)

    assert :ok = Web.AbortSignal.receive_abort(nil, 0, true)
    assert {:error, :aborted} = Web.AbortSignal.subscribe(signal) |> wait_for_abort()
  end

  test "any/1 aborts when the first source signal aborts" do
    first = Web.AbortController.new()
    second = Web.AbortController.new()
    third = Web.AbortController.new()

    signal = Web.AbortSignal.any([first.signal, second.signal, third.signal])
    # The waiters of the new signal subscribed to each source.
    for controller <- [first, second, third], do: await_subscriber(controller.signal)

    assert :ok = Web.AbortController.abort(second, :middle_first)
    assert {:error, :aborted} = Web.AbortSignal.subscribe(signal) |> wait_for_abort()
    assert Web.AbortSignal.reason(signal) == :middle_first

    assert :ok = Web.AbortController.abort(first, :later)
    assert :ok = Web.AbortController.abort(third, :later)
    assert Web.AbortSignal.reason(signal) == :middle_first
  end

  test "any/1 aborts immediately when a source is already aborted" do
    controller = Web.AbortController.new()
    assert :ok = Web.AbortController.abort(controller, :pre_aborted)

    signal = Web.AbortSignal.any([controller.signal, self()])

    assert Web.AbortSignal.aborted?(signal)
    assert Web.AbortSignal.reason(signal) == :pre_aborted
    assert {:error, :aborted} = Web.AbortSignal.subscribe(signal)
  end

  test "any/1 ignores sources that are already dead while waiting on the rest" do
    {dead_pid, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^dead_pid, _reason}

    controller = Web.AbortController.new()
    signal = Web.AbortSignal.any([dead_pid, controller.signal])
    await_subscriber(controller.signal)

    assert :ok = Web.AbortController.abort(controller, :survivor)
    assert {:error, :aborted} = Web.AbortSignal.subscribe(signal) |> wait_for_abort()
  end

  test "handle_info ignores stale subscriber down messages" do
    monitor_ref = make_ref()
    other_ref = make_ref()
    state = %{ref: make_ref(), subscribers: %{self() => {other_ref, 1}}}

    assert {:noreply, ^state} =
             Web.AbortSignal.handle_info({:DOWN, monitor_ref, :process, self(), :normal}, state)
  end

  test "handle_info removes matching subscribers on down" do
    monitor_ref = make_ref()
    state = %{ref: make_ref(), subscribers: %{self() => {monitor_ref, 1}}}

    assert {:noreply, %{subscribers: %{}}} =
             Web.AbortSignal.handle_info({:DOWN, monitor_ref, :process, self(), :normal}, state)
  end

  test "handle_info timeout triggers the same shutdown path as abort" do
    ref = make_ref()
    state = %{ref: ref, subscribers: %{self() => {make_ref(), 1}}}

    assert {:stop, {:shutdown, {:aborted, :timeout}}, ^state} =
             Web.AbortSignal.handle_info({:abort_signal_timeout, :timeout}, state)

    assert_receive {:abort, ^ref, :timeout}
  end

  test "receive_abort/3 gives the reason of a token abort" do
    token_subscription = %{type: :token, token: :token}
    send(self(), {:abort, :token, :boom})

    assert {:error, :aborted, :boom} = Web.AbortSignal.receive_abort(token_subscription, 0, true)
  end

  test "receive_abort/3 handles nil and timeout paths" do
    assert :ok = Web.AbortSignal.receive_abort(nil, 0, true)
    assert :ok = Web.AbortSignal.receive_abort(%{type: :token, token: :token}, 0, true)
  end

  test "throw_if_aborted/1 allows nil and active signals" do
    controller = Web.AbortController.new()

    assert :ok = Web.AbortSignal.throw_if_aborted(nil)
    assert :ok = Web.AbortSignal.throw_if_aborted(controller.signal)
  end

  test "throw_if_aborted/1 raises AbortError for pre-aborted signals" do
    exception =
      assert_raise Web.DOMException, fn ->
        Web.AbortSignal.throw_if_aborted(Web.AbortSignal.abort(:manual))
      end

    assert exception.name == "AbortError"
    assert exception.message == ":manual"
  end

  test "throw_if_aborted/1 raises AbortError for live aborted signals" do
    controller = Web.AbortController.new()
    assert :ok = Web.AbortController.abort(controller, :boom)

    exception =
      assert_raise Web.DOMException, fn ->
        Web.AbortSignal.throw_if_aborted(controller.signal)
      end

    assert exception.name == "AbortError"
    assert exception.message == ":boom"
  end

  test "throw_if_aborted/1 can consume queued abort messages from a live signal" do
    controller = Web.AbortController.new()
    send(self(), {:abort, controller.signal.ref, :queued_abort})

    exception =
      assert_raise Web.DOMException, fn ->
        Web.AbortSignal.throw_if_aborted(controller.signal)
      end

    assert exception.name == "AbortError"
    assert exception.message == ":queued_abort"
  end

  test "any/1 ignores nil sources while waiting on live sources" do
    controller = Web.AbortController.new()
    signal = Web.AbortSignal.any([nil, controller.signal])

    assert :ok = Web.AbortController.abort(controller, :survivor)
    assert {:error, :aborted} = Web.AbortSignal.subscribe(signal) |> wait_for_abort()
    assert Web.AbortSignal.reason(signal) == :survivor
  end

  test "any/1 token waiters abort on bare token messages" do
    {signal, _coordinator, waiter} = start_any_with_waiter(:token)
    send(waiter, {:abort, :token})

    assert {:error, :aborted} = Web.AbortSignal.subscribe(signal) |> wait_for_abort()
    assert %Web.DOMException{name: "AbortError"} = Web.AbortSignal.reason(signal)
  end

  test "any/1 token waiters abort on reasoned token messages" do
    {signal, _coordinator, waiter} = start_any_with_waiter(:token)
    send(waiter, {:abort, :token, :token_reason})

    assert {:error, :aborted} = Web.AbortSignal.subscribe(signal) |> wait_for_abort()
    assert Web.AbortSignal.reason(signal) == :token_reason
  end

  test "any/1 token waiters stop quietly when their coordinator exits" do
    {signal, coordinator, waiter} = start_any_with_waiter(:token)
    Process.unlink(coordinator)
    monitor_ref = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^coordinator, :killed}
    # The waiter did all its steps when it stopped.
    assert_down(waiter)

    refute Web.AbortSignal.aborted?(signal)
  end

  test "any/1 pid waiters abort on direct abort messages" do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {signal, _coordinator, waiter} = start_any_with_waiter(pid)
    send(waiter, {:abort, pid, :pid_reason})

    assert {:error, :aborted} = Web.AbortSignal.subscribe(signal) |> wait_for_abort()
    assert Web.AbortSignal.reason(signal) == :pid_reason

    send(pid, :stop)
  end

  test "any/1 pid waiters abort when the monitored pid exits" do
    pid =
      spawn(fn ->
        receive do
        end
      end)

    {signal, _coordinator, waiter} = start_any_with_waiter(pid)
    await_waiting(waiter)
    Process.exit(pid, :pid_shutdown)

    assert {:error, :aborted} = Web.AbortSignal.subscribe(signal) |> wait_for_abort()
    assert Web.AbortSignal.reason(signal) == :pid_shutdown
  end

  test "any/1 pid waiters stop quietly when their coordinator exits" do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {signal, coordinator, waiter} = start_any_with_waiter(pid)
    Process.unlink(coordinator)
    monitor_ref = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^coordinator, :killed}
    send(pid, :stop)
    # The waiter did all its steps when it stopped.
    assert_down(waiter)

    refute Web.AbortSignal.aborted?(signal)
  end

  test "any/1 abort-signal waiters surface shutdown aborted reasons" do
    source = start_fake_abort_signal()
    {signal, _coordinator, waiter} = start_any_with_waiter(source)
    await_waiting(waiter)
    send(source.pid, {:stop, {:shutdown, {:aborted, :signal_reason}}})

    assert {:error, :aborted} = Web.AbortSignal.subscribe(signal) |> wait_for_abort()
    assert Web.AbortSignal.reason(signal) == :signal_reason
  end

  test "any/1 abort-signal waiters give the default reason for a signal that stops" do
    source = start_fake_abort_signal()
    {signal, _coordinator, waiter} = start_any_with_waiter(source)
    await_waiting(waiter)
    send(source.pid, {:stop, :signal_down})

    assert {:error, :aborted} = Web.AbortSignal.subscribe(signal) |> wait_for_abort()
    assert %Web.DOMException{name: "AbortError"} = Web.AbortSignal.reason(signal)
  end

  test "any/1 abort-signal waiters stop quietly when their coordinator exits" do
    source = start_fake_abort_signal()
    {signal, coordinator, waiter} = start_any_with_waiter(source)
    Process.unlink(coordinator)
    monitor_ref = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^coordinator, :killed}
    send(source.pid, {:stop, {:shutdown, {:aborted, :ignored}}})
    # The waiter did all its steps when it stopped.
    assert_down(waiter)

    refute Web.AbortSignal.aborted?(signal)
  end

  test "receive_abort/3 can observe process down reasons directly" do
    signal_pid =
      spawn(fn ->
        receive do
        end
      end)

    signal_monitor = Process.monitor(signal_pid)

    signal_subscription = %{
      type: :abort_signal,
      pid: signal_pid,
      ref: make_ref(),
      monitor_ref: signal_monitor
    }

    Process.exit(signal_pid, :custom_shutdown)

    assert {:error, :aborted, %Web.DOMException{name: "AbortError"}} =
             Web.AbortSignal.receive_abort(signal_subscription, 100, true)

    pid =
      spawn(fn ->
        receive do
        end
      end)

    {:ok, pid_subscription} = Web.AbortSignal.subscribe(pid)
    Process.exit(pid, :pid_shutdown)

    assert {:error, :aborted, :pid_shutdown} =
             Web.AbortSignal.receive_abort(pid_subscription, 100, true)

    assert :ok = Web.AbortSignal.unsubscribe(pid_subscription)
  end

  test "AbortController.abort/2 tolerates a process exiting during the synchronous abort call" do
    pid =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, {:abort, _reason}} ->
            exit(:not_a_genserver)
        end
      end)

    controller = %Web.AbortController{signal: %Web.AbortSignal{pid: pid}}

    assert :ok = Web.AbortController.abort(controller, :boom)
  end

  defp start_any_with_waiter(source) do
    :erlang.trace(self(), true, [:procs, :set_on_spawn])

    try do
      signal = Web.AbortSignal.any([source])
      {coordinator, waiter} = await_any_waiter_trace()
      {signal, coordinator, waiter}
    after
      :erlang.trace(self(), false, [:all])
    end
  end

  defp await_any_waiter_trace(attempts \\ 40)

  defp await_any_waiter_trace(attempts) when attempts > 0 do
    receive do
      {:trace, coordinator, :spawn, waiter, {:erlang, :apply, [fun, []]}} ->
        if String.contains?(inspect(fun), "start_any_abort_waiter") do
          {coordinator, waiter}
        else
          await_any_waiter_trace(attempts - 1)
        end
    after
      50 -> await_any_waiter_trace(attempts - 1)
    end
  end

  defp await_any_waiter_trace(0), do: flunk("expected AbortSignal.any/1 to spawn a waiter")

  defp start_fake_abort_signal do
    ref = make_ref()
    pid = spawn(fn -> fake_abort_signal_loop() end)
    %Web.AbortSignal{pid: pid, ref: ref}
  end

  defp fake_abort_signal_loop do
    receive do
      {:"$gen_call", {from, ref}, {:subscribe, _subscriber}} ->
        send(from, {ref, :ok})
        fake_abort_signal_loop()

      {:stop, reason} ->
        exit(reason)
    end
  end

  defp assert_down(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
  end

  # Waits until the process of `signal` has a subscriber.
  defp await_subscriber(signal) do
    eventually(fn -> map_size(:sys.get_state(signal.pid).subscribers) > 0 end)
  end

  # Waits until the waiter has its subscription, and waits for an abort.
  defp await_waiting(waiter) do
    eventually(fn ->
      Process.info(waiter, :current_function) ==
        {:current_function, {Web.AbortSignal, :wait_for_subscription_or_coordinator, 3}}
    end)
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  defp wait_for_abort({:error, :aborted} = result), do: result

  defp wait_for_abort({:ok, subscription}) do
    Enum.reduce_while(1..20, :ok, fn _, _ ->
      case Web.AbortSignal.receive_abort(subscription, 25, true) do
        :ok -> {:cont, :ok}
        {:error, :aborted, _reason} -> {:halt, {:error, :aborted}}
      end
    end)
  after
    Web.AbortSignal.unsubscribe(subscription)
  end
end
