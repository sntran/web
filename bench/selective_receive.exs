Mix.Task.run("app.start")

defmodule Web.Benchmarks.SelectiveReceive do
  @moduledoc false
  @before_commit System.cmd("git", ["rev-parse", "--short", "HEAD~1"]) |> elem(0) |> String.trim()
  @after_commit System.cmd("git", ["rev-parse", "--short", "HEAD"]) |> elem(0) |> String.trim()

  @mailbox_depths %{
    "1k" => 1_000,
    "10k" => 10_000,
    "100k" => 100_000
  }
  @repetitions 2_000

  def run do
    Benchee.run(
      %{
        "#{@before_commit} (HEAD~1) legacy receive" => fn %{pid: pid} ->
          measure(pid, :legacy, @repetitions)
        end,
        "#{@after_commit} (HEAD) ref-tagged selective receive" => fn %{pid: pid} ->
          measure(pid, :optimized, @repetitions)
        end
      },
      inputs: @mailbox_depths,
      time: 3,
      memory_time: 1,
      parallel: 1,
      before_scenario: fn mailbox_depth ->
        %{pid: start_bench_process(mailbox_depth), mailbox_depth: mailbox_depth}
      end,
      after_scenario: fn %{pid: pid} = context ->
        Process.exit(pid, :kill)
        context
      end,
      formatters: [
        {Benchee.Formatters.Console, extended_statistics: true}
      ]
    )
  end

  defp start_bench_process(mailbox_depth) do
    parent = self()

    spawn_link(fn ->
      Enum.each(1..mailbox_depth, fn index ->
        send(self(), {:data_chunk, index})
      end)

      send(parent, {:bench_ready, self()})
      loop()
    end)
    |> await_ready()
  end

  defp await_ready(pid) do
    receive do
      {:bench_ready, ^pid} -> pid
    end
  end

  defp loop do
    receive do
      {:measure, caller, ref, mode, repetitions} ->
        elapsed =
          case mode do
            :legacy -> measure_legacy(repetitions)
            :optimized -> measure_optimized(repetitions)
          end

        send(caller, {ref, elapsed})
        loop()
    end
  end

  defp measure(pid, mode, repetitions) do
    ref = make_ref()
    send(pid, {:measure, self(), ref, mode, repetitions})

    receive do
      {^ref, elapsed} -> elapsed
    end
  end

  defp measure_legacy(repetitions) do
    start_time = System.monotonic_time()

    Enum.each(1..repetitions, fn _ ->
      send(self(), :control)

      receive do
        :control -> :ok
      end
    end)

    System.monotonic_time() - start_time
  end

  defp measure_optimized(repetitions) do
    start_time = System.monotonic_time()

    Enum.each(1..repetitions, fn _ ->
      ref = make_ref()
      send(self(), {:control, ref})

      receive do
        {:control, ^ref} -> :ok
      end
    end)

    System.monotonic_time() - start_time
  end
end

Web.Benchmarks.SelectiveReceive.run()
