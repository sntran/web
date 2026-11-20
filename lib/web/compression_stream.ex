defmodule Web.CompressionStream do
  @moduledoc """
  WHATWG-compliant `CompressionStream`.

  Compresses a stream of binary data using the specified format, backed by
  Erlang's native `:zlib` module.

  ## The zlib handle

  A zlib handle belongs to the process that opens it. The stream opens its
  handle in its worker process, which runs each callback, at the first
  chunk. The handle closes when the stream stops.

  ## Supported formats

    * `"gzip"` — gzip compression (window bits 31)
    * `"deflate"` — zlib-wrapped deflate (window bits 15)
    * `"deflate-raw"` — raw deflate without zlib wrapper (window bits −15)

  ## Example

      iex> cs = Web.CompressionStream.new("gzip")
      iex> writer = Web.WritableStream.get_writer(cs.writable)
      iex> Web.await(Web.WritableStreamDefaultWriter.write(writer, "hello"))
      :ok
      iex> Web.await(Web.WritableStreamDefaultWriter.close(writer))
      :ok
      iex> [%Web.Uint8Array{} | _] = chunks = Enum.to_list(cs.readable)
      iex> chunks |> Enum.map_join(&Web.Uint8Array.to_binary/1) |> :zlib.gunzip()
      "hello"

  Each chunk of the readable side is a `Web.Uint8Array`, as the Compression
  Standard specifies. A chunk for the writable side is a binary, a
  `Web.Uint8Array`, or a `Web.ArrayBuffer`.
  """

  use Web.Stream

  require Logger

  alias Web.Internal.Bytes
  alias Web.ReadableStreamDefaultController
  alias Web.TypeError
  alias Web.Uint8Array

  defstruct [:readable, :writable]

  @type t :: %__MODULE__{
          readable: Web.ReadableStream.t(),
          writable: Web.WritableStream.t()
        }

  @valid_formats ~w[gzip deflate deflate-raw]

  @doc """
  Creates a new `CompressionStream` for the given `format`.

  Raises `Web.TypeError` if `format` is not one of `"gzip"`, `"deflate"`, or
  `"deflate-raw"`.
  """
  @spec new(String.t()) :: t()
  def new(format) when format in @valid_formats do
    {:ok, pid} = start_link(window_bits: window_bits_for(format))

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
    {:producer_consumer, %{window_bits: Keyword.fetch!(opts, :window_bits), zlib: nil}}
  end

  # The callbacks run in the worker process of the stream: the handle opens
  # at the first chunk, thus it belongs to the worker.
  @impl Web.Stream
  def write(chunk, ctrl, state) do
    bin = to_binary!(chunk, "CompressionStream")
    maybe_log_runtime_event("write", byte_size(bin))
    zlib = zlib(state)

    # A deflate of bytes cannot fail.
    for c <- :zlib.deflate(zlib, bin) do
      ReadableStreamDefaultController.wait_for_capacity(ctrl)
      ReadableStreamDefaultController.enqueue(ctrl, Uint8Array.from(c))
    end

    {:ok, %{state | zlib: zlib}}
  end

  @impl Web.Stream
  def flush(ctrl, state) do
    maybe_log_runtime_event("flush", 0)
    zlib = zlib(state)
    final_chunks = :zlib.deflate(zlib, <<>>, :finish)
    :zlib.close(zlib)

    # The last chunks do not wait for the reader, thus the close of the
    # writable side does not need a reader, as in the Streams Standard.
    for c <- final_chunks,
        do: ReadableStreamDefaultController.enqueue(ctrl, Uint8Array.from(c))

    {:ok, %{state | zlib: nil}}
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

  defp zlib(%{zlib: nil, window_bits: window_bits}) do
    zlib = :zlib.open()
    :ok = :zlib.deflateInit(zlib, :default, :deflated, window_bits, 8, :default)
    zlib
  end

  defp zlib(%{zlib: zlib}), do: zlib

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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
