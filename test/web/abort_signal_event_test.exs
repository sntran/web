defmodule Web.AbortSignalEventTest do
  # A signal is an event target: the event `abort`, the event handler
  # `onabort`, and the signals of `AbortSignal.any/1` that depend on a
  # signal.
  use ExUnit.Case, async: true

  alias Web.AbortController
  alias Web.AbortSignal
  alias Web.Event
  alias Web.EventTarget

  defp listen(signal, name) do
    me = self()

    EventTarget.add_event_listener(signal, "abort", fn event ->
      send(
        me,
        {name, event.type, event.target, event.is_trusted, AbortSignal.reason(event.target)}
      )
    end)
  end

  defp names do
    receive do
      {name, "abort", _target, _trusted, _reason} -> [name | names()]
    after
      0 -> []
    end
  end

  defp assert_down(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 2_000
  end

  test "an abort fires a trusted event abort at the signal before abort/2 returns" do
    controller = AbortController.new()
    signal = controller.signal
    assert listen(signal, :listener) == signal

    :ok = AbortController.abort(controller, :why)
    assert_received {:listener, "abort", ^signal, true, :why}

    # A second abort fires no event, and the process of the signal stops.
    :ok = AbortController.abort(controller, :again)
    refute_received {:listener, _type, _target, _trusted, _reason}
    assert_down(signal.pid)
  end

  test "onabort/2 sets and removes the event handler, in its place among the listeners" do
    controller = AbortController.new()
    signal = controller.signal
    me = self()
    handler = fn -> send(me, {:handler, "abort", nil, nil, nil}) end

    listen(signal, :first)
    assert AbortSignal.onabort(signal) == nil
    assert AbortSignal.onabort(signal, handler) == signal
    assert AbortSignal.onabort(signal) == handler
    listen(signal, :last)

    # A new handler keeps the place of the first one.
    handler = fn -> send(me, {:new_handler, "abort", nil, nil, nil}) end
    AbortSignal.onabort(signal, handler)
    assert AbortSignal.onabort(signal) == handler

    :ok = AbortController.abort(controller)
    assert names() == [:first, :new_handler, :last]
  end

  test "onabort/2 with nil removes the handler" do
    controller = AbortController.new()
    me = self()
    AbortSignal.onabort(controller.signal, fn -> send(me, :handler) end)
    AbortSignal.onabort(controller.signal, nil)

    :ok = AbortController.abort(controller)
    refute_received :handler
  end

  test "a signal with no process has no event handler" do
    signal = AbortSignal.abort()

    assert AbortSignal.onabort(signal, fn -> :ok end) == signal
    assert AbortSignal.onabort(signal) == nil
    assert listen(signal, :listener) == signal
    assert EventTarget.remove_event_listener(signal, "abort", fn -> :ok end) == signal
    assert {^signal, true} = EventTarget.dispatch_event(signal, Event.new("abort"))
  end

  test "dispatch_event/2 runs the listeners of the signal" do
    signal = AbortController.new().signal
    listen(signal, :listener)

    assert {^signal, true} = EventTarget.dispatch_event(signal, Event.new("abort"))
    # An event of dispatch_event/2 is not trusted.
    assert_received {:listener, "abort", ^signal, false, nil}
    refute AbortSignal.aborted?(signal)
  end

  test "during the event, the signal is aborted and gives its reason" do
    controller = AbortController.new()
    signal = controller.signal
    me = self()

    EventTarget.add_event_listener(signal, "abort", fn ->
      send(me, {
        AbortSignal.subscribe(signal),
        AbortSignal.aborted?(signal),
        AbortSignal.reason(signal),
        AbortSignal.__add_algorithm__(signal, {Kernel, :send, [me, :algorithm]}),
        GenServer.call(signal.pid, :sources),
        GenServer.call(signal.pid, {:add_dependent, AbortController.new().signal})
      })
    end)

    :ok = AbortController.abort(controller, :why)
    assert_received {{:error, :aborted}, true, :why, :aborted, {:ok, nil}, {:aborted, :why}}
    refute_received :algorithm
  end

  test "the protocol removes a listener of a signal and of a target" do
    me = self()
    listener = fn -> send(me, :listener) end

    for object <- [AbortController.new().signal, EventTarget.new()] do
      object = EventTarget.add_event_listener(object, "x", listener)
      assert Web.EventTarget.Protocol.remove_event_listener(object, "x", listener) == object
      assert {^object, true} = EventTarget.dispatch_event(object, Event.new("x"))
      refute_received :listener
    end
  end

  test "an abort algorithm runs before the event" do
    controller = AbortController.new()
    me = self()
    :ok = AbortSignal.__add_algorithm__(controller.signal, {Kernel, :send, [me, :algorithm]})
    listen(controller.signal, :listener)

    :ok = AbortController.abort(controller)
    assert_received :algorithm
    assert names() == [:listener]

    # A signal that aborted takes no algorithm.
    assert AbortSignal.__add_algorithm__(controller.signal, {Kernel, :send, [me, :x]}) ==
             :aborted

    assert AbortSignal.__add_algorithm__(AbortSignal.abort(), {Kernel, :send, [me, :x]}) ==
             :aborted
  end

  test "the process that aborts the signal stops: the signal stops" do
    controller = AbortController.new()
    signal = controller.signal

    EventTarget.add_event_listener(signal, "abort", fn -> Process.exit(self(), :kill) end)
    {pid, monitor} = spawn_monitor(fn -> AbortController.abort(controller, :why) end)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    assert_down(signal.pid)
    assert AbortSignal.reason(signal) == :why
  end

  # A writable stream whose controller signal has the listener `listener`.
  defp stream_with_listener(listener) do
    me = self()

    stream =
      Web.WritableStream.new(%{
        start: fn controller ->
          signal = Web.WritableStreamDefaultController.signal(controller)
          EventTarget.add_event_listener(signal, "abort", listener)
          send(me, {:signal, signal})
        end
      })

    assert_receive {:signal, signal}
    {stream, signal}
  end

  test "a public abort of a writable stream runs the listeners in the calling process" do
    me = self()
    {stream, signal} = stream_with_listener(fn -> send(me, {:listener, self()}) end)

    promise = Web.WritableStream.abort(stream, :why)
    # The listener ran before the abort returned.
    assert_received {:listener, ^me}
    assert AbortSignal.reason(signal) == :why
    assert Web.Promise.await(promise) == :ok
  end

  test "the process of a stream aborts its signal for an abort of the library, and a new process runs the listeners" do
    me = self()

    # The listener waits, then calls the stream. If the process of the
    # stream ran the listener, the stream could not answer.
    {stream, signal} =
      stream_with_listener(fn ->
        send(me, {:listener, self()})

        receive do
          {:call, pid} -> send(me, {:locked, Web.WritableStream.locked?(pid)})
        end
      end)

    # A pipe with a signal that aborted aborts the stream.
    source = Web.ReadableStream.new()
    pipe = Web.ReadableStream.pipe_to(source, stream, signal: AbortSignal.abort(:why))
    assert_receive {:listener, listener}
    refute listener in [me, stream.controller_pid]
    assert AbortSignal.aborted?(signal)
    assert AbortSignal.reason(signal) == :why

    send(listener, {:call, stream.controller_pid})
    assert_receive {:locked, _locked}
    assert catch_exit(Web.Promise.await(pipe)) == :why

    assert AbortSignal.__signal_abort_later__(AbortSignal.abort(), :x) == :ok
    assert AbortSignal.__signal_abort__(AbortSignal.abort(), :x) == :ok
  end

  describe "AbortSignal.any/1" do
    test "the dependent signals abort before the listeners of the source run" do
      controller = AbortController.new()
      source = controller.signal
      first = AbortSignal.any([source])
      second = AbortSignal.any([first, source])
      me = self()

      EventTarget.add_event_listener(source, "abort", fn ->
        send(me, {:in_source, AbortSignal.aborted?(first), AbortSignal.aborted?(second)})
      end)

      listen(second, :second)
      listen(first, :first)
      listen(source, :source)

      :ok = AbortController.abort(controller, :why)
      assert_received {:in_source, true, true}
      assert names() == [:source, :first, :second]
      assert AbortSignal.reason(second) == :why
    end

    test "a dependent signal depends on the sources of a dependent signal" do
      controller = AbortController.new()
      first = AbortSignal.any([controller.signal, controller.signal])
      second = AbortSignal.any([first])

      assert :sys.get_state(second.pid).sources == [controller.signal]
      assert :sys.get_state(controller.signal.pid).dependents == [first, second]
    end

    test "a reentrant abort of a second source does not abort the dependent signal again" do
      first = AbortController.new()
      second = AbortController.new()
      signal = AbortSignal.any([first.signal, second.signal])

      EventTarget.add_event_listener(first.signal, "abort", fn ->
        AbortController.abort(second, :second)
      end)

      listen(signal, :signal)
      :ok = AbortController.abort(first, :first)

      assert names() == [:signal]
      assert AbortSignal.reason(signal) == :first
    end

    test "a source that aborted when the signal is added aborts the signal" do
      source = %AbortSignal{pid: spawn_link(fn -> fake_source({:aborted, :late}) end)}
      signal = AbortSignal.any([source])

      assert AbortSignal.aborted?(signal)
      assert AbortSignal.reason(signal) == :late
    end

    test "a source that stops when the signal is added aborts the signal if it aborted" do
      source = %AbortSignal{pid: spawn(fn -> fake_source(:stop) end), ref: make_ref()}
      signal = AbortSignal.any([source])

      assert AbortSignal.aborted?(signal)
      assert %Web.DOMException{name: "AbortError"} = AbortSignal.reason(signal)
    end

    test "a dependent signal that stopped before the abort of its source" do
      controller = AbortController.new()
      source = controller.signal
      dependent = AbortSignal.any([source])
      listen(source, :source)

      # The source gets the abort before the stop of the dependent signal:
      # it asks the dependent signal, which stopped, to abort.
      :erlang.suspend_process(source.pid)
      aborter = spawn(fn -> AbortController.abort(controller) end)
      await_queue(source.pid, 1)
      Process.exit(dependent.pid, :kill)
      await_queue(source.pid, 2)
      monitor = Process.monitor(aborter)
      :erlang.resume_process(source.pid)

      assert_receive {:DOWN, ^monitor, :process, ^aborter, :normal}
      assert AbortSignal.aborted?(source)
    end

    test "a source that stops before the signal is added" do
      source = %AbortSignal{pid: spawn(fn -> fake_source(:exit_at_sources) end), ref: make_ref()}
      signal = AbortSignal.any([source])

      assert AbortSignal.aborted?(signal)
    end
  end

  describe "AbortSignal.timeout/1" do
    # `timeout/1` gives the timer the earlier timeouts of the process. The
    # test sends the message of the timer itself: thus no time limit is in
    # the test.
    test "a new process runs the listeners, after the earlier timeouts of the process" do
      me = self()
      first = AbortController.new()
      second = AbortController.new()

      EventTarget.add_event_listener(second.signal, "abort", fn event ->
        send(me, {:second, AbortSignal.reason(event.target)})
      end)

      # The time of the second signal is complete, but the first signal did
      # not abort yet: the second one waits for it.
      :erlang.trace(second.signal.pid, true, [:procs])
      send(second.signal.pid, {:abort_signal_timeout, :timeout, [first.signal.pid]})
      assert_receive {:trace, _signal, :spawn, waiter, _call}
      await_function(waiter, {AbortSignal, :await_stop, 1})
      refute AbortSignal.aborted?(second.signal)

      :ok = AbortController.abort(first)
      assert_receive {:second, :timeout}
    end
  end

  defp await_queue(pid, length, attempts \\ 200) do
    cond do
      Process.info(pid, :message_queue_len) == {:message_queue_len, length} -> :ok
      attempts == 0 -> flunk("the queue of the process does not have #{length} messages")
      true -> Process.sleep(5) && await_queue(pid, length, attempts - 1)
    end
  end

  defp await_function(pid, function, attempts \\ 200) do
    cond do
      Process.info(pid, :current_function) == {:current_function, function} -> :ok
      attempts == 0 -> flunk("the process does not wait in #{inspect(function)}")
      true -> Process.sleep(5) && await_function(pid, function, attempts - 1)
    end
  end

  # A process with the role of the process of a source signal.
  defp fake_source(add_dependent_reply) do
    receive do
      {:"$gen_call", from, {:subscribe, _pid}} ->
        GenServer.reply(from, :ok)
        fake_source(add_dependent_reply)

      {:"$gen_cast", {:unsubscribe, _pid}} ->
        fake_source(add_dependent_reply)

      {:"$gen_call", _from, :sources} when add_dependent_reply == :exit_at_sources ->
        exit(:normal)

      {:"$gen_call", from, :sources} ->
        GenServer.reply(from, {:ok, nil})
        fake_source(add_dependent_reply)

      {:"$gen_call", _from, {:add_dependent, _signal}} when add_dependent_reply == :stop ->
        exit(:normal)

      {:"$gen_call", from, {:add_dependent, _signal}} ->
        GenServer.reply(from, add_dependent_reply)
        fake_source(add_dependent_reply)
    end
  end
end
