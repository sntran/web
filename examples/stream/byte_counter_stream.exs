defmodule ByteCounterSink do
  @moduledoc """
  A writable stream that counts the total number of bytes written to it.
  Its underlying sink is a map of functions, as in the Streams Standard.
  """

  alias Web.WritableStream

  @doc """
  Returns the number of bytes of a chunk. A chunk of a response body is a
  `Web.Uint8Array`. A chunk from a different source can be a binary.
  """
  @spec chunk_size(Web.Uint8Array.t() | iodata()) :: non_neg_integer()
  def chunk_size(%Web.Uint8Array{byte_length: length}), do: length
  def chunk_size(chunk), do: IO.iodata_length(chunk)

  @doc """
  Makes the writable stream. At the close, the process `notify` gets the
  total number of bytes.
  """
  @spec new(pid()) :: WritableStream.t()
  def new(notify) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    WritableStream.new(%{
      write: fn chunk, _controller ->
        Agent.update(counter, &(&1 + chunk_size(chunk)))
      end,
      close: fn _controller ->
        send(notify, {:sink_counter_total, Agent.get(counter, & &1)})
        Agent.stop(counter)
      end
    })
  end
end

defmodule StreamByteCounterDemo do
  @moduledoc """
  Example demo that fetches a web resource using Web.fetch/1, then streams the response body
  through two pipelines to count the total bytes: a pipe to a writable stream, and a pipe
  through a transform stream.

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
      %Response{body: body_stream} = await(fetch(url))
      [left, right] = ReadableStream.tee(body_stream)

      sink_counter = ByteCounterSink.new(self())
      {:ok, transform_counter_pid} = Agent.start_link(fn -> 0 end)

      transform_counter =
        TransformStream.new(%{
          transform: fn chunk, controller ->
            ReadableStreamDefaultController.enqueue(controller, chunk)

            Agent.update(transform_counter_pid, fn total ->
              total + ByteCounterSink.chunk_size(chunk)
            end)

            :ok
          end,
          flush: fn controller ->
            ReadableStreamDefaultController.close(controller)
            send(parent, {:transform_counter_total, Agent.get(transform_counter_pid, & &1)})
            :ok
          end
        })

      sink_pipe = ReadableStream.pipe_to(left, sink_counter)
      transformed_readable = ReadableStream.pipe_through(right, transform_counter)

      # Read the transform while the pipe runs: a branch of a tee that no
      # process reads keeps its chunks.
      combined =
        Promise.all([
          sink_pipe,
          Response.text(Response.new(transformed_readable))
        ])

      [_pipe_ok, _transform_body] = await(combined)

      sink_total = await_total(:sink_counter_total)
      transform_total = await_total(:transform_counter_total)

      IO.puts("URL: #{url}")
      IO.puts("Sink bytes:      #{sink_total}")
      IO.puts("Transform bytes: #{transform_total}")
      IO.puts("Totals match?:   #{sink_total == transform_total}")

      Agent.stop(transform_counter_pid)
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
