defmodule Web.WritableStreamAbortListenerTest do
  # WritableStreamAbort signals abort on the signal of the controller in its
  # step 2. The listeners of the signal run at once, before the steps that
  # change the stream, thus a listener that aborts or closes the stream
  # again gets the result of the Streams Standard. A public abort runs the
  # listeners in the calling process. See "The abort of a writable stream by
  # a public function" in `Web.Stream`.
  use ExUnit.Case, async: true

  import Web, only: [await: 1]

  alias Web.AbortSignal
  alias Web.EventTarget
  alias Web.TypeError
  alias Web.WritableStream
  alias Web.WritableStreamDefaultController, as: Controller
  alias Web.WritableStreamDefaultWriter, as: Writer

  defp rejection(promise), do: catch_exit(await(promise))

  # A stream, its controller, and the signal of its controller. With
  # `started: false`, the function `start` of the sink returns a promise
  # that the test resolves with the function `resolve`.
  defp stream(test, opts \\ []) do
    {start, resolve, _reject} = Web.Promise.with_resolvers()
    started = Keyword.get(opts, :started, true)

    sink = %{
      start: fn controller ->
        send(test, {:controller, controller})
        if started, do: :ok, else: start
      end,
      close: fn _controller -> send(test, :close) end,
      abort: fn reason -> send(test, {:abort, reason}) end
    }

    stream = WritableStream.new(sink)
    assert_receive {:controller, controller}

    # The stream handled the end of `start`.
    if started, do: eventually(fn -> slots(stream.controller_pid).active_operation == nil end)

    %{
      stream: stream,
      controller: controller,
      signal: Controller.signal(controller),
      resolve: resolve
    }
  end

  defp listen(signal, fun), do: EventTarget.add_event_listener(signal, "abort", fun)

  defp slots(pid), do: WritableStream.__get_slots__(pid)

  defp eventually(fun) do
    if fun.() do
      :ok
    else
      Process.sleep(1)
      eventually(fun)
    end
  end

  describe "an abort from a listener of the signal" do
    test "of a stream that started: the stream has the reason of the listener" do
      test = self()
      %{stream: stream, signal: signal} = stream(test)
      writer = WritableStream.get_writer(stream)
      listen(signal, fn -> send(test, {:inner, Writer.abort(writer, :e2)}) end)

      outer = Writer.abort(writer, :e1)
      assert_received {:inner, inner}
      assert AbortSignal.reason(signal) == :e1

      assert await(outer) == :ok
      assert await(inner) == :ok
      assert rejection(Writer.closed(writer)) == :e2
      assert_received {:abort, :e2}
      refute_received {:abort, :e1}
    end

    test "of a stream that did not start: the two aborts have the reason of the listener" do
      test = self()
      %{stream: stream, signal: signal, resolve: resolve} = stream(test, started: false)
      writer = WritableStream.get_writer(stream)
      listen(signal, fn -> send(test, {:inner, Writer.abort(writer, :e2)}) end)

      outer = Writer.abort(writer, :e1)
      assert_received {:inner, inner}
      assert slots(stream.controller_pid).state == :erroring

      resolve.(:ok)
      assert await(outer) == :ok
      assert await(inner) == :ok
      assert rejection(Writer.closed(writer)) == :e2
      assert_received {:abort, :e2}
    end
  end

  describe "a close from a listener of the signal" do
    test "of a stream that started: the close is in flight, and it completes" do
      test = self()
      %{stream: stream, signal: signal} = stream(test)
      writer = WritableStream.get_writer(stream)
      listen(signal, fn -> send(test, {:close, Writer.close(writer)}) end)

      abort = Writer.abort(writer, :e)
      assert_received {:close, close}

      assert await(abort) == :ok
      assert await(close) == :ok
      assert await(Writer.closed(writer)) == :ok
      assert_received :close
      refute_received {:abort, _reason}
    end

    test "of a stream that did not start: the close waits, and rejects with the reason" do
      test = self()
      %{stream: stream, signal: signal, resolve: resolve} = stream(test, started: false)
      writer = WritableStream.get_writer(stream)
      listen(signal, fn -> send(test, {:close, Writer.close(writer)}) end)

      abort = Writer.abort(writer, :e)
      assert_received {:close, close}

      resolve.(:ok)
      assert await(abort) == :ok
      assert rejection(close) == :e
      assert rejection(Writer.closed(writer)) == :e
      assert_received {:abort, :e}
      refute_received :close
    end

    test "comes before the abort, also when the stream has messages to handle" do
      test = self()
      %{stream: stream, signal: signal} = stream(test)
      pid = stream.controller_pid
      writer = WritableStream.get_writer(stream)

      # The listener sends the close to a stream that is suspended. The
      # process that suspends the stream lets it continue when the next
      # request of the abort comes.
      listen(signal, fn ->
        listener = self()

        spawn(fn ->
          true = :erlang.suspend_process(pid)
          send(listener, :suspended)
          resume_at_next_request(pid)
        end)

        assert_receive :suspended
        send(test, {:close, Writer.close(writer)})
      end)

      abort = Writer.abort(writer, :e)
      assert_received {:close, close}

      assert await(abort) == :ok
      assert await(close) == :ok
      assert_received :close
    end
  end

  # Lets the suspended stream continue when it has a request of the abort
  # after the close of the listener.
  defp resume_at_next_request(pid) do
    {:messages, messages} = Process.info(pid, :messages)

    if Enum.any?(messages, &next_request?/1) do
      true = :erlang.resume_process(pid)
    else
      Process.sleep(1)
      resume_at_next_request(pid)
    end
  end

  defp next_request?({:"$gen_call", _from, request}),
    do: request == :handled or match?({:abort_rest, _window, _abort}, request)

  defp next_request?(_message), do: false

  describe "the results of the callbacks during the listeners" do
    test "a write that stops when the signal aborts: the sink gets its abort after the write" do
      test = self()

      write = fn _chunk, controller ->
        worker = self()
        pid = controller.pid

        # The listener runs in the process that aborts. It waits until the
        # stream has the result of the write.
        listen(Controller.signal(controller), fn ->
          send(worker, :stop)
          eventually(fn -> has_result?(slots(pid)) end)
        end)

        send(test, :writing)

        receive do
          :stop -> throw(:stopped)
        end
      end

      stream =
        WritableStream.new(%{write: write, abort: fn reason -> send(test, {:abort, reason}) end})

      writer = WritableStream.get_writer(stream)
      write = Writer.write(writer, "a")
      assert_receive :writing

      abort = Writer.abort(writer, :e)
      assert rejection(write) == :stopped
      assert await(abort) == :ok
      assert_received {:abort, :e}
      assert rejection(Writer.closed(writer)) == :e
    end
  end

  # The stream keeps the result of a callback, or it handled it.
  defp has_result?(%{abort_window: %{held: [_ | _]}}), do: true
  defp has_result?(%{state: state}), do: state == :errored

  describe "a caller that stops" do
    test "in a listener: the stream does the abort with no caller" do
      test = self()
      %{stream: stream, signal: signal} = stream(test)
      writer = WritableStream.get_writer(stream)
      listen(signal, fn -> Process.exit(self(), :kill) end)

      {pid, monitor} = spawn_monitor(fn -> Writer.abort(writer, :e) end)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

      assert rejection(Writer.closed(writer)) == :e
      assert_received {:abort, :e}
      assert AbortSignal.reason(signal) == :e
    end
  end

  describe "a caller that stops after an error of the stream" do
    test "in a listener: the stream does no abort" do
      test = self()
      %{stream: stream, controller: controller, signal: signal} = stream(test)
      pid = stream.controller_pid
      writer = WritableStream.get_writer(stream)

      listen(signal, fn ->
        :ok = Controller.error(controller, :boom)
        eventually(fn -> slots(pid).state == :errored end)
        Process.exit(self(), :kill)
      end)

      {caller, monitor} = spawn_monitor(fn -> Writer.abort(writer, :e) end)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}

      assert rejection(Writer.closed(writer)) == :boom
      eventually(fn -> slots(pid).abort_window == nil end)
      refute_received {:abort, _reason}
    end
  end

  describe "a stream that stops" do
    test "while the caller waits for its state: the abort gets the result of a stopped stream" do
      test = self()
      %{stream: stream} = stream(test)
      pid = stream.controller_pid
      writer = WritableStream.get_writer(stream)

      true = :erlang.suspend_process(pid)
      writer_abort = Task.async(fn -> rejection(Writer.abort(writer, :e)) end)
      stream_abort = Task.async(fn -> await(WritableStream.abort(stream, :e)) end)
      eventually(fn -> requests(pid, {:abort_first_steps, :_, :e}) == 2 end)
      Process.exit(pid, :kill)

      assert %TypeError{} = Task.await(writer_abort)
      assert Task.await(stream_abort) == :ok
    end
  end

  # The number of requests in the mailbox of `pid` that match `pattern`.
  defp requests(pid, {name, _owner, reason}) do
    {:messages, messages} = Process.info(pid, :messages)

    Enum.count(messages, fn
      {:"$gen_call", _from, {:as_writer, _lock, {^name, _pid, ^reason}}} -> true
      {:"$gen_call", _from, {^name, nil, ^reason}} -> true
      _other -> false
    end)
  end

  describe "step 1 of WritableStreamAbort, and the lock" do
    test "an abort of a closed stream does not abort the signal" do
      test = self()
      %{stream: stream, signal: signal} = stream(test)
      listen(signal, fn -> send(test, :listener) end)
      writer = WritableStream.get_writer(stream)
      assert await(Writer.close(writer)) == :ok

      assert await(Writer.abort(writer, :late)) == :ok
      refute AbortSignal.aborted?(signal)
      refute_received :listener
    end

    test "an abort of an errored stream does not abort the signal" do
      test = self()
      %{stream: stream, controller: controller, signal: signal} = stream(test)
      listen(signal, fn -> send(test, :listener) end)
      assert :ok = Controller.error(controller, :boom)

      assert await(WritableStream.abort(stream, :late)) == :ok
      refute AbortSignal.aborted?(signal)
      refute_received :listener
    end

    test "an abort of a locked stream rejects, and does not abort the signal" do
      test = self()
      %{stream: stream, signal: signal} = stream(test)
      listen(signal, fn -> send(test, :listener) end)
      _writer = WritableStream.get_writer(stream)

      assert %TypeError{message: "Cannot abort a locked stream."} =
               rejection(WritableStream.abort(stream, :e))

      refute AbortSignal.aborted?(signal)
      refute_received :listener
    end

    test "an abort of a writer that released its lock rejects, and does not abort the signal" do
      test = self()
      %{stream: stream, signal: signal} = stream(test)
      listen(signal, fn -> send(test, :listener) end)
      writer = WritableStream.get_writer(stream)
      assert :ok = Writer.release_lock(writer)

      assert %TypeError{} = rejection(Writer.abort(writer, :e))
      refute AbortSignal.aborted?(signal)
      refute_received :listener
    end
  end

  describe "a stream on a different node" do
    @describetag :cluster

    test "gets the abort with no wait: the caller cannot read the dictionary of the stream" do
      {_peer, node} = Web.TestCluster.start_peer()
      {:ok, agent} = :erpc.call(node, Agent, :start, [WritableStream, :new, []])
      stream = :erpc.call(node, Agent, :get, [agent, Function, :identity, []])
      assert node(stream.controller_pid) == node

      assert await(WritableStream.abort(stream, :remote_stop)) == :ok

      assert :erpc.call(node, WritableStream, :__get_slots__, [stream.controller_pid]).state ==
               :errored
    end
  end
end
