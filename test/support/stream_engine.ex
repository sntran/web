defmodule Web.Test.StreamEngine do
  @moduledoc false

  # The requests of the stream engine (`Web.Stream`) for the tests of the
  # engine. A stream process takes these requests from the readers, the
  # writers, and the pipes of the library. A test sends them with no reader
  # or writer struct: the lock belongs to the process `owner`.

  alias Web.WritableStream

  @doc "A read for the reader lock of `owner`."
  def read(pid, owner \\ self()) when is_pid(pid),
    do: Web.Stream.call(pid, {:read, owner}, {:error, :not_locked_by_reader})

  @doc "Takes the writer lock for this process: `:ok` or `{:error, reason}`."
  def lock_writer(%WritableStream{controller_pid: pid}), do: lock_writer(pid)

  def lock_writer(pid) when is_pid(pid) do
    case Web.Stream.call(pid, {:get_writer, self(), :writer}, {:error, :released}) do
      {:ok, _lock} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "A write for the writer lock of `owner`. Waits until the sink took the chunk."
  def write(pid, owner, chunk) when is_pid(pid),
    do: Web.Stream.call(pid, {:write, owner, chunk}, {:error, :released})

  @doc "Waits for the promise `ready` of the writer lock of `owner`."
  def ready(pid, owner) when is_pid(pid),
    do: Web.Stream.call(pid, {:ready, owner}, {:error, :released})

  @doc "A close for the writer lock of `owner`. Waits until the sink closed."
  def close(pid, owner) when is_pid(pid), do: Web.Stream.control_call(pid, {:close, owner})

  @doc "An abort for the writer lock of `owner`."
  def abort(pid, owner, reason) when is_pid(pid),
    do: Web.Stream.control_call(pid, {:abort, owner, reason})

  @doc "A close or an abort with no check of the lock. Gives a promise."
  def terminate(pid, type, reason) when is_pid(pid) and type in [:close, :abort] do
    Web.Stream.promise_call(pid, {:terminate, type, reason}, :ok, fn
      :ok -> {:ok, :ok}
      {:error, thrown} -> {:error, thrown}
    end)
  end

  @doc "Releases the writer lock of `owner`."
  def release_writer(pid, owner \\ self()) when is_pid(pid),
    do: Web.Stream.call(pid, {:release_lock, :writer, owner}, :ok)

  @doc "Tells if the writer lock is held."
  def writer_locked?(%WritableStream{controller_pid: pid}), do: writer_locked?(pid)
  def writer_locked?(pid) when is_pid(pid), do: Web.Stream.call(pid, {:locked?, :writer}, false)

  @doc """
  The desired size of a writable stream: `nil` when the stream is erroring
  or errored, and 0 when it is closed.
  """
  def desired_size(%{controller_pid: pid}), do: desired_size(pid)
  def desired_size(%{pid: pid}), do: desired_size(pid)
  def desired_size(pid) when is_pid(pid), do: Web.Stream.call(pid, :desired_size, nil)

  @doc "The slot [[backpressure]] of a writable stream."
  def backpressure?(%{controller_pid: pid}), do: backpressure?(pid)
  def backpressure?(pid) when is_pid(pid), do: WritableStream.__get_slots__(pid).backpressure
end
