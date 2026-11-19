defmodule Web.CompressionStandardTest do
  # The behaviour of the compression streams that the Compression Standard
  # specifies for data that is not complete or not valid.
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Web

  @formats ~w[gzip deflate deflate-raw]

  # Gives the chunks of the readable side as binaries.
  defp through(chunks, transform) do
    chunks
    |> ReadableStream.from()
    |> ReadableStream.pipe_through(transform)
    |> Web.TestBytes.binaries()
  end

  defp compress(data, format),
    do: [data] |> through(CompressionStream.new(format)) |> IO.iodata_to_binary()

  defp decompress(chunks, format),
    do: chunks |> through(DecompressionStream.new(format)) |> IO.iodata_to_binary()

  # Splits a binary at the given positions.
  defp split(binary, []), do: [binary]

  defp split(binary, [size | sizes]) do
    size = min(size, byte_size(binary))
    <<head::binary-size(size), rest::binary>> = binary
    [head | split(rest, sizes)]
  end

  describe "a decompression stream" do
    test "gives TypeError when the stream closes before the end of the data" do
      for format <- @formats do
        compressed = compress(String.duplicate("payload ", 2_000), format)

        for size <- [0, 1, 10, div(byte_size(compressed), 2), byte_size(compressed) - 1] do
          assert_raise TypeError, ~r/not complete|invalid data/, fn ->
            decompress([binary_part(compressed, 0, size)], format)
          end
        end
      end
    end

    test "gives TypeError when the stream closes with no data" do
      for format <- @formats do
        assert_raise TypeError, ~r/not complete/, fn -> decompress([], format) end
      end
    end

    test "gives TypeError for data after the end of the compressed data" do
      for format <- @formats do
        compressed = compress("payload", format)

        # In the same chunk, in a later chunk, and a second compressed stream.
        for chunks <- [[compressed <> "x"], [compressed, "x"], [compressed <> compressed]] do
          assert_raise TypeError, ~r/invalid data/, fn -> decompress(chunks, format) end
        end
      end
    end

    test "puts the two sides in the errored state for data that is not valid" do
      stream = DecompressionStream.new("gzip")
      writer = WritableStream.get_writer(stream.writable)
      read = ReadableStreamDefaultReader.read(ReadableStream.get_reader(stream.readable))

      assert %TypeError{} =
               catch_exit(await(WritableStreamDefaultWriter.write(writer, "not gzip")))

      assert %TypeError{} = catch_exit(await(read))
      assert %TypeError{} = catch_exit(await(WritableStreamDefaultWriter.write(writer, "more")))
    end

    property "gives the data for each division of the compressed bytes into chunks" do
      check all(
              data <- binary(max_length: 2_000),
              format <- member_of(@formats),
              sizes <- list_of(integer(1..64), max_length: 20),
              max_runs: 60
            ) do
        compressed = compress(data, format)
        assert decompress(split(compressed, sizes), format) == data
      end
    end

    property "gives TypeError for each prefix of the compressed bytes" do
      check all(
              data <- binary(min_length: 1, max_length: 500),
              format <- member_of(@formats),
              cut <- integer(1..40),
              max_runs: 60
            ) do
        compressed = compress(data, format)
        prefix = binary_part(compressed, 0, max(byte_size(compressed) - cut, 0))

        assert_raise TypeError, fn -> decompress([prefix], format) end
      end
    end
  end

  describe "a chunk of bytes" do
    test "can be a binary, a Uint8Array, or an ArrayBuffer" do
      for format <- @formats do
        chunks = ["ab", Uint8Array.new(ArrayBuffer.new("xcdx"), 1, 2), ArrayBuffer.new("ef")]
        compressed = chunks |> through(CompressionStream.new(format)) |> IO.iodata_to_binary()

        assert decompress([compressed], format) == "abcdef"
        assert decompress([ArrayBuffer.new(compressed)], format) == "abcdef"
        assert decompress([Uint8Array.new(ArrayBuffer.new(compressed))], format) == "abcdef"
      end
    end

    test "that is a different term gives TypeError" do
      for make <- [&CompressionStream.new/1, &DecompressionStream.new/1],
          chunk <- [123, :atom, %{}] do
        assert_raise TypeError, ~r/chunk must be a binary/, fn ->
          through([chunk], make.("gzip"))
        end
      end
    end
  end

  describe "the format" do
    test "must be one of the three formats of the Standard" do
      for make <- [&CompressionStream.new/1, &DecompressionStream.new/1] do
        for format <- @formats, do: assert(%{readable: _, writable: _} = make.(format))

        for format <- ["brotli", "GZIP", "", :gzip, nil],
            do: assert_raise(TypeError, fn -> make.(format) end)
      end
    end
  end

  describe "the backpressure" do
    test "holds the writes of a compression stream that no process reads" do
      stream = CompressionStream.new("gzip")
      writer = WritableStream.get_writer(stream.writable)

      writes =
        for _ <- 1..50,
            do: WritableStreamDefaultWriter.write(writer, :crypto.strong_rand_bytes(20_000))

      Process.sleep(100)
      assert Enum.count(writes, &(Promise.peek(&1) == :pending)) >= 45
      assert :queue.len(ReadableStream.__get_slots__(stream.readable.controller_pid).queue) <= 2
    end
  end
end
