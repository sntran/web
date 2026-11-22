defmodule Web.Uint8Array do
  @moduledoc """
  An immutable `Uint8Array` view of a part of a `Web.ArrayBuffer`.

  A view does not copy the bytes of its buffer. `to_string/1` gives the
  bytes of the view as a binary. It raises `Web.TypeError` when the buffer
  is detached.

  ## Chunks of bytes

  Each stream of bytes of this library gives its chunks as `Web.Uint8Array`
  values, as the Web standards specify: the body of a request or a response,
  `Web.Blob.stream/1`, the readable side of a socket, of a compression
  stream, and of `Web.TextEncoderStream`, and a default read of a byte
  stream. Use `to_string/1` to get the binary of a chunk:

      iex> response = Web.Response.new("hello")
      iex> Enum.map(response.body, &to_string/1)
      ["hello"]

  To get all the bytes of a body, use the functions of the body:
  `Web.Response.text/1`, `Web.Response.bytes/1`, or
  `Web.Response.array_buffer/1`.

  Each consumer of bytes of this library accepts a binary, a
  `Web.Uint8Array`, or a `Web.ArrayBuffer`.

  ## Examples

      iex> buffer = Web.ArrayBuffer.new("hello")
      iex> uint8 = Web.Uint8Array.new(buffer, 1, 3)
      iex> uint8.byte_length
      3
      iex> to_string(uint8)
      "ell"
  """

  alias Web.ArrayBuffer

  @enforce_keys [:id, :buffer, :byte_offset, :byte_length]
  defstruct [:id, :buffer, :byte_offset, :byte_length]

  @type t :: %__MODULE__{
          id: reference() | nil,
          buffer: ArrayBuffer.t(),
          byte_offset: non_neg_integer(),
          byte_length: non_neg_integer()
        }

  @doc """
  Creates a new Uint8Array view over the given ArrayBuffer.
  """
  @spec new(ArrayBuffer.t(), non_neg_integer(), non_neg_integer() | nil) :: t()
  def new(%ArrayBuffer{} = buffer, offset \\ 0, length \\ nil) do
    ensure_attached!(buffer)
    max_length = ArrayBuffer.byte_length(buffer)
    validate_offset!(offset, max_length)
    byte_length = resolve_length(offset, length, max_length)

    build_view(buffer, offset, byte_length)
  end

  @doc """
  The constant `Uint8Array.BYTES_PER_ELEMENT` of ECMAScript (1): the size
  of one element in bytes.

  ## Examples

      iex> Web.Uint8Array.bytes_per_element()
      1
  """
  @spec bytes_per_element() :: 1
  def bytes_per_element, do: 1

  @doc """
  Makes a `Uint8Array` with a new buffer that has the given bytes.

  The bytes are a binary, iodata, a `Web.ArrayBuffer`, or a
  `Web.Uint8Array`.

  ## Examples

      iex> bytes = Web.Uint8Array.from("hello")
      iex> {bytes.byte_length, to_string(bytes)}
      {5, "hello"}

      iex> Web.Uint8Array.from([104, "i"]) |> to_string()
      "hi"
  """
  @spec from(iodata() | ArrayBuffer.t() | t()) :: t()
  def from(bytes) when is_binary(bytes), do: bytes |> ArrayBuffer.new() |> new()
  def from(bytes) when is_list(bytes), do: bytes |> IO.iodata_to_binary() |> from()
  def from(%ArrayBuffer{} = buffer), do: buffer |> ArrayBuffer.data() |> from()
  def from(%__MODULE__{} = view), do: view |> to_binary() |> from()

  defp ensure_attached!(buffer) do
    if ArrayBuffer.detached?(buffer) do
      raise Web.TypeError.exception("Cannot create a Uint8Array from a detached ArrayBuffer")
    end
  end

  defp validate_offset!(offset, max_length) do
    if is_integer(offset) and offset >= 0 and offset <= max_length do
      :ok
    else
      raise ArgumentError, "invalid byte offset"
    end
  end

  defp resolve_length(offset, nil, max_length), do: max_length - offset

  defp resolve_length(offset, length, max_length)
       when is_integer(length) and length >= 0 and offset + length <= max_length,
       do: length

  defp resolve_length(_offset, _length, _max_length) do
    raise ArgumentError, "invalid byte length"
  end

  defp build_view(buffer, offset, byte_length) do
    %__MODULE__{id: make_ref(), buffer: buffer, byte_offset: offset, byte_length: byte_length}
  end

  @doc false
  @spec identity(t()) :: reference() | nil
  def identity(%__MODULE__{} = uint8_array), do: uint8_array.id

  @doc false
  # The bytes of the view. A caller of the library uses `to_string/1`: see
  # the implementation of `String.Chars`.
  @spec to_binary(t()) :: binary()
  def to_binary(%__MODULE__{buffer: buffer, byte_offset: offset, byte_length: len}) do
    data = ArrayBuffer.data(buffer)
    binary_part(data, offset, len)
  end
end

defimpl String.Chars, for: Web.Uint8Array do
  # The bytes of the view, as a binary. A detached buffer raises
  # `Web.TypeError`.
  def to_string(view), do: Web.Uint8Array.to_binary(view)
end

defimpl Inspect, for: Web.Uint8Array do
  import Inspect.Algebra

  # A short form, because each chunk of a stream of bytes is a view:
  # `#Web.Uint8Array<"hello">`. The usual limits of `inspect/2` apply to the
  # bytes.
  def inspect(%Web.Uint8Array{buffer: buffer} = view, opts) do
    bytes =
      if Web.ArrayBuffer.detached?(buffer),
        do: "detached",
        else: to_doc(Web.Uint8Array.to_binary(view), opts)

    concat(["#Web.Uint8Array<", bytes, ">"])
  end
end
