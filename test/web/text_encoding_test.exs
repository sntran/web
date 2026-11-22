defmodule Web.TextEncodingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Web, only: [await: 1]

  alias Web.ArrayBuffer
  alias Web.Response
  alias Web.TextDecoder
  alias Web.TextDecoderStream
  alias Web.TextEncoder
  alias Web.TextEncoderStream
  alias Web.Uint8Array
  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter

  @bom <<0xEF, 0xBB, 0xBF>>
  @utf8_labels ["UTF8", "utf8", "utf-8", "UTF-8", "unicode-1-1-utf-8", " Unicode-1-1-UTF-8 "]

  test "TextEncoder encodes strings into Uint8Array" do
    encoder = TextEncoder.new()
    bytes = TextEncoder.encode(encoder, "Hello, 🌍")

    assert %Uint8Array{} = bytes
    assert to_string(bytes) == "Hello, 🌍"
  end

  test "TextEncoder rejects non-string input" do
    assert_raise Web.TypeError, "TextEncoder.encode input must be a string", fn ->
      TextEncoder.encode(TextEncoder.new(), 123)
    end
  end

  test "TextDecoder rejects non-string labels and invalid decode inputs" do
    assert_raise Web.TypeError, "TextDecoder label must be a string", fn ->
      TextDecoder.new(123)
    end

    assert_raise Web.TypeError, "TextDecoder.decode input must be a binary or Uint8Array", fn ->
      TextDecoder.decode(TextDecoder.new(), 123)
    end
  end

  test "TextDecoder with fatal: true raises on invalid UTF-8" do
    decoder = TextDecoder.new("utf-8", %{fatal: true})

    assert_raise Web.TypeError, "The encoded data was not valid utf-8", fn ->
      TextDecoder.decode(decoder, <<0xC3, 0x28>>)
    end
  end

  test "TextDecoder replaces trailing partial UTF-8 when stream is false" do
    decoder = TextDecoder.new()

    assert TextDecoder.decode(decoder, <<0xF0, 0x9F>>) == <<0xEF, 0xBF, 0xBD>>
  end

  test "TextDecoder handles valid complete input in fatal mode, and starts again after the end of the data" do
    decoder = TextDecoder.new("utf-8", %{fatal: true, ignore_bom: true})

    assert TextDecoder.decode(decoder, "hello") == "hello"
    assert TextDecoder.decode(decoder, "", %{stream: true}) == ""
    assert %{bom_seen: false, carry: ""} = :sys.get_state(decoder.state_pid)
  end

  test "TextDecoder has the option ignore_bom, the snake_case name of ignoreBOM" do
    assert TextDecoder.new("utf-8", ignore_bom: true).ignore_bom
    refute TextDecoder.new("utf-8", %{ignoreBOM: true}).ignore_bom
  end

  test "TextEncoder.encode/1 encodes the empty string, the default input" do
    bytes = TextEncoder.encode(TextEncoder.new())
    assert {bytes.byte_length, to_string(bytes)} == {0, ""}
  end

  test "TextDecoder empty decodes exercise fresh BOM state branches" do
    ignore_bom_decoder = TextDecoder.new("utf-8", %{ignore_bom: true})
    assert TextDecoder.decode(ignore_bom_decoder, "", %{stream: true}) == ""
    assert %{bom_seen: false, carry: ""} = :sys.get_state(ignore_bom_decoder.state_pid)

    decoder = TextDecoder.new()
    assert TextDecoder.decode(decoder, "", %{stream: true}) == ""
    assert %{bom_seen: false, carry: ""} = :sys.get_state(decoder.state_pid)
    # A call with no `stream` option is the end of the data: the decoder
    # starts again.
    assert TextDecoder.decode(decoder, "", %{stream: false}) == ""
    assert %{bom_seen: false, carry: ""} = :sys.get_state(decoder.state_pid)
  end

  test "TextDecoder preserves split three-byte and four-byte prefixes across streamed chunks" do
    decoder = TextDecoder.new()

    assert TextDecoder.decode(decoder, <<0xE2, 0x82>>, %{stream: true}) == ""
    assert TextDecoder.decode(decoder, <<0xAC>>, %{stream: false}) == "€"

    decoder = TextDecoder.new()
    assert TextDecoder.decode(decoder, <<0xF0, 0x9F, 0x8C>>, %{stream: true}) == ""
    assert TextDecoder.decode(decoder, <<0x8D>>, %{stream: false}) == "🌍"
  end

  test "TextDecoder treats non-partial trailing bytes as complete data" do
    decoder = TextDecoder.new()
    assert TextDecoder.decode(decoder, "a", %{stream: true}) == "a"

    assert TextDecoder.decode(decoder, <<0xC3, 0x28>>, %{stream: true}) ==
             <<0xEF, 0xBF, 0xBD, 0x28>>
  end

  test "TextDecoder only holds two-byte partial suffixes when the second byte is a valid continuation" do
    decoder = TextDecoder.new()
    assert TextDecoder.decode(decoder, <<0xE2, 0x82>>, %{stream: true}) == ""
    assert %{carry: <<0xE2, 0x82>>} = :sys.get_state(decoder.state_pid)

    decoder = TextDecoder.new()

    assert TextDecoder.decode(decoder, <<0xE2, 0x28>>, %{stream: true}) ==
             <<0xEF, 0xBF, 0xBD, 0x28>>
  end

  test "TextDecoder treats 0xE0 prefixes as partial only for valid second bytes" do
    decoder = TextDecoder.new()
    assert TextDecoder.decode(decoder, <<0xE0, 0xA0>>, %{stream: true}) == ""
    assert %{carry: <<0xE0, 0xA0>>} = :sys.get_state(decoder.state_pid)

    decoder = TextDecoder.new()

    assert TextDecoder.decode(decoder, <<0xE0, 0x9F>>, %{stream: true}) ==
             <<0xEF, 0xBF, 0xBD, 0xEF, 0xBF, 0xBD>>
  end

  test "TextDecoder treats 0xED prefixes as partial only for valid surrogate-range second bytes" do
    decoder = TextDecoder.new()
    assert TextDecoder.decode(decoder, <<0xED, 0x9F>>, %{stream: true}) == ""
    assert %{carry: <<0xED, 0x9F>>} = :sys.get_state(decoder.state_pid)

    decoder = TextDecoder.new()

    assert TextDecoder.decode(decoder, <<0xED, 0xA0>>, %{stream: true}) ==
             <<0xEF, 0xBF, 0xBD, 0xEF, 0xBF, 0xBD>>
  end

  test "TextDecoder only holds three-byte partial suffixes for valid four-byte prefixes" do
    decoder = TextDecoder.new()
    assert TextDecoder.decode(decoder, <<0xF0, 0x9F, 0x8C>>, %{stream: true}) == ""
    assert %{carry: <<0xF0, 0x9F, 0x8C>>} = :sys.get_state(decoder.state_pid)

    decoder = TextDecoder.new()

    assert TextDecoder.decode(decoder, <<0xF0, 0x28, 0x8C>>, %{stream: true}) ==
             <<0xEF, 0xBF, 0xBD, 0x28, 0xEF, 0xBF, 0xBD>>
  end

  test "TextDecoder carry keeps only the copied partial suffix" do
    decoder = TextDecoder.new()
    large_chunk = IO.iodata_to_binary([:binary.copy("a", 1_000_000), <<0xF0>>])

    assert TextDecoder.decode(decoder, large_chunk, %{stream: true}) ==
             :binary.copy("a", 1_000_000)

    assert %{carry: <<0xF0>>, bom_seen: true} = :sys.get_state(decoder.state_pid)

    :erlang.garbage_collect(decoder.state_pid)
    {:binary, binaries} = :erlang.process_info(decoder.state_pid, :binary)
    refute Enum.any?(binaries, fn {_refc, size, _used} -> size > 1024 end)
  end

  test "Response.text/1 decodes multi-byte codepoints split across stream chunks" do
    chunks = [<<"A", 0xF0, 0x9F>>, <<0x8C, 0x8D, "B">>]
    assert await(Response.text(Response.new(body: chunks))) == "A🌍B"
  end

  property "TextEncoder/TextDecoder round-trip UTF-8 strings exactly" do
    check all(text <- string(:utf8, min_length: 0), max_runs: 100) do
      encoder = TextEncoder.new()
      decoder = TextDecoder.new()

      encoded = TextEncoder.encode(encoder, text)
      assert TextDecoder.decode(decoder, encoded) == text
    end
  end

  property "TextDecoderStream reconstructs text across random byte chunking" do
    check all(
            text <- string(:utf8, min_length: 1),
            chunk_sizes <- list_of(integer(1..4), min_length: 1, max_length: 24),
            max_runs: 100
          ) do
      stream = TextDecoderStream.new()
      writer = WritableStream.get_writer(stream.writable)

      text
      |> split_binary_into_chunks(chunk_sizes)
      |> Enum.each(fn chunk ->
        WritableStreamDefaultWriter.write(writer, chunk)
      end)

      WritableStreamDefaultWriter.close(writer)
      assert Enum.join(stream.readable, "") == text
    end
  end

  property "fatal decoders reject invalid UTF-8 while non-fatal decoders always return a valid string" do
    check all(binary <- invalid_utf8_binary(), max_runs: 100) do
      fatal_decoder = TextDecoder.new("utf-8", %{fatal: true})
      forgiving_decoder = TextDecoder.new("utf-8", %{fatal: false})

      assert_raise Web.TypeError, "The encoded data was not valid utf-8", fn ->
        TextDecoder.decode(fatal_decoder, binary)
      end

      result = TextDecoder.decode(forgiving_decoder, binary)
      assert is_binary(result)
      assert String.valid?(result)
    end
  end

  property "ignoreBOM false strips only the initial BOM and ignoreBOM true preserves it" do
    check all(text <- string(:utf8, min_length: 0), max_runs: 100) do
      stripped_decoder = TextDecoder.new("utf-8", %{ignore_bom: false})
      preserved_decoder = TextDecoder.new("utf-8", %{ignore_bom: true})
      input = @bom <> text

      assert TextDecoder.decode(stripped_decoder, input) == text
      assert TextDecoder.decode(preserved_decoder, input) == @bom <> text
    end
  end

  property "BOM bytes in the middle of a stream are never stripped" do
    check all(
            prefix <- string(:utf8, min_length: 1),
            suffix <- string(:utf8, min_length: 0),
            max_runs: 100
          ) do
      decoder = TextDecoder.new("utf-8", %{ignore_bom: false})

      first = TextDecoder.decode(decoder, prefix, %{stream: true})
      second = TextDecoder.decode(decoder, @bom <> suffix, %{stream: false})

      assert first <> second == prefix <> @bom <> suffix
    end
  end

  property "TextDecoder label normalization accepts UTF-8 aliases and rejects invalid labels" do
    check all(
            valid_label <- member_of(@utf8_labels),
            invalid_label <- invalid_utf8_label(),
            max_runs: 100
          ) do
      assert %TextDecoder{encoding: "utf-8"} = TextDecoder.new(valid_label)

      # The Encoding Standard gives RangeError for a label that is not known.
      assert_raise Web.RangeError, ~r/is not valid/, fn ->
        TextDecoder.new(invalid_label)
      end
    end
  end

  test "TextDecoderStream flush emits replacement for trailing partial UTF-8" do
    stream = TextDecoderStream.new()
    writer = WritableStream.get_writer(stream.writable)

    WritableStreamDefaultWriter.write(writer, <<0xF0, 0x9F>>)
    WritableStreamDefaultWriter.close(writer)
    assert Enum.join(stream.readable, "") == <<0xEF, 0xBF, 0xBD>>
  end

  test "TextDecoderStream with fatal: true errors during flush for trailing partial UTF-8" do
    stream = TextDecoderStream.new("utf-8", %{fatal: true})
    writer = WritableStream.get_writer(stream.writable)

    # A read waits, thus the write and the close can continue.
    reader = Web.ReadableStream.get_reader(stream.readable)
    read = Web.ReadableStreamDefaultReader.read(reader)
    WritableStreamDefaultWriter.write(writer, <<0xF0, 0x9F>>)

    assert %Web.TypeError{} =
             catch_exit(await(WritableStreamDefaultWriter.close(writer)))

    assert %Web.TypeError{} = catch_exit(await(read))
  end

  test "TextEncoderStream encodes written strings into Uint8Array chunks" do
    stream = TextEncoderStream.new()
    writer = WritableStream.get_writer(stream.writable)

    WritableStreamDefaultWriter.write(writer, "Hi ")
    WritableStreamDefaultWriter.write(writer, "🌍")
    WritableStreamDefaultWriter.close(writer)

    assert Enum.map(stream.readable, &to_string/1) == ["Hi ", "🌍"]
  end

  test "TextEncoderStream errors when a chunk with no String.Chars is written" do
    stream = TextEncoderStream.new()
    writer = WritableStream.get_writer(stream.writable)

    # A read waits, thus the transform of the chunk starts.
    reader = Web.ReadableStream.get_reader(stream.readable)
    read = Web.ReadableStreamDefaultReader.read(reader)

    assert %Web.TypeError{} =
             catch_exit(await(WritableStreamDefaultWriter.write(writer, {:no, :string})))

    assert %Web.TypeError{} = catch_exit(await(read))
  end

  describe "the text streams and the Encoding Standard" do
    defp through(chunks, transform) do
      chunks
      |> Web.ReadableStream.from()
      |> Web.ReadableStream.pipe_through(transform)
      |> Enum.to_list()
    end

    test "TextEncoderStream gives no chunk for an empty string, and has the encoding utf-8" do
      stream = TextEncoderStream.new()
      assert stream.encoding == "utf-8"

      assert ["", "a", "", "b", ""] |> through(stream) |> Enum.map(&to_string/1) == [
               "a",
               "b"
             ]
    end

    test "TextEncoderStream joins a code point that is divided between two chunks" do
      chunks = [<<"a", 0xC3>>, <<0xA9, 0xF0, 0x9F>>, <<0x8C, 0x8D, "z">>]

      assert chunks |> through(TextEncoderStream.new()) |> Enum.map_join(&to_string/1) ==
               "aé🌍z"
    end

    test "TextEncoderStream gives U+FFFD for bytes that are not valid, also at the end" do
      assert [<<"a", 0xFF, "b">>]
             |> through(TextEncoderStream.new())
             |> Enum.map_join(&to_string/1) ==
               "a\uFFFDb"

      assert [<<"a", 0xF0, 0x9F>>]
             |> through(TextEncoderStream.new())
             |> Enum.map_join(&to_string/1) ==
               "a\uFFFD"
    end

    test "TextEncoderStream keeps a byte order mark" do
      assert ["\uFEFFa"]
             |> through(TextEncoderStream.new())
             |> Enum.map_join(&to_string/1) ==
               "\uFEFFa"
    end

    test "TextEncoder gives U+FFFD for bytes that are not valid" do
      encoded = TextEncoder.encode(TextEncoder.new(), <<"a", 0xFF, "b">>)
      assert to_string(encoded) == "a\uFFFDb"
    end

    property "TextEncoderStream gives valid UTF-8 for each sequence of binaries" do
      check all(chunks <- list_of(binary(max_length: 8), max_length: 12), max_runs: 100) do
        output =
          chunks |> through(TextEncoderStream.new()) |> Enum.map_join(&to_string/1)

        assert String.valid?(output)
        assert output == chunks |> IO.iodata_to_binary() |> String.replace_invalid()
      end
    end

    test "TextDecoderStream has the attributes encoding, fatal, and ignore_bom" do
      stream = TextDecoderStream.new("UTF8", %{fatal: true})
      assert {stream.encoding, stream.fatal, stream.ignore_bom} == {"utf-8", true, false}

      stream = TextDecoderStream.new("utf-8", ignore_bom: true)
      assert {stream.encoding, stream.fatal, stream.ignore_bom} == {"utf-8", false, true}
    end

    test "TextDecoderStream keeps the byte order mark only with the option ignore_bom" do
      bom = <<0xEF, 0xBB, 0xBF>>
      assert through([bom <> "a"], TextDecoderStream.new()) == ["a"]

      assert through([bom <> "a"], TextDecoderStream.new("utf-8", %{ignore_bom: true})) == [
               "\uFEFFa"
             ]

      assert through([bom <> "a"], TextDecoderStream.new("utf-8", %{ignore_bom: true})) == [
               "\uFEFFa"
             ]
    end

    test "TextDecoderStream accepts each kind of byte chunk" do
      chunks = ["h", Uint8Array.new(Web.ArrayBuffer.new("é")), Web.ArrayBuffer.new("llo")]
      assert chunks |> through(TextDecoderStream.new()) |> Enum.join() == "héllo"
    end

    test "the labels of UTF-8 are accepted, and each other label gives RangeError" do
      for label <- [
            "utf-8",
            "UTF-8",
            " utf8 ",
            "unicode-1-1-utf-8",
            "unicode11utf8",
            "unicode20utf8",
            "x-unicode20utf8"
          ] do
        assert TextDecoder.new(label).encoding == "utf-8"
        assert TextDecoderStream.new(label).encoding == "utf-8"
      end

      for label <- ["no-such-encoding", "", "replacement", "iso-2022-kr", "utf-7"] do
        assert_raise Web.RangeError, fn -> TextDecoder.new(label) end
        assert_raise Web.RangeError, fn -> TextDecoderStream.new(label) end
      end

      assert_raise Web.TypeError, fn -> TextDecoder.new(:utf8) end
    end
  end

  describe "TextDecoder.decode/2 and a detached buffer" do
    test "decodes no bytes, as for a copy of the bytes of WebIDL" do
      view = Uint8Array.from("abc")
      buffer = ArrayBuffer.new("def")
      _moved = ArrayBuffer.transfer(view.buffer)
      _moved = ArrayBuffer.transfer(buffer)

      decoder = TextDecoder.new()
      assert TextDecoder.decode(decoder, view) == ""
      assert TextDecoder.decode(decoder, buffer) == ""
    end
  end

  describe "TextDecoder.decode/1 and no input" do
    test "decodes no bytes, and a call with no stream option ends the stream" do
      decoder = TextDecoder.new()
      assert TextDecoder.decode(decoder) == ""

      assert TextDecoder.decode(decoder, <<0xC9>>, %{stream: true}) == ""
      assert TextDecoder.decode(decoder) == "\uFFFD"

      assert TextDecoder.decode(decoder, <<0xC9>>, %{stream: true}) == ""
      assert TextDecoder.decode(decoder, nil) == "\uFFFD"

      assert TextDecoder.decode(decoder, <<0xC9>>, %{stream: true}) == ""
      assert TextDecoder.decode(decoder, nil, %{}) == "\uFFFD"

      # With stream: true, a call with no input keeps the bytes.
      assert TextDecoder.decode(decoder, <<0xC3>>, %{stream: true}) == ""
      assert TextDecoder.decode(decoder, nil, %{stream: true}) == ""
      assert TextDecoder.decode(decoder, <<0xA9>>) == "\u00E9"
    end

    test "raises TypeError with the option fatal for bytes that are not complete, and starts again" do
      for label <- ["utf-8", "utf-16le", "utf-16be"] do
        decoder = TextDecoder.new(label, %{fatal: true})
        assert TextDecoder.decode(decoder, <<0xF0>>, %{stream: true}) == ""
        assert_raise Web.TypeError, fn -> TextDecoder.decode(decoder) end
        assert TextDecoder.decode(decoder) == ""
      end
    end

    property "gives the text of one call, when a call with no input ends the stream" do
      check all(
              label <- member_of(Web.Encoding.supported()),
              bytes <- binary(max_length: 16),
              sizes <- list_of(integer(1..4), min_length: 1, max_length: 6)
            ) do
        decoder = TextDecoder.new(label)
        chunks = split_binary_into_chunks(bytes, sizes)
        parts = Enum.map(chunks, &TextDecoder.decode(decoder, &1, %{stream: true}))

        assert IO.iodata_to_binary([parts, TextDecoder.decode(decoder)]) ==
                 TextDecoder.decode(TextDecoder.new(label), bytes)
      end
    end
  end

  describe "TextEncoder.encode_into/3" do
    # A view of `length` bytes at `offset`, in a buffer with the byte
    # `filler` in each place.
    defp view(filler, offset, length, size) do
      <<filler>> |> :binary.copy(size) |> ArrayBuffer.new() |> Uint8Array.new(offset, length)
    end

    test "follows the tests of the Standard" do
      for {source, read, length, written} <- [
            {"Hi", 0, 0, ""},
            {"A", 1, 10, "A"},
            {"\u{1D306}", 2, 4, <<0xF0, 0x9D, 0x8C, 0x86>>},
            {"\u{1D306}A", 0, 3, ""},
            {"\uFFFDA\uFFFDA\u00A5Hi", 5, 10, "\uFFFDA\uFFFDA\u00A5"},
            {"A\uFFFD", 2, 4, "A\uFFFD"},
            {"\u00A5\u00A5", 2, 4, "\u00A5\u00A5"}
          ],
          {offset, extra} <- [{0, 0}, {4, 10}],
          filler <- [0, 0x80] do
        destination = view(filler, offset, length, length + extra)
        {result, changed} = TextEncoder.encode_into(TextEncoder.new(), source, destination)

        assert result == %{read: read, written: byte_size(written)}
        assert {changed.byte_offset, changed.byte_length} == {offset, length}
        before = :binary.copy(<<filler>>, offset)
        rest = :binary.copy(<<filler>>, length + extra - offset - byte_size(written))
        assert to_string(changed.buffer) == before <> written <> rest
      end
    end

    property "writes the longest start of the UTF-8 form that fits, and no other byte" do
      check all(
              source <- string(:utf8, max_length: 12),
              filler <- integer(0..255),
              offset <- integer(0..4),
              length <- integer(0..24),
              tail <- integer(0..4)
            ) do
        destination = view(filler, offset, length, offset + length + tail)
        {result, changed} = TextEncoder.encode_into(TextEncoder.new(), source, destination)

        # The longest start of whole characters with no more than `length` bytes.
        expected =
          source
          |> String.to_charlist()
          |> Enum.scan("", &(&2 <> <<&1::utf8>>))
          |> Enum.filter(&(byte_size(&1) <= length))
          |> List.last("")

        units = div(byte_size(:unicode.characters_to_binary(expected, :utf8, :utf16)), 2)
        assert result == %{read: units, written: byte_size(expected)}
        assert {changed.byte_offset, changed.byte_length} == {offset, length}

        assert to_string(changed.buffer) ==
                 :binary.copy(<<filler>>, offset) <>
                   expected <> :binary.copy(<<filler>>, length - byte_size(expected) + tail)
      end
    end

    test "gives U+FFFD for bytes that are not valid UTF-8" do
      {result, changed} =
        TextEncoder.encode_into(TextEncoder.new(), <<"a", 0xFF, "b">>, view(0, 0, 6, 6))

      assert result == %{read: 3, written: 5}
      assert to_string(changed) == <<"a\uFFFDb", 0>>
    end

    test "writes no byte into a detached destination" do
      buffer = ArrayBuffer.new("abc")
      destination = Uint8Array.new(buffer)
      _moved = ArrayBuffer.transfer(buffer)

      assert TextEncoder.encode_into(TextEncoder.new(), "", destination) ==
               {%{read: 0, written: 0}, destination}

      assert TextEncoder.encode_into(TextEncoder.new(), "test", destination) ==
               {%{read: 0, written: 0}, destination}
    end

    test "raises TypeError for a source that is not a string, or a destination that is not a Uint8Array" do
      assert_raise Web.TypeError, "TextEncoder.encodeInto destination must be a Uint8Array", fn ->
        TextEncoder.encode_into(TextEncoder.new(), "a", "destination")
      end

      assert_raise Web.TypeError, "TextEncoder.encodeInto destination must be a Uint8Array", fn ->
        TextEncoder.encode_into(TextEncoder.new(), "a", ArrayBuffer.new(4))
      end

      assert_raise Web.TypeError, "TextEncoder.encodeInto source must be a string", fn ->
        TextEncoder.encode_into(TextEncoder.new(), 1, view(0, 0, 4, 4))
      end
    end
  end

  defp split_binary_into_chunks(binary, sizes) do
    do_split_binary_into_chunks(binary, sizes, sizes, [])
  end

  defp do_split_binary_into_chunks(<<>>, _remaining_sizes, _all_sizes, acc), do: Enum.reverse(acc)

  defp do_split_binary_into_chunks(binary, [], all_sizes, acc) do
    do_split_binary_into_chunks(binary, all_sizes, all_sizes, acc)
  end

  defp do_split_binary_into_chunks(binary, [size | rest], all_sizes, acc) do
    chunk_size = min(size, byte_size(binary))
    chunk = binary_part(binary, 0, chunk_size)
    remainder = binary_part(binary, chunk_size, byte_size(binary) - chunk_size)
    do_split_binary_into_chunks(remainder, rest, all_sizes, [chunk | acc])
  end

  defp invalid_utf8_binary do
    one_of([
      constant(<<0x80>>),
      constant(<<0xC3, 0x28>>),
      constant(<<0xE2, 0x28, 0xA1>>),
      constant(<<0xF0, 0x28, 0x8C, 0xBC>>),
      constant(<<0xF0>>),
      constant(<<0xE2, 0x82>>),
      bind(string(:utf8, min_length: 0), fn prefix ->
        bind(member_of([<<0x80>>, <<0xC3, 0x28>>, <<0xF0>>, <<0xE2, 0x82>>]), fn invalid ->
          constant(prefix <> invalid)
        end)
      end)
    ])
  end

  # A label that the Encoding Standard does not have.
  defp invalid_utf8_label do
    filter(string(:alphanumeric, min_length: 1), &(Web.Encoding.get(&1) == :error))
  end
end
