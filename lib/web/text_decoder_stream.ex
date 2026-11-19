defmodule Web.TextDecoderStream do
  @moduledoc """
  A transform stream from UTF-8 bytes to text, as `TextDecoderStream` of the
  Encoding Standard.

  Each chunk that is written is a binary, a `Web.Uint8Array`, or a
  `Web.ArrayBuffer`. Each chunk that is read is a string. A code point that
  is divided between two chunks is joined.

  The options are the options of `Web.TextDecoder.new/2`: `:fatal` and
  `:ignore_bom`. The struct has the fields `:encoding`, `:fatal`, and
  `:ignore_bom`, as the attributes of the Standard.
  """

  alias Web.ReadableStreamDefaultController
  alias Web.TextDecoder
  alias Web.TransformStream

  defstruct [:readable, :writable, :encoding, :fatal, :ignore_bom]

  @type t :: %__MODULE__{
          readable: %Web.ReadableStream{},
          writable: %Web.WritableStream{},
          encoding: String.t(),
          fatal: boolean(),
          ignore_bom: boolean()
        }

  @spec new(String.t(), map() | keyword()) :: t()
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
          TextDecoder.dispose(decoder)

          if decoded != "" do
            ReadableStreamDefaultController.enqueue(controller, decoded)
          end
        end,
        cancel: fn _reason -> TextDecoder.dispose(decoder) end
      })

    %__MODULE__{
      readable: stream.readable,
      writable: stream.writable,
      encoding: decoder.encoding,
      fatal: decoder.fatal,
      ignore_bom: decoder.ignore_bom
    }
  end
end
