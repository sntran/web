defmodule Web.TransformStreamTest do
  # The behaviour of a transform stream that the Streams Standard specifies.
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Web

  import ExUnit.CaptureLog

  alias Web.ReadableStreamDefaultReader, as: Reader
  alias Web.TransformStreamDefaultController, as: Controller
  alias Web.WritableStreamDefaultWriter, as: Writer

  defp rejection(promise), do: catch_exit(await(promise))
  defp slots(transform), do: ReadableStream.__get_slots__(transform.readable.controller_pid)

  # Writes the chunks and closes, with no await.
  defp write_all(transform, chunks) do
    writer = WritableStream.get_writer(transform.writable)
    writes = Enum.map(chunks, &Writer.write(writer, &1))
    {writer, writes, Writer.close(writer)}
  end

  describe "new/2" do
    test "gives a struct with the two sides, which have the default limits of the Standard" do
      transform = TransformStream.new()

      assert %TransformStream{readable: %ReadableStream{}, writable: %WritableStream{}} =
               transform

      assert slots(transform).readable_desired_size == 0
      assert slots(transform).writable_desired_size == 1
    end

    test "accepts a strategy for each side" do
      transform =
        TransformStream.new(%{},
          writable_strategy: CountQueuingStrategy.new(3),
          readable_strategy: CountQueuingStrategy.new(7)
        )

      assert slots(transform).writable_desired_size == 3
      assert slots(transform).readable_desired_size == 7
      assert slots(TransformStream.new(%{}, high_water_mark: 4)).writable_desired_size == 4
    end

    test "refuses a transformer that is not valid" do
      # The call is not correct for the type checker too, thus the test makes
      # it at run time.
      assert_raise TypeError, ~r/must be a map/, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(TransformStream, :new, [:nope])
      end

      for {name, bad} <- [
            start: fn -> :ok end,
            transform: fn _chunk -> :ok end,
            flush: :nope,
            cancel: fn _reason, _extra -> :ok end
          ] do
        assert_raise TypeError, ~r/must be a function/, fn ->
          TransformStream.new(%{name => bad})
        end
      end

      for key <- [:readable_type, :writable_type] do
        assert_raise Web.RangeError, ~r/is not permitted/, fn ->
          TransformStream.new(%{key => "bytes"})
        end
      end
    end

    test "throws the value that the function start throws, and writes no crash report" do
      log =
        capture_log(fn ->
          assert_raise RuntimeError, "start failed", fn ->
            TransformStream.new(%{start: fn _controller -> raise "start failed" end})
          end

          assert catch_throw(TransformStream.new(%{start: fn _controller -> throw(:thrown) end})) ==
                   :thrown

          assert catch_exit(TransformStream.new(%{start: fn _controller -> exit(:stopped) end})) ==
                   :stopped
        end)

      assert log == ""
    end

    test "does not wait for a promise that the function start returns" do
      test = self()
      {started, resolve, _reject} = Promise.with_resolvers()

      transform =
        TransformStream.new(%{
          start: fn _controller -> started end,
          transform: fn chunk, controller ->
            send(test, {:transform, chunk})
            Controller.enqueue(controller, chunk)
          end
        })

      # The constructor returned, and the promise is pending. The write and
      # the read wait for it.
      writer = WritableStream.get_writer(transform.writable)
      reader = ReadableStream.get_reader(transform.readable)
      write = Writer.write(writer, :chunk)
      read = Reader.read(reader)
      refute_receive {:transform, _chunk}, 50
      assert Promise.peek(write) == :pending

      resolve.(:ok)
      assert await(read) == %{value: :chunk, done: false}
      assert await(write) == :ok
      assert_received {:transform, :chunk}
    end

    test "goes to the errored state when the promise of the function start rejects" do
      {started, _resolve, reject} = Promise.with_resolvers()
      transform = TransformStream.new(%{start: fn _controller -> started end})

      writer = WritableStream.get_writer(transform.writable)
      reader = ReadableStream.get_reader(transform.readable)
      write = Writer.write(writer, :chunk)
      read = Reader.read(reader)

      reject.(:start_failed)
      assert rejection(write) == :start_failed
      assert rejection(read) == :start_failed
      assert rejection(Writer.closed(writer)) == :start_failed
    end

    test "runs the function start in the process that makes the stream" do
      test = self()

      transform =
        TransformStream.new(%{
          start: fn controller ->
            send(test, {:start, self(), Controller.desired_size(controller)})
          end
        })

      # The controller is usable in `start`: the readable side has the limit 0.
      assert_received {:start, ^test, 0}
      assert %TransformStream{} = transform
    end

    test "lets the function start put chunks in the queue" do
      transform =
        TransformStream.new(%{
          start: fn controller -> Controller.enqueue(controller, "first") end
        })

      {_writer, _writes, _close} = write_all(transform, ["second"])
      assert Enum.to_list(transform.readable) == ["first", "second"]
    end
  end

  describe "the backpressure" do
    test "holds each write until a process reads, and does not start its transform" do
      test = self()

      transform =
        TransformStream.new(%{
          transform: fn chunk, controller ->
            send(test, {:transformed, chunk})
            Controller.enqueue(controller, chunk)
          end
        })

      writer = WritableStream.get_writer(transform.writable)
      writes = for index <- 1..50, do: Writer.write(writer, index)
      ready = Writer.ready(writer)

      Process.sleep(100)
      assert Enum.all?([ready | writes], &(Promise.peek(&1) == :pending))
      assert :queue.len(slots(transform).queue) == 0
      refute_received {:transformed, _chunk}
      assert Writer.desired_size(writer) < 0

      # One read lets one write continue.
      reader = ReadableStream.get_reader(transform.readable)
      assert await(Reader.read(reader)) == %{value: 1, done: false}
      assert await(hd(writes)) == :ok
      assert_receive {:transformed, 1}
      Process.sleep(50)
      refute_received {:transformed, 2}
      assert Promise.peek(Enum.at(writes, 1)) == :pending
    end

    test "lets the transform run for the limit of the readable side with no reader" do
      transform = TransformStream.new(%{}, readable_strategy: CountQueuingStrategy.new(3))
      writer = WritableStream.get_writer(transform.writable)
      writes = for index <- 1..5, do: Writer.write(writer, index)

      Process.sleep(100)

      assert Enum.map(writes, &Promise.peek/1) ==
               [{:fulfilled, :ok}, {:fulfilled, :ok}, {:fulfilled, :ok}, :pending, :pending]

      assert :queue.len(slots(transform).queue) == 3
    end

    test "does not hold the close: the function flush runs with no reader" do
      test = self()
      transform = TransformStream.new(%{flush: fn _controller -> send(test, :flushed) end})

      writer = WritableStream.get_writer(transform.writable)
      assert await(Writer.close(writer)) == :ok
      assert_received :flushed
      assert Enum.to_list(transform.readable) == []
    end

    property "keeps the queue of the readable side at its limit, and loses no chunk" do
      check all(
              chunks <- list_of(integer(), max_length: 40),
              limit <- integer(0..4),
              max_runs: 40
            ) do
        transform = TransformStream.new(%{}, readable_strategy: CountQueuingStrategy.new(limit))
        {_writer, writes, close} = write_all(transform, chunks)
        reader = ReadableStream.get_reader(transform.readable)

        read =
          Enum.map(chunks, fn _chunk ->
            assert :queue.len(slots(transform).queue) <= max(limit, 1)
            await(Reader.read(reader)).value
          end)

        assert read == chunks
        assert await(Reader.read(reader)) == %{value: nil, done: true}
        assert Enum.map(writes, &await/1) == Enum.map(chunks, fn _chunk -> :ok end)
        assert await(close) == :ok
      end
    end

    test "goes through a pipe: a source with no end is read only for the reader" do
      counter = :counters.new(1, [])

      source =
        ReadableStream.new(%{
          pull: fn controller ->
            :counters.add(counter, 1, 1)
            ReadableStreamDefaultController.enqueue(controller, :counters.get(counter, 1))
          end
        })

      result =
        source
        |> ReadableStream.pipe_through(TransformStream.new())
        |> ReadableStream.pipe_through(TransformStream.new())

      Process.sleep(150)
      pulled_with_no_reader = :counters.get(counter, 1)
      assert pulled_with_no_reader <= 6

      assert Enum.take(result, 3) == [1, 2, 3]
      Process.sleep(100)
      assert :counters.get(counter, 1) <= pulled_with_no_reader + 6
    end
  end

  describe "the controller" do
    test "is a TransformStreamDefaultController, and gives the desired size of the readable side" do
      test = self()

      transform =
        TransformStream.new(
          %{
            transform: fn chunk, controller ->
              send(test, {:controller, controller, Controller.desired_size(controller)})
              Controller.enqueue(controller, chunk)
            end
          },
          readable_strategy: CountQueuingStrategy.new(2)
        )

      {_writer, _writes, _close} = write_all(transform, ["a"])
      assert Enum.to_list(transform.readable) == ["a"]
      assert_received {:controller, %Controller{}, 2}
    end

    test "accepts the functions of the readable stream controller also" do
      transform =
        TransformStream.new(%{
          transform: fn chunk, controller ->
            ReadableStreamDefaultController.enqueue(controller, String.upcase(chunk))
          end
        })

      {_writer, _writes, _close} = write_all(transform, ["a", "b"])
      assert Enum.to_list(transform.readable) == ["A", "B"]
    end

    test "can give zero chunks, or many chunks, for one chunk" do
      transform =
        TransformStream.new(%{
          transform: fn count, controller ->
            for index <- 1..count//1, do: Controller.enqueue(controller, {count, index})
            :ok
          end
        })

      {_writer, _writes, _close} = write_all(transform, [0, 2, 0, 3])
      assert Enum.to_list(transform.readable) == [{2, 1}, {2, 2}, {3, 1}, {3, 2}, {3, 3}]
    end

    test "terminate closes the readable side and stops the writable side" do
      transform =
        TransformStream.new(%{
          transform: fn chunk, controller ->
            Controller.enqueue(controller, chunk)
            if chunk == :last, do: Controller.terminate(controller)
          end
        })

      writer = WritableStream.get_writer(transform.writable)
      writes = Enum.map([:first, :last, :late], &Writer.write(writer, &1))

      assert Enum.to_list(transform.readable) == [:first, :last]
      assert [:ok, :ok] = Enum.map(Enum.take(writes, 2), &await/1)
      assert %TypeError{} = rejection(Enum.at(writes, 2))
      assert %TypeError{} = rejection(Writer.write(writer, :later))
    end

    test "terminate puts the writable side in the errored state with a TypeError" do
      transform =
        TransformStream.new(%{
          transform: fn _chunk, controller -> Controller.terminate(controller) end
        })

      writer = WritableStream.get_writer(transform.writable)
      closed = Writer.closed(writer)
      write = Writer.write(writer, :chunk)
      late = Writer.write(writer, :late)
      close = Writer.close(writer)

      assert Enum.to_list(transform.readable) == []
      assert await(write) == :ok

      # The write that waited, the close that waited, and the promises of
      # the writer reject with the same error.
      error = rejection(late)
      assert %TypeError{message: "The transform stream was terminated."} = error
      assert rejection(close) == error
      assert rejection(closed) == error
      assert rejection(Writer.closed(writer)) == error
      assert rejection(Writer.ready(writer)) == error
      assert Writer.desired_size(writer) == nil

      # The readable side is closed, not errored.
      reader = ReadableStream.get_reader(transform.readable)
      assert await(Reader.closed(reader)) == :ok
      assert await(Reader.read(reader)) == %{value: nil, done: true}
    end

    test "terminate in the function flush does not prevent the close" do
      transform =
        TransformStream.new(%{flush: fn controller -> Controller.terminate(controller) end})

      {writer, [write], close} = write_all(transform, [:chunk])

      assert Enum.to_list(transform.readable) == [:chunk]
      assert await(write) == :ok
      assert await(close) == :ok
      assert await(Writer.closed(writer)) == :ok
    end

    test "enqueue raises a TypeError after terminate, and the write rejects with it" do
      transform =
        TransformStream.new(%{
          transform: fn chunk, controller ->
            Controller.enqueue(controller, chunk)
            Controller.terminate(controller)
            Controller.enqueue(controller, :late)
          end
        })

      writer = WritableStream.get_writer(transform.writable)
      write = Writer.write(writer, :chunk)

      # The readable side is closed with the chunk that came before the
      # terminate. It is not errored.
      assert Enum.to_list(transform.readable) == [:chunk]

      assert %TypeError{message: "Cannot enqueue a chunk: the stream is closed."} =
               rejection(write)

      assert %TypeError{message: "The transform stream was terminated."} =
               rejection(Writer.closed(writer))
    end

    test "enqueue raises a TypeError after a cancel of the readable side" do
      test = self()

      transform =
        TransformStream.new(%{start: fn controller -> send(test, {:controller, controller}) end})

      assert_receive {:controller, controller}
      assert await(ReadableStream.cancel(transform.readable, :stop)) == :ok
      assert_raise TypeError, fn -> Controller.enqueue(controller, :late) end
    end

    test "enqueue raises a TypeError in the function start after terminate or error" do
      for ended <- [&Controller.terminate/1, &Controller.error(&1, :failed)] do
        assert_raise TypeError, fn ->
          TransformStream.new(%{
            start: fn controller ->
              ended.(controller)
              Controller.enqueue(controller, :late)
            end
          })
        end
      end
    end

    test "a close of the readable side in the function start is a terminate" do
      assert_raise TypeError, "Cannot enqueue a chunk: the stream is closed.", fn ->
        TransformStream.new(%{
          start: fn controller ->
            ReadableStreamDefaultController.close(controller)
            Controller.enqueue(controller, :late)
          end
        })
      end

      transform =
        TransformStream.new(%{
          start: fn controller -> ReadableStreamDefaultController.close(controller) end
        })

      assert Enum.to_list(transform.readable) == []
    end

    test "terminate rejects a process that waits for the writable side with a message" do
      transform =
        TransformStream.new(%{start: fn controller -> Controller.terminate(controller) end})

      assert Enum.to_list(transform.readable) == []
      writer = WritableStream.get_writer(transform.writable)

      assert {:error, {:errored, %TypeError{message: "The transform stream was terminated."}}} =
               WritableStream.ready(writer.controller_pid, writer.owner_pid)
    end

    test "terminate in the function start gives a stream with no chunks" do
      transform =
        TransformStream.new(%{start: fn controller -> Controller.terminate(controller) end})

      assert Enum.to_list(transform.readable) == []
      writer = WritableStream.get_writer(transform.writable)
      assert %TypeError{} = rejection(Writer.write(writer, :late))
    end

    test "error puts the two sides in the errored state" do
      transform =
        TransformStream.new(%{
          transform: fn _chunk, controller -> Controller.error(controller, :failed) end
        })

      writer = WritableStream.get_writer(transform.writable)
      reader = ReadableStream.get_reader(transform.readable)
      read = Reader.read(reader)
      Writer.write(writer, 1)

      assert rejection(read) == :failed
      assert rejection(Writer.write(writer, 2)) == :failed
      assert rejection(Writer.closed(writer)) == :failed
    end
  end

  describe "an error" do
    test "that transform throws goes to the two sides, with the thrown value" do
      for {callback, expected} <- [
            {fn _chunk, _controller -> raise "transform failed" end,
             %RuntimeError{message: "transform failed"}},
            {fn _chunk, _controller -> throw(:thrown) end, :thrown},
            {fn _chunk, _controller -> Promise.reject(:rejected) end, :rejected}
          ] do
        transform = TransformStream.new(%{transform: callback})
        writer = WritableStream.get_writer(transform.writable)
        read = Reader.read(ReadableStream.get_reader(transform.readable))

        assert rejection(Writer.write(writer, 1)) == expected
        assert rejection(read) == expected
        assert rejection(Writer.write(writer, 2)) == expected
      end
    end

    test "that flush throws rejects the close, and the read" do
      transform = TransformStream.new(%{flush: fn _controller -> raise "flush failed" end})
      writer = WritableStream.get_writer(transform.writable)

      assert %RuntimeError{message: "flush failed"} = rejection(Writer.close(writer))

      assert %RuntimeError{message: "flush failed"} =
               rejection(Reader.read(ReadableStream.get_reader(transform.readable)))
    end
  end

  describe "a cancel of the readable side" do
    test "calls the function cancel with the reason, and errors the writable side" do
      test = self()
      transform = TransformStream.new(%{cancel: fn reason -> send(test, {:cancel, reason}) end})
      writer = WritableStream.get_writer(transform.writable)
      held = Writer.write(writer, :held)

      assert await(ReadableStream.cancel(transform.readable, :no_interest)) == :ok
      assert_received {:cancel, :no_interest}

      # The write that waited, and each later write, reject with the reason.
      assert rejection(held) == :no_interest
      assert rejection(Writer.write(writer, :late)) == :no_interest
      assert %TypeError{} = rejection(Writer.close(writer))

      # The promises of the writer reject with the reason also. A pipe reads
      # `ready` before each write, and gives this reason to its source.
      assert rejection(Writer.ready(writer)) == :no_interest
      assert rejection(Writer.closed(writer)) == :no_interest

      assert WritableStream.ready(writer.controller_pid, writer.owner_pid) ==
               {:error, {:errored, :no_interest}}
    end

    test "stops a pipe, and cancels the source of the pipe with the reason" do
      test = self()

      source =
        ReadableStream.new(%{
          pull: fn controller -> ReadableStreamDefaultController.enqueue(controller, :chunk) end,
          cancel: fn reason -> send(test, {:source_cancelled, reason}) end
        })

      result = ReadableStream.pipe_through(source, TransformStream.new())
      reader = ReadableStream.get_reader(result)
      assert await(Reader.read(reader)).value == :chunk

      assert await(Reader.cancel(reader, :enough)) == :ok
      assert_receive {:source_cancelled, :enough}, 1_000
    end
  end

  describe "an abort of the writable side" do
    test "calls the function cancel with the reason, and errors the readable side" do
      test = self()
      transform = TransformStream.new(%{cancel: fn reason -> send(test, {:cancel, reason}) end})
      writer = WritableStream.get_writer(transform.writable)

      assert await(Writer.abort(writer, :stop)) == :ok
      assert_received {:cancel, :stop}
      assert rejection(Reader.read(ReadableStream.get_reader(transform.readable))) == :stop
    end

    test "of the stream object gives the same reason to the function cancel" do
      test = self()
      transform = TransformStream.new(%{cancel: fn reason -> send(test, {:cancel, reason}) end})

      assert await(WritableStream.abort(transform.writable, :stop)) == :ok
      assert_received {:cancel, :stop}
    end
  end

  describe "the sequence of the calls" do
    test "is one transform at a time, in the sequence of the writes, and then flush" do
      test = self()

      transform =
        TransformStream.new(
          %{
            transform: fn chunk, controller ->
              send(test, {:start, chunk})
              Process.sleep(10)
              send(test, {:end, chunk})
              Controller.enqueue(controller, chunk)
            end,
            flush: fn _controller -> send(test, :flush) end
          },
          readable_strategy: CountQueuingStrategy.new(10)
        )

      {_writer, _writes, close} = write_all(transform, [1, 2, 3])
      assert await(close) == :ok

      events =
        Stream.repeatedly(fn ->
          receive do
            event -> event
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(& &1)

      assert events == [start: 1, end: 1, start: 2, end: 2, start: 3, end: 3] ++ [:flush]
    end
  end
end
