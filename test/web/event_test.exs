defmodule Web.EventTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.CustomEvent
  alias Web.Event
  alias Web.EventTarget

  doctest Web.Event

  defp dispatch(target, event), do: elem(EventTarget.dispatch_event(target, event), 1)

  test "new/2 has the defaults of EventInit, and a time stamp" do
    event = Event.new(:ping)

    assert %Event{type: "ping", target: nil, bubbles: false, cancelable: false} = event
    assert %Event{composed: false, is_trusted: false} = event
    assert event.time_stamp > 0
    assert Event.event_phase(event) == 0
    assert Event.current_target(event) == nil
    assert Event.src_element(event) == nil
    assert Event.composed_path(event) == []
    refute Event.default_prevented(event)
    assert Event.return_value(event)
    refute Event.cancel_bubble(event)

    event = Event.new("x", bubbles: true, cancelable: true, composed: true)
    assert %Event{bubbles: true, cancelable: true, composed: true} = event
  end

  property "only a cancelable event outside a passive listener is canceled" do
    check all(
            cancelable <- boolean(),
            passive <- boolean(),
            cancel <- member_of([:prevent_default, :return_value])
          ) do
      me = self()

      listener = fn event ->
        case cancel do
          :prevent_default -> :ok = Event.prevent_default(event)
          :return_value -> :ok = Event.return_value(event, false)
        end

        send(me, {:canceled, Event.default_prevented(event), Event.return_value(event)})
      end

      target = EventTarget.add_event_listener(EventTarget.new(), "x", listener, passive: passive)
      canceled? = cancelable and not passive

      assert dispatch(target, Event.new("x", cancelable: cancelable)) == not canceled?
      assert_received {:canceled, ^canceled?, return_value}
      assert return_value == not canceled?
    end
  end

  test "new/2 has only the members of EventInit" do
    event = Event.new("x", target: :a_target, current_target: :a_target, bubbles: true)
    assert {event.target, event.current_target, event.bubbles} == {nil, nil, true}

    event = Web.CustomEvent.new("x", target: :a_target, detail: 1, composed: true)
    assert {event.target, event.detail, event.composed} == {nil, 1, true}
  end

  test "return_value/2 with true and cancel_bubble/2 with false change nothing" do
    event = Event.new("x", cancelable: true)

    assert :ok = Event.return_value(event, true)
    assert :ok = Event.cancel_bubble(event, false)
    refute Event.default_prevented(event)
    refute Event.cancel_bubble(event)

    assert :ok = Event.cancel_bubble(event, true)
    assert Event.cancel_bubble(event)
  end

  test "a listener gets the event with its target and its phase" do
    me = self()
    target = EventTarget.new()
    event = Event.new("x")

    target =
      EventTarget.add_event_listener(target, "x", fn got ->
        send(me, {
          got.flags == event.flags,
          got.target,
          Event.current_target(got),
          Event.src_element(got),
          Event.composed_path(got),
          Event.event_phase(got)
        })
      end)

    assert dispatch(target, event)
    assert_received {true, ^target, ^target, ^target, [^target], 2}

    # After the dispatch, no listener runs: the phase is NONE.
    assert Event.event_phase(event) == 0
    assert Event.composed_path(event) == []
  end

  test "stop_immediate_propagation/1 stops the listeners after the current one" do
    me = self()

    target =
      EventTarget.new()
      |> EventTarget.add_event_listener("x", fn event ->
        :ok = Event.stop_immediate_propagation(event)
        send(me, :first)
      end)
      |> EventTarget.add_event_listener("x", fn -> send(me, :second) end)

    event = Event.new("x")
    assert dispatch(target, event)
    assert_received :first
    refute_received :second

    # The flags of the propagation are unset after the dispatch.
    refute Event.cancel_bubble(event)
  end

  test "stop_propagation/1 in a capture listener stops the other listeners of the target" do
    me = self()

    target =
      EventTarget.new()
      |> EventTarget.add_event_listener("x", fn -> send(me, :bubbling) end)
      |> EventTarget.add_event_listener(
        "x",
        fn event ->
          send(me, {:capturing, Event.cancel_bubble(event)})
          :ok = Event.stop_propagation(event)
          send(me, {:capturing, Event.cancel_bubble(event)})
        end,
        true
      )
      |> EventTarget.add_event_listener("x", fn -> send(me, :capturing_2) end, capture: true)

    assert dispatch(target, Event.new("x"))
    assert_received {:capturing, false}
    assert_received {:capturing, true}
    # The other capture listener runs: stop_propagation/1 does not stop the
    # listeners of the current target and phase.
    assert_received :capturing_2
    refute_received :bubbling
  end

  test "a dispatch of an event in its dispatch raises an InvalidStateError" do
    me = self()
    target = EventTarget.new()

    target =
      EventTarget.add_event_listener(target, "x", fn event ->
        error = catch_error(EventTarget.dispatch_event(target, event))
        send(me, error.name)
      end)

    assert dispatch(target, Event.new("x"))
    assert_received "InvalidStateError"
  end

  test "init_event/4 initializes the event again, but not during its dispatch" do
    me = self()
    event = Event.new("x", cancelable: true)
    :ok = Event.prevent_default(event)
    :ok = Event.stop_propagation(event)

    event = Event.init_event(event, :y, true, true)
    assert %Event{type: "y", bubbles: true, cancelable: true, is_trusted: false} = event
    refute Event.default_prevented(event)
    refute Event.cancel_bubble(event)
    assert %Event{bubbles: false, cancelable: false} = Event.init_event(event, "z")

    target =
      EventTarget.add_event_listener(EventTarget.new(), "y", fn got ->
        send(me, Event.init_event(got, "other").type)
      end)

    assert dispatch(target, event)
    assert_received "y"
  end

  test "CustomEvent has the fields and the flags of Event, and detail" do
    event = CustomEvent.new(:tick, detail: %{n: 1}, cancelable: true)

    assert %CustomEvent{type: "tick", detail: %{n: 1}, cancelable: true} = event
    assert event.time_stamp > 0
    :ok = Event.prevent_default(event)
    assert Event.default_prevented(event)

    assert %CustomEvent{bubbles: true, cancelable: false, detail: nil} =
             CustomEvent.init_custom_event(event, "a", true)

    assert %CustomEvent{cancelable: true, detail: nil} =
             CustomEvent.init_custom_event(event, "a", false, true)

    event = CustomEvent.init_custom_event(event, "other", true, false, :data)
    assert %CustomEvent{type: "other", bubbles: true, cancelable: false, detail: :data} = event
    refute Event.default_prevented(event)

    me = self()

    target =
      EventTarget.add_event_listener(EventTarget.new(), "other", fn got ->
        send(me, CustomEvent.init_custom_event(got, "changed").type)
      end)

    assert dispatch(target, event)
    assert_received "other"
  end

  test "a map with no flags is dispatched, and no listener can cancel it" do
    me = self()

    target =
      EventTarget.add_event_listener(EventTarget.new(), "x", fn event ->
        :ok = Event.prevent_default(event)
        send(me, {Map.has_key?(event, :flags), Event.event_phase(event)})
      end)

    assert dispatch(target, %{type: "x", cancelable: true})
    assert_received {false, 0}
  end
end
