defmodule Web.StreamRulesTest do
  # Rules of the stream engine for the cases that are not usual: a message
  # that the stream does not know, a process that stops, and a callback
  # that fails.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Web, only: [await: 1]

  alias Web.AbortController
  alias Web.CompressionStream
  alias Web.DecompressionStream
  alias Web.Internal.ReadableStreamTee
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.ReadableStreamDefaultReader
  alias Web.TextEncoderStream
  alias Web.TransformStream
  alias Web.TransformStreamDefaultController
  alias Web.TypeError
  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  defp state(pid), do: ReadableStream.__get_slots__(pid).state

  # A sink that sends each chunk to the test process.
  defp collecting_sink do
    test = self()
    WritableStream.new(%{write: fn chunk, _controller -> send(test, {:written, chunk}) end})
  end

  # ---------------------------------------------------------------------------
  # Messages that the stream does not know
  # ---------------------------------------------------------------------------

  describe "a message that the stream does not know" do
    test "has no effect on a readable stream, also after its close" do
      stream = ReadableStream.new()
      pid = stream.controller_pid

      send(pid, :unknown)
      :gen_statem.cast(pid, :unknown)
      ReadableStream.enqueue(pid, "a")
      ReadableStream.close(pid)

      assert Enum.to_list(stream) == ["a"]

      send(pid, :unknown)
      :gen_statem.cast(pid, :unknown)
      # A close of a stream that is closed.
      ReadableStream.close(pid)

      assert state(pid) == :closed
      # The stream keeps no message that it did not know.
      assert {:message_queue_len, 0} = Process.info(pid, :message_queue_len)
    end

    test "has no effect on a writable stream" do
      stream = WritableStream.new()
      pid = stream.controller_pid

      send(pid, :unknown)
      :gen_statem.cast(pid, :unknown)

      assert WritableStream.desired_size(stream) == 1
      assert :ok = await(WritableStream.close(stream))
    end
  end

  # ---------------------------------------------------------------------------
  # A stream process that stopped
  # ---------------------------------------------------------------------------

  describe "a stream process that stopped" do
    test "needs no terminal event, and a second stop has no effect" do
      stream = ReadableStream.from([1])
      pid = stream.controller_pid

      assert :ok = Web.Stream.stop(pid)
      refute Process.alive?(pid)

      assert :ok = Web.Stream.terminate_and_wait(pid, :cancel, :late)
      assert :ok = Web.Stream.stop(pid)
    end

    test "ends an enumeration that waits for a chunk" do
      stream = ReadableStream.new()
      pid = stream.controller_pid

      reading =
        Task.async(fn ->
          try do
            Enum.to_list(stream)
          rescue
            error -> error
          end
        end)

      eventually(fn -> not :queue.is_empty(ReadableStream.__get_slots__(pid).read_requests) end)
      Process.exit(pid, :kill)

      assert %TypeError{message: "This reader is no longer locked."} = Task.await(reading)
    end

    test "gives a strategy that is not a struct the default strategy" do
      {:ok, pid} = Web.Stream.start_link(ReadableStream, strategy: nil)

      assert ReadableStream.get_desired_size(pid) == 1
      Web.Stream.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # The lifetime
  # ---------------------------------------------------------------------------

  describe "the linger time :infinity" do
    test "is not applicable after the owner stopped" do
      test = self()

      owner =
        spawn(fn ->
          send(test, {:stream, ReadableStream.new(%{}, linger: :infinity)})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:stream, stream}
      pid = stream.controller_pid
      assert ReadableStream.__get_slots__(pid).lifetime_timer == nil

      send(owner, :stop)

      # The stream waits the usual 5 seconds for a process that got it.
      eventually(fn -> ReadableStream.__get_slots__(pid).lifetime_timer == 5_000 end)
      Web.Stream.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # A transform stream
  # ---------------------------------------------------------------------------

  describe "terminate of a transform stream" do
    setup do
      test = self()

      stream =
        TransformStream.new(%{start: fn controller -> send(test, {:controller, controller}) end})

      assert_receive {:controller, controller}

      writer = WritableStream.get_writer(stream.writable)
      reader = ReadableStream.get_reader(stream.readable)

      # After this write, no callback of the stream is in progress.
      write = WritableStreamDefaultWriter.write(writer, "a")
      assert await(ReadableStreamDefaultReader.read(reader)) == %{value: "a", done: false}
      assert :ok = await(write)

      {:ok, stream: stream, controller: controller, writer: writer, reader: reader}
    end

    test "can come from a process that is not a callback", context do
      assert :ok = TransformStreamDefaultController.terminate(context.controller)

      assert await(ReadableStreamDefaultReader.read(context.reader)) == %{value: nil, done: true}

      assert %TypeError{} =
               catch_exit(await(WritableStreamDefaultWriter.write(context.writer, "b")))

      # A second call has no effect.
      assert :ok = TransformStreamDefaultController.terminate(context.controller)
      assert state(context.stream.readable.controller_pid) == :closed
    end

    test "is the effect of a close of the readable side with no check", context do
      ReadableStream.close(context.stream.readable.controller_pid)

      assert await(ReadableStreamDefaultReader.read(context.reader)) == %{value: nil, done: true}
    end
  end

  describe "wait_for_capacity of a transform controller" do
    test "makes a transform with many results wait for the reader" do
      stream =
        TransformStream.new(%{
          transform: fn parts, controller ->
            for part <- parts do
              TransformStreamDefaultController.wait_for_capacity(controller)
              TransformStreamDefaultController.enqueue(controller, part)
            end
          end
        })

      writer = WritableStream.get_writer(stream.writable)
      write = WritableStreamDefaultWriter.write(writer, [1, 2, 3])
      _close = WritableStreamDefaultWriter.close(writer)

      # No process reads: the transform does not fill the queue.
      Process.sleep(30)
      assert ReadableStream.__get_slots__(stream.readable.controller_pid).total_queued_size == 0

      assert Enum.to_list(stream.readable) == [1, 2, 3]
      assert :ok = await(write)
    end
  end

  # ---------------------------------------------------------------------------
  # Callbacks that fail
  # ---------------------------------------------------------------------------

  describe "a callback that fails" do
    test "an abort callback whose process is killed gives a fulfilled abort" do
      stream = WritableStream.new(%{abort: fn _reason -> Process.exit(self(), :kill) end})
      writer = WritableStream.get_writer(stream)

      assert :ok = await(WritableStreamDefaultWriter.abort(writer, :stop))
      assert WritableStream.__get_slots__(stream.controller_pid).state == :errored
    end

    test "a close callback that raises puts the stream in the errored state" do
      stream = WritableStream.new(%{close: fn _controller -> raise "the close failed" end})
      pid = stream.controller_pid

      assert %RuntimeError{message: "the close failed"} =
               catch_exit(await(WritableStream.close(pid)))

      assert WritableStream.__get_slots__(pid).state == :errored
    end

    test "an abort callback that throws gives its value as the rejection reason" do
      stream = WritableStream.new(%{abort: fn _reason -> throw(:the_abort_failed) end})

      assert catch_exit(await(WritableStream.abort(stream.controller_pid, :stop))) ==
               :the_abort_failed
    end

    test "a cancel callback that throws gives its value as the rejection reason" do
      stream = ReadableStream.new(%{cancel: fn _reason -> throw(:the_cancel_failed) end})

      assert catch_exit(await(ReadableStream.cancel(stream.controller_pid, :stop))) ==
               :the_cancel_failed
    end
  end

  # ---------------------------------------------------------------------------
  # A stream from an enumerable
  # ---------------------------------------------------------------------------

  describe "a stream from an enumerable" do
    # An enumerable that tells the test its process, and that waits for
    # `:go` before each element.
    defp gated_enumerable do
      test = self()

      Stream.repeatedly(fn ->
        send(test, {:enumerator, self()})

        receive do
          :go -> 1
        end
      end)
    end

    # The stream has the high water mark 0: the enumerable starts at the
    # first read. The read runs in a task, and the test controls the
    # enumerator.
    defp read_all_later(stream) do
      Task.async(fn ->
        try do
          {:ok, Enum.to_list(stream)}
        rescue
          error -> {:raised, error}
        end
      end)
    end

    test "has the error of an enumerator that is killed" do
      read = read_all_later(ReadableStream.from(gated_enumerable()))
      assert_receive {:enumerator, enumerator}

      # The pull of the stream waits for the enumerator.
      Process.exit(enumerator, :kill)

      assert {:raised, %TypeError{cause: :killed}} = Task.await(read)
    end

    test "ends when its enumerator stopped" do
      read = read_all_later(ReadableStream.from(gated_enumerable()))
      assert_receive {:enumerator, enumerator}

      # The enumerator gives one element, and then it gets the stop.
      send(enumerator, :stop)
      send(enumerator, :go)

      assert Task.await(read) == {:ok, [1]}
    end

    test "stops its enumerator at a cancel" do
      test = self()

      enumerable =
        Stream.resource(
          fn -> :ok end,
          fn acc -> {[1], acc} end,
          fn _acc -> send(test, :enumerable_ended) end
        )

      stream = ReadableStream.from(enumerable)
      assert Enum.take(stream, 2) == [1, 1]

      assert_receive :enumerable_ended
    end
  end

  # ---------------------------------------------------------------------------
  # Pipes
  # ---------------------------------------------------------------------------

  describe "a pipe" do
    test "to a destination that is errored rejects, and cancels the source" do
      test = self()
      sink = WritableStream.new()
      assert :ok = await(WritableStream.abort(sink, :broken))

      source =
        ReadableStream.new(%{
          pull: fn _controller -> :ok end,
          cancel: fn reason -> send(test, {:source_cancelled, reason}) end
        })

      assert catch_exit(await(ReadableStream.pipe_to(source, sink))) == :broken
      assert_receive {:source_cancelled, :broken}
    end

    test "to a destination that is closed rejects with TypeError, and cancels the source" do
      test = self()
      sink = WritableStream.new()
      assert :ok = await(WritableStream.close(sink))

      source =
        ReadableStream.new(%{
          start: fn controller -> ReadableStreamDefaultController.enqueue(controller, "a") end,
          cancel: fn reason -> send(test, {:source_cancelled, reason}) end
        })

      assert %TypeError{} = error = catch_exit(await(ReadableStream.pipe_to(source, sink)))
      assert_receive {:source_cancelled, ^error}
    end

    test "with a signal that aborted with an exception cancels the source and aborts the destination" do
      test = self()
      error = %RuntimeError{message: "the reason of the signal"}

      source =
        ReadableStream.new(%{
          pull: fn _controller -> :ok end,
          cancel: fn reason -> send(test, {:source_cancelled, reason}) end
        })

      sink = WritableStream.new(%{abort: fn reason -> send(test, {:sink_aborted, reason}) end})
      signal = Web.AbortSignal.abort(error)

      assert catch_exit(await(ReadableStream.pipe_to(source, sink, signal: signal))) == error
      assert_receive {:source_cancelled, ^error}
      assert_receive {:sink_aborted, ^error}
    end

    test "with a signal waits for a slow source" do
      controller = AbortController.new()

      source =
        ReadableStream.new(%{
          pull: fn source_controller ->
            # Longer than the time between two checks of the signal.
            Process.sleep(40)
            ReadableStreamDefaultController.enqueue(source_controller, "late")
            ReadableStreamDefaultController.close(source_controller)
          end
        })

      assert :ok =
               await(ReadableStream.pipe_to(source, collecting_sink(), signal: controller.signal))

      assert_received {:written, "late"}
    end

    test "with a signal stops a read that waits when the signal aborts" do
      test = self()
      controller = AbortController.new()

      source =
        ReadableStream.new(%{
          pull: fn _controller -> :ok end,
          cancel: fn reason -> send(test, {:source_cancelled, reason}) end
        })

      sink = WritableStream.new(%{abort: fn reason -> send(test, {:sink_aborted, reason}) end})
      pipe = ReadableStream.pipe_to(source, sink, signal: controller.signal)

      # The read of the pipe waits for a chunk that does not come.
      eventually(fn ->
        {:readable, data} = :sys.get_state(source.controller_pid)
        :queue.len(data.read_requests) == 1
      end)

      # Longer than the time between two checks of the signal.
      Process.sleep(40)
      AbortController.abort(controller, :stop)

      assert catch_exit(await(pipe)) == :stop
      assert_receive {:source_cancelled, :stop}
      assert_receive {:sink_aborted, :stop}
    end

    test "that no process awaits ends with no error report when its destination fails" do
      test = self()
      source = ReadableStream.from(["a", "b"])

      sink =
        WritableStream.new(%{
          write: fn _chunk, _controller ->
            send(test, {:write_started, self()})

            receive do
              :never -> :ok
            end
          end
        })

      log =
        capture_log(fn ->
          destination = %{readable: ReadableStream.new(), writable: sink}
          _readable = ReadableStream.pipe_through(source, destination)
          assert_receive {:write_started, write_process}

          # The pipe waits for the write. The destination stops with a
          # failure that is not a usual stop.
          Process.exit(sink.controller_pid, :the_destination_failed)
          Process.exit(write_process, :kill)

          eventually(fn -> not ReadableStream.locked?(source) end)
          Process.sleep(30)
        end)

      refute log =~ "terminating"
    end
  end

  # ---------------------------------------------------------------------------
  # Tee
  # ---------------------------------------------------------------------------

  describe "a tee" do
    test "whose process stopped has a complete cancel" do
      {:ok, tee} = ReadableStreamTee.start(ReadableStream.new().controller_pid)
      Process.exit(tee, :kill)
      eventually(fn -> not Process.alive?(tee) end)

      assert :ok = await(ReadableStreamTee.cancel(tee, 1, :late))
    end
  end

  # ---------------------------------------------------------------------------
  # Streams of text and of compressed data
  # ---------------------------------------------------------------------------

  describe "a text encoder stream" do
    test "can be cancelled" do
      stream = TextEncoderStream.new()
      writer = WritableStream.get_writer(stream.writable)

      assert :ok = await(ReadableStream.cancel(stream.readable, :stop))
      assert catch_exit(await(WritableStreamDefaultWriter.write(writer, "late"))) == :stop
    end
  end

  describe "a compression stream and a decompression stream" do
    test "refuse a chunk that is a list" do
      for module <- [CompressionStream, DecompressionStream] do
        stream = module.new("gzip")
        writer = WritableStream.get_writer(stream.writable)
        reader = ReadableStream.get_reader(stream.readable)
        _read = ReadableStreamDefaultReader.read(reader)

        assert %TypeError{message: message} =
                 catch_exit(await(WritableStreamDefaultWriter.write(writer, [1, 2])))

        assert message =~ "chunk must be a binary, a Uint8Array, or an ArrayBuffer"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # A cluster
  # ---------------------------------------------------------------------------

  describe "a stream on a different node" do
    @describetag :cluster

    test "gets a cancel as a usual message" do
      {_peer, node} = Web.TestCluster.start_peer()

      # An agent on the second node makes the stream, and it is its owner.
      {:ok, agent} = :erpc.call(node, Agent, :start, [ReadableStream, :new, []])
      stream = :erpc.call(node, Agent, :get, [agent, Function, :identity, []])
      pid = stream.controller_pid
      assert node(pid) == node
      assert :erpc.call(node, ReadableStream, :__get_slots__, [pid]).state == :readable

      # A priority message needs the alias of a process of this node.
      assert :ok = await(ReadableStream.cancel(stream, :remote_stop))
      assert :erpc.call(node, ReadableStream, :__get_slots__, [pid]).state == :closed
    end
  end

  describe "the abort of an ambient signal" do
    defp ambient_stream(controller) do
      test = self()

      Web.AsyncContext.with_signal(controller.signal, fn ->
        ReadableStream.new(%{
          start: fn stream_controller -> send(test, {:controller, stream_controller}) end
        })
      end)
    end

    test "errors a closed stream that has chunks, and discards them" do
      controller = AbortController.new()
      stream = ambient_stream(controller)
      assert_receive {:controller, stream_controller}

      ReadableStreamDefaultController.enqueue(stream_controller, "kept")
      ReadableStreamDefaultController.close(stream_controller)
      AbortController.abort(controller, :stop)

      reader = ReadableStream.get_reader(stream)
      assert catch_exit(await(ReadableStreamDefaultReader.read(reader))) == :stop
    end

    test "has no effect on a stream that closed and gave its last chunk" do
      controller = AbortController.new()
      stream = ambient_stream(controller)
      assert_receive {:controller, stream_controller}

      ReadableStreamDefaultController.enqueue(stream_controller, "read")
      ReadableStreamDefaultController.close(stream_controller)
      reader = ReadableStream.get_reader(stream)
      assert %{value: "read"} = await(ReadableStreamDefaultReader.read(reader))

      AbortController.abort(controller, :late)

      assert %{done: true} = await(ReadableStreamDefaultReader.read(reader))
      assert ReadableStream.__get_slots__(stream.controller_pid).state == :closed
    end
  end
end
