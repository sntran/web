defmodule Web.ReadableStreamDefaultReader do
  @moduledoc """
  A reader that allows exclusive access to a ReadableStream's data.

  Follows WHATWG §3.5: `read/1` returns a `%Web.Promise{}` that resolves to a
  `ReadableStreamReadResult` map (`%{value: term(), done: boolean()}`).
  """
  defstruct [:controller_pid, :owner_pid]

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
    Web.Stream.promise_call(pid, {:read, owner(reader)}, {:error, :not_locked_by_reader}, fn
      {:ok, chunk} ->
        {:ok, %{value: chunk, done: false}}

      :done ->
        {:ok, %{value: nil, done: true}}

      {:error, :not_locked_by_reader} ->
        {:error, %TypeError{message: "This reader is no longer locked."}}

      {:error, :errored} ->
        {:error, %TypeError{message: "The stream is errored."}}

      {:error, {:errored, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end)
  end

  # The process that has the lock. A reader from `get_reader/1` has it in
  # the struct, thus each process can use the reader.
  defp owner(%__MODULE__{owner_pid: owner}) when is_pid(owner), do: owner
  defp owner(%__MODULE__{}), do: self()

  @doc """
  Releases the reader's lock on the stream.
  """
  def release_lock(%__MODULE__{controller_pid: pid} = reader) do
    ReadableStream.release_lock(pid, owner(reader))
  end

  @doc """
  Returns a promise that fulfils when the stream is closed, as the attribute
  `closed`. It rejects with the error of the stream when the stream is
  errored, and with `Web.TypeError` when the lock of the reader is released.
  """
  def closed(%__MODULE__{controller_pid: pid} = reader) do
    ReadableStream.reader_closed(pid, owner(reader))
  end

  @doc """
  Cancels the stream, returning the `%Web.Promise{}` from the underlying
  stream cancellation so callers can await cleanup completion.
  """
  def cancel(%__MODULE__{controller_pid: pid}, reason \\ :cancelled) do
    ReadableStream.cancel(pid, reason)
  end
end
