defmodule Web.TLA.PriorityMessagesPropertyTest do
  # Checks the properties of `tla/PriorityMessages.tla` on the real code.
  # The test process S writes to a writable stream and aborts it. A different
  # process O writes to the same stream. The stream is suspended while the
  # messages come, thus its mailbox has them in the sequence of the test.
  # Then the stream handles them:
  #
  #   * SenderOrder: the writes of S before its abort come before the abort.
  #     The first one is in flight when the abort comes, thus the sink gets it.
  #   * AbortPasses: the abort comes before the writes of O. The sink gets
  #     no write of O.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter, as: Writer

  # A process that writes to the stream when the test asks.
  defp other_writer(writer) do
    spawn_link(fn -> other_loop(writer) end)
  end

  defp other_loop(writer) do
    receive do
      {:write, test, chunk} ->
        send(test, {:written, Writer.write(writer, chunk)})
        other_loop(writer)
    end
  end

  # Sends one message of the sequence. Returns the promise of a write, or of
  # the abort.
  defp send_event({:s, _index} = chunk, writer, _other), do: {chunk, Writer.write(writer, chunk)}
  defp send_event(:abort, writer, _other), do: {:abort, Writer.abort(writer, :stop)}

  defp send_event({:o, _index} = chunk, _writer, other) do
    send(other, {:write, self(), chunk})
    assert_receive {:written, promise}
    {chunk, promise}
  end

  defp events do
    gen all(
          writes <- list_of(member_of([:s, :o]), max_length: 6),
          at <- integer(0..length(writes))
        ) do
      numbered = writes |> Enum.with_index(1) |> Enum.map(fn {who, index} -> {who, index} end)
      List.insert_at(numbered, at, :abort)
    end
  end

  property "the writes of S before its abort come first, and the abort passes the writes of O" do
    check all(sequence <- events(), max_runs: 50) do
      test = self()

      stream =
        WritableStream.new(%{
          write: fn chunk, _controller -> send(test, {:sink_write, chunk}) end,
          abort: fn reason -> send(test, {:sink_abort, reason}) end
        })

      writer = WritableStream.get_writer(stream)
      other = other_writer(writer)
      pid = stream.controller_pid

      true = :erlang.suspend_process(pid)
      promises = Enum.map(sequence, &send_event(&1, writer, other))
      true = :erlang.resume_process(pid)

      {abort, writes} = Enum.split_with(promises, &match?({:abort, _promise}, &1))
      assert [{:abort, abort}] = abort
      assert await(abort) == :ok
      assert_receive {:sink_abort, :stop}

      # The write in flight: the first write of S before the abort.
      first = sequence |> Enum.take_while(&(&1 != :abort)) |> Enum.find(&match?({:s, _}, &1))

      for {chunk, promise} <- writes do
        if chunk == first,
          do: assert(await(promise) == :ok),
          else: assert(catch_exit(await(promise)) == :stop)
      end

      if first, do: assert_received({:sink_write, ^first})
      refute_received {:sink_write, _chunk}
      Process.unlink(other)
      Process.exit(other, :kill)
    end
  end
end
