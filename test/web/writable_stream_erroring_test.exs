defmodule Web.WritableStreamErroringTest do
  # The state "erroring" of a WritableStream, as the Streams Standard
  # specifies: an abort or an error of the controller does not stop a write
  # or a close that is in flight. The stream waits for it, and then it is
  # "errored". These tests control each step of the sink with messages.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.CountQueuingStrategy
  alias Web.TransformStream
  alias Web.TypeError
  alias Web.WritableStream
  alias Web.WritableStreamDefaultController, as: Controller
  alias Web.WritableStreamDefaultWriter, as: Writer

  defp rejection(promise), do: catch_exit(await(promise))

  defp state(stream), do: WritableStream.__get_slots__(stream.controller_pid).state

  # A sink that tells the test each call, and waits for `{:result, value}`
  # before it returns `value` from `write` and `close`. A value
  # `{:throw, reason}` is thrown.
  defp gated_sink(test) do
    %{
      write: fn chunk, controller ->
        send(test, {:write, self(), chunk, controller})
        gate()
      end,
      close: fn _controller ->
        send(test, {:close, self()})
        gate()
      end,
      abort: fn reason ->
        send(test, {:abort, reason})
        :ok
      end
    }
  end

  defp gate do
    receive do
      {:result, {:throw, reason}} -> throw(reason)
      {:result, value} -> value
    end
  end

  # A promise that is not settled yet. The stream answers the calls of one
  # process in their sequence, thus the call to the stream comes after the
  # requests of the promises.
  defp pending?(stream, promise) do
    _ = state(stream)
    Web.Promise.peek(promise) == :pending
  end

  describe "an abort during a write" do
    property "waits for the write, rejects the writes that wait, and then calls the abort of the sink" do
      check all(queued <- integer(0..5), result <- member_of([:ok, {:throw, :failed}])) do
        test = self()
        stream = WritableStream.new(Map.put(gated_sink(test), :high_water_mark, 10))
        writer = WritableStream.get_writer(stream)

        first = Writer.write(writer, :first)
        assert_receive {:write, sink, :first, _controller}
        waiting = for index <- 1..queued//1, do: Writer.write(writer, index)

        abort = Writer.abort(writer, :stop)
        assert state(stream) == :erroring
        assert pending?(stream, first)
        refute_received {:abort, _reason}

        send(sink, {:result, result})

        case result do
          :ok -> assert await(first) == :ok
          {:throw, reason} -> assert rejection(first) == reason
        end

        for promise <- waiting, do: assert(rejection(promise) == :stop)
        assert await(abort) == :ok
        assert_received {:abort, :stop}
        assert rejection(Writer.closed(writer)) == :stop
        assert state(stream) == :errored
      end
    end

    test "gives the same result to each caller, and calls the abort of the sink one time" do
      test = self()
      stream = WritableStream.new(gated_sink(test))
      writer = WritableStream.get_writer(stream)

      _write = Writer.write(writer, :chunk)
      assert_receive {:write, sink, :chunk, _controller}

      first = Writer.abort(writer, :first_reason)
      second = Writer.abort(writer, :second_reason)
      third = WritableStream.abort(stream.controller_pid, :third_reason)

      send(sink, {:result, :ok})

      assert await(first) == :ok
      assert await(second) == :ok
      assert await(third) == :ok
      assert_received {:abort, :first_reason}
      refute_received {:abort, _reason}
    end
  end

  describe "the abort of the sink" do
    test "runs before the rejection of the promise closed and of a close that waits" do
      test = self()

      stream =
        WritableStream.new(%{
          write: fn _chunk, _controller ->
            send(test, {:write, self()})

            receive do
              :continue -> :ok
            end
          end,
          abort: fn reason ->
            send(test, {:abort, self(), reason})

            receive do
              :continue -> :ok
            end
          end
        })

      writer = WritableStream.get_writer(stream)
      _write = Writer.write(writer, :chunk)
      close = Writer.close(writer)
      closed = Writer.closed(writer)
      abort = Writer.abort(writer, :stop)

      assert_receive {:write, worker}
      send(worker, :continue)
      assert_receive {:abort, abort_worker, :stop}

      # The stream is errored, and the abort of the sink is in progress.
      assert state(stream) == :errored
      assert pending?(stream, closed)
      assert pending?(stream, close)
      assert pending?(stream, abort)

      send(abort_worker, :continue)
      assert await(abort) == :ok
      assert rejection(close) == :stop
      assert rejection(closed) == :stop
    end
  end

  describe "an error of the controller" do
    test "during a write lets the write fulfil when the sink returns normally" do
      test = self()
      stream = WritableStream.new(gated_sink(test))
      writer = WritableStream.get_writer(stream)

      write = Writer.write(writer, :chunk)
      assert_receive {:write, sink, :chunk, controller}
      closed = Writer.closed(writer)

      assert :ok = Controller.error(controller, :boom)
      assert rejection(Writer.ready(writer)) == :boom
      assert Writer.desired_size(writer) == nil
      assert pending?(stream, closed)

      send(sink, {:result, :ok})

      assert await(write) == :ok
      assert rejection(closed) == :boom
      assert state(stream) == :errored
    end

    test "makes a later abort reject with the stored error, with no call of the sink" do
      test = self()
      stream = WritableStream.new(gated_sink(test))
      writer = WritableStream.get_writer(stream)

      _write = Writer.write(writer, :chunk)
      assert_receive {:write, sink, :chunk, controller}
      assert :ok = Controller.error(controller, :boom)

      abort = Writer.abort(writer, :stop)
      send(sink, {:result, :ok})

      assert rejection(abort) == :boom
      refute_received {:abort, _reason}
    end

    test "during a close does not error the stream when the close succeeds" do
      test = self()
      stream = WritableStream.new(gated_sink(test))
      writer = WritableStream.get_writer(stream)

      write = Writer.write(writer, :chunk)
      assert_receive {:write, sink, :chunk, controller}
      send(sink, {:result, :ok})
      assert await(write) == :ok

      close = Writer.close(writer)
      assert_receive {:close, sink}
      assert :ok = Controller.error(controller, :boom)
      abort = Writer.abort(writer, :stop)
      assert state(stream) == :erroring

      send(sink, {:result, :ok})

      # WritableStreamFinishInFlightClose: the stream closes, and the abort
      # request fulfils.
      assert await(close) == :ok
      assert await(abort) == :ok
      assert await(Writer.closed(writer)) == :ok
      assert state(stream) == :closed
      refute_received {:abort, _reason}
    end
  end

  describe "an abort during a close" do
    test "rejects with the failure of the close, and the stream has the abort reason" do
      test = self()
      stream = WritableStream.new(gated_sink(test))
      writer = WritableStream.get_writer(stream)

      close = Writer.close(writer)
      assert_receive {:close, sink}
      abort = Writer.abort(writer, :stop)

      send(sink, {:result, {:throw, :close_failed}})

      assert rejection(close) == :close_failed
      assert rejection(abort) == :close_failed
      assert rejection(Writer.closed(writer)) == :stop
      refute_received {:abort, _reason}
    end
  end

  describe "the requests of a stream that is erroring" do
    test "a write gives the stored error, or a TypeError when a close waits" do
      test = self()
      stream = WritableStream.new(gated_sink(test))
      writer = WritableStream.get_writer(stream)

      _write = Writer.write(writer, :chunk)
      assert_receive {:write, sink, :chunk, _controller}
      abort = Writer.abort(writer, :stop)

      assert rejection(Writer.write(writer, :late)) == :stop

      close = Writer.close(writer)
      assert %TypeError{message: "The stream is closing."} = rejection(Writer.close(writer))

      assert %TypeError{message: "The stream is closing."} =
               rejection(Writer.write(writer, :late))

      # A process that does not hold the lock gets a TypeError.
      other =
        Task.async(fn ->
          writer = %{writer | owner_pid: self()}
          {rejection(Writer.write(writer, :other)), rejection(Writer.close(writer))}
        end)

      assert {%TypeError{}, %TypeError{}} = Task.await(other)

      send(sink, {:result, :ok})

      # WritableStreamFinishErroring: the close rejects with the stored
      # error after the abort of the sink.
      assert await(abort) == :ok
      assert rejection(close) == :stop
    end

    test "a close waits, and rejects with the stored error" do
      test = self()

      stream =
        WritableStream.new(%{
          start: fn controller ->
            send(test, {:controller, controller})
            Web.Promise.new(fn resolve, _reject -> send(test, {:start, resolve}) end)
          end
        })

      assert_receive {:controller, controller}
      assert_receive {:start, resolve}

      # The function `start` is not complete: the stream is erroring.
      assert :ok = Controller.error(controller, :boom)
      assert state(stream) == :erroring

      close = WritableStream.close(stream)
      resolve.(:ok)

      assert rejection(close) == :boom
      assert state(stream) == :errored
    end
  end

  describe "the attribute desiredSize of a writer" do
    test "raises a TypeError after the release of the lock" do
      stream = WritableStream.new()
      writer = WritableStream.get_writer(stream)
      assert Writer.desired_size(writer) == 1

      assert :ok = Writer.release_lock(writer)

      assert_raise TypeError, "This writer is no longer locked.", fn ->
        Writer.desired_size(writer)
      end
    end

    test "is nil on an errored stream, also after the release of the lock" do
      stream = WritableStream.new()
      writer = WritableStream.get_writer(stream)
      assert :ok = await(Writer.abort(writer, :stop))
      assert Writer.desired_size(writer) == nil
      assert :ok = Writer.release_lock(writer)
      assert Writer.desired_size(writer) == nil
    end
  end

  describe "the promise ready" do
    test "fulfils when a write completes and the queue is below its limit, with writes in the queue" do
      test = self()
      stream = WritableStream.new(Map.put(gated_sink(test), :high_water_mark, 3))
      writer = WritableStream.get_writer(stream)

      _first = Writer.write(writer, 1)
      assert_receive {:write, sink, 1, _controller}
      _second = Writer.write(writer, 2)
      _third = Writer.write(writer, 3)
      ready = Writer.ready(writer)
      assert pending?(stream, ready)

      # The write 2 starts, and the write 3 waits: the desired size is 1.
      send(sink, {:result, :ok})
      assert await(ready) == :ok
      assert Writer.desired_size(writer) == 1
      assert_receive {:write, ^sink, 2, _controller}
    end

    test "fulfils when the writer closes the stream" do
      test = self()
      stream = WritableStream.new(gated_sink(test))
      writer = WritableStream.get_writer(stream)

      _write = Writer.write(writer, 1)
      assert_receive {:write, _sink, 1, _controller}
      ready = Writer.ready(writer)
      assert pending?(stream, ready)

      _close = Writer.close(writer)
      assert await(ready) == :ok
      assert await(Writer.ready(writer)) == :ok
    end
  end

  describe "the writable side of a transform stream" do
    test "an abort stops the transform that is in progress" do
      test = self()

      transform =
        TransformStream.new(
          %{
            transform: fn _chunk, _controller ->
              send(test, {:transform, self()})
              Process.sleep(:infinity)
            end
          },
          readable_strategy: CountQueuingStrategy.new(1)
        )

      writer = WritableStream.get_writer(transform.writable)
      write = Writer.write(writer, :chunk)
      assert_receive {:transform, worker}
      monitor = Process.monitor(worker)

      assert :ok = await(Writer.abort(writer, :stop))
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
      assert rejection(write) == :stop
    end
  end
end
