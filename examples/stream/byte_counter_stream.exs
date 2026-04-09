defmodule ByteCounterStream do
  @moduledoc """
  A custom stream that counts the total number of bytes written through it.
  Used to demonstrate streaming and byte counting in the Web.Stream API.
  """

  use Web.Stream

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController

  @doc """
  Initializes the stream state, tracking the target pid and an optional notify pid.
  """
  @spec start(pid(), keyword()) :: {:producer_consumer, map()}
  def start(pid, opts) do
    {:producer_consumer,
     %{
       pid: pid,
       notify: Keyword.get(opts, :notify),
       total_bytes: 0
     }}
  end

  @doc """
  Handles each chunk, enqueues it, and updates the total byte count.
  """
  @spec write(iodata(), term(), map()) :: {:ok, map()}
  def write(chunk, controller, state) do
    binary = IO.iodata_to_binary(chunk)

    ReadableStreamDefaultController.enqueue(controller, binary)

    {:ok, %{state | total_bytes: state.total_bytes + byte_size(binary)}}
  end

  @doc """
  Closes the stream and notifies the parent process of the total byte count.
  """
  @spec flush(term(), map()) :: {:ok, map()}
  def flush(_ctrl, state) do
    ReadableStream.close(state.pid)

    if state.notify do
      send(state.notify, {:custom_counter_total, state.total_bytes})
    end

    {:ok, state}
  end

  @doc """
  Creates a new ByteCounterStream, returning readable and writable endpoints.
  """
  @spec new(keyword()) :: %{readable: Web.ReadableStream.t(), writable: Web.WritableStream.t()}
  def new(opts \\ []) do
    {:ok, pid} = start_link(opts)

    %{
      readable: %Web.ReadableStream{controller_pid: pid},
      writable: %Web.WritableStream{controller_pid: pid}
    }
  end
end

defmodule StreamByteCounterDemo do
  @moduledoc """
  Example demo that fetches a web resource using Web.fetch/1, then streams the response body
  through two pipelines to count the total bytes using a custom stream and a transform stream.

  Usage:
    mix run examples/stream/byte_counter_stream.exs [url]
  If no URL is provided, defaults to https://example.com
  """

  use Web

  @doc """
  Entry point. Accepts an optional URL argument, fetches the resource, and counts the bytes of the response body.
  """
  def run do
    run(System.argv())
  end

  def run([url | _]) do
    do_count(url)
  end

  def run([]) do
    url = "https://example.com"
    do_count(url)
  end

  defp do_count(url) do
    parent = self()
    IO.puts("Fetching: #{url}")

    try do
      %Response{body: body_stream} = await fetch(url)
      [left, right] = ReadableStream.tee(body_stream)

      custom_counter = ByteCounterStream.new(notify: self())

      transform_counter =
        TransformStream.new(%{
          transform: fn chunk, controller, state ->
            binary = IO.iodata_to_binary(chunk)
            ReadableStreamDefaultController.enqueue(controller, binary)
            total = Map.get(state, :total_bytes, 0) + byte_size(binary)
            {:ok, Map.put(state, :total_bytes, total)}
          end,
          flush: fn controller, state ->
            ReadableStreamDefaultController.close(controller)
            send(parent, {:transform_counter_total, Map.get(state, :total_bytes, 0)})
            {:ok, state}
          end
        })

      custom_pipe_task = ReadableStream.pipe_to(left, custom_counter.writable)
      transformed_readable = ReadableStream.pipe_through(right, transform_counter)

      # Drain both output streams concurrently so backpressure does not stall the pipes.
      combined =
        Promise.all([
          custom_pipe_task,
          Response.text(Response.new(body: custom_counter.readable)),
          Response.text(Response.new(body: transformed_readable))
        ])

      [_pipe_ok, _custom_body, _transform_body] = await(combined)

      custom_total = await_total(:custom_counter_total)
      transform_total = await_total(:transform_counter_total)

      IO.puts("URL: #{url}")
      IO.puts("Custom bytes:    #{custom_total}")
      IO.puts("Transform bytes: #{transform_total}")
      IO.puts("Totals match?:   #{custom_total == transform_total}")
    rescue
      e ->
        IO.puts("Failed to fetch #{url}: #{Exception.message(e)}")
    end
  end

  defp await_total(tag) do
    receive do
      {^tag, total} -> total
    after
      1_000 ->
        raise "timed out waiting for #{inspect(tag)}"
    end
  end
end

StreamByteCounterDemo.run()
