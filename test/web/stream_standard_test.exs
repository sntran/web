defmodule Web.StreamStandardTest do
  # The behaviour that the Streams Standard specifies for operations that are
  # not awaited, for locks, and for the promises of readers and writers.
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Web

  alias Web.ReadableStreamDefaultReader, as: Reader
  alias Web.WritableStreamDefaultWriter, as: Writer

  defp rejection(promise), do: catch_exit(await(promise))

  # A sink that tells the test each event.
  defp recording_sink(parent, extra \\ %{}) do
    Map.merge(
      %{
        write: fn chunk, _controller -> send(parent, {:write, chunk}) end,
        close: fn _controller -> send(parent, :close) end,
        abort: fn reason -> send(parent, {:abort, reason}) end
      },
      extra
    )
  end

  defp events(acc \\ []) do
    receive do
      event -> events([event | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  describe "operations that are not awaited" do
    property "the sink gets the writes and the close in the sequence of the calls" do
      check all(chunks <- list_of(integer(), max_length: 30), max_runs: 50) do
        writer = WritableStream.get_writer(WritableStream.new(recording_sink(self())))

        writes = Enum.map(chunks, &Writer.write(writer, &1))
        close = Writer.close(writer)

        assert await(close) == :ok
        assert Enum.map(writes, &await/1) == Enum.map(chunks, fn _ -> :ok end)
        assert events() == Enum.map(chunks, &{:write, &1}) ++ [:close]
      end
    end

    property "the reads get the chunks in the sequence of the calls" do
      check all(chunks <- list_of(integer(), min_length: 1, max_length: 20), max_runs: 50) do
        stream = ReadableStream.new(%{})
        reader = ReadableStream.get_reader(stream)

        # All the reads are pending before the first chunk comes.
        reads = Enum.map(chunks, fn _ -> Reader.read(reader) end)
        last = Reader.read(reader)
        assert Enum.all?(reads, &(Promise.peek(&1) == :pending))

        Enum.each(chunks, &ReadableStream.enqueue(stream.controller_pid, &1))
        ReadableStream.close(stream.controller_pid)

        assert Enum.map(reads, &await(&1).value) == chunks
        assert await(last) == %{value: nil, done: true}
      end
    end

    property "a transform gives the chunks in the sequence of the writes" do
      check all(chunks <- list_of(binary(), max_length: 20), max_runs: 50) do
        transform = TransformStream.new(%{}, readable_strategy: CountQueuingStrategy.new(100))
        writer = WritableStream.get_writer(transform.writable)

        Enum.each(chunks, &Writer.write(writer, &1))
        Writer.close(writer)

        assert Enum.to_list(transform.readable) == chunks
      end
    end

    test "a write after a close that is not awaited rejects" do
      writer = WritableStream.get_writer(WritableStream.new(recording_sink(self())))

      first = Writer.write(writer, 1)
      close = Writer.close(writer)
      late = Writer.write(writer, 2)

      assert await(first) == :ok
      assert await(close) == :ok
      assert %TypeError{} = rejection(late)
      assert events() == [{:write, 1}, :close]
    end

    test "a write before an abort that is not awaited rejects with the reason" do
      test = self()

      sink =
        recording_sink(test, %{
          write: fn chunk, _controller ->
            send(test, {:write, chunk})
            # The write stays in progress until the abort stops it.
            Process.sleep(:infinity)
          end
        })

      writer = WritableStream.get_writer(WritableStream.new(sink))

      first = Writer.write(writer, 1)
      second = Writer.write(writer, 2)
      abort = Writer.abort(writer, :stop)

      assert rejection(second) == :stop
      assert await(abort) == :ok
      assert rejection(first) == :stop
      assert {:abort, :stop} in events()
    end
  end

  describe "a read" do
    test "returns a pending promise, and does not block its caller" do
      stream = ReadableStream.new(%{})
      reader = ReadableStream.get_reader(stream)

      {time, promise} = :timer.tc(fn -> Reader.read(reader) end)
      assert time < 100_000
      assert Promise.peek(promise) == :pending

      ReadableStream.enqueue(stream.controller_pid, "late")
      assert await(promise) == %{value: "late", done: false}
    end

    test "with a BYOB reader returns a pending promise" do
      stream = ReadableStream.new(%{type: "bytes"})
      reader = ReadableStream.get_reader(stream, mode: "byob")

      promise = ReadableStreamBYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(4)))
      assert Promise.peek(promise) == :pending

      ReadableStream.enqueue(stream.controller_pid, "data")
      assert %{value: value, done: false} = await(promise)
      assert Uint8Array.to_binary(value) == "data"
    end

    test "can come from a process that got the reader in a message" do
      stream = ReadableStream.from(["a", "b"])
      reader = ReadableStream.get_reader(stream)

      task = Task.async(fn -> await(Reader.read(reader)) end)
      assert Task.await(task) == %{value: "a", done: false}

      # The lock stays with the process that got the reader.
      assert ReadableStream.locked?(stream)
      assert await(Reader.read(reader)) == %{value: "b", done: false}
    end

    test "that is pending rejects when the reader releases its lock" do
      stream = ReadableStream.new(%{})
      reader = ReadableStream.get_reader(stream)
      pending = [Reader.read(reader), Reader.read(reader)]

      assert :ok = Reader.release_lock(reader)

      for promise <- pending do
        assert %TypeError{message: "This reader is no longer locked."} = rejection(promise)
      end

      # A different reader gets the chunks.
      ReadableStream.enqueue(stream.controller_pid, "kept")
      assert await(Reader.read(ReadableStream.get_reader(stream))).value == "kept"
    end
  end

  describe "the promise closed" do
    test "of a reader fulfils when the stream closes" do
      stream = ReadableStream.new(%{})
      reader = ReadableStream.get_reader(stream)
      closed = Reader.closed(reader)
      assert Promise.peek(closed) == :pending

      ReadableStream.close(stream.controller_pid)
      assert await(closed) == :ok
      assert await(Reader.closed(reader)) == :ok
    end

    test "of a reader rejects with the error of the stream" do
      stream = ReadableStream.new(%{})
      reader = ReadableStream.get_reader(stream)
      closed = Reader.closed(reader)

      ReadableStream.error(stream.controller_pid, :failed)
      assert rejection(closed) == :failed
      assert rejection(Reader.closed(reader)) == :failed
    end

    test "of a reader rejects when the reader releases its lock" do
      stream = ReadableStream.new(%{})
      reader = ReadableStream.get_reader(stream)
      closed = Reader.closed(reader)

      Reader.release_lock(reader)
      assert %TypeError{} = rejection(closed)
      assert %TypeError{} = rejection(Reader.closed(reader))
    end

    test "of a BYOB reader fulfils when the stream closes" do
      stream = ReadableStream.new(%{type: "bytes"})
      reader = ReadableStream.get_reader(stream, mode: "byob")
      closed = ReadableStreamBYOBReader.closed(reader)

      ReadableStream.close(stream.controller_pid)
      assert await(closed) == :ok
    end

    test "of a writer fulfils after the close, and rejects after an error" do
      writer = WritableStream.get_writer(WritableStream.new())
      closed = Writer.closed(writer)
      assert Promise.peek(closed) == :pending
      assert await(Writer.close(writer)) == :ok
      assert await(closed) == :ok

      failing = WritableStream.get_writer(WritableStream.new())
      closed = Writer.closed(failing)
      assert await(Writer.abort(failing, :stopped)) == :ok
      assert rejection(closed) == :stopped
    end

    test "of a writer rejects when the writer releases its lock" do
      writer = WritableStream.get_writer(WritableStream.new())
      closed = Writer.closed(writer)

      Writer.release_lock(writer)
      assert %TypeError{} = rejection(closed)
    end
  end

  describe "a lock" do
    test "refuses a cancel of the stream object, and permits a cancel of the reader" do
      stream = ReadableStream.from(["a"])
      reader = ReadableStream.get_reader(stream)

      assert %TypeError{message: "Cannot cancel a locked stream."} =
               rejection(ReadableStream.cancel(stream, :no))

      assert ReadableStream.locked?(stream)
      assert await(Reader.cancel(reader, :yes)) == :ok
    end

    test "refuses an abort and a close of the stream object" do
      stream = WritableStream.new(recording_sink(self()))
      writer = WritableStream.get_writer(stream)

      assert %TypeError{message: "Cannot abort a locked stream."} =
               rejection(WritableStream.abort(stream, :no))

      assert %TypeError{message: "Cannot close a locked stream."} =
               rejection(WritableStream.close(stream))

      assert events() == []
      assert await(Writer.write(writer, 1)) == :ok

      # The stream object can do these operations after the release.
      Writer.release_lock(writer)
      assert await(WritableStream.close(stream)) == :ok
    end

    test "has no effect when it is released two times" do
      stream = ReadableStream.from(["a"])
      reader = ReadableStream.get_reader(stream)
      assert :ok = Reader.release_lock(reader)
      assert :ok = Reader.release_lock(reader)

      writer = WritableStream.get_writer(WritableStream.new())
      assert :ok = Writer.release_lock(writer)
      assert :ok = Writer.release_lock(writer)
    end

    test "is separate for the two sides of a transform stream" do
      transform = TransformStream.new()
      refute ReadableStream.locked?(transform.readable)
      refute WritableStream.locked?(transform.writable)

      writer = WritableStream.get_writer(transform.writable)
      assert WritableStream.locked?(transform.writable)
      refute ReadableStream.locked?(transform.readable)

      reader = ReadableStream.get_reader(transform.readable)
      assert ReadableStream.locked?(transform.readable)

      # The release of one side keeps the lock of the other side.
      Writer.release_lock(writer)
      refute WritableStream.locked?(transform.writable)
      assert ReadableStream.locked?(transform.readable)

      Reader.release_lock(reader)
      refute ReadableStream.locked?(transform.readable)
    end
  end

  describe "a writable stream" do
    test "rejects a second close" do
      writer = WritableStream.get_writer(WritableStream.new())
      assert await(Writer.close(writer)) == :ok
      assert %TypeError{message: "The stream is closed."} = rejection(Writer.close(writer))
    end

    test "gives the desired size 0 after a close, and nil after an error" do
      closed = WritableStream.get_writer(WritableStream.new())
      await(Writer.close(closed))
      assert Writer.desired_size(closed) == 0

      errored = WritableStream.get_writer(WritableStream.new())
      await(Writer.abort(errored, :stop))
      assert Writer.desired_size(errored) == nil
    end

    test "rejects a write, and the promise ready, with its error" do
      sink = %{write: fn _chunk, _controller -> raise "sink failed" end}
      writer = WritableStream.get_writer(WritableStream.new(sink))

      assert %RuntimeError{message: "sink failed"} = rejection(Writer.write(writer, 1))
      assert %RuntimeError{message: "sink failed"} = rejection(Writer.write(writer, 2))
      assert %RuntimeError{message: "sink failed"} = rejection(Writer.ready(writer))
      assert %TypeError{message: "The stream is errored."} = rejection(Writer.close(writer))
      assert await(Writer.abort(writer, :late)) == :ok
    end

    test "settles an abort after the abort callback of the sink" do
      test = self()

      # The abort callback waits until the test lets it continue.
      sink = %{
        abort: fn reason ->
          send(test, {:abort_started, self()})

          receive do
            :continue -> send(test, {:abort_complete, reason})
          end
        end
      }

      writer = WritableStream.get_writer(WritableStream.new(sink))
      abort = Writer.abort(writer, :stop)

      assert_receive {:abort_started, callback}
      assert Promise.peek(abort) == :pending
      send(callback, :continue)
      assert await(abort) == :ok
      assert_received {:abort_complete, :stop}
    end

    test "rejects an abort with the value that the abort callback throws or rejects with" do
      for {callback, expected} <- [
            {fn _reason -> throw(:thrown) end, :thrown},
            {fn _reason -> Promise.reject(:rejected) end, :rejected}
          ] do
        writer = WritableStream.get_writer(WritableStream.new(%{abort: callback}))
        assert rejection(Writer.abort(writer, :stop)) == expected

        # The stream has the reason of the abort.
        assert rejection(Writer.write(writer, 1)) == :stop
      end

      stream = WritableStream.new(%{abort: fn _reason -> raise "abort failed" end})

      assert %RuntimeError{message: "abort failed"} =
               rejection(WritableStream.abort(stream, :stop))
    end
  end

  describe "the function start of a sink" do
    test "runs in the process that makes the stream, with a controller that is usable" do
      test = self()

      stream =
        WritableStream.new(%{
          start: fn controller ->
            send(test, {:start, self(), WritableStreamDefaultController.signal(controller)})
          end
        })

      assert_received {:start, ^test, %AbortSignal{} = signal}
      refute AbortSignal.aborted?(signal)
      assert await(WritableStream.abort(stream, :stop)) == :ok
      assert AbortSignal.aborted?(signal)
    end

    test "holds the writes until its promise fulfils" do
      test = self()
      {started, resolve, _reject} = Promise.with_resolvers()

      stream =
        WritableStream.new(%{
          start: fn _controller -> started end,
          write: fn chunk, _controller -> send(test, {:written, chunk}) end
        })

      writer = WritableStream.get_writer(stream)
      write = Writer.write(writer, :chunk)
      refute_receive {:written, _chunk}, 50

      resolve.(:ok)
      assert await(write) == :ok
      assert_received {:written, :chunk}
    end

    test "that throws stops the stream process, and the constructor throws the value" do
      test = self()

      assert catch_throw(
               WritableStream.new(%{
                 start: fn controller ->
                   send(test, {:controller, controller})
                   throw(:failed)
                 end
               })
             ) == :failed

      assert_received {:controller, controller}
      refute Process.alive?(controller.pid)
    end
  end

  describe "a close of the stream object" do
    test "completes the writes that wait, and awaits the promise of the sink" do
      test = self()
      {closed, resolve, _reject} = Promise.with_resolvers()

      stream =
        WritableStream.new(%{
          write: fn chunk, _controller ->
            # A slow write: the close comes while the writes wait.
            Process.sleep(20)
            send(test, {:written, chunk})
          end,
          close: fn _controller ->
            send(test, :close_called)
            closed
          end
        })

      writer = WritableStream.get_writer(stream)
      writes = Enum.map([1, 2], &Writer.write(writer, &1))
      Writer.release_lock(writer)

      close = WritableStream.close(stream)

      # The close callback runs after the two writes.
      assert_receive :close_called
      assert_received {:written, 1}
      assert_received {:written, 2}
      assert Enum.map(writes, &await/1) == [:ok, :ok]

      # The close waits for the promise of the sink. This is a negative
      # check, and no message tells when the stream did all its work. Thus
      # the test waits for some time before the check.
      Process.sleep(30)
      assert Promise.peek(close) == :pending
      resolve.(:ok)
      assert await(close) == :ok
    end

    test "rejects when the promise of the sink rejects, and errors the stream" do
      stream = WritableStream.new(%{close: fn _controller -> Promise.reject(:close_failed) end})

      assert rejection(WritableStream.close(stream)) == :close_failed
      assert WritableStream.__get_slots__(stream.controller_pid).state == :errored
    end

    test "rejects with a TypeError for a stream that closes, is closed, or is errored" do
      # A slow close callback: the second close comes while the stream closes.
      slow = WritableStream.new(%{close: fn _controller -> Process.sleep(50) end})
      first = WritableStream.close(slow)
      assert %TypeError{} = rejection(WritableStream.close(slow))
      assert await(first) == :ok
      assert %TypeError{} = rejection(WritableStream.close(slow))

      errored = WritableStream.new()
      assert await(WritableStream.abort(errored, :stop)) == :ok
      assert %TypeError{} = rejection(WritableStream.close(errored))
    end

    test "of the writable side of a transform stream runs the function flush" do
      transform =
        TransformStream.new(%{
          flush: fn controller ->
            Web.TransformStreamDefaultController.enqueue(controller, :last)
          end
        })

      close = WritableStream.close(transform.writable)
      assert Enum.to_list(transform.readable) == [:last]
      assert await(close) == :ok
    end
  end

  describe "the checks of the constructors" do
    test "refuse an underlying source that is not valid" do
      for source <- [:nope, 123, "text", [1, 2]] do
        assert_raise TypeError, ~r/Invalid underlying source/, fn ->
          ReadableStream.new(source)
        end
      end

      for {name, bad} <- [start: :nope, pull: fn -> :ok end, cancel: fn _a, _b -> :ok end] do
        assert_raise TypeError, ~r/must be a function/, fn ->
          ReadableStream.new(%{name => bad})
        end
      end

      assert_raise TypeError, ~r/Invalid type/, fn -> ReadableStream.new(%{type: "nope"}) end
      assert %ReadableStream{} = ReadableStream.new(%{type: "bytes"})
    end

    test "refuse a limit that is not a number or that is below zero" do
      for limit <- [-1, :big, "1"] do
        assert_raise Web.RangeError, ~r/Invalid high water mark/, fn ->
          ReadableStream.new(%{}, high_water_mark: limit)
        end

        assert_raise Web.RangeError, ~r/Invalid high water mark/, fn ->
          WritableStream.new(%{high_water_mark: limit})
        end

        assert_raise Web.RangeError, fn -> CountQueuingStrategy.new(limit) end
        assert_raise Web.RangeError, fn -> ByteLengthQueuingStrategy.new(limit) end
      end

      assert ReadableStream.get_desired_size(
               ReadableStream.new(%{}, high_water_mark: 0).controller_pid
             ) == 0
    end

    test "refuse an underlying sink that is not valid" do
      assert_raise TypeError, ~r/must be a map/, fn -> WritableStream.new(:nope) end

      assert_raise Web.RangeError, ~r/:type is not permitted/, fn ->
        WritableStream.new(%{type: "bytes"})
      end

      for {name, bad} <- [
            start: :nope,
            write: fn _chunk -> :ok end,
            close: 1,
            abort: fn -> :ok end
          ] do
        assert_raise TypeError, ~r/must be a function/, fn ->
          WritableStream.new(%{name => bad})
        end
      end
    end

    test "refuse a value that is not enumerable for from/1" do
      assert_raise TypeError, ~r/Cannot make a ReadableStream/, fn -> ReadableStream.from(123) end
    end

    test "give the size of each kind of byte chunk" do
      assert ByteLengthQueuingStrategy.size("abc") == 3
      assert ByteLengthQueuingStrategy.size(Uint8Array.new(ArrayBuffer.new("abcd"), 1, 2)) == 2
      assert ByteLengthQueuingStrategy.size(ArrayBuffer.new("abcde")) == 5
    end
  end

  describe "a pipe" do
    test "has the two locks when pipe_to/3 returns" do
      source = ReadableStream.new(%{})
      destination = WritableStream.new()
      pipe = ReadableStream.pipe_to(source, destination)

      assert ReadableStream.locked?(source)
      assert WritableStream.locked?(destination)

      ReadableStream.close(source.controller_pid)
      assert await(pipe) == :ok
    end

    test "releases its locks before its promise settles" do
      source = ReadableStream.from(["a"])
      destination = WritableStream.new()

      assert await(ReadableStream.pipe_to(source, destination, prevent_close: true)) == :ok
      refute WritableStream.locked?(destination)

      # A second pipe can use the same destination.
      assert await(ReadableStream.pipe_to(ReadableStream.from(["b"]), destination)) == :ok
    end

    test "rejects when one of the two streams is locked, and takes no lock" do
      locked_source = ReadableStream.from(["a"])
      _reader = ReadableStream.get_reader(locked_source)
      destination = WritableStream.new()

      assert %TypeError{message: "ReadableStream is already locked"} =
               rejection(ReadableStream.pipe_to(locked_source, destination))

      refute WritableStream.locked?(destination)

      locked_destination = WritableStream.new()
      _writer = WritableStream.get_writer(locked_destination)
      source = ReadableStream.from(["a"])

      assert %TypeError{message: "WritableStream is already locked"} =
               rejection(ReadableStream.pipe_to(source, locked_destination))

      refute ReadableStream.locked?(source)
    end

    test "raises from pipe_through/3 when one of the two streams is locked" do
      locked_source = ReadableStream.from(["a"])
      _reader = ReadableStream.get_reader(locked_source)

      assert_raise TypeError, "ReadableStream is already locked", fn ->
        ReadableStream.pipe_through(locked_source, TransformStream.new())
      end

      transform = TransformStream.new()
      _writer = WritableStream.get_writer(transform.writable)

      assert_raise TypeError, "WritableStream is already locked", fn ->
        ReadableStream.pipe_through(ReadableStream.from(["a"]), transform)
      end
    end

    test "accepts each option with its Elixir name and with its name in the Standard" do
      for option <- [:prevent_close, :preventClose] do
        destination = WritableStream.new(recording_sink(self()))

        assert await(
                 ReadableStream.pipe_to(ReadableStream.from([1]), destination, [{option, true}])
               ) == :ok

        assert events() == [{:write, 1}]
      end

      for option <- [:prevent_abort, :preventAbort] do
        source = ReadableStream.new(%{})
        destination = WritableStream.new(recording_sink(self()))
        pipe = ReadableStream.pipe_to(source, destination, [{option, true}])
        ReadableStream.error(source.controller_pid, :failed)
        assert rejection(pipe) == :failed
        assert events() == []
      end

      for option <- [:prevent_cancel, :preventCancel] do
        test = self()

        source =
          ReadableStream.new(%{
            pull: fn controller -> ReadableStreamDefaultController.enqueue(controller, 1) end,
            cancel: fn reason -> send(test, {:cancel, reason}) end
          })

        destination =
          WritableStream.new(%{write: fn _chunk, _controller -> raise "sink failed" end})

        pipe = ReadableStream.pipe_to(source, destination, [{option, true}])
        assert %RuntimeError{} = rejection(pipe)
        assert events() == []

        # The source is not cancelled, thus the test cancels it.
        assert await(ReadableStream.cancel(source, :cleanup)) == :ok
        assert events() == [cancel: :cleanup]
      end
    end
  end

  describe "a cancel" do
    test "settles after the cancel callback of the source, also when it returns a promise" do
      test = self()

      # Each callback waits until the test lets it continue.
      wait_for_test = fn reason ->
        send(test, {:cancel_started, self()})

        receive do
          :continue -> send(test, {:cancel_complete, reason})
        end
      end

      for callback <- [
            wait_for_test,
            fn reason ->
              Promise.new(fn resolve, _reject ->
                wait_for_test.(reason)
                resolve.(:ok)
              end)
            end
          ] do
        stream = ReadableStream.new(%{cancel: callback})
        cancel = ReadableStream.cancel(stream, :enough)

        # The stream is closed immediately. The promise waits for the callback.
        assert await(Reader.read(ReadableStream.get_reader(stream))) == %{value: nil, done: true}
        assert_receive {:cancel_started, callback_process}
        assert Promise.peek(cancel) == :pending
        send(callback_process, :continue)
        assert await(cancel) == :ok
        assert_received {:cancel_complete, :enough}
      end
    end

    test "rejects with the value that the callback throws, or that its promise rejects with" do
      for {callback, expected} <- [
            {fn _reason -> raise "cancel failed" end, %RuntimeError{message: "cancel failed"}},
            {fn _reason -> throw(:thrown) end, :thrown},
            {fn _reason -> Promise.reject(:rejected) end, :rejected}
          ] do
        stream = ReadableStream.new(%{cancel: callback})
        assert rejection(ReadableStream.cancel(stream, :enough)) == expected

        # The stream is closed, and its process did not stop.
        assert Process.alive?(stream.controller_pid)
        assert ReadableStream.__get_slots__(stream.controller_pid).state == :closed
      end
    end

    test "has no effect on the result when the callback returns a value that is not a promise" do
      for value <- [:ok, {:error, :not_a_rejection}, nil, "text"] do
        stream = ReadableStream.new(%{cancel: fn _reason -> value end})
        assert await(ReadableStream.cancel(stream, :enough)) == :ok
      end
    end

    test "of a closed stream, and a second cancel, call no callback" do
      test = self()
      source = %{cancel: fn reason -> send(test, {:cancelled, reason}) end}

      closed = ReadableStream.new(source)
      ReadableStream.close(closed.controller_pid)
      assert await(ReadableStream.cancel(closed, :late)) == :ok
      assert events() == []

      stream = ReadableStream.new(source)
      assert await(ReadableStream.cancel(stream, :first)) == :ok
      assert await(ReadableStream.cancel(stream, :second)) == :ok
      assert events() == [cancelled: :first]
    end

    test "from a halt of an enumeration does not wait for the callback" do
      test = self()
      counter = :counters.new(1, [])

      stream =
        ReadableStream.new(%{
          pull: fn controller ->
            :counters.add(counter, 1, 1)
            ReadableStreamDefaultController.enqueue(controller, :counters.get(counter, 1))
          end,
          # The cancel callback waits until the test lets it continue. The
          # enumeration must end while the callback waits.
          cancel: fn reason ->
            send(test, {:cancel_started, self()})

            receive do
              :continue -> send(test, {:cancel_complete, reason})
            end
          end
        })

      # An enumeration that waits for the callback does not end: the yield
      # then gives `nil`.
      enumeration = Task.async(fn -> Enum.take(stream, 2) end)
      assert Task.yield(enumeration, 5_000) == {:ok, [1, 2]}

      assert_receive {:cancel_started, callback}, 1_000
      refute_received {:cancel_complete, _reason}
      send(callback, :continue)
      assert_receive {:cancel_complete, :halted}, 1_000
    end

    test "of a writable stream object settles after the abort callback of the sink" do
      test = self()

      # The promise of the abort callback waits until the test lets it
      # continue.
      stream =
        WritableStream.new(%{
          abort: fn reason ->
            Promise.new(fn resolve, _reject ->
              send(test, {:abort_started, self()})

              receive do
                :continue -> send(test, {:abort_complete, reason})
              end

              resolve.(:ok)
            end)
          end
        })

      abort = WritableStream.abort(stream, :stop)
      assert_receive {:abort_started, callback}
      assert Promise.peek(abort) == :pending
      send(callback, :continue)
      assert await(abort) == :ok
      assert_received {:abort_complete, :stop}
    end
  end

  describe "the signal of a writable stream controller" do
    test "aborts with the reason when the writer aborts, also during a write" do
      test = self()

      sink = %{
        write: fn _chunk, controller ->
          signal = WritableStreamDefaultController.signal(controller)
          send(test, {:signal, signal, WritableStreamDefaultController.signal(controller)})
          Process.sleep(:infinity)
        end
      }

      writer = WritableStream.get_writer(WritableStream.new(sink))
      write = Writer.write(writer, :chunk)

      assert_receive {:signal, signal, same_signal}
      assert signal == same_signal
      refute AbortSignal.aborted?(signal)

      assert await(Writer.abort(writer, :stop)) == :ok
      assert AbortSignal.aborted?(signal)
      assert AbortSignal.reason(signal) == :stop
      assert rejection(write) == :stop
    end

    test "is aborted already when the sink asks for it after the abort" do
      test = self()

      stream =
        WritableStream.new(%{
          abort: fn _reason -> send(test, :abort_called) end,
          start: fn controller -> send(test, {:controller, controller}) end
        })

      assert_receive {:controller, controller}
      assert await(WritableStream.abort(stream, :stop)) == :ok

      signal = WritableStreamDefaultController.signal(controller)
      assert AbortSignal.aborted?(signal)
      assert AbortSignal.reason(signal) == :stop
    end

    test "starts no process for a stream that does not use it" do
      stream = WritableStream.new()
      assert WritableStream.__get_slots__(stream.controller_pid).abort_controller == nil

      assert await(WritableStream.abort(stream, :stop)) == :ok

      assert WritableStream.__get_slots__(stream.controller_pid).abort_controller ==
               {:aborted, :stop}
    end

    test "is an aborted signal for a stream that stopped" do
      pid = spawn(fn -> :ok end)
      monitor = Process.monitor(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}

      controller = %WritableStreamDefaultController{pid: pid}
      assert AbortSignal.aborted?(WritableStreamDefaultController.signal(controller))
    end
  end

  describe "a readable stream controller" do
    defp controller_of(source \\ %{}, opts \\ []) do
      test = self()
      start = fn controller -> send(test, {:controller, controller}) end
      stream = ReadableStream.new(Map.put(source, :start, start), opts)
      assert_receive {:controller, controller}
      {stream, controller}
    end

    test "raises a TypeError for an enqueue or a close after a close" do
      {stream, controller} = controller_of()
      assert ReadableStreamDefaultController.enqueue(controller, :chunk) == :ok
      assert ReadableStreamDefaultController.close(controller) == :ok

      assert_raise TypeError, "Cannot enqueue a chunk: the stream is closed.", fn ->
        ReadableStreamDefaultController.enqueue(controller, :late)
      end

      assert_raise TypeError, "Cannot close: the stream is closed.", fn ->
        ReadableStreamDefaultController.close(controller)
      end

      assert Enum.to_list(stream) == [:chunk]
    end

    test "an error after a close discards the chunks that no read took" do
      # The stream is readable, with a close request, until a read takes the
      # last chunk. An error at that time discards the chunks.
      {stream, controller} = controller_of()
      assert ReadableStreamDefaultController.enqueue(controller, :chunk) == :ok
      assert ReadableStreamDefaultController.close(controller) == :ok
      assert ReadableStreamDefaultController.error(controller, :failed) == :ok

      reader = ReadableStream.get_reader(stream)
      assert catch_exit(Web.await(ReadableStreamDefaultReader.read(reader))) == :failed
    end

    test "a cancel after a close discards the chunks and calls the cancel callback" do
      # The stream is readable, with a close request, until a read takes the
      # last chunk. A cancel at that time discards the chunks, and the
      # source gets the cancel.
      test = self()

      stream =
        ReadableStream.new(%{
          start: fn controller ->
            ReadableStreamDefaultController.enqueue(controller, :chunk)
            ReadableStreamDefaultController.close(controller)
          end,
          cancel: fn reason -> send(test, {:canceled, reason}) end
        })

      assert Web.await(ReadableStream.cancel(stream, :no_more)) == :ok
      assert_receive {:canceled, :no_more}
      assert Enum.to_list(stream) == []
    end

    test "an error after a close and the last read has no effect" do
      {stream, controller} = controller_of()
      assert ReadableStreamDefaultController.enqueue(controller, :chunk) == :ok
      assert ReadableStreamDefaultController.close(controller) == :ok
      assert Enum.to_list(stream) == [:chunk]

      # The stream is closed. An error does not raise and changes nothing.
      assert ReadableStreamDefaultController.error(controller, :failed) == :ok
      assert Web.await(ReadableStream.cancel(stream, :late)) == :ok
    end

    test "raises a TypeError for an enqueue or a close after an error" do
      {_stream, controller} = controller_of()
      assert ReadableStreamDefaultController.error(controller, :failed) == :ok

      assert_raise TypeError, "Cannot enqueue a chunk: the stream is errored.", fn ->
        ReadableStreamDefaultController.enqueue(controller, :late)
      end

      assert_raise TypeError, "Cannot close: the stream is errored.", fn ->
        ReadableStreamDefaultController.close(controller)
      end
    end

    test "raises a TypeError for an enqueue after a cancel, and after the stream stopped" do
      {stream, controller} = controller_of()
      assert await(ReadableStream.cancel(stream, :stop)) == :ok

      assert_raise TypeError, fn ->
        ReadableStreamDefaultController.enqueue(controller, :late)
      end

      monitor = Process.monitor(stream.controller_pid)
      Process.exit(stream.controller_pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, _pid, :killed}

      assert_raise TypeError, fn ->
        ReadableStreamDefaultController.enqueue(controller, :late)
      end
    end

    test "raises a TypeError for an enqueue to a stream that has no readable side" do
      stream = WritableStream.new()
      controller = %WritableStreamDefaultController{pid: stream.controller_pid}

      assert_raise TypeError, fn ->
        ReadableStreamDefaultController.enqueue(controller, :chunk)
      end

      assert_raise TypeError, fn -> ReadableStreamDefaultController.close(controller) end
    end

    test "raises the same errors for a byte stream" do
      {stream, controller} = controller_of(%{type: "bytes"})
      assert ReadableByteStreamController.enqueue(controller, "bytes") == :ok
      assert ReadableByteStreamController.close(controller) == :ok

      assert_raise TypeError, fn -> ReadableByteStreamController.enqueue(controller, "late") end
      assert_raise TypeError, fn -> ReadableByteStreamController.close(controller) end
      assert Web.TestBytes.join(stream) == "bytes"
    end

    test "keeps a closed stream closed when its pull fails after the close" do
      stream =
        ReadableStream.new(%{
          pull: fn controller ->
            ReadableStreamDefaultController.enqueue(controller, :chunk)
            ReadableStreamDefaultController.close(controller)
            ReadableStreamDefaultController.enqueue(controller, :late)
          end
        })

      assert Enum.to_list(stream) == [:chunk]
      assert ReadableStream.__get_slots__(stream.controller_pid).state == :closed
    end

    test "gives the desired size 0 after a close, and nil after an error" do
      closed = ReadableStream.new(%{})
      ReadableStream.close(closed.controller_pid)
      assert ReadableStream.get_desired_size(closed.controller_pid) == 0

      errored = ReadableStream.new(%{})
      ReadableStream.error(errored.controller_pid, :failed)
      assert ReadableStream.get_desired_size(errored.controller_pid) == nil
    end
  end
end
