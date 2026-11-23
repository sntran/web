defmodule Web.PrioritySignalingTest do
  # A cancel, an abort, and an error are priority messages of Erlang/OTP:
  # the stream gets them before the other messages of its mailbox.
  use ExUnit.Case, async: true

  import Web, only: [await: 1]

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.Test.StreamEngine
  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter

  # Stops the stream process, runs the function, and lets the process
  # continue. The messages that the function sends are in the mailbox of the
  # stream in the sequence of the calls. An abort, a close, a cancel, and an
  # error send their message before they return: they need no wait.
  defp while_suspended(pid, fun) do
    :erlang.suspend_process(pid)

    try do
      fun.()
    after
      :erlang.resume_process(pid)
    end
  end

  # A usual request that waits in the mailbox of the stream. Its answer
  # tells if the stream handled it before or after the signal. The function
  # returns when the request of the task is in the mailbox of the stream.
  defp usual_request(pid, fun) do
    task = Task.async(fun)
    task_pid = task.pid
    await_message(pid, &match?({:"$gen_call", {^task_pid, _tag}, _request}, &1))
    task
  end

  # Waits until the mailbox of the process has a message for which `fun`
  # gives true. The process can be suspended.
  defp await_message(pid, fun, attempts \\ 200) do
    {:messages, messages} = Process.info(pid, :messages)

    cond do
      Enum.any?(messages, fun) -> :ok
      attempts == 0 -> flunk("the message did not come")
      true -> Process.sleep(5) && await_message(pid, fun, attempts - 1)
    end
  end

  defp blocked_sink do
    test = self()

    WritableStream.new(%{
      write: fn chunk, _controller ->
        send(test, {:write_started, self(), chunk})

        receive do
          :release -> :ok
        end
      end,
      abort: fn reason ->
        send(test, {:sink_aborted, reason})
        :ok
      end
    })
  end

  test "an abort of a writer comes before the requests that wait" do
    stream = WritableStream.new()
    writer = WritableStream.get_writer(stream)

    request =
      while_suspended(stream.controller_pid, fn ->
        request =
          usual_request(stream.controller_pid, fn ->
            StreamEngine.desired_size(stream)
          end)

        _abort = WritableStreamDefaultWriter.abort(writer, :stop)
        request
      end)

    # The stream was errored when it answered the request.
    assert Task.await(request) == nil
  end

  test "a close is a usual message: it comes after the requests that wait" do
    stream = WritableStream.new()
    writer = WritableStream.get_writer(stream)

    request =
      while_suspended(stream.controller_pid, fn ->
        request =
          usual_request(stream.controller_pid, fn ->
            StreamEngine.desired_size(stream)
          end)

        _close = WritableStreamDefaultWriter.close(writer)
        request
      end)

    assert Task.await(request) == 1
  end

  test "a cancel of a readable stream comes before the chunks that wait" do
    test = self()

    stream =
      ReadableStream.new(%{
        start: fn controller -> send(test, {:controller, controller}) end,
        cancel: fn reason -> send(test, {:source_cancelled, reason}) end
      })

    assert_receive {:controller, controller}
    pid = stream.controller_pid

    while_suspended(pid, fn ->
      # A source that is a different process sends chunks and does not wait.
      from_other_process(fn -> Enum.each(1..1_000, &ReadableStream.enqueue(pid, &1)) end)
      _cancel = ReadableStream.cancel(stream, :stop)
    end)

    assert_receive {:source_cancelled, :stop}
    # The stream took no chunk: it was cancelled first.
    assert ReadableStreamDefaultController.desired_size(controller) in [0, nil]
    assert ReadableStream.__get_slots__(pid).total_queued_size == 0
  end

  test "an error of a controller comes before the chunks that wait" do
    stream = ReadableStream.new(%{pull: fn _controller -> :ok end})
    pid = stream.controller_pid

    request =
      while_suspended(pid, fn ->
        request = usual_request(pid, fn -> ReadableStream.get_desired_size(pid) end)
        ReadableStream.error(pid, :failed)
        request
      end)

    assert Task.await(request) == nil
    assert ReadableStream.__get_slots__(pid).state == :errored
  end

  test "an abort comes before the writes in a full mailbox" do
    stream = blocked_sink()
    writer = WritableStream.get_writer(stream)
    pid = stream.controller_pid

    write = Task.async(fn -> Web.Promise.wait(WritableStreamDefaultWriter.write(writer, 0)) end)
    assert_receive {:write_started, sink, 0}

    # A different process sends the writes, in the form of
    # `Web.Stream.promise_call/4`: the tag tells the sender. The answers come
    # to the test.
    test = self()

    {abort, tags} =
      while_suspended(pid, fn ->
        tags =
          from_other_process(fn ->
            for index <- 1..100_000 do
              tag = {:"$web_sent", self(), make_ref()}
              send(pid, {:"$gen_call", {test, tag}, {:write, writer.owner_pid, index}})
              tag
            end
          end)

        {WritableStreamDefaultWriter.abort(writer, :emergency_stop), tags}
      end)

    # The stream got the abort first: it is erroring, and each write of the
    # mailbox rejects immediately, while the first write is still in flight.
    # A write after the abort would wait for the first write.
    for tag <- tags do
      assert_receive {^tag, {:error, {:errored, :emergency_stop}}}, 5_000
    end

    refute_received {:sink_aborted, _reason}

    # The abort callback of the sink runs when the write in flight is
    # complete.
    send(sink, :release)
    assert {:fulfilled, :ok} = Task.await(write)
    assert_receive {:sink_aborted, :emergency_stop}
    assert :ok = await(abort)
    assert WritableStream.__get_slots__(pid).state == :errored
  end

  # Runs `fun` in a different process, and returns its result.
  defp from_other_process(fun) do
    fun |> Task.async() |> Task.await(30_000)
  end

  describe "the sequence of one sender" do
    test "a write before an abort of the same process starts first, as in the Standard" do
      test = self()

      stream =
        WritableStream.new(%{
          write: fn chunk, _controller ->
            send(test, {:write_started, self(), chunk})
            receive(do: (:release -> :ok))
          end,
          abort: fn reason -> send(test, {:sink_aborted, reason}) end
        })

      writer = WritableStream.get_writer(stream)

      {write, abort} =
        while_suspended(stream.controller_pid, fn ->
          {WritableStreamDefaultWriter.write(writer, "a"),
           WritableStreamDefaultWriter.abort(writer, :stop)}
        end)

      # WritableStreamAbort waits for the write in flight.
      assert_receive {:write_started, sink, "a"}
      refute_received {:sink_aborted, _reason}
      send(sink, :release)
      assert await(write) == :ok
      assert await(abort) == :ok
      assert_received {:sink_aborted, :stop}
    end

    test "a close before an abort of the same process is in flight, and it completes" do
      test = self()
      stream = WritableStream.new(%{close: fn _controller -> send(test, :sink_closed) end})
      writer = WritableStream.get_writer(stream)

      {close, abort} =
        while_suspended(stream.controller_pid, fn ->
          {WritableStreamDefaultWriter.close(writer),
           WritableStreamDefaultWriter.abort(writer, :stop)}
        end)

      assert await(close) == :ok
      assert await(abort) == :ok
      assert_received :sink_closed
      assert WritableStream.__get_slots__(stream.controller_pid).state == :closed
    end

    test "a chunk before an error of the same process goes to the read that waits" do
      stream = ReadableStream.new(%{})
      pid = stream.controller_pid
      reader = ReadableStream.get_reader(stream)
      read = Web.ReadableStreamDefaultReader.read(reader)
      eventually(fn -> not :queue.is_empty(ReadableStream.__get_slots__(pid).read_requests) end)

      while_suspended(pid, fn ->
        ReadableStream.enqueue(pid, "a")
        ReadableStream.error(pid, :failed)
      end)

      assert await(read) == %{value: "a", done: false}
      assert ReadableStream.__get_slots__(pid).state == :errored
    end

    test "an abort comes before the write of a different process" do
      test = self()

      stream =
        WritableStream.new(%{
          write: fn chunk, _controller -> send(test, {:write_started, chunk}) end,
          abort: fn reason -> send(test, {:sink_aborted, reason}) end
        })

      writer = WritableStream.get_writer(stream)
      pid = stream.controller_pid

      {write, abort} =
        while_suspended(pid, fn ->
          write = from_other_process(fn -> WritableStreamDefaultWriter.write(writer, "a") end)
          {write, WritableStreamDefaultWriter.abort(writer, :stop)}
        end)

      assert catch_exit(await(write)) == :stop
      assert await(abort) == :ok
      assert_received {:sink_aborted, :stop}
      refute_received {:write_started, _chunk}
    end

    test "a call with no wait before a cancel of the same process: the call names its sender" do
      # The pipe, the tees, and the parser of `Web.FormData` read a stream
      # with such a call, with their own pid in it.
      test = self()

      stream =
        ReadableStream.new(%{start: fn c -> ReadableStreamDefaultController.enqueue(c, "a") end})

      pid = stream.controller_pid
      :ok = ReadableStream.__get_reader__(pid)
      tag = make_ref()

      cancel =
        while_suspended(pid, fn ->
          send(pid, {:"$gen_call", {test, tag}, {:read, test}})
          ReadableStream.__cancel__(pid, :stop)
        end)

      # The read came first: it got the chunk in the queue.
      assert_receive {^tag, {:ok, "a"}}
      assert await(cancel) == :ok
    end

    test "the end of a pull before an error of the same source process" do
      # A source that is a process tells the end of each pull, for example
      # the process of a socket or of an enumerable.
      stream = ReadableStream.__new__(%{}, [high_water_mark: 2], direct_pull: {:process, self()})
      pid = stream.controller_pid
      assert_receive {:web_stream_pull, ref, ^pid}

      while_suspended(pid, fn ->
        ReadableStream.enqueue(pid, "a")
        Web.Stream.__send_info__(pid, {ref, :pulled})
        ReadableStream.error(pid, :failed)
      end)

      # The pull ended before the error: the stream wants one more chunk, and
      # pulls again. Then it gets the error.
      assert_receive {:web_stream_pull, _next, ^pid}
      assert ReadableStream.__get_slots__(pid).state == :errored
    end

    test "a usual cast before a cancel of the same process: the cast names its sender" do
      # The process of an enumerable gives its error as a usual cast.
      stream = ReadableStream.new(%{})
      pid = stream.controller_pid

      cancel =
        while_suspended(pid, fn ->
          Web.Stream.__usual_cast__(pid, {:error, :failed})
          ReadableStream.__cancel__(pid, :stop)
        end)

      # The error came first: the cancel of an errored stream rejects.
      assert catch_exit(await(cancel)) == :failed
    end

    test "a fence that the stream handled before the priority message" do
      stream = ReadableStream.new(%{})
      pid = stream.controller_pid
      {_item, alias} = Process.info(pid, {:dictionary, {Web.Stream, :priority_alias}})

      # The sender sends the fence and the priority message as
      # `Web.Stream.control_cast/2` does. The stream handles the fence first.
      fence = make_ref()
      send(pid, {:"$web_fence", fence})
      assert ReadableStream.__get_slots__(pid).state == :readable
      message = {:"$gen_cast", {:"$web_fenced", self(), fence, {:error, :failed}}}
      :erlang.send(alias, message, [:priority])

      assert ReadableStream.__get_slots__(pid).state == :errored
      # The stream forgot the fence.
      key = {:"$web_fence", fence}
      assert Process.info(pid, {:dictionary, key}) == {{:dictionary, key}, :undefined}
    end
  end

  defp eventually(fun) do
    if fun.() do
      :ok
    else
      Process.sleep(1)
      eventually(fun)
    end
  end

  test "a signal to a stream that stopped, and to a process that is not a stream" do
    stream = ReadableStream.from([1])
    assert Enum.to_list(stream) == [1]
    assert :ok = await(ReadableStream.cancel(stream, :late))

    # A process with no priority alias gets a usual message.
    other = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = Web.Stream.control_cast(other, {:error, :ignored})
    assert {:messages, [{:"$gen_cast", {:error, :ignored}}]} = Process.info(other, :messages)
    Process.exit(other, :kill)
  end
end
