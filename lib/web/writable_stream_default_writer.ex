defmodule Web.WritableStreamDefaultWriter do
  @moduledoc """
  A writer that allows exclusive access to a WritableStream's sink.

  The lock belongs to the writer, not to its process, as in the Streams
  Standard: a writer that released its lock has no effect on the stream,
  also when the same process has a new writer.
  """
  # The field `lock` is the reference of the lock of this writer: see
  # `Web.WritableStream.get_writer/1`.
  defstruct [:controller_pid, :owner_pid, :lock]

  @typedoc "A writer. The fields are private."
  @type t :: %__MODULE__{controller_pid: pid(), owner_pid: pid(), lock: reference()}

  alias Web.Internal.QueuingStrategy
  alias Web.TypeError

  @doc """
  Writes a chunk to the stream and waits until the underlying sink finishes it.

  The size function of the queuing strategy runs in the process that calls
  this function, before the write goes to the stream, as the Streams
  Standard specifies.
  """
  def write(%__MODULE__{controller_pid: pid, owner_pid: owner_pid} = writer, chunk) do
    case Web.Stream.__writable_size__(pid) do
      nil ->
        promise_call(writer, {:write, owner_pid, chunk})

      size ->
        promise_call(writer, {:write, owner_pid, chunk, QueuingStrategy.call(size, chunk)})
    end
  end

  @doc """
  Returns a promise that fulfils when the stream is ready to accept more
  data, as the attribute `ready`.

  Each call gives the same promise until the Streams Standard replaces it:
  the backpressure of the stream starts again, the stream gets an error, or
  the writer releases its lock.
  """
  def ready(%__MODULE__{} = writer), do: stream_promise(writer, :writer_ready)

  @doc """
  Closes the stream after any pending writes finish.
  """
  def close(%__MODULE__{owner_pid: owner_pid} = writer) do
    promise_call(writer, {:close, owner_pid})
  end

  @doc """
  Aborts the stream, as `abort(reason)`. The function `abort` of the sink
  gets the reason. The default reason is `nil`, as `undefined` in the
  Streams Standard.

  The listeners of the event `abort` of the signal of the controller run in
  the calling process before this function returns, as the Streams Standard
  specifies.
  """
  def abort(%__MODULE__{controller_pid: pid, owner_pid: owner_pid} = writer, reason \\ nil) do
    # A value that the abort callback of the sink throws is the rejection
    # reason, with no change.
    Web.Stream.__abort__(
      pid,
      {as_writer(writer, {:abort_first_steps, owner_pid, reason}),
       as_writer(writer, {:abort, owner_pid, reason})},
      reason,
      {:error, :released},
      fn
        :ok ->
          {:ok, :ok}

        {:error, reason} when reason in [:not_locked_by_writer, :released] ->
          {:error, map_stream_error(reason)}

        {:error, thrown} ->
          {:error, thrown}
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp promise_call(%__MODULE__{controller_pid: pid} = writer, message) do
    Web.Stream.promise_call(pid, as_writer(writer, message), {:error, :released}, fn
      :ok -> {:ok, :ok}
      {:error, reason} -> {:error, map_stream_error(reason)}
    end)
  end

  # A request of this writer, with the reference of its lock.
  defp as_writer(%__MODULE__{lock: lock}, message), do: {:as_writer, lock, message}

  # A promise that the stream keeps for the writer: `ready` or `closed`.
  defp stream_promise(%__MODULE__{controller_pid: pid} = writer, request) do
    case Web.Stream.call(pid, as_writer(writer, request), :gone) do
      %Web.Promise{} = promise -> promise
      :gone -> Web.Promise.reject(map_stream_error(:released))
    end
  end

  defp map_stream_error(:not_locked_by_writer),
    do: TypeError.exception("This writer is no longer locked.")

  defp map_stream_error(:closing),
    do: TypeError.exception("The stream is closing.")

  defp map_stream_error(:closed),
    do: TypeError.exception("The stream is closed.")

  defp map_stream_error(:errored),
    do: TypeError.exception("The stream is errored.")

  # A write to an errored stream rejects with the error of the stream.
  defp map_stream_error({:errored, reason}), do: reason

  defp map_stream_error(:released),
    do: TypeError.exception("The stream is not available. It ended, or its owner stopped.")

  @doc """
  Releases the writer's lock on the stream.

  A second call, or a call after a new writer took the lock, has no
  effect, as in the Streams Standard.
  """
  def release_lock(%__MODULE__{controller_pid: pid, owner_pid: owner_pid} = writer) do
    Web.Stream.call(pid, as_writer(writer, {:release_lock, :writer, owner_pid}), :ok)
  end

  @doc """
  Returns a promise that fulfils when the stream is closed, as the attribute
  `closed`. It rejects with the error of the stream when the stream is
  errored, and with `Web.TypeError` when the lock of the writer is released.

  Each call gives the same promise, as in the Streams Standard.
  """
  def closed(%__MODULE__{} = writer), do: stream_promise(writer, :writer_closed)

  @doc """
  Returns the stream's desired size: `nil` when the stream is erroring or
  errored, and 0 when it is closed. A writer that released its lock raises
  `Web.TypeError`, as the Streams Standard specifies.
  """
  def desired_size(%__MODULE__{controller_pid: pid, owner_pid: owner_pid} = writer) do
    case Web.Stream.call(pid, as_writer(writer, {:desired_size, :writer, owner_pid}), nil) do
      {:error, :not_locked_by_writer} -> raise map_stream_error(:not_locked_by_writer)
      size -> size
    end
  end
end
