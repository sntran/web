Mix.Task.run("app.start")

defmodule Web.Benchmarks.CloggedAbortLatency do
  @moduledoc false

  # The time from the abort of a writable stream to the call of the function
  # `abort` of its sink, when the mailbox of the stream is full of the writes
  # of a different process.
  #
  # An abort is a priority message of Erlang/OTP: the stream gets it before
  # the requests of the other processes that wait in its mailbox. It does not
  # pass the earlier requests of the process that aborts.
  #
  # Usage: mix run bench/clogged_abort_latency.exs

  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter

  @samples 9

  def run do
    for requests <- [1_000, 50_000, 200_000] do
      samples = Enum.sort(for _sample <- 1..@samples, do: run_sample(requests))

      IO.puts(
        "requests_in_mailbox=#{requests} median_us=#{Enum.at(samples, div(@samples, 2))} " <>
          "min_us=#{hd(samples)} max_us=#{List.last(samples)}"
      )
    end
  end

  defp run_sample(requests) do
    parent = self()

    # No write is in flight: the abort calls the function `abort` of the sink
    # at once. A write in flight would wait for its sink.
    stream =
      WritableStream.new(%{
        write: fn _chunk, _controller -> :ok end,
        abort: fn _reason ->
          send(parent, {:sink_aborted, System.monotonic_time(:microsecond)})
          :ok
        end
      })

    writer = WritableStream.get_writer(stream)
    pid = stream.controller_pid

    # The stream process stops while the requests and the abort go into its
    # mailbox. Thus the abort is behind all the requests.
    :erlang.suspend_process(pid)

    # A different process sends the writes, in the form of
    # `Web.Stream.promise_call/4`. The answers come to this process.
    writes =
      Task.async(fn ->
        for index <- 1..requests do
          tag = {:"$web_sent", self(), make_ref()}
          send(pid, {:"$gen_call", {parent, tag}, {:write, writer.owner_pid, index}})
        end
      end)

    Task.await(writes, :infinity)
    abort = WritableStreamDefaultWriter.abort(writer, :emergency_stop)
    Process.sleep(20)
    resumed_at = System.monotonic_time(:microsecond)
    :erlang.resume_process(pid)

    elapsed =
      receive do
        {:sink_aborted, aborted_at} -> aborted_at - resumed_at
      end

    Web.Promise.wait(abort)
    flush(requests)
    elapsed
  end

  # The answers of the requests that the abort rejected.
  defp flush(0), do: :ok

  defp flush(count) do
    receive do
      {{:"$web_sent", _pid, _ref}, _answer} -> flush(count - 1)
    end
  end
end

Web.Benchmarks.CloggedAbortLatency.run()
