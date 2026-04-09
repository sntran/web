defmodule Web.PipingTest do
  use ExUnit.Case, async: true
  import Web, only: [await: 1]

  alias Web.AbortController
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.TransformStream
  alias Web.WritableStream

  test "pipe_to/3 pipes chunks and closes destination by default" do
    parent = self()

    source = ReadableStream.from(["a", "b", "c"])

    sink =
      WritableStream.new(%{
        write: fn chunk, _controller ->
          send(parent, {:chunk, chunk})
          :ok
        end,
        close: fn _controller ->
          send(parent, :sink_closed)
          :ok
        end
      })

    promise = ReadableStream.pipe_to(source, sink)

    assert Task.await(promise.task, 1_000) == :ok
    assert_receive {:chunk, "a"}
    assert_receive {:chunk, "b"}
    assert_receive {:chunk, "c"}
    assert_receive :sink_closed
  end

  test "pipe_through/3 supports chaining transforms" do
    source = ReadableStream.from(["ab", "cd"])

    upcase_transform =
      TransformStream.new(%{
        transform: fn chunk, controller ->
          ReadableStreamDefaultController.enqueue(controller, String.upcase(chunk))
        end,
        flush: fn controller ->
          ReadableStreamDefaultController.close(controller)
        end
      })

    suffix_transform =
      TransformStream.new(%{
        transform: fn chunk, controller ->
          ReadableStreamDefaultController.enqueue(controller, chunk <> "!")
        end,
        flush: fn controller ->
          ReadableStreamDefaultController.close(controller)
        end
      })

    transformed =
      source
      |> ReadableStream.pipe_through(upcase_transform)
      |> ReadableStream.pipe_through(suffix_transform)

    assert "AB!CD!" == Enum.join(transformed, "")
  end

  test "pipe_to/3 with preventClose keeps sink writable" do
    parent = self()

    source = ReadableStream.from(["x"])

    sink =
      WritableStream.new(%{
        close: fn _controller ->
          send(parent, :sink_closed)
          :ok
        end
      })

    promise = ReadableStream.pipe_to(source, sink, preventClose: true)

    assert Task.await(promise.task, 1_000) == :ok
    refute_received :sink_closed
    assert WritableStream.__get_slots__(sink.controller_pid).state == :writable
  end

  test "pipe_to/3 preserves custom abort reasons during cancel/abort" do
    parent = self()
    controller = AbortController.new()
    reason = :my_custom_reason

    source =
      ReadableStream.new(%{
        start: fn stream_controller ->
          ReadableStreamDefaultController.enqueue(stream_controller, "chunk")
        end,
        cancel: fn reason ->
          send(parent, {:source_cancelled, reason})
          :ok
        end
      })

    sink =
      WritableStream.new(%{
        write: fn _chunk, _controller ->
          send(parent, {:sink_write_started, self()})

          receive do
            :continue -> :ok
          end
        end,
        abort: fn reason ->
          send(parent, {:sink_aborted, reason})
          :ok
        end
      })

    promise = ReadableStream.pipe_to(source, sink, signal: controller.signal)

    assert_receive {:sink_write_started, sink_write_pid}
    :ok = AbortController.abort(controller, reason)
    send(sink_write_pid, :continue)

    assert catch_exit(await(promise)) == {:aborted, :my_custom_reason}
    assert_receive {:source_cancelled, :my_custom_reason}
    assert_receive {:sink_aborted, :my_custom_reason}
  end

  test "pipe_to/3 source errors abort sink unless preventAbort is true" do
    parent = self()

    source =
      ReadableStream.new(%{
        start: fn controller ->
          ReadableStreamDefaultController.error(controller, :boom)
        end
      })

    sink =
      WritableStream.new(%{
        abort: fn reason ->
          send(parent, {:sink_aborted, reason})
          :ok
        end
      })

    promise = ReadableStream.pipe_to(source, sink)

    assert catch_exit(await(promise)) == {:errored, :boom}
    assert_receive {:sink_aborted, {:errored, :boom}}

    source_2 =
      ReadableStream.new(%{
        start: fn controller ->
          ReadableStreamDefaultController.error(controller, :boom)
        end
      })

    sink_2 =
      WritableStream.new(%{
        abort: fn reason ->
          send(parent, {:sink_aborted_prevented, reason})
          :ok
        end
      })

    promise_2 = ReadableStream.pipe_to(source_2, sink_2, preventAbort: true)

    assert catch_exit(await(promise_2)) == {:errored, :boom}
    refute_received {:sink_aborted_prevented, _reason}
  end

  test "pipe_to/3 sink errors cancel source unless preventCancel is true" do
    parent = self()

    source =
      ReadableStream.new(%{
        start: fn controller ->
          ReadableStreamDefaultController.enqueue(controller, "x")
        end,
        cancel: fn reason ->
          send(parent, {:source_cancelled, reason})
          :ok
        end
      })

    sink =
      WritableStream.new(%{
        write: fn _chunk, controller ->
          Web.WritableStreamDefaultController.error(controller, :sink_boom)
          :ok
        end
      })

    promise = ReadableStream.pipe_to(source, sink)

    assert catch_exit(await(promise)) == {:errored, :sink_boom}
    assert_receive {:source_cancelled, {:errored, :sink_boom}}

    source_2 =
      ReadableStream.new(%{
        start: fn controller ->
          ReadableStreamDefaultController.enqueue(controller, "x")
        end,
        cancel: fn reason ->
          send(parent, {:source_cancelled_prevented, reason})
          :ok
        end
      })

    sink_2 =
      WritableStream.new(%{
        write: fn _chunk, controller ->
          Web.WritableStreamDefaultController.error(controller, :sink_boom)
          :ok
        end
      })

    promise_2 = ReadableStream.pipe_to(source_2, sink_2, preventCancel: true)

    assert catch_exit(await(promise_2)) == {:errored, :sink_boom}
    refute_received {:source_cancelled_prevented, _reason}
  end

  test "pipe_to/3 accepts readable and writable pids" do
    source = ReadableStream.from(["pid-path"])

    sink =
      WritableStream.new(%{
        write: fn _chunk, _controller -> :ok end
      })

    promise = ReadableStream.pipe_to(source.controller_pid, sink.controller_pid)
    assert Task.await(promise.task, 1_000) == :ok
  end

  test "pipe_to/3 fails fast when source or sink is already locked" do
    source = ReadableStream.from(["locked"])
    _reader = ReadableStream.get_reader(source)

    sink = WritableStream.new(%{})

    promise = ReadableStream.pipe_to(source.controller_pid, sink)

    assert %Web.TypeError{message: "ReadableStream is already locked"} =
             catch_exit(await(promise))

    source_2 = ReadableStream.from(["x"])
    sink_2 = WritableStream.new(%{})
    _writer = WritableStream.get_writer(sink_2)

    promise_2 = ReadableStream.pipe_to(source_2, sink_2.controller_pid)

    assert %Web.TypeError{message: "WritableStream is already locked"} =
             catch_exit(await(promise_2))
  end

  test "pipe_to/3 releases the reader lock when writer acquisition fails" do
    source = ReadableStream.from(["x"])
    sink = WritableStream.new(%{})
    _writer = WritableStream.get_writer(sink)

    promise = ReadableStream.pipe_to(source.controller_pid, sink.controller_pid)

    assert %Web.TypeError{message: "WritableStream is already locked"} =
             catch_exit(await(promise))

    assert :ok = ReadableStream.get_reader(source.controller_pid)
    assert :ok = ReadableStream.release_lock(source.controller_pid)
  end

  test "pipe_to/3 aborts promptly while blocked waiting for the source" do
    parent = self()
    controller = AbortController.new()

    source =
      ReadableStream.new(%{
        pull: fn _stream_controller ->
          send(parent, :source_pull_started)

          receive do
            :continue -> :ok
          end
        end,
        cancel: fn reason ->
          send(parent, {:source_cancelled_preemptively, reason})
          :ok
        end
      })

    sink =
      WritableStream.new(%{
        write: fn _chunk, _controller ->
          send(parent, :sink_write_called)
          :ok
        end,
        abort: fn reason ->
          send(parent, {:sink_aborted_preemptively, reason})
          :ok
        end
      })

    promise = ReadableStream.pipe_to(source, sink, signal: controller.signal)

    assert_receive :source_pull_started
    assert :ok = AbortController.abort(controller, :timeout)

    assert catch_exit(await(promise)) == {:aborted, :timeout}
    assert_receive {:source_cancelled_preemptively, :timeout}
    assert_receive {:sink_aborted_preemptively, :timeout}
    refute_received :sink_write_called
  end

  test "pipe_to/3 preserves custom token abort reasons while blocked" do
    parent = self()

    source =
      ReadableStream.new(%{
        pull: fn _stream_controller ->
          send(parent, :token_pull_started)

          receive do
            :continue -> :ok
          end
        end,
        cancel: fn reason ->
          send(parent, {:token_source_cancelled, reason})
          :ok
        end
      })

    sink =
      WritableStream.new(%{
        abort: fn reason ->
          send(parent, {:token_sink_aborted, reason})
          :ok
        end
      })

    promise = ReadableStream.pipe_to(source, sink, signal: :pipe_token)

    assert_receive :token_pull_started
    send(promise.task.pid, {:abort, :pipe_token, :token_reason})

    assert catch_exit(await(promise)) == {:aborted, :token_reason}
    assert_receive {:token_source_cancelled, :token_reason}
    assert_receive {:token_sink_aborted, :token_reason}
  end

  test "pipe_to/3 normalizes token aborts without explicit reasons" do
    parent = self()

    source =
      ReadableStream.new(%{
        pull: fn _stream_controller ->
          send(parent, :token_default_pull_started)

          receive do
            :continue -> :ok
          end
        end,
        cancel: fn reason ->
          send(parent, {:token_default_source_cancelled, reason})
          :ok
        end
      })

    sink =
      WritableStream.new(%{
        abort: fn reason ->
          send(parent, {:token_default_sink_aborted, reason})
          :ok
        end
      })

    promise = ReadableStream.pipe_to(source, sink, signal: :pipe_token_default)

    assert_receive :token_default_pull_started
    send(promise.task.pid, {:abort, :pipe_token_default})

    assert catch_exit(await(promise)) == {:aborted, :aborted}
    assert_receive {:token_default_source_cancelled, :aborted}
    assert_receive {:token_default_sink_aborted, :aborted}
  end
end
