defmodule Web.ReadableStreamDefaultController do
  @moduledoc """
  The controller that the functions `start` and `pull` of the underlying
  source of a `Web.ReadableStream` get, as `ReadableStreamDefaultController`
  of the Streams Standard.
  """
  defstruct [:pid]

  @typedoc "A controller. The field is private."
  @type t :: %__MODULE__{pid: pid()}

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

  Raises `Web.TypeError` when the stream is closed or errored, as the
  Streams Standard specifies.
  """
  def enqueue(%_{pid: pid}, chunk) do
    ReadableStream.controller_enqueue(pid, chunk)
  end

  @doc """
  Closes the stream.

  Once closed, no more data can be enqueued. Raises `Web.TypeError` when the
  stream is closed or errored, as the Streams Standard specifies.
  """
  def close(%_{pid: pid}) do
    ReadableStream.controller_close(pid)
  end

  @doc """
  Puts the stream in the errored state, as `error(e)`. The chunks in the
  queue are discarded. The default reason is `nil`, as `undefined` in the
  Streams Standard.
  """
  def error(%_{pid: pid}, reason \\ nil) do
    ReadableStream.error(pid, reason)
  end

  @doc false
  # Blocks the calling process until the queue of the stream has space: the
  # backpressure of `Web.DecompressionStream`, which gives many chunks for
  # one input chunk. Returns `:ok` at once when the queue has space, and
  # also when the stream is closed or errored, thus the transform can
  # complete.
  def wait_for_capacity(%_{pid: pid}) do
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
  Returns the desired size to fill the queue of the stream, as the
  attribute `desiredSize`. It is `nil` for an errored stream, and 0 for a
  closed stream.

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
  def desired_size(%_{pid: pid}) do
    ReadableStream.get_desired_size(pid)
  end
end
