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

  @enforce_keys [:buffer, :byte_offset, :byte_length]
  defstruct [:buffer, :byte_offset, :byte_length]

  @type t :: %__MODULE__{
          buffer: ArrayBuffer.t(),
          byte_offset: non_neg_integer(),
          byte_length: non_neg_integer()
        }

  @doc """
  Creates a new Uint8Array view over the given ArrayBuffer.
  """
  @spec new(ArrayBuffer.t(), non_neg_integer(), non_neg_integer() | nil) :: t()
  def new(%ArrayBuffer{} = buffer, offset \\ 0, length \\ nil) do
    max_length = buffer.byte_length

    cond do
      not (is_integer(offset) and offset >= 0 and offset <= max_length) ->
        raise ArgumentError, "invalid byte offset"

      is_nil(length) ->
        %__MODULE__{buffer: buffer, byte_offset: offset, byte_length: max_length - offset}

      not (is_integer(length) and length >= 0 and offset + length <= max_length) ->
        raise ArgumentError, "invalid byte length"

      true ->
        %__MODULE__{buffer: buffer, byte_offset: offset, byte_length: length}
    end
  end

  @doc """
  Returns the binary represented by this Uint8Array view.
  """
  @spec to_binary(t()) :: binary()
  def to_binary(%__MODULE__{
        buffer: %ArrayBuffer{data: data},
        byte_offset: offset,
        byte_length: len
      }) do
    binary_part(data, offset, len)
  end
end
