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

  # The calls of the transformer that the test got.
  defp calls do
    receive do
      call when call == :flush or elem(call, 0) == :cancel -> [call | calls()]
    after
      0 -> []
    end
  end

  # The two sides have their own processes, as in the Streams Standard.
  defp slots(transform), do: ReadableStream.__get_slots__(transform.readable.controller_pid)

  defp writable_slots(transform),
    do: WritableStream.__get_slots__(transform.writable.controller_pid)

  # Writes the chunks and closes, with no await.
  defp write_all(transform, chunks) do
    writer = WritableStream.get_writer(transform.writable)
    writes = Enum.map(chunks, &Writer.write(writer, &1))
    {writer, writes, Writer.close(writer)}
  end

  # A transformer with a function `transform` that does the default
  # transform. Its transform runs in the worker of the writable side.
  defp enqueue_transformer,
    do: %{transform: fn chunk, controller -> Controller.enqueue(controller, chunk) end}

  defp eventually(fun, attempts \\ 400) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  # The owner makes the stream, and then waits. The test stops it.
  defp owned_transform do
    test = self()

    owner =
      spawn(fn ->
        send(test, {:made, TransformStream.new()})
        Process.sleep(:infinity)
      end)

    assert_receive {:made, transform}
    {owner, transform}
  end

  # The call of the default transform from the writable side. Its tag names
  # the writable side.
  defp transform_write_of?({:"$gen_call", {pid, {:"$web_sent", pid, ref}}, request}, pid),
    do: is_reference(ref) and match?({:transform_write, _chunk}, request)

  defp transform_write_of?(_message, _pid), do: false

  # The trace messages of the messages that `pid` got.
  defp received_messages(pid) do
    :erlang.trace(pid, false, [:receive])
    ref = :erlang.trace_delivered(pid)
    assert_receive {:trace_delivered, ^pid, ^ref}
    collect_received(pid)
  end

  defp collect_received(pid) do
    receive do
      {:trace, ^pid, :receive, message} -> [message | collect_received(pid)]
    after
      0 -> []
    end
  end

  # The results of a failure of the transform, for one transformer. The
  # first chunk stays in the queue of the readable side, thus the
  # backpressure is off for the second chunk.
  defp failure_outcome(transformer, scenario) do
    test = self()
    start = fn controller -> send(test, {:controller, controller}) end

    strategy =
      if scenario == :size,
        do: ByteLengthQueuingStrategy.new(16),
        else: CountQueuingStrategy.new(2)

    transform =
      TransformStream.new(Map.put(transformer, :start, start), readable_strategy: strategy)

    assert_receive {:controller, controller}
    readable = transform.readable.controller_pid
    writable = transform.writable.controller_pid
    writer = WritableStream.get_writer(transform.writable)
    reader = ReadableStream.get_reader(transform.readable)
    first = Promise.wait(Writer.write(writer, "first"))

    second =
      case scenario do
        # The chunk has no byte length: its size is not valid.
        :size ->
          Writer.write(writer, 42)

        # The write is in the mailbox of the writable side before the
        # message of the controller.
        operation when operation in [:terminate, :error] ->
          :erlang.suspend_process(writable)
          write = Writer.write(writer, "second")

          if operation == :terminate,
            do: Controller.terminate(controller),
            else: Controller.error(controller, :failed)

          :erlang.resume_process(writable)
          write

        # The readable side stopped before the write.
        :stopped ->
          Process.exit(readable, :kill)
          eventually(fn -> writable_slots(transform).transform.peer_ref == nil end)
          Writer.write(writer, "second")

        # The readable side stops before it handles the enqueue.
        :stops ->
          :erlang.suspend_process(readable)
          write = Writer.write(writer, "second")

          eventually(fn ->
            {:messages, messages} = Process.info(readable, :messages)
            Enum.any?(messages, &match?({:"$gen_call", _from, {_tag, "second"}}, &1))
          end)

          Process.exit(readable, :kill)
          write
      end

    # The read comes after the end of the write: the readable side has the
    # result of the failure.
    second = Promise.wait(second)
    closed = Promise.wait(Writer.closed(writer))
    read = if scenario in [:stopped, :stops], do: nil, else: Promise.wait(Reader.read(reader))
    {first, second, closed, read}
  end

  describe "new/2" do
    test "gives a struct with the two sides, which have the default limits of the Standard" do
      transform = TransformStream.new()

      assert %TransformStream{readable: %ReadableStream{}, writable: %WritableStream{}} =
               transform

      assert slots(transform).readable_desired_size == 0
      assert writable_slots(transform).writable_desired_size == 1
    end

    test "accepts a strategy for each side" do
      transform =
        TransformStream.new(%{},
          writable_strategy: CountQueuingStrategy.new(3),
          readable_strategy: CountQueuingStrategy.new(7)
        )

      assert writable_slots(transform).writable_desired_size == 3
      assert slots(transform).readable_desired_size == 7

      assert writable_slots(TransformStream.new(%{}, high_water_mark: 4)).writable_desired_size ==
               4
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

      # The log can have lines of the tests that run at the same time.
      refute log =~ "start failed"
      refute log =~ "terminating"
    end

    test "returns after the two sides have the end of a start that gives a value" do
      for start <- [fn _controller -> :ok end, fn _controller -> Promise.resolve(:ok) end] do
        transform = TransformStream.new(%{start: start})

        # These calls can come before a message of a worker: the sides have
        # the end of start before the constructor returns.
        assert slots(transform).active_operation == nil
        assert writable_slots(transform).active_operation == nil
      end
    end

    test "answers at once a request for the end of start after the start" do
      transform = TransformStream.new(%{start: fn _controller -> :ok end})

      for pid <- [transform.readable.controller_pid, transform.writable.controller_pid] do
        assert Web.Stream.call(pid, :await_start, :gone) == :ok
      end
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

      # This call comes after the writes from the same process. Thus the
      # writable side handled the writes when the call returns. The first
      # write is in flight, and waits for the end of the backpressure: no
      # transform runs.
      writable = writable_slots(transform)
      assert writable.active_task == nil
      assert {:write, _from} = writable.active_operation
      assert Enum.all?([ready | writes], &(Promise.peek(&1) == :pending))
      assert :queue.len(slots(transform).queue) == 0
      refute_received {:transformed, _chunk}
      assert Writer.desired_size(writer) < 0

      # One read lets one write continue.
      reader = ReadableStream.get_reader(transform.readable)
      assert await(Reader.read(reader)) == %{value: 1, done: false}
      assert await(hd(writes)) == :ok
      assert_receive {:transformed, 1}
      # The stream replied to the first write before this call. It holds the
      # second write, and no transform runs.
      assert writable_slots(transform).active_task == nil
      refute_received {:transformed, 2}
      assert Promise.peek(Enum.at(writes, 1)) == :pending
    end

    test "lets the transform run for the limit of the readable side with no reader" do
      transform = TransformStream.new(%{}, readable_strategy: CountQueuingStrategy.new(3))
      writer = WritableStream.get_writer(transform.writable)
      writes = for index <- 1..5, do: Writer.write(writer, index)

      # The first three transforms fill the readable queue. Then the stream
      # holds the writes, and no transform runs.
      for write <- Enum.take(writes, 3), do: assert(await(write) == :ok)
      assert writable_slots(transform).active_task == nil

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

    test "costs no message when it changes, and one message for each held write" do
      transform = TransformStream.new()
      readable = transform.readable.controller_pid
      writable = transform.writable.controller_pid
      writer = WritableStream.get_writer(transform.writable)
      reader = ReadableStream.get_reader(transform.readable)
      :erlang.trace(writable, true, [:receive])

      # The read comes first: its pull turns the backpressure off, and the
      # transform turns it on again. The readable side handled the read when
      # the call `slots/1` returns.
      for index <- 1..5 do
        read = Reader.read(reader)
        _slots = slots(transform)
        assert await(Writer.write(writer, index)) == :ok
        assert await(read) == %{value: index, done: false}
      end

      # The write comes first: the writable side holds it. The pull of the
      # read sends one message, and the transform runs.
      write = Writer.write(writer, :held)
      assert writable_slots(transform).active_task == nil
      assert await(Reader.read(reader)) == %{value: :held, done: false}
      assert await(write) == :ok

      releases =
        writable
        |> received_messages()
        |> Enum.count(
          &match?({:"$gen_cast", {:"$web_sent", ^readable, {:transform_backpressure, false}}}, &1)
        )

      assert releases == 1
    end

    property "loses no write when the writer and the reader are different processes" do
      check all(
              chunks <- list_of(integer(), max_length: 60),
              readable_limit <- integer(0..3),
              writable_limit <- integer(1..3),
              transformer <- member_of([%{}, enqueue_transformer()]),
              max_runs: 40
            ) do
        transform =
          TransformStream.new(transformer,
            readable_strategy: CountQueuingStrategy.new(readable_limit),
            writable_strategy: CountQueuingStrategy.new(writable_limit)
          )

        reader = Task.async(fn -> Enum.to_list(transform.readable) end)
        writer = WritableStream.get_writer(transform.writable)

        # The writer waits for the promise `ready` before each write, as a
        # pipe does. The holds of the writes and the pulls of the reader come
        # in each sequence.
        for chunk <- chunks do
          assert await(Writer.ready(writer)) == :ok
          Writer.write(writer, chunk)
        end

        assert await(Writer.close(writer)) == :ok
        assert Task.await(reader) == chunks
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

      # These are negative checks: the count of the pulls must stay below a
      # limit. Many processes do the pipes, and no message tells when they
      # did all their work. Thus the test waits for some time before each
      # check.
      Process.sleep(150)
      pulled_with_no_reader = :counters.get(counter, 1)
      assert pulled_with_no_reader <= 6

      assert Enum.take(result, 3) == [1, 2, 3]
      Process.sleep(100)
      assert :counters.get(counter, 1) <= pulled_with_no_reader + 6
    end
  end

  describe "the lock rule of the two sides" do
    test "a side that asked grants no lock until the answer, and ends when the other side stops" do
      {owner, transform} = owned_transform()
      readable = transform.readable.controller_pid
      writable = transform.writable.controller_pid

      # The owner fails: the readable side has no linger time, and no lock.
      # It asks the writable side, which does not answer.
      :erlang.suspend_process(writable)
      Process.exit(owner, :kill)
      eventually(fn -> slots(transform).transform.ending end)

      # The request names its sender, thus a priority message of the same
      # side cannot pass it.
      {:messages, messages} = Process.info(writable, :messages)
      ask = {:transform_end, :ask, {:owner_down, :killed}}
      assert {:"$gen_cast", {:"$web_sent", readable, ask}} in messages

      # A request for a lock waits in the readable side.
      reader = Task.async(fn -> ReadableStream.get_reader(transform.readable) end)
      eventually(fn -> length(slots(transform).transform.deferred) == 1 end)
      assert Task.yield(reader, 0) == nil

      # The writable side stops before its answer. The readable side ends by
      # the owner rule, and then it grants the lock of the request.
      Process.exit(writable, :kill)
      assert %Reader{} = Task.await(reader)
      assert %{state: :closed, transform: %{ending: false, deferred: []}} = slots(transform)
    end

    test "each message between the two sides names its sender" do
      transform = TransformStream.new()
      readable = transform.readable.controller_pid
      writable = transform.writable.controller_pid
      :erlang.trace(readable, true, [:receive])

      writer = WritableStream.get_writer(transform.writable)
      eventually(fn -> slots(transform).transform.peer_locked end)
      read = Reader.read(ReadableStream.get_reader(transform.readable))
      assert await(Writer.write(writer, :chunk)) == :ok
      assert await(read) == %{value: :chunk, done: false}

      messages = received_messages(readable)
      assert {:"$gen_cast", {:"$web_sent", writable, {:transform_peer_locked, true}}} in messages
      assert Enum.any?(messages, &transform_write_of?(&1, writable))
    end
  end

  describe "the default transform" do
    test "runs in no worker of the writable side" do
      for {transformer, worker?} <- [{%{}, false}, {enqueue_transformer(), true}] do
        transform = TransformStream.new(transformer)
        writer = WritableStream.get_writer(transform.writable)
        reader = ReadableStream.get_reader(transform.readable)

        for index <- 1..3 do
          read = Reader.read(reader)
          assert await(Writer.write(writer, index)) == :ok
          assert await(read) == %{value: index, done: false}
        end

        {:dictionary, dictionary} = Process.info(transform.writable.controller_pid, :dictionary)
        assert List.keymember?(dictionary, {Web.Stream, :worker}, 0) == worker?
      end
    end

    test "calls the size function of the readable side in the worker" do
      test = self()

      size = fn _chunk ->
        send(test, {:size, self()})
        1
      end

      transform = TransformStream.new(%{}, readable_strategy: %{high_water_mark: 2, size: size})
      writer = WritableStream.get_writer(transform.writable)

      assert await(Writer.write(writer, :chunk)) == :ok
      assert_received {:size, worker}
      refute worker in [transform.readable.controller_pid, transform.writable.controller_pid]
      assert Enum.take(transform.readable, 1) == [:chunk]
    end

    test "fails as a transform that enqueues the chunk" do
      type_error = &%Web.TypeError{message: "Cannot enqueue a chunk: the stream is #{&1}."}
      terminated = %Web.TypeError{message: "The transform stream was terminated."}

      for scenario <- [:size, :terminate, :error, :stopped, :stops] do
        outcome = failure_outcome(%{}, scenario)
        assert outcome == failure_outcome(enqueue_transformer(), scenario)
        assert {{:fulfilled, :ok}, {:rejected, second}, {:rejected, closed}, read} = outcome

        case scenario do
          :size ->
            assert %Web.RangeError{} = second
            assert {closed, read} == {second, {:rejected, second}}

          # The readable side is closed with a chunk in its queue: the
          # failure of the enqueue puts it in the errored state
          # (TransformStreamError).
          :terminate ->
            assert {second, closed, read} ==
                     {type_error.(:closed), terminated, {:rejected, type_error.(:closed)}}

          :error ->
            assert {second, closed, read} ==
                     {type_error.(:errored), :failed, {:rejected, :failed}}

          _stopped ->
            assert {second, closed} == {type_error.(:closed), type_error.(:closed)}
        end
      end
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
      writer = WritableStream.get_writer(transform.writable)

      assert %TypeError{message: "The transform stream was terminated."} =
               rejection(Writer.closed(writer))

      # A second close throws, as ReadableStreamDefaultController.close().
      assert_raise TypeError, "Cannot close: the stream is closed.", fn ->
        TransformStream.new(%{
          start: fn controller ->
            ReadableStreamDefaultController.close(controller)
            ReadableStreamDefaultController.close(controller)
          end
        })
      end
    end

    test "error of the readable stream controller puts the two sides in the errored state" do
      transform =
        TransformStream.new(%{
          start: fn controller -> ReadableStreamDefaultController.error(controller, :failed) end
        })

      writer = WritableStream.get_writer(transform.writable)
      assert rejection(Writer.closed(writer)) == :failed
      assert rejection(Reader.read(ReadableStream.get_reader(transform.readable))) == :failed
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

  describe "the two sides" do
    test "a transform that calls error completes its write, and then the two sides are errored" do
      transform =
        TransformStream.new(
          %{
            transform: fn chunk, controller ->
              Controller.enqueue(controller, chunk)
              Controller.error(controller, :failed)
            end
          },
          readable_strategy: CountQueuingStrategy.new(1)
        )

      writer = WritableStream.get_writer(transform.writable)

      # The writable side is erroring during the transform: the write in
      # flight completes, as WritableStreamFinishInFlightWrite specifies.
      assert await(Writer.write(writer, :chunk)) == :ok
      assert rejection(Writer.closed(writer)) == :failed
      assert rejection(Writer.write(writer, :late)) == :failed
      assert rejection(Reader.read(ReadableStream.get_reader(transform.readable))) == :failed
    end

    test "a cancel or an abort whose function cancel calls error rejects with that error" do
      for operation <- [:cancel, :abort] do
        test = self()

        transform =
          TransformStream.new(%{
            start: fn controller -> send(test, {:controller, controller}) end,
            # The function gets the controller from the test.
            cancel: fn _reason ->
              send(test, {:cancel, self()})

              receive do
                {:controller, controller} -> Controller.error(controller, :failed)
              end
            end
          })

        assert_receive {:controller, controller}
        writer = WritableStream.get_writer(transform.writable)
        reader = ReadableStream.get_reader(transform.readable)

        # The constructor returned after the end of start on the two sides.
        # Thus the error of the function cancel puts the writable side in
        # the state "errored", and not "erroring", as in JavaScript, where
        # the reaction to start comes before the reaction to the cancel.
        result =
          if operation == :cancel,
            do: Reader.cancel(reader, :no_interest),
            else: Writer.abort(writer, :stop)

        assert_receive {:cancel, worker}
        send(worker, {:controller, controller})

        # The other side is errored after the function: the operation
        # rejects with its stored error, as the algorithms of the Standard
        # specify. The side of the operation keeps its own state.
        assert rejection(result) == :failed

        if operation == :cancel do
          assert await(Reader.closed(reader)) == :ok
          assert rejection(Writer.closed(writer)) == :failed
        else
          assert rejection(Writer.closed(writer)) == :stop
          assert rejection(Reader.closed(reader)) == :failed
        end
      end
    end

    test "a flush that calls error rejects the close with that error" do
      transform = TransformStream.new(%{flush: &Controller.error(&1, :failed)})
      writer = WritableStream.get_writer(transform.writable)

      assert rejection(Writer.close(writer)) == :failed
      assert rejection(Reader.read(ReadableStream.get_reader(transform.readable))) == :failed
    end

    test "a flush that terminates and then throws rejects the close, and the readable side stays closed" do
      transform =
        TransformStream.new(%{
          flush: fn controller ->
            Controller.terminate(controller)
            raise "flush failed"
          end
        })

      writer = WritableStream.get_writer(transform.writable)
      assert %RuntimeError{message: "flush failed"} = rejection(Writer.close(writer))
      assert Enum.to_list(transform.readable) == []
    end

    test "a cancel after the end of flush gets the result of flush, with no call of cancel" do
      test = self()

      transform =
        TransformStream.new(%{
          flush: fn controller -> Controller.enqueue(controller, :last) end,
          cancel: fn reason -> send(test, {:cancel, reason}) end
        })

      writer = WritableStream.get_writer(transform.writable)
      assert await(Writer.close(writer)) == :ok

      # The readable side has a chunk in its queue: it is still readable.
      assert await(ReadableStream.cancel(transform.readable, :no_interest)) == :ok
      refute_received {:cancel, _reason}
    end

    test "a close during a cancel gets the result of the cancel, with no call of flush" do
      test = self()

      transform =
        TransformStream.new(%{
          flush: fn _controller -> send(test, :flush) end,
          cancel: fn reason ->
            send(test, {:cancel, self(), reason})

            receive do
              :continue -> :ok
            end
          end
        })

      writer = WritableStream.get_writer(transform.writable)
      cancel = ReadableStream.cancel(transform.readable, :no_interest)
      assert_receive {:cancel, worker, :no_interest}
      close = Writer.close(writer)

      # This call comes after the close from the same process: the flush of
      # the writable side waits for [[finishPromise]].
      assert WritableStream.__get_slots__(transform.writable.controller_pid).state == :closing
      send(worker, :continue)

      assert await(cancel) == :ok
      assert await(close) == :ok
      refute_received :flush
    end

    test "an abort after terminate calls no transformer, and rejects the write that waits" do
      test = self()

      transform =
        TransformStream.new(%{
          start: fn controller -> send(test, {:controller, controller}) end,
          cancel: fn reason -> send(test, {:cancel, reason}) end
        })

      assert_receive {:controller, controller}
      writer = WritableStream.get_writer(transform.writable)

      # No process reads: the write waits for the backpressure, and the
      # abort waits for the write.
      write = Writer.write(writer, :chunk)
      abort = Writer.abort(writer, :stop)
      assert WritableStream.__get_slots__(transform.writable.controller_pid).state == :erroring

      # The terminate ends the backpressure. The writable side is erroring:
      # the write rejects with the stored error. The transformer has no
      # algorithms after the terminate (TransformStreamDefaultControllerClearAlgorithms).
      assert :ok = Controller.terminate(controller)
      assert rejection(write) == :stop
      assert await(abort) == :ok
      refute_received {:cancel, _reason}
    end

    property "flush, cancel, and abort call the transformer one time, in each sequence" do
      check all(
              operations <-
                map(list_of(member_of([:close, :cancel, :abort]), min_length: 1), &Enum.uniq/1),
              max_runs: 40
            ) do
        test = self()

        transform =
          TransformStream.new(%{
            flush: fn _controller -> send(test, :flush) end,
            cancel: fn reason -> send(test, {:cancel, reason}) end
          })

        writer = WritableStream.get_writer(transform.writable)
        reader = ReadableStream.get_reader(transform.readable)

        promises =
          Enum.map(operations, fn
            :close -> Writer.close(writer)
            :cancel -> Reader.cancel(reader, :no_interest)
            :abort -> Writer.abort(writer, :stop)
          end)

        # Each operation settles. [[finishPromise]] lets only the first of
        # flush, the cancel, and the abort call the transformer.
        Enum.each(promises, &Promise.wait/1)
        assert [_call] = calls()
      end
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
              # A slow transform: a second transform that starts too early
              # comes before the end of this transform.
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
