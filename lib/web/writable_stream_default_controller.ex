defmodule Web.WritableStreamDefaultController do
  @moduledoc """
  The controller that the functions `start`, `write`, and `close` of the
  underlying sink of a `Web.WritableStream` get, as
  `WritableStreamDefaultController` of the Streams Standard.
  """
  defstruct [:pid]

  @type t :: %__MODULE__{pid: pid()}

  alias Web.WritableStream

  @doc """
  Puts the stream in the errored state, as `error(e)`. The default reason
  is `nil`, as `undefined` in the Streams Standard.
  """
  def error(%__MODULE__{pid: pid}, reason \\ nil) do
    WritableStream.error(pid, reason)
  end

  @doc """
  Returns the abort signal of the stream, as the attribute `signal`.

  The signal aborts, with the reason of the abort, when the stream is
  aborted. A sink can use it to stop a long write.

  ## Examples

      iex> test = self()
      iex> stream = Web.WritableStream.new(%{
      ...>   start: fn controller ->
      ...>     send(test, {:signal, Web.WritableStreamDefaultController.signal(controller)})
      ...>   end
      ...> })
      iex> signal = receive do {:signal, signal} -> signal end
      iex> Web.AbortSignal.aborted?(signal)
      false
      iex> Web.await(Web.WritableStream.abort(stream, :stop))
      :ok
      iex> {Web.AbortSignal.aborted?(signal), Web.AbortSignal.reason(signal)}
      {true, :stop}
  """
  @spec signal(t()) :: Web.AbortSignal.t()
  def signal(%__MODULE__{pid: pid}) do
    Web.Stream.call(pid, :abort_signal, nil) ||
      Web.AbortSignal.abort(
        Web.TypeError.exception("The stream is not available. It ended, or its owner stopped.")
      )
  end
end
