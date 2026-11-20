defmodule Web.TextEncoder do
  @moduledoc """
  WHATWG-style UTF-8 text encoder.

  `TextEncoder` only supports UTF-8.

  ## Examples

      iex> encoder = Web.TextEncoder.new()
      iex> bytes = Web.TextEncoder.encode(encoder, "hello")
      iex> Web.Uint8Array.to_binary(bytes)
      "hello"
  """

  alias Web.ArrayBuffer
  alias Web.TypeError
  alias Web.Uint8Array

  defstruct encoding: "utf-8"

  @type t :: %__MODULE__{encoding: String.t()}

  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @spec encode(t(), String.t()) :: Uint8Array.t()
  def encode(%__MODULE__{encoding: "utf-8"}, input) when is_binary(input) do
    # A string of the BEAM can contain bytes that are not valid UTF-8. They
    # become U+FFFD, as the Encoding Standard does for a lone surrogate.
    input
    |> String.replace_invalid()
    |> ArrayBuffer.new()
    |> Uint8Array.new()
  end

  def encode(%__MODULE__{}, _input) do
    raise TypeError, "TextEncoder.encode input must be a string"
  end

  @doc """
  Encodes `source` as UTF-8 into the start of `destination`, as the method
  `encodeInto()` of the Encoding Standard.

  The encoder writes each character that fits completely, in sequence. It
  stops at the first character that does not fit. The result has `read`,
  the number of UTF-16 code units of `source` that the encoder encoded, and
  `written`, the number of bytes that it wrote. A character above U+FFFF
  counts as two code units, as in the Standard.

  A `Web.Uint8Array` and its `Web.ArrayBuffer` are immutable structs, thus
  this function cannot write into `destination`. It returns
  `{%{read: read, written: written}, destination}`: the result of the
  Standard, and the changed destination. The changed destination has the
  same byte offset and byte length, and the encoded bytes at its start. Its
  other bytes, and the other bytes of its buffer, do not change. Use the
  changed destination in place of the given one.

  A detached destination has no space: the result is `read: 0` and
  `written: 0`.

  ## Examples

      iex> encoder = Web.TextEncoder.new()
      iex> destination = Web.Uint8Array.new(Web.ArrayBuffer.new("......"))
      iex> {result, destination} = Web.TextEncoder.encode_into(encoder, "aé😀", destination)
      iex> result
      %{read: 2, written: 3}
      iex> Web.Uint8Array.to_binary(destination)
      "aé..."
  """
  @spec encode_into(t(), String.t(), Uint8Array.t()) ::
          {%{read: non_neg_integer(), written: non_neg_integer()}, Uint8Array.t()}
  def encode_into(%__MODULE__{encoding: "utf-8"}, source, %Uint8Array{} = destination)
      when is_binary(source) do
    # Bytes that are not valid UTF-8 become U+FFFD, as in `encode/2`.
    source = String.replace_invalid(source)
    %Uint8Array{buffer: buffer, byte_offset: offset, byte_length: length} = destination
    space = if ArrayBuffer.detached?(buffer), do: 0, else: length
    {read, written} = fit(source, space, 0, 0)

    if written == 0 do
      {%{read: read, written: 0}, destination}
    else
      # A copy: the destination does not keep a reference to all the source.
      chunk = :binary.copy(binary_part(source, 0, written))

      {%{read: read, written: written},
       %{destination | buffer: ArrayBuffer.replace(buffer, offset, chunk)}}
    end
  end

  def encode_into(%__MODULE__{}, source, _destination) when is_binary(source) do
    raise TypeError, "TextEncoder.encodeInto destination must be a Uint8Array"
  end

  def encode_into(%__MODULE__{}, _source, _destination) do
    raise TypeError, "TextEncoder.encodeInto source must be a string"
  end

  # The number of UTF-16 code units and of UTF-8 bytes of the longest start
  # of `source` that fits in `space` bytes.
  defp fit(<<code_point::utf8, rest::binary>> = source, space, read, written) do
    size = byte_size(source) - byte_size(rest)

    if written + size <= space do
      units = if code_point > 0xFFFF, do: 2, else: 1
      fit(rest, space, read + units, written + size)
    else
      {read, written}
    end
  end

  defp fit(<<>>, _space, read, written), do: {read, written}
end
