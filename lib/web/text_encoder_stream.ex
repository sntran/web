defmodule Web.TextEncoderStream do
  @moduledoc """
  WHATWG-style `TextEncoderStream`.
  """

  alias Web.ReadableStreamDefaultController
  alias Web.TextEncoder
  alias Web.TransformStream

  defstruct [:readable, :writable]

  @type t :: %__MODULE__{
          readable: Web.ReadableStream.t(),
          writable: Web.WritableStream.t()
        }

  @spec new() :: t()
  def new do
    encoder = TextEncoder.new()

    stream =
      TransformStream.new(%{
        transform: fn chunk, controller ->
          ReadableStreamDefaultController.enqueue(controller, TextEncoder.encode(encoder, chunk))
        end
      })

    %__MODULE__{readable: stream.readable, writable: stream.writable}
  end
end
