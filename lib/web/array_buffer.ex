defmodule Web.ArrayBuffer do
  @moduledoc """
  WHATWG-style immutable ArrayBuffer representation.
  """

  @enforce_keys [:data, :byte_length]
  defstruct [:data, :byte_length]

  @type t :: %__MODULE__{
          data: binary(),
          byte_length: non_neg_integer()
        }

  @doc """
  Creates a new ArrayBuffer from a binary or from a byte length.

  ## Examples

      iex> buffer = Web.ArrayBuffer.new("hello")
      iex> {buffer.data, buffer.byte_length}
      {"hello", 5}

      iex> buffer = Web.ArrayBuffer.new(4)
      iex> {buffer.data, buffer.byte_length}
      {<<0, 0, 0, 0>>, 4}
  """
  @spec new(binary() | non_neg_integer()) :: t()
  def new(data) when is_binary(data) do
    %__MODULE__{data: data, byte_length: byte_size(data)}
  end

  def new(byte_length) when is_integer(byte_length) and byte_length >= 0 do
    %__MODULE__{data: :binary.copy(<<0>>, byte_length), byte_length: byte_length}
  end
end
