defmodule Web.TextEncoderStream do
  @moduledoc """
  A transform stream from text to UTF-8 bytes, as `TextEncoderStream` of the
  Encoding Standard.

  Each chunk that is read is a `Web.Uint8Array`. An empty string gives no
  chunk.

  The Standard converts each chunk that is written to a string. A chunk
  that is not a string becomes a string through the protocol `String.Chars`
  of Elixir, as with interpolation: for example `3.14` gives `"3.14"`, and
  `nil` gives `""`. A chunk with no `String.Chars` implementation, such as
  a map, puts the two sides of the stream in the errored state with
  `Web.TypeError`.

  A string of the BEAM is a binary, and can contain bytes that are not valid
  UTF-8. Such bytes become U+FFFD. A code point that is divided between two
  chunks is joined, as the Standard does for a surrogate pair.

  ## Examples

      iex> stream = Web.ReadableStream.from(["Hi ", "é"]) |> Web.ReadableStream.pipe_through(Web.TextEncoderStream.new())
      iex> Enum.map(stream, &Web.Uint8Array.to_binary/1)
      ["Hi ", "é"]
  """

  alias Web.TextDecoder
  alias Web.TransformStream
  alias Web.TransformStreamDefaultController, as: Controller
  alias Web.Uint8Array

  defstruct [:readable, :writable, encoding: "utf-8"]

  @type t :: %__MODULE__{
          readable: %Web.ReadableStream{},
          writable: %Web.WritableStream{},
          encoding: String.t()
        }

  @doc """
  Makes an encoder stream, as `new TextEncoderStream()`.
  """
  @spec new() :: t()
  def new do
    # A UTF-8 decoder does the work: it joins a code point that is divided
    # between two chunks, and replaces bytes that are not valid. It keeps a
    # byte order mark, because an encoder does not remove one.
    decoder = TextDecoder.new("utf-8", %{ignore_bom: true})

    stream =
      TransformStream.new(%{
        transform: fn chunk, controller ->
          text = to_text!(chunk)
          enqueue_text(controller, TextDecoder.decode(decoder, text, %{stream: true}))
        end,
        flush: fn controller ->
          text = TextDecoder.decode(decoder, <<>>, %{stream: false})
          TextDecoder.dispose(decoder)
          enqueue_text(controller, text)
        end,
        cancel: fn _reason -> TextDecoder.dispose(decoder) end
      })

    %__MODULE__{readable: stream.readable, writable: stream.writable}
  end

  # The conversion of a chunk to a string.
  defp to_text!(chunk) when is_binary(chunk), do: chunk

  defp to_text!(chunk) do
    String.Chars.to_string(chunk)
  rescue
    _error in [Protocol.UndefinedError, ArgumentError] ->
      reraise Web.TypeError,
              [message: "TextEncoderStream cannot convert #{inspect(chunk)} to a string."],
              __STACKTRACE__
  end

  defp enqueue_text(_controller, ""), do: :ok

  defp enqueue_text(controller, text) do
    Controller.enqueue(controller, Uint8Array.from(text))
  end
end
