defmodule Web.TextDecoderStream do
  @moduledoc """
  WHATWG-style `TextDecoderStream`.
  """

  alias Web.ReadableStreamDefaultController
  alias Web.TextDecoder
  alias Web.TransformStream

  defstruct [:readable, :writable]

  @type t :: %__MODULE__{
          readable: Web.ReadableStream.t(),
          writable: Web.WritableStream.t()
        }

  @spec new(String.t(), map()) :: t()
  def new(label \\ "utf-8", options \\ %{}) do
    decoder = TextDecoder.new(label, options)

    stream =
      TransformStream.new(%{
        transform: fn chunk, controller ->
          decoded = TextDecoder.decode(decoder, chunk, %{stream: true})

          if decoded != "" do
            ReadableStreamDefaultController.enqueue(controller, decoded)
          end
        end,
        flush: fn controller ->
          decoded = TextDecoder.decode(decoder, <<>>, %{stream: false})

          if decoded != "" do
            ReadableStreamDefaultController.enqueue(controller, decoded)
          end
        end
      })

    %__MODULE__{readable: stream.readable, writable: stream.writable}
  end
end
