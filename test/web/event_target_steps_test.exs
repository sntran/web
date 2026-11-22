defmodule Web.EventTargetStepsTest do
  # The listener steps of the DOM Standard ("add an event listener",
  # "dispatch", "inner invoke") on each kind of event target of the
  # library: a target of `Web.EventTarget.new/0`, a signal, a message port,
  # and a broadcast channel. See also
  # `test/tla/event_target_conformance_test.exs`.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Web.AbortController
  alias Web.Event
  alias Web.EventTarget

  @kinds [:new, :signal, :port, :channel]

  defp make(:new), do: EventTarget.new()
  defp make(:signal), do: AbortController.new().signal

  defp make(:port) do
    %{port1: port1, port2: port2} = Web.MessageChannel.new()

    on_exit(fn ->
      Web.MessagePort.close(port1)
      Web.MessagePort.close(port2)
    end)

    port2
  end

  defp make(:channel) do
    channel = Web.BroadcastChannel.new("steps-#{System.unique_integer([:positive])}")
    on_exit(fn -> Web.BroadcastChannel.close(channel) end)
    channel
  end

  defp dispatch(target, event), do: elem(EventTarget.dispatch_event(target, event), 1)

  defp note(name) do
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

  for kind <- @kinds do
    describe "#{kind}:" do
      test "a listener runs in the process that dispatches, with the target in the event" do
        target = make(unquote(kind))
        me = self()

        EventTarget.add_event_listener(target, "x", fn event ->
          send(me, {self(), event.target, Event.current_target(event), event.is_trusted})
        end)

        trusted = %{Event.new("x") | is_trusted: true}
        assert dispatch(target, trusted)
        # The event of `dispatchEvent()` is not trusted.
        assert_received {pid, ^target, ^target, false}
        assert pid == self()
      end

      test "the capture is a part of the listener, and the capture listeners run first" do
        target = make(unquote(kind))
        callback = note(:same)

        target
        |> EventTarget.add_event_listener("x", note(:bubbling))
        |> EventTarget.add_event_listener("x", callback)
        |> EventTarget.add_event_listener("x", callback, true)
        |> EventTarget.add_event_listener("x", note(:capturing), capture: true)

        assert dispatch(target, Event.new("x"))
        assert received() == [:same, :capturing, :bubbling, :same]

        EventTarget.remove_event_listener(target, "x", callback, capture: true)
        assert dispatch(target, Event.new("x"))
        assert received() == [:capturing, :bubbling, :same]
      end

      test "a once listener is removed before its call" do
        target = make(unquote(kind))
        me = self()

        EventTarget.add_event_listener(
          target,
          "x",
          fn ->
            send(me, :once)
            # A new event in the call does not call the listener again.
            assert dispatch(target, Event.new("x"))
          end,
          once: true
        )

        assert dispatch(target, Event.new("x"))
        assert dispatch(target, Event.new("x"))
        assert received() == [:once]
      end

      test "prevent_default/1 in a passive listener has no effect, and passive is false by default" do
        target = make(unquote(kind))
        me = self()

        cancel = fn name ->
          fn event ->
            :ok = Event.prevent_default(event)
            send(me, {name, Event.default_prevented?(event)})
          end
        end

        EventTarget.add_event_listener(target, "x", cancel.(:passive), passive: true)
        assert dispatch(target, Event.new("x", cancelable: true))
        assert_received {:passive, false}

        EventTarget.add_event_listener(target, "x", cancel.(:default))
        refute dispatch(target, Event.new("x", cancelable: true))
        assert_received {:passive, false}
        assert_received {:default, true}
      end

      test "a listener that an earlier listener removes, or whose signal it aborts, does not run" do
        target = make(unquote(kind))
        controller = AbortController.new()
        removed = note(:removed)

        target
        |> EventTarget.add_event_listener("x", fn ->
          EventTarget.remove_event_listener(target, "x", removed)
          AbortController.abort(controller)
          EventTarget.add_event_listener(target, "x", note(:added))
        end)
        |> EventTarget.add_event_listener("x", removed)
        |> EventTarget.add_event_listener("x", note(:aborted), signal: controller.signal)

        assert dispatch(target, Event.new("x"))
        assert received() == []

        # The listener that came during the dispatch runs in the next one.
        assert dispatch(target, Event.new("x"))
        assert received() == [:added]
      end

      test "stop_immediate_propagation/1 stops the listeners after the listener" do
        target = make(unquote(kind))

        target
        |> EventTarget.add_event_listener("x", &Event.stop_immediate_propagation/1)
        |> EventTarget.add_event_listener("x", note(:after))

        event = Event.new("x")
        assert dispatch(target, event)
        assert received() == []
        refute Event.cancel_bubble?(event)
      end

      test "a dispatch of an event in its dispatch, or not initialized, raises an InvalidStateError" do
        target = make(unquote(kind))
        me = self()

        EventTarget.add_event_listener(target, "x", fn event ->
          send(me, catch_error(EventTarget.dispatch_event(target, event)).name)
        end)

        assert dispatch(target, Event.new("x"))
        assert_received "InvalidStateError"

        error = catch_error(EventTarget.dispatch_event(target, %Event{type: "x"}))
        assert %Web.DOMException{name: "InvalidStateError"} = error
        refute_received _message
      end

      test "an exception of a listener goes to the log, and the next listener runs" do
        target = make(unquote(kind))

        target
        |> EventTarget.add_event_listener("x", fn -> raise "listener failure" end)
        |> EventTarget.add_event_listener("x", note(:next))

        log = capture_log(fn -> assert dispatch(target, Event.new("x")) end)
        assert log =~ "listener failure"
        assert received() == [:next]
      end

      test "a signal that is not a signal raises a TypeError, also with no callback" do
        target = make(unquote(kind))

        for callback <- [note(:a), nil] do
          assert_raise Web.TypeError, fn ->
            EventTarget.add_event_listener(target, "x", callback, signal: :not_a_signal)
          end
        end
      end
    end
  end

  property "the listeners of a type run in the sequence of the adds on each target" do
    check all(
            kind <- member_of(@kinds),
            numbers <- uniq_list_of(integer(0..1_000), min_length: 1, max_length: 6)
          ) do
      me = self()

      target =
        Enum.reduce(numbers, make(kind), fn number, target ->
          EventTarget.add_event_listener(target, "x", fn -> send(me, {:called, number}) end)
        end)

      assert dispatch(target, Event.new("x"))

      called =
        Enum.map(numbers, fn _ -> receive(do: ({:called, n} -> n), after: (0 -> :none)) end)

      assert called == numbers
    end
  end

  test "a port or a channel that is closed has no listener, and checks the event" do
    for kind <- [:port, :channel] do
      target = make(kind)
      monitor = Process.monitor(target.address)

      if kind == :port,
        do: Web.MessagePort.close(target),
        else: Web.BroadcastChannel.close(target)

      assert_receive {:DOWN, ^monitor, :process, _pid, _reason}

      assert EventTarget.add_event_listener(target, "x", note(:a)) == target
      assert dispatch(target, Event.new("x"))
      assert received() == []

      error = catch_error(EventTarget.dispatch_event(target, %Event{type: "x"}))
      assert %Web.DOMException{name: "InvalidStateError"} = error
    end
  end
end
