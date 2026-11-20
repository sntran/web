defmodule Web.TestZstd do
  @moduledoc false

  # Compresses data with zstd for the tests.
  #
  # On Erlang/OTP 28, `:zstd.compress/1` fails for empty data: the internal
  # loop of the module has no clause for the end of its input. Erlang/OTP 29
  # corrects this. For empty data, this function gives the frame that
  # Erlang/OTP 29 makes: a frame with a content size of 0.
  @empty_frame <<40, 181, 47, 253, 32, 0, 1, 0, 0>>

  def compress(<<>>), do: @empty_frame
  def compress(data), do: IO.iodata_to_binary(:zstd.compress(data))
end
