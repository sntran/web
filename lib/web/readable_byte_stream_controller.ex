defmodule Web.ReadableByteStreamController do
  @moduledoc """
  Controller for byte-oriented readable streams.
  """

  defstruct [:pid]

  alias Web.ReadableStream

  @type t :: %__MODULE__{pid: pid()}

  @doc """
  Puts a chunk of bytes in the queue of the stream.

  The chunk is a binary or a `Web.Uint8Array`. The stream takes the buffer
  of a `Web.Uint8Array`, as the Streams Standard specifies: that buffer
  becomes detached.

  Raises `Web.TypeError` when the stream is closed or errored.
  """
  @spec enqueue(t(), binary() | Web.Uint8Array.t()) :: :ok
  def enqueue(%__MODULE__{pid: pid}, chunk) when is_binary(chunk) do
    ReadableStream.controller_enqueue(pid, chunk)
  end

  def enqueue(%__MODULE__{pid: pid}, %Web.Uint8Array{} = chunk) do
    bytes = Web.Uint8Array.to_binary(chunk)
    Web.ArrayBuffer.detach(chunk.buffer)
    ReadableStream.controller_enqueue(pid, bytes)
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid}) do
    ReadableStream.controller_close(pid)
  end

  @spec error(t(), term()) :: :ok
  def error(%__MODULE__{pid: pid}, reason) do
    ReadableStream.error(pid, reason)
  end

  @spec byob_request(t()) :: Web.ReadableStreamBYOBRequest.t() | nil
  def byob_request(%__MODULE__{pid: pid}) do
    Web.Stream.control_call(pid, :get_byob_request)
  end

  @spec desired_size(t()) :: number() | nil
  def desired_size(%__MODULE__{pid: pid}) do
    ReadableStream.get_desired_size(pid)
  end

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
end
