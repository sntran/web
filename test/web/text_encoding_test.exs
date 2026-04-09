defmodule Web.TextEncodingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Web, only: [await: 1]

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
    assert Uint8Array.to_binary(bytes) == "Hello, 🌍"
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

    assert_raise Web.TypeError, "The encoded data was not valid UTF-8", fn ->
      TextDecoder.decode(decoder, <<0xC3, 0x28>>)
    end
  end

  test "TextDecoder replaces trailing partial UTF-8 when stream is false" do
    decoder = TextDecoder.new()

    assert TextDecoder.decode(decoder, <<0xF0, 0x9F>>) == <<0xEF, 0xBF, 0xBD>>
  end

  test "TextDecoder handles valid complete input in fatal mode and leaves BOM state untouched on empty ignoreBOM stream chunks" do
    decoder = TextDecoder.new("utf-8", %{fatal: true, ignoreBOM: true})

    assert TextDecoder.decode(decoder, "hello") == "hello"
    assert TextDecoder.decode(decoder, "", %{stream: true}) == ""
    assert %{bom_seen: true, carry: ""} = :sys.get_state(decoder.state_pid)
  end

  test "TextDecoder empty decodes exercise fresh BOM state branches" do
    ignore_bom_decoder = TextDecoder.new("utf-8", %{ignoreBOM: true})
    assert TextDecoder.decode(ignore_bom_decoder, "", %{stream: true}) == ""
    assert %{bom_seen: false, carry: ""} = :sys.get_state(ignore_bom_decoder.state_pid)

    decoder = TextDecoder.new()
    assert TextDecoder.decode(decoder, "", %{stream: true}) == ""
    assert %{bom_seen: false, carry: ""} = :sys.get_state(decoder.state_pid)
    assert TextDecoder.decode(decoder, "", %{stream: false}) == ""
    assert %{bom_seen: true, carry: ""} = :sys.get_state(decoder.state_pid)
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
        assert :ok = await(WritableStreamDefaultWriter.write(writer, chunk))
      end)

      assert :ok = await(WritableStreamDefaultWriter.close(writer))
      assert Enum.join(stream.readable, "") == text
    end
  end

  property "fatal decoders reject invalid UTF-8 while non-fatal decoders always return a valid string" do
    check all(binary <- invalid_utf8_binary(), max_runs: 100) do
      fatal_decoder = TextDecoder.new("utf-8", %{fatal: true})
      forgiving_decoder = TextDecoder.new("utf-8", %{fatal: false})

      assert_raise Web.TypeError, "The encoded data was not valid UTF-8", fn ->
        TextDecoder.decode(fatal_decoder, binary)
      end

      result = TextDecoder.decode(forgiving_decoder, binary)
      assert is_binary(result)
      assert String.valid?(result)
    end
  end

  property "ignoreBOM false strips only the initial BOM and ignoreBOM true preserves it" do
    check all(text <- string(:utf8, min_length: 0), max_runs: 100) do
      stripped_decoder = TextDecoder.new("utf-8", %{ignoreBOM: false})
      preserved_decoder = TextDecoder.new("utf-8", %{ignoreBOM: true})
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
      decoder = TextDecoder.new("utf-8", %{ignoreBOM: false})

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

      assert_raise Web.TypeError, "TextDecoder only supports UTF-8", fn ->
        TextDecoder.new(invalid_label)
      end
    end
  end

  test "TextDecoderStream flush emits replacement for trailing partial UTF-8" do
    stream = TextDecoderStream.new()
    writer = WritableStream.get_writer(stream.writable)

    assert :ok = await(WritableStreamDefaultWriter.write(writer, <<0xF0, 0x9F>>))
    assert :ok = await(WritableStreamDefaultWriter.close(writer))
    assert Enum.join(stream.readable, "") == <<0xEF, 0xBF, 0xBD>>
  end

  test "TextDecoderStream with fatal: true errors during flush for trailing partial UTF-8" do
    stream = TextDecoderStream.new("utf-8", %{fatal: true})
    writer = WritableStream.get_writer(stream.writable)

    assert :ok = await(WritableStreamDefaultWriter.write(writer, <<0xF0, 0x9F>>))

    assert %Web.TypeError{message: "The stream is errored."} =
             catch_exit(await(WritableStreamDefaultWriter.close(writer)))
  end

  test "TextEncoderStream encodes written strings into Uint8Array chunks" do
    stream = TextEncoderStream.new()
    writer = WritableStream.get_writer(stream.writable)

    assert :ok = await(WritableStreamDefaultWriter.write(writer, "Hi "))
    assert :ok = await(WritableStreamDefaultWriter.write(writer, "🌍"))
    assert :ok = await(WritableStreamDefaultWriter.close(writer))

    assert Enum.map(stream.readable, &Uint8Array.to_binary/1) == ["Hi ", "🌍"]
  end

  test "TextEncoderStream errors when a non-string chunk is written" do
    stream = TextEncoderStream.new()
    writer = WritableStream.get_writer(stream.writable)

    assert %Web.TypeError{message: "The stream is errored."} =
             catch_exit(await(WritableStreamDefaultWriter.write(writer, 123)))
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

  defp invalid_utf8_label do
    string(:alphanumeric, min_length: 1)
    |> filter(fn label ->
      normalized =
        label
        |> String.trim()
        |> String.downcase()

      normalized not in ["utf-8", "utf8", "unicode-1-1-utf-8"]
    end)
  end
end
