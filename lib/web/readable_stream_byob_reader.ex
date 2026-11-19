defmodule Web.ReadableStreamBYOBReader do
  @moduledoc """
  A BYOB ("bring your own buffer") reader for a readable byte stream.

  `read/2` moves the buffer of the view into the stream, as the Streams
  Standard specifies. The buffer that you gave becomes detached. The result
  has a new view, in a new buffer that has the same length:

      {:ok, view} = ...
      %{value: value, done: false} = await(ReadableStreamBYOBReader.read(reader, view))
      bytes = Web.Uint8Array.to_binary(value)

      # Use the buffer of the result for the subsequent read.
      view = Web.Uint8Array.new(value.buffer)

  A binary of the BEAM is immutable. Thus a BYOB read does not decrease the
  number of copies, as it does in a browser. Its function here is to limit
  the number of bytes of each read to the length of the view.
  """

  defstruct [:controller_pid]

  alias Web.Promise
  alias Web.ReadableStream
  alias Web.TypeError
  alias Web.Uint8Array

  @type t :: %__MODULE__{controller_pid: pid()}

  @spec read(t(), Uint8Array.t()) :: Promise.t()
  def read(%__MODULE__{controller_pid: pid}, %Uint8Array{} = view) do
    case ReadableStream.byob_read(pid, view) do
      {:ok, %Uint8Array{} = chunk_view} ->
        Promise.resolve(%{value: chunk_view, done: false})

      {:done, %Uint8Array{} = empty_view} ->
        Promise.resolve(%{value: empty_view, done: true})

      {:error, :not_locked_by_reader} ->
        Promise.reject(%TypeError{message: "This BYOB reader is no longer locked."})

      {:error, :invalid_byob_view} ->
        Promise.reject(%TypeError{message: "BYOB reads require a Uint8Array view."})

      {:error, {:errored, reason}} ->
        Promise.reject(reason)

      {:error, reason} ->
        Promise.reject(reason)
    end
  end

  def read(%__MODULE__{}, _view) do
    Promise.reject(%TypeError{message: "BYOB reads require a Uint8Array view."})
  end

  @spec release_lock(t()) :: :ok
  def release_lock(%__MODULE__{controller_pid: pid}) do
    case ReadableStream.release_lock(pid) do
      :ok ->
        :ok

      {:error, :not_locked_by_reader} ->
        raise TypeError, "This BYOB reader is no longer locked."

      {:error, reason} ->
        raise TypeError, "Unknown error: #{inspect(reason)}"
    end
  end

  @spec cancel(t(), term()) :: Promise.t()
  def cancel(%__MODULE__{controller_pid: pid}, reason \\ :cancelled) do
    ReadableStream.cancel(pid, reason)
  end
end
