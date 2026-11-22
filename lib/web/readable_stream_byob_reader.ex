defmodule Web.ReadableStreamBYOBReader do
  @moduledoc """
  A BYOB ("bring your own buffer") reader for a readable byte stream, as
  `ReadableStreamBYOBReader` of the Streams Standard.

  `read/3` moves the buffer of the view into the stream, as the Streams
  Standard specifies. The buffer that you gave becomes detached. The result
  has a new view, in a new buffer that has the same length:

      iex> stream =
      ...>   Web.ReadableStream.new(%{
      ...>     type: "bytes",
      ...>     start: fn controller ->
      ...>       Web.ReadableByteStreamController.enqueue(controller, "hello")
      ...>     end
      ...>   })
      iex> reader = Web.ReadableStream.get_reader(stream, mode: "byob")
      iex> view = Web.Uint8Array.new(Web.ArrayBuffer.new(4))
      iex> %{value: value, done: false} = Web.await(Web.ReadableStreamBYOBReader.read(reader, view))
      iex> {to_string(value), Web.ArrayBuffer.detached?(view.buffer)}
      {"hell", true}
      iex> # Use the buffer of the result for the subsequent read.
      iex> view = Web.Uint8Array.new(value.buffer)
      iex> %{value: value} = Web.await(Web.ReadableStreamBYOBReader.read(reader, view))
      iex> to_string(value)
      "o"

  A binary of the BEAM is immutable. Thus a BYOB read does not decrease the
  number of copies, as it does in a browser. Its function here is to limit
  the number of bytes of each read to the length of the view, and to wait
  for a minimum number of bytes: see the option `:min`.
  """

  # The field `lock` is the reference of the lock of this reader: a reader
  # that released its lock has no effect on the stream, also when the same
  # process has a new reader.
  defstruct [:controller_pid, :owner_pid, :lock]

  alias Web.ArrayBuffer
  alias Web.Promise
  alias Web.RangeError
  alias Web.TypeError
  alias Web.Uint8Array

  @typedoc "A BYOB reader. The fields are private."
  @type t :: %__MODULE__{controller_pid: pid(), owner_pid: pid(), lock: reference()}

  @doc """
  Reads bytes into the view, as `read(view, options)`.

  The promise fulfils with `%{value: view, done: false}` when the stream
  has bytes, and with `%{value: view, done: true}` when the stream is
  closed. The view of the result is in a new buffer. After a cancel, the
  value is `nil`. The promise rejects with the error of an errored stream.

  ## Options

    * `:min` - the minimum number of bytes of the result. The default is 1.
      A closed stream can give fewer bytes.

  The promise rejects with `Web.TypeError` when the view has no bytes, when
  its buffer is detached, when `:min` is 0, and when the reader is
  released. It rejects with `Web.RangeError` when `:min` is larger than the
  view.
  """
  @spec read(t(), Uint8Array.t(), keyword()) :: Promise.t()
  def read(reader, view, opts \\ [])

  def read(%__MODULE__{controller_pid: pid} = reader, %Uint8Array{} = view, opts)
      when is_list(opts) do
    min = Keyword.get(opts, :min, 1)

    case view_refusal(view, min) do
      nil ->
        message = as_reader(reader, {:byob_read, reader.owner_pid, view, min})
        Web.Stream.promise_call(pid, message, {:error, :not_locked_by_reader}, &read_result/1)

      error ->
        Promise.reject(error)
    end
  end

  def read(%__MODULE__{}, _view, _opts) do
    Promise.reject(%TypeError{message: "BYOB reads require a Uint8Array view."})
  end

  # The checks of `read(view, options)` of the Streams Standard, before the
  # check of the lock. A detached buffer has the byte length 0.
  defp view_refusal(view, min) do
    cond do
      view.byte_length == 0 ->
        TypeError.exception("A BYOB read needs a view with a byte length above zero.")

      ArrayBuffer.byte_length(view.buffer) == 0 ->
        TypeError.exception("A BYOB read needs a view of a buffer that is not detached.")

      not is_integer(min) or min < 0 ->
        TypeError.exception("The option min must be a number of bytes, got: #{inspect(min)}")

      min == 0 ->
        TypeError.exception("The option min must be above 0.")

      min > view.byte_length ->
        RangeError.exception("The option min is larger than the view.")

      true ->
        nil
    end
  end

  defp read_result({:ok, %Uint8Array{} = view}), do: {:ok, %{value: view, done: false}}
  defp read_result({:done, view}), do: {:ok, %{value: view, done: true}}
  defp read_result(:done), do: {:ok, %{value: nil, done: true}}

  defp read_result({:error, :not_locked_by_reader}),
    do: {:error, %TypeError{message: "This BYOB reader is no longer locked."}}

  defp read_result({:error, {:errored, reason}}), do: {:error, reason}
  defp read_result({:error, reason}), do: {:error, reason}

  # A request of this reader, with the reference of its lock: see
  # `Web.ReadableStreamDefaultReader`.
  defp as_reader(%__MODULE__{lock: lock}, message), do: {:as_reader, lock, message}

  @doc """
  Releases the lock of the reader on the stream, as
  ReadableStreamReaderGenericRelease specifies. The reads that wait reject
  with `Web.TypeError`.

  A second call, or a call after a new reader took the lock, has no effect.
  """
  @spec release_lock(t()) :: :ok
  def release_lock(%__MODULE__{controller_pid: pid} = reader) do
    Web.Stream.call(pid, as_reader(reader, {:release_lock, :reader, reader.owner_pid}), :ok)
  end

  @doc """
  Returns a promise that fulfils when the stream is closed, as the attribute
  `closed`. It rejects with the error of the stream when the stream is
  errored, and with `Web.TypeError` when the lock of the reader is released.

  Each call gives the same promise, as in the Streams Standard. A release of
  the lock of a stream that is closed or errored replaces the promise with
  a promise that is rejected with `Web.TypeError`.
  """
  @spec closed(t()) :: Promise.t()
  def closed(%__MODULE__{controller_pid: pid, lock: lock}) do
    case Web.Stream.call(pid, {:reader_closed, lock}, :gone) do
      %Promise{} = promise -> promise
      # The stream stopped: it was closed or errored.
      :gone -> Promise.resolve(:ok)
    end
  end

  @doc """
  Cancels the stream, as `cancel(reason)`. The reads that wait fulfil with
  `%{value: nil, done: true}`. The default reason is `nil`, as `undefined`
  in the Streams Standard.

  The reader keeps its lock, as in the Streams Standard. A reader that
  released its lock gives a promise that rejects with `Web.TypeError`.
  """
  @spec cancel(t(), term()) :: Promise.t()
  def cancel(%__MODULE__{controller_pid: pid} = reader, reason \\ nil) do
    message = as_reader(reader, {:terminate, :cancel, reason})

    Web.Stream.promise_call(pid, message, :ok, fn
      :ok -> {:ok, :ok}
      {:error, :not_locked_by_reader} -> read_result({:error, :not_locked_by_reader})
      {:error, thrown} -> {:error, thrown}
    end)
  end
end
