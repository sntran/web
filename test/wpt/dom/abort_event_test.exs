# Port of web-platform-tests dom/abort/event.any.js
# WPT revision 61ad038e419a0bfacee26801e584b5057c3fbd60
#
# Forms of JS in this file:
#   - `new AbortController()` is `Web.AbortController.new/0`, and
#     `controller.abort(reason)` is `Web.AbortController.abort/2`.
#   - `AbortSignal.abort(reason)` is `Web.AbortSignal.abort/1`.
#   - `signal.aborted` is `Web.AbortSignal.aborted?/1`, and `signal.reason`
#     is `Web.AbortSignal.reason/1`. JS `undefined` as a result is `nil`.
#   - `"reason" in signal` is a check that `Web.AbortSignal.reason/1`
#     exists.
#   - JS `null` is `nil`. `Error("hello")` is `%RuntimeError{}`.
#   - `instanceof DOMException` is a match on `%Web.DOMException{}`.
#   - `signal.addEventListener(type, f)` is
#     `Web.EventTarget.add_event_listener/3`. `signal.onabort = f` is
#     `Web.AbortSignal.onabort(signal, f)`, the form of the event handlers
#     of `Web.MessagePort` and `Web.BroadcastChannel`.
#   - A listener sends a message to the test process, and the test process
#     does the checks. The event fires before `abort` returns: the test
#     uses `assert_received`, which does not wait.
#   - `assert_throws_exactly(value, f)` is `catch_error/1`: Erlang can raise
#     each term as an error, and `catch_error/1` gives that term.
#
# Not ported:
#   - "AbortController abort(undefined) creates an \"AbortError\"
#     DOMException": Elixir has no `undefined`. The call with no reason is
#     in "aborting AbortController without reason creates an \"AbortError\"
#     DOMException".

defmodule Web.WPT.DOM.AbortEventTest do
  use ExUnit.Case, async: true

  alias Web.AbortController
  alias Web.AbortSignal

  # `"reason" in signal`.
  defp has_reason_property? do
    Code.ensure_loaded?(AbortSignal) and function_exported?(AbortSignal, :reason, 1)
  end

  # `signal.onabort = callback`.
  defp set_onabort(signal, callback), do: AbortSignal.onabort(signal, callback)

  # The DOM Standard: "interface AbortSignal : EventTarget". The steps "run
  # the abort steps", step 3: "Fire an event named abort at signal". The
  # "signal abort" algorithm runs these steps before it returns.
  test "AbortController abort() should fire event synchronously" do
    c = AbortController.new()
    s = c.signal
    test_pid = self()

    refute AbortSignal.aborted?(s)
    assert has_reason_property?(), "signal has reason property"
    assert AbortSignal.reason(s) == nil, "signal.reason is initially undefined"

    Web.EventTarget.add_event_listener(s, "abort", fn _event ->
      send(test_pid, :abort_listener_called)
    end)

    :ok = AbortController.abort(c)

    # The listener ran one time before `abort` returned.
    assert_received :abort_listener_called
    refute_received :abort_listener_called
    assert AbortSignal.aborted?(s)
    reason = AbortSignal.reason(s)
    assert is_struct(reason, Web.DOMException), "signal.reason is DOMException"
    assert reason.name == "AbortError", "signal.reason is AbortError"

    :ok = AbortController.abort(c)

    # In WPT, a second call of the listener fails the test.
    refute_receive :abort_listener_called
  end

  test "controller.signal should always return the same object" do
    controller = AbortController.new()
    signal = controller.signal

    assert controller.signal == signal, "value of controller.signal should not have changed"
    :ok = AbortController.abort(controller)

    assert controller.signal == signal,
           "value of controller.signal should still not have changed"
  end

  # The DOM Standard: AbortSignal has "attribute EventHandler onabort". The
  # steps "run the abort steps", step 3: "Fire an event named abort at
  # signal". The "signal abort" algorithm, step 1: "If signal is aborted,
  # then return", thus a second abort fires no event.
  test "controller.abort() should do nothing the second time it is called" do
    controller = AbortController.new()
    signal = controller.signal
    test_pid = self()

    set_onabort(signal, fn _event -> send(test_pid, :abort_handler_called) end)

    :ok = AbortController.abort(controller)
    assert AbortSignal.aborted?(signal)
    # The event handler ran one time.
    assert_received :abort_handler_called
    refute_received :abort_handler_called, "event handler should have been called once"

    :ok = AbortController.abort(controller)
    assert AbortSignal.aborted?(signal)
    refute_receive :abort_handler_called, 100, "event handler should not have been called again"
  end

  # The DOM Standard: AbortSignal has "attribute EventHandler onabort".
  # The event fires one time only, when the signal aborts. Thus a handler
  # that is set after the abort is not called.
  test "event handler should not be called if added after controller.abort()" do
    controller = AbortController.new()
    test_pid = self()

    :ok = AbortController.abort(controller)

    set_onabort(controller.signal, fn _event ->
      send(test_pid, :unreached)
    end)

    refute_receive :unreached, 100, "event handler should not be called"
  end

  # The DOM Standard: AbortSignal has "attribute EventHandler onabort". The
  # steps "run the abort steps", step 3: "Fire an event named abort at
  # signal". "Fire an event" makes an event with the type "abort", with the
  # signal as target, with `bubbles` false, and with `isTrusted` true.
  test "the abort event should have the right properties" do
    controller = AbortController.new()
    signal = controller.signal
    test_pid = self()

    set_onabort(signal, fn event -> send(test_pid, {:abort_event, event}) end)

    :ok = AbortController.abort(controller)

    assert_receive {:abort_event, event}
    assert event.type == "abort", "event type should be abort"
    assert event.target == signal, "event target should be signal"
    refute event.bubbles, "event should not bubble"
    assert event.is_trusted, "event should be trusted"
  end

  test "AbortController abort(reason) should set signal.reason" do
    controller = AbortController.new()
    signal = controller.signal

    assert has_reason_property?(), "signal has reason property"
    assert AbortSignal.reason(signal) == nil, "signal.reason is initially undefined"

    reason = %RuntimeError{message: "hello"}
    :ok = AbortController.abort(controller, reason)

    assert AbortSignal.aborted?(signal), "signal.aborted"
    assert AbortSignal.reason(signal) == reason, "signal.reason"
  end

  test "aborting AbortController without reason creates an \"AbortError\" DOMException" do
    controller = AbortController.new()
    signal = controller.signal

    assert has_reason_property?(), "signal has reason property"
    assert AbortSignal.reason(signal) == nil, "signal.reason is initially undefined"

    :ok = AbortController.abort(controller)

    assert AbortSignal.aborted?(signal), "signal.aborted"
    reason = AbortSignal.reason(signal)
    assert is_struct(reason, Web.DOMException), "signal.reason is DOMException"
    assert reason.name == "AbortError", "signal.reason is AbortError"
  end

  # The library: `Web.AbortController.abort(controller, nil)` gives the
  # reason `AbortError` DOMException. The store of the reasons reads `nil`
  # as "no reason". (`Web.AbortSignal.abort(nil)` keeps the reason `nil`.)
  # The DOM Standard, "signal abort", step 2: "Set signal's abort reason to
  # reason if it is given; otherwise to a new "AbortError" DOMException".
  # Here the reason is given, and it is `nil`.
  @tag :wpt_failure
  test "AbortController abort(null) should set signal.reason" do
    controller = AbortController.new()
    signal = controller.signal

    assert has_reason_property?(), "signal has reason property"
    assert AbortSignal.reason(signal) == nil, "signal.reason is initially undefined"

    :ok = AbortController.abort(controller, nil)

    assert AbortSignal.aborted?(signal), "signal.aborted"
    assert AbortSignal.reason(signal) == nil, "signal.reason"
  end

  test "static aborting signal should have right properties" do
    signal = AbortSignal.abort()

    assert AbortSignal.aborted?(signal), "signal.aborted"
    reason = AbortSignal.reason(signal)
    assert is_struct(reason, Web.DOMException), "signal.reason is DOMException"
    assert reason.name == "AbortError", "signal.reason is AbortError"
  end

  test "static aborting signal with reason should set signal.reason" do
    reason = %RuntimeError{message: "hello"}
    signal = AbortSignal.abort(reason)

    assert AbortSignal.aborted?(signal), "signal.aborted"
    assert AbortSignal.reason(signal) == reason, "signal.reason"
  end

  test "throwIfAborted() should throw abort.reason if signal aborted" do
    reason = %RuntimeError{message: "boom"}
    message = reason.message
    signal = AbortSignal.abort(reason)

    assert AbortSignal.aborted?(signal)
    assert catch_error(AbortSignal.throw_if_aborted(signal)) == reason

    assert reason.message == message,
           "abort.reason should not be changed by throwIfAborted()"
  end

  # The DOM Standard, the throwIfAborted() method steps: "throw this's abort
  # reason, if this is aborted". Erlang can raise each term as an error
  # (`:erlang.error/1`), thus the library raises the reason itself.
  test "throwIfAborted() should throw primitive abort.reason if signal aborted" do
    signal = AbortSignal.abort("hello")

    assert AbortSignal.aborted?(signal)
    assert catch_error(AbortSignal.throw_if_aborted(signal)) == "hello"
  end

  test "throwIfAborted() should not throw if signal not aborted" do
    controller = AbortController.new()

    refute AbortSignal.aborted?(controller.signal)
    AbortSignal.throw_if_aborted(controller.signal)
  end

  test "AbortSignal.reason returns the same DOMException" do
    signal = AbortSignal.abort()

    assert is_struct(AbortSignal.reason(signal), Web.DOMException),
           "signal.reason is a DOMException"

    assert AbortSignal.reason(signal) == AbortSignal.reason(signal),
           "signal.reason returns the same DOMException"
  end

  test "AbortController.signal.reason returns the same DOMException" do
    controller = AbortController.new()
    :ok = AbortController.abort(controller)

    assert is_struct(AbortSignal.reason(controller.signal), Web.DOMException),
           "signal.reason is a DOMException"

    assert AbortSignal.reason(controller.signal) == AbortSignal.reason(controller.signal),
           "signal.reason returns the same DOMException"
  end
end
