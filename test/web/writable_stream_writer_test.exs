defmodule Web.WritableStreamWriterTest do
  # The lock and the promises of a writer, and the errors of a size, as the
  # Streams Standard specifies.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.Promise
  alias Web.RangeError
  alias Web.TypeError
  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter, as: Writer

  defp rejection(promise), do: catch_exit(await(promise))
  defp state(stream), do: WritableStream.__get_slots__(stream.controller_pid).state

  # A sink that tells the test about each write. The write waits until the
  # test sends `:continue` to the worker.
  defp gated_sink(test) do
    %{
      write: fn chunk, _controller ->
        send(test, {:write, self(), chunk})

        receive do
          :continue -> :ok
        end
      end
    }
  end

  describe "the lock" do
    property "a writer that released its lock has no effect on the next writer of its process" do
      check all(
              operation <-
                member_of([:release_lock, :write, :close, :abort, :desired_size, :ready, :closed])
            ) do
        stream = WritableStream.new()
        old = WritableStream.get_writer(stream)
        assert :ok = Writer.release_lock(old)
        new = WritableStream.get_writer(stream)

        # The operations of the Standard on a writer with no stream.
        case operation do
          :release_lock -> assert Writer.release_lock(old) == :ok
          :write -> assert %TypeError{} = rejection(Writer.write(old, :chunk))
          :close -> assert %TypeError{} = rejection(Writer.close(old))
          :abort -> assert %TypeError{} = rejection(Writer.abort(old, :stop))
          :desired_size -> assert_raise TypeError, fn -> Writer.desired_size(old) end
          :ready -> assert %TypeError{} = rejection(Writer.ready(old))
          :closed -> assert %TypeError{} = rejection(Writer.closed(old))
        end

        # The new writer holds the lock, and the stream is writable.
        assert WritableStream.locked?(stream)
        assert state(stream) == :writable
        assert await(Writer.ready(new)) == :ok
        assert Writer.desired_size(new) == 1
        assert await(Writer.write(new, :next)) == :ok
      end
    end
  end

  describe "the promise ready" do
    test "is the same promise until the backpressure starts again" do
      test = self()
      writer = WritableStream.get_writer(WritableStream.new(gated_sink(test)))

      first = Writer.ready(writer)
      assert Writer.ready(writer) == first
      assert await(first) == :ok

      # The write is in flight: the backpressure is on, and a new promise is
      # pending (WritableStreamUpdateBackpressure).
      write = Writer.write(writer, :a)
      assert_receive {:write, worker, :a}
      second = Writer.ready(writer)
      assert second != first
      assert Writer.ready(writer) == second
      assert Promise.peek(second) == :pending

      send(worker, :continue)
      assert await(write) == :ok
      assert await(second) == :ok
      assert Writer.ready(writer) == second
    end

    test "rejects at the start of an error, and the next request gets the same promise" do
      test = self()
      writer = WritableStream.get_writer(WritableStream.new(gated_sink(test)))
      write = Writer.write(writer, :a)
      assert_receive {:write, worker, :a}
      ready = Writer.ready(writer)

      # The stream is erroring: the write in flight continues.
      abort = Writer.abort(writer, :stop)
      assert rejection(ready) == :stop
      assert Writer.ready(writer) == ready

      send(worker, :continue)
      assert await(write) == :ok
      assert await(abort) == :ok
    end
  end

  describe "the promise closed" do
    test "is the same promise, and settles at the end of the stream" do
      writer = WritableStream.get_writer(WritableStream.new())
      closed = Writer.closed(writer)
      assert Writer.closed(writer) == closed
      assert Promise.peek(closed) == :pending

      assert await(Writer.close(writer)) == :ok
      assert await(closed) == :ok
      assert Writer.closed(writer) == closed

      errored = WritableStream.get_writer(WritableStream.new())
      assert :ok = await(Writer.abort(errored, :stop))
      closed = Writer.closed(errored)
      assert rejection(closed) == :stop
      assert Writer.closed(errored) == closed
    end
  end

  describe "the promise closed with an abort callback" do
    test "rejects when the abort callback of the sink is complete" do
      test = self()

      stream =
        WritableStream.new(%{
          abort: fn reason ->
            send(test, {:sink_abort, self(), reason})

            receive do
              :continue -> :ok
            end
          end
        })

      writer = WritableStream.get_writer(stream)
      closed = Writer.closed(writer)
      abort = Writer.abort(writer, :stop)
      assert_receive {:sink_abort, worker, :stop}

      # The stream is errored, and the abort callback runs: the promise
      # waits, as WritableStreamFinishErroring specifies.
      assert state(stream) == :errored
      assert Promise.peek(closed) == :pending

      send(worker, :continue)
      assert await(abort) == :ok
      assert rejection(closed) == :stop
    end
  end

  describe "a writer after a release of the lock by the stream" do
    test "has the stream still, as in the Streams Standard" do
      stream = WritableStream.new()
      writer = WritableStream.get_writer(stream)
      ready = Writer.ready(writer)

      # A terminal event of the engine releases the writer lock. The writer
      # does not release it: it gets the error of the stream.
      Web.Stream.terminate(stream.controller_pid, :error, :failed)
      assert state(stream) == :errored

      # The promise ready fulfilled before the error: the writer has a new
      # rejected promise (WritableStreamDefaultWriterEnsureReadyPromiseRejected).
      errored = Writer.ready(writer)
      assert errored != ready
      assert rejection(errored) == :failed
      assert Writer.ready(writer) == errored
      assert rejection(Writer.closed(writer)) == :failed
      assert rejection(Writer.write(writer, :late)) == :failed
      assert %TypeError{} = rejection(Writer.close(writer))
      assert await(Writer.abort(writer, :stop)) == :ok
      assert Writer.desired_size(writer) == nil
      assert :ok = Writer.release_lock(writer)
      assert %TypeError{} = rejection(Writer.closed(writer))
    end
  end

  describe "a promise of a writer whose process stopped" do
    test "gives a promise with the same outcome" do
      test = self()
      stream = WritableStream.new(gated_sink(test))

      {pid, monitor} =
        spawn_monitor(fn ->
          writer = WritableStream.get_writer(stream)
          _write = Writer.write(writer, :a)
          _ready = Writer.ready(writer)
          :ok = Writer.release_lock(writer)
          send(test, {:writer, writer})
        end)

      assert_receive {:writer, writer}
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
      assert_receive {:write, worker, :a}

      # The promises belong to the process of the writer, thus they stopped
      # with it. The stream keeps their outcome.
      assert %TypeError{message: "This writer is no longer locked."} =
               rejection(Writer.ready(writer))

      send(worker, :continue)
    end

    # The stop of the owner comes to its promise some time after the stop.
    # The test suspends the promise, thus the promise stays alive after its
    # owner stopped, as on a busy machine.
    test "gives a promise with the same outcome while the old promise did not stop yet" do
      test = self()
      stream = WritableStream.new(gated_sink(test))

      {pid, monitor} =
        spawn_monitor(fn ->
          writer = WritableStream.get_writer(stream)
          _write = Writer.write(writer, :a)
          ready = Writer.ready(writer)
          :ok = Writer.release_lock(writer)
          send(test, {:writer, writer, ready})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:writer, writer, old}
      assert_receive {:write, worker, :a}
      true = :erlang.suspend_process(old.pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

      promise = Writer.ready(writer)
      assert promise.pid != old.pid
      assert %TypeError{message: "This writer is no longer locked."} = rejection(promise)

      true = :erlang.resume_process(old.pid)
      send(worker, :continue)
    end
  end

  describe "a release of the lock" do
    test "rejects the pending promises with a TypeError, and the writer keeps them" do
      test = self()
      stream = WritableStream.new(gated_sink(test))
      writer = WritableStream.get_writer(stream)
      write = Writer.write(writer, :a)
      assert_receive {:write, worker, :a}
      ready = Writer.ready(writer)
      closed = Writer.closed(writer)

      assert :ok = Writer.release_lock(writer)
      assert %TypeError{} = rejection(ready)
      assert %TypeError{} = rejection(closed)
      assert Writer.ready(writer) == ready
      assert Writer.closed(writer) == closed

      # The write in flight completes. A new writer has new promises.
      send(worker, :continue)
      assert await(write) == :ok
      writer = WritableStream.get_writer(stream)
      assert Writer.closed(writer) != closed
      assert await(Writer.ready(writer)) == :ok
    end

    test "gives a new rejected promise for a promise that settled before the release" do
      writer = WritableStream.get_writer(WritableStream.new())
      ready = Writer.ready(writer)
      assert await(ready) == :ok

      assert :ok = Writer.release_lock(writer)
      assert %TypeError{} = rejection(Writer.ready(writer))
      assert %TypeError{} = rejection(Writer.closed(writer))
    end
  end

  describe "a size that is not valid" do
    test "from a size function that throws: the write rejects at once, after an error that waits" do
      test = self()
      size = fn chunk -> if chunk == :bad, do: throw(:size_failed), else: 1 end
      stream = WritableStream.new(gated_sink(test), high_water_mark: 4, size: size)
      writer = WritableStream.get_writer(stream)
      first = Writer.write(writer, :a)
      assert_receive {:write, worker, :a}

      # WritableStreamDefaultControllerGetChunkSize starts the error. The
      # write in flight continues.
      assert rejection(Writer.write(writer, :bad)) == :size_failed
      assert state(stream) == :erroring

      send(worker, :continue)
      assert await(first) == :ok
      assert rejection(Writer.closed(writer)) == :size_failed
      assert state(stream) == :errored
    end

    test "that is not a number: the write and a later abort reject when the error is complete" do
      test = self()
      size = fn chunk -> if chunk == :bad, do: -1, else: 1 end

      sink =
        test
        |> gated_sink()
        |> Map.put(:abort, fn reason -> send(test, {:sink_abort, reason}) end)

      stream = WritableStream.new(sink, high_water_mark: 4, size: size)
      writer = WritableStream.get_writer(stream)
      first = Writer.write(writer, :a)
      assert_receive {:write, worker, :a}

      # The write request is in the queue when the error starts
      # (WritableStreamDefaultControllerWrite). The abort finds the stream
      # erroring: it gets the stored error, and the sink gets no abort.
      bad = Writer.write(writer, :bad)
      abort = Writer.abort(writer, :stop)
      assert state(stream) == :erroring
      assert Promise.peek(bad) == :pending

      send(worker, :continue)
      assert await(first) == :ok
      assert %RangeError{} = rejection(bad)
      assert %RangeError{} = rejection(abort)
      refute_received {:sink_abort, _reason}
    end
  end
end
