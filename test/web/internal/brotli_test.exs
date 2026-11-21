defmodule Web.Internal.BrotliTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Web.Internal.Brotli.Decoder
  alias Web.Internal.Brotli.Dictionary
  alias Web.Internal.Brotli.Encoder
  alias Web.TestBrotliWriter, as: B

  # Test vectors of the reference implementation: the directory
  # tests/testdata of https://github.com/google/brotli (MIT license,
  # Copyright (c) 2009, 2010, 2013-2016 by the Brotli Authors). Each vector
  # has the compressed bytes, and the size and the SHA-256 hash of the
  # original file.
  @vectors [
    {"empty", "06", 0, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
    {"x", "0b00805803", 1, "4b68ab3847feda7d6c62c1fbcbeebfa35eab7351ed5e78f4ddadea5df64b8015"},
    {"10x10y", "1b130000a4b0b2ea8147028a", 20,
     "41bd4c895e9fb36d74bc97db5092872a24267e3b0455ff6152b0d262faa00d49"},
    {"64x", "1b3f000024b0e2998012", 64,
     "be4d3ed1fc5f5cfa00735b28605a975f3293fa235d23abb1d9dea380fba0fb87"},
    {"xyzzy", "0b028058797a7a7903", 5,
     "7609128715518308672067aab169e24944ead24e3d732aab8a8f0b7013a65564"},
    {"zeros", "5bffff036002201e0b28f77e00", 262_144,
     "8a39d2abd3999ab73c34db2476849cddf303ce389b35826850f9a700589b4a90"},
    {"backward65536", "5bff0001400a00ab167bac00484e73ed019203", 65_792,
     "a6dbac2165542001c574fe1d5ed6ca646203660c228cac57b47a9fec68c20217"},
    {"quickfox",
     "0b158054686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c617a7920646f6703",
     43, "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"},
    {"quickfox_repeated",
     "5bffaf02c022795cfb5a8c423bf42555195a9299b135c8199e9e0a7b4b90b93c98c80940f3e6d94de46d651b2787135fa6e930967b3c15d8531c",
     176_128, "254fdc641d1a65d0b1e427e4b0a1e16a96a5242adb98af71833782ba99c3dd82"},
    {"ukkonooa",
     "1b760000144aac9b7abde1979d7f8ec282360e9ce09003f78b9e38e6b600abc3caa0c2da6636dccd808d2e21d76ee3ea4cb8f0d2b8c7c2704d3af0697ea1b84573abc4571e",
     119, "1fb2529b0c6fbf80a60d2bb4c20efba2fff6cecb0c52d42693d404501064f407"},
    {"monkey",
     "1b4a03008c946edeb4d796b17886f22de11abc0b1cbaa9c7f7cc6eb2423451448b4e1308a0cd6ee82ca553a19c5d2c1d231ad256bedbeb26ba03657c966aa276ecef874733d6270e6395e21d8d2cc5d1289f60946f028bddaa64942c1e3b657c07455ab2e2fc49812c9f40aeef6881ac167a0ff53b6d1cb91e2d5fd5c8af5e85aa05be5375c2b0228a15c6a3b1e64214f4845453195fbec3f21dd1b7e5ddb6d923c6f69f9ef64d6530fbc0714504ad03b5bec9cbfde2505a4674040dff200477b26d27bf47a99d1b962c6290238be0f81dcfaf1d3dee8ac8752366ddded66de32a828a788adbe6204cb75c63ba30e33fb6ee8c22a22ab0220a99ff3d6251ee08f63d4ae4ccef228711e28328e4f58f3519635be15a9273dda1509d385cebb5036a649094c88dfb2f8a8622cc1d87e0480a96779039c6232348fb114756ca20e34281f77732c1a55c40216517402917176c5632983806dc994d3329bb02df4c26936c17828620d703797d9a00d78700e70b66e34c6671670832f9083e8133cd177231f0b894524b90318e68c1ef90c9e5f261097225adecc562c00b1205f791750dee612e2e1909c203",
     843, "937ad127fe0e373e0e267d11905f2bca154f40fe6fd438b6ddcce40de2ddcd99"}
  ]

  # A stream that this project made field by field, with random commands:
  # block switches of the three categories with each kind of block type
  # code, the four context modes, two literal prefix codes with a context
  # map (RLEMAX 3 and the inverse move-to-front transform), two distance
  # prefix codes with a context map, NPOSTFIX 1 and NDIRECT 2, the short
  # distance codes, a literal code of 10 bits, and the repeat codes 16 and
  # 17. The reference decoder (google/brotli 1.1.0) gives the output of the
  # hash.
  @switches {"switches",
             "224b6036b22e2010194760b0c13517182fc8a3c09d899a28db444db744dbaf9be8279aa6db29514d9d7a4d55af29a22d4ad4366daf49753b6dbd688b3ab53594f003552caafefb79f1f1bcc757af273e5fbf1e79beebf5eacf633ed74000c0803a0148906149052148030a108a77535555557b001ceb620ffde02bcf9cdf8edf47284ff5fffea210efdf84d3bfb46fe99d0eee68b5d50efa24772800b9fceb260ee2bffd7febaf5fff7fffcefbc4565b899efebebff7b7dc9c05df83f2eef57883e76860b0bff9dfb7bf3f90efbfd7fe47c346119f89e7fff7fffbff7bffff7f27fffc1ffddffbaf0916ca3f3a63593e",
             602, "d2a24ac132c23f8d36a4713fd67c5e698dea66a198606d175aa1934c9acf8372"}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp hash(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

  # Gives each chunk to a decoder, and takes all the output. Returns
  # `{result, output}`: the result is `{:end, rest}`, `:more`, or
  # `{:error, :invalid}`. The chunks after the end go to the decoder too.
  defp decode(chunks, limit \\ 65_536) do
    {result, pieces} = pieces(chunks, limit)
    {result, IO.iodata_to_binary(pieces)}
  end

  # The same as `decode/2`, with the list of the pieces.
  defp pieces(chunks, limit) do
    {result, pieces} =
      Enum.reduce_while(chunks, {{:more, Decoder.new()}, []}, fn chunk, {{_, decoder}, acc} ->
        case drain(Decoder.append(decoder, chunk), limit, acc) do
          {{:error, _reason}, _acc} = error -> {:halt, error}
          other -> {:cont, other}
        end
      end)

    result =
      case result do
        {:more, _decoder} -> :more
        {:end, decoder} -> {:end, Decoder.rest(decoder)}
        error -> error
      end

    {result, Enum.reverse(pieces)}
  end

  defp drain(decoder, limit, acc) do
    case Decoder.run(decoder, limit) do
      {:output, piece, decoder} -> drain(decoder, limit, [piece | acc])
      other -> {other, acc}
    end
  end

  defp split(binary, sizes) do
    {chunks, rest} =
      Enum.reduce(sizes, {[], binary}, fn size, {chunks, rest} ->
        size = min(size, byte_size(rest))
        <<chunk::binary-size(^size), rest::binary>> = rest
        {[chunk | chunks], rest}
      end)

    Enum.reverse([rest | chunks])
  end

  defp encode(chunks) do
    {outputs, encoder} = Enum.map_reduce(chunks, Encoder.new(), &Encoder.push(&2, &1))
    IO.iodata_to_binary([outputs, Encoder.finish(encoder)])
  end

  # The fields of a compressed meta-block with one prefix code for each
  # alphabet, after the window size.
  defp meta_block(length, literal, command, distance, commands) do
    [B.header(true, length), B.one_of_each(literal, command, distance), commands]
  end

  # ---------------------------------------------------------------------------
  # The static dictionary
  # ---------------------------------------------------------------------------

  describe "the static dictionary" do
    # The hash comes from the bytes of appendix A of the text of RFC 7932
    # (https://www.rfc-editor.org/rfc/rfc7932.txt). The RFC gives the CRC-32.
    test "has the bytes of RFC 7932, appendix A" do
      bytes = Dictionary.bytes()
      assert byte_size(bytes) == 122_784
      assert :erlang.crc32(bytes) == 0x5136CB04
      assert hash(bytes) == "20e42eb1b511c21806d4d227d07e5dd06877d8ce7b3a817f378f313653f35c70"
    end

    # Appendix B: each transform as its prefix, a zero byte, the number of
    # the elementary transform, the suffix, and a zero byte.
    test "has the 121 transforms of RFC 7932, appendix B" do
      number = fn
        :identity -> 0
        :ferment_first -> 1
        :ferment_all -> 2
        {:omit_first, count} -> 2 + count
        {:omit_last, count} -> 11 + count
      end

      bytes =
        for {prefix, transform, suffix} <- Dictionary.transforms(), into: <<>> do
          <<prefix::binary, 0, number.(transform), suffix::binary, 0>>
        end

      assert length(Dictionary.transforms()) == 121
      assert byte_size(bytes) == 648
      assert :erlang.crc32(bytes) == 0x3D965F81
    end

    test "gives the transformed words of section 8" do
      # The first word of length 4 is "time". A word identifier has the
      # transform in the bits after the 10 bits of the index.
      assert Dictionary.word(4, 0) == "time"
      assert Dictionary.word(4, 1 <<< 10) == "time "
      assert Dictionary.word(4, 3 <<< 10) == "ime"
      assert Dictionary.word(4, 9 <<< 10) == "Time"
      assert Dictionary.word(4, 12 <<< 10) == "tim"
      assert Dictionary.word(4, 44 <<< 10) == "TIME"
      assert Dictionary.word(4, 54 <<< 10) == ""
      assert Dictionary.word(4, 64 <<< 10) == ""
      assert Dictionary.word(4, 73 <<< 10) == " the time of the "
    end

    test "ferments the sequences of two and three bytes of UTF-8" do
      # Two bytes: "за" becomes "За" and "ЗА".
      assert Dictionary.word(4, 939) == "за"
      assert Dictionary.word(4, 9 <<< 10 ||| 939) == "За"
      assert Dictionary.word(4, 44 <<< 10 ||| 939) == "ЗА"
      # Three bytes: the third byte changes.
      assert Dictionary.word(4, 527) == "\xE2\x80\x99s"
      assert Dictionary.word(4, 9 <<< 10 ||| 527) == "\xE2\x80\x9Cs"
      assert Dictionary.word(4, 44 <<< 10 ||| 527) == "\xE2\x80\x9CS"
      # A sequence that the word cuts does not change.
      assert Dictionary.word(4, 436) == "zh:\xE5"
      assert Dictionary.word(4, 44 <<< 10 ||| 436) == "ZH:\xE5"
      assert Dictionary.word(4, 44 <<< 10 ||| 683) == "KM\xC2\x92"
    end

    test "has no word for a length out of 4 to 24, or for a transform after 120" do
      assert Dictionary.word(3, 0) == :error
      assert Dictionary.word(25, 0) == :error
      assert Dictionary.word(4, 121 <<< 10) == :error
    end
  end

  # ---------------------------------------------------------------------------
  # The decoder
  # ---------------------------------------------------------------------------

  describe "the decoder" do
    test "has the tables of section 7.1 with the CRC-32 values of the RFC" do
      {lut0, lut1, lut2} = Decoder.__tables__()
      assert Enum.map([lut0, lut1, lut2], &byte_size/1) == [256, 256, 256]
      assert :erlang.crc32(lut0) == 0x8E91EFB7
      assert :erlang.crc32(lut1) == 0xD01A32F4
      assert :erlang.crc32(lut2) == 0x0DD7A0D6
    end

    test "decodes the test vectors of the reference implementation" do
      for {name, hex, size, digest} <- [@switches | @vectors] do
        {result, output} = decode([Base.decode16!(hex, case: :lower)])
        assert result == {:end, 0}, name
        assert byte_size(output) == size, name
        assert hash(output) == digest, name
      end
    end

    property "gives the same output for each split of the input" do
      check all(
              {_name, hex, size, digest} <- member_of([@switches | @vectors]),
              sizes <- list_of(integer(1..20), max_length: 30),
              max_runs: 100
            ) do
        {result, output} = decode(split(Base.decode16!(hex, case: :lower), sizes))
        assert result == {:end, 0}
        assert byte_size(output) == size
        assert hash(output) == digest
      end
    end

    # The input has 40 bytes or more in some chunks: the fast loop of the
    # commands starts and stops at many positions. The limit stops it in
    # the literals and in the copies.
    property "gives the same output for each split of the input and each limit" do
      check all(
              {_name, hex, size, digest} <- member_of([@switches | @vectors]),
              sizes <- list_of(integer(1..80), max_length: 12),
              limit <- one_of([integer(1..40), constant(65_536)]),
              max_runs: 200
            ) do
        {result, pieces} = pieces(split(Base.decode16!(hex, case: :lower), sizes), limit)
        output = IO.iodata_to_binary(pieces)
        assert result == {:end, 0}
        assert byte_size(output) == size
        assert hash(output) == digest
        assert Enum.all?(pieces, &(byte_size(&1) in 1..limit))
      end
    end

    test "gives the output in pieces of the limit" do
      {"zeros", hex, size, _digest} = Enum.at(@vectors, 5)
      input = Base.decode16!(hex, case: :lower)
      decoder = Decoder.append(Decoder.new(), input)
      assert {:output, piece, _decoder} = Decoder.run(decoder, 1000)
      assert piece == :binary.copy(<<0>>, 1000)
      assert decode([input], 1000) == {{:end, 0}, :binary.copy(<<0>>, size)}

      # A limit of a few bytes stops the literals and the copies at each
      # byte.
      for {name, hex, size, digest} <- [@switches | @vectors],
          size < 1_000,
          limit <- [1, 2, 3, 7] do
        {result, output} = decode([Base.decode16!(hex, case: :lower)], limit)
        assert {result, hash(output)} == {{:end, 0}, digest}, "#{name} with the limit #{limit}"
      end
    end

    test "each prefix of a stream needs more input, and gives a prefix of the output" do
      for {name, hex, _size, _digest} <- Enum.take([@switches | @vectors], 6) do
        input = Base.decode16!(hex, case: :lower)
        {_result, full} = decode([input])

        for cut <- 0..(byte_size(input) - 1) do
          {result, output} = decode([binary_part(input, 0, cut)])
          assert result == :more, "#{name} at #{cut}"
          assert String.starts_with?(full, output)
        end
      end
    end

    test "counts the bytes after the end of the stream" do
      {"x", hex, _size, _digest} = Enum.at(@vectors, 1)
      input = Base.decode16!(hex, case: :lower)
      assert decode([input <> "abc"]) == {{:end, 3}, "X"}
      assert decode([input, "a", "bc"]) == {{:end, 3}, "X"}
    end

    test "accepts each window size of section 9.1" do
      for wbits <- 10..24 do
        stream = B.bytes([B.window(wbits), B.last_empty()])
        assert decode([stream]) == {{:end, 0}, ""}, "WBITS #{wbits}"
      end
    end

    test "skips the metadata, and copies an uncompressed meta-block" do
      stream = metadata_stream()
      assert decode([stream]) == {{:end, 0}, "hello"}

      for size <- 1..9 do
        assert decode(split(stream, List.duplicate(size, byte_size(stream)))) ==
                 {{:end, 0}, "hello"}
      end
    end

    test "keeps the window when the output is longer than the window" do
      # The window of WBITS 10 has 1008 bytes. The first command inserts
      # "abc" and copies 140000 bytes at the distance 3. The second command
      # inserts "b" and copies 5 bytes at the distance 1000.
      {literal, literals} = B.simple([?a, ?b, ?c], 256)
      {command, commands} = B.simple([415, 139], 704)
      {distance, distances} = B.simple([17, 31], 64)

      fields = [
        B.window(10),
        meta_block(140_009, literal, command, distance, [
          B.symbol(commands, 415),
          {140_000 - 2118, 24},
          for(byte <- ~c"abc", do: B.symbol(literals, byte)),
          B.symbol(distances, 17),
          {0, 1},
          B.symbol(commands, 139),
          B.symbol(literals, ?b),
          B.symbol(distances, 31),
          {235, 8}
        ])
      ]

      start = binary_part(:binary.copy("abc", 46_668), 0, 140_003) <> "b"
      expected = start <> binary_part(start, byte_size(start) - 1000, 5)
      assert decode([B.bytes(fields)]) == {{:end, 0}, expected}
      assert decode([B.bytes(fields)], 5000) == {{:end, 0}, expected}
    end

    test "copies the words of the static dictionary" do
      # A distance larger than the output is a word: the identifier of the
      # word is the distance minus the output size minus 1. The second word
      # is empty. Four meta-blocks have the same words.
      ids = [0, 54 <<< 10, 73 <<< 10, (44 <<< 10) + 939]
      words = Enum.map_join(ids, &Dictionary.word(4, &1))
      {literal, _literals} = B.simple([0], 256)
      {command, commands} = B.simple([130], 704)

      blocks =
        for block <- 0..3 do
          {codes, _size} =
            Enum.map_reduce(ids, block * byte_size(words), fn id, size ->
              {B.distance(id + size + 1), size + byte_size(Dictionary.word(4, id))}
            end)

          {distance, distances} = B.simple(Enum.map(codes, &elem(&1, 0)), 64)

          [
            B.header(block == 3, byte_size(words)),
            B.one_of_each(literal, command, distance),
            for(
              {code, extra} <- codes,
              do: [B.symbol(commands, 130), B.symbol(distances, code), extra]
            )
          ]
        end

      stream = B.bytes([B.window(16), blocks])
      assert decode([stream]) == {{:end, 0}, :binary.copy(words, 4)}

      # A word can make the output longer than the limit: the next piece
      # has the rest.
      for limit <- [1, 3, 10] do
        {result, pieces} = pieces([stream], limit)
        assert {result, IO.iodata_to_binary(pieces)} == {{:end, 0}, :binary.copy(words, 4)}
        assert Enum.all?(pieces, &(byte_size(&1) in 1..limit)), "the limit #{limit}"
      end
    end

    test "decodes many meta-blocks with input after each one" do
      pattern = :crypto.strong_rand_bytes(5_000)
      data = :binary.copy(pattern, 40)
      assert decode([encode([data])]) == {{:end, 0}, data}
    end
  end

  # The metadata blocks of 0, 3, and 300 bytes, an uncompressed meta-block,
  # and a metadata block as the last meta-block.
  defp metadata_stream do
    B.bytes([
      B.window(17),
      [{0, 1}, {3, 2}, {0, 1}, {0, 2}, :align],
      [{0, 1}, {3, 2}, {0, 1}, {1, 2}, {2, 8}, :align, {:bytes, "abc"}],
      [{0, 1}, {3, 2}, {0, 1}, {2, 2}, {299, 16}, :align, {:bytes, :binary.copy("m", 300)}],
      [B.header(false, 5, true), :align, {:bytes, "hello"}],
      [{1, 1}, {0, 1}, {3, 2}, {0, 1}, {1, 2}, {0, 8}, :align, {:bytes, "z"}]
    ])
  end

  describe "the decoder refuses data that is not valid" do
    test "a window size of the large window of RFC 9841" do
      assert invalid?([{1, 1}, {0, 3}, {1, 3}, B.last_empty()])
    end

    test "bits that are not zero before a byte boundary" do
      # After the last meta-block, after a metadata header, and before an
      # uncompressed meta-block.
      assert invalid?([B.window(16), B.last_empty(), {1, 5}])
      assert invalid?([B.window(16), {0, 1}, {3, 2}, {0, 1}, {0, 2}, {1, 1}])
      assert invalid?([B.window(16), B.header(false, 1, true), {1, 3}, {:bytes, "a"}])
    end

    test "a metadata header that is not valid" do
      # The reserved bit, and a length with a zero byte at the end.
      assert invalid?([B.window(16), {0, 1}, {3, 2}, {1, 1}, {0, 2}])
      assert invalid?([B.window(16), {0, 1}, {3, 2}, {0, 1}, {2, 2}, {5, 16}])
    end

    test "a length of a meta-block with a zero nibble at the end" do
      assert invalid?([B.window(16), {0, 1}, {1, 2}, {5, 20}])
    end

    test "a simple prefix code with a symbol out of the alphabet, or two equal symbols" do
      start = [B.window(16), B.header(true, 1), B.count(2)]
      {types, _table} = B.simple([0, 1], 4)
      assert invalid?([start, types, {1, 2}, {0, 2}, {30, 5}])
      assert invalid?([start, {1, 2}, {1, 2}, {0, 2}, {0, 2}])
    end

    test "a complex prefix code that is not complete" do
      start = [B.window(16), B.header(true, 1), B.count(2)]
      # The code length code: two lengths of 2.
      assert invalid?([start, {0, 2}, {3, 3}, {3, 3}, List.duplicate({0, 2}, 16)])
      # The code: lengths 1 and 2 for an alphabet of 4 symbols.
      code = B.complex([{1, 1}, {2, 2}, {0, 2}], [{1, 0}, {2, 0}, {0, 0}, {0, 0}])
      assert invalid?([start, code])
      # A repeat of 6 lengths after the first symbol of 4.
      code = B.complex([{1, 1}, {16, 1}], [{1, 0}, {16, 3}], skip: 0)
      assert invalid?([start, code])
    end

    test "a run of zeros that is longer than the context map" do
      {literal, _} = B.simple([0], 256)
      {runs, _} = B.simple([1], 3)

      fields = [
        B.window(16),
        B.header(true, 1),
        B.count(1),
        B.count(1),
        B.count(1),
        {0, 6},
        {0, 2},
        B.count(2),
        {1, 1},
        {0, 4},
        runs,
        List.duplicate({1, 1}, 22),
        literal
      ]

      assert invalid?(fields)
    end

    test "a distance that is not positive" do
      # The first copy has the distance 1. The distance code 4 is then the
      # last distance minus 1.
      {literal, _} = B.simple([?a], 256)
      {command, commands} = B.simple([137, 129], 704)
      {distance, distances} = B.simple([16, 4], 64)

      commands = [
        [B.symbol(commands, 137), B.symbol(distances, 16), {0, 1}],
        [B.symbol(commands, 129), B.symbol(distances, 4)]
      ]

      assert invalid?([B.window(16), meta_block(10, literal, command, distance, commands)])
    end

    test "a command that is longer than the meta-block" do
      {literal, _} = B.simple([?a], 256)
      {distance, distances} = B.simple([16], 64)

      # Three literals in a meta-block of 2 bytes, and 66 literals: the
      # insert length code 14 with 5 extra bits.
      {command, commands} = B.simple([152], 704)
      fields = meta_block(2, literal, command, distance, [B.symbol(commands, 152)])
      assert invalid?([B.window(16), fields])
      {command, commands} = B.simple([304], 704)
      fields = meta_block(2, literal, command, distance, [B.symbol(commands, 304), {0, 5}])
      assert invalid?([B.window(16), fields])
      assert output_before_error([B.window(16), fields]) <= 2

      # A copy of 3 bytes after 1 literal in a meta-block of 3 bytes.
      {command, commands} = B.simple([137], 704)

      fields =
        meta_block(3, literal, command, distance, [
          B.symbol(commands, 137),
          B.symbol(distances, 16),
          {0, 1}
        ])

      assert invalid?([B.window(16), fields])
      assert output_before_error([B.window(16), fields]) <= 3
    end

    test "a reference to the dictionary that is not valid" do
      {literal, _} = B.simple([?a], 256)

      # A word of 4 bytes in a meta-block of 3 bytes, a transform after
      # 120, and a word of 3 bytes.
      for {length, id, copy} <- [{3, 0, 130}, {10, 121 <<< 10, 130}, {10, 0, 129}] do
        {command, commands} = B.simple([copy], 704)
        {code, extra} = B.distance(id + 1)
        {distance, distances} = B.simple([code], 64)

        fields =
          meta_block(length, literal, command, distance, [
            B.symbol(commands, copy),
            B.symbol(distances, code),
            extra
          ])

        assert invalid?([B.window(16), fields])
      end
    end
  end

  # The largest number of bytes that the decoder gives before the error,
  # with the limit 1, with and without 64 bytes after the data.
  defp output_before_error(fields) do
    data = B.bytes(fields)

    for input <- [data, data <> :binary.copy(<<0>>, 64)] do
      {{:error, :invalid}, pieces} = pieces([input], 1)
      IO.iodata_length(pieces)
    end
    |> Enum.max()
  end

  # The data must be invalid also with 64 bytes after it: then the fast
  # loop of the commands decodes it.
  defp invalid?(fields) do
    data = B.bytes(fields)

    Enum.all?([data, data <> :binary.copy(<<0>>, 64)], fn input ->
      elem(decode([input]), 0) == {:error, :invalid}
    end)
  end

  # ---------------------------------------------------------------------------
  # The encoder
  # ---------------------------------------------------------------------------

  describe "the encoder" do
    property "makes a stream that the decoder decodes to the input" do
      check all(
              parts <-
                list_of(
                  one_of([
                    binary(max_length: 3_000),
                    map(integer(1..100_000), &:binary.copy(<<0>>, &1)),
                    map({binary(min_length: 1, max_length: 20), integer(1..500)}, fn {b, n} ->
                      :binary.copy(b, n)
                    end)
                  ]),
                  max_length: 5
                ),
              sizes <- list_of(integer(1..70_000), max_length: 5),
              max_runs: 100
            ) do
        data = IO.iodata_to_binary(parts)
        encoded = encode(split(data, sizes))
        assert decode([encoded]) == {{:end, 0}, data}
      end
    end

    test "makes an empty stream for no input" do
      assert decode([encode([])]) == {{:end, 0}, ""}
      assert decode([encode(["", ""])]) == {{:end, 0}, ""}
    end

    test "uses each cell of the insert-and-copy length codes" do
      # Random literals of each insert length, then a copy of each length
      # from the first part.
      first = :crypto.strong_rand_bytes(3_000)

      parts =
        for insert <- [3, 50, 200, 3_000, 10_000, 30_000], copy <- [5, 40, 1_000] do
          [:crypto.strong_rand_bytes(insert), binary_part(first, 0, copy)]
        end

      data = IO.iodata_to_binary([first | parts])
      assert decode([encode([data])]) == {{:end, 0}, data}
    end

    test "keeps the last distance of the decoder" do
      # The first block has copies at the distance 1000. The second block
      # does not compress, thus it is an uncompressed meta-block, but it has
      # a copy of 6 bytes at the distance 6. The third block starts with a
      # copy at the distance 6, and then compresses: the last distance of
      # the decoder is still 1000.
      pattern = :crypto.strong_rand_bytes(1_000)
      first = binary_part(:binary.copy(pattern, 66), 0, 65_536)
      repeat = :crypto.strong_rand_bytes(6)
      second = :crypto.strong_rand_bytes(65_536 - 12) <> repeat <> repeat
      third = repeat <> :binary.copy("abc", 2_000)
      data = first <> second <> third
      assert decode([encode([data])]) == {{:end, 0}, data}

      # Copies of 79 bytes at the last distance, with one literal between
      # them: the copy length code 16 needs a distance code.
      changed =
        for <<chunk::binary-size(80) <- pattern>>,
          into: <<>>,
          do: binary_part(chunk, 0, 79) <> "!"

      data = pattern <> changed
      assert decode([encode([data])]) == {{:end, 0}, data}
    end

    test "uses the prefix codes of section 3 for each kind of counts" do
      # Four literals with the lengths 1, 2, 3, and 3. Then all the 256
      # bytes once: each code length is 8, and the code length code has one
      # symbol.
      for data <- ["aaaabaacad", :binary.list_to_bin(Enum.shuffle(0..255))] do
        assert decode([encode([data])]) == {{:end, 0}, data}
      end
    end

    test "compresses text, and adds little to data that does not compress" do
      text = :binary.copy("the quick brown fox jumps over the lazy dog, ", 2_000)
      assert byte_size(encode([text])) < div(byte_size(text), 20)

      random = :crypto.strong_rand_bytes(200_000)
      assert byte_size(encode([random])) < 200_000 + 100
    end

    property "gives each insert length and copy length its code of section 5" do
      inserts = elem(Code.eval_string(insert_table()), 0)
      copies = elem(Code.eval_string(copy_table()), 0)

      check all(length <- one_of([integer(0..3_000), integer(0..16_779_333)]), max_runs: 300) do
        {offset, bits} = elem(inserts, Encoder.__insert_code__(length))
        assert length >= offset and length < offset + (1 <<< bits)

        if length >= 2 do
          {offset, bits} = elem(copies, Encoder.__copy_code__(length))
          assert length >= offset and length < offset + (1 <<< bits)
        end
      end
    end

    property "makes complete prefix codes with lengths up to the limit" do
      check all(
              counts <- list_of(integer(1..1_000_000), min_length: 2, max_length: 300),
              limit <- member_of([5, 15]),
              length(counts) <= 1 <<< limit
            ) do
        lengths =
          Encoder.__lengths__(Enum.with_index(counts, fn count, i -> {i, count} end), limit)

        assert length(lengths) == length(counts)
        assert Enum.all?(lengths, fn {_symbol, length} -> length in 1..limit end)

        assert Enum.sum(Enum.map(lengths, fn {_symbol, length} -> 1 <<< (limit - length) end)) ==
                 1 <<< limit
      end
    end
  end

  # The insert length codes and the copy length codes of section 5.
  defp insert_table do
    "{{0, 0}, {1, 0}, {2, 0}, {3, 0}, {4, 0}, {5, 0}, {6, 1}, {8, 1}, {10, 2}, {14, 2}, {18, 3}, {26, 3}, {34, 4}, {50, 4}, {66, 5}, {98, 5}, {130, 6}, {194, 7}, {322, 8}, {578, 9}, {1090, 10}, {2114, 12}, {6210, 14}, {22594, 24}}"
  end

  defp copy_table do
    "{{2, 0}, {3, 0}, {4, 0}, {5, 0}, {6, 0}, {7, 0}, {8, 0}, {9, 0}, {10, 1}, {12, 1}, {14, 2}, {18, 2}, {22, 3}, {30, 3}, {38, 4}, {54, 4}, {70, 5}, {102, 5}, {134, 6}, {198, 7}, {326, 8}, {582, 9}, {1094, 10}, {2118, 24}}"
  end
end
