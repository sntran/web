defmodule Web.StreamTest do
  use ExUnit.Case, async: true

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
      slots = ReadableStream.get_slots(pid)
      assert slots.state == :readable
      assert slots.desired_size == 3
    end

    test "consumer starts in writable state with correct desired_size" do
      {:ok, pid} = Web.Stream.start_link(WritableStream, high_water_mark: 2)
      slots = WritableStream.get_slots(pid)
      assert slots.state == :writable
      assert slots.desired_size == 2
    end

    test "producer_consumer starts in writable state" do
      ts = TransformStream.new(%{})
      slots = ReadableStream.get_slots(ts.readable.controller_pid)
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

      assert {:ok, "x"} = ReadableStream.read_all(stream)
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
      write_task = Task.async(fn -> WritableStreamDefaultWriter.write(writer, "a") end)
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
      ReadableStream.cancel(stream.controller_pid, :user_cancel)

      assert_receive {:cancelled, :user_cancel}
      assert ReadableStream.get_slots(stream.controller_pid).state == :closed
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
      _write_task = Task.async(fn -> WritableStreamDefaultWriter.write(writer, "x") end)
      assert_receive {:write_started, _}
      Process.sleep(50)

      WritableStreamDefaultWriter.abort(writer, :force_abort)
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
      assert ReadableStream.get_slots(pid).state == :errored
    end

    test "write errors transition stream to errored" do
      stream =
        WritableStream.new(%{
          write: fn _chunk, _ctrl -> raise "write failed" end
        })

      writer = WritableStream.get_writer(stream)

      assert_raise Web.TypeError, fn ->
        WritableStreamDefaultWriter.write(writer, "x")
      end

      Process.sleep(50)
      assert WritableStream.get_slots(stream.controller_pid).state == :errored
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
      WritableStreamDefaultWriter.write(writer, "hello")
      WritableStreamDefaultWriter.write(writer, " world")
      WritableStreamDefaultWriter.close(writer)

      assert {:ok, "hello world"} = ReadableStream.read_all(ts.readable)
    end

    test "transform function maps chunks" do
      ts =
        TransformStream.new(%{
          transform: fn chunk, ctrl, state ->
            Web.ReadableStreamDefaultController.enqueue(ctrl, String.upcase(chunk))
            {:ok, state}
          end
        })

      writer = WritableStream.get_writer(ts.writable)
      WritableStreamDefaultWriter.write(writer, "hello")
      WritableStreamDefaultWriter.write(writer, " world")
      WritableStreamDefaultWriter.close(writer)

      assert {:ok, "HELLO WORLD"} = ReadableStream.read_all(ts.readable)
    end

    test "transform function with arity 2" do
      ts =
        TransformStream.new(%{
          transform: fn chunk, ctrl ->
            Web.ReadableStreamDefaultController.enqueue(ctrl, chunk <> "!")
          end
        })

      writer = WritableStream.get_writer(ts.writable)
      WritableStreamDefaultWriter.write(writer, "hi")
      WritableStreamDefaultWriter.close(writer)

      assert {:ok, "hi!"} = ReadableStream.read_all(ts.readable)
    end

    test "flush function enqueues final data before close" do
      ts =
        TransformStream.new(%{
          transform: fn chunk, ctrl, state ->
            Web.ReadableStreamDefaultController.enqueue(ctrl, chunk)
            {:ok, state}
          end,
          flush: fn ctrl, state ->
            Web.ReadableStreamDefaultController.enqueue(ctrl, "END")
            {:ok, state}
          end
        })

      writer = WritableStream.get_writer(ts.writable)
      WritableStreamDefaultWriter.write(writer, "A")
      WritableStreamDefaultWriter.close(writer)

      assert {:ok, "AEND"} = ReadableStream.read_all(ts.readable)
    end

    test "flush function with arity 1" do
      ts =
        TransformStream.new(%{
          flush: fn ctrl ->
            Web.ReadableStreamDefaultController.enqueue(ctrl, "flushed")
          end
        })

      writer = WritableStream.get_writer(ts.writable)
      WritableStreamDefaultWriter.close(writer)

      assert {:ok, "flushed"} = ReadableStream.read_all(ts.readable)
    end

    test "cancel callback is called on cancellation" do
      parent = self()

      ts =
        TransformStream.new(%{
          cancel: fn reason ->
            send(parent, {:transform_cancelled, reason})
          end
        })

      ReadableStream.cancel(ts.readable.controller_pid, :stop)
      assert_receive {:transform_cancelled, :stop}
    end

    test "TransformStream can be enumerated" do
      ts =
        TransformStream.new(%{
          transform: fn chunk, ctrl, state ->
            Web.ReadableStreamDefaultController.enqueue(ctrl, chunk * 2)
            {:ok, state}
          end
        })

      writer = WritableStream.get_writer(ts.writable)

      for n <- 1..3 do
        WritableStreamDefaultWriter.write(writer, n)
      end

      WritableStreamDefaultWriter.close(writer)

      assert Enum.to_list(ts.readable) == [2, 4, 6]
    end

    test "TransformStream with high_water_mark option" do
      ts = TransformStream.new(%{}, high_water_mark: 5)
      slots = ReadableStream.get_slots(ts.readable.controller_pid)
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
          transform: fn _chunk, _ctrl, _state ->
            raise "transform failed"
          end
        })

      writer = WritableStream.get_writer(ts.writable)

      assert_raise Web.TypeError, fn ->
        WritableStreamDefaultWriter.write(writer, "x")
      end

      Process.sleep(50)
      assert ReadableStream.get_slots(ts.readable.controller_pid).state == :errored
    end

    test "terminate without cancel function completes gracefully on cancel" do
      ts = TransformStream.new(%{})
      ReadableStream.cancel(ts.readable.controller_pid)
      slots = ReadableStream.get_slots(ts.readable.controller_pid)
      assert slots.state == :closed
    end
  end

  describe "Web.Stream get_slots" do
    test "get_slots returns all engine internals with state key" do
      {:ok, pid} = Web.Stream.start_link(ReadableStream, high_water_mark: 2)
      # Wait briefly for the init pull task (for nil source) to complete
      Process.sleep(50)
      slots = ReadableStream.get_slots(pid)

      assert slots.state == :readable
      assert slots.hwm == 2
      assert :queue.is_empty(slots.queue)
      assert :queue.is_empty(slots.read_requests)
      assert slots.reader_pid == nil
      assert slots.disturbed == false
      assert slots.pulling == false
    end

    test "get_slots includes desired_size" do
      stream =
        WritableStream.new(%{
          write: fn _chunk, _ctrl -> :ok end
        })

      slots = WritableStream.get_slots(stream.controller_pid)
      assert slots.desired_size == 1
    end

    test "terminal states always report nil desired size" do
      closed_stream = WritableStream.new()
      closed_writer = WritableStream.get_writer(closed_stream)

      assert :ok = WritableStreamDefaultWriter.close(closed_writer)
      assert WritableStream.desired_size(closed_stream) == nil
      assert :ok = WritableStreamDefaultWriter.release_lock(closed_writer)

      errored_stream = WritableStream.new()
      errored_writer = WritableStream.get_writer(errored_stream)

      assert :ok = WritableStreamDefaultWriter.abort(errored_writer, :boom)

      assert_wait(fn ->
        WritableStream.get_slots(errored_stream.controller_pid).state == :errored
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
          try do
            WritableStreamDefaultWriter.write(writer, "x")
          rescue
            error in TypeError -> {:errored, error.message}
          end
        end)

      assert_receive {:write_task_started, sink_task_pid}
      assert :ok = WritableStreamDefaultWriter.abort(writer, :abort_now)

      Process.sleep(50)
      refute Process.alive?(sink_task_pid)
      assert {:ok, {:errored, message}} = Task.yield(write_task, 1_000)
      assert message in ["The stream is errored.", "This writer is no longer locked."]
    end

    test "transform bridge check blocks ready when readable queue is saturated" do
      ts = TransformStream.new(%{}, high_water_mark: 1)
      writer = WritableStream.get_writer(ts.writable)

      assert :ok = WritableStreamDefaultWriter.write(writer, "a")
      assert ReadableStream.get_slots(ts.readable.controller_pid).desired_size == 0

      ready_task = Task.async(fn -> WritableStreamDefaultWriter.ready(writer) end)
      assert Task.yield(ready_task, 100) == nil

      reader = ReadableStream.get_reader(ts.readable)
      assert Web.ReadableStreamDefaultReader.read(reader) == "a"
      assert {:ok, :ok} = Task.yield(ready_task, 1_000)
      assert :ok = Web.ReadableStreamDefaultReader.release_lock(reader)
      assert :ok = WritableStreamDefaultWriter.release_lock(writer)
    end

    test "transform desired size uses readable branch capacity when branch sizes are present" do
      ts = TransformStream.new(%{}, high_water_mark: 2)
      pid = ts.readable.controller_pid

      :gen_statem.cast(pid, {:branch_desired_size, self(), 1})
      Process.sleep(25)

      assert WritableStream.desired_size(ts.writable) == 1
    end

    test "fan-out check propagates pull failure to tee branches" do
      source = %{
        pull: fn _controller ->
          raise "pull failed"
        end
      }

      stream = ReadableStream.new(source)
      {left, right} = ReadableStream.tee(stream)

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

      assert_raise TypeError, "The stream is errored.", fn ->
        WritableStreamDefaultWriter.write(writer, "slow")
      end

      assert_wait(fn ->
        slots = WritableStream.get_slots(stream.controller_pid)
        slots.state == :errored and slots.error_reason == {:error, {:task_timeout, :write}}
      end)
    end

    test "write callback can return {:ok, state, extra} and preserve flow" do
      parent = self()

      stream =
        WritableStream.new(%{
          write: fn chunk, _controller ->
            send(parent, {:triple_ok_write, chunk})
            {:ok, %{seen: chunk}, :metadata}
          end
        })

      writer = WritableStream.get_writer(stream)

      assert :ok = WritableStreamDefaultWriter.write(writer, "triple")
      assert_receive {:triple_ok_write, "triple"}
    end

    test "transform callback can return {:ok, state, extra}" do
      ts =
        TransformStream.new(%{
          transform: fn chunk, ctrl, state ->
            Web.ReadableStreamDefaultController.enqueue(ctrl, chunk)
            {:ok, state, :extra}
          end
        })

      writer = WritableStream.get_writer(ts.writable)
      assert :ok = WritableStreamDefaultWriter.write(writer, "x")
      assert :ok = WritableStreamDefaultWriter.close(writer)
      assert {:ok, "x"} = ReadableStream.read_all(ts.readable)
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

      assert_raise TypeError, "The stream is errored.", fn ->
        WritableStreamDefaultWriter.close(writer)
      end

      assert_wait(fn ->
        slots = WritableStream.get_slots(stream.controller_pid)
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
        slots = ReadableStream.get_slots(pid)
        slots.state == :errored and slots.error_reason == {:error, {:task_timeout, :pull}}
      end)
    end
  end

  describe "Web.Stream callback rescue/catch paths" do
    test "source start callback exception transitions stream to errored state" do
      {:ok, pid} =
        ReadableStream.start_link(
          source: %{start: fn _ctrl -> raise "source start failed" end}
        )

      Process.sleep(50)
      assert ReadableStream.get_slots(pid).state == :errored
    end

    test "pull throw transitions stream to errored (catch clause)" do
      {:ok, pid} =
        ReadableStream.start_link(
          source: %{pull: fn _ctrl -> throw :pull_thrown end}
        )

      Process.sleep(100)
      assert ReadableStream.get_slots(pid).state == :errored
    end

    test "flush callback throw errors the stream (catch clause)" do
      stream =
        WritableStream.new(%{close: fn _ctrl -> throw :flush_thrown end})

      writer = WritableStream.get_writer(stream)

      assert_raise Web.TypeError, fn ->
        WritableStreamDefaultWriter.close(writer)
      end

      assert WritableStream.get_slots(stream.controller_pid).state == :errored
    end

    test "flush callback exception errors the stream (rescue clause)" do
      stream = WritableStream.new(%{close: fn _ctrl -> raise "flush error" end})
      writer = WritableStream.get_writer(stream)

      assert_raise Web.TypeError, fn ->
        WritableStreamDefaultWriter.close(writer)
      end

      assert WritableStream.get_slots(stream.controller_pid).state == :errored
    end

    test "abort terminate callback raise is caught by rescue clause" do
      ts = TransformStream.new(%{cancel: fn _reason -> raise "cancel error" end})
      writer = WritableStream.get_writer(ts.writable)
      assert :ok = WritableStreamDefaultWriter.abort(writer, :reason)
      Process.sleep(50)
      assert WritableStream.get_slots(ts.writable.controller_pid).state == :errored
    end

    test "abort terminate callback throw is caught by catch clause" do
      ts = TransformStream.new(%{cancel: fn _reason -> throw :my_throw end})
      writer = WritableStream.get_writer(ts.writable)
      assert :ok = WritableStreamDefaultWriter.abort(writer, :reason)
      Process.sleep(50)
      assert WritableStream.get_slots(ts.writable.controller_pid).state == :errored
    end
  end

  describe "Web.Stream closed/3 edge cases" do
    test "non-owner write on closed stream returns :not_locked_by_writer" do
      stream = WritableStream.new(%{})
      writer = WritableStream.get_writer(stream)
      WritableStreamDefaultWriter.close(writer)
      non_owner = spawn(fn -> :ok end)
      result = :gen_statem.call(stream.controller_pid, {:write, non_owner, "chunk"})
      assert result == {:error, :not_locked_by_writer}
    end

    test "non-owner close on closed stream returns :not_locked_by_writer" do
      stream = WritableStream.new(%{})
      writer = WritableStream.get_writer(stream)
      WritableStreamDefaultWriter.close(writer)
      non_owner = spawn(fn -> :ok end)
      result = :gen_statem.call(stream.controller_pid, {:close, non_owner})
      assert result == {:error, :not_locked_by_writer}
    end

    test "non-owner abort on closed stream returns :not_locked_by_writer" do
      stream = WritableStream.new(%{})
      writer = WritableStream.get_writer(stream)
      WritableStreamDefaultWriter.close(writer)
      non_owner = spawn(fn -> :ok end)
      result = :gen_statem.call(stream.controller_pid, {:abort, non_owner, :reason})
      assert result == {:error, :not_locked_by_writer}
    end

    test "transform callback with non-standard return preserves previous state" do
      ts = TransformStream.new(%{transform: fn _chunk, _ctrl, _state -> :not_an_ok_tuple end})
      writer = WritableStream.get_writer(ts.writable)
      assert :ok = WritableStreamDefaultWriter.write(writer, "test")
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
