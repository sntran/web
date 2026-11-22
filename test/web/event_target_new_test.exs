defmodule Web.EventTargetNewTest do
  # The event targets of `Web.EventTarget.new/0`.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Web.AbortController
  alias Web.Event
  alias Web.EventTarget

  defp dispatch(target, event), do: elem(EventTarget.dispatch_event(target, event), 1)

  defp recorder(name) do
    me = self()
    fn -> send(me, name) end
  end

  defp received do
    receive do
      name when is_atom(name) -> [name | received()]
    after
      0 -> []
    end
  end

  test "new/0 makes a target, and the listeners run before the dispatch returns" do
    target = EventTarget.new()
    assert %EventTarget{pid: pid} = target
    assert is_pid(pid)

    target =
      target
      |> EventTarget.add_event_listener("x", recorder(:a))
      |> EventTarget.add_event_listener(:x, recorder(:b))
      |> EventTarget.add_event_listener("y", recorder(:c))

    assert {^target, true} = EventTarget.dispatch_event(target, Event.new("x"))
    assert received() == [:a, :b]
  end

  property "the listeners of a type run in the sequence in which they were added" do
    check all(numbers <- uniq_list_of(integer(0..1_000), min_length: 1, max_length: 8)) do
      me = self()

      target =
        Enum.reduce(numbers, EventTarget.new(), fn number, target ->
          EventTarget.add_event_listener(target, "x", fn -> send(me, {:called, number}) end)
        end)

      assert dispatch(target, Event.new("x"))

      called =
        Enum.map(numbers, fn _ -> receive(do: ({:called, n} -> n), after: (0 -> :none)) end)

      assert called == numbers
    end
  end

  test "a listener with the same type, callback, and capture is added one time" do
    callback = recorder(:a)

    target =
      EventTarget.new()
      |> EventTarget.add_event_listener("x", callback)
      |> EventTarget.add_event_listener("x", callback, %{once: true})
      |> EventTarget.add_event_listener("x", callback, true)

    assert dispatch(target, Event.new("x"))
    assert received() == [:a, :a]

    # The listener without once stays. The capture is in the options of the
    # remove.
    target = EventTarget.remove_event_listener(target, "x", callback, capture: true)
    assert dispatch(target, Event.new("x"))
    assert received() == [:a]

    target = EventTarget.remove_event_listener(target, "x", callback)
    assert dispatch(target, Event.new("x"))
    assert received() == []
  end

  test "the options can be a keyword list, a map, or a boolean for the capture" do
    for options <- [[once: true], %{once: true}] do
      target = EventTarget.add_event_listener(EventTarget.new(), "x", recorder(:a), options)
      assert dispatch(target, Event.new("x"))
      assert dispatch(target, Event.new("x"))
      assert received() == [:a]
    end

    target =
      EventTarget.new()
      |> EventTarget.add_event_listener("x", recorder(:bubbling), false)
      |> EventTarget.add_event_listener("x", recorder(:capturing), true)

    assert dispatch(target, Event.new("x"))
    assert received() == [:capturing, :bubbling]
  end

  test "the capture listeners run first" do
    target =
      EventTarget.new()
      |> EventTarget.add_event_listener("x", recorder(:bubbling))
      |> EventTarget.add_event_listener("x", recorder(:capturing), capture: true)

    assert dispatch(target, Event.new("x"))
    assert received() == [:capturing, :bubbling]
  end

  test "a once listener is removed before it runs" do
    me = self()
    target = EventTarget.new()

    target =
      EventTarget.add_event_listener(
        target,
        "x",
        fn ->
          send(me, :once)
          assert dispatch(target, Event.new("x"))
        end,
        once: true
      )

    assert dispatch(target, Event.new("x"))
    assert dispatch(target, Event.new("x"))
    assert received() == [:once]
  end

  test "a listener that a listener removes does not run, and a new listener runs later" do
    target = EventTarget.new()
    later = recorder(:later)
    removed = recorder(:removed)

    target =
      target
      |> EventTarget.add_event_listener("x", fn ->
        EventTarget.remove_event_listener(target, "x", removed)
        EventTarget.add_event_listener(target, "x", later)
      end)
      |> EventTarget.add_event_listener("x", removed)

    assert dispatch(target, Event.new("x"))
    assert received() == []

    assert dispatch(target, Event.new("x"))
    assert received() == [:later]
  end

  test "a callback that is nil adds and removes nothing" do
    target = EventTarget.new()

    assert EventTarget.add_event_listener(target, "x", nil) == target
    assert EventTarget.remove_event_listener(target, "x", nil, true) == target
    assert dispatch(target, Event.new("x"))
  end

  test "an exception of a listener goes to the log, and the next listener runs" do
    target =
      EventTarget.new()
      |> EventTarget.add_event_listener("x", fn -> raise "listener failure" end)
      |> EventTarget.add_event_listener("x", recorder(:next))

    log = capture_log(fn -> assert dispatch(target, Event.new("x")) end)
    assert log =~ "listener failure"
    assert received() == [:next]
  end

  describe "the option signal" do
    test "the abort of the signal removes the listener" do
      controller = AbortController.new()

      target =
        EventTarget.add_event_listener(EventTarget.new(), "x", recorder(:a),
          signal: controller.signal
        )

      assert dispatch(target, Event.new("x"))
      assert received() == [:a]

      :ok = AbortController.abort(controller)
      assert dispatch(target, Event.new("x"))
      assert received() == []
    end

    test "a signal that aborted adds no listener" do
      for signal <- [Web.AbortSignal.abort(), aborted_signal()] do
        target =
          EventTarget.add_event_listener(EventTarget.new(), "x", recorder(:a), signal: signal)

        assert dispatch(target, Event.new("x"))
        assert received() == []
      end
    end

    test "a listener that aborts its signal stops the listeners of the signal after it" do
      controller = AbortController.new()

      target =
        EventTarget.new()
        |> EventTarget.add_event_listener("x", fn -> AbortController.abort(controller) end,
          signal: controller.signal
        )
        |> EventTarget.add_event_listener("x", recorder(:after), signal: controller.signal)

      assert dispatch(target, Event.new("x"))
      assert received() == []
    end

    test "a signal that aborts after the check of the add removes the listener" do
      signal = %Web.AbortSignal{pid: spawn_link(&late_abort_signal/0), ref: make_ref()}

      target =
        EventTarget.add_event_listener(EventTarget.new(), "x", recorder(:a), signal: signal)

      assert dispatch(target, Event.new("x"))
      assert received() == []
    end

    test "a value that is not a signal raises a TypeError, also with no callback" do
      for callback <- [recorder(:a), nil] do
        assert_raise Web.TypeError, fn ->
          EventTarget.add_event_listener(EventTarget.new(), "x", callback, signal: self())
        end
      end
    end
  end

  test "a target whose process stopped has no listener" do
    target = EventTarget.new()
    monitor = Process.monitor(target.pid)
    Process.exit(target.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _pid, :killed}

    assert EventTarget.add_event_listener(target, "x", recorder(:a)) == target
    assert EventTarget.remove_event_listener(target, "x", recorder(:a)) == target
    assert dispatch(target, Event.new("x"))
    assert received() == []
  end

  defp aborted_signal do
    controller = AbortController.new()
    :ok = AbortController.abort(controller)
    controller.signal
  end

  # A signal that is not aborted at the check of `add_event_listener/4`, and
  # that aborted when the listener asks for its abort algorithm.
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
