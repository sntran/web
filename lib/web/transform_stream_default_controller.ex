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

  # The process of the readable side, and the process of the writable side.
  defstruct [:pid, :writable_pid]

  @typedoc "A controller. The fields are private."
  @type t :: %__MODULE__{pid: pid(), writable_pid: pid()}

  @doc """
  Puts a chunk in the queue of the readable side, as `enqueue(chunk)` of
  the Streams Standard. The chunk is optional: the default is `nil`, as
  `undefined` in the Standard.

  Raises `Web.TypeError` when the readable side is closed or errored, as the
  Streams Standard specifies. For example, after a reader cancelled the
  stream, or after `terminate/1`.
  """
  @spec enqueue(t(), term()) :: :ok
  def enqueue(%__MODULE__{pid: pid}, chunk \\ nil) do
    Web.ReadableStream.controller_enqueue(pid, chunk, :transform)
  end

  @doc """
  Puts the two sides of the stream in the errored state, as `error(reason)`
  and TransformStreamDefaultControllerError specify. The default reason is
  `nil`, as `undefined` in the Streams Standard.

  The readable side gets the error only when it is readable. The writable
  side gets it only when it is writable. A second call has no effect.
  """
  @spec error(t(), term()) :: :ok
  def error(%__MODULE__{pid: pid, writable_pid: writable}, reason \\ nil) do
    # The writable side gets the error first: a transform that calls this
    # function sends its result to the writable side after this message.
    error_writable(writable, reason)
    Web.Stream.control_cast(pid, {:transform_error, reason})
  end

  @doc """
  Closes the readable side, and stops the writable side.

  A reader gets the chunks that are in the queue, and then the end of the
  stream. A write that comes after this call rejects with `Web.TypeError`.
  """
  @spec terminate(t()) :: :ok
  def terminate(%__MODULE__{pid: pid, writable_pid: writable}) do
    error_writable(writable, Web.TypeError.exception("The transform stream was terminated."))
    Web.Stream.control_cast(pid, :transform_terminate)
  end

  # TransformStreamErrorWritableAndUnblockWrite.
  defp error_writable(writable, reason),
    do: Web.Stream.control_cast(writable, {:transform_error_unblock, reason})

  @doc """
  Returns the desired size of the readable side, as the attribute
  `desiredSize`: the number of chunks that the readable side can accept
  before it gives backpressure. The value is `nil` for an errored stream,
  and 0 for a closed stream.
  """
  @spec desired_size(t()) :: number() | nil
  def desired_size(%__MODULE__{pid: pid}) do
    Web.ReadableStream.get_desired_size(pid)
  end
end
