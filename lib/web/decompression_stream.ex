defmodule Web.DecompressionStream do
  @moduledoc """
  WHATWG-compliant `DecompressionStream`.

  Decompresses a stream of binary data using the specified format, backed by
  Erlang's native `:zlib` module. The format `"brotli"` has a decoder in
  Elixir: Erlang/OTP has no brotli.

  The stream gives its output in chunks of approximately 64 KiB, and makes
  the next chunk only when a read asks for a chunk. Thus a small compressed
  chunk that expands much does not fill the memory. The Compression
  Standard puts all the output of a chunk in the queue at once. Here a write
  that gives more than one chunk is complete only when the reads took its
  chunks. The decoder is the decoder of `Web.fetch/2`. It opens its zlib
  handle in the worker process of the stream, which runs each callback: the
  handle belongs to that process, and closes when the stream stops.

  ## Supported formats

    * `"brotli"` — brotli decompression (RFC 7932)
    * `"gzip"` — gzip decompression (window bits 31)
    * `"deflate"` — zlib-wrapped deflate (window bits 15)
    * `"deflate-raw"` — raw deflate without zlib wrapper (window bits −15)

  ## Example

      iex> ds = Web.DecompressionStream.new("gzip")
      iex> writer = Web.WritableStream.get_writer(ds.writable)
      iex> compressed = :zlib.gzip("hello world")
      iex> write = Web.WritableStreamDefaultWriter.write(writer, compressed)
      iex> close = Web.WritableStreamDefaultWriter.close(writer)
      iex> Enum.map_join(ds.readable, &to_string/1)
      "hello world"
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
  alias Web.Internal.Bytes
  alias Web.Internal.ContentDecoder
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
  Creates a new `DecompressionStream` for the given `format`.

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
    raise TypeError, "DecompressionStream format must be a string"
  end

  # ---------------------------------------------------------------------------
  # Web.Stream behavior callbacks
  # ---------------------------------------------------------------------------

  @impl Web.Stream
  def start(_pid, opts) do
    {:producer_consumer, %{format: Keyword.fetch!(opts, :format), decoder: nil}}
  end

  # The callbacks run in the worker process of the stream: the decoder
  # starts at the first chunk, thus its zlib handle belongs to the worker.
  @impl Web.Stream
  def write(chunk, ctrl, state) do
    bin = to_binary!(chunk, "DecompressionStream")
    maybe_log_runtime_event("write", byte_size(bin))
    decoder = ContentDecoder.push(decoder(state), bin)
    {:ok, %{state | decoder: drain(decoder, ctrl)}}
  end

  # The Compression Standard gives a `TypeError` when the stream closes
  # before the end of the compressed data. This is also true for a stream
  # with no data.
  @impl Web.Stream
  def flush(ctrl, state) do
    maybe_log_runtime_event("flush", 0)
    _decoder = state |> decoder() |> ContentDecoder.finish() |> drain(ctrl)
    {:ok, %{state | decoder: nil}}
  end

  # A cancel or an abort runs in the worker too: the handle closes at once.
  @impl Web.Stream
  def terminate(_event, %{decoder: decoder}) do
    if decoder, do: ContentDecoder.close(decoder)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp decoder(%{decoder: nil, format: format}), do: ContentDecoder.format(format)
  defp decoder(%{decoder: decoder}), do: decoder

  # Each piece goes to the readable side when it has space. A piece is
  # never empty.
  defp drain(decoder, ctrl) do
    case ContentDecoder.pull(decoder) do
      {:piece, piece, decoder} ->
        ReadableStreamDefaultController.wait_for_capacity(ctrl)
        ReadableStreamDefaultController.enqueue(ctrl, Uint8Array.from(piece))
        drain(decoder, ctrl)

      {_more_or_done, decoder} ->
        decoder
    end
  rescue
    error in ContentDecoder.Error ->
      maybe_log_zlib_failure(runtime_metadata(), "DecompressionStream", error)
      reraise TypeError, [message: error_message(error)], __STACKTRACE__
  end

  defp error_message(%{reason: :incomplete}),
    do: "Decompression failed: the compressed data is not complete"

  defp error_message(%{reason: :invalid}), do: "Decompression failed: invalid data"

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
          "DecompressionStream #{stage} #{bytes}B user=#{user}#{runtime_context_suffix(metadata)}"
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

  defp maybe_log_zlib_failure(metadata, context, error) do
    if Map.get(metadata, :web_runtime_observe, false) do
      Logger.error(
        runtime_log_prefix(metadata) <>
          "#{context} zlib failure: #{Exception.message(error)}#{runtime_context_suffix(metadata)}"
      )
    end
  end
end
