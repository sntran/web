defmodule Web.WritableStreamDefaultWriter do
  @moduledoc """
  A writer that allows exclusive access to a WritableStream's sink.
  """
  defstruct [:controller_pid, :owner_pid]

  alias Web.TypeError

  @doc """
  Writes a chunk to the stream and waits until the underlying sink finishes it.
  """
  def write(%__MODULE__{controller_pid: pid, owner_pid: owner_pid}, chunk) do
    promise_call(pid, {:write, owner_pid, chunk})
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
    promise_call(pid, {:abort, owner_pid, reason})
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp promise_call(pid, message) do
    Web.Promise.new(fn resolve, reject ->
      case :gen_statem.call(pid, message, :infinity) do
        :ok -> resolve.(:ok)
        {:error, reason} -> reject.(map_stream_error(reason))
      end
    end)
  end

  defp map_stream_error(:not_locked_by_writer),
    do: TypeError.exception("This writer is no longer locked.")

  defp map_stream_error(:closing),
    do: TypeError.exception("The stream is closing.")

  defp map_stream_error(:closed),
    do: TypeError.exception("The stream is closed.")

  defp map_stream_error({:errored, _reason}),
    do: TypeError.exception("The stream is errored.")

  # coveralls-ignore-start
  defp map_stream_error(reason),
    do: TypeError.exception("Unknown error: #{inspect(reason)}")

  # coveralls-ignore-stop

  @doc """
  Releases the writer's lock on the stream.
  """
  def release_lock(%__MODULE__{controller_pid: pid, owner_pid: owner_pid}) do
    case :gen_statem.call(pid, {:release_lock, owner_pid}) do
      :ok ->
        :ok

      {:error, :not_locked_by_writer} ->
        raise TypeError, "This writer is no longer locked."

      # coveralls-ignore-start
      {:error, reason} ->
        raise TypeError, "Unknown error: #{inspect(reason)}"
        # coveralls-ignore-stop
    end
  end

  @doc """
  Returns the stream's desired size.
  """
  def desired_size(%__MODULE__{controller_pid: pid}) do
    :gen_statem.call(pid, :desired_size)
  end
end
