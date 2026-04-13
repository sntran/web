defmodule Web.ReadableStreamDefaultReader do
  @moduledoc """
  A reader that allows exclusive access to a ReadableStream's data.

  Follows WHATWG §3.5: `read/1` returns a `%Web.Promise{}` that resolves to a
  `ReadableStreamReadResult` map (`%{value: term(), done: boolean()}`).
  """
  defstruct [:controller_pid]

  alias Web.Promise
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
  def read(%__MODULE__{controller_pid: pid}) do
    case ReadableStream.read(pid) do
      {:ok, chunk} ->
        Promise.resolve(%{value: chunk, done: false})

      :done ->
        Promise.resolve(%{value: nil, done: true})

      {:error, :not_locked_by_reader} ->
        Promise.reject(%TypeError{message: "This reader is no longer locked."})

      {:error, :errored} ->
        Promise.reject(%TypeError{message: "The stream is errored."})

      {:error, {:errored, reason}} ->
        Promise.reject(reason)

      {:error, reason} ->
        Promise.reject(reason)
    end
  end

  @doc """
  Releases the reader's lock on the stream.
  """
  def release_lock(%__MODULE__{controller_pid: pid}) do
    case ReadableStream.release_lock(pid) do
      :ok ->
        :ok

      {:error, :not_locked_by_reader} ->
        raise TypeError, "This reader is no longer locked."

      {:error, reason} ->
        raise TypeError, "Unknown error: #{inspect(reason)}"
    end
  end

  @doc """
  Cancels the stream, returning the `%Web.Promise{}` from the underlying
  stream cancellation so callers can await cleanup completion.
  """
  def cancel(%__MODULE__{controller_pid: pid}, reason \\ :cancelled) do
    ReadableStream.cancel(pid, reason)
  end
end
