defmodule Web.Bench.GzipBenchStream do
  @moduledoc false

  use Web.Stream

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.TypeError
  alias Web.Uint8Array
  alias Web.WritableStream

  defstruct [:readable, :writable]

  def new(format \\ "gzip")

  def new(format) when format == "gzip" do
    {:ok, pid} = start_link(format: format)

    %__MODULE__{
      readable: %ReadableStream{controller_pid: pid},
      writable: %WritableStream{controller_pid: pid}
    }
  end

  def new(format) do
    raise TypeError, "Unsupported bench compression format: #{inspect(format)}"
  end

  @impl Web.Stream
  def start(_pid, format: "gzip") do
    {:ok, agent} =
      Agent.start_link(fn ->
        z = :zlib.open()
        :ok = :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)
        z
      end)

    {:producer_consumer, %{agent: agent}}
  end

  @impl Web.Stream
  def write(chunk, ctrl, %{agent: agent} = state) do
    chunks =
      Agent.get(agent, fn z ->
        :zlib.deflate(z, to_binary!(chunk))
      end)

    emit_chunks(chunks, ctrl)

    {:ok, state}
  end

  @impl Web.Stream
  def flush(ctrl, %{agent: agent} = state) do
    chunks =
      Agent.get(agent, fn z ->
        :zlib.deflate(z, <<>>, :finish)
      end)

    emit_chunks(chunks, ctrl)

    {:ok, state}
  end

  @impl Web.Stream
  def terminate(_reason, %{agent: agent}) do
    if Process.alive?(agent), do: Agent.stop(agent, :normal)
    :ok
  end

  defp emit_chunks(chunks, ctrl) do
    Enum.each(chunks, fn chunk ->
      ReadableStreamDefaultController.enqueue(ctrl, chunk)
    end)
  end

  defp to_binary!(bin) when is_binary(bin), do: bin
  defp to_binary!(%Uint8Array{} = arr), do: Uint8Array.to_binary(arr)
  defp to_binary!(other), do: raise(TypeError, "expected binary chunk, got: #{inspect(other)}")
end
