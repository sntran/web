defmodule Web.PrioritySignalingTest do
  use ExUnit.Case, async: false
  import Web, only: [await: 1]

  alias Web.WritableStream

  test "abort preempts a clogged writable mailbox" do
    parent = self()

    stream =
      WritableStream.new(%{
        write: fn chunk, _controller ->
          send(parent, {:sink_write_started, self(), chunk})

          receive do
            :release -> :ok
          end
        end,
        abort: fn reason ->
          send(parent, {:sink_aborted, reason})
          :ok
        end
      })

    writer = WritableStream.get_writer(stream)
    owner_pid = writer.owner_pid
    pid = stream.controller_pid

    write_task =
      Task.async(fn ->
        catch_exit(await(Web.WritableStreamDefaultWriter.write(writer, "chunk-0")))
      end)

    assert_receive {:sink_write_started, sink_pid, "chunk-0"}

    flooder =
      spawn(fn ->
        Enum.each(1..50_000, fn index ->
          ref = make_ref()
          send(pid, {:"$gen_call", {self(), ref}, {:write, owner_pid, "chunk-#{index}"}})
        end)

        receive do
          :stop -> :ok
        end
      end)

    assert_eventually(fn ->
      slots = WritableStream.__get_slots__(pid)
      slots.pending_write_request != nil or :queue.len(slots.queued_write_requests) > 0
    end)

    started_at = System.monotonic_time(:microsecond)
    assert :ok = await(Web.WritableStreamDefaultWriter.abort(writer, :emergency_stop))
    elapsed_us = System.monotonic_time(:microsecond) - started_at

    assert elapsed_us <= 10_000
    assert_receive {:sink_aborted, :emergency_stop}
    assert WritableStream.__get_slots__(pid).state == :errored

    send(sink_pid, :release)
    send(flooder, :stop)
    Task.shutdown(write_task, :brutal_kill)
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(1)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0) do
    flunk("condition was not met in time")
  end
end
