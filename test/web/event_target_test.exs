defmodule Web.EventTargetTest do
  # The internal processes of the event targets: the listener process of a
  # port or a channel (`Web.Internal.EventTarget.Runner`), and the store of
  # its listeners (`Web.Internal.EventTarget.Store`).
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Web.AsyncContext.Snapshot
  alias Web.Internal.EventTarget.Dispatch
  alias Web.Internal.EventTarget.Runner
  alias Web.Internal.EventTarget.Store

  defmodule Target do
    defstruct [:label]
  end

  # An event as "create an event" makes it: it is trusted.
  def build_event(type, detail),
    do: %{Web.CustomEvent.new(type, detail: detail) | is_trusted: true}

  def build_nothing, do: nil
  def build_failure, do: raise("the event cannot be made")

  # A listener process with its store, as `Web.Internal.MessageTarget`
  # starts them.
  defp start_runner do
    gate = :atomics.new(1, signed: false)
    {:ok, runner} = Runner.start_link(gate)
    %{runner: runner, gate: gate, store: Store.start(runner, :with_owner)}
  end

  defp add(%{store: store}, type, callback, options \\ %{}),
    do: :ok = Web.EventTarget.__add__(store, type, callback, options)

  defp task(system, build, reply_to \\ nil) do
    task = %{build: build, snapshot: Snapshot.new(), target: %Target{}, store: system.store}
    if reply_to, do: Map.put(task, :reply_to, reply_to), else: task
  end

  describe "the listener process" do
    test "a task makes its event in the process, and the listeners get it" do
      test = self()
      system = start_runner()

      add(system, "made", fn event ->
        send(test, {event, self(), Web.Event.current_target(event)})
      end)

      :ok = Runner.run_task(system.runner, task(system, {__MODULE__, :build_event, ["made", 7]}))
      runner = system.runner
      assert_receive {%Web.CustomEvent{type: "made", detail: 7} = event, ^runner, %Target{}}
      # The listener process fires the event: the event stays trusted.
      assert event.is_trusted

      # A task with an address for the answer.
      :ok =
        Runner.run_task(
          system.runner,
          task(system, {__MODULE__, :build_event, ["made", 8]}, {self(), :one})
        )

      assert_receive {%Web.CustomEvent{detail: 8}, ^runner, _target}
      assert_receive {:event_done, :one}
    end

    test "a task that makes no event, or that fails, has no event" do
      test = self()
      system = start_runner()
      add(system, "made", fn event -> send(test, event) end)

      :ok =
        Runner.run_task(
          system.runner,
          task(system, {__MODULE__, :build_nothing, []}, {self(), :none})
        )

      assert_receive {:event_done, :none}

      log =
        capture_log(fn ->
          :ok =
            Runner.run_task(
              system.runner,
              task(system, {__MODULE__, :build_failure, []}, {self(), :failed})
            )

          assert_receive {:event_done, :failed}
        end)

      assert log =~ "The task of an event failed."
      assert log =~ "the event cannot be made"
      refute_received %Web.CustomEvent{}
      assert Process.alive?(system.runner)
    end

    test "a closed gate stops the events, and a task comes back" do
      test = self()
      system = start_runner()
      add(system, "made", fn event -> send(test, event) end)

      :atomics.put(system.gate, 1, 1)

      :ok =
        Runner.run_task(
          system.runner,
          task(system, {__MODULE__, :build_event, ["made", 1]}, {self(), :one})
        )

      assert_receive {:event_returned, :one}

      :ok = Runner.run_task(system.runner, task(system, {__MODULE__, :build_event, ["made", 2]}))
      _state = :sys.get_state(system.runner)
      refute_received %Web.CustomEvent{}
    end

    test "the process takes each other message, and stops after the event that it does" do
      system = start_runner()
      runner = system.runner
      monitor = Process.monitor(runner)
      store_monitor = Process.monitor(system.store)

      send(runner, :unexpected)
      _state = :sys.get_state(runner)
      assert {:messages, []} = Process.info(runner, :messages)

      Process.unlink(runner)
      :ok = Runner.stop(runner)
      assert_receive {:DOWN, ^monitor, :process, ^runner, :normal}
      # The store stops with the listener process.
      assert_receive {:DOWN, ^store_monitor, :process, _store, :normal}
    end
  end

  describe "the store of a port or a channel" do
    test "a listener stays when the process that added it stops" do
      test = self()
      system = start_runner()

      {adder, monitor} =
        spawn_monitor(fn -> add(system, "x", fn -> send(test, :called) end) end)

      assert_receive {:DOWN, ^monitor, :process, ^adder, :normal}

      assert Dispatch.dispatch(
               %Target{},
               Web.Event.new("x"),
               system.store
             )

      assert_received :called
    end

    test "the abort of the signal removes the listener, also after the adder stopped" do
      test = self()
      system = start_runner()
      controller = Web.AbortController.new()

      {adder, monitor} =
        spawn_monitor(fn ->
          add(system, "x", fn -> send(test, :called) end, %{signal: controller.signal})
        end)

      assert_receive {:DOWN, ^monitor, :process, ^adder, :normal}
      :ok = Web.AbortController.abort(controller)

      assert Dispatch.dispatch(
               %Target{},
               Web.Event.new("x"),
               system.store
             )

      refute_received :called
      assert :sys.get_state(system.store).listeners.entries == []
    end

    test "a signal that aborts after the check of the add removes the listener" do
      system = start_runner()
      signal = %Web.AbortSignal{pid: spawn_link(&late_abort_signal/0), ref: make_ref()}

      add(system, "x", fn -> :ok end, %{signal: signal})
      assert :sys.get_state(system.store).listeners.entries == []

      # A second add of the same listener is not added again, and adds no
      # abort algorithm.
      system = start_runner()
      controller = Web.AbortController.new()
      callback = fn -> :ok end
      add(system, "x", callback, %{signal: controller.signal})
      add(system, "x", callback, %{signal: controller.signal})
      assert [_listener] = :sys.get_state(system.store).listeners.entries
      assert [_algorithm] = :sys.get_state(controller.signal.pid).algorithms
    end
  end

  test "two functions with different values are two callbacks" do
    test = self()
    make = fn value -> fn -> send(test, value) end end

    target =
      Web.EventTarget.new()
      |> Web.EventTarget.add_event_listener("tick", make.(1))
      |> Web.EventTarget.add_event_listener("tick", make.(2))
      # The same function with the same value is the same callback.
      |> Web.EventTarget.add_event_listener("tick", make.(2))
      |> Web.EventTarget.remove_event_listener("tick", make.(1))

    assert {^target, true} = Web.EventTarget.dispatch_event(target, Web.Event.new("tick"))
    assert_received 2
    refute_received 2
    refute_received 1
  end

  # A signal that is not aborted at the check of the add, and that aborted
  # when the store asks for its abort algorithm.
  defp late_abort_signal do
    receive do
      {:"$gen_call", from, {:subscribe, _pid}} ->
        GenServer.reply(from, :ok)
        late_abort_signal()

      {:"$gen_cast", {:unsubscribe, _pid}} ->
        late_abort_signal()

      {:"$gen_call", from, {:add_algorithm, _algorithm}} ->
        GenServer.reply(from, :aborted)
        late_abort_signal()
    end
  end
end
