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
    input
    |> ArrayBuffer.new()
    |> Uint8Array.new()
  end

  def encode(%__MODULE__{}, _input) do
    raise TypeError, "TextEncoder.encode input must be a string"
  end
end
