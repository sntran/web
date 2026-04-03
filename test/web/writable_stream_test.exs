defmodule Web.WritableStreamTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.TypeError
  alias Web.WritableStream
  alias Web.WritableStreamDefaultController
  alias Web.WritableStreamDefaultWriter

  test "new/1 validates the underlying sink type" do
    assert_raise ArgumentError, ~r/underlying_sink must be a map/, fn ->
      WritableStream.new(:not_a_map)
    end
  end

  test "pid wrappers expose the writable stream api" do
    parent = self()

    stream =
      WritableStream.new(%{
        write: fn chunk, _controller ->
          send(parent, {:sink_write, chunk})
          :ok
        end,
        close: fn _controller ->
          send(parent, :sink_close)
          :ok
        end,
        abort: fn reason ->
          send(parent, {:sink_abort, reason})
          :ok
        end
      })

    pid = stream.controller_pid

    assert WritableStream.locked?(stream) == false
    assert WritableStream.locked?(pid) == false
    assert WritableStream.backpressure?(stream) == false
    assert WritableStream.backpressure?(pid) == false
    assert WritableStream.desired_size(stream) == 1
    assert WritableStream.desired_size(pid) == 1

    assert :ok = WritableStream.get_writer(pid)
    assert :ok = WritableStream.write(pid, "chunk")
    assert_receive {:sink_write, "chunk"}
    assert :ok = WritableStream.ready(pid)
    assert :ok = WritableStream.close(pid)
    assert_receive :sink_close
    assert WritableStream.desired_size(stream) == nil
    assert :ok = WritableStream.release_lock(pid)

    abort_stream =
      WritableStream.new(%{
        abort: fn reason ->
          send(parent, {:sink_abort, reason})
          :ok
        end
      })

    abort_pid = abort_stream.controller_pid
    assert :ok = WritableStream.get_writer(abort_pid)
    assert :ok = WritableStream.abort(abort_pid, :pid_abort)
    assert_receive {:sink_abort, :pid_abort}
    assert {:error, :not_locked_by_writer} = WritableStream.release_lock(abort_pid)
  end

  test "controller helpers expose desired size and can error the stream" do
    parent = self()

    stream =
      WritableStream.new(%{
        start: fn controller ->
          send(
            parent,
            {:controller_size, WritableStreamDefaultController.desired_size(controller)}
          )

          WritableStreamDefaultController.error(controller, :boom)
        end
      })

    assert_receive {:controller_size, 1}
    assert_wait(fn -> WritableStream.get_slots(stream.controller_pid).state == :errored end)
    assert WritableStream.desired_size(stream) == nil
  end

  test "successful start callbacks leave the stream writable" do
    parent = self()

    stream =
      WritableStream.new(%{
        start: fn controller ->
          send(parent, {:start_ok, WritableStreamDefaultController.desired_size(controller)})
          :ok
        end
      })

    assert_receive {:start_ok, 1}
    assert_wait(fn -> WritableStream.get_slots(stream.controller_pid).state == :writable end)
  end

  test "default sink callbacks fall back to ok" do
    stream = WritableStream.new()
    writer = WritableStream.get_writer(stream)

    assert :ok = WritableStreamDefaultWriter.write(writer, "noop")
    assert :ok = WritableStreamDefaultWriter.close(writer)
    assert :ok = WritableStreamDefaultWriter.release_lock(writer)

    abort_stream = WritableStream.new()
    abort_writer = WritableStream.get_writer(abort_stream)

    assert :ok = WritableStreamDefaultWriter.abort(abort_writer, :no_abort_callback)

    assert_raise TypeError, "This writer is no longer locked.", fn ->
      WritableStreamDefaultWriter.release_lock(abort_writer)
    end
  end

  test "write/2 waits for a slow sink and ready/1 resolves when backpressure clears" do
    parent = self()

    stream =
      WritableStream.new(%{
        write: fn chunk, _controller ->
          send(parent, {:sink_write, self(), chunk})

          receive do
            :continue -> :ok
          end
        end
      })

    writer = WritableStream.get_writer(stream)
    write_task = Task.async(fn -> WritableStreamDefaultWriter.write(writer, "chunk-1") end)

    assert_receive {:sink_write, sink_task_pid, "chunk-1"}
    assert WritableStream.backpressure?(stream) == true
    assert WritableStreamDefaultWriter.desired_size(writer) == 0
    assert Task.yield(write_task, 50) == nil

    ready_task = Task.async(fn -> WritableStreamDefaultWriter.ready(writer) end)
    assert Task.yield(ready_task, 50) == nil

    send(sink_task_pid, :continue)

    assert {:ok, :ok} = Task.yield(write_task, 1_000)
    assert {:ok, :ok} = Task.yield(ready_task, 1_000)
    assert WritableStream.backpressure?(stream) == false
    assert WritableStreamDefaultWriter.desired_size(writer) == 1
  end

  test "queued writes drain before close and a second close sees the closing state" do
    parent = self()
    owner_pid = self()

    stream =
      WritableStream.new(%{
        write: fn chunk, _controller ->
          send(parent, {:sink_write, self(), chunk})

          receive do
            {:continue, ^chunk} -> :ok
          end
        end,
        close: fn _controller ->
          send(parent, :sink_closed)
          :ok
        end
      })

    pid = stream.controller_pid
    assert :ok = WritableStream.get_writer(pid)

    write_a = Task.async(fn -> WritableStream.write(pid, owner_pid, "a") end)
    assert_receive {:sink_write, sink_a, "a"}

    write_b = Task.async(fn -> WritableStream.write(pid, owner_pid, "b") end)

    assert_wait(fn ->
      WritableStream.get_slots(pid).queued_write_requests
      |> :queue.len()
      |> Kernel.==(1)
    end)

    close_task = Task.async(fn -> WritableStream.close(pid, owner_pid) end)

    assert_wait(fn ->
      slots = WritableStream.get_slots(pid)
      slots.state == :closing and not is_nil(slots.pending_close_request)
    end)

    assert {:error, :closing} = WritableStream.close(pid, owner_pid)

    send(sink_a, {:continue, "a"})
    assert {:ok, :ok} = Task.yield(write_a, 1_000)

    assert_receive {:sink_write, sink_b, "b"}
    send(sink_b, {:continue, "b"})

    assert {:ok, :ok} = Task.yield(write_b, 1_000)
    assert_receive :sink_closed
    assert {:ok, :ok} = Task.yield(close_task, 1_000)
  end

  test "erroring the stream rejects pending writes ready requests and close requests" do
    parent = self()
    owner_pid = self()

    stream =
      WritableStream.new(%{
        write: fn chunk, _controller ->
          send(parent, {:sink_write, self(), chunk})

          receive do
            :wait_forever -> :ok
          end
        end
      })

    pid = stream.controller_pid
    assert :ok = WritableStream.get_writer(pid)

    write_a = Task.async(fn -> WritableStream.write(pid, owner_pid, "a") end)
    assert_receive {:sink_write, _sink_pid, "a"}

    write_b = Task.async(fn -> WritableStream.write(pid, owner_pid, "b") end)

    assert_wait(fn ->
      WritableStream.get_slots(pid).queued_write_requests
      |> :queue.len()
      |> Kernel.==(1)
    end)

    ready_task = Task.async(fn -> WritableStream.ready(pid, owner_pid) end)
    close_task = Task.async(fn -> WritableStream.close(pid, owner_pid) end)

    assert_wait(fn ->
      slots = WritableStream.get_slots(pid)

      slots.state == :closing and
        not is_nil(slots.pending_close_request) and
        :queue.len(slots.ready_requests) == 1
    end)

    WritableStream.error(pid, :boom)

    assert {:ok, {:error, {:errored, :boom}}} = Task.yield(write_a, 1_000)
    assert {:ok, {:error, {:errored, :boom}}} = Task.yield(write_b, 1_000)
    assert {:ok, {:error, {:errored, :boom}}} = Task.yield(ready_task, 1_000)
    assert {:ok, {:error, {:errored, :boom}}} = Task.yield(close_task, 1_000)
    assert_wait(fn -> WritableStream.get_slots(pid).state == :errored end)
  end

  test "a writable stream cannot have two active writers at once" do
    stream = WritableStream.new()
    writer = WritableStream.get_writer(stream)

    assert_raise TypeError, "WritableStream is already locked", fn ->
      WritableStream.get_writer(stream)
    end

    assert :ok = WritableStreamDefaultWriter.release_lock(writer)

    second_writer = WritableStream.get_writer(stream)
    assert %WritableStreamDefaultWriter{} = second_writer
  end

  test "writer-facing errors cover released closing closed and errored states" do
    released_stream = WritableStream.new()
    released_writer = WritableStream.get_writer(released_stream)
    assert :ok = WritableStreamDefaultWriter.release_lock(released_writer)

    assert_raise TypeError, "This writer is no longer locked.", fn ->
      WritableStreamDefaultWriter.write(released_writer, "late")
    end

    assert_raise TypeError, "This writer is no longer locked.", fn ->
      WritableStreamDefaultWriter.ready(released_writer)
    end

    assert_raise TypeError, "This writer is no longer locked.", fn ->
      WritableStreamDefaultWriter.close(released_writer)
    end

    assert_raise TypeError, "This writer is no longer locked.", fn ->
      WritableStreamDefaultWriter.abort(released_writer, :late)
    end

    assert_raise TypeError, "This writer is no longer locked.", fn ->
      WritableStreamDefaultWriter.release_lock(released_writer)
    end

    parent = self()

    closing_stream =
      WritableStream.new(%{
        write: fn chunk, _controller ->
          send(parent, {:closing_write, self(), chunk})

          receive do
            :continue -> :ok
          end
        end
      })

    closing_writer = WritableStream.get_writer(closing_stream)
    write_task = Task.async(fn -> WritableStreamDefaultWriter.write(closing_writer, "first") end)
    assert_receive {:closing_write, sink_pid, "first"}

    close_task = Task.async(fn -> WritableStreamDefaultWriter.close(closing_writer) end)
    Process.sleep(50)

    assert_raise TypeError, "The stream is closing.", fn ->
      WritableStreamDefaultWriter.write(closing_writer, "second")
    end

    assert_raise TypeError, "The stream is closing.", fn ->
      WritableStreamDefaultWriter.close(closing_writer)
    end

    send(sink_pid, :continue)
    assert {:ok, :ok} = Task.yield(write_task, 1_000)
    assert {:ok, :ok} = Task.yield(close_task, 1_000)

    assert :ok = WritableStreamDefaultWriter.close(closing_writer)

    assert_raise TypeError, "The stream is closed.", fn ->
      WritableStreamDefaultWriter.write(closing_writer, "after-close")
    end

    assert :ok = WritableStreamDefaultWriter.abort(closing_writer, :ignored_after_close)
    assert :ok = WritableStreamDefaultWriter.release_lock(closing_writer)

    errored_stream = WritableStream.new()
    errored_writer = WritableStream.get_writer(errored_stream)
    assert :ok = WritableStreamDefaultWriter.abort(errored_writer, :boom)

    assert_raise TypeError, "This writer is no longer locked.", fn ->
      WritableStreamDefaultWriter.write(errored_writer, "late")
    end

    assert_raise TypeError, "This writer is no longer locked.", fn ->
      WritableStreamDefaultWriter.ready(errored_writer)
    end

    assert_raise TypeError, "This writer is no longer locked.", fn ->
      WritableStreamDefaultWriter.close(errored_writer)
    end

    assert_raise TypeError, "This writer is no longer locked.", fn ->
      WritableStreamDefaultWriter.abort(errored_writer, :again)
    end

    assert_raise TypeError, "This writer is no longer locked.", fn ->
      WritableStreamDefaultWriter.release_lock(errored_writer)
    end
  end

  test "abort/2 invokes the underlying sink abort callback and errors the stream" do
    parent = self()

    stream =
      WritableStream.new(%{
        abort: fn reason ->
          send(parent, {:sink_abort, reason})
          :ok
        end
      })

    writer = WritableStream.get_writer(stream)

    assert :ok = WritableStreamDefaultWriter.abort(writer, :boom)
    assert_receive {:sink_abort, :boom}
    assert_wait(fn -> WritableStream.get_slots(stream.controller_pid).state == :errored end)
    assert WritableStream.locked?(stream) == false

    assert_raise TypeError, "This writer is no longer locked.", fn ->
      WritableStreamDefaultWriter.write(writer, "late")
    end
  end

  test "abort/2 returns quickly while cleanup continues in the background" do
    parent = self()

    stream =
      WritableStream.new(%{
        abort: fn reason ->
          send(parent, {:abort_started, self(), reason})
          Process.sleep(200)
          send(parent, {:abort_finished, reason})
          :ok
        end
      })

    writer = WritableStream.get_writer(stream)
    abort_task = Task.async(fn -> WritableStreamDefaultWriter.abort(writer, :slow_boom) end)

    assert_receive {:abort_started, _sink_pid, :slow_boom}
    assert {:ok, :ok} = Task.yield(abort_task, 50)
    assert Process.alive?(stream.controller_pid)

    slots = WritableStream.get_slots(stream.controller_pid)
    assert slots.state == :errored
    assert slots.error_reason == :slow_boom
    assert slots.active_operation == :abort
    assert is_reference(slots.task_ref)

    assert WritableStream.desired_size(stream) == nil

    assert_raise TypeError, "This writer is no longer locked.", fn ->
      WritableStreamDefaultWriter.write(writer, "late")
    end

    assert_raise TypeError, "This writer is no longer locked.", fn ->
      WritableStreamDefaultWriter.close(writer)
    end

    refute_receive {:abort_finished, :slow_boom}, 100
    assert_receive {:abort_finished, :slow_boom}, 300

    assert_wait(fn ->
      slots = WritableStream.get_slots(stream.controller_pid)
      is_nil(slots.active_operation) and is_nil(slots.task_ref)
    end)
  end

  test "abort task failures do not replace the original errored reason" do
    raised_stream =
      WritableStream.new(%{
        abort: fn _reason ->
          raise "abort failed"
        end
      })

    raised_writer = WritableStream.get_writer(raised_stream)

    assert :ok = WritableStreamDefaultWriter.abort(raised_writer, :boom)

    assert_wait(fn ->
      slots = WritableStream.get_slots(raised_stream.controller_pid)
      slots.state == :errored and slots.error_reason == :boom and is_nil(slots.active_operation)
    end)

    assert_raise TypeError, "This writer is no longer locked.", fn ->
      WritableStreamDefaultWriter.write(raised_writer, "late")
    end

    thrown_stream =
      WritableStream.new(%{
        abort: fn _reason ->
          throw(:abort_thrown)
        end
      })

    thrown_writer = WritableStream.get_writer(thrown_stream)

    assert :ok = WritableStreamDefaultWriter.abort(thrown_writer, :boom)

    assert_wait(fn ->
      slots = WritableStream.get_slots(thrown_stream.controller_pid)
      slots.state == :errored and slots.error_reason == :boom and is_nil(slots.active_operation)
    end)

    assert_raise TypeError, "This writer is no longer locked.", fn ->
      WritableStreamDefaultWriter.close(thrown_writer)
    end
  end

  test "start and write callback failures move the stream into errored" do
    raised_start_stream =
      WritableStream.new(%{
        start: fn _controller ->
          raise "start failed"
        end
      })

    thrown_start_stream =
      WritableStream.new(%{
        start: fn _controller ->
          throw(:start_thrown)
        end
      })

    assert_wait(fn ->
      WritableStream.get_slots(raised_start_stream.controller_pid).state == :errored
    end)

    assert_wait(fn ->
      WritableStream.get_slots(thrown_start_stream.controller_pid).state == :errored
    end)

    raised_write_stream =
      WritableStream.new(%{
        write: fn _chunk, _controller ->
          raise "write failed"
        end
      })

    raised_writer = WritableStream.get_writer(raised_write_stream)

    assert_raise TypeError, "The stream is errored.", fn ->
      WritableStreamDefaultWriter.write(raised_writer, "boom")
    end

    thrown_write_stream =
      WritableStream.new(%{
        write: fn _chunk, _controller ->
          throw(:write_thrown)
        end
      })

    thrown_writer = WritableStream.get_writer(thrown_write_stream)

    assert_raise TypeError, "The stream is errored.", fn ->
      WritableStreamDefaultWriter.write(thrown_writer, "boom")
    end
  end

  test "writer locks clear when the owner dies and task down messages are handled" do
    writer_lock_stream = WritableStream.new()
    parent = self()

    spawn(fn ->
      assert :ok = WritableStream.get_writer(writer_lock_stream.controller_pid)
      send(parent, :writer_locked)
    end)

    assert_receive :writer_locked

    assert_wait(fn ->
      WritableStream.get_slots(writer_lock_stream.controller_pid).writer_pid == nil
    end)

    slow_stream =
      WritableStream.new(%{
        write: fn _chunk, _controller ->
          Process.sleep(5_000)
        end
      })

    assert :ok = WritableStream.get_writer(slow_stream.controller_pid)
    spawn(fn -> WritableStream.write(slow_stream.controller_pid, parent, "x") end)
    Process.sleep(50)

    normal_ref = WritableStream.get_slots(slow_stream.controller_pid).task_ref
    send(slow_stream.controller_pid, {:DOWN, normal_ref, :process, self(), :normal})
    Process.sleep(50)

    assert WritableStream.get_slots(slow_stream.controller_pid).state == :writable
    :gen_statem.stop(slow_stream.controller_pid)

    abnormal_stream =
      WritableStream.new(%{
        write: fn _chunk, _controller ->
          Process.sleep(5_000)
        end
      })

    assert :ok = WritableStream.get_writer(abnormal_stream.controller_pid)
    spawn(fn -> WritableStream.write(abnormal_stream.controller_pid, parent, "x") end)
    Process.sleep(50)

    abnormal_ref = WritableStream.get_slots(abnormal_stream.controller_pid).task_ref
    send(abnormal_stream.controller_pid, {:DOWN, abnormal_ref, :process, self(), :kaboom})
    Process.sleep(50)

    assert WritableStream.get_slots(abnormal_stream.controller_pid).state == :errored
  end

  test "unknown casts do not crash writable streams in any state" do
    stream = WritableStream.new()
    :gen_statem.cast(stream.controller_pid, :unknown)

    parent = self()
    owner_pid = self()

    closing_stream =
      WritableStream.new(%{
        write: fn _chunk, _controller ->
          send(parent, {:closing_state, self()})

          receive do
            :continue -> :ok
          end
        end
      })

    _writer = WritableStream.get_writer(closing_stream)

    write_task =
      Task.async(fn ->
        WritableStream.write(closing_stream.controller_pid, owner_pid, "chunk")
      end)

    assert_receive {:closing_state, sink_pid}

    close_task =
      Task.async(fn -> WritableStream.close(closing_stream.controller_pid, owner_pid) end)

    assert_wait(fn ->
      WritableStream.get_slots(closing_stream.controller_pid).state == :closing
    end)

    :gen_statem.cast(closing_stream.controller_pid, :unknown)

    assert :ok = WritableStream.abort(closing_stream.controller_pid, owner_pid, :closing_abort)

    assert_wait(fn ->
      WritableStream.get_slots(closing_stream.controller_pid).state == :errored
    end)

    :gen_statem.cast(closing_stream.controller_pid, :unknown)
    assert {:ok, {:error, {:errored, :closing_abort}}} = Task.yield(write_task, 1_000)
    assert {:ok, {:error, {:errored, :closing_abort}}} = Task.yield(close_task, 1_000)
    send(sink_pid, :continue)

    errored_stream = WritableStream.new()
    errored_writer = WritableStream.get_writer(errored_stream)
    assert :ok = WritableStreamDefaultWriter.abort(errored_writer, :boom)

    assert_wait(fn ->
      WritableStream.get_slots(errored_stream.controller_pid).state == :errored
    end)

    :gen_statem.cast(errored_stream.controller_pid, :unknown)
  end

  test "race to abort does not crash and concurrent writes do not hang" do
    stream =
      WritableStream.new(%{
        write: fn _chunk, _controller ->
          Process.sleep(50)
          :ok
        end
      })

    writer = WritableStream.get_writer(stream)

    write_tasks =
      Enum.map(1..10, fn idx ->
        Task.async(fn ->
          attempt_write(writer, "chunk-#{idx}")
        end)
      end)

    abort_task =
      Task.async(fn ->
        try do
          WritableStreamDefaultWriter.abort(writer, :race_abort)
          :ok
        rescue
          _ in TypeError -> :ok
        end
      end)

    write_results = Task.yield_many(write_tasks, 2_000)

    assert Enum.all?(write_results, fn
             {_task, {:ok, :ok}} -> true
             {_task, {:ok, {:type_error, _message}}} -> true
             _ -> false
           end)

    assert Enum.any?(write_results, fn
             {_task, {:ok, {:type_error, _message}}} -> true
             _ -> false
           end)

    assert {:ok, :ok} = Task.yield(abort_task, 2_000)
    assert_wait(fn -> WritableStream.get_slots(stream.controller_pid).state == :errored end)
    assert WritableStream.locked?(stream.controller_pid) == false
    assert Process.alive?(stream.controller_pid)

    late_write_task = Task.async(fn -> attempt_write(writer, "late") end)
    assert {:ok, {:type_error, message}} = Task.yield(late_write_task, 1_000)
    assert message in ["The stream is errored.", "This writer is no longer locked."]
  end

  property "writing a list of chunks to a synchronous sink preserves order" do
    check all chunks <- StreamData.list_of(StreamData.binary(min_length: 0), max_length: 8) do
      parent = self()

      stream =
        WritableStream.new(%{
          write: fn chunk, _controller ->
            send(parent, {:written, chunk})
            :ok
          end,
          close: fn _controller ->
            send(parent, :closed)
            :ok
          end
        })

      writer = WritableStream.get_writer(stream)

      Enum.each(chunks, fn chunk ->
        assert :ok = WritableStreamDefaultWriter.write(writer, chunk)
      end)

      assert :ok = WritableStreamDefaultWriter.close(writer)

      received =
        Enum.map(chunks, fn _ ->
          receive do
            {:written, chunk} -> chunk
          after
            1_000 -> flunk("expected chunk write")
          end
        end)

      assert received == chunks
      assert_receive :closed
      assert WritableStream.desired_size(stream) == nil
      assert :ok = WritableStreamDefaultWriter.release_lock(writer)
    end
  end

  property "lock acquisition and release round trips cleanly" do
    check all iterations <- StreamData.integer(1..5) do
      stream = WritableStream.new()

      Enum.each(1..iterations, fn _ ->
        refute WritableStream.locked?(stream)
        writer = WritableStream.get_writer(stream)
        assert WritableStream.locked?(stream)
        assert :ok = WritableStreamDefaultWriter.release_lock(writer)
        refute WritableStream.locked?(stream)
      end)
    end
  end

  property "terminal states always report nil desired size" do
    check all abort_reason <- StreamData.term() do
      closed_stream = WritableStream.new()
      closed_writer = WritableStream.get_writer(closed_stream)

      assert :ok = WritableStreamDefaultWriter.close(closed_writer)
      assert WritableStream.desired_size(closed_stream) == nil
      assert :ok = WritableStreamDefaultWriter.release_lock(closed_writer)

      errored_stream = WritableStream.new()
      errored_writer = WritableStream.get_writer(errored_stream)

      assert :ok = WritableStreamDefaultWriter.abort(errored_writer, abort_reason)
      assert_wait(fn -> WritableStream.get_slots(errored_stream.controller_pid).state == :errored end)
      assert WritableStream.desired_size(errored_stream) == nil
      assert WritableStream.locked?(errored_stream.controller_pid) == false
    end
  end

  defp attempt_write(writer, chunk) do
    try do
      WritableStreamDefaultWriter.write(writer, chunk)
      :ok
    rescue
      error in TypeError -> {:type_error, error.message}
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
