defmodule Web.Uint8Array do
  @moduledoc """
  WHATWG-style immutable Uint8Array view over an ArrayBuffer.

  ## Examples

      iex> buffer = Web.ArrayBuffer.new("hello")
      iex> uint8 = Web.Uint8Array.new(buffer, 1, 3)
      iex> uint8.byte_length
      3
      iex> Web.Uint8Array.to_binary(uint8)
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

  @doc """
  Returns the binary represented by this Uint8Array view.
  """
  @spec to_binary(t()) :: binary()
  def to_binary(%__MODULE__{buffer: buffer, byte_offset: offset, byte_length: len}) do
    data = ArrayBuffer.data(buffer)
    binary_part(data, offset, len)
  end
end
