defmodule Web.ReadableStreamAsyncIterator do
  @moduledoc """
  The asynchronous iterator of a `Web.ReadableStream`, as the asynchronous
  iteration of the Streams Standard (`for await (const chunk of stream)`).

  `Web.ReadableStream.values/2` gives the iterator. `next/1` reads the next
  chunk, and `return/2` stops the iteration.

      iex> stream = Web.ReadableStream.from(["a", "b"])
      iex> iterator = Web.ReadableStream.values(stream)
      iex> Web.await(Web.ReadableStreamAsyncIterator.next(iterator))
      %{value: "a", done: false}
      iex> Web.await(Web.ReadableStreamAsyncIterator.next(iterator))
      %{value: "b", done: false}
      iex> Web.await(Web.ReadableStreamAsyncIterator.next(iterator))
      %{value: nil, done: true}

  The iterator has the reader lock of the stream until the end of the
  stream, an error of the stream, or `return/2`. After the end and after
  `return/2`, `next/1` gives `done: true`. After an error, `next/1` rejects
  with the error again.

  An `Enum` function on the stream is the usual way to read all its chunks
  in Elixir: see `Web.ReadableStream`. The async iterator helpers of
  `Web.AsyncIterator`, for example `Web.AsyncIterator.map/2`, take the
  iterator as their source.
  """

  alias Web.Promise
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultReader

  defstruct [:reader, prevent_cancel: false]

  @typedoc "An asynchronous iterator of a stream. The fields are private."
  @type t :: %__MODULE__{reader: ReadableStreamDefaultReader.t(), prevent_cancel: boolean()}

  @doc false
  # The asynchronous iterator initialization steps: the iterator has the
  # reader, and the option `preventCancel`.
  def __new__(%ReadableStreamDefaultReader{} = reader, prevent_cancel) do
    %__MODULE__{reader: reader, prevent_cancel: prevent_cancel}
  end

  @doc """
  Reads the next chunk, as `next()`.

  The promise fulfils with `%{value: chunk, done: false}`, or with
  `%{value: nil, done: true}` at the end of the stream. It rejects with the
  error of an errored stream. At the end and at an error, the iterator
  releases the lock of the stream.
  """
  @spec next(t()) :: Promise.t()
  def next(%__MODULE__{reader: %ReadableStreamDefaultReader{} = reader}) do
    # The read is a request of the process that calls this function: the
    # stream gets the reads of one process in their sequence.
    Web.Stream.promise_call(
      reader.controller_pid,
      {:read, reader.owner_pid},
      :finished,
      &next_result(&1, reader)
    )
  end

  # The steps "get the next iteration result": the close steps and the
  # error steps release the reader. A reader that has no lock is the reader
  # of a finished iterator.
  defp next_result({:ok, chunk}, _reader), do: {:ok, %{value: chunk, done: false}}

  defp next_result(:done, reader) do
    :ok = ReadableStreamDefaultReader.release_lock(reader)
    {:ok, %{value: nil, done: true}}
  end

  defp next_result({:error, {:errored, reason}}, reader) do
    :ok = ReadableStreamDefaultReader.release_lock(reader)
    {:error, reason}
  end

  defp next_result(_finished, _reader), do: {:ok, %{value: nil, done: true}}

  @doc """
  Stops the iteration, as `return(value)`, and releases the lock of the
  stream.

  Without the option `:prevent_cancel` of `Web.ReadableStream.values/2`,
  the stream is cancelled with `value` as the reason. The promise fulfils
  with `%{value: value, done: true}` when the cancel is complete, and
  rejects with the reason of a cancel that fails.
  """
  @spec return(t(), term()) :: Promise.t()
  def return(%__MODULE__{reader: reader, prevent_cancel: prevent_cancel}, value \\ nil) do
    result =
      if prevent_cancel do
        Promise.resolve(:ok)
      else
        ReadableStream.__cancel__(reader.controller_pid, value)
      end

    :ok = ReadableStreamDefaultReader.release_lock(reader)
    Promise.then(result, fn _ok -> %{value: value, done: true} end)
  end
end
