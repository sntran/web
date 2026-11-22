defmodule Web.ReadableByteStreamController do
  @moduledoc """
  The controller of a readable byte stream, as `ReadableByteStreamController`
  of the Streams Standard.

  The function `start` and `pull` of an underlying byte source get the
  controller: `Web.ReadableStream.new(%{type: "bytes", pull: fn controller -> ... end})`.

  ## BYOB requests

  A read of a `Web.ReadableStreamBYOBReader` gives its view to the stream.
  The source then gets the view as a `Web.ReadableStreamBYOBRequest` from
  `byob_request/1`. With the option `auto_allocate_chunk_size` of the
  source, a read of a default reader also makes a request, with a new
  buffer of that size:

      iex> stream =
      ...>   Web.ReadableStream.new(%{
      ...>     type: "bytes",
      ...>     auto_allocate_chunk_size: 4,
      ...>     pull: fn controller ->
      ...>       request = Web.ReadableByteStreamController.byob_request(controller)
      ...>       Web.ReadableStreamBYOBRequest.respond(request, "abc")
      ...>     end
      ...>   })
      iex> reader = Web.ReadableStream.get_reader(stream)
      iex> %{value: value, done: false} = Web.await(Web.ReadableStreamDefaultReader.read(reader))
      iex> to_string(value)
      "abc"
  """

  defstruct [:pid]

  alias Web.ReadableStream
  alias Web.TypeError
  alias Web.Uint8Array

  @type t :: %__MODULE__{pid: pid()}

  @doc """
  Puts a chunk of bytes in the queue of the stream, as `enqueue(chunk)`.

  The chunk is a `Web.Uint8Array` or a binary. The stream takes the buffer
  of a `Web.Uint8Array`, as the Streams Standard specifies: that buffer
  becomes detached.

  Raises `Web.TypeError` when the chunk has no bytes, when its buffer is
  detached, when the stream has a close request, and when the stream is
  closed or errored.
  """
  @spec enqueue(t(), binary() | Uint8Array.t()) :: :ok
  def enqueue(%__MODULE__{} = controller, chunk) when is_binary(chunk) do
    enqueue(controller, Uint8Array.from(chunk))
  end

  def enqueue(%__MODULE__{pid: pid}, %Uint8Array{} = chunk) do
    pid |> request({:enqueue_bytes, chunk}) |> result()
  end

  def enqueue(%__MODULE__{}, chunk) do
    raise TypeError, "The chunk of a byte stream must be a Uint8Array, got: #{inspect(chunk)}"
  end

  @doc """
  Closes the stream, as `close()`. A reader reads the bytes in the queue
  before the end.

  Raises `Web.TypeError` when the stream has a close request, and when the
  stream is closed or errored.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid}) do
    pid |> request({:close_bytes}) |> result()
  end

  @doc """
  Puts the stream in the errored state, as `error(e)`. The chunks in the
  queue are discarded.
  """
  @spec error(t(), term()) :: :ok
  def error(%__MODULE__{pid: pid}, reason) do
    ReadableStream.error(pid, reason)
  end

  @doc """
  Returns the current BYOB request, as the attribute `byobRequest`, or
  `nil` when no read waits for bytes.
  """
  @spec byob_request(t()) :: Web.ReadableStreamBYOBRequest.t() | nil
  def byob_request(%__MODULE__{pid: pid}) do
    request(pid, {:byob_request}, nil)
  end

  @doc """
  Returns the desired size, as the attribute `desiredSize`: the high water
  mark less the bytes in the queue. It is `nil` for an errored stream, and 0
  for a closed stream.
  """
  @spec desired_size(t()) :: number() | nil
  def desired_size(%__MODULE__{pid: pid}) do
    ReadableStream.get_desired_size(pid)
  end

  @doc """
  Waits until the stream wants more bytes, or until the stream ends.
  """
  @spec wait_for_capacity(t()) :: :ok
  def wait_for_capacity(%__MODULE__{pid: pid}) do
    ref = make_ref()
    Web.Stream.control_cast(pid, {:register_enqueue_waiter, self(), ref})

    receive do
      {:ready, ^ref} ->
        :ok

      {:stream_error, ^ref, _reason} ->
        :ok
    end
  end

  @stopped "The stream is not available. It ended, or its owner stopped."

  defp request(pid, message, gone \\ {:error, TypeError.exception(@stopped)}) do
    Web.Stream.call(pid, message, gone)
  end

  defp result(:ok), do: :ok
  defp result({:error, error}), do: raise(error)
end
