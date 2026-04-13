defmodule Web.CompressionStream do
  @moduledoc """
  WHATWG-compliant `CompressionStream`.

  Compresses a stream of binary data using the specified format, backed by
  Erlang's native `:zlib` module.

  ## OTP 26 process-ownership

  Since OTP 26 the zlib NIF resource is bound to the process that called
  `:zlib.open/0`. The `Agent` that owns the z-stream is started inside
  the engine's `start/2` callback, which runs in the gen_statem's init
  process. This links the Agent to the stream's lifecycle: if the stream
  is garbage-collected or crashes, the Agent (and thus the zlib port) is
  automatically terminated.

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
      iex> compressed = Enum.join(cs.readable, "")
      iex> is_binary(compressed) and byte_size(compressed) > 0
      true
  """

  use Web.Stream

  require Logger

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
    raise TypeError, "CompressionStream format must be a string"
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
        :zlib.deflateInit(z, :default, :deflated, window_bits, 8, :default)
        z
      end)

    {:producer_consumer, %{zlib_agent: agent}}
  end

  @impl Web.Stream
  def write(chunk, ctrl, %{zlib_agent: agent} = state) do
    bin = to_binary!(chunk, "CompressionStream")
    maybe_log_runtime_event("write", byte_size(bin))
    result = run_zlib(agent, fn z -> :zlib.deflate(z, bin) end, "CompressionStream")

    case result do
      {:ok, compressed_chunks} ->
        for c <- compressed_chunks do
          ReadableStreamDefaultController.wait_for_capacity(ctrl)
          ReadableStreamDefaultController.enqueue(ctrl, c)
        end

        {:ok, state}

      # coveralls-ignore-start
      {:error, e} ->
        stop_agent(agent)
        raise TypeError, zlib_error_message(e)
        # coveralls-ignore-stop
    end
  end

  @impl Web.Stream
  def flush(ctrl, %{zlib_agent: agent} = state) do
    maybe_log_runtime_event("flush", 0)
    result = run_zlib(agent, fn z -> :zlib.deflate(z, <<>>, :finish) end, "CompressionStream")

    # Always stop the agent — whether flush succeeds or fails.
    stop_agent(agent)

    case result do
      {:ok, final_chunks} ->
        for c <- final_chunks do
          ReadableStreamDefaultController.wait_for_capacity(ctrl)
          ReadableStreamDefaultController.enqueue(ctrl, c)
        end

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

  defp run_zlib(agent, operation, context) do
    metadata = runtime_metadata()

    case Agent.get(agent, fn z ->
           try do
             {:ok, operation.(z)}
           rescue
             # coveralls-ignore-next-line
             e in ErlangError -> {:error, e}
           end
         end) do
      {:ok, _result} = ok ->
        ok

      {:error, e} ->
        # coveralls-ignore-next-line
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

  defp maybe_log_zlib_failure(metadata, context, error) do
    # coveralls-ignore-start
    # CompressionStream's zlib failure logging is defensive only.
    # On current OTP runtimes the public stream API transitions to an errored
    # stream before :zlib.deflate/2 surfaces a recoverable ErlangError here.
    if Map.get(metadata, :web_runtime_observe, false) do
      Logger.error(
        runtime_log_prefix(metadata) <>
          "#{context} zlib failure: #{Exception.message(error)}#{runtime_context_suffix(metadata)}"
      )
    end

    # coveralls-ignore-stop
  end

  # coveralls-ignore-start
  # All zlib_error_message clauses for CompressionStream are defensive only:
  # :zlib.deflate/2 does not produce ErlangErrors on valid input in normal usage.
  defp zlib_error_message(%ErlangError{original: :data_error}),
    do: "Compression failed: invalid data"

  defp zlib_error_message(%ErlangError{original: :stream_error}),
    do: "Compression failed: stream error"

  defp zlib_error_message(%ErlangError{original: {:error, reason}}),
    do: "Compression failed: #{inspect(reason)}"

  defp zlib_error_message(%ErlangError{original: reason}),
    do: "Compression failed: #{inspect(reason)}"

  # coveralls-ignore-stop
end
