defmodule Web.PipeRulesTest do
  # The rules of ReadableStreamPipeTo in the Streams Standard: the
  # propagation of a close and of an error in the two directions, the
  # options `preventClose`, `preventAbort`, and `preventCancel`, the signal,
  # the shutdown, and the flow control. The sink and the source tell the test
  # each call, and the sink waits for the test before it completes a write.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.AbortController
  alias Web.AbortSignal
  alias Web.Internal.ReadableStreamPipe
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController, as: Source
  alias Web.TypeError
  alias Web.WritableStream
  alias Web.WritableStreamDefaultController, as: Sink
  alias Web.WritableStreamDefaultWriter, as: Writer

  defp rejection(promise), do: catch_exit(await(promise))

  # A source with no chunks. The test gets its controller.
  defp source(test, extra \\ %{}) do
    stream =
      ReadableStream.new(
        Map.merge(
          %{
            start: fn controller -> send(test, {:source, controller}) end,
            cancel: fn reason -> send(test, {:cancel, reason}) end
          },
          extra
        ),
        high_water_mark: 0
      )

    assert_receive {:source, controller}
    {stream, controller}
  end

  # A sink that waits for `{:result, value}` before it completes a write.
  # The test gets its controller.
  defp sink(test, extra \\ %{}) do
    stream =
      WritableStream.new(
        Map.merge(
          %{
            start: fn controller -> send(test, {:sink, controller}) end,
            write: fn chunk, _controller ->
              send(test, {:write, self(), chunk})

              receive do
                {:result, {:throw, reason}} -> throw(reason)
                {:result, value} -> value
              end
            end,
            close: fn _controller -> send(test, :close) end,
            abort: fn reason -> send(test, {:abort, reason}) end
          },
          extra
        )
      )

    assert_receive {:sink, controller}
    {stream, controller}
  end

  defp slots(%ReadableStream{controller_pid: pid}), do: ReadableStream.__get_slots__(pid)
  defp slots(%WritableStream{controller_pid: pid}), do: WritableStream.__get_slots__(pid)

  # The process of the pipe holds the reader lock of the source.
  defp pipe_process(source), do: eventually(fn -> slots(source).reader_pid end)

  # The pipe waits for the promise `ready` of the destination.
  defp waits_for_ready(dest),
    do: eventually(fn -> not :queue.is_empty(slots(dest).ready_waiters) end)

  # The pipe waits for a read of the source.
  defp waits_for_read(source),
    do: eventually(fn -> not :queue.is_empty(slots(source).read_requests) end)

  defp eventually(fun, attempts \\ 400) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _no ->
        if attempts == 0, do: flunk("the condition did not become true")
        Process.sleep(5)
        eventually(fun, attempts - 1)
    end
  end

  # Waits until the mailbox of the suspended process `pid` has a message for
  # which `fun` gives true.
  defp in_mailbox(pid, fun) do
    eventually(fn ->
      {:messages, messages} = Process.info(pid, :messages)
      Enum.any?(messages, fun)
    end)
  end

  defp pending?(promise), do: Web.Promise.peek(promise) == :pending

  # The source handled the requests of the test, and the process of the pipe
  # handled the messages of the source. The call to the source comes after
  # the requests of this process, and the messages of the source to the pipe
  # come before its answer.
  defp settled(source, pipe_pid) do
    _ = slots(source)
    idle(pipe_pid)
  end

  # The process of the pipe handled each message that it has: it stopped, or
  # it waits in its loop, or for the answer of an action, with no message. A
  # process that waits for a call to a stream is not idle.
  defp idle(pid) do
    eventually(fn ->
      case Process.info(pid, [:current_function, :message_queue_len]) do
        nil ->
          true

        [current_function: {ReadableStreamPipe, name, _arity}, message_queue_len: 0] ->
          name in [:loop, :collect, :await_steps]

        _busy ->
          false
      end
    end)
  end

  # A sink whose abort callback tells the test, and returns when the test
  # sends `:return`.
  defp waiting_abort(test) do
    %{
      abort: fn reason ->
        send(test, {:abort, self(), reason})

        receive do
          :return -> :ok
        end
      end
    }
  end

  describe "closing must be propagated backward" do
    test "a destination that is closed cancels the source, and the pipe rejects with a TypeError" do
      test = self()
      {source, _controller} = source(test)
      {dest, _sink} = sink(test)
      writer = WritableStream.get_writer(dest)
      assert :ok = await(Writer.close(writer))
      assert :ok = Writer.release_lock(writer)

      assert %TypeError{} = error = rejection(ReadableStream.pipe_to(source, dest))
      assert_received {:cancel, ^error}
      refute WritableStream.locked?(dest)
      refute ReadableStream.locked?(source)
    end

    test "a close in flight is a close, and preventCancel keeps the source" do
      test = self()
      {source, _controller} = source(test)

      {dest, _sink} =
        sink(test, %{
          close: fn _controller ->
            send(test, {:close, self()})

            receive do
              :continue -> :ok
            end
          end
        })

      writer = WritableStream.get_writer(dest)
      close = Writer.close(writer)
      assert_receive {:close, sink_worker}
      assert :ok = Writer.release_lock(writer)

      pipe = ReadableStream.pipe_to(source, dest, preventCancel: true)
      assert %TypeError{} = rejection(pipe)
      refute_received {:cancel, _reason}

      send(sink_worker, :continue)
      assert :ok = await(close)
    end
  end

  describe "errors must be propagated backward" do
    test "an error of the destination cancels the source while no chunk comes" do
      test = self()
      {source, _controller} = source(test)
      {dest, sink} = sink(test)

      pipe = ReadableStream.pipe_to(source, dest)
      waits_for_read(source)

      assert :ok = Sink.error(sink, :boom)
      assert rejection(pipe) == :boom
      assert_received {:cancel, :boom}
    end

    test "with preventCancel, the pipe rejects and keeps the source" do
      test = self()
      {source, _controller} = source(test)
      {dest, sink} = sink(test)

      pipe = ReadableStream.pipe_to(source, dest, preventCancel: true)
      waits_for_read(source)

      assert :ok = Sink.error(sink, :boom)
      assert rejection(pipe) == :boom
      refute_received {:cancel, _reason}
      refute ReadableStream.locked?(source)
    end

    test "a rejection of the cancel is the result of the pipe" do
      test = self()
      {source, _controller} = source(test, %{cancel: fn _reason -> throw(:cancel_failed) end})
      {dest, sink} = sink(test)

      pipe = ReadableStream.pipe_to(source, dest)
      waits_for_read(source)

      assert :ok = Sink.error(sink, :boom)
      assert rejection(pipe) == :cancel_failed
    end
  end

  describe "a destination that wants no chunk" do
    test "gets the close of the source" do
      test = self()
      {source, controller} = source(test)
      {dest, _sink} = sink(test, %{high_water_mark: 0})

      pipe = ReadableStream.pipe_to(source, dest)
      waits_for_ready(dest)

      assert :ok = Source.close(controller)
      assert await(pipe) == :ok
      assert_received :close
    end

    test "gets the abort for an error of the source, unless preventAbort" do
      for prevent_abort <- [false, true] do
        test = self()
        {source, controller} = source(test)
        {dest, _sink} = sink(test, %{high_water_mark: 0})

        pipe = ReadableStream.pipe_to(source, dest, preventAbort: prevent_abort)
        waits_for_ready(dest)

        assert :ok = Source.error(controller, :boom)
        assert rejection(pipe) == :boom

        if prevent_abort,
          do: refute_received({:abort, _reason}),
          else: assert_received({:abort, :boom})
      end
    end
  end

  describe "the result of the pipe" do
    test "is the rejection of the abort of the destination" do
      test = self()
      {source, controller} = source(test)
      {dest, _sink} = sink(test, %{abort: fn _reason -> throw(:abort_failed) end})

      pipe = ReadableStream.pipe_to(source, dest)
      waits_for_read(source)

      assert :ok = Source.error(controller, :boom)
      assert rejection(pipe) == :abort_failed
    end

    test "is the rejection of the close of the destination" do
      test = self()
      {source, controller} = source(test)
      {dest, _sink} = sink(test, %{close: fn _controller -> throw(:close_failed) end})

      pipe = ReadableStream.pipe_to(source, dest)
      waits_for_read(source)

      assert :ok = Source.close(controller)
      assert rejection(pipe) == :close_failed
    end

    test "is the error of a destination that is errored when the source closes" do
      test = self()
      {source, controller} = source(test)
      {dest, sink} = sink(test)

      pipe = ReadableStream.pipe_to(source, dest)
      pipe_pid = pipe_process(source)
      assert :ok = Source.enqueue(controller, "a")
      assert_receive {:write, worker, "a"}
      waits_for_ready(dest)

      # The pipe gets the close of the source before the error of the
      # destination. The destination is errored when the pipe closes it.
      :erlang.suspend_process(pipe_pid)
      assert :ok = Source.close(controller)
      in_mailbox(pipe_pid, &match?({_tag, :ok}, &1))

      send(worker, {:result, :ok})
      eventually(fn -> slots(dest).pending_write_request == nil end)
      assert :ok = Sink.error(sink, :boom)
      in_mailbox(pipe_pid, &match?({_tag, {:error, {:errored, :boom}}}, &1))
      :erlang.resume_process(pipe_pid)

      assert rejection(pipe) == :boom
      refute_received :close
    end
  end

  describe "the shutdown" do
    test "waits for the writes in progress, and reads no chunk after it starts" do
      test = self()
      {source, controller} = source(test)
      {dest, _sink} = sink(test, %{high_water_mark: 3})

      pipe = ReadableStream.pipe_to(source, dest, preventAbort: true)
      pipe_pid = pipe_process(source)
      assert :ok = Source.enqueue(controller, "a")
      assert_receive {:write, worker, "a"}
      waits_for_read(source)

      assert :ok = Source.error(controller, :boom)
      settled(source, pipe_pid)
      assert pending?(pipe)

      send(worker, {:result, :ok})
      assert rejection(pipe) == :boom
      refute_received {:abort, _reason}
    end

    test "does not wait for the writes of a destination that is erroring" do
      test = self()
      {source, controller} = source(test)
      {dest, sink} = sink(test)

      pipe = ReadableStream.pipe_to(source, dest)
      pipe_pid = pipe_process(source)
      assert :ok = Source.enqueue(controller, "a")
      assert_receive {:write, worker, "a"}

      assert :ok = Sink.error(sink, :dest_boom)
      eventually(fn -> slots(dest).state == :erroring end)
      assert :ok = Source.error(controller, :boom)
      settled(source, pipe_pid)

      # The abort of an erroring stream rejects with its stored error when
      # the write is complete.
      send(worker, {:result, :ok})
      assert rejection(pipe) == :dest_boom
      refute_received {:abort, _reason}
    end

    test "ignores the promise ready that fulfils while it waits for the writes" do
      test = self()
      {source, controller} = source(test)
      {dest, _sink} = sink(test, %{high_water_mark: 2})

      pipe = ReadableStream.pipe_to(source, dest, preventAbort: true)
      pipe_pid = pipe_process(source)
      assert :ok = Source.enqueue(controller, "a")
      assert_receive {:write, worker, "a"}
      assert :ok = Source.enqueue(controller, "b")
      waits_for_ready(dest)

      assert :ok = Source.error(controller, :boom)
      settled(source, pipe_pid)
      send(worker, {:result, :ok})
      assert_receive {:write, worker, "b"}
      idle(pipe_pid)
      assert pending?(pipe)

      send(worker, {:result, :ok})
      assert rejection(pipe) == :boom
    end
  end

  describe "the flow control" do
    test "reads while the destination wants chunks, with no wait for the writes" do
      test = self()
      {source, controller} = source(test)
      {dest, _sink} = sink(test, %{high_water_mark: 3})
      for chunk <- 1..5, do: Source.enqueue(controller, chunk)

      pipe = ReadableStream.pipe_to(source, dest)
      assert_receive {:write, worker, 1}

      # The writes 2 and 3 wait in the queue of the destination. The pipe
      # reads no more chunks.
      waits_for_ready(dest)
      assert :queue.len(slots(source).queue) == 2
      assert slots(dest).queued_write_count == 2
      send(worker, {:result, :ok})

      for chunk <- 2..5 do
        assert_receive {:write, ^worker, ^chunk}
        send(worker, {:result, :ok})
      end

      assert :ok = Source.close(controller)
      assert await(pipe) == :ok
    end

    property "the destination gets each chunk in sequence, and never more than it wants" do
      check all(
              chunks <- list_of(integer(), max_length: 12),
              high_water_mark <- integer(1..4),
              max_runs: 30
            ) do
        test = self()

        dest =
          WritableStream.new(%{
            high_water_mark: high_water_mark,
            write: fn chunk, controller ->
              send(test, {:written, chunk, Sink.desired_size(controller)})
            end
          })

        assert :ok = await(ReadableStream.pipe_to(ReadableStream.from(chunks), dest))

        for chunk <- chunks do
          assert_received {:written, ^chunk, desired_size}
          assert desired_size >= 0
        end
      end
    end

    test "a read in progress gives the last chunk after the close of the source" do
      test = self()
      {source, controller} = source(test)
      {dest, _sink} = sink(test)

      pipe = ReadableStream.pipe_to(source, dest)
      assert :ok = Source.enqueue(controller, "a")
      assert_receive {:write, worker, "a"}
      waits_for_ready(dest)

      # The close of the source comes to the pipe before the answer of the
      # read, which has the last chunk.
      :erlang.suspend_process(source.controller_pid)
      ReadableStream.enqueue(source.controller_pid, "b")
      ReadableStream.close(source.controller_pid)
      send(worker, {:result, :ok})
      in_mailbox(source.controller_pid, &match?({:"$gen_call", _from, {:read, _owner}}, &1))
      :erlang.resume_process(source.controller_pid)

      assert_receive {:write, worker, "b"}
      send(worker, {:result, :ok})
      assert await(pipe) == :ok
      assert_received :close
    end
  end

  describe "the signal" do
    test "aborts the destination and cancels the source, and gives the first failure of the actions" do
      test = self()

      {source, _controller} =
        source(test, %{cancel: fn reason -> throw({:cancel_failed, reason}) end})

      {dest, _sink} = sink(test, %{abort: fn reason -> throw({:abort_failed, reason}) end})
      abort_controller = AbortController.new()

      pipe = ReadableStream.pipe_to(source, dest, signal: abort_controller.signal)
      waits_for_read(source)

      assert :ok = AbortController.abort(abort_controller, :stop)
      assert rejection(pipe) == {:abort_failed, :stop}
    end

    test "with no abort of the destination, gives the failure of the cancel" do
      test = self()

      {source, _controller} =
        source(test, %{cancel: fn reason -> throw({:cancel_failed, reason}) end})

      {dest, _sink} = sink(test)
      abort_controller = AbortController.new()

      pipe =
        ReadableStream.pipe_to(source, dest, signal: abort_controller.signal, preventAbort: true)

      waits_for_read(source)

      assert :ok = AbortController.abort(abort_controller, :stop)
      assert rejection(pipe) == {:cancel_failed, :stop}
      refute_received {:abort, _reason}
    end

    test "aborted before the pipe aborts only a destination that is writable" do
      test = self()
      {source, _controller} = source(test)
      {dest, sink} = sink(test)

      # The destination is erroring: a write is in flight.
      writer = WritableStream.get_writer(dest)
      write = Writer.write(writer, "a")
      assert_receive {:write, worker, "a"}
      assert :ok = Sink.error(sink, :dest_boom)
      assert :ok = Writer.release_lock(writer)

      pipe = ReadableStream.pipe_to(source, dest, signal: AbortSignal.abort(:stop))
      assert rejection(pipe) == :stop
      assert_received {:cancel, :stop}

      send(worker, {:result, :ok})
      assert await(write) == :ok
      refute_received {:abort, _reason}
    end

    test "can be a process: its stop is the abort, with its exit reason" do
      test = self()
      {source, _controller} = source(test)
      {dest, _sink} = sink(test)
      signal = spawn(fn -> receive(do: (:stop -> exit(:signal_stopped))) end)

      pipe = ReadableStream.pipe_to(source, dest, signal: signal)
      waits_for_read(source)

      send(signal, :stop)
      assert rejection(pipe) == :signal_stopped
      assert_received {:cancel, :signal_stopped}
      assert_received {:abort, :signal_stopped}
    end

    test "can be a process that sends the abort" do
      test = self()
      {source, _controller} = source(test)
      {dest, _sink} = sink(test)
      signal = spawn(fn -> Process.sleep(:infinity) end)

      pipe = ReadableStream.pipe_to(source, dest, signal: signal)
      send(pipe_process(source), {:abort, signal, :sent_reason})
      assert rejection(pipe) == :sent_reason
      Process.exit(signal, :kill)
    end

    test "that stops with no abort aborts the pipe with an AbortError" do
      test = self()
      {source, _controller} = source(test)
      {dest, _sink} = sink(test)
      abort_controller = AbortController.new()

      pipe = ReadableStream.pipe_to(source, dest, signal: abort_controller.signal)
      waits_for_read(source)

      Process.exit(abort_controller.signal.pid, :kill)
      assert %Web.DOMException{name: "AbortError"} = rejection(pipe)
    end

    test "a message that is not of the signal has no effect" do
      test = self()
      {source, controller} = source(test)
      {dest, _sink} = sink(test)

      pipe = ReadableStream.pipe_to(source, dest, signal: :pipe_token)
      pipe_pid = pipe_process(source)
      send(pipe_pid, {:abort, :other_token, :other_reason})
      send(pipe_pid, {:abort, :other_token})

      assert :ok = Source.close(controller)
      assert await(pipe) == :ok
    end
  end

  # The abort algorithm of the signal does WritableStreamAbort of the
  # destination, and then ReadableStreamCancel of the source. The sink gets
  # its abort before the source gets its cancel, when the destination can
  # abort at once. See "The abort action of a pipe" in `Web.Stream`.
  describe "the sequence of the actions of the signal" do
    test "the source gets its cancel when the abort callback of the sink returned" do
      test = self()
      {source, _controller} = source(test)
      {dest, _sink} = sink(test, waiting_abort(test))
      abort_controller = AbortController.new()

      pipe = ReadableStream.pipe_to(source, dest, signal: abort_controller.signal)
      pipe_pid = pipe_process(source)
      waits_for_read(source)

      assert :ok = AbortController.abort(abort_controller, :stop)
      assert_receive {:abort, worker, :stop}

      # The pipe waits for the answer of the destination, and it sent no
      # cancel. The call to the source comes after the requests of the pipe.
      idle(pipe_pid)
      assert slots(source).state == :readable
      refute_received {:cancel, _reason}

      send(worker, :return)
      assert_receive {:cancel, :stop}
      assert rejection(pipe) == :stop
    end

    test "the source gets its cancel while the promise of the abort callback is pending" do
      test = self()
      {source, _controller} = source(test)

      abort = fn reason ->
        {promise, resolve, _reject} = Web.Promise.with_resolvers()
        send(test, {:abort, resolve, reason})
        promise
      end

      {dest, _sink} = sink(test, %{abort: abort})

      pipe = ReadableStream.pipe_to(source, dest, signal: AbortSignal.abort(:stop))
      assert_receive {:abort, resolve, :stop}
      assert_receive {:cancel, :stop}
      assert pending?(pipe)

      resolve.(:ok)
      assert rejection(pipe) == :stop
    end

    test "a destination that did not start: the source gets its cancel first" do
      test = self()
      {source, _controller} = source(test)
      {start, resolve, _reject} = Web.Promise.with_resolvers()

      dest =
        WritableStream.new(%{
          start: fn _controller -> start end,
          abort: fn reason -> send(test, {:abort, reason}) end
        })

      pipe = ReadableStream.pipe_to(source, dest, signal: AbortSignal.abort(:stop))
      assert_receive {:cancel, :stop}
      refute_received {:abort, _reason}

      # The abort of the sink waits for the start, as in the Standard.
      resolve.(:ok)
      assert rejection(pipe) == :stop
      assert_received {:abort, :stop}
    end

    test "a destination with a write in flight: the source gets its cancel first" do
      test = self()
      {source, _controller} = source(test)
      {dest, _sink} = sink(test)

      writer = WritableStream.get_writer(dest)
      write = Writer.write(writer, "a")
      assert_receive {:write, worker, "a"}
      assert :ok = Writer.release_lock(writer)

      pipe = ReadableStream.pipe_to(source, dest, signal: AbortSignal.abort(:stop))
      assert_receive {:cancel, :stop}
      refute_received {:abort, _reason}

      # The abort of the sink waits for the write in flight.
      send(worker, {:result, :ok})
      assert await(write) == :ok
      assert rejection(pipe) == :stop
      assert_received {:abort, :stop}
    end

    test "a destination that stops during its abort callback: the pipe cancels the source" do
      test = self()
      {source, _controller} = source(test)
      {dest, _sink} = sink(test, waiting_abort(test))

      pipe = ReadableStream.pipe_to(source, dest, signal: AbortSignal.abort(:stop))
      assert_receive {:abort, _worker, :stop}

      Process.exit(dest.controller_pid, :kill)
      assert_receive {:cancel, :stop}
      assert rejection(pipe) == :stop
    end

    test "an abort callback that does not return: the source gets its cancel after the time limit" do
      test = self()
      {source, _controller} = source(test)
      sink = %{abort: fn _reason -> receive(do: (:never -> :ok)) end}
      {:ok, dest} = WritableStream.start_link(underlying_sink: sink, timeout_ms: 50)

      pipe = ReadableStream.pipe_to(source, dest, signal: AbortSignal.abort(:stop))
      assert %TypeError{cause: {:task_timeout, :abort}} = rejection(pipe)
      assert_received {:cancel, :stop}
    end

    test "an abort callback that returns after its time limit sends no notice to the pipe" do
      test = self()

      {source, _controller} =
        source(test, %{
          cancel: fn reason ->
            send(test, {:cancel, self(), reason})
            receive(do: (:return -> :ok))
          end
        })

      {:ok, dest} = WritableStream.start_link(underlying_sink: waiting_abort(test))

      pipe = ReadableStream.pipe_to(source, dest, signal: AbortSignal.abort(:stop))
      pipe_pid = pipe_process(source)
      assert_receive {:abort, worker, :stop}

      # The time limit ends before the stream gets the return of the
      # callback: the stream answers the pipe first. The test sends the
      # message of the timer of the callback.
      task_ref = WritableStream.__get_slots__(dest).task_ref
      true = :erlang.suspend_process(dest)
      send(dest, {:task_timeout, task_ref})
      send(worker, :return)
      in_mailbox(dest, &match?({:abort_callback_returned, _from}, &1))
      true = :erlang.resume_process(dest)

      # The pipe got the answer, and then cancelled the source. It has no
      # message while it waits for the cancel.
      assert_receive {:cancel, cancel_worker, :stop}
      idle(pipe_pid)
      assert {:messages, []} = Process.info(pipe_pid, :messages)

      send(cancel_worker, :return)
      assert %TypeError{cause: {:task_timeout, :abort}} = rejection(pipe)
    end
  end

  describe "a stream that stops" do
    test "the destination: the pipe cancels the source" do
      test = self()
      {source, _controller} = source(test)
      {dest, _sink} = sink(test)

      pipe = ReadableStream.pipe_to(source, dest)
      waits_for_read(source)

      Process.exit(dest.controller_pid, :kill)
      assert %TypeError{} = error = rejection(pipe)
      assert_received {:cancel, ^error}
    end

    test "the destination while the shutdown waits for the writes" do
      test = self()
      {source, controller} = source(test)
      {dest, _sink} = sink(test)

      pipe = ReadableStream.pipe_to(source, dest)
      pipe_pid = pipe_process(source)
      assert :ok = Source.enqueue(controller, "a")
      assert_receive {:write, _worker, "a"}

      assert :ok = Source.error(controller, :boom)
      settled(source, pipe_pid)
      assert pending?(pipe)

      Process.exit(dest.controller_pid, :kill)
      assert rejection(pipe) == :boom
    end

    test "the destination while the abort of the signal waits for the writes" do
      test = self()
      {source, controller} = source(test)
      {dest, _sink} = sink(test)
      abort_controller = AbortController.new()

      pipe = ReadableStream.pipe_to(source, dest, signal: abort_controller.signal)
      pipe_pid = pipe_process(source)
      assert :ok = Source.enqueue(controller, "a")
      assert_receive {:write, _worker, "a"}

      assert :ok = AbortController.abort(abort_controller, :stop)
      settled(source, pipe_pid)
      assert pending?(pipe)

      # The destination stopped: the pipe only cancels the source.
      Process.exit(dest.controller_pid, :kill)
      assert rejection(pipe) == :stop
      assert_received {:cancel, :stop}
      refute_received {:abort, _reason}
    end

    test "the destination before the close of the source: a stopped destination is closed" do
      test = self()
      {source, controller} = source(test)
      {dest, _sink} = sink(test)

      pipe = ReadableStream.pipe_to(source, dest)
      pipe_pid = pipe_process(source)
      waits_for_read(source)
      idle(pipe_pid)

      # The pipe gets the close of the source before the stop of the
      # destination: it closes a destination that is not there.
      true = :erlang.suspend_process(pipe_pid)
      assert :ok = Source.close(controller)
      _ = slots(source)
      in_mailbox(pipe_pid, &match?({ref, _reply} when is_reference(ref), &1))

      Process.exit(dest.controller_pid, :kill)
      in_mailbox(pipe_pid, &match?({:DOWN, _ref, :process, _pid, :killed}, &1))
      true = :erlang.resume_process(pipe_pid)

      assert await(pipe) == :ok
      refute_received :close
    end

    test "the source: the pipe aborts the destination" do
      test = self()
      {source, _controller} = source(test)
      {dest, _sink} = sink(test)

      pipe = ReadableStream.pipe_to(source, dest)
      waits_for_read(source)

      Process.exit(source.controller_pid, :kill)
      assert %TypeError{} = error = rejection(pipe)
      assert_received {:abort, ^error}
    end
  end

  describe "a transform stream as the destination" do
    test "with a cancelled readable side cancels the source with the reason" do
      test = self()
      {source, _controller} = source(test)
      transform = Web.TransformStream.new()
      assert :ok = await(ReadableStream.cancel(transform.readable, :gone))

      assert rejection(ReadableStream.pipe_to(source, transform.writable)) == :gone
      assert_received {:cancel, :gone}
    end
  end
end
