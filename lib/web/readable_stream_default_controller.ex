defmodule Web.ReadableStreamDefaultController do
  @moduledoc """
  The interface passed to ReadableStream user-defined callbacks.
  Reflects the WHATWG ReadableStreamDefaultController API.
  """
  defstruct [:pid]

  alias Web.ReadableStream

  @doc """
  Enqueues a chunk into the stream's internal queue.

  ## Examples

      iex> source = %{
      ...>   start: fn controller ->
      ...>     Web.ReadableStreamDefaultController.enqueue(controller, "data")
      ...>     Web.ReadableStreamDefaultController.close(controller)
      ...>   end
      ...> }
      iex> stream = Web.ReadableStream.new(source)
      iex> Enum.to_list(stream)
      ["data"]
  """
  def enqueue(%__MODULE__{pid: pid}, chunk) do
    ReadableStream.enqueue(pid, chunk)
  end

  @doc """
  Closes the stream.

  Once closed, no more data can be enqueued.
  """
  def close(%__MODULE__{pid: pid}) do
    ReadableStream.close(pid)
  end

  @doc """
  Errors the stream with a reason.
  """
  def error(%__MODULE__{pid: pid}, reason) do
    ReadableStream.error(pid, reason)
  end

  @doc """
  Blocks the calling process until the stream's readable queue has capacity.

  Used by `TransformStream` implementations that produce multiple output chunks
  per input to implement signal-driven (non-polling) backpressure. Returns `:ok`
  immediately if capacity is already available, or parks the caller until a
  reader drains the queue below the High-Water Mark.

  If the stream is closed or errored the call also returns `:ok` so the
  transform task can complete cleanly.
  """
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

  @doc """
  Returns the desired size to fill the stream's internal queue.

  ## Examples

      iex> source = %{
      ...>   start: fn controller ->
      ...>     # Desired size is positive by default
      ...>     _size = Web.ReadableStreamDefaultController.desired_size(controller)
      ...>   end
      ...> }
      iex> _stream = Web.ReadableStream.new(source)
      iex> :ok
      :ok
  """
  def desired_size(%__MODULE__{pid: pid}) do
    ReadableStream.get_desired_size(pid)
  end
end
