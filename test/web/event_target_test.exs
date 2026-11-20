defmodule Web.EventTargetTest do
  use ExUnit.Case, async: true

  alias Web.AsyncContext.Snapshot
  alias Web.Internal.EventTarget.Server
  alias Web.TestSupport.EventTargetFixture, as: FixtureTarget

  defmodule OkCallbackModule do
    def handle_add_listener(_target, _type, _callback, _options), do: :ok
    def handle_dispatch(_target, _event), do: :ok
  end

  defmodule BareTarget do
    defstruct [:ref, :label]
  end

  test "dispatchEvent invokes registered listeners, fires callbacks, and removes once listeners" do
    parent = self()

    target =
      FixtureTarget.new(parent)
      |> Web.EventTarget.addEventListener("message", fn event ->
        send(parent, {:persistent, event.detail})
      end)
      |> Web.EventTarget.addEventListener(
        "message",
        fn event ->
          send(parent, {:once, event.detail})
        end,
        once: true
      )

    event = Web.CustomEvent.new("message", detail: %{value: 1})

    assert_receive {:handle_add_listener, "message"}
    assert_receive {:handle_add_listener, "message"}

    {target, true} = Web.EventTarget.dispatchEvent(target, event)

    assert_receive {:handle_dispatch, "message"}
    assert_receive {:persistent, %{value: 1}}
    assert_receive {:once, %{value: 1}}

    {target, true} = Web.EventTarget.dispatchEvent(target, event)

    assert_receive {:handle_dispatch, "message"}
    assert_receive {:persistent, %{value: 1}}
    refute_receive {:once, _}

    assert map_size(listeners(target)) == 1
  end

  test "removeEventListener removes matching callbacks and keeps non-matching ones" do
    keep = &Kernel.is_nil/1
    drop = fn _event -> :ok end

    target =
      FixtureTarget.new()
      |> Web.EventTarget.addEventListener("shared", keep)
      |> Web.EventTarget.addEventListener("shared", drop)

    target = Web.EventTarget.removeEventListener(target, "shared", drop)

    assert [%{callback: ^keep}] = listeners(target)["shared"]
  end

  test "duplicate suppression, atom types, and zero-arity callbacks work" do
    parent = self()
    callback = fn -> send(parent, :ping) end

    target =
      FixtureTarget.new(parent)
      |> Web.EventTarget.addEventListener(:tick, callback, %{once: false})
      |> Web.EventTarget.addEventListener(:tick, callback)

    assert [%{watcher: nil}] = listeners(target)["tick"]

    {target, true} = Web.EventTarget.dispatchEvent(target, Web.CustomEvent.new(:tick))
    assert_receive :ping

    target = Web.EventTarget.removeEventListener(target, :tick, callback)
    assert listeners(target) == %{}
  end

  test "pre-aborted signals are skipped and live pid watchers are removed on abort" do
    callback = fn _event -> :ok end

    skipped =
      FixtureTarget.new()
      |> Web.EventTarget.addEventListener("aborted", callback,
        signal: Web.AbortSignal.abort(:done)
      )

    assert listeners(skipped) == %{}

    target =
      FixtureTarget.new()
      |> Web.EventTarget.addEventListener("pid-signal", callback, signal: self())

    assert [%{watcher: watcher}] = listeners(target)["pid-signal"]
    send(watcher, :noise)
    send(watcher, {:abort, self(), :pid_stop})

    await_no_listeners(target)
    assert listeners(target) == %{}

    signal = spawn(fn -> Process.sleep(:infinity) end)

    target =
      FixtureTarget.new()
      |> Web.EventTarget.addEventListener("pid-down", callback, signal: signal)

    assert [%{watcher: pid_down_watcher}] = listeners(target)["pid-down"]
    await_watcher_monitor(pid_down_watcher, signal)

    Process.exit(signal, :kill)
    await_no_listeners(target)
    assert listeners(target) == %{}
  end

  test "token-backed watchers handle both abort message shapes" do
    callback = fn _event -> :ok end

    target =
      FixtureTarget.new()
      |> Web.EventTarget.addEventListener("token", callback, signal: :token_signal)

    assert [%{watcher: watcher}] = listeners(target)["token"]
    send(watcher, :noise)
    send(watcher, {:abort, :token_signal})
    await_no_listeners(target)
    assert listeners(target) == %{}

    target =
      FixtureTarget.new()
      |> Web.EventTarget.addEventListener("token-2", callback, signal: :token_signal_2)

    assert [%{watcher: watcher2}] = listeners(target)["token-2"]
    send(watcher2, {:abort, :token_signal_2, :stop})
    await_no_listeners(target)
    assert listeners(target) == %{}
  end

  test "abort-signal watchers remove listeners on abort and on signal-process exit" do
    controller = Web.AbortController.new()

    target =
      FixtureTarget.new()
      |> Web.EventTarget.addEventListener("signal", fn _event -> :ok end,
        signal: controller.signal
      )

    assert [%{watcher: watcher}] = listeners(target)["signal"]
    send(watcher, :noise)

    Web.AbortController.abort(controller, :stop)
    await_no_listeners(target)
    assert listeners(target) == %{}

    controller = Web.AbortController.new()

    target =
      FixtureTarget.new()
      |> Web.EventTarget.addEventListener("signal-down", fn _event -> :ok end,
        signal: controller.signal
      )

    # The watcher subscribed to the signal. Thus the stop of the signal
    # process comes to the watcher as a DOWN message.
    assert [%{watcher: watcher}] = listeners(target)["signal-down"]
    await_subscriber(controller.signal, watcher)
    Process.exit(controller.signal.pid, :kill)
    await_no_listeners(target)
    assert listeners(target) == %{}
  end

  test "removing a listener stops its watcher process" do
    callback = fn _event -> :ok end

    target =
      FixtureTarget.new()
      |> Web.EventTarget.addEventListener("loop", callback, signal: self())

    assert [%{watcher: watcher}] = listeners(target)["loop"]
    assert is_pid(watcher)

    target = Web.EventTarget.removeEventListener(target, "loop", callback)

    assert listeners(target) == %{}
    await_process_exit(watcher)
  end

  test "self-cast add, remove, and nested dispatch paths stay asynchronous and stable" do
    parent = self()

    removable = fn _event -> send(parent, :removable) end

    target =
      FixtureTarget.new(parent)
      |> Web.EventTarget.add_event_listener("tick", removable)
      |> Web.EventTarget.add_event_listener("tick", fn event ->
        Web.EventTarget.add_event_listener(event.target, "later", fn _later_event ->
          send(parent, :later)
        end)

        Web.EventTarget.remove_event_listener(event.target, "tick", removable)

        {_target, true} =
          Web.EventTarget.dispatch_event(event.target, %{type: "nested", target: event.target})
      end)
      |> Web.EventTarget.add_event_listener("nested", fn _event ->
        send(parent, :nested)
      end)

    assert {^target, true} =
             Web.EventTarget.dispatch_event(target, %{type: "tick", target: target})

    assert_receive :removable
    # The server casts the add, the remove, and the nested dispatch to itself
    # in this sequence. Thus the event "nested" tells that the server did
    # the add and the remove.
    assert_receive :nested

    assert {^target, true} =
             Web.EventTarget.dispatch_event(target, %{type: "tick", target: target})

    refute_receive :removable

    assert {^target, true} =
             Web.EventTarget.dispatch_event(target, %{type: "later", target: target})

    assert_receive :later
  end

  describe "the listener process of a port or a channel" do
    import ExUnit.CaptureLog

    defp start_server(opts \\ []) do
      {:ok, server} = Server.start_link([target: %BareTarget{label: "bare"}] ++ opts)
      server
    end

    def build_event(type, detail), do: Web.CustomEvent.new(type, detail: detail)
    def build_nothing, do: nil
    def build_failure, do: raise("the event cannot be made")

    defp task(build, reply_to \\ nil) do
      task = %{build: build, snapshot: Snapshot.take()}
      if reply_to, do: Map.put(task, :reply_to, reply_to), else: task
    end

    test "an event handler has the place of its first callback" do
      test = self()
      server = start_server()
      note = fn name -> fn event -> send(test, {name, event.detail}) end end

      :ok = Server.add_event_listener(server, "tick", note.(:before), %{})
      :ok = Server.set_handler(server, :tick, note.(:handler))
      :ok = Server.add_event_listener(server, "tick", note.(:after), %{})
      :ok = Server.set_handler(server, "tick", note.(:handler_2))

      Server.dispatch_event(server, Web.CustomEvent.new("tick", detail: 1), Snapshot.take())

      assert {:messages, [before: 1, handler_2: 1, after: 1]} = Process.info(self(), :messages)

      # A handler of nil keeps its place, and does not run.
      :ok = Server.set_handler(server, "tick", nil)
      Server.dispatch_event(server, Web.CustomEvent.new("tick", detail: 2), Snapshot.take())
      assert_received {:before, 2}
      assert_received {:after, 2}
      refute_received {:handler_2, 2}

      # The place of a handler is not a listener that a caller can remove.
      assert [_before, %{callback: :handler}, _after] = :sys.get_state(server).listeners["tick"]
    end

    test "a task makes its event in the process, and answers" do
      test = self()
      server = start_server()
      :ok = Server.add_event_listener(server, "made", fn event -> send(test, event) end, %{})

      :ok = Server.run_task(server, task({__MODULE__, :build_event, ["made", 7]}, {self(), :one}))

      assert_receive {:event_done, :one}
      assert_received %Web.CustomEvent{type: "made", detail: 7}

      # A task with no address for the answer.
      :ok = Server.run_task(server, task({__MODULE__, :build_event, ["made", 8]}))
      assert_receive %Web.CustomEvent{detail: 8}
    end

    test "a task that makes no event, or that fails, has no event" do
      test = self()
      server = start_server()
      :ok = Server.add_event_listener(server, "made", fn event -> send(test, event) end, %{})

      :ok = Server.run_task(server, task({__MODULE__, :build_nothing, []}, {self(), :nothing}))
      assert_receive {:event_done, :nothing}

      log =
        capture_log(fn ->
          :ok = Server.run_task(server, task({__MODULE__, :build_failure, []}, {self(), :failed}))
          assert_receive {:event_done, :failed}
        end)

      assert log =~ "The task of an event failed."
      assert log =~ "the event cannot be made"
      refute_received %Web.CustomEvent{}
      assert Process.alive?(server)
    end

    test "a closed gate stops the events, and a task comes back" do
      test = self()
      gate = :atomics.new(1, signed: false)
      server = start_server(gate: gate)
      :ok = Server.add_event_listener(server, "made", fn event -> send(test, event) end, %{})

      :atomics.put(gate, 1, 1)

      :ok = Server.run_task(server, task({__MODULE__, :build_event, ["made", 1]}, {self(), :one}))
      assert_receive {:event_returned, :one}

      :ok = Server.run_task(server, task({__MODULE__, :build_event, ["made", 2]}))
      GenServer.cast(server, {:dispatch_event, Web.CustomEvent.new("made"), Snapshot.take()})
      assert Server.dispatch_event(server, Web.CustomEvent.new("made"), Snapshot.take())

      refute_received %Web.CustomEvent{}
    end

    test "a listener that fails goes to the log, and the next listener runs" do
      test = self()
      server = start_server()
      :ok = Server.add_event_listener(server, "tick", fn -> exit(:the_listener_stopped) end, %{})
      :ok = Server.add_event_listener(server, "tick", fn -> send(test, :next) end, %{})

      log =
        capture_log(fn ->
          Server.dispatch_event(server, Web.CustomEvent.new("tick"), Snapshot.take())
        end)

      assert log =~ ~s(A listener of the event "tick" failed.)
      assert log =~ "the_listener_stopped"
      assert_received :next
    end

    test "two functions with different values are two callbacks" do
      test = self()
      server = start_server()
      make = fn value -> fn -> send(test, value) end end

      :ok = Server.add_event_listener(server, "tick", make.(1), %{})
      :ok = Server.add_event_listener(server, "tick", make.(2), %{})
      # The same function with the same value is the same callback.
      :ok = Server.add_event_listener(server, "tick", make.(2), %{})
      assert length(:sys.get_state(server).listeners["tick"]) == 2

      :ok = Server.remove_event_listener(server, "tick", make.(1))
      Server.dispatch_event(server, Web.CustomEvent.new("tick"), Snapshot.take())

      assert_received 2
      refute_received 1
    end

    test "the process stops after the event that it does, and ignores other messages" do
      server = start_server()
      monitor = Process.monitor(server)

      send(server, :unexpected)
      assert Server.dispatch_event(server, Web.CustomEvent.new("tick"), Snapshot.take())

      Process.unlink(server)
      :ok = Server.stop(server)
      assert_receive {:DOWN, ^monitor, :process, ^server, :normal}
    end
  end

  test "event target public surface does not export pid helpers" do
    exported = Web.EventTarget.__info__(:functions)

    refute {:event_target_pid!, 1} in exported
    refute {:server_pid!, 1} in exported
  end

  test "direct event_target_pid resolves the event target server" do
    target = FixtureTarget.new()
    pid = event_target_pid(target)

    assert Process.alive?(pid)
  end

  test "event target operations raise for unknown handles" do
    target = %FixtureTarget{event_target_pid: nil, parent: self()}

    assert_raise ArgumentError, ~r/Unknown EventTarget handle/, fn ->
      Web.EventTarget.add_event_listener(target, "missing", fn _event -> :ok end)
    end
  end

  test "event target operations raise for dead pids" do
    target = FixtureTarget.new()
    pid = event_target_pid(target)

    assert :ok = GenServer.stop(pid)

    assert_raise ArgumentError, ~r/Unknown EventTarget pid/, fn ->
      Web.EventTarget.dispatch_event(target, %{type: "dead", target: target})
    end
  end

  test "internal server falls back when callback modules return :ok or export nothing" do
    callback = fn _event -> :ok end
    target = %BareTarget{ref: make_ref(), label: :ok_fallback}

    {:ok, ok_pid} =
      Server.start_link(
        target: target,
        registry_key: nil,
        callback_module: OkCallbackModule
      )

    assert :ok = Server.add_event_listener(ok_pid, "ok", callback, %{})
    assert true = Server.dispatch_event(ok_pid, %{type: "ok", target: target}, Snapshot.take())
    assert :ok = Server.remove_event_listener(ok_pid, "ok", callback)
    assert :ok = GenServer.stop(ok_pid)

    {:ok, fallback_pid} =
      Server.start_link(
        target: %BareTarget{ref: make_ref(), label: :no_callbacks},
        registry_key: nil,
        callback_module: Map
      )

    assert :ok = Server.add_event_listener(fallback_pid, "plain", callback, %{})

    assert true =
             Server.dispatch_event(
               fallback_pid,
               %{type: "plain", target: target},
               Snapshot.take()
             )

    assert :ok = GenServer.stop(fallback_pid)
  end

  test "dead signal pids trigger the aborted subscribe cleanup path" do
    {dead_signal, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^dead_signal, _reason}

    target =
      FixtureTarget.new()
      |> Web.EventTarget.addEventListener("dead", fn _event -> :ok end, signal: dead_signal)

    await_no_listeners(target)
    assert listeners(target) == %{}
  end

  test "watchers exit cleanly when the event target server goes down for each signal shape" do
    controller = Web.AbortController.new()

    target =
      FixtureTarget.new()
      |> Web.EventTarget.addEventListener("abort-owner", fn _event -> :ok end,
        signal: controller.signal
      )

    assert [%{watcher: abort_watcher}] = listeners(target)["abort-owner"]
    server_pid = event_target_pid(target)
    Process.unlink(server_pid)
    Process.exit(server_pid, :shutdown)
    await_process_exit(abort_watcher)

    target =
      FixtureTarget.new()
      |> Web.EventTarget.addEventListener("pid-owner", fn _event -> :ok end, signal: self())

    assert [%{watcher: pid_watcher}] = listeners(target)["pid-owner"]
    server_pid = event_target_pid(target)
    Process.unlink(server_pid)
    Process.exit(server_pid, :shutdown)
    await_process_exit(pid_watcher)

    target =
      FixtureTarget.new()
      |> Web.EventTarget.addEventListener("token-owner", fn _event -> :ok end,
        signal: :owner_bound_token
      )

    assert [%{watcher: token_watcher}] = listeners(target)["token-owner"]
    server_pid = event_target_pid(target)
    Process.unlink(server_pid)
    Process.exit(server_pid, :shutdown)
    await_process_exit(token_watcher)
  end

  defp listeners(target) do
    target
    |> event_target_pid()
    |> :sys.get_state()
    |> Map.fetch!(:listeners)
  end

  defp event_target_pid(%{event_target_pid: event_target_pid}) when is_pid(event_target_pid),
    do: event_target_pid

  defp await_no_listeners(target, attempts \\ 50)

  defp await_no_listeners(_target, 0), do: flunk("expected listener cleanup")

  defp await_no_listeners(target, attempts) do
    if listeners(target) == %{} do
      target
    else
      Process.sleep(20)
      await_no_listeners(target, attempts - 1)
    end
  end

  defp await_process_exit(pid, attempts \\ 50)

  defp await_process_exit(_pid, 0), do: flunk("expected process shutdown")

  defp await_process_exit(pid, attempts) do
    if Process.alive?(pid) do
      Process.sleep(20)
      await_process_exit(pid, attempts - 1)
    else
      :ok
    end
  end

  defp await_watcher_monitor(watcher, signal, attempts \\ 50)
  defp await_watcher_monitor(_watcher, _signal, 0), do: flunk("expected watcher monitor")

  defp await_watcher_monitor(watcher, signal, attempts) do
    case Process.info(watcher, :monitors) do
      {:monitors, monitors} when is_list(monitors) ->
        if Enum.any?(monitors, &match?({:process, ^signal}, &1)) do
          :ok
        else
          Process.sleep(20)
          await_watcher_monitor(watcher, signal, attempts - 1)
        end

      _other ->
        Process.sleep(20)
        await_watcher_monitor(watcher, signal, attempts - 1)
    end
  end

  defp await_subscriber(signal, subscriber, attempts \\ 50)
  defp await_subscriber(_signal, _subscriber, 0), do: flunk("expected a subscription")

  defp await_subscriber(signal, subscriber, attempts) do
    if Map.has_key?(:sys.get_state(signal.pid).subscribers, subscriber) do
      :ok
    else
      Process.sleep(20)
      await_subscriber(signal, subscriber, attempts - 1)
    end
  end
end
