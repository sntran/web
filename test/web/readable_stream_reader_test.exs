defmodule Web.ReadableStreamReaderTest do
  # The lock of a reader, its promise `closed`, and its cancel, as the
  # Streams Standard specifies them. Also the pulls before the end of the
  # function `start`, and the conversion of the chunks of the text streams.
  use ExUnit.Case, async: true

  import Web, only: [await: 1]

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController, as: Controller
  alias Web.ReadableStreamDefaultReader, as: Reader
  alias Web.TransformStream
  alias Web.TransformStreamDefaultController, as: TransformController
  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter, as: Writer

  defp rejection(promise), do: catch_exit(await(promise))

  defp readable(source \\ %{}) do
    test = self()

    stream =
      ReadableStream.new(Map.put(source, :start, fn c -> send(test, {:controller, c}) end))

    assert_receive {:controller, controller}
    {stream, controller}
  end

  describe "the lock of a reader" do
    test "of a reader that released it has no effect on the next reader of the process" do
      {stream, controller} = readable()
      Controller.enqueue(controller, "a")

      first = ReadableStream.get_reader(stream)
      :ok = Reader.release_lock(first)
      second = ReadableStream.get_reader(stream)

      # The second release of the first reader is a no-op.
      :ok = Reader.release_lock(first)
      assert ReadableStream.locked?(stream)
      assert %Web.TypeError{} = rejection(Reader.read(first))
      assert await(Reader.read(second)) == %{value: "a", done: false}
    end

    test "stays after a cancel: the reader reads the end of the stream" do
      {stream, _controller} = readable()
      reader = ReadableStream.get_reader(stream)

      assert :ok = await(Reader.cancel(reader, :stop))
      assert ReadableStream.locked?(stream)
      assert await(Reader.read(reader)) == %{value: nil, done: true}
      assert await(Reader.closed(reader)) == :ok
    end

    test "of a reader that released it gives a cancel that rejects, and that has no effect" do
      test = self()
      {stream, controller} = readable(%{cancel: fn reason -> send(test, {:cancel, reason}) end})
      Controller.enqueue(controller, "a")
      reader = ReadableStream.get_reader(stream)
      :ok = Reader.release_lock(reader)

      assert %Web.TypeError{} = rejection(Reader.cancel(reader, :stop))
      refute_received {:cancel, _reason}
      assert ["a"] = Enum.take(stream, 1)
    end
  end

  describe "a reader with no reference of its lock" do
    test "has the lock of its process" do
      {stream, _controller} = readable()
      :ok = ReadableStream.get_reader(stream.controller_pid)
      reader = %Reader{controller_pid: stream.controller_pid}
      closed = Reader.closed(reader)

      assert :ok = await(Reader.cancel(reader, :stop))
      assert await(closed) == :ok
      :ok = Reader.release_lock(reader)
      refute ReadableStream.locked?(stream)
    end

    test "gets the error of the stream, or a TypeError after the release, from closed" do
      {stream, controller} = readable()
      :ok = ReadableStream.get_reader(stream.controller_pid)
      reader = %Reader{controller_pid: stream.controller_pid}
      closed = Reader.closed(reader)
      :ok = Reader.release_lock(reader)
      assert %Web.TypeError{} = rejection(closed)

      :ok = ReadableStream.get_reader(stream.controller_pid)
      Controller.error(controller, :failed)
      assert rejection(Reader.closed(reader)) == :failed
    end
  end

  describe "the cancel of an errored stream" do
    test "rejects with the error of the stream" do
      {stream, controller} = readable()
      Controller.error(controller, :broken)
      reader = ReadableStream.get_reader(stream)

      assert rejection(Reader.cancel(reader, :stop)) == :broken
      :ok = Reader.release_lock(reader)
      assert rejection(ReadableStream.cancel(stream, :stop)) == :broken
    end
  end

  describe "the promise closed of a reader" do
    test "is the same promise for each request" do
      {stream, controller} = readable()
      reader = ReadableStream.get_reader(stream)
      closed = Reader.closed(reader)
      assert Reader.closed(reader) == closed

      Controller.close(controller)
      assert await(closed) == :ok
      assert Reader.closed(reader) == closed
    end

    test "rejects with a TypeError, and keeps its identity, at a release of a readable stream" do
      {stream, controller} = readable()
      Controller.enqueue(controller, "a")
      Controller.close(controller)

      # A closed stream with a chunk in its queue is readable.
      reader = ReadableStream.get_reader(stream)
      closed = Reader.closed(reader)
      :ok = Reader.release_lock(reader)

      assert Reader.closed(reader) == closed
      assert %Web.TypeError{} = rejection(closed)
    end

    test "is a new promise that rejects with a TypeError after a release of a closed stream" do
      {stream, controller} = readable()
      reader = ReadableStream.get_reader(stream)
      before = Reader.closed(reader)
      Controller.close(controller)
      assert await(before) == :ok

      :ok = Reader.release_lock(reader)
      later = Reader.closed(reader)
      assert later != before
      assert %Web.TypeError{} = rejection(later)
    end

    test "rejects with the error of the stream, and with a TypeError after the release" do
      {stream, controller} = readable()
      Controller.error(controller, :broken)
      reader = ReadableStream.get_reader(stream)
      assert rejection(Reader.closed(reader)) == :broken

      :ok = Reader.release_lock(reader)
      assert %Web.TypeError{} = rejection(Reader.closed(reader))
    end

    test "of a reader that released its lock before the request rejects with a TypeError" do
      {stream, _controller} = readable()
      reader = ReadableStream.get_reader(stream)
      :ok = Reader.release_lock(reader)
      _second = ReadableStream.get_reader(stream)
      assert %Web.TypeError{} = rejection(Reader.closed(reader))
    end

    test "fulfils for a stream that stopped" do
      {stream, _controller} = readable()
      reader = ReadableStream.get_reader(stream)
      Web.Stream.stop(stream.controller_pid)
      assert await(Reader.closed(reader)) == :ok
    end

    test "fulfils when the last chunk of a closed stream is read" do
      {stream, controller} = readable()
      Controller.enqueue(controller, "a")
      Controller.close(controller)
      reader = ReadableStream.get_reader(stream)
      closed = Reader.closed(reader)

      assert await(Reader.read(reader)) == %{value: "a", done: false}
      assert await(closed) == :ok
    end
  end

  describe "the pull" do
    test "does not start before the promise of the function start fulfils" do
      test = self()
      {gate, resolve, _reject} = Web.Promise.with_resolvers()

      source = %{
        start: fn controller ->
          Controller.enqueue(controller, "a")
          gate
        end,
        pull: fn _controller -> send(test, :pull) end
      }

      stream = ReadableStream.new(source)
      reader = ReadableStream.get_reader(stream)
      assert await(Reader.read(reader)) == %{value: "a", done: false}
      refute_received :pull

      # The end of the function start causes one pull: the queue is empty.
      resolve.(:ok)
      assert_receive :pull
      _ = ReadableStream.get_desired_size(stream.controller_pid)
      refute_received :pull
    end
  end

  describe "a transform stream" do
    test "gives the error of the function cancel to the other side" do
      transformer = %{cancel: fn _reason -> throw(:cancel_failed) end}

      transform = TransformStream.new(transformer)
      writer = WritableStream.get_writer(transform.writable)
      assert rejection(ReadableStream.cancel(transform.readable, :stop)) == :cancel_failed
      assert rejection(Writer.closed(writer)) == :cancel_failed

      transform = TransformStream.new(transformer)
      reader = ReadableStream.get_reader(transform.readable)
      assert rejection(WritableStream.abort(transform.writable, :stop)) == :cancel_failed
      assert rejection(Reader.closed(reader)) == :cancel_failed
    end

    test "errors a readable side with a chunk when transform fails after terminate" do
      transformer = %{
        transform: fn chunk, controller ->
          TransformController.enqueue(controller, chunk)
          TransformController.terminate(controller)
          throw(:transform_failed)
        end
      }

      transform =
        TransformStream.new(transformer, readable_strategy: Web.CountQueuingStrategy.new(1))

      writer = WritableStream.get_writer(transform.writable)
      reader = ReadableStream.get_reader(transform.readable)
      assert rejection(Writer.write(writer, "a")) == :transform_failed
      assert rejection(Reader.closed(reader)) == :transform_failed
    end

    test "discards a chunk that the size function enqueues after terminate in a transform" do
      {:ok, cell} = Agent.start_link(fn -> nil end)
      start = fn controller -> Agent.update(cell, fn _ -> controller end) end

      # The size function runs in the transform, thus during the write. The
      # terminate closes the readable side at once: its queue is empty.
      size = fn _chunk ->
        controller = Agent.get(cell, & &1)
        TransformController.terminate(controller)
        # The terminate is a message: a call after it waits for its end.
        _ = TransformController.desired_size(controller)
        1
      end

      transform =
        TransformStream.new(%{start: start},
          readable_strategy: [size: size, high_water_mark: :infinity]
        )

      writer = WritableStream.get_writer(transform.writable)
      assert :ok = await(Writer.write(writer, "a"))
      assert Enum.to_list(transform.readable) == []
    end
  end

  describe "the text streams" do
    test "TextEncoderStream converts a chunk to a string with String.Chars" do
      encoder = Web.TextEncoderStream.new()
      writer = WritableStream.get_writer(encoder.writable)

      for chunk <- [3.14, :atom, nil, ~c"abc", ["d", "e"], 1] do
        _ = Writer.write(writer, chunk)
      end

      _ = Writer.close(writer)
      text = Enum.map_join(encoder.readable, &Web.Uint8Array.to_binary/1)
      assert text == "3.14atomabcde1"
    end

    test "TextEncoderStream errors the two sides for a chunk with no String.Chars" do
      encoder = Web.TextEncoderStream.new()
      writer = WritableStream.get_writer(encoder.writable)
      reader = ReadableStream.get_reader(encoder.readable)

      # The readable side has the high water mark 0: the transform runs for
      # a read.
      read = Reader.read(reader)
      assert %Web.TypeError{message: message} = rejection(Writer.write(writer, %{a: 1}))
      assert message =~ "cannot convert"
      assert %Web.TypeError{} = rejection(read)
    end

    test "TextDecoderStream errors the two sides for the chunk nil" do
      decoder = Web.TextDecoderStream.new()
      writer = WritableStream.get_writer(decoder.writable)
      reader = ReadableStream.get_reader(decoder.readable)

      read = Reader.read(reader)
      assert %Web.TypeError{} = rejection(Writer.write(writer, nil))
      assert %Web.TypeError{} = rejection(read)
    end
  end
end
