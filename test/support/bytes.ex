defmodule Web.TestBytes do
  @moduledoc false
  # Helpers for the tests that read a stream of bytes. Each chunk of such a
  # stream is a `Web.Uint8Array`.

  alias Web.Internal.Bytes

  @doc "Returns the bytes of one chunk as a binary."
  def binary(chunk), do: Bytes.to_binary!(chunk, "The test")

  @doc "Reads the enumerable to its end, and returns the chunks as binaries."
  def binaries(enumerable), do: Enum.map(enumerable, &binary/1)

  @doc "Reads the enumerable to its end, and returns all the bytes."
  def join(enumerable), do: enumerable |> binaries() |> IO.iodata_to_binary()
end
