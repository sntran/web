defmodule Web.PrioritySignalingTest do
  # A cancel, an abort, and an error are priority messages of Erlang/OTP:
  # the stream gets them before the other messages of its mailbox.
  use ExUnit.Case, async: true

  import Web, only: [await: 1]

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter

  # Stops the stream process, runs the function, and lets the process
  # continue. The messages that the function sends are in the mailbox of the
  # stream in the sequence of the calls.
  defp while_suspended(pid, fun) do
    :erlang.suspend_process(pid)

    try do
      fun.()
    after
      :erlang.resume_process(pid)
    end
  end

  # A usual request that waits in the mailbox of the stream. Its answer
  # tells if the stream handled it before or after the signal.
  defp usual_request(fun) do
    task = Task.async(fun)
    # The task sends its request, then it waits for the answer.
    Process.sleep(20)
    task
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
        request = usual_request(fn -> WritableStream.desired_size(stream) end)
        _abort = WritableStreamDefaultWriter.abort(writer, :stop)
        Process.sleep(20)
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
        request = usual_request(fn -> WritableStream.desired_size(stream) end)
        _close = WritableStreamDefaultWriter.close(writer)
        Process.sleep(20)
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
      # A source that is a process sends chunks and does not wait.
      Enum.each(1..1_000, &ReadableStream.enqueue(pid, &1))
      _cancel = ReadableStream.cancel(stream, :stop)
      Process.sleep(20)
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
        request = usual_request(fn -> ReadableStream.get_desired_size(pid) end)
        ReadableStream.error(pid, :failed)
        Process.sleep(20)
        request
      end)

    assert Task.await(request) == nil
    assert ReadableStream.__get_slots__(pid).state == :errored
  end

  test "an abort stops a stream that has a full mailbox in a short time" do
    stream = blocked_sink()
    writer = WritableStream.get_writer(stream)
    pid = stream.controller_pid

    write = Task.async(fn -> Web.Promise.wait(WritableStreamDefaultWriter.write(writer, 0)) end)
    assert_receive {:write_started, sink, 0}

    {abort, started_at} =
      while_suspended(pid, fn ->
        for index <- 1..100_000 do
          send(pid, {:"$gen_call", {self(), make_ref()}, {:write, writer.owner_pid, index}})
        end

        abort = WritableStreamDefaultWriter.abort(writer, :emergency_stop)
        Process.sleep(20)
        {abort, System.monotonic_time(:millisecond)}
      end)

    assert_receive {:sink_aborted, :emergency_stop}, 5_000
    elapsed = System.monotonic_time(:millisecond) - started_at

    # The stream does not handle the 100000 requests before the abort. The
    # limit is large for a machine that is busy.
    assert elapsed < 1_000
    assert :ok = await(abort)
    assert WritableStream.__get_slots__(pid).state == :errored

    send(sink, :release)
    Task.shutdown(write, :brutal_kill)
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
