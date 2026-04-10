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
      iex> Enum.join(ds.readable, "")
      "hello world"
  """

  use Web.Stream

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
        :zlib.inflateInit(z, window_bits)
        z
      end)

    {:producer_consumer, %{zlib_agent: agent}}
  end

  @impl Web.Stream
  def write(chunk, ctrl, %{zlib_agent: agent} = state) do
    bin = to_binary!(chunk, "DecompressionStream")

    result =
      Agent.get(agent, fn z ->
        try do
          {:ok, :zlib.inflate(z, bin)}
        rescue
          e in ErlangError -> {:error, e}
        end
      end)

    case result do
      {:ok, decompressed_chunks} ->
        for c <- decompressed_chunks do
          ReadableStreamDefaultController.wait_for_capacity(ctrl)
          ReadableStreamDefaultController.enqueue(ctrl, c)
        end

        {:ok, state}

      {:error, e} ->
        stop_agent(agent)
        raise TypeError, zlib_error_message(e)
    end
  end

  @impl Web.Stream
  def flush(ctrl, %{zlib_agent: agent} = state) do
    # Attempt to flush any remaining buffered output.
    # Per the WHATWG Compression specification, closing a decompression
    # stream before the compressed payload is complete MUST raise a
    # TypeError. Zlib signals this via :buf_error (Z_BUF_ERROR) when
    # there is no more output and Z_STREAM_END was never seen. We do NOT
    # suppress this error — a truncated stream is an integrity violation.
    # NOTE: In OTP 27+ inflate/2 returns {:ok, []} instead of raising
    # :buf_error with empty input, so the rescue and error branches below
    # are unreachable in current runtimes but kept for older OTP.
    result =
      Agent.get(agent, fn z ->
        try do
          {:ok, :zlib.inflate(z, <<>>)}
        rescue
          # coveralls-ignore-start
          e in ErlangError ->
            {:error, e}
            # coveralls-ignore-stop
        end
      end)

    # Always stop the agent — whether flush succeeds or fails.
    stop_agent(agent)

    case result do
      {:ok, final_chunks} ->
        # coveralls-ignore-start
        # In practice, inflate(<<>>) after a complete stream returns [].
        # This guard is kept for hypothetical edge cases where decompressor
        # state yields final output only on Z_FINISH flush.
        for chunk <- final_chunks, byte_size(chunk) > 0 do
          ReadableStreamDefaultController.wait_for_capacity(ctrl)
          ReadableStreamDefaultController.enqueue(ctrl, chunk)
        end

        # coveralls-ignore-stop

        {:ok, state}

      # coveralls-ignore-start
      {:error, e} ->
        raise TypeError, zlib_error_message(e)
        # coveralls-ignore-stop
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

  defp to_binary!(bin, _ctx) when is_binary(bin), do: bin
  defp to_binary!(%Uint8Array{} = arr, _ctx), do: Uint8Array.to_binary(arr)

  defp to_binary!(_, ctx),
    do: raise(TypeError, "#{ctx} chunk must be a binary or Uint8Array")

  # Stop the Agent idempotently.
  defp stop_agent(agent) do
    if Process.alive?(agent), do: Agent.stop(agent, :normal)
  end

  defp zlib_error_message(%ErlangError{original: :data_error}),
    do: "Decompression failed: invalid data"

  # coveralls-ignore-start
  # The following clauses handle errors that are unreachable in OTP 27+:
  # inflate/2 with empty input returns {:ok, []} rather than raising :buf_error;
  # :stream_error and the catch-all patterns require API misuse.
  defp zlib_error_message(%ErlangError{original: :buf_error}),
    do: "Decompression failed: compressed stream is truncated or incomplete"

  defp zlib_error_message(%ErlangError{original: :stream_error}),
    do: "Decompression failed: stream error"

  defp zlib_error_message(%ErlangError{original: {:error, reason}}),
    do: "Decompression failed: #{inspect(reason)}"

  defp zlib_error_message(%ErlangError{original: reason}),
    do: "Decompression failed: #{inspect(reason)}"

  # coveralls-ignore-stop
end
