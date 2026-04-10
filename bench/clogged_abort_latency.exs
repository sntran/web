Mix.Task.run("app.start")

defmodule Web.Benchmarks.CloggedAbortLatency do
  @moduledoc false

  import Web, only: [await: 1]

  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter

  @flood_size 50_000
  @samples 15

  def run do
    samples =
      1..@samples
      |> Enum.map(fn _ -> run_sample() end)
      |> Enum.sort()

    IO.puts("""
    commit=#{git_short_rev("HEAD")}
    samples=#{length(samples)}
    p50_us=#{percentile(samples, 50)}
    p95_us=#{percentile(samples, 95)}
    p99_us=#{percentile(samples, 99)}
    min_us=#{Enum.min(samples)}
    max_us=#{Enum.max(samples)}
    avg_us=#{Float.round(Enum.sum(samples) / length(samples), 2)}
    """)
  end

  defp run_sample do
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
          send(parent, {:sink_aborted, System.monotonic_time(:microsecond), reason})
          :ok
        end
      })

    writer = WritableStream.get_writer(stream)
    owner_pid = writer.owner_pid
    pid = stream.controller_pid

    write_task =
      Task.async(fn ->
        try do
          await(WritableStreamDefaultWriter.write(writer, "chunk-0"))
        catch
          :exit, _ -> :ok
        end
      end)

    {:sink_write_started, sink_pid, "chunk-0"} = wait_for_write_start()

    flooder =
      spawn(fn ->
        Enum.each(1..@flood_size, fn index ->
          ref = make_ref()
          send(pid, {:"$gen_call", {self(), ref}, {:write, owner_pid, "chunk-#{index}"}})
        end)

        receive do
          :stop -> :ok
        end
      end)

    wait_for_queue_pressure(pid)

    started_at = System.monotonic_time(:microsecond)
    abort_task = WritableStream.abort(stream, :emergency_stop)

    elapsed_us =
      receive do
        {:sink_aborted, aborted_at, :emergency_stop} -> aborted_at - started_at
      end

    _ = await(abort_task)

    send(sink_pid, :release)
    send(flooder, :stop)
    Task.shutdown(write_task, :brutal_kill)

    elapsed_us
  end

  defp wait_for_write_start do
    receive do
      {:sink_write_started, sink_pid, "chunk-0"} ->
        {:sink_write_started, sink_pid, "chunk-0"}
    end
  end

  defp wait_for_queue_pressure(pid, attempts \\ 1_000)

  defp wait_for_queue_pressure(_pid, 0), do: raise("mailbox pressure did not build in time")

  defp wait_for_queue_pressure(pid, attempts) do
    if Process.info(pid, :message_queue_len) |> elem(1) > 10_000 do
      :ok
    else
      Process.sleep(1)
      wait_for_queue_pressure(pid, attempts - 1)
    end
  end

  defp percentile(sorted, p) do
    index =
      sorted
      |> length()
      |> Kernel.*(p / 100)
      |> Float.ceil()
      |> trunc()
      |> max(1)

    Enum.at(sorted, index - 1)
  end

  defp git_short_rev(ref) do
    case System.cmd("git", ["rev-parse", "--short", ref]) do
      {output, 0} -> String.trim(output)
      _ -> ref
    end
  end
end

Web.Benchmarks.CloggedAbortLatency.run()
