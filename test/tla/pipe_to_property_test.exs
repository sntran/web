defmodule Web.TLA.PipeToPropertyTest do
  # Checks the properties of `tla/PipeTo.tla` on the real code. The sink
  # waits for the test before it completes each write. Thus the test knows
  # the chunks that the pipe read when an end comes:
  #
  #   * QueueBound: the desired size of the destination is not below zero
  #     during a write.
  #   * AllChunks: a pipe that ends with the close of the source gives each
  #     chunk to the sink, also when the source closes during a read.
  #   * NoLostWrite: the shutdown waits for the writes of the pipe, thus the
  #     sink gets each chunk that the pipe read.
  #   * ClosedDestCancels: a pipe to a closed or errored destination cancels
  #     the source.
  #   * PreventsActions: the options prevent their actions.
  #   * LocksReleased: the two streams are not locked after the pipe.
  #   * Progress: the pipe settles after each end.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.AbortController
  alias Web.Internal.ReadableStreamPipe
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController, as: Source
  alias Web.TypeError
  alias Web.WritableStream
  alias Web.WritableStreamDefaultController, as: Sink
  alias Web.WritableStreamDefaultWriter, as: Writer

  defp slots(%ReadableStream{controller_pid: pid}), do: ReadableStream.__get_slots__(pid)
  defp slots(%WritableStream{controller_pid: pid}), do: WritableStream.__get_slots__(pid)

  defp eventually(fun) do
    if fun.() do
      :ok
    else
      Process.sleep(1)
      eventually(fun)
    end
  end

  defp source(test) do
    stream =
      ReadableStream.new(
        %{
          start: fn controller -> send(test, {:source, controller}) end,
          cancel: fn reason -> send(test, {:cancel, reason}) end
        },
        high_water_mark: 0
      )

    assert_receive {:source, controller}
    {stream, controller}
  end

  # The sink tells the test each write, with the desired size, and waits for
  # `:go`.
  defp destination(test, hwm, init) do
    stream =
      WritableStream.new(
        %{
          start: fn controller -> send(test, {:sink, controller}) end,
          write: fn chunk, controller ->
            send(test, {:write, self(), chunk, Sink.desired_size(controller)})
            receive(do: (:go -> :ok))
          end,
          close: fn _controller -> send(test, :close) end,
          abort: fn reason -> send(test, {:abort, reason}) end
        },
        high_water_mark: hwm
      )

    assert_receive {:sink, controller}
    prepare(stream, controller, init)
    {stream, controller}
  end

  defp prepare(_stream, _controller, :writable), do: :ok

  defp prepare(stream, _controller, :closed) do
    writer = WritableStream.get_writer(stream)
    assert await(Writer.close(writer)) == :ok
    assert_receive :close
    :ok = Writer.release_lock(writer)
  end

  defp prepare(_stream, controller, :errored), do: :ok = Sink.error(controller, :dest_failed)

  defp scenario do
    gen all(
          init <- frequency([{4, constant(:writable)}, {1, member_of([:closed, :errored])}]),
          options <- list_of(member_of([:prevent_close, :prevent_abort, :prevent_cancel])),
          hwm <- member_of([1, 2]),
          chunks <- integer(0..3),
          ending <- member_of([:source_close, :source_error, :dest_error, :signal]),
          started <- integer(0..chunks),
          late <- boolean()
        ) do
      # An error or the signal comes while a write is in flight, after the
      # pipe read its chunks: then the test knows the chunks that it read.
      started = if ending == :source_close or chunks == 0, do: started, else: max(started, 1)

      # With `late`, the source gets one more chunk and closes while the
      # read of the pipe for that chunk is in progress.
      late = late and ending == :source_close and hwm == 1 and chunks > 0
      started = if late, do: chunks, else: started

      %{init: init, options: Enum.uniq(options), hwm: hwm, chunks: chunks}
      |> Map.merge(%{ending: ending, started: started, late: late})
    end
  end

  property "the pipe keeps the properties of the specification" do
    check all(case <- scenario(), max_runs: 60) do
      test = self()
      {source, source_controller} = source(test)
      {dest, sink_controller} = destination(test, case.hwm, case.init)
      signal = AbortController.new()
      options = [signal: signal.signal] ++ Enum.map(case.options, &{&1, true})

      pipe = start_pipe(source, dest, options)

      if case.init == :writable do
        run_writable(case, source, source_controller, dest, sink_controller, signal)
      else
        check_closed_dest(case)
      end

      # LocksReleased: the process of the pipe is alive.
      refute ReadableStream.locked?(source)
      refute WritableStream.locked?(dest)
      send(pipe, :stop)
    end
  end

  # The pipe of `ReadableStream.pipe_to/3`, in a process that stays after
  # the pipe until it gets `:stop`. Thus a lock that the pipe keeps stays.
  defp start_pipe(source, dest, options) do
    test = self()

    spawn_link(fn ->
      :ok = ReadableStream.get_reader(source.controller_pid)
      :ok = WritableStream.get_writer(dest.controller_pid, :pipe)
      result = ReadableStreamPipe.run(source.controller_pid, dest.controller_pid, options)
      send(test, {:pipe, outcome(result)})
      receive(do: (:stop -> :ok))
    end)
  end

  defp outcome(:ok), do: :ok
  defp outcome({:error, reason}), do: reason

  # ClosedDestCancels, and Progress.
  defp check_closed_dest(case) do
    assert_receive {:pipe, result}, 5_000

    if case.init == :closed,
      do: assert(%TypeError{} = result),
      else: assert(result == :dest_failed)

    if :prevent_cancel in case.options,
      do: refute_received({:cancel, _reason}),
      else: assert_received({:cancel, ^result})

    refute_received {:write, _worker, _chunk, _size}
  end

  defp run_writable(case, source, source_controller, dest, sink_controller, signal) do
    chunks = Enum.to_list(1..case.chunks//1)
    Enum.each(chunks, &(:ok = Source.enqueue(source_controller, &1)))
    {written, worker} = take_writes(case.started, [], nil)

    # With a write in flight, the pipe reads while the destination is ready:
    # the destination has `hwm` writes at most.
    read = min(length(chunks), case.started + case.hwm - 1)

    if case.ending != :source_close and case.started > 0 do
      eventually(fn -> slots(dest).queued_write_count == read - case.started end)
    end

    {reason, chunks} =
      if case.late do
        {close_during_read(source, worker, length(chunks) + 1), chunks ++ [length(chunks) + 1]}
      else
        reason = finish(case.ending, source_controller, sink_controller, signal)
        if worker, do: send(worker, :go)
        {reason, chunks}
      end

    {written, result} = drain(written)
    check_result(case, result, reason, Enum.reverse(written), chunks, read)
  end

  # The test lets the first `count` writes start, and completes each of them
  # except the last one.
  defp take_writes(0, written, worker), do: {written, worker}

  defp take_writes(count, written, _worker) do
    assert_receive {:write, worker, chunk, size}, 5_000
    # QueueBound.
    assert size >= 0
    if count > 1, do: send(worker, :go)
    take_writes(count - 1, [chunk | written], worker)
  end

  # The source gets the last chunk and closes before it gets the next read
  # of the pipe. The promise `closed` comes to the pipe while its read is in
  # progress, and the read gives the last chunk.
  defp close_during_read(source, worker, last) do
    pid = source.controller_pid
    true = :erlang.suspend_process(pid)
    :ok = ReadableStream.enqueue(pid, last)
    :ok = ReadableStream.close(pid)
    # The write is complete: the destination is ready, and the pipe reads.
    send(worker, :go)

    eventually(fn ->
      {:messages, messages} = Process.info(pid, :messages)
      Enum.any?(messages, &match?({:"$gen_call", _from, {:read, _pipe}}, &1))
    end)

    true = :erlang.resume_process(pid)
    :ok
  end

  defp finish(:source_close, controller, _sink, _signal) do
    :ok = Source.close(controller)
    :ok
  end

  defp finish(:source_error, controller, _sink, _signal) do
    :ok = Source.error(controller, :source_failed)
    :source_failed
  end

  defp finish(:dest_error, _controller, sink, _signal) do
    :ok = Sink.error(sink, :dest_failed)
    :dest_failed
  end

  defp finish(:signal, _controller, _sink, signal) do
    :ok = AbortController.abort(signal, :stop)
    :stop
  end

  # Completes each write until the pipe settles. Progress.
  defp drain(written) do
    receive do
      {:write, worker, chunk, size} ->
        assert size >= 0
        send(worker, :go)
        drain([chunk | written])

      {:pipe, result} ->
        {written, result}
    after
      5_000 -> flunk("the pipe did not settle")
    end
  end

  defp check_result(%{ending: :source_close} = case, result, :ok, written, chunks, _read) do
    assert result == :ok
    # AllChunks.
    assert written == chunks
    if :prevent_close in case.options, do: refute_received(:close), else: assert_received(:close)
  end

  defp check_result(%{ending: :dest_error} = case, result, reason, written, chunks, _read) do
    assert result == reason
    assert written == Enum.take(chunks, length(written))
    check_action(case, :prevent_cancel, {:cancel, reason})
    refute_received {:abort, _reason}
  end

  defp check_result(case, result, reason, written, chunks, read) do
    assert result == reason
    # NoLostWrite: the sink got each chunk that the pipe read.
    assert written == Enum.take(chunks, read)
    check_action(case, :prevent_abort, {:abort, reason})

    if case.ending == :signal,
      do: check_action(case, :prevent_cancel, {:cancel, reason}),
      else: refute_received({:cancel, _reason})
  end

  # PreventsActions.
  defp check_action(case, option, message) do
    if option in case.options do
      refute_received ^message
    else
      assert_received ^message
    end
  end
end
