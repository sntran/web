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

  defstruct [:controller_pid, :owner_pid]

  alias Web.Promise
  alias Web.ReadableStream
  alias Web.TypeError
  alias Web.Uint8Array

  @type t :: %__MODULE__{controller_pid: pid()}

  @spec read(t(), Uint8Array.t()) :: Promise.t()
  def read(%__MODULE__{controller_pid: pid} = reader, %Uint8Array{} = view) do
    message = {:byob_read, owner(reader), view}

    Web.Stream.promise_call(pid, message, {:error, :not_locked_by_reader}, fn
      {:ok, %Uint8Array{} = chunk_view} ->
        {:ok, %{value: chunk_view, done: false}}

      {:done, %Uint8Array{} = empty_view} ->
        {:ok, %{value: empty_view, done: true}}

      {:error, :not_locked_by_reader} ->
        {:error, %TypeError{message: "This BYOB reader is no longer locked."}}

      {:error, :invalid_byob_view} ->
        {:error, %TypeError{message: "BYOB reads require a Uint8Array view."}}

      {:error, {:errored, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end)
  end

  def read(%__MODULE__{}, _view) do
    Promise.reject(%TypeError{message: "BYOB reads require a Uint8Array view."})
  end

  defp owner(%__MODULE__{owner_pid: owner}) when is_pid(owner), do: owner
  defp owner(%__MODULE__{}), do: self()

  @spec release_lock(t()) :: :ok
  def release_lock(%__MODULE__{controller_pid: pid} = reader) do
    ReadableStream.release_lock(pid, owner(reader))
  end

  @doc """
  Returns a promise that fulfils when the stream is closed, as the attribute
  `closed`.
  """
  @spec closed(t()) :: Promise.t()
  def closed(%__MODULE__{controller_pid: pid} = reader) do
    ReadableStream.reader_closed(pid, owner(reader))
  end

  @spec cancel(t(), term()) :: Promise.t()
  def cancel(%__MODULE__{controller_pid: pid}, reason \\ :cancelled) do
    ReadableStream.cancel(pid, reason)
  end
end
