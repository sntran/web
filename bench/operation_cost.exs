Mix.Task.run("app.start")

defmodule Web.Benchmarks.OperationCost do
  @moduledoc false

  # The cost of one element or one operation, for one process:
  #
  #   * a stream from `ReadableStream.from/1`, read with `Enum`;
  #   * a stream with a function `pull` that enqueues one chunk;
  #   * a stream through one transform stream;
  #   * a write to a writable stream, with a function `write`;
  #   * `text/1` of a response with a body in memory;
  #   * a promise and `Web.await/1`;
  #   * a message to a process and its answer, for comparison.
  #
  # Each case runs 5 times after one run that warms up the code, and the
  # script prints the median and the range.
  #
  # Usage: mix run bench/operation_cost.exs

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController, as: Controller
  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter, as: Writer

  @count 20_000

  def run do
    IO.puts("count=#{@count}")

    report("from read with Enum", fn ->
      stream = ReadableStream.from(1..@count)
      each(fn -> @count = length(Enum.to_list(stream)) end)
    end)

    report("new with a pull that enqueues one chunk", fn ->
      stream = ReadableStream.new(%{pull: counting_pull()}, high_water_mark: 0)
      each(fn -> @count = length(Enum.to_list(stream)) end)
    end)

    report("from through one transform stream", fn ->
      stream =
        ReadableStream.pipe_through(ReadableStream.from(1..@count), Web.TransformStream.new())

      each(fn -> @count = length(Enum.to_list(stream)) end)
    end)

    report("write to a writable stream", fn ->
      sink = %{write: fn _chunk, _controller -> :ok end}
      writer = WritableStream.get_writer(WritableStream.new(sink))

      each(fn ->
        for index <- 1..@count, do: Writer.write(writer, index)
        :ok = Web.await(Writer.close(writer))
      end)
    end)

    report("text of a response with a body in memory", fn ->
      each(fn ->
        for _index <- 1..@count do
          response = Web.Response.new(body: ReadableStream.from("hello"))
          "hello" = Web.await(Web.Response.text(response))
        end
      end)
    end)

    report("a promise and await", fn ->
      each(fn ->
        for index <- 1..@count do
          ^index = Web.await(Web.Promise.new(fn resolve, _reject -> resolve.(index) end))
        end
      end)
    end)

    report("a message to a process and its answer", fn ->
      echo = spawn(fn -> echo() end)

      each(fn ->
        for index <- 1..@count do
          send(echo, {self(), index})
          receive do: (^index -> :ok)
        end
      end)
    end)
  end

  # A pull that enqueues the next number, and closes the stream after
  # `@count` numbers.
  defp counting_pull do
    counter = :counters.new(1, [])

    fn controller ->
      if :counters.get(counter, 1) >= @count do
        Controller.close(controller)
      else
        :counters.add(counter, 1, 1)
        Controller.enqueue(controller, :counters.get(counter, 1))
      end
    end
  end

  defp echo do
    receive do
      {from, value} -> send(from, value)
    end

    echo()
  end

  # The time of `work` for each element, in microseconds.
  defp each(work) do
    {time, _result} = :timer.tc(work)
    time / @count
  end

  defp report(label, run) do
    _warm_up = run.()
    costs = Enum.sort(for _run <- 1..5, do: run.())

    IO.puts(
      "#{label}: median_us=#{Float.round(Enum.at(costs, 2), 2)} " <>
        "range_us=#{Float.round(hd(costs), 2)}-#{Float.round(List.last(costs), 2)}"
    )
  end
end

Web.Benchmarks.OperationCost.run()
