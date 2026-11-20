defmodule Web.ReadableStreamDefaultReader do
  @moduledoc """
  A reader that allows exclusive access to a ReadableStream's data.

  Follows WHATWG §3.5: `read/1` returns a `%Web.Promise{}` that resolves to a
  `ReadableStreamReadResult` map (`%{value: term(), done: boolean()}`).
  """
  defstruct [:controller_pid, :owner_pid, :lock]

  @typedoc "A reader. The fields are private."
  @type t :: %__MODULE__{controller_pid: pid(), owner_pid: pid() | nil, lock: reference() | nil}

  alias Web.ReadableStream
  alias Web.TypeError

  @doc """
  Reads a chunk from the stream.

  Returns a `%Web.Promise{}` that resolves to a `ReadableStreamReadResult` map:

    * `%{value: chunk, done: false}` — data is available
    * `%{value: nil, done: true}` — the stream is closed

  If the stream is errored, the promise is rejected with the error reason.

  ## Examples

      iex> stream = Web.ReadableStream.new(%{
      ...>   start: fn c ->
      ...>     Web.ReadableStreamDefaultController.enqueue(c, "a")
      ...>     Web.ReadableStreamDefaultController.close(c)
      ...>   end
      ...> })
      iex> reader = Web.ReadableStream.get_reader(stream)
      iex> Web.await(Web.ReadableStreamDefaultReader.read(reader))
      %{value: "a", done: false}
      iex> Web.await(Web.ReadableStreamDefaultReader.read(reader))
      %{value: nil, done: true}
  """
  def read(%__MODULE__{controller_pid: pid} = reader) do
    Web.Stream.promise_call(
      pid,
      as_reader(reader, {:read, owner(reader)}),
      {:error, :not_locked_by_reader},
      &read_result/1
    )
  end

  @doc false
  # A read with no promise: the process that calls this function waits for
  # the chunk. Returns `{:ok, result}` with the result of `read/1`, or
  # `{:error, reason}` with its rejection reason.
  #
  # The code of this library that reads all the chunks of a stream uses this
  # function. A promise for each chunk is one process for each chunk, and
  # that process keeps the chunk for the linger time of a promise.
  def read_now(%__MODULE__{controller_pid: pid} = reader) do
    pid
    |> Web.Stream.request(
      as_reader(reader, {:read, owner(reader)}),
      {:error, :not_locked_by_reader}
    )
    |> read_result()
  end

  @doc false
  # A batch read with no promise, for the code of this library that reads
  # many chunks of a stream. It takes the chunks that are in the queue, up
  # to `max`, as reads one after the other. With an empty queue, it is one
  # read that waits. See the request `:read_batch` of `Web.Stream`. Returns
  # `{:ok, chunks}` with one chunk or more, `:done`, or `{:error, reason}`
  # with the rejection reason of a read.
  def read_batch_now(%__MODULE__{controller_pid: pid} = reader, max) do
    pid
    |> ReadableStream.read_batch(owner(reader), max)
    |> batch_result()
  end

  @doc false
  def batch_result({:chunks, chunks}), do: {:ok, chunks}
  def batch_result({:ok, chunk}), do: {:ok, [chunk]}
  def batch_result(:done), do: :done
  def batch_result(error), do: read_result(error)

  # The answer of the stream to a read request, as the result of a read.
  defp read_result({:ok, chunk}), do: {:ok, %{value: chunk, done: false}}
  defp read_result(:done), do: {:ok, %{value: nil, done: true}}

  defp read_result({:error, :not_locked_by_reader}) do
    {:error, %TypeError{message: "This reader is no longer locked."}}
  end

  defp read_result({:error, {:errored, reason}}), do: {:error, reason}

  # The process that has the lock. A reader from `get_reader/1` has it in
  # the struct, thus each process can use the reader.
  defp owner(%__MODULE__{owner_pid: owner}) when is_pid(owner), do: owner
  defp owner(%__MODULE__{}), do: self()

  # A request of this reader. A reader from `Web.ReadableStream.get_reader/1`
  # has the reference of its lock: a reader that released its lock has no
  # effect on the stream, also when the same process has a new reader.
  defp as_reader(%__MODULE__{lock: nil}, message), do: message
  defp as_reader(%__MODULE__{lock: lock}, message), do: {:as_reader, lock, message}

  @doc """
  Releases the reader's lock on the stream.
  """
  def release_lock(%__MODULE__{lock: nil, controller_pid: pid} = reader) do
    ReadableStream.release_lock(pid, owner(reader))
  end

  def release_lock(%__MODULE__{controller_pid: pid} = reader) do
    Web.Stream.call(pid, as_reader(reader, {:release_lock, :reader, owner(reader)}), :ok)
  end

  @doc """
  Returns a promise that fulfils when the stream is closed, as the attribute
  `closed`. It rejects with the error of the stream when the stream is
  errored, and with `Web.TypeError` when the lock of the reader is released.

  Each call gives the same promise, as in the Streams Standard. A release of
  the lock of a stream that is closed or errored replaces the promise with
  a promise that is rejected with `Web.TypeError`.
  """
  def closed(%__MODULE__{lock: nil, controller_pid: pid} = reader) do
    ReadableStream.reader_closed(pid, owner(reader))
  end

  def closed(%__MODULE__{controller_pid: pid, lock: lock}) do
    case Web.Stream.call(pid, {:reader_closed, lock}, :gone) do
      %Web.Promise{} = promise -> promise
      # The stream stopped: it was closed or errored.
      :gone -> Web.Promise.resolve(:ok)
    end
  end

  @doc """
  Cancels the stream, returning the `%Web.Promise{}` from the underlying
  stream cancellation so callers can await cleanup completion.

  The reader keeps its lock, as in the Streams Standard. A reader that
  released its lock gives a promise that rejects with `Web.TypeError`.
  """
  def cancel(reader, reason \\ :cancelled)

  def cancel(%__MODULE__{lock: nil, controller_pid: pid}, reason) do
    ReadableStream.cancel(pid, reason)
  end

  def cancel(%__MODULE__{controller_pid: pid} = reader, reason) do
    Web.Stream.promise_call(pid, as_reader(reader, {:terminate, :cancel, reason}), :ok, fn
      :ok -> {:ok, :ok}
      {:error, :not_locked_by_reader} -> read_result({:error, :not_locked_by_reader})
      {:error, thrown} -> {:error, thrown}
    end)
  end
end
