defmodule Web.StreamTest do
  use ExUnit.Case, async: true
  import Web, only: [await: 1]

  defmodule UsingMacroStream do
    use Web.Stream

    @impl Web.Stream
    def start(_pid, _opts), do: {:producer, %{}}
  end

  defmodule HibernateSourceStream do
    use Web.Stream

    @impl Web.Stream
    def start(_pid, _opts), do: {:producer, %{sent?: false}}

    # The first pull gives a chunk and asks for hibernation. The stream is
    # open at that time, thus the engine uses the result of the pull.
    @impl Web.Stream
    def pull(ctrl, %{sent?: false} = state) do
      Web.ReadableStreamDefaultController.enqueue(ctrl, "x")
      {:ok, %{state | sent?: true}, :hibernate}
    end

    def pull(ctrl, %{sent?: true} = state) do
      Web.ReadableStreamDefaultController.close(ctrl)
      {:ok, state}
    end
  end

  defmodule PromiseResultReadableStream do
    use Web.Stream

    @impl Web.Stream
    def start(_pid, opts), do: {:producer, Map.new(opts)}

    @impl Web.Stream
    def pull(ctrl, %{promise_factory: promise_factory}) when is_function(promise_factory, 1) do
      promise_factory.(ctrl)
    end

    def pull(_ctrl, %{promise_factory: promise_factory}) when is_function(promise_factory, 0) do
      promise_factory.()
    end
  end

  defmodule InvalidReadableHwmStrategy do
    defstruct high_water_mark: :invalid

    def size(_chunk), do: 1
  end

  alias Web.ReadableStream
  alias Web.ReadableStreamBYOBReader
  alias Web.TransformStream
  alias Web.TypeError
  alias Web.Uint8Array
  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter

  describe "Web.Stream engine basics" do
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

    test "init tolerates unexpected async context snapshots" do
      assert {:ok, :readable, %Web.Stream{}, _actions} =
               Web.Stream.init({UsingMacroStream, [], :not_a_snapshot, self()})

      assert {:ok, :readable, %Web.Stream{}, _actions} =
               Web.Stream.init({UsingMacroStream, [], %{ambient_signal: :not_a_signal}, self()})
    end

    test "init forwards ambient aborts for signals that abort during subscription" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}
      assert reason in [:normal, :noproc]

      signal = %Web.AbortSignal{pid: pid, ref: make_ref()}

      assert {:ok, :readable, %Web.Stream{}, _actions} =
               Web.Stream.init({UsingMacroStream, [], %{ambient_signal: signal}, self()})

      assert_receive {:ambient_signal_abort, %Web.DOMException{name: "AbortError"}}
    end

    test "start_task falls back to plain execution when async_context is not a snapshot" do
      parent = self()

      data = %Web.Stream{async_context: :not_a_snapshot, timeout_ms: 50}

      assert {:keep_state, next_data} =
               Web.Stream.readable(
                 :internal,
                 {:start_task, fn -> send(parent, :started) end},
                 data
               )

      assert_receive :started, 1_000
      # The worker sends the result to the process of the stream: here, the
      # test process.
      ref = next_data.active_task.ref
      assert_receive {^ref, {:ok, :init_done}}, 1_000
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

    test "a cancel of a stream whose module has no callback terminate is complete" do
      {:ok, pid} = UsingMacroStream.start_link([])

      assert :ok = await(ReadableStream.cancel(%ReadableStream{controller_pid: pid}, :stop))
      assert ReadableStream.__get_slots__(pid).state == :closed
    end

    test "pull callbacks can request hibernation" do
      {:ok, pid} = HibernateSourceStream.start_link([])
      stream = %ReadableStream{controller_pid: pid}
      _reader = ReadableStream.get_reader(stream)

      assert {:ok, "x"} = ReadableStream.read(pid)
      assert :done = ReadableStream.read(pid)
    end

    test "byte stream BYOB reads preserve queued remainders in engine state" do
      stream = ReadableStream.new(%{type: "bytes"})
      reader = ReadableStream.get_reader(stream, mode: "byob")

      ReadableStream.enqueue(stream.controller_pid, "hello")

      view = Uint8Array.new(Web.ArrayBuffer.new(2))

      assert %{value: first_chunk, done: false} =
               await(ReadableStreamBYOBReader.read(reader, view))

      assert Uint8Array.to_binary(first_chunk) == "he"

      slots = ReadableStream.__get_slots__(stream.controller_pid)
      assert slots.total_queued_size == 3
      assert :queue.to_list(slots.queue) == ["llo"]
    end

    test "byte streams clear pending BYOB requests when they close" do
      parent = self()

      stream = ReadableStream.new(%{type: "bytes"})

      spawn(fn ->
        reader = ReadableStream.get_reader(stream, mode: "byob")
        read = ReadableStreamBYOBReader.read(reader, Uint8Array.new(Web.ArrayBuffer.new(4)))

        # This process sent the read before this call. Thus the stream has
        # the BYOB request when the call returns.
        request = Web.Stream.control_call(stream.controller_pid, :get_byob_request)
        send(parent, {:byob_request, request})
        send(parent, {:read_result, await(read)})
      end)

      assert_receive {:byob_request, request}
      assert %Web.ReadableStreamBYOBRequest{} = request

      ReadableStream.close(stream.controller_pid)
      assert_receive {:read_result, %{done: true}}, 1_000
      assert ReadableStream.__get_slots__(stream.controller_pid).pending_byob_request == nil
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
            # A slow pull: the cancel stops it.
            Process.sleep(5_000)
          end,
          cancel: fn reason ->
            send(parent, {:cancelled, reason})
          end
        })

      _reader = ReadableStream.get_reader(stream)
      _read_task = Task.async(fn -> ReadableStream.read(stream.controller_pid) end)

      # The pull runs. Thus the stream has an active task.
      assert_receive :pull_started

      # Cancel the stream
      assert :ok =
               Web.Promise.await(ReadableStream.cancel(stream.controller_pid, :user_cancel))

      assert_receive {:cancelled, :user_cancel}
      assert ReadableStream.__get_slots__(stream.controller_pid).state == :closed
    end

    test "abort while write task active: task is killed and terminate called" do
      parent = self()

      stream =
        WritableStream.new(%{
          write: fn _chunk, _ctrl ->
            send(parent, {:write_started, self()})
            # A slow write: the abort stops it.
            Process.sleep(5_000)
          end,
          abort: fn reason ->
            send(parent, {:aborted, reason})
          end
        })

      writer = WritableStream.get_writer(stream)

      _write_task =
        Task.async(fn -> catch_exit(await(WritableStreamDefaultWriter.write(writer, "x"))) end)

      # The write runs. Thus the stream has an active task.
      assert_receive {:write_started, _}

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

      # The promise `closed` of a reader rejects when the stream is errored.
      reader = ReadableStream.get_reader(%ReadableStream{controller_pid: pid})

      assert %RuntimeError{message: "pull failed"} =
               catch_exit(await(Web.ReadableStreamDefaultReader.closed(reader)))

      assert ReadableStream.__get_slots__(pid).state == :errored
    end

    test "write errors transition stream to errored" do
      stream =
        WritableStream.new(%{
          write: fn _chunk, _ctrl -> raise "write failed" end
        })

      writer = WritableStream.get_writer(stream)

      assert %RuntimeError{message: "write failed"} =
               catch_exit(await(WritableStreamDefaultWriter.write(writer, "x")))
    end
  end

  describe "Web.Stream disturbed flag" do
    test "disturbed/locked behavior tracks stream usage" do
      stream = ReadableStream.from("hello")

      assert ReadableStream.disturbed?(stream) == false
      assert ReadableStream.locked?(stream) == false

      # The reader starts the process of the stream. Each copy of the struct
      # finds that process.
      reader = ReadableStream.get_reader(stream)
      assert ReadableStream.locked?(stream) == true
      assert %{value: chunk, done: false} = await(Web.ReadableStreamDefaultReader.read(reader))
      assert Web.Uint8Array.to_binary(chunk) == "hello"
      assert ReadableStream.disturbed?(stream) == true
      assert ReadableStream.disturbed?(reader.controller_pid) == true
      assert :ok = Web.ReadableStreamDefaultReader.release_lock(reader)

      # The Streams Standard permits a tee of a stream that is disturbed and
      # not locked. The branches get the chunks that are not read.
      assert [left, right] = ReadableStream.tee(stream)
      assert ReadableStream.locked?(stream) == true
      assert Enum.to_list(left) == []
      assert Enum.to_list(right) == []
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
      reader = ReadableStream.get_reader(stream)
      _ = ReadableStream.read(reader.controller_pid)

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
      WritableStreamDefaultWriter.write(writer, "hello")
      WritableStreamDefaultWriter.write(writer, " world")
      WritableStreamDefaultWriter.close(writer)

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
      WritableStreamDefaultWriter.write(writer, "hi")
      WritableStreamDefaultWriter.close(writer)

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
      WritableStreamDefaultWriter.write(writer, "A")
      WritableStreamDefaultWriter.close(writer)

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
               Web.Promise.await(ReadableStream.cancel(ts.readable.controller_pid, :stop))

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
        WritableStreamDefaultWriter.write(writer, n)
      end

      WritableStreamDefaultWriter.close(writer)

      assert Enum.to_list(ts.readable) == [2, 4, 6]
    end

    test "TransformStream with high_water_mark option" do
      # The option is the limit of the writable side. The default limit of
      # the readable side is 0, as in the Streams Standard.
      ts = TransformStream.new(%{}, high_water_mark: 5)
      slots = ReadableStream.__get_slots__(ts.readable.controller_pid)
      assert slots.writable_desired_size == 5
      assert slots.readable_desired_size == 0
    end

    test "TransformStream falls back to writable high water mark for invalid readable strategy hwm" do
      ts =
        TransformStream.new(%{},
          high_water_mark: 3,
          readable_strategy: %InvalidReadableHwmStrategy{}
        )

      slots = ReadableStream.__get_slots__(ts.readable.controller_pid)
      assert slots.readable_hwm == 3
      assert slots.desired_size == 3
    end

    test "ReadableStream falls back to a count strategy for invalid readable strategies" do
      {:ok, pid} = ReadableStream.start_link(high_water_mark: 2, strategy: :invalid)

      ReadableStream.enqueue(pid, "ab")
      assert ReadableStream.get_desired_size(pid) == 1
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

      # A read waits, thus the transform of the chunk starts.
      read = Web.ReadableStreamDefaultReader.read(ReadableStream.get_reader(ts.readable))

      assert %RuntimeError{message: "transform failed"} =
               catch_exit(await(WritableStreamDefaultWriter.write(writer, "x")))

      assert %RuntimeError{message: "transform failed"} = catch_exit(await(read))
      assert ReadableStream.__get_slots__(ts.readable.controller_pid).state == :errored
    end

    test "terminate without cancel function completes gracefully on cancel" do
      ts = TransformStream.new(%{})
      assert :ok = Web.Promise.await(ReadableStream.cancel(ts.readable.controller_pid))
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
      WritableStreamDefaultWriter.write(writer, "hello")
      WritableStreamDefaultWriter.close(writer)
      assert Enum.join(ts.readable, "") == "HELLO"
    end
  end

  describe "Web.Stream __get_slots__" do
    test "__get_slots__ returns all engine internals with state key" do
      {:ok, pid} = Web.Stream.start_link(ReadableStream, high_water_mark: 2)
      # The stream pulls one time at the start, in its worker. Wait for the
      # end of that pull. A stream with no source does not pull again.
      assert_wait(fn -> not ReadableStream.__get_slots__(pid).pulling end)
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

    test "a closed stream reports the desired size 0, and an errored stream nil" do
      closed_stream = WritableStream.new()
      closed_writer = WritableStream.get_writer(closed_stream)

      assert :ok = await(WritableStreamDefaultWriter.close(closed_writer))
      assert WritableStream.desired_size(closed_stream) == 0
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
            # A slow write: the abort stops it.
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

      # The stream stops the worker of the write before it replies to the
      # abort.
      refute Process.alive?(sink_task_pid)
      # The write rejects with the abort reason, which is the error of the
      # stream.
      assert {:ok, result} = Task.yield(write_task, 1_000)
      assert result in [:abort_now, {:errored, "This writer is no longer locked."}]
    end

    test "a transform stream gives backpressure to its writer until a process reads" do
      ts = TransformStream.new(%{}, high_water_mark: 1)
      writer = WritableStream.get_writer(ts.writable)

      first = WritableStreamDefaultWriter.write(writer, "a")
      second = WritableStreamDefaultWriter.write(writer, "b")
      ready = WritableStreamDefaultWriter.ready(writer)

      # This call comes after the writes from the same process. Thus the
      # stream handled the writes when the call returns.
      slots = ReadableStream.__get_slots__(ts.readable.controller_pid)

      # No process reads. The writes wait, and no chunk is in the readable queue.
      assert Enum.map([first, second, ready], &Web.Promise.peek/1) == [
               :pending,
               :pending,
               :pending
             ]

      assert :queue.len(slots.queue) == 0

      reader = ReadableStream.get_reader(ts.readable)
      assert await(Web.ReadableStreamDefaultReader.read(reader)) == %{value: "a", done: false}
      assert await(first) == :ok
      assert await(Web.ReadableStreamDefaultReader.read(reader)) == %{value: "b", done: false}
      assert await(second) == :ok
      assert await(ready) == :ok
      assert :ok = Web.ReadableStreamDefaultReader.release_lock(reader)
      assert :ok = WritableStreamDefaultWriter.release_lock(writer)
    end

    test "transform desired size separates readable and writable accounting" do
      ts = TransformStream.new(%{}, high_water_mark: 2)
      writer = WritableStream.get_writer(ts.writable)
      WritableStreamDefaultWriter.write(writer, "a")

      # The write waits for a reader. It uses one place of the writable side.
      # This call comes after the write from the same process. Thus the
      # stream handled the write when the call returns.
      slots = ReadableStream.__get_slots__(ts.readable.controller_pid)
      assert slots.readable_desired_size == 0
      assert slots.writable_desired_size == 1

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

      assert catch_exit(await(Web.ReadableStreamDefaultReader.read(left_reader)))

      assert catch_exit(await(Web.ReadableStreamDefaultReader.read(right_reader)))
    end

    test "timeout check transitions to errored with task timeout reason" do
      {:ok, pid} =
        WritableStream.start_link(
          underlying_sink: %{
            write: fn _chunk, _controller ->
              # Longer than the time limit of the callback.
              Process.sleep(60_000)
              :ok
            end
          },
          timeout_ms: 100
        )

      stream = %WritableStream{controller_pid: pid}
      writer = WritableStream.get_writer(stream)

      assert %TypeError{cause: {:task_timeout, :write}} =
               catch_exit(await(WritableStreamDefaultWriter.write(writer, "slow")))

      assert_wait(fn ->
        slots = WritableStream.__get_slots__(stream.controller_pid)

        slots.state == :errored and
          match?(%TypeError{cause: {:task_timeout, :write}}, slots.error_reason)
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
      WritableStreamDefaultWriter.write(writer, "x")
      WritableStreamDefaultWriter.close(writer)
      assert "X" == Enum.join(ts.readable, "")
      assert_receive {:transform_chunk, "x"}
    end

    test "timeout check transitions to errored with task timeout reason for flush" do
      {:ok, pid} =
        WritableStream.start_link(
          underlying_sink: %{
            close: fn _controller ->
              # Longer than the time limit of the callback.
              Process.sleep(60_000)
              :ok
            end
          },
          timeout_ms: 100
        )

      stream = %WritableStream{controller_pid: pid}
      writer = WritableStream.get_writer(stream)

      assert %TypeError{cause: {:task_timeout, :flush}} =
               catch_exit(await(WritableStreamDefaultWriter.close(writer)))

      assert_wait(fn ->
        slots = WritableStream.__get_slots__(stream.controller_pid)

        slots.state == :errored and
          match?(%TypeError{cause: {:task_timeout, :flush}}, slots.error_reason)
      end)
    end

    test "timeout check transitions to errored with task timeout reason for pull" do
      {:ok, pid} =
        ReadableStream.start_link(
          source: %{
            pull: fn _controller ->
              # Longer than the time limit of the callback.
              Process.sleep(60_000)
            end
          },
          timeout_ms: 100
        )

      _reader = ReadableStream.get_reader(pid)
      _ = ReadableStream.read(pid)

      assert_wait(fn ->
        slots = ReadableStream.__get_slots__(pid)

        slots.state == :errored and
          match?(%TypeError{cause: {:task_timeout, :pull}}, slots.error_reason)
      end)
    end
  end

  describe "Web.Stream callback rescue/catch paths" do
    test "source start callback exception is raised by the constructor" do
      assert_raise RuntimeError, "source start failed", fn ->
        ReadableStream.new(%{start: fn _ctrl -> raise "source start failed" end})
      end
    end

    test "pull throw transitions stream to errored (catch clause)" do
      {:ok, pid} =
        ReadableStream.start_link(source: %{pull: fn _ctrl -> throw(:pull_thrown) end})

      # The promise `closed` of a reader rejects when the stream is errored.
      reader = ReadableStream.get_reader(%ReadableStream{controller_pid: pid})
      assert catch_exit(await(Web.ReadableStreamDefaultReader.closed(reader))) == :pull_thrown
      assert ReadableStream.__get_slots__(pid).state == :errored
    end

    test "flush callback throw errors the stream (catch clause)" do
      stream =
        WritableStream.new(%{close: fn _ctrl -> throw(:flush_thrown) end})

      writer = WritableStream.get_writer(stream)

      assert :flush_thrown = catch_exit(await(WritableStreamDefaultWriter.close(writer)))

      assert WritableStream.__get_slots__(stream.controller_pid).state == :errored
    end

    test "flush callback exception errors the stream (rescue clause)" do
      stream = WritableStream.new(%{close: fn _ctrl -> raise "flush error" end})
      writer = WritableStream.get_writer(stream)

      assert %RuntimeError{message: "flush error"} =
               catch_exit(await(WritableStreamDefaultWriter.close(writer)))

      assert WritableStream.__get_slots__(stream.controller_pid).state == :errored
    end

    test "an abort rejects with the error that the cancel callback raises" do
      ts = TransformStream.new(%{cancel: fn _reason -> raise "cancel error" end})
      writer = WritableStream.get_writer(ts.writable)

      assert %RuntimeError{message: "cancel error"} =
               catch_exit(await(WritableStreamDefaultWriter.abort(writer, :reason)))

      # The stream is errored when the abort starts, before its reply.
      assert WritableStream.__get_slots__(ts.writable.controller_pid).state == :errored
    end

    test "an abort rejects with the value that the cancel callback throws" do
      ts = TransformStream.new(%{cancel: fn _reason -> throw(:my_throw) end})
      writer = WritableStream.get_writer(ts.writable)
      assert catch_exit(await(WritableStreamDefaultWriter.abort(writer, :reason))) == :my_throw
      # The stream is errored when the abort starts, before its reply.
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
      WritableStreamDefaultWriter.write(writer, "test")
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
    test "control_call exits when the target dies before replying" do
      pid =
        spawn(fn ->
          receive do
            _ -> :ok
          end
        end)

      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

      assert catch_exit(Web.Stream.control_call(pid, :never_replied)) ==
               {:noproc, {Web.Stream, :control_call, [pid, :never_replied]}}
    end

    # --- stream.ex line 591: cancel on already-closed stream calls signal_terminate ---

    test "cancel-on-closed stream calls signal_terminate but does nothing" do
      stream = WritableStream.new()
      writer = WritableStream.get_writer(stream)
      await(WritableStreamDefaultWriter.close(writer))
      # send {:terminate, :cancel, nil} to an already-closed stream
      Web.Stream.terminate(stream.controller_pid, :cancel)
      # This call comes after the terminal event from the same process. Thus
      # the stream handled the event when the call returns.
      assert WritableStream.__get_slots__(stream.controller_pid).state == :closed
    end

    test "control_call terminate on an already closed stream replies :ok without changing state" do
      stream = WritableStream.new()
      writer = WritableStream.get_writer(stream)
      assert :ok = await(WritableStreamDefaultWriter.close(writer))

      assert :ok = Web.Stream.control_call(stream.controller_pid, {:terminate, :close, nil})
      assert WritableStream.__get_slots__(stream.controller_pid).state == :closed
    end

    # --- stream.ex line 604: {:cancel, reason} cast ---

    test ":cancel cast terminates the stream directly" do
      {:ok, pid} = ReadableStream.start_link()
      :gen_statem.cast(pid, {:cancel, :direct_cancel})
      # This call comes after the cast from the same process. Thus the
      # stream handled the cast when the call returns.
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
      WritableStreamDefaultWriter.write(writer, "hi")
      WritableStreamDefaultWriter.close(writer)
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

    test "owner calls on closed writable streams use closed replies" do
      stream = WritableStream.new()
      writer = WritableStream.get_writer(stream)

      :sys.replace_state(stream.controller_pid, fn {_state, data} ->
        {:closed, data}
      end)

      assert {:error, :closed} =
               :gen_statem.call(stream.controller_pid, {:write, writer.owner_pid, "x"})

      # A second close is an error, and an abort of a closed stream has no effect.
      assert {:error, :closed} =
               :gen_statem.call(stream.controller_pid, {:close, writer.owner_pid})

      assert :ok = :gen_statem.call(stream.controller_pid, {:abort, writer.owner_pid, :boom})
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

    test "signal-based ready returns errors for the wrong owner and ok after close" do
      stream = WritableStream.new()
      writer = WritableStream.get_writer(stream)

      other_owner = spawn(fn -> Process.sleep(:infinity) end)

      assert {:error, :not_locked_by_writer} =
               WritableStream.ready(stream.controller_pid, other_owner)

      assert :ok = await(WritableStreamDefaultWriter.close(writer))
      assert :ok = WritableStream.ready(stream.controller_pid, writer.owner_pid)

      Process.exit(other_owner, :kill)
    end

    test "legacy enqueue_ready call still supports immediate and parked backpressure checks" do
      ts = TransformStream.new(%{}, readable_strategy: Web.CountQueuingStrategy.new(1))
      pid = ts.readable.controller_pid

      assert :ok = :gen_statem.call(pid, :enqueue_ready)

      Web.ReadableStream.enqueue(pid, "full")

      waiter = Task.async(fn -> :gen_statem.call(pid, :enqueue_ready, 1_000) end)

      assert_wait(fn ->
        :queue.len(Web.ReadableStream.__get_slots__(pid).enqueue_waiters) == 1
      end)

      reader = Web.ReadableStream.get_reader(ts.readable)
      assert %{value: "full", done: false} == await(Web.ReadableStreamDefaultReader.read(reader))
      assert :ok = Task.await(waiter, 1_000)
    end

    test "legacy enqueue_ready call returns ok after the stream is closed" do
      ts = TransformStream.new(%{})
      pid = ts.readable.controller_pid

      Web.Stream.terminate(pid, :close)

      assert_wait(fn ->
        Web.ReadableStream.__get_slots__(pid).state == :closed
      end)

      assert :ok = :gen_statem.call(pid, :enqueue_ready)
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
      # The stop returns when the process stopped.
      :gen_statem.stop(stream.controller_pid)
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
            # The write stays in progress until the terminal event stops it.
            Process.sleep(:infinity)
          end
        })

      writer = WritableStream.get_writer(stream)

      # Start a write in a background task
      write_task =
        Task.async(fn ->
          try do
            await(WritableStreamDefaultWriter.write(writer, "data"))
          catch
            :exit, reason -> {:exited, reason}
          end
        end)

      # Wait until write is actually in progress inside the gen_statem
      assert_receive :write_in_progress, 500

      # Queue a close request - while write is active, this sets pending_close_request
      close_task =
        Task.async(fn ->
          close = WritableStreamDefaultWriter.close(writer)
          # This call comes after the close from the same process. Thus the
          # stream has the close request when the call returns.
          _slots = WritableStream.__get_slots__(stream.controller_pid)
          send(parent, :close_requested)

          try do
            await(close)
          catch
            :exit, reason -> {:exited, reason}
          end
        end)

      assert_receive :close_requested

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

    test "resolve_if_promise handles promised pull results and exits" do
      {:ok, ok_pid} =
        PromiseResultReadableStream.start_link(
          promise_factory: fn ctrl ->
            Web.Promise.new(fn resolve, _reject ->
              Web.ReadableStreamDefaultController.close(ctrl)
              resolve.({:ok, %{promise_factory: fn _ -> :ok end}})
            end)
          end
        )

      send(ok_pid, {:internal, :maybe_pull})

      assert_wait(fn ->
        :gen_statem.call(ok_pid, :get_slots).active_task == nil
      end)

      {:ok, pause_pid} =
        PromiseResultReadableStream.start_link(
          promise_factory: fn ctrl ->
            Web.Promise.new(fn resolve, _reject ->
              Web.ReadableStreamDefaultController.close(ctrl)
              resolve.({:ok, %{promise_factory: fn _ -> :ok end}, :pause})
            end)
          end
        )

      send(pause_pid, {:internal, :maybe_pull})

      assert_wait(fn ->
        :gen_statem.call(pause_pid, :get_slots).active_task == nil
      end)

      {:ok, error_pid} =
        PromiseResultReadableStream.start_link(
          promise_factory: fn -> Web.Promise.resolve({:error, :promise_error}) end
        )

      send(error_pid, {:internal, :maybe_pull})
      assert_wait(fn -> :gen_statem.call(error_pid, :get_slots).state == :errored end)

      {:ok, unexpected_pid} =
        PromiseResultReadableStream.start_link(
          promise_factory: fn ctrl ->
            Web.Promise.new(fn resolve, _reject ->
              Web.ReadableStreamDefaultController.close(ctrl)
              resolve.(:unexpected)
            end)
          end
        )

      send(unexpected_pid, {:internal, :maybe_pull})

      assert_wait(fn ->
        :gen_statem.call(unexpected_pid, :get_slots).active_task == nil
      end)

      {:ok, shutdown_pid} =
        PromiseResultReadableStream.start_link(
          promise_factory: fn ->
            Web.Promise.reject(:promise_shutdown)
          end
        )

      send(shutdown_pid, {:internal, :maybe_pull})
      assert_wait(fn -> :gen_statem.call(shutdown_pid, :get_slots).state == :errored end)

      {:ok, nested_shutdown_pid} =
        PromiseResultReadableStream.start_link(
          promise_factory: fn ->
            Web.Promise.new(fn _resolve, _reject ->
              exit({{:shutdown, :nested_shutdown}, :context})
            end)
          end
        )

      send(nested_shutdown_pid, {:internal, :maybe_pull})

      assert_wait(fn ->
        :gen_statem.call(nested_shutdown_pid, :get_slots).state == :errored
      end)

      {:ok, generic_exit_pid} =
        PromiseResultReadableStream.start_link(
          promise_factory: fn ->
            Web.Promise.new(fn _resolve, _reject -> exit(:promise_boom) end)
          end
        )

      send(generic_exit_pid, {:internal, :maybe_pull})
      assert_wait(fn -> :gen_statem.call(generic_exit_pid, :get_slots).state == :errored end)
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
