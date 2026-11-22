defmodule Web.TextDecoderStream do
  @moduledoc """
  A transform stream from bytes to text, as `TextDecoderStream` of the
  Encoding Standard. The default encoding is UTF-8. `Web.TextDecoder` lists
  the encodings that the label can name.

  Each chunk that is written is a binary, a `Web.Uint8Array`, or a
  `Web.ArrayBuffer`. Each chunk that is read is a string. A character that
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

  @doc """
  Makes a decoder stream, as `new TextDecoderStream(label, options)`.

  The options are the members of the dictionary `TextDecoderOptions`:
  `:fatal` and `:ignore_bom`. Raises `Web.RangeError` for a label that
  names no encoding.
  """
  @spec new(String.t(), map() | keyword()) :: t()
  def new(label \\ "utf-8", options \\ %{}) do
    decoder = TextDecoder.new(label, options)

    stream =
      TransformStream.new(%{
        transform: fn chunk, controller ->
          decoded = TextDecoder.decode(decoder, buffer_source!(chunk), %{stream: true})

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

  # The Standard converts each chunk to a buffer source. `nil` is no
  # buffer: `Web.TextDecoder.decode/3` takes it as no input, but a chunk of
  # a stream must have bytes.
  defp buffer_source!(nil) do
    raise Web.TypeError, "TextDecoderStream needs a chunk of bytes, got: nil"
  end

  defp buffer_source!(chunk), do: chunk
end
