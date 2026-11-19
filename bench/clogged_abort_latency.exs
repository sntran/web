Mix.Task.run("app.start")

defmodule Web.Benchmarks.CloggedAbortLatency do
  @moduledoc false

  # The time from the abort of a writable stream to the call of the function
  # `abort` of its sink, when the mailbox of the stream is full.
  #
  # An abort is a priority message of Erlang/OTP: the stream gets it before
  # the requests that wait in its mailbox.
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

    stream =
      WritableStream.new(%{
        write: fn _chunk, _controller ->
          send(parent, {:write_started, self()})

          receive do
            :release -> :ok
          end
        end,
        abort: fn _reason ->
          send(parent, {:sink_aborted, System.monotonic_time(:microsecond)})
          :ok
        end
      })

    writer = WritableStream.get_writer(stream)
    pid = stream.controller_pid

    # The first write stays in the sink.
    spawn(fn -> Web.Promise.wait(WritableStreamDefaultWriter.write(writer, "first")) end)

    sink =
      receive do
        {:write_started, sink} -> sink
      end

    # The stream process stops while the requests and the abort go into its
    # mailbox. Thus the abort is behind all the requests.
    :erlang.suspend_process(pid)

    for index <- 1..requests do
      send(pid, {:"$gen_call", {self(), make_ref()}, {:write, writer.owner_pid, index}})
    end

    abort = WritableStreamDefaultWriter.abort(writer, :emergency_stop)
    Process.sleep(20)
    resumed_at = System.monotonic_time(:microsecond)
    :erlang.resume_process(pid)

    elapsed =
      receive do
        {:sink_aborted, aborted_at} -> aborted_at - resumed_at
      end

    Web.Promise.wait(abort)
    send(sink, :release)
    flush()
    elapsed
  end

  # The answers of the requests that the abort rejected.
  defp flush do
    receive do
      _answer -> flush()
    after
      0 -> :ok
    end
  end
end

Web.Benchmarks.CloggedAbortLatency.run()
