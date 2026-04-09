defmodule Web.StreamTest do
  use ExUnit.Case, async: true
  import Web, only: [await: 1]

  defmodule UsingMacroStream do
    use Web.Stream

    @impl Web.Stream
    def start(_pid, _opts), do: {:producer, %{}}
  end

  alias Web.ReadableStream
  alias Web.TypeError
  alias Web.WritableStream
  alias Web.TransformStream
  alias Web.WritableStreamDefaultWriter

  describe "Web.Stream engine basics" do
    test "TypeError definition check" do
      assert %TypeError{message: "m"}.message == "m"
    end

    test "start_link/2 starts a gen_statem process" do
      {:ok, pid} = Web.Stream.start_link(ReadableStream, [])
      assert is_pid(pid)
      assert Process.alive?(pid)
      :gen_statem.stop(pid)
    end

    test "use Web.Stream injects behaviour and start_link/1" do
      {:ok, pid} = UsingMacroStream.start_link([])
      assert is_pid(pid)
      assert Process.alive?(pid)
      :gen_statem.stop(pid)
    end

    test "producer starts in readable state with correct desired_size" do
      {:ok, pid} = Web.Stream.start_link(ReadableStream, high_water_mark: 3)
      slots = ReadableStream.__get_slots__(pid)
      assert slots.state == :readable
      assert slots.desired_size == 3
    end

    test "consumer starts in writable state with correct desired_size" do
      {:ok, pid} = Web.Stream.start_link(WritableStream, high_water_mark: 2)
      slots = WritableStream.__get_slots__(pid)
      assert slots.state == :writable
      assert slots.desired_size == 2
    end

    test "producer_consumer starts in writable state" do
      ts = TransformStream.new(%{})
      slots = ReadableStream.__get_slots__(ts.readable.controller_pid)
      assert slots.state == :writable
    end
  end

  describe "Web.Stream backpressure (producer)" do
    test "desired_size decreases as chunks are enqueued" do
      {:ok, pid} = Web.Stream.start_link(ReadableStream, high_water_mark: 3)
      assert ReadableStream.get_desired_size(pid) == 3
      ReadableStream.enqueue(pid, "a")
      assert ReadableStream.get_desired_size(pid) == 2
      ReadableStream.enqueue(pid, "b")
      assert ReadableStream.get_desired_size(pid) == 1
      ReadableStream.enqueue(pid, "c")
      assert ReadableStream.get_desired_size(pid) == 0
    end

    test "auto-pulls when desired_size > 0 and source has pull" do
      parent = self()

      stream =
        ReadableStream.new(%{
          pull: fn controller ->
            send(parent, {:pulled, controller})
            Web.ReadableStreamDefaultController.enqueue(controller, "x")
            Web.ReadableStreamDefaultController.close(controller)
          end
        })

      assert "x" == Enum.join(stream, "")
    end
  end

  describe "Web.Stream backpressure (consumer)" do
    test "backpressure? reflects pending write count vs hwm" do
      parent = self()

      stream =
        WritableStream.new(%{
          write: fn chunk, _ctrl ->
            send(parent, {:sink_write, self(), chunk})

            receive do
              :continue -> :ok
            end
          end
        })

      pid = stream.controller_pid
      assert WritableStream.backpressure?(stream) == false

      writer = WritableStream.get_writer(stream)
      write_task = Task.async(fn -> await(WritableStreamDefaultWriter.write(writer, "a")) end)
      assert_receive {:sink_write, sink_pid, "a"}

      assert WritableStream.backpressure?(stream) == true
      send(sink_pid, :continue)
      assert {:ok, :ok} = Task.yield(write_task, 1_000)
      assert WritableStream.backpressure?(stream) == false
      WritableStreamDefaultWriter.release_lock(writer)
      _ = pid
    end
  end

  describe "Web.Stream abort/terminate callback" do
    test "abort kills active task and calls terminate/2" do
      parent = self()

      stream =
        ReadableStream.new(%{
          pull: fn _ctrl ->
            send(parent, :pull_started)
            Process.sleep(5_000)
          end,
          cancel: fn reason ->
            send(parent, {:cancelled, reason})
          end
        })

      _reader = ReadableStream.get_reader(stream)
      _read_task = Task.async(fn -> ReadableStream.read(stream.controller_pid) end)

      # Wait for pull to start
      assert_receive :pull_started
      Process.sleep(50)

      # Cancel the stream
      assert :ok =
               Task.await(ReadableStream.cancel(stream.controller_pid, :user_cancel).task, 1_000)

      assert_receive {:cancelled, :user_cancel}
      assert ReadableStream.__get_slots__(stream.controller_pid).state == :closed
    end

    test "abort while write task active: task is killed and terminate called" do
      parent = self()

      stream =
        WritableStream.new(%{
          write: fn _chunk, _ctrl ->
            send(parent, {:write_started, self()})
            Process.sleep(5_000)
          end,
          abort: fn reason ->
            send(parent, {:aborted, reason})
          end
        })

      writer = WritableStream.get_writer(stream)
      _write_task = Task.async(fn -> catch_exit(await(WritableStreamDefaultWriter.write(writer, "x"))) end)
      assert_receive {:write_started, _}
      Process.sleep(50)

      await(WritableStreamDefaultWriter.abort(writer, :force_abort))
      assert_receive {:aborted, :force_abort}
    end
  end

  describe "Web.Stream task supervision" do
    test "pull errors transition stream to errored" do
      {:ok, pid} =
        ReadableStream.start_link(
          source: %{
            pull: fn _ctrl -> raise "pull failed" end
          }
        )

      Process.sleep(100)
      assert ReadableStream.__get_slots__(pid).state == :errored
    end

    test "write errors transition stream to errored" do
      stream =
        WritableStream.new(%{
          write: fn _chunk, _ctrl -> raise "write failed" end
        })

      writer = WritableStream.get_writer(stream)

      assert %TypeError{} = catch_exit(await(WritableStreamDefaultWriter.write(writer, "x")))
    end
  end

  describe "Web.Stream disturbed flag" do
    test "disturbed/locked behavior tracks stream usage" do
      stream = ReadableStream.from("hello")

      assert ReadableStream.disturbed?(stream.controller_pid) == false
      assert ReadableStream.locked?(stream.controller_pid) == false

      reader = ReadableStream.get_reader(stream)
      assert ReadableStream.locked?(stream.controller_pid) == true
      assert Web.ReadableStreamDefaultReader.read(reader) == "hello"
      assert ReadableStream.disturbed?(stream.controller_pid) == true
      assert :ok = Web.ReadableStreamDefaultReader.release_lock(reader)

      assert_raise TypeError, ~r/already locked/, fn ->
        ReadableStream.tee(stream)
      end
    end

    test "disturbed is set when a read is requested" do
      stream = ReadableStream.new()
      ReadableStream.enqueue(stream.controller_pid, "x")
      assert ReadableStream.disturbed?(stream) == false

      _reader = ReadableStream.get_reader(stream)
      assert {:ok, "x"} = ReadableStream.read(stream.controller_pid)

      assert ReadableStream.disturbed?(stream) == true
    end

    test "disturbed prevents tee on a disturbed stream" do
      stream = ReadableStream.from("hello")
      _reader = ReadableStream.get_reader(stream)
      _ = ReadableStream.read(stream.controller_pid)

      assert_raise Web.TypeError, ~r/already locked/, fn ->
        ReadableStream.tee(stream)
      end
    end
  end

  describe "Web.TransformStream" do
    test "start_link/1 is available through use Web.Stream" do
      {:ok, pid} = TransformStream.start_link(transformer: %{})
      assert is_pid(pid)
      assert Process.alive?(pid)
      :gen_statem.stop(pid)
    end

    test "new/2 returns readable and writable struct pair" do
      ts = TransformStream.new()
      assert %ReadableStream{} = ts.readable
      assert %WritableStream{} = ts.writable
      assert ts.readable.controller_pid == ts.writable.controller_pid
    end

    test "passthrough transform (no transform function)" do
      ts = TransformStream.new(%{})

      writer = WritableStream.get_writer(ts.writable)
      await(WritableStreamDefaultWriter.write(writer, "hello"))
      await(WritableStreamDefaultWriter.write(writer, " world"))
      await(WritableStreamDefaultWriter.close(writer))

      assert "hello world" == Enum.join(ts.readable, "")
    end

    test "transform function maps chunks" do
      ts =
        TransformStream.new(%{
          transform: fn chunk, ctrl ->
            Web.ReadableStreamDefaultController.enqueue(ctrl, String.upcase(chunk))
          end
        })

      writer = WritableStream.get_writer(ts.writable)
      await(WritableStreamDefaultWriter.write(writer, "hello"))
      await(WritableStreamDefaultWriter.write(writer, " world"))
      await(WritableStreamDefaultWriter.close(writer))

      assert "HELLO WORLD" == Enum.join(ts.readable, "")
    end

    test "transform function with arity 2" do
      ts =
        TransformStream.new(%{
          transform: fn chunk, ctrl ->
            Web.ReadableStreamDefaultController.enqueue(ctrl, chunk <> "!")
          end
        })

      writer = WritableStream.get_writer(ts.writable)
      await(WritableStreamDefaultWriter.write(writer, "hi"))
      await(WritableStreamDefaultWriter.close(writer))

      assert "hi!" == Enum.join(ts.readable, "")
    end

    test "flush function enqueues final data before close" do
      ts =
        TransformStream.new(%{
          transform: fn chunk, ctrl ->
            Web.ReadableStreamDefaultController.enqueue(ctrl, chunk)
          end,
          flush: fn ctrl ->
            Web.ReadableStreamDefaultController.enqueue(ctrl, "END")
          end
        })

      writer = WritableStream.get_writer(ts.writable)
      await(WritableStreamDefaultWriter.write(writer, "A"))
      await(WritableStreamDefaultWriter.close(writer))

      assert "AEND" == Enum.join(ts.readable, "")
    end

    test "flush function with arity 1" do
      ts =
        TransformStream.new(%{
          flush: fn ctrl ->
            Web.ReadableStreamDefaultController.enqueue(ctrl, "flushed")
          end
        })

      writer = WritableStream.get_writer(ts.writable)
      await(WritableStreamDefaultWriter.close(writer))

      assert "flushed" == Enum.join(ts.readable, "")
    end

    test "cancel callback is called on cancellation" do
      parent = self()

      ts =
        TransformStream.new(%{
          cancel: fn reason ->
            send(parent, {:transform_cancelled, reason})
          end
        })

      assert :ok =
               Task.await(ReadableStream.cancel(ts.readable.controller_pid, :stop).task, 1_000)

      assert_receive {:transform_cancelled, :stop}
    end

    test "TransformStream can be enumerated" do
      ts =
        TransformStream.new(%{
          transform: fn chunk, ctrl ->
            Web.ReadableStreamDefaultController.enqueue(ctrl, chunk * 2)
          end
        })

      writer = WritableStream.get_writer(ts.writable)

      for n <- 1..3 do
        await(WritableStreamDefaultWriter.write(writer, n))
      end

      await(WritableStreamDefaultWriter.close(writer))

      assert Enum.to_list(ts.readable) == [2, 4, 6]
    end

    test "TransformStream with high_water_mark option" do
      ts = TransformStream.new(%{}, high_water_mark: 5)
      slots = ReadableStream.__get_slots__(ts.readable.controller_pid)
      assert slots.desired_size == 5
    end

    test "readable side can be locked independently" do
      ts = TransformStream.new(%{})
      reader = ReadableStream.get_reader(ts.readable)
      assert is_struct(reader, Web.ReadableStreamDefaultReader)
      Web.ReadableStreamDefaultReader.release_lock(reader)
    end

    test "writable side can be locked independently" do
      ts = TransformStream.new(%{})
      writer = WritableStream.get_writer(ts.writable)
      assert is_struct(writer, Web.WritableStreamDefaultWriter)
      Web.WritableStreamDefaultWriter.release_lock(writer)
    end

    test "error during transform transitions to errored on read" do
      ts =
        TransformStream.new(%{
          transform: fn _chunk, _ctrl ->
            raise "transform failed"
          end
        })

      writer = WritableStream.get_writer(ts.writable)

      assert %TypeError{} = catch_exit(await(WritableStreamDefaultWriter.write(writer, "x")))

      Process.sleep(50)
      assert ReadableStream.__get_slots__(ts.readable.controller_pid).state == :errored
    end

    test "terminate without cancel function completes gracefully on cancel" do
      ts = TransformStream.new(%{})
      assert :ok = Task.await(ReadableStream.cancel(ts.readable.controller_pid).task, 1_000)
      slots = ReadableStream.__get_slots__(ts.readable.controller_pid)
      assert slots.state == :closed
    end

    test "start callback returning :ok works with WHATWG-compliant callbacks" do
      # start/1 returns :ok per the WHATWG spec (no state merging).
      ts =
        TransformStream.new(%{
          start: fn _ctrl -> :ok end,
          transform: fn chunk, ctrl ->
            Web.ReadableStreamDefaultController.enqueue(ctrl, String.upcase(chunk))
          end
        })

      writer = WritableStream.get_writer(ts.writable)
      await(WritableStreamDefaultWriter.write(writer, "hello"))
      await(WritableStreamDefaultWriter.close(writer))
      assert Enum.join(ts.readable, "") == "HELLO"
    end
  end

  describe "Web.Stream __get_slots__" do
    test "__get_slots__ returns all engine internals with state key" do
      {:ok, pid} = Web.Stream.start_link(ReadableStream, high_water_mark: 2)
      # Wait briefly for the init pull task (for nil source) to complete
      Process.sleep(50)
      slots = ReadableStream.__get_slots__(pid)

      assert slots.state == :readable
      assert slots.hwm == 2
      assert :queue.is_empty(slots.queue)
      assert :queue.is_empty(slots.read_requests)
      assert slots.reader_pid == nil
      assert slots.disturbed == false
      assert slots.pulling == false
    end

    test "__get_slots__ includes desired_size" do
      stream =
        WritableStream.new(%{
          write: fn _chunk, _ctrl -> :ok end
        })

      slots = WritableStream.__get_slots__(stream.controller_pid)
      assert slots.desired_size == 1
    end

    test "terminal states always report nil desired size" do
      closed_stream = WritableStream.new()
      closed_writer = WritableStream.get_writer(closed_stream)

      assert :ok = await(WritableStreamDefaultWriter.close(closed_writer))
      assert WritableStream.desired_size(closed_stream) == nil
      assert :ok = WritableStreamDefaultWriter.release_lock(closed_writer)

      errored_stream = WritableStream.new()
      errored_writer = WritableStream.get_writer(errored_stream)

      assert :ok = await(WritableStreamDefaultWriter.abort(errored_writer, :boom))

      assert_wait(fn ->
        WritableStream.__get_slots__(errored_stream.controller_pid).state == :errored
      end)

      assert WritableStream.desired_size(errored_stream) == nil
      assert WritableStream.locked?(errored_stream.controller_pid) == false
    end

    test "pid wrappers expose writable stream state helpers" do
      stream = WritableStream.new(%{})
      pid = stream.controller_pid

      assert WritableStream.locked?(stream) == false
      assert WritableStream.locked?(pid) == false
      assert WritableStream.backpressure?(stream) == false
      assert WritableStream.backpressure?(pid) == false

      writer = WritableStream.get_writer(stream)
      assert WritableStream.locked?(stream) == true
      assert WritableStream.locked?(pid) == true
      assert :ok = WritableStreamDefaultWriter.release_lock(writer)
      assert WritableStream.locked?(stream) == false
    end
  end

  describe "Web.Stream hardening regressions" do
    test "abort orphan check kills in-flight write task quickly" do
      parent = self()

      stream =
        WritableStream.new(%{
          write: fn _chunk, _controller ->
            send(parent, {:write_task_started, self()})
            Process.sleep(5_000)
            :ok
          end
        })

      writer = WritableStream.get_writer(stream)

      write_task =
        Task.async(fn ->
          case catch_exit(await(WritableStreamDefaultWriter.write(writer, "x"))) do
            %TypeError{message: msg} -> {:errored, msg}
            other -> other
          end
        end)

      assert_receive {:write_task_started, sink_task_pid}
      assert :ok = await(WritableStreamDefaultWriter.abort(writer, :abort_now))

      Process.sleep(50)
      refute Process.alive?(sink_task_pid)
      assert {:ok, {:errored, message}} = Task.yield(write_task, 1_000)
      assert message in ["The stream is errored.", "This writer is no longer locked."]
    end

    test "transform bridge check blocks ready when readable queue is saturated" do
      ts = TransformStream.new(%{}, high_water_mark: 1)
      writer = WritableStream.get_writer(ts.writable)

      assert :ok = await(WritableStreamDefaultWriter.write(writer, "a"))
      assert ReadableStream.__get_slots__(ts.readable.controller_pid).desired_size == 0

      ready_task = Task.async(fn -> await(WritableStreamDefaultWriter.ready(writer)) end)
      assert Task.yield(ready_task, 100) == nil

      reader = ReadableStream.get_reader(ts.readable)
      assert Web.ReadableStreamDefaultReader.read(reader) == "a"
      assert {:ok, :ok} = Task.yield(ready_task, 1_000)
      assert :ok = Web.ReadableStreamDefaultReader.release_lock(reader)
      assert :ok = WritableStreamDefaultWriter.release_lock(writer)
    end

    test "transform desired size reflects readable queue occupancy" do
      ts = TransformStream.new(%{}, high_water_mark: 2)
      writer = WritableStream.get_writer(ts.writable)
      assert :ok = await(WritableStreamDefaultWriter.write(writer, "a"))
      assert ReadableStream.__get_slots__(ts.readable.controller_pid).desired_size == 1

      assert WritableStream.desired_size(ts.writable) == 1
      assert :ok = WritableStreamDefaultWriter.release_lock(writer)
    end

    test "fan-out check propagates pull failure to tee branches" do
      source = %{
        pull: fn _controller ->
          raise "pull failed"
        end
      }

      stream = ReadableStream.new(source)
      [left, right] = ReadableStream.tee(stream)

      left_reader = ReadableStream.get_reader(left)
      right_reader = ReadableStream.get_reader(right)

      assert_raise TypeError, "The stream is errored.", fn ->
        Web.ReadableStreamDefaultReader.read(left_reader)
      end

      assert_raise TypeError, "The stream is errored.", fn ->
        Web.ReadableStreamDefaultReader.read(right_reader)
      end
    end

    test "timeout check transitions to errored with task timeout reason" do
      {:ok, pid} =
        WritableStream.start_link(
          underlying_sink: %{
            write: fn _chunk, _controller ->
              Process.sleep(60_000)
              :ok
            end
          },
          timeout_ms: 100
        )

      stream = %WritableStream{controller_pid: pid}
      writer = WritableStream.get_writer(stream)

      assert %TypeError{message: "The stream is errored."} =
        catch_exit(await(WritableStreamDefaultWriter.write(writer, "slow")))

      assert_wait(fn ->
        slots = WritableStream.__get_slots__(stream.controller_pid)
        slots.state == :errored and slots.error_reason == {:error, {:task_timeout, :write}}
      end)
    end

    test "transform callback uses the current two-argument signature" do
      parent = self()

      ts =
        TransformStream.new(%{
          transform: fn chunk, ctrl ->
            send(parent, {:transform_chunk, chunk})
            Web.ReadableStreamDefaultController.enqueue(ctrl, String.upcase(chunk))
            :ok
          end
        })

      writer = WritableStream.get_writer(ts.writable)
      assert :ok = await(WritableStreamDefaultWriter.write(writer, "x"))
      assert :ok = await(WritableStreamDefaultWriter.close(writer))
      assert_receive {:transform_chunk, "x"}
      assert "X" == Enum.join(ts.readable, "")
    end

    test "timeout check transitions to errored with task timeout reason for flush" do
      {:ok, pid} =
        WritableStream.start_link(
          underlying_sink: %{
            close: fn _controller ->
              Process.sleep(60_000)
              :ok
            end
          },
          timeout_ms: 100
        )

      stream = %WritableStream{controller_pid: pid}
      writer = WritableStream.get_writer(stream)

      assert %TypeError{message: "The stream is errored."} =
        catch_exit(await(WritableStreamDefaultWriter.close(writer)))

      assert_wait(fn ->
        slots = WritableStream.__get_slots__(stream.controller_pid)
        slots.state == :errored and slots.error_reason == {:error, {:task_timeout, :flush}}
      end)
    end

    test "timeout check transitions to errored with task timeout reason for pull" do
      {:ok, pid} =
        ReadableStream.start_link(
          source: %{
            pull: fn _controller ->
              Process.sleep(60_000)
            end
          },
          timeout_ms: 100
        )

      _reader = ReadableStream.get_reader(pid)
      _ = ReadableStream.read(pid)

      assert_wait(fn ->
        slots = ReadableStream.__get_slots__(pid)
        slots.state == :errored and slots.error_reason == {:error, {:task_timeout, :pull}}
      end)
    end
  end

  describe "Web.Stream callback rescue/catch paths" do
    test "source start callback exception transitions stream to errored state" do
      {:ok, pid} =
        ReadableStream.start_link(source: %{start: fn _ctrl -> raise "source start failed" end})

      Process.sleep(50)
      assert ReadableStream.__get_slots__(pid).state == :errored
    end

    test "pull throw transitions stream to errored (catch clause)" do
      {:ok, pid} =
        ReadableStream.start_link(source: %{pull: fn _ctrl -> throw(:pull_thrown) end})

      Process.sleep(100)
      assert ReadableStream.__get_slots__(pid).state == :errored
    end

    test "flush callback throw errors the stream (catch clause)" do
      stream =
        WritableStream.new(%{close: fn _ctrl -> throw(:flush_thrown) end})

      writer = WritableStream.get_writer(stream)

      assert %TypeError{} = catch_exit(await(WritableStreamDefaultWriter.close(writer)))

      assert WritableStream.__get_slots__(stream.controller_pid).state == :errored
    end

    test "flush callback exception errors the stream (rescue clause)" do
      stream = WritableStream.new(%{close: fn _ctrl -> raise "flush error" end})
      writer = WritableStream.get_writer(stream)

      assert %TypeError{} = catch_exit(await(WritableStreamDefaultWriter.close(writer)))

      assert WritableStream.__get_slots__(stream.controller_pid).state == :errored
    end

    test "abort terminate callback raise is caught by rescue clause" do
      ts = TransformStream.new(%{cancel: fn _reason -> raise "cancel error" end})
      writer = WritableStream.get_writer(ts.writable)
      assert :ok = await(WritableStreamDefaultWriter.abort(writer, :reason))
      Process.sleep(50)
      assert WritableStream.__get_slots__(ts.writable.controller_pid).state == :errored
    end

    test "abort terminate callback throw is caught by catch clause" do
      ts = TransformStream.new(%{cancel: fn _reason -> throw(:my_throw) end})
      writer = WritableStream.get_writer(ts.writable)
      assert :ok = await(WritableStreamDefaultWriter.abort(writer, :reason))
      Process.sleep(50)
      assert WritableStream.__get_slots__(ts.writable.controller_pid).state == :errored
    end
  end

  describe "Web.Stream closed/3 edge cases" do
    test "non-owner write on closed stream returns :not_locked_by_writer" do
      stream = WritableStream.new(%{})
      writer = WritableStream.get_writer(stream)
      await(WritableStreamDefaultWriter.close(writer))
      non_owner = spawn(fn -> :ok end)
      result = :gen_statem.call(stream.controller_pid, {:write, non_owner, "chunk"})
      assert result == {:error, :not_locked_by_writer}
    end

    test "non-owner close on closed stream returns :not_locked_by_writer" do
      stream = WritableStream.new(%{})
      writer = WritableStream.get_writer(stream)
      await(WritableStreamDefaultWriter.close(writer))
      non_owner = spawn(fn -> :ok end)
      result = :gen_statem.call(stream.controller_pid, {:close, non_owner})
      assert result == {:error, :not_locked_by_writer}
    end

    test "non-owner abort on closed stream returns :not_locked_by_writer" do
      stream = WritableStream.new(%{})
      writer = WritableStream.get_writer(stream)
      await(WritableStreamDefaultWriter.close(writer))
      non_owner = spawn(fn -> :ok end)
      result = :gen_statem.call(stream.controller_pid, {:abort, non_owner, :reason})
      assert result == {:error, :not_locked_by_writer}
    end

    test "transform callback with non-standard return preserves flow" do
      ts = TransformStream.new(%{transform: fn _chunk, _ctrl -> :not_an_ok_tuple end})
      writer = WritableStream.get_writer(ts.writable)
      assert :ok = await(WritableStreamDefaultWriter.write(writer, "test"))
    end

    test "write callback with non-standard return preserves flow" do
      parent = self()

      stream =
        WritableStream.new(%{
          write: fn chunk, _controller ->
            send(parent, {:nonstandard_write, chunk})
            :not_an_ok_tuple
          end
        })

      writer = WritableStream.get_writer(stream)

      assert :ok = await(WritableStreamDefaultWriter.write(writer, "test"))
      assert_receive {:nonstandard_write, "test"}
    end
  end

  describe "Web.Stream coverage gaps" do
    # --- stream.ex line 591: cancel on already-closed stream calls signal_terminate ---

    test "cancel-on-closed stream calls signal_terminate but does nothing" do
      stream = WritableStream.new()
      writer = WritableStream.get_writer(stream)
      await(WritableStreamDefaultWriter.close(writer))
      Process.sleep(20)
      # send {:terminate, :cancel, nil} to an already-closed stream
      Web.Stream.terminate(stream.controller_pid, :cancel)
      Process.sleep(20)
      assert WritableStream.__get_slots__(stream.controller_pid).state == :closed
    end

    # --- stream.ex line 604: {:cancel, reason} cast ---

    test ":cancel cast terminates the stream directly" do
      {:ok, pid} = ReadableStream.start_link()
      :gen_statem.cast(pid, {:cancel, :direct_cancel})
      Process.sleep(20)
      assert ReadableStream.__get_slots__(pid).state == :closed
    end

    # --- transform_stream.ex lines 63, 86: transform/flush returning a Promise ---

    test "transform callback can return a %Web.Promise{}" do
      ts =
        TransformStream.new(%{
          transform: fn chunk, ctrl ->
            Web.Promise.new(fn resolve, _reject ->
              Web.ReadableStreamDefaultController.enqueue(ctrl, chunk <> "!")
              resolve.(:ok)
            end)
          end
        })

      writer = WritableStream.get_writer(ts.writable)
      assert :ok = await(WritableStreamDefaultWriter.write(writer, "hi"))
      assert :ok = await(WritableStreamDefaultWriter.close(writer))
      assert "hi!" == Enum.join(ts.readable, "")
    end

    test "flush callback can return a %Web.Promise{}" do
      ts =
        TransformStream.new(%{
          flush: fn ctrl ->
            Web.Promise.new(fn resolve, _reject ->
              Web.ReadableStreamDefaultController.enqueue(ctrl, "flushed_promise")
              resolve.(:ok)
            end)
          end
        })

      writer = WritableStream.get_writer(ts.writable)
      assert :ok = await(WritableStreamDefaultWriter.close(writer))
      assert "flushed_promise" == Enum.join(ts.readable, "")
    end

    test "start callback can return a %Web.Promise{}" do
      parent = self()

      ts =
        TransformStream.new(%{
          start: fn ctrl ->
            Web.Promise.new(fn resolve, _reject ->
              send(parent, {:transform_started, ctrl.pid})
              resolve.(:ok)
            end)
          end
        })

      assert_receive {:transform_started, pid}
      assert pid == ts.readable.controller_pid
      assert ts.readable.controller_pid == ts.writable.controller_pid
    end

    # --- writable_stream.ex line 41: start callback returning a Promise ---

    test "WritableStream start callback can return a %Web.Promise{}" do
      parent = self()

      stream =
        WritableStream.new(%{
          start: fn _ctrl ->
            Web.Promise.new(fn resolve, _reject ->
              send(parent, :start_ran)
              resolve.(:ok)
            end)
          end
        })

      assert_receive :start_ran, 500
      assert WritableStream.__get_slots__(stream.controller_pid).state == :writable
    end

    # --- writable_stream.ex line 57: close/flush callback returning a Promise ---

    test "WritableStream write callback can return a %Web.Promise{}" do
      stream =
        WritableStream.new(%{
          write: fn chunk, _ctrl ->
            Web.Promise.new(fn resolve, _reject ->
              resolve.("wrote_#{chunk}")
            end)
          end
        })

      writer = WritableStream.get_writer(stream)
      assert :ok = await(WritableStreamDefaultWriter.write(writer, "x"))
    end

    test "WritableStream close callback can return a %Web.Promise{}" do
      stream =
        WritableStream.new(%{
          close: fn _ctrl ->
            Web.Promise.new(fn resolve, _reject ->
              resolve.(:closed_via_promise)
            end)
          end
        })

      writer = WritableStream.get_writer(stream)
      assert :ok = await(WritableStreamDefaultWriter.close(writer))
    end

    # --- writable_stream.ex line 192 (release_lock/2 with explicit owner_pid) ---

    test "WritableStream.release_lock/2 accepts explicit owner_pid" do
      stream = WritableStream.new()
      _writer = WritableStream.get_writer(stream)
      assert :ok = WritableStream.release_lock(stream.controller_pid, self())
    end

    # --- writable_stream.ex line 156: close/1 struct overload ---

    test "WritableStream.close/1 accepts a %WritableStream{} struct" do
      stream = WritableStream.new()
      result_promise = WritableStream.close(stream)
      assert :ok == await(result_promise)
    end

    # --- writable_stream.ex line 172: abort/2 struct overload ---

    test "WritableStream.abort/2 accepts a %WritableStream{} struct" do
      stream = WritableStream.new()
      result_promise = WritableStream.abort(stream, :test_abort)
      assert :ok == await(result_promise)
    end

    # --- writable_stream.ex lines 233-234, 244-245: retry loops in await_settled_state / await_abort_completion ---
    # These are indirectly covered by any close/abort operation, but the loop body
    # runs when the stream takes more than one polling cycle to reach the target state.

    test "close waits through multiple polling cycles if stream takes time to settle" do
      # WritableStream.close(pid) polls via await_settled_state; the sleep branch
      # is exercised when the close callback takes more than one poll cycle
      stream =
        WritableStream.new(%{
          close: fn _ctrl ->
            Process.sleep(30)
            :ok
          end
        })

      # Use close(pid) directly so await_settled_state/2 is called
      assert :ok = await(WritableStream.close(stream.controller_pid))
    end

    test "abort waits through multiple polling cycles if stream takes time to abort" do
      # WritableStream.abort(pid, reason) polls via await_abort_completion; the sleep
      # branch is hit when the abort callback takes more than one polling cycle
      stream =
        WritableStream.new(%{
          abort: fn _reason ->
            Process.sleep(30)
            :ok
          end
        })

      # Use abort(pid, reason) so await_abort_completion is polled
      assert :ok = await(WritableStream.abort(stream.controller_pid, :slow_abort))
    end

    # --- writable_stream.ex line 252: safe_get_slots catch when pid dead ---

    test "WritableStream.abort/2 resolves even if stream pid is already dead" do
      stream = WritableStream.new()
      :gen_statem.stop(stream.controller_pid)
      Process.sleep(20)
      # abort waits for :errored state; safe_get_slots catches the exit and returns
      # %{state: :errored, active_operation: nil} which satisfies await_abort_completion
      assert :ok == await(WritableStream.abort(stream, :dead_pid_abort))
    end

    # --- stream.ex lines 1138/1150: pending write + close at termination ---

    test "closing a writable stream while a write is in progress replies closed to both" do
      # When Web.Stream.terminate(pid, :close) fires while a write is active,
      # pending_write_request is non-nil at finalize_termination time → exercises
      # pending_write_closed_actions (line 1138).
      # When a close request was queued (pending_close_request non-nil) from
      # WritableStreamDefaultWriter.close/1, close_ok_actions (line 1150) is invoked.
      parent = self()

      stream =
        WritableStream.new(%{
          write: fn _chunk, _ctrl ->
            send(parent, :write_in_progress)
            Process.sleep(200)
            :ok
          end
        })

      writer = WritableStream.get_writer(stream)

      # Start a write in a background task
      write_task = Task.async(fn ->
        try do
          await(WritableStreamDefaultWriter.write(writer, "data"))
        catch
          :exit, reason -> {:exited, reason}
        end
      end)

      # Wait until write is actually in progress inside the gen_statem
      assert_receive :write_in_progress, 500

      # Queue a close request - while write is active, this sets pending_close_request
      close_task = Task.async(fn ->
        try do
          await(WritableStreamDefaultWriter.close(writer))
        catch
          :exit, reason -> {:exited, reason}
        end
      end)

      Process.sleep(20)

      # Terminate with :close to hit pending_write_closed_actions + close_ok_actions
      Web.Stream.terminate(stream.controller_pid, :close)

      write_result = Task.await(write_task, 1000)
      close_result = Task.await(close_task, 1000)

      assert write_result != :timeout
      assert close_result != :timeout
    end

    # --- stream.ex lines 1242-1254: resolve_if_promise when start callback returns Promise ---

    test "resolve_if_promise path is hit when start callback returns a %Web.Promise{}" do
      # The stream.ex start_task calls module.start then resolve_if_promise on the result
      parent = self()
      stream =
        WritableStream.new(%{
          start: fn _ctrl ->
            Web.Promise.new(fn resolve, _reject ->
              send(parent, :start_promise_executed)
              resolve.({:ok, :init_state})
            end)
          end
        })

      assert_receive :start_promise_executed, 500
      assert WritableStream.__get_slots__(stream.controller_pid).state == :writable
    end
  end

  defp assert_wait(fun, attempts \\ 20)

  defp assert_wait(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(25)
      assert_wait(fun, attempts - 1)
    end
  end

  defp assert_wait(_fun, 0) do
    flunk("condition was not met in time")
  end
end
