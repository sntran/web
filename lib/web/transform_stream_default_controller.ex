defmodule Web.TransformStreamDefaultController do
  @moduledoc """
  The controller that the callbacks of a `Web.TransformStream` get, as
  `TransformStreamDefaultController` of the Streams Standard.

  ## Examples

      iex> upcase = Web.TransformStream.new(%{
      ...>   transform: fn chunk, controller ->
      ...>     Web.TransformStreamDefaultController.enqueue(controller, String.upcase(chunk))
      ...>   end
      ...> })
      iex> Web.ReadableStream.from(["a", "b"]) |> Web.ReadableStream.pipe_through(upcase) |> Enum.to_list()
      ["A", "B"]
  """

  defstruct [:pid]

  @type t :: %__MODULE__{pid: pid()}

  @doc """
  Puts a chunk in the queue of the readable side.
  """
  @spec enqueue(t(), term()) :: :ok
  def enqueue(%__MODULE__{pid: pid}, chunk) do
    Web.ReadableStream.enqueue(pid, chunk)
  end

  @doc """
  Puts the two sides of the stream in the errored state.
  """
  @spec error(t(), term()) :: :ok
  def error(%__MODULE__{pid: pid}, reason) do
    Web.ReadableStream.error(pid, reason)
  end

  @doc """
  Closes the readable side, and stops the writable side.

  A reader gets the chunks that are in the queue, and then the end of the
  stream. A write that comes after this call rejects with `Web.TypeError`.
  """
  @spec terminate(t()) :: :ok
  def terminate(%__MODULE__{pid: pid}) do
    Web.Stream.control_cast(pid, :terminate_transform)
  end

  @doc """
  Returns the number of chunks that the readable side can accept before it
  gives backpressure. The value is `nil` for an errored stream, and 0 for a
  closed stream.
  """
  @spec desired_size(t()) :: number() | nil
  def desired_size(%__MODULE__{pid: pid}) do
    Web.ReadableStream.get_desired_size(pid)
  end

  @doc """
  Waits until the readable side wants a chunk.

  A transform that gives many chunks for one input chunk can call this
  function between the chunks. Thus it does not fill the queue of the
  readable side.
  """
  @spec wait_for_capacity(t()) :: :ok
  def wait_for_capacity(%__MODULE__{pid: pid}) do
    Web.ReadableStreamDefaultController.wait_for_capacity(%Web.ReadableStreamDefaultController{
      pid: pid
    })
  end
end
