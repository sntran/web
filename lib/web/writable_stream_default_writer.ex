defmodule Web.WritableStreamDefaultWriter do
  @moduledoc """
  A writer that allows exclusive access to a WritableStream's sink.
  """
  defstruct [:controller_pid, :owner_pid]

  alias Web.TypeError
  alias Web.WritableStream

  @doc """
  Writes a chunk to the stream and waits until the underlying sink finishes it.
  """
  def write(%__MODULE__{controller_pid: pid, owner_pid: owner_pid}, chunk) do
    case WritableStream.write(pid, owner_pid, chunk) do
      :ok ->
        :ok

      {:error, :not_locked_by_writer} ->
        raise TypeError, "This writer is no longer locked."

      {:error, :closing} ->
        raise TypeError, "The stream is closing."

      {:error, :closed} ->
        raise TypeError, "The stream is closed."

      {:error, {:errored, _reason}} ->
        raise TypeError, "The stream is errored."

      # coveralls-ignore-start
      {:error, reason} ->
        raise TypeError, "Unknown error: #{inspect(reason)}"
        # coveralls-ignore-stop
    end
  end

  @doc """
  Resolves when the stream is ready to accept more data.
  """
  def ready(%__MODULE__{controller_pid: pid, owner_pid: owner_pid}) do
    case WritableStream.ready(pid, owner_pid) do
      :ok ->
        :ok

      {:error, :not_locked_by_writer} ->
        raise TypeError, "This writer is no longer locked."

      # coveralls-ignore-start
      {:error, {:errored, _reason}} ->
        raise TypeError, "The stream is errored."
      # coveralls-ignore-stop

      # coveralls-ignore-start
      {:error, reason} ->
        raise TypeError, "Unknown error: #{inspect(reason)}"
        # coveralls-ignore-stop
    end
  end

  @doc """
  Closes the stream after any pending writes finish.
  """
  def close(%__MODULE__{controller_pid: pid, owner_pid: owner_pid}) do
    case WritableStream.close(pid, owner_pid) do
      :ok ->
        :ok

      {:error, :closing} ->
        raise TypeError, "The stream is closing."

      {:error, :not_locked_by_writer} ->
        raise TypeError, "This writer is no longer locked."

      # coveralls-ignore-start
      {:error, {:errored, _reason}} ->
        raise TypeError, "The stream is errored."
      # coveralls-ignore-stop

      # coveralls-ignore-start
      {:error, reason} ->
        raise TypeError, "Unknown error: #{inspect(reason)}"
        # coveralls-ignore-stop
    end
  end

  @doc """
  Aborts the stream and notifies the underlying sink.
  """
  def abort(%__MODULE__{controller_pid: pid, owner_pid: owner_pid}, reason) do
    case WritableStream.abort(pid, owner_pid, reason) do
      :ok ->
        :ok

      {:error, :not_locked_by_writer} ->
        raise TypeError, "This writer is no longer locked."

      # coveralls-ignore-start
      {:error, {:errored, _reason}} ->
        raise TypeError, "The stream is errored."
      # coveralls-ignore-stop

      # coveralls-ignore-start
      {:error, error_reason} ->
        raise TypeError, "Unknown error: #{inspect(error_reason)}"
        # coveralls-ignore-stop
    end
  end

  @doc """
  Releases the writer's lock on the stream.
  """
  def release_lock(%__MODULE__{controller_pid: pid, owner_pid: owner_pid}) do
    case WritableStream.release_lock(pid, owner_pid) do
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
    WritableStream.desired_size(pid)
  end
end
