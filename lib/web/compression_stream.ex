defmodule Web.CompressionStream do
  @moduledoc """
  WHATWG-compliant `CompressionStream`.

  Compresses a stream of binary data using the specified format, backed by
  Erlang's native `:zlib` module. The format `"brotli"` has an encoder in
  Elixir: Erlang/OTP has no brotli.

  ## The zlib handle

  A zlib handle belongs to the process that opens it. The stream opens its
  handle in its worker process, which runs each callback, at the first
  chunk. The handle closes when the stream stops.

  ## Supported formats

    * `"brotli"` — brotli compression (RFC 7932), with a simple encoder: one
      prefix code for each alphabet, and repeated strings of 4 bytes or more
      in a window of 256 KiB
    * `"gzip"` — gzip compression (window bits 31)
    * `"deflate"` — zlib-wrapped deflate (window bits 15)
    * `"deflate-raw"` — raw deflate without zlib wrapper (window bits −15)

  ## Example

      iex> cs = Web.CompressionStream.new("gzip")
      iex> writer = Web.WritableStream.get_writer(cs.writable)
      iex> write = Web.WritableStreamDefaultWriter.write(writer, "hello")
      iex> close = Web.WritableStreamDefaultWriter.close(writer)
      iex> [%Web.Uint8Array{} | _] = chunks = Enum.to_list(cs.readable)
      iex> chunks |> Enum.map_join(&Web.Uint8Array.to_binary/1) |> :zlib.gunzip()
      "hello"
      iex> {Web.await(write), Web.await(close)}
      {:ok, :ok}

  The transform of a chunk starts only when a read asks for a chunk, as the
  Compression Standard specifies: the readable side has the high water mark
  0, and the writable side has the high water mark 1. Thus start the read
  before you wait for a write.

  Each chunk of the readable side is a `Web.Uint8Array`, as the Compression
  Standard specifies. A chunk for the writable side is a binary, a
  `Web.Uint8Array`, or a `Web.ArrayBuffer`.
  """

  use Web.Stream

  require Logger

  alias Web.CountQueuingStrategy
  alias Web.Internal.Brotli.Encoder
  alias Web.Internal.Bytes
  alias Web.ReadableStreamDefaultController
  alias Web.TypeError
  alias Web.Uint8Array

  defstruct [:readable, :writable]

  @type t :: %__MODULE__{
          readable: Web.ReadableStream.t(),
          writable: Web.WritableStream.t()
        }

  @valid_formats ~w[brotli gzip deflate deflate-raw]

  # The Compression Standard sets up the stream with the steps "set up a
  # TransformStream" of the Streams Standard. These steps give the writable
  # side the high water mark 1 and the readable side the high water mark 0.
  # The size of each chunk is 1 on the two sides. Thus the transform of a
  # chunk starts only when a reader asks for a chunk.
  @queuing [
    high_water_mark: 1,
    writable_size: :count,
    strategy: %CountQueuingStrategy{high_water_mark: 0}
  ]

  @doc """
  Creates a new `CompressionStream` for the given `format`.

  Raises `Web.TypeError` if `format` is not one of `"brotli"`, `"gzip"`,
  `"deflate"`, or `"deflate-raw"`.
  """
  @spec new(String.t()) :: t()
  def new(format) when format in @valid_formats do
    {:ok, pid} = start_link([format: format] ++ @queuing)

    %__MODULE__{
      readable: %Web.ReadableStream{controller_pid: pid},
      writable: %Web.WritableStream{controller_pid: pid}
    }
  end

  def new(format) when is_binary(format) do
    raise TypeError, "Unsupported compression format: #{inspect(format)}"
  end

  def new(_) do
    raise TypeError, "CompressionStream format must be a string"
  end

  # ---------------------------------------------------------------------------
  # Web.Stream behavior callbacks
  # ---------------------------------------------------------------------------

  @impl Web.Stream
  def start(_pid, opts) do
    {:producer_consumer, %{format: Keyword.fetch!(opts, :format), zlib: nil, brotli: nil}}
  end

  # The callbacks run in the worker process of the stream: the handle opens
  # at the first chunk, thus it belongs to the worker.
  #
  # The step "compress and enqueue a chunk" of the Compression Standard puts
  # all the output of a chunk in the queue of the readable side. The output
  # of a chunk is approximately as large as the chunk, or smaller, and it is
  # in the memory already. Thus the output does not wait for the reader, and
  # the write is complete when the output is in the queue. The next write
  # waits until a read asks for a chunk: see `@queuing`.
  @impl Web.Stream
  def write(chunk, ctrl, state) do
    bin = to_binary!(chunk, "CompressionStream")
    maybe_log_runtime_event("write", byte_size(bin))
    {chunks, state} = compress(state, bin)
    enqueue_all(ctrl, chunks)
    {:ok, state}
  end

  # The last chunks do not wait for the reader, thus the close of the
  # writable side does not need a reader, as in the Streams Standard.
  @impl Web.Stream
  def flush(ctrl, state) do
    maybe_log_runtime_event("flush", 0)
    {final_chunks, state} = compress_end(state)
    enqueue_all(ctrl, final_chunks)
    {:ok, state}
  end

  # A cancel or an abort runs in the worker too: the handle closes at once.
  @impl Web.Stream
  def terminate(_event, %{zlib: zlib}) do
    if zlib, do: :zlib.close(zlib)
    :ok
  rescue
    # The handle of a worker that stopped is closed already.
    ErlangError -> :ok
  end

  # A deflate of bytes cannot fail. The brotli encoder gives no output until
  # it has a block, or until the end.
  defp compress(%{format: "brotli"} = state, bin) do
    {out, encoder} = Encoder.push(state.brotli || Encoder.new(), bin)
    {if(out == <<>>, do: [], else: [out]), %{state | brotli: encoder}}
  end

  defp compress(state, bin) do
    zlib = zlib(state)
    {:zlib.deflate(zlib, bin), %{state | zlib: zlib}}
  end

  defp compress_end(%{format: "brotli"} = state),
    do: {[Encoder.finish(state.brotli || Encoder.new())], %{state | brotli: nil}}

  defp compress_end(state) do
    zlib = zlib(state)
    final_chunks = :zlib.deflate(zlib, <<>>, :finish)
    :zlib.close(zlib)
    {final_chunks, %{state | zlib: nil}}
  end

  defp zlib(%{zlib: nil, format: format}) do
    zlib = :zlib.open()
    :ok = :zlib.deflateInit(zlib, :default, :deflated, window_bits_for(format), 8, :default)
    zlib
  end

  defp zlib(%{zlib: zlib}), do: zlib

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp enqueue_all(ctrl, chunks) do
    for c <- chunks, do: ReadableStreamDefaultController.enqueue(ctrl, Uint8Array.from(c))
  end

  defp window_bits_for("gzip"), do: 31
  defp window_bits_for("deflate"), do: 15
  defp window_bits_for("deflate-raw"), do: -15

  defp to_binary!(chunk, ctx) when is_list(chunk) do
    raise TypeError, "#{ctx} chunk must be a binary, a Uint8Array, or an ArrayBuffer"
  end

  defp to_binary!(chunk, ctx), do: Bytes.to_binary!(chunk, ctx)

  defp maybe_log_runtime_event(stage, bytes) do
    metadata = runtime_metadata()

    if Map.get(metadata, :web_runtime_observe, false) do
      user = Map.get(metadata, :user, "unknown")

      Logger.info(
        runtime_log_prefix(metadata) <>
          "CompressionStream #{stage} #{bytes}B user=#{user}#{runtime_context_suffix(metadata)}"
      )
    end
  end

  defp runtime_log_prefix(metadata) do
    String.duplicate("  ", Map.get(metadata, :group_depth, 0))
  end

  defp runtime_metadata do
    case :logger.get_process_metadata() do
      current when is_map(current) -> current
      _ -> %{}
    end
  end

  defp runtime_context_suffix(metadata) do
    context = Map.take(metadata, [:group_depth, :request_id, :user])
    if context == %{}, do: "", else: " metadata=" <> inspect(context)
  end
end
