defmodule Web.Internal.Bytes do
  @moduledoc false
  # The forms of a chunk of bytes.
  #
  # A stream of this library gives each chunk of bytes as a `Web.Uint8Array`,
  # as the Web standards specify. A consumer of this library accepts more
  # forms, because a stream from the caller can give a binary: a binary, a
  # `Web.Uint8Array`, a `Web.ArrayBuffer`, or iodata.

  alias Web.ArrayBuffer
  alias Web.Uint8Array

  @doc """
  Returns the bytes of a chunk as `{:ok, binary}`, or `:error` for a value
  that is not a chunk of bytes.
  """
  @spec to_binary(term()) :: {:ok, binary()} | :error
  def to_binary(chunk) when is_binary(chunk), do: {:ok, chunk}
  def to_binary(%Uint8Array{} = chunk), do: {:ok, Uint8Array.to_binary(chunk)}
  def to_binary(%ArrayBuffer{} = chunk), do: {:ok, ArrayBuffer.data(chunk)}

  def to_binary(chunk) when is_list(chunk) do
    {:ok, IO.iodata_to_binary(chunk)}
  rescue
    ArgumentError -> :error
  end

  def to_binary(_chunk), do: :error

  @doc """
  Returns the bytes of a chunk. Raises `Web.TypeError`, with the name of the
  consumer in the message, for a value that is not a chunk of bytes.
  """
  @spec to_binary!(term(), String.t()) :: binary()
  def to_binary!(chunk, consumer) do
    case to_binary(chunk) do
      {:ok, binary} ->
        binary

      :error ->
        raise Web.TypeError,
              "#{consumer} chunk must be a binary, a Uint8Array, or an ArrayBuffer, " <>
                "got: #{inspect(chunk)}"
    end
  end

  @doc """
  Changes a binary into a `Web.Uint8Array`. Each other value stays as it is.
  """
  @spec chunk(term()) :: term()
  def chunk(binary) when is_binary(binary), do: Uint8Array.from(binary)
  def chunk(other), do: other
end
