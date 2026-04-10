defmodule Web.AbortSignalTest do
  use ExUnit.Case, async: true

  test "child_spec exposes the signal starter" do
    assert %{start: {Web.AbortSignal, :start_link, []}} = Web.AbortSignal.child_spec(nil)
  end

  test "token subscriptions handle abort messages and idle checks" do
    assert :ok = Web.AbortSignal.receive_abort(%{type: :token, token: :token}, 0)

    send(self(), {:abort, :token, :boom})
    assert {:error, :aborted} = Web.AbortSignal.receive_abort(%{type: :token, token: :token}, 0)
  end

  test "pid subscriptions handle direct abort messages" do
    {:ok, subscription} = Web.AbortSignal.subscribe(self())

    send(self(), {:abort, self(), :boom})
    assert {:error, :aborted} = Web.AbortSignal.receive_abort(subscription, 0)

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

    assert {:error, :aborted, :aborted} =
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
    assert {:error, :aborted} = Web.AbortSignal.receive_abort(subscription, 100)
    assert {:error, :aborted} = Web.AbortSignal.receive_abort(subscription, 100)
    assert :ok = Web.AbortSignal.unsubscribe(subscription)
  end

  test "subscribe returns aborted when given a live pid that is not a signal server" do
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

  test "abort/0 uses the default aborted reason" do
    signal = Web.AbortSignal.abort()

    assert signal.aborted
    assert signal.reason == :aborted
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

    assert :ok = Web.AbortSignal.receive_abort(nil, 0)
    assert {:error, :aborted} = Web.AbortSignal.subscribe(signal) |> wait_for_abort()
  end

  test "any/1 aborts when the first source signal aborts" do
    first = Web.AbortController.new()
    second = Web.AbortController.new()
    third = Web.AbortController.new()

    signal = Web.AbortSignal.any([first.signal, second.signal, third.signal])
    Process.sleep(20)

    assert :ok = Web.AbortController.abort(second, :middle_first)
    assert {:error, :aborted} = Web.AbortSignal.subscribe(signal) |> wait_for_abort()

    assert :ok = Web.AbortController.abort(first, :later)
    assert :ok = Web.AbortController.abort(third, :later)
  end

  test "any/1 ignores sources that are already dead while waiting on the rest" do
    dead_pid = spawn(fn -> :ok end)
    Process.sleep(10)

    controller = Web.AbortController.new()
    signal = Web.AbortSignal.any([dead_pid, controller.signal])
    Process.sleep(20)

    assert :ok = Web.AbortController.abort(controller, :survivor)
    assert {:error, :aborted} = Web.AbortSignal.subscribe(signal) |> wait_for_abort()
  end

  test "handle_info ignores stale subscriber down messages" do
    monitor_ref = make_ref()
    other_ref = make_ref()
    state = %{ref: make_ref(), subscribers: %{self() => other_ref}}

    assert {:noreply, ^state} =
             Web.AbortSignal.handle_info({:DOWN, monitor_ref, :process, self(), :normal}, state)
  end

  test "handle_info removes matching subscribers on down" do
    monitor_ref = make_ref()
    state = %{ref: make_ref(), subscribers: %{self() => monitor_ref}}

    assert {:noreply, %{subscribers: %{}}} =
             Web.AbortSignal.handle_info({:DOWN, monitor_ref, :process, self(), :normal}, state)
  end

  test "handle_info timeout triggers the same shutdown path as abort" do
    ref = make_ref()
    state = %{ref: ref, subscribers: %{self() => make_ref()}}

    assert {:stop, {:shutdown, {:aborted, :timeout}}, ^state} =
             Web.AbortSignal.handle_info({:abort_signal_timeout, :timeout}, state)

    assert_receive {:abort, ^ref, :timeout}
  end

  test "receive_abort/2 normalizes reason-aware aborts" do
    token_subscription = %{type: :token, token: :token}
    send(self(), {:abort, :token, :boom})

    assert {:error, :aborted} = Web.AbortSignal.receive_abort(token_subscription, 0)
  end

  test "receive_abort/3 handles nil and timeout paths" do
    assert :ok = Web.AbortSignal.receive_abort(nil, 0, true)
    assert :ok = Web.AbortSignal.receive_abort(%{type: :token, token: :token}, 0, true)
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

    assert {:error, :aborted, :custom_shutdown} =
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

  defp wait_for_abort({:error, :aborted} = result), do: result

  defp wait_for_abort({:ok, subscription}) do
    Enum.reduce_while(1..20, :ok, fn _, _ ->
      case Web.AbortSignal.receive_abort(subscription, 25) do
        :ok -> {:cont, :ok}
        result -> {:halt, result}
      end
    end)
  after
    Web.AbortSignal.unsubscribe(subscription)
  end
end
