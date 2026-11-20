defmodule Web.Internal.ContentDecoderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Internal.ContentDecoder, as: Decoder
  alias Web.Internal.ContentDecoder.Error

  @codings ["gzip", "x-gzip", "deflate", "raw deflate", "zstd", "deflate, gzip"]

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp encode("gzip", data), do: :zlib.gzip(data)
  defp encode("x-gzip", data), do: :zlib.gzip(data)
  defp encode("deflate", data), do: :zlib.compress(data)
  defp encode("raw deflate", data), do: :zlib.zip(data)
  defp encode("zstd", data), do: Web.TestZstd.compress(data)
  defp encode("deflate, gzip", data), do: data |> :zlib.compress() |> :zlib.gzip()

  defp header("raw deflate"), do: "deflate"
  defp header(coding), do: coding

  defp decoder(coding), do: Decoder.new([{"content-encoding", header(coding)}])

  # Decodes the chunks, and returns the output.
  defp decode(stages, chunks) do
    stages |> pieces(chunks) |> IO.iodata_to_binary()
  end

  # Gives each chunk, and takes the pieces after each chunk.
  defp pieces(stages, chunks) do
    {pieces, stages} =
      Enum.reduce(chunks, {[], stages}, fn chunk, {pieces, stages} ->
        {:more, pieces, stages} = drain(Decoder.push(stages, chunk), pieces)
        {pieces, stages}
      end)

    {:done, pieces, _stages} = drain(Decoder.finish(stages), pieces)
    Enum.reverse(pieces)
  end

  defp drain(stages, pieces) do
    case Decoder.pull(stages) do
      {:piece, piece, stages} -> drain(stages, [piece | pieces])
      {status, stages} -> {status, pieces, stages}
    end
  end

  defp split(binary, sizes) do
    Enum.reduce(sizes, {[], binary}, fn
      _size, {chunks, <<>>} ->
        {chunks, <<>>}

      size, {chunks, rest} ->
        size = min(size, byte_size(rest))
        <<chunk::binary-size(^size), rest::binary>> = rest
        {[chunk | chunks], rest}
    end)
    |> then(fn {chunks, rest} -> Enum.reverse([rest | chunks]) end)
  end

  defp decode_error(coding, encoded) do
    assert_raise Error, fn -> decode(decoder(coding), [encoded]) end
  end

  # ---------------------------------------------------------------------------
  # The codings
  # ---------------------------------------------------------------------------

  describe "new/1" do
    test "knows gzip, x-gzip, deflate, and zstd" do
      for coding <- ["gzip", "x-gzip", "deflate", "zstd", "deflate, gzip"] do
        assert [_stage | _rest] = decoder(coding)
      end
    end

    test "gives no decoder for no coding, for identity, and for a coding that it does not know" do
      assert Decoder.new([{"content-type", "text/plain"}]) == nil
      assert Decoder.new([{"content-encoding", "identity"}]) == nil
      assert Decoder.new([{"content-encoding", " , "}]) == nil
      assert Decoder.new([{"content-encoding", "br"}]) == nil
      # One coding that the decoder does not know: no decoding.
      assert Decoder.new([{"content-encoding", "gzip, br"}]) == nil
    end

    test "reads each header line, with no case and no space" do
      assert [%{coding: "deflate"}, %{coding: "gzip"}] =
               Decoder.new([{"Content-Encoding", " GZIP "}, {"content-encoding", "Deflate"}])
    end

    test "the request header has the codings that the decoder knows" do
      assert Decoder.accept_encoding() == "gzip, deflate, zstd"
    end
  end

  describe "push/2 and pull/1" do
    test "gives the data of each coding" do
      data = :crypto.strong_rand_bytes(20_000) <> :binary.copy("hello ", 50_000)

      for coding <- @codings do
        assert decode(decoder(coding), [encode(coding, data)]) == data, coding
      end
    end

    test "accepts a split at each byte position" do
      data = "a short body, " <> :binary.copy("x", 300)

      for coding <- @codings do
        encoded = encode(coding, data)

        for position <- 0..byte_size(encoded) do
          <<first::binary-size(^position), second::binary>> = encoded
          assert decode(decoder(coding), [first, second]) == data, "#{coding} at #{position}"
        end
      end
    end

    test "accepts one byte at a time" do
      data = :binary.copy("one byte at a time ", 200)

      for coding <- @codings do
        encoded = encode(coding, data)

        assert decode(decoder(coding), split(encoded, List.duplicate(1, byte_size(encoded)))) ==
                 data
      end
    end

    test "gives the output in pieces, also for a small chunk that expands much" do
      for coding <- @codings do
        encoded = encode(coding, :binary.copy(<<0>>, 2_000_000))
        sizes = decoder(coding) |> pieces([encoded]) |> Enum.map(&byte_size/1)

        assert Enum.sum(sizes) == 2_000_000, coding
        assert Enum.max(sizes) < 200_000, coding
      end
    end

    test "gives an empty body for each coding" do
      for coding <- @codings, do: assert(decode(decoder(coding), [<<>>]) == <<>>)
    end

    test "decodes only the piece that a pull takes" do
      data = :binary.copy(<<0>>, 1_000_000)

      for coding <- @codings do
        stages = Decoder.push(decoder(coding), encode(coding, data))
        assert {:piece, first, stages} = Decoder.pull(stages)
        assert byte_size(first) < 200_000, coding

        # The rest of the output comes with the subsequent pulls.
        assert {:piece, _second, _stages} = Decoder.pull(stages)
      end
    end
  end

  describe "data that is not correct" do
    test "data that is not valid raises" do
      assert decode_error("gzip", "not gzip data").message == "The gzip data is not valid."
      assert decode_error("deflate", "xx not deflate").message == "The deflate data is not valid."
      assert decode_error("zstd", "not zstd data").message == "The data is not a zstd frame."
    end

    test "data that is cut raises at the end" do
      data = :crypto.strong_rand_bytes(5_000)

      for coding <- @codings do
        encoded = encode(coding, data)
        cut = binary_part(encoded, 0, byte_size(encoded) - 3)
        error = decode_error(coding, cut)
        assert error.message =~ "is not complete", coding
      end
    end

    test "a zstd frame with a correct structure and data that is not correct raises" do
      data = :binary.copy("some text that compresses ", 2_000)
      {:ok, context} = :zstd.context(:compress, %{checksumFlag: true})
      {:done, frame} = :zstd.finish(context, data)
      frame = IO.iodata_to_binary(frame)

      # A byte in the middle of the block. The checksum of the frame is not
      # the checksum of the output.
      position = div(byte_size(frame), 2)
      <<head::binary-size(^position), byte, tail::binary>> = frame
      corrupt = head <> <<Bitwise.bxor(byte, 0xFF)>> <> tail

      assert decode_error("zstd", corrupt).message == "The zstd data is not valid."
    end

    test "one byte of deflate data is not complete" do
      assert decode_error("deflate", "x").message == "The deflate data is not complete."
    end

    test "a zlib stream that needs a dictionary is not valid" do
      zlib = :zlib.open()
      :ok = :zlib.deflateInit(zlib)
      _adler = :zlib.deflateSetDictionary(zlib, "a dictionary")
      encoded = IO.iodata_to_binary(:zlib.deflate(zlib, "data", :finish))
      :zlib.close(zlib)

      assert decode_error("deflate", encoded).message == "The deflate data is not valid."
    end

    test "a zstd frame header with the reserved bit is not valid" do
      frame = <<0xFD2FB528::32-little, 0x08, 0>>
      assert decode_error("zstd", frame).message == "The zstd frame header is not valid."
    end

    test "a zstd block of the reserved type is not valid" do
      # A frame with one segment and a content size of one byte, then a
      # block header of type 3.
      frame = <<0xFD2FB528::32-little, 0x20, 1, 0b111::24-little>>
      assert decode_error("zstd", frame).message == "The zstd block type is not valid."
    end
  end

  describe "zstd frames" do
    test "two frames, a skippable frame, a checksum, and a block of one repeated byte" do
      data = :crypto.strong_rand_bytes(1_000) <> :binary.copy("r", 300_000)
      plain = IO.iodata_to_binary(:zstd.compress(data))

      {:ok, context} = :zstd.context(:compress, %{checksumFlag: true})
      {:done, with_checksum} = :zstd.finish(context, data)
      with_checksum = IO.iodata_to_binary(with_checksum)

      skippable = <<0x184D2A50::32-little, 5::32-little, "skip!">>
      body = skippable <> plain <> with_checksum

      for sizes <- [[byte_size(body)], List.duplicate(3, div(byte_size(body), 3) + 1)] do
        assert decode(decoder("zstd"), split(body, sizes)) == data <> data
      end

      # A frame that ends in its checksum is not complete.
      cut = binary_part(with_checksum, 0, byte_size(with_checksum) - 2)
      assert decode_error("zstd", cut).message == "The zstd data is not complete."
    end
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "each coding gives the input, for each split of the data" do
    check all(
            data <- binary(max_length: 20_000),
            coding <- member_of(@codings),
            sizes <- list_of(integer(1..4_096), max_length: 20),
            max_runs: 200
          ) do
      encoded = encode(coding, data)
      assert decode(decoder(coding), split(encoded, sizes)) == data
    end
  end
end
