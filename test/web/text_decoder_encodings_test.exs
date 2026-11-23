defmodule Web.TextDecoderEncodingsTest do
  # The encodings of `Web.TextDecoder` other than UTF-8: UTF-16, the
  # single-byte encodings, and x-user-defined. See also
  # `Web.TextDecoderMultiByteTest`.
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Web

  alias Web.Encoding

  @single_byte ~w[
    ibm866 iso-8859-2 iso-8859-3 iso-8859-4 iso-8859-5 iso-8859-6 iso-8859-7
    iso-8859-8 iso-8859-8-i iso-8859-10 iso-8859-13 iso-8859-14 iso-8859-15
    iso-8859-16 koi8-r koi8-u macintosh windows-874 windows-1250 windows-1251
    windows-1252 windows-1253 windows-1254 windows-1255 windows-1256
    windows-1257 windows-1258 x-mac-cyrillic
  ]

  defp decode(label, bytes, options \\ %{}) do
    TextDecoder.decode(TextDecoder.new(label, options), bytes)
  end

  # Decodes the chunks with the option `stream`, and then ends the data.
  defp decode_stream(label, chunks, options \\ %{}) do
    decoder = TextDecoder.new(label, options)
    parts = Enum.map(chunks, &TextDecoder.decode(decoder, &1, %{stream: true}))
    IO.iodata_to_binary([parts, TextDecoder.decode(decoder, "")])
  end

  defp utf16(text, endian), do: :unicode.characters_to_binary(text, :utf8, {:utf16, endian})

  # Divides a binary into chunks at positions from the generator.
  defp divide(binary, []), do: [binary]

  defp divide(binary, [size | sizes]) do
    size = min(size, byte_size(binary))
    <<head::binary-size(^size), rest::binary>> = binary
    [head | divide(rest, sizes)]
  end

  describe "the labels" do
    test "give the encodings of the Encoding Standard" do
      for {label, encoding} <- [
            {"latin1", "windows-1252"},
            {"ascii", "windows-1252"},
            {"iso-8859-1", "windows-1252"},
            {"l1", "windows-1252"},
            {"x-cp1252", "windows-1252"},
            {"iso-8859-9", "windows-1254"},
            {"iso-8859-11", "windows-874"},
            {"tis-620", "windows-874"},
            {"utf-16", "utf-16le"},
            {"ucs-2", "utf-16le"},
            {"unicode", "utf-16le"},
            {"unicodefffe", "utf-16be"},
            {"866", "ibm866"},
            {"koi8", "koi8-r"},
            {"koi8-ru", "koi8-u"},
            {"x-mac-roman", "macintosh"},
            {"x-mac-ukrainian", "x-mac-cyrillic"},
            {"logical", "iso-8859-8-i"},
            {"visual", "iso-8859-8"},
            {"x-user-defined", "x-user-defined"}
          ] do
        assert TextDecoder.new(label).encoding == encoding
        assert TextDecoderStream.new(label).encoding == encoding
      end
    end

    test "has a decoder for each encoding of the Standard other than replacement" do
      multi_byte = ~w[gbk gb18030 big5 euc-jp iso-2022-jp shift_jis euc-kr]
      expected = ["utf-8", "utf-16le", "utf-16be", "x-user-defined"] ++ @single_byte ++ multi_byte
      assert Enum.sort(Encoding.supported()) == Enum.sort(expected)

      for encoding <- expected do
        assert TextDecoder.new(encoding).encoding == encoding
      end
    end

    property "ignore ASCII whitespace at the two ends, and the case of ASCII letters" do
      whitespace = string([?\t, ?\n, ?\f, ?\r, ?\s], max_length: 3)

      check all(
              encoding <- member_of(Encoding.supported()),
              upper <- list_of(boolean(), length: byte_size(encoding)),
              before <- whitespace,
              after_label <- whitespace
            ) do
        label =
          encoding
          |> String.to_charlist()
          |> Enum.zip(upper)
          |> Enum.map(fn {char, upper?} -> if upper?, do: :string.to_upper(char), else: char end)
          |> List.to_string()

        assert TextDecoder.new(before <> label <> after_label).encoding == encoding
      end
    end

    test "do not ignore whitespace that is not ASCII, or letters that are not ASCII" do
      # U+00A0, U+2028, and U+212A (the Kelvin sign, which has the lowercase "k").
      for label <- ["\u00A0utf-8", "utf-8\u2028", "\u212Aoi8-r", "utf 8", "utf\t8"] do
        assert_raise Web.RangeError, ~r/is not valid/, fn -> TextDecoder.new(label) end
      end
    end

    test "give RangeError for each label of replacement" do
      for label <- ~w[replacement csiso2022kr hz-gb-2312 iso-2022-cn iso-2022-cn-ext iso-2022-kr] do
        assert_raise Web.RangeError, ~r/is not valid/, fn -> TextDecoder.new(label) end
      end
    end
  end

  describe "a single-byte encoding" do
    test "decodes known text" do
      for {label, bytes, text} <- [
            {"windows-1252", <<0x63, 0x61, 0x66, 0xE9>>, "café"},
            {"windows-1252", <<0x80, 0x9F>>, "€Ÿ"},
            {"windows-1251", <<0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2>>, "Привет"},
            {"koi8-r", <<0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4>>, "Привет"},
            {"koi8-u", <<0xA4, 0xA6, 0xA7>>, "єії"},
            {"ibm866", <<0x8F, 0xE0, 0xA8, 0xA2, 0xA5, 0xE2>>, "Привет"},
            {"iso-8859-5", <<0xBF, 0xE0, 0xD8, 0xD2, 0xD5, 0xE2>>, "Привет"},
            {"x-mac-cyrillic", <<0x8F, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2>>, "Привет"},
            {"iso-8859-2", <<0xB1, 0xE6, 0xEA>>, "ąćę"},
            {"windows-1250", <<0xB9, 0xE6, 0xEA>>, "ąćę"},
            {"iso-8859-7", <<0xE1, 0xE2, 0xE3>>, "αβγ"},
            {"windows-1253", <<0xE1, 0xE2, 0xE3>>, "αβγ"},
            {"iso-8859-15", <<0xA4>>, "€"},
            {"iso-8859-8", <<0xE0, 0xE1>>, "אב"},
            {"windows-1255", <<0xE0, 0xE1>>, "אב"},
            {"windows-1256", <<0xC7, 0xC8>>, "اب"},
            {"iso-8859-6", <<0xC7, 0xC8>>, "اب"},
            {"windows-874", <<0xA1, 0xA2>>, "กข"},
            {"windows-1254", <<0xF0, 0xFD, 0xFE>>, "ğış"},
            {"windows-1257", <<0xE0, 0xE8>>, "ąč"},
            {"windows-1258", <<0xF0, 0xFE>>, "đ₫"},
            {"macintosh", <<0x8E, 0xDB>>, "é€"}
          ] do
        assert decode(label, bytes) == text
        assert decode(label, Uint8Array.from(bytes)) == text
      end
    end

    test "gives the C1 control for a byte of windows-1252 that has no character" do
      assert decode("windows-1252", <<0x81, 0x8D, 0x8F, 0x90, 0x9D>>) ==
               <<0x81::utf8, 0x8D::utf8, 0x8F::utf8, 0x90::utf8, 0x9D::utf8>>
    end

    test "agrees with Latin-1 for the bytes 0xA0 to 0xFF of windows-1252" do
      bytes = :binary.list_to_bin(Enum.to_list(0xA0..0xFF))
      assert decode("latin1", bytes) == :unicode.characters_to_binary(bytes, :latin1)
    end

    test "gives U+FFFD, or TypeError with the option fatal, for a byte with no code point" do
      for {label, byte} <- [
            {"iso-8859-3", 0xA5},
            {"iso-8859-6", 0xA1},
            {"iso-8859-7", 0xAE},
            {"iso-8859-8", 0xA1},
            {"windows-874", 0xDB},
            {"windows-1253", 0xAA},
            {"windows-1255", 0xD9},
            {"windows-1257", 0xA1}
          ] do
        assert decode(label, <<?a, byte, ?b>>) == "a\uFFFDb"

        assert_raise TypeError, "The encoded data was not valid #{label}", fn ->
          decode(label, <<?a, byte, ?b>>, %{fatal: true})
        end
      end
    end

    test "gives the same text for iso-8859-8 and iso-8859-8-i" do
      bytes = :binary.list_to_bin(Enum.to_list(0x00..0xFF))
      assert decode("iso-8859-8-i", bytes) == decode("iso-8859-8", bytes)
    end

    test "does not remove a byte order mark" do
      assert decode("windows-1252", <<0xEF, 0xBB, 0xBF, ?a>>) == "ï»¿a"
    end

    property "gives one code point for each byte, and ASCII with no change" do
      check all(
              encoding <- member_of(@single_byte),
              bytes <- binary(),
              ascii <- string(:ascii)
            ) do
        text = decode(encoding, bytes)
        assert String.valid?(text)
        assert length(String.to_charlist(text)) == byte_size(bytes)
        assert decode(encoding, ascii) == ascii
      end
    end

    property "gives the same text for each division of the bytes into chunks" do
      check all(
              encoding <- member_of(["x-user-defined" | @single_byte]),
              bytes <- binary(),
              sizes <- list_of(integer(0..5), max_length: 8)
            ) do
        assert decode_stream(encoding, divide(bytes, sizes)) == decode(encoding, bytes)
      end
    end
  end

  describe "x-user-defined" do
    test "gives ASCII with no change, and the Private Use Area for each other byte" do
      assert decode("x-user-defined", "abc") == "abc"
      assert decode("x-user-defined", <<0x80, 0xFF>>) == <<0xF780::utf8, 0xF7FF::utf8>>
      assert decode("x-user-defined", <<0x80>>, %{fatal: true}) == <<0xF780::utf8>>
    end
  end

  describe "UTF-16" do
    property "decodes each string, for the two byte orders" do
      check all(text <- string(:utf8), endian <- member_of([:little, :big])) do
        label = if endian == :little, do: "utf-16le", else: "utf-16be"
        # A string that starts with U+FEFF would lose it as a byte order mark.
        text = String.trim_leading(text, "\uFEFF")

        assert decode(label, utf16(text, endian)) == text
        assert decode(label, utf16(text, endian), %{fatal: true}) == text
      end
    end

    property "gives the same text for each division of the bytes into chunks" do
      check all(
              text <- string(:utf8),
              endian <- member_of([:little, :big]),
              sizes <- list_of(integer(0..5), max_length: 12),
              fatal <- boolean()
            ) do
        label = if endian == :little, do: "utf-16le", else: "utf-16be"
        text = String.trim_leading(text, "\uFEFF")
        chunks = divide(utf16(text, endian), sizes)

        assert decode_stream(label, chunks, %{fatal: fatal}) == text
      end
    end

    property "gives valid text, and the same text for each division, for bytes that are not valid" do
      check all(
              bytes <- binary(),
              label <- member_of(["utf-16le", "utf-16be"]),
              sizes <- list_of(integer(0..5), max_length: 8)
            ) do
        text = decode(label, bytes)
        assert String.valid?(text)
        assert decode_stream(label, divide(bytes, sizes)) == text
      end
    end

    test "removes one byte order mark at the start, unless the option ignore_bom is set" do
      for {label, bom, a} <- [
            {"utf-16le", <<0xFF, 0xFE>>, <<?a, 0>>},
            {"utf-16be", <<0xFE, 0xFF>>, <<0, ?a>>}
          ] do
        assert decode(label, bom <> a) == "a"
        assert decode(label, bom <> bom <> a) == "\uFEFFa"
        assert decode(label, a <> bom) == "a\uFEFF"
        assert decode(label, bom <> a, %{ignore_bom: true}) == "\uFEFFa"

        # The mark can be divided between two chunks.
        <<first, second>> = bom
        assert decode_stream(label, [<<first>>, <<second>>, a]) == "a"
      end

      # The mark of the other byte order is not a mark.
      assert decode("utf-16le", <<0xFE, 0xFF>>) == "\uFFFE"
    end

    test "removes the byte order mark again after the end of the data" do
      decoder = TextDecoder.new("utf-16le")
      bytes = <<0xFF, 0xFE, ?a, 0>>

      assert TextDecoder.decode(decoder, bytes) == "a"
      assert TextDecoder.decode(decoder, bytes) == "a"
      assert TextDecoder.decode(decoder, bytes, %{stream: true}) == "a"
      assert TextDecoder.decode(decoder, bytes, %{stream: true}) == "\uFEFFa"
      assert TextDecoder.decode(decoder, "") == ""
      assert TextDecoder.decode(decoder, bytes) == "a"
    end

    test "gives U+FFFD for a surrogate with no pair, as the tests of the Standard" do
      for {bytes, text} <- [
            # A lead surrogate only, and a trail surrogate only.
            {<<0x00, 0xD8>>, "\uFFFD"},
            {<<0x00, 0xDC>>, "\uFFFD"},
            # A lead or a trail surrogate, and then U+0000.
            {<<0x00, 0xD8, 0x00, 0x00>>, "\uFFFD\u0000"},
            {<<0x00, 0xDC, 0x00, 0x00>>, "\uFFFD\u0000"},
            # A trail surrogate before a lead surrogate.
            {<<0x00, 0xDC, 0x00, 0xD8>>, "\uFFFD\uFFFD"},
            # Two lead surrogates, and then a trail surrogate: one error, one pair.
            {<<0x00, 0xD8, 0x3D, 0xD8, 0x00, 0xDE>>, "\uFFFD😀"},
            # A byte with no pair, also after a lead surrogate: one error.
            {<<?a, 0, 0x00>>, "a\uFFFD"},
            {<<?a, 0, 0x00, 0xD8, 0x00>>, "a\uFFFD"}
          ] do
        assert decode("utf-16le", bytes) == text
        assert decode_stream("utf-16le", for(<<byte <- bytes>>, do: <<byte>>)) == text

        assert_raise TypeError, ~r/^The encoded data was not valid utf-16/, fn ->
          decode("utf-16le", bytes, %{fatal: true})
        end
      end
    end

    test "gives TypeError with the option fatal for the two byte orders" do
      assert_raise TypeError, "The encoded data was not valid utf-16be", fn ->
        decode("utf-16be", <<0xDC, 0x00, 0x00, ?a>>, %{fatal: true})
      end

      assert_raise TypeError, "The encoded data was not valid utf-16le", fn ->
        decode("utf-16le", <<0x00, 0xDC, ?a, 0x00>>, %{fatal: true})
      end
    end

    test "follows the test of the Standard for the option fatal with streams" do
      decoder = TextDecoder.new("utf-16le", %{fatal: true})
      odd = <<0x00>>
      even = <<0x00, 0x00>>

      assert TextDecoder.decode(decoder, odd, %{stream: true}) == ""
      assert TextDecoder.decode(decoder, odd) == "\u0000"

      assert TextDecoder.decode(decoder, even, %{stream: true}) == "\u0000"
      assert_raise TypeError, fn -> TextDecoder.decode(decoder, odd) end

      assert TextDecoder.decode(decoder, odd, %{stream: true}) == ""
      assert_raise TypeError, fn -> TextDecoder.decode(decoder, even) end

      assert TextDecoder.decode(decoder, even, %{stream: true}) == "\u0000"
      assert TextDecoder.decode(decoder, even) == "\u0000"
    end
  end

  describe "TextDecoderStream" do
    test "decodes the chunks of each encoding, and joins a character that is divided" do
      for {label, bytes, text} <- [
            {"utf-16le", utf16("héllo 😀", :little), "héllo 😀"},
            {"utf-16be", <<0xFE, 0xFF>> <> utf16("héllo 😀", :big), "héllo 😀"},
            {"windows-1251", <<0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2>>, "Привет"}
          ] do
        chunks = for <<byte <- bytes>>, do: Uint8Array.from(<<byte>>)

        result =
          chunks
          |> ReadableStream.from()
          |> ReadableStream.pipe_through(TextDecoderStream.new(label))
          |> Enum.join()

        assert result == text
      end
    end

    test "puts the stream in the errored state for data that is not valid, with the option fatal" do
      stream =
        [<<0x00, 0xD8>>]
        |> ReadableStream.from()
        |> ReadableStream.pipe_through(TextDecoderStream.new("utf-16le", %{fatal: true}))

      assert %TypeError{} = catch_error(Enum.to_list(stream))
    end
  end
end
