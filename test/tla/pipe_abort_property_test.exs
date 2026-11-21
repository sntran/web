defmodule Web.TLA.PipeAbortPropertyTest do
  # Checks the properties of `tla/PipeAbort.tla` on the real code. The test
  # cannot control each message between the pipe, the destination, and its
  # worker, thus it checks the properties in each case of the destination:
  #
  #   * AbortFirst: a destination that can abort at once calls the abort
  #     callback of the sink before the source gets its cancel. The callback
  #     waits until the pipe waits, and then it looks at the source.
  #   * Progress: the pipe settles, with the first failure of its actions.
  #   * NoLateNotice: the process of the pipe has no message while it waits
  #     for the result of the cancel.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.AbortSignal
  alias Web.Internal.ReadableStreamPipe
  alias Web.ReadableStream
  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter, as: Writer

  defp slots(%ReadableStream{controller_pid: pid}), do: ReadableStream.__get_slots__(pid)
  defp slots(pid) when is_pid(pid), do: WritableStream.__get_slots__(pid)

  defp eventually(fun) do
    if fun.() do
      :ok
    else
      Process.sleep(1)
      eventually(fun)
    end
  end

  # The process of the pipe waits for the answer of an action, with no
  # message.
  defp waits?(pid) do
    case Process.info(pid, [:current_function, :message_queue_len]) do
      [current_function: {ReadableStreamPipe, name, _arity}, message_queue_len: 0] ->
        name in [:await_steps, :collect]

      _other ->
        false
    end
  end

  # The abort callback of the sink. For a destination that can abort at
  # once, it tells the test if the source was readable when the pipe
  # waited. Then it returns, as `kind` tells.
  defp abort_callback(test, source, kind, ready?) do
    fn reason ->
      if ready?, do: send(test, {:source_readable, readable_when_pipe_waits?(source)})

      case kind do
        :returns ->
          :ok

        :promise ->
          {promise, resolve, _reject} = Web.Promise.with_resolvers()
          send(test, {:resolve, resolve})
          promise

        :throws ->
          throw({:abort_failed, reason})
      end
    end
  end

  # The process of the pipe holds the reader lock of the source.
  defp readable_when_pipe_waits?(source) do
    pipe = slots(source).reader_pid
    eventually(fn -> waits?(pipe) end)
    slots(source).state == :readable
  end

  # The destination of each case, and the function that completes the
  # operation that it waits for.
  defp destination(:ready, abort) do
    {:ok, pid} = WritableStream.start_link(underlying_sink: %{abort: abort})
    {pid, fn -> :ok end}
  end

  defp destination(:write_in_flight, abort) do
    test = self()

    write = fn _chunk, _controller ->
      send(test, {:writing, self()})
      receive(do: (:go -> :ok))
    end

    stream = WritableStream.new(%{write: write, abort: abort})
    writer = WritableStream.get_writer(stream)
    _write = Writer.write(writer, "a")
    assert_receive {:writing, worker}
    :ok = Writer.release_lock(writer)
    {stream.controller_pid, fn -> send(worker, :go) end}
  end

  defp destination(:not_started, abort) do
    {start, resolve, _reject} = Web.Promise.with_resolvers()
    stream = WritableStream.new(%{start: fn _controller -> start end, abort: abort})
    {stream.controller_pid, fn -> resolve.(:ok) end}
  end

  property "the abort of the sink comes first, the pipe settles, and it gets no late notice" do
    check all(
            dest_case <- member_of([:ready, :write_in_flight, :not_started]),
            kind <- member_of([:returns, :promise, :throws]),
            max_runs: 30
          ) do
      test = self()

      cancel = fn reason ->
        send(test, {:cancel, self(), reason})
        receive(do: (:go -> :ok))
      end

      source = ReadableStream.new(%{cancel: cancel}, high_water_mark: 0)
      abort = abort_callback(test, source, kind, dest_case == :ready)
      {dest, release} = destination(dest_case, abort)

      pipe = ReadableStream.pipe_to(source, dest, signal: AbortSignal.abort(:stop))
      pipe_pid = slots(dest).writer_pid

      # AbortFirst.
      if dest_case == :ready, do: assert_receive({:source_readable, true}, 5_000)

      assert_receive {:cancel, cancel_worker, :stop}, 5_000
      release.()

      if kind == :promise do
        assert_receive {:resolve, resolve}, 5_000
        resolve.(:ok)
      end

      # NoLateNotice: the pipe took the result of the abort, and it waits for
      # the cancel. It has no other message.
      eventually(fn -> abort_done?(dest) and only_notices?(pipe_pid) end)
      assert {:messages, []} = Process.info(pipe_pid, :messages)
      send(cancel_worker, :go)

      # Progress.
      expected = if kind == :throws, do: {:abort_failed, :stop}, else: :stop
      assert catch_exit(await(pipe)) == expected
    end
  end

  # The pipe waits for the cancel, and its mailbox has only notices.
  defp only_notices?(pid) do
    case Process.info(pid, [:current_function, :messages]) do
      [current_function: {ReadableStreamPipe, :collect, 2}, messages: messages] ->
        Enum.all?(messages, &match?({:abort_steps_done, _tag}, &1))

      _other ->
        false
    end
  end

  # The destination replied to the abort.
  defp abort_done?(dest) do
    case slots(dest) do
      %{pending_abort_request: nil, abort_request: nil} -> true
      _other -> false
    end
  end
end
