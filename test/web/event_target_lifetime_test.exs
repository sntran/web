defmodule Web.EventTargetLifetimeTest do
  # The lifetime of the process of a target of `Web.EventTarget.new/0`, of
  # the listeners of a signal, and of the blob URLs. These tests set the
  # linger time for the application. Thus they cannot run at the same time
  # as other tests.
  use ExUnit.Case, async: false

  alias Web.AbortController
  alias Web.AbortSignal
  alias Web.Event
  alias Web.EventTarget

  @linger 50

  setup do
    previous = Application.get_env(:web, :linger)
    Application.put_env(:web, :linger, @linger)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:web, :linger),
        else: Application.put_env(:web, :linger, previous)
    end)
  end

  # Runs `fun` in a process that then stops, and gives its result.
  defp in_short_process(fun) do
    parent = self()
    {pid, monitor} = spawn_monitor(fn -> send(parent, {:result, self(), fun.()}) end)
    assert_receive {:result, ^pid, result}
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
    result
  end

  defp assert_down(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 2_000
  end

  defp refute_down(pid, time) do
    monitor = Process.monitor(pid)
    refute_receive {:DOWN, ^monitor, :process, ^pid, _reason}, time
    Process.demonitor(monitor, [:flush])
  end

  # Examines `fun` until it gives true.
  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  test "a target stops after its owner stopped and its last listener went away" do
    target = in_short_process(&EventTarget.new/0)
    assert_down(target.pid)

    me = self()
    listener = fn -> send(me, :listener) end
    target = in_short_process(fn -> EventTarget.new() end)
    target = EventTarget.add_event_listener(target, "x", listener)

    # The listener of a live process keeps the target.
    refute_down(target.pid, 3 * @linger)
    assert {_target, true} = EventTarget.dispatch_event(target, Event.new("x"))
    assert_received :listener

    EventTarget.remove_event_listener(target, "x", listener)
    assert_down(target.pid)
  end

  test "a target with no use stays for the handoff time when the linger time is :infinity" do
    Application.put_env(:web, :linger, :infinity)

    target = in_short_process(&EventTarget.new/0)
    # The owner stopped and the target has no listener. The target waits
    # for a process that got it in a message.
    refute_down(target.pid, 3 * @linger)
    assert {_target, true} = EventTarget.dispatch_event(target, Event.new("x"))
    Process.exit(target.pid, :kill)
  end

  test "the listeners of a process that stopped go away" do
    target = EventTarget.new()
    signal = AbortController.new().signal

    for object <- [target, signal] do
      in_short_process(fn ->
        EventTarget.add_event_listener(object, "x", fn -> :ok end)
        AbortSignal.onabort(signal, fn -> :ok end)
      end)

      eventually(fn -> :sys.get_state(object.pid).listeners.entries == [] end)
    end

    assert AbortSignal.onabort(signal) == nil
  end

  test "a signal with a listener, or with a dependent signal, stays after its owner stopped" do
    listener = fn -> :ok end
    signal = in_short_process(fn -> AbortController.new().signal end)
    EventTarget.add_event_listener(signal, "abort", listener)
    refute_down(signal.pid, 3 * @linger)

    EventTarget.remove_event_listener(signal, "abort", listener)
    assert_down(signal.pid)

    # A signal of `AbortSignal.any/1` depends on the source: the source
    # stays while the dependent signal stays.
    source = in_short_process(fn -> AbortController.new().signal end)
    dependent = AbortSignal.any([source])
    refute_down(source.pid, 3 * @linger)

    # The owner of a second dependent signal stops: that signal stops, and
    # the source removes it.
    other = in_short_process(fn -> AbortSignal.any([source]) end)
    assert_down(other.pid)
    eventually(fn -> :sys.get_state(source.pid).dependents == [dependent] end)
  end

  test "a blob URL is revoked when the process that made it stops" do
    url = in_short_process(fn -> Web.URL.create_object_url(Web.Blob.new(["a"])) end)

    eventually(fn ->
      match?({:rejected, %Web.TypeError{}}, Web.Promise.wait(Web.fetch(url)))
    end)
  end
end
