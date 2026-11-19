defmodule Web.DecompressionStream do
  @moduledoc """
  WHATWG-compliant `DecompressionStream`.

  Decompresses a stream of binary data using the specified format, backed by
  Erlang's native `:zlib` module.

  ## OTP 26 process-ownership

  Since OTP 26 the zlib NIF resource is bound to the process that called
  `:zlib.open/0`. The `Agent` that owns the z-stream is started inside
  the engine's `start/2` callback, which runs in the gen_statem's init
  process. This links the Agent to the stream's lifecycle: if the stream
  is garbage-collected or crashes, the Agent (and thus the zlib port) is
  automatically terminated.

  ## Supported formats

    * `"gzip"` — gzip decompression (window bits 31)
    * `"deflate"` — zlib-wrapped deflate (window bits 15)
    * `"deflate-raw"` — raw deflate without zlib wrapper (window bits −15)

  ## Example

      iex> ds = Web.DecompressionStream.new("gzip")
      iex> writer = Web.WritableStream.get_writer(ds.writable)
      iex> compressed = :zlib.gzip("hello world")
      iex> Web.await(Web.WritableStreamDefaultWriter.write(writer, compressed))
      :ok
      iex> Web.await(Web.WritableStreamDefaultWriter.close(writer))
      :ok
      iex> Enum.map_join(ds.readable, &Web.Uint8Array.to_binary/1)
      "hello world"

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
  Creates a new `DecompressionStream` for the given `format`.

  Raises `Web.TypeError` if `format` is not one of `"gzip"`, `"deflate"`, or
  `"deflate-raw"`.
  """
  @spec new(String.t()) :: t()
  def new(format) when format in @valid_formats do
    window_bits = window_bits_for(format)
    {:ok, pid} = start_link(window_bits: window_bits)

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
    window_bits = Keyword.fetch!(opts, :window_bits)

    # Agent.start_link runs in the gen_statem's init process, so the Agent is
    # linked to the stream process. If the stream terminates, the Agent (and
    # thus the zlib port) is automatically cleaned up.
    {:ok, agent} =
      Agent.start_link(fn ->
        z = :zlib.open()
        # The option `:error` refuses data after the end of the compressed
        # stream, as the Compression Standard specifies.
        :zlib.inflateInit(z, window_bits, :error)
        z
      end)

    {:producer_consumer, %{zlib_agent: agent}}
  end

  @impl Web.Stream
  def write(chunk, ctrl, %{zlib_agent: agent} = state) do
    bin = to_binary!(chunk, "DecompressionStream")
    maybe_log_runtime_event("write", byte_size(bin))
    result = run_zlib(agent, fn z -> :zlib.inflate(z, bin) end, "DecompressionStream")

    case result do
      {:ok, decompressed_chunks} ->
        for c <- decompressed_chunks do
          ReadableStreamDefaultController.wait_for_capacity(ctrl)
          ReadableStreamDefaultController.enqueue(ctrl, Uint8Array.from(c))
        end

        {:ok, state}

      {:error, e} ->
        stop_agent(agent)
        raise TypeError, zlib_error_message(e)
    end
  end

  @impl Web.Stream
  def flush(_ctrl, %{zlib_agent: agent} = state) do
    # The Compression Standard gives a `TypeError` when the stream closes
    # before the end of the compressed data. `inflateEnd/1` raises if zlib
    # did not get to that end. This is also true for a stream with no data.
    maybe_log_runtime_event("flush", 0)
    result = run_zlib(agent, fn z -> :zlib.inflateEnd(z) end, "DecompressionStream")
    stop_agent(agent)

    case result do
      {:ok, :ok} ->
        {:ok, state}

      {:error, _error} ->
        raise TypeError, "Decompression failed: the compressed data is not complete"
    end
  end

  @impl Web.Stream
  def terminate(_event, %{zlib_agent: agent}) do
    stop_agent(agent)
    :ok
  end

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

  # Stop the Agent idempotently.
  defp stop_agent(agent) do
    if Process.alive?(agent), do: Agent.stop(agent, :normal)
  end

  defp run_zlib(agent, operation, context) do
    metadata = runtime_metadata()

    case Agent.get(agent, fn z ->
           try do
             {:ok, operation.(z)}
           rescue
             e in ErlangError -> {:error, e}
           end
         end) do
      {:ok, _result} = ok ->
        ok

      {:error, e} ->
        maybe_log_zlib_failure(metadata, context, e)

        {:error, e}
    end
  end

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

  defp zlib_error_message(%ErlangError{}), do: "Decompression failed: invalid data"
end
