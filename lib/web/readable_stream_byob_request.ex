defmodule Web.ReadableStreamBYOBRequest do
  @moduledoc """
  A request of a readable byte stream for bytes, as
  `ReadableStreamBYOBRequest` of the Streams Standard.

  `Web.ReadableByteStreamController.byob_request/1` gives the request. Its
  view is a part of the buffer of the read that waits. The buffer belongs
  to the stream: the struct of a buffer is a value, thus the source gives
  its bytes with the response.

    * `respond/2` with a binary puts the bytes at the start of the view, and
      responds with their number. This is the form of an Elixir source.
    * `respond/2` with an integer responds with that number of bytes of the
      view, as `respond(bytesWritten)`.
    * `respond_with_new_view/2` gives a different view of a buffer with the
      same length, at the same position, as `respondWithNewView(view)`.

  After a response, the request is not valid: `view/1` returns `nil`, and
  the buffer of the view is detached.

      iex> stream =
      ...>   Web.ReadableStream.new(%{
      ...>     type: "bytes",
      ...>     pull: fn controller ->
      ...>       request = Web.ReadableByteStreamController.byob_request(controller)
      ...>       view = Web.ReadableStreamBYOBRequest.view(request)
      ...>       Web.ReadableStreamBYOBRequest.respond(request, String.duplicate("x", view.byte_length))
      ...>     end
      ...>   })
      iex> reader = Web.ReadableStream.get_reader(stream, mode: "byob")
      iex> view = Web.Uint8Array.new(Web.ArrayBuffer.new(3))
      iex> %{value: value} = Web.await(Web.ReadableStreamBYOBReader.read(reader, view))
      iex> Web.Uint8Array.to_binary(value)
      "xxx"
  """

  alias Web.ArrayBuffer
  alias Web.TypeError
  alias Web.Uint8Array

  defstruct [:controller_pid, :id, :view]

  @typedoc "A BYOB request. The fields are private."
  @type t :: %__MODULE__{controller_pid: pid(), id: reference(), view: Uint8Array.t()}

  @doc """
  Returns the view to write into, as the attribute `view`, or `nil` after
  a response.
  """
  @spec view(t()) :: Uint8Array.t() | nil
  def view(%__MODULE__{controller_pid: pid, id: id, view: view}) do
    if Web.Stream.call(pid, {:byob_request_view, id}, false), do: view
  end

  @doc """
  Gives the bytes of the request to the stream, as `respond(bytesWritten)`.

  With an integer, the stream takes that number of bytes from the start of
  the view. With a binary, the stream takes these bytes.

  Raises `Web.TypeError` when the request is not valid, when the buffer of
  the view is detached, when the response is 0 for a readable stream, and
  when it is not 0 for a closed stream. Raises `Web.RangeError` when the
  response is larger than the view.
  """
  @spec respond(t(), non_neg_integer() | binary()) :: :ok
  def respond(%__MODULE__{} = request, bytes_written)
      when is_integer(bytes_written) and bytes_written >= 0 do
    send_request(request, {:byob_respond, request.id, bytes_written, request.view})
  end

  def respond(%__MODULE__{view: view} = request, bytes) when is_binary(bytes) do
    # The bytes go into the buffer of the view, at the start of the view. A
    # response that is larger than the view gets the `RangeError` of the
    # stream.
    view =
      if byte_size(bytes) <= view.byte_length,
        do: %{view | buffer: ArrayBuffer.replace(view.buffer, view.byte_offset, bytes)},
        else: view

    respond(%{request | view: view}, byte_size(bytes))
  end

  def respond(%__MODULE__{}, bytes_written) do
    raise TypeError, "The response must be a number of bytes, got: #{inspect(bytes_written)}"
  end

  @doc """
  Gives a new view to the stream, as `respondWithNewView(view)`. The stream
  takes the buffer of the view: that buffer becomes detached.

  The view must start at the start of the view of the request, its buffer
  must have the length of the buffer of the request, and it must not be
  larger than the view of the request. For a closed stream, the view has
  no bytes. A binary is the same as `respond/2` with that binary.

  Raises `Web.TypeError` or `Web.RangeError` when the view does not agree
  with the request.
  """
  @spec respond_with_new_view(t(), Uint8Array.t() | binary()) :: :ok
  def respond_with_new_view(%__MODULE__{} = request, %Uint8Array{} = view) do
    send_request(request, {:byob_respond_with_new_view, request.id, view})
  end

  def respond_with_new_view(%__MODULE__{} = request, bytes) when is_binary(bytes) do
    respond(request, bytes)
  end

  def respond_with_new_view(%__MODULE__{}, view) do
    raise TypeError, "The new view must be a Uint8Array, got: #{inspect(view)}"
  end

  @stopped "The BYOB request is no longer valid."

  defp send_request(%__MODULE__{controller_pid: pid}, message) do
    case Web.Stream.call(pid, message, {:error, TypeError.exception(@stopped)}) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end
end
