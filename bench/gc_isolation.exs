Mix.Task.run("app.start")

defmodule Web.Benchmarks.GcIsolation do
  @moduledoc false

  alias Web.WritableStream

  @chunk_size 64 * 1024
  @chunk_count 1_600
  @sample_interval_ms 2

  def run do
    metrics = measure()

    IO.puts("""
    commit=#{git_short_rev("HEAD")}
    bytes=#{metrics.bytes}
    gc_count=#{metrics.gc_count}
    max_heap_words=#{metrics.max_heap_words}
    final_heap_words=#{metrics.final_heap_words}
    peak_queue_len=#{metrics.peak_queue_len}
    samples=#{metrics.sample_count}
    """)
  end

  defp measure do
    {:ok, agent} =
      Agent.start_link(fn ->
        z = :zlib.open()
        :ok = :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)
        z
      end)

    stream =
      WritableStream.new(%{
        write: fn {_index, chunk}, _controller ->
          _ = Agent.get(agent, fn z -> :zlib.deflate(z, chunk) end)
          Process.sleep(1)
          :ok
        end
      })

    writer = WritableStream.get_writer(stream)
    pid = stream.controller_pid
    owner_pid = writer.owner_pid

    sampler = Task.async(fn -> sample_loop(pid, 0, 0, 0) end)

    flooder =
      spawn(fn ->
        chunk = :binary.copy(<<"a">>, @chunk_size)

        Enum.each(1..@chunk_count, fn index ->
          ref = make_ref()
          send(pid, {:"$gen_call", {self(), ref}, {:write, owner_pid, {index, chunk}}})
        end)
      end)

    wait_until_drained(pid)

    send(sampler.pid, :stop)

    metrics =
      sampler
      |> Task.await(:infinity)
      |> Map.merge(%{
        bytes: @chunk_size * @chunk_count,
        gc_count: gc_count(pid),
        final_heap_words: total_heap_size(pid)
      })

    if Process.alive?(agent), do: Agent.stop(agent, :normal)
    Process.exit(flooder, :kill)

    metrics
  end

  defp sample_loop(pid, max_heap_words, peak_queue_len, sample_count) do
    receive do
      :stop ->
        %{
          max_heap_words: max_heap_words,
          peak_queue_len: peak_queue_len,
          sample_count: sample_count
        }
    after
      @sample_interval_ms ->
        heap_words = total_heap_size(pid)
        queue_len = message_queue_len(pid)

        sample_loop(
          pid,
          max(max_heap_words, heap_words),
          max(peak_queue_len, queue_len),
          sample_count + 1
        )
    end
  end

  defp wait_until_drained(pid, stable_checks \\ 10)

  defp wait_until_drained(_pid, 0), do: :ok

  defp wait_until_drained(pid, stable_checks) do
    queue_len = message_queue_len(pid)
    slots = WritableStream.__get_slots__(pid)

    if queue_len == 0 and slots.pending_write_request == nil and :queue.len(slots.queued_write_requests) == 0 do
      Process.sleep(5)
      wait_until_drained(pid, stable_checks - 1)
    else
      Process.sleep(5)
      wait_until_drained(pid, 10)
    end
  end

  defp gc_count(pid) do
    case Process.info(pid, :garbage_collection) do
      {:garbage_collection, info} -> Keyword.get(info, :number_of_gcs, 0)
      _ -> 0
    end
  end

  defp total_heap_size(pid) do
    case Process.info(pid, :total_heap_size) do
      {:total_heap_size, size} -> size
      _ -> 0
    end
  end

  defp message_queue_len(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, size} -> size
      _ -> 0
    end
  end

  defp git_short_rev(ref) do
    case System.cmd("git", ["rev-parse", "--short", ref]) do
      {output, 0} -> String.trim(output)
      _ -> ref
    end
  end
end

Web.Benchmarks.GcIsolation.run()
