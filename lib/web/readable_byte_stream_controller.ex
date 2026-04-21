defmodule Web.ReadableByteStreamController do
  @moduledoc """
  Controller for byte-oriented readable streams.
  """

  defstruct [:pid]

  alias Web.ReadableStream

  @type t :: %__MODULE__{pid: pid()}

  @spec enqueue(t(), binary()) :: :ok
  def enqueue(%__MODULE__{pid: pid}, chunk) when is_binary(chunk) do
    ReadableStream.enqueue(pid, chunk)
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid}) do
    ReadableStream.close(pid)
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
