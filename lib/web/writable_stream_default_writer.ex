defmodule Web.WritableStreamDefaultWriter do
  @moduledoc """
  A writer that allows exclusive access to a WritableStream's sink.
  """
  defstruct [:controller_pid, :owner_pid]

  alias Web.Internal.QueuingStrategy
  alias Web.TypeError

  @doc """
  Writes a chunk to the stream and waits until the underlying sink finishes it.

  The size function of the queuing strategy runs in the process that calls
  this function, before the write goes to the stream, as the Streams
  Standard specifies.
  """
  def write(%__MODULE__{controller_pid: pid, owner_pid: owner_pid}, chunk) do
    case Web.Stream.__writable_size__(pid) do
      nil -> promise_call(pid, {:write, owner_pid, chunk})
      size -> promise_call(pid, {:write, owner_pid, chunk, QueuingStrategy.call(size, chunk)})
    end
  end

  @doc """
  Resolves when the stream is ready to accept more data.
  """
  def ready(%__MODULE__{controller_pid: pid, owner_pid: owner_pid}) do
    promise_call(pid, {:ready, owner_pid})
  end

  @doc """
  Closes the stream after any pending writes finish.
  """
  def close(%__MODULE__{controller_pid: pid, owner_pid: owner_pid}) do
    promise_call(pid, {:close, owner_pid})
  end

  @doc """
  Aborts the stream and notifies the underlying sink.
  """
  def abort(%__MODULE__{controller_pid: pid, owner_pid: owner_pid}, reason) do
    # A value that the abort callback of the sink throws is the rejection
    # reason, with no change.
    Web.Stream.promise_call(pid, {:abort, owner_pid, reason}, {:error, :released}, fn
      :ok ->
        {:ok, :ok}

      {:error, reason} when reason in [:not_locked_by_writer, :released] ->
        {:error, map_stream_error(reason)}

      {:error, thrown} ->
        {:error, thrown}
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp promise_call(pid, message) do
    Web.Stream.promise_call(pid, message, {:error, :released}, fn
      :ok -> {:ok, :ok}
      {:error, reason} -> {:error, map_stream_error(reason)}
    end)
  end

  defp map_stream_error(:not_locked_by_writer),
    do: TypeError.exception("This writer is no longer locked.")

  defp map_stream_error(:closing),
    do: TypeError.exception("The stream is closing.")

  defp map_stream_error(:closed),
    do: TypeError.exception("The stream is closed.")

  defp map_stream_error(:errored),
    do: TypeError.exception("The stream is errored.")

  defp map_stream_error(:lock_released),
    do: TypeError.exception("This writer is no longer locked.")

  # A write to an errored stream rejects with the error of the stream.
  defp map_stream_error({:errored, reason}), do: reason

  defp map_stream_error(:released),
    do: TypeError.exception("The stream is not available. It ended, or its owner stopped.")

  @doc """
  Releases the writer's lock on the stream.
  """
  def release_lock(%__MODULE__{controller_pid: pid, owner_pid: owner_pid}) do
    Web.Stream.call(pid, {:release_lock, :writer, owner_pid}, :ok)
  end

  @doc """
  Returns a promise that fulfils when the stream is closed, as the attribute
  `closed`. It rejects with the error of the stream when the stream is
  errored, and with `Web.TypeError` when the lock of the writer is released.
  """
  def closed(%__MODULE__{controller_pid: pid, owner_pid: owner_pid}) do
    promise_call(pid, {:wait_closed, :writer, owner_pid})
  end

  @doc """
  Returns the stream's desired size: `nil` when the stream is erroring or
  errored, and 0 when it is closed. A writer that released its lock raises
  `Web.TypeError`, as the Streams Standard specifies.
  """
  def desired_size(%__MODULE__{controller_pid: pid, owner_pid: owner_pid}) do
    case Web.Stream.call(pid, {:desired_size, :writer, owner_pid}, nil) do
      {:error, :not_locked_by_writer} -> raise map_stream_error(:not_locked_by_writer)
      size -> size
    end
  end
end
