defmodule Web.TextDecoderMultiByteTest do
  # The multi-byte encodings of `Web.TextDecoder`: gb18030 and GBK, Big5,
  # EUC-JP, ISO-2022-JP, Shift_JIS, and EUC-KR.
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Web

  alias Web.Encoding.Indexes

  @encodings ~w[gbk gb18030 big5 euc-jp iso-2022-jp shift_jis euc-kr]

  defp decode(label, bytes, options \\ %{}) do
    TextDecoder.decode(TextDecoder.new(label, options), bytes)
  end

  # Decodes the chunks with the option `stream`, and then ends the data.
  defp decode_stream(label, chunks, options \\ %{}) do
    decoder = TextDecoder.new(label, options)
    parts = Enum.map(chunks, &TextDecoder.decode(decoder, &1, %{stream: true}))
    IO.iodata_to_binary([parts, TextDecoder.decode(decoder)])
  end

  # The text, or `:error` for `Web.TypeError`.
  defp result(fun) do
    fun.()
  rescue
    TypeError -> :error
  end

  defp divide(binary, []), do: [binary]

  defp divide(binary, [size | sizes]) do
    size = min(size, byte_size(binary))
    <<head::binary-size(^size), rest::binary>> = binary
    [head | divide(rest, sizes)]
  end

  # Bytes with many lead bytes, trail bytes, and escape sequences.
  defp bytes do
    special =
      member_of(
        [0x1B, 0x24, 0x28, 0x30, 0x39, 0x40, 0x42, 0x49, 0x4A, 0x5C, 0x7E, 0x80] ++
          [0x81, 0x8E, 0x8F, 0xA1, 0xA2, 0xB0, 0xDF, 0xE0, 0xF0, 0xFE, 0xFF]
      )

    [special, integer(0..255)]
    |> one_of()
    |> list_of(max_length: 24)
    |> map(&:binary.list_to_bin/1)
  end

  defp hash(lines) do
    :sha256 |> :crypto.hash(lines) |> Base.encode16(case: :lower)
  end

  describe "the indexes" do
    # The SHA-256 hash of the lines "pointer code point" of each pointer with
    # a code point. The hashes come from the files
    # https://encoding.spec.whatwg.org/index-<name>.txt with the date
    # 2024-09-18, with a tool that is not this library.
    test "have the code points of the index files of the Standard" do
      for {name, index, count, expected} <- [
            {"gb18030", &Indexes.gb18030/1, 23_940,
             "3af234429c1c730052b00d43c2231a9f66a5eacf96e8b651279833c632d6b037"},
            {"big5", &Indexes.big5/1, 18_590,
             "9dc1cd2bca5d54a934541f0941ad206524077446964d8750355b61f83181c0fe"},
            {"jis0208", &Indexes.jis0208/1, 7_724,
             "d7d155dd3a24dac9c122d69e9c2b1e64e7bd934d9532fa27675b0f813aac8d21"},
            {"jis0212", &Indexes.jis0212/1, 6_067,
             "e11d762d8eb2fbc182cb8f28c914a15e04a2605cea76955fd2b2863180687ce0"},
            {"euc-kr", &Indexes.euc_kr/1, 17_048,
             "e05304009fa6956bacd721e4328cac6534e1947cbd624837d1f23ce14845e16f"}
          ] do
        lines =
          for pointer <- 0..30_000,
              code_point = index.(pointer),
              do: "#{pointer} #{Integer.to_string(code_point, 16)}\n"

        assert {name, length(lines)} == {name, count}
        assert {name, hash(lines)} == {name, expected}
      end
    end

    test "give the code points of index gb18030 ranges" do
      lines =
        for pointer <- 0..39_419,
            do: "#{pointer} #{Integer.to_string(Indexes.gb18030_ranges(pointer), 16)}\n"

      assert hash(lines) == "5f907d92e1d700c571b085b8a944ce5809b316d14f2cbceb236b43f8ddf0f68d"
      assert Indexes.gb18030_ranges(7457) == 0xE7C7
      assert Indexes.gb18030_ranges(189_000) == 0x10000
      assert Indexes.gb18030_ranges(1_237_575) == 0x10FFFF

      for pointer <- [39_420, 188_999, 1_237_576] do
        assert Indexes.gb18030_ranges(pointer) == nil
      end
    end
  end

  describe "the labels" do
    test "give the multi-byte encodings" do
      for {label, encoding} <- [
            {"gb2312", "gbk"},
            {"chinese", "gbk"},
            {"x-gbk", "gbk"},
            {"GB18030", "gb18030"},
            {"big5-hkscs", "big5"},
            {"cn-big5", "big5"},
            {"x-euc-jp", "euc-jp"},
            {"csiso2022jp", "iso-2022-jp"},
            {"sjis", "shift_jis"},
            {"windows-31j", "shift_jis"},
            {"ms932", "shift_jis"},
            {"korean", "euc-kr"},
            {"windows-949", "euc-kr"}
          ] do
        assert TextDecoder.new(label).encoding == encoding
        assert TextDecoderStream.new(label).encoding == encoding
      end
    end
  end

  describe "each multi-byte encoding" do
    test "decodes known text, also with the option fatal" do
      for {label, bytes, text} <- [
            {"gbk", <<0xD6, 0xD0, 0xCE, 0xC4>>, "中文"},
            {"gb18030", <<0xD6, 0xD0, 0xCE, 0xC4>>, "中文"},
            {"big5", <<0xA4, 0xA4, 0xA4, 0xE5>>, "中文"},
            {"euc-jp", <<0xC6, 0xFC, 0xCB, 0xDC, 0xB8, 0xEC>>, "日本語"},
            {"shift_jis", <<0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA>>, "日本語"},
            {"iso-2022-jp", <<0x1B, ?$, ?B, 0x46, 0x7C, 0x4B, 0x5C, 0x38, 0x6C, 0x1B, ?(, ?B>>,
             "日本語"},
            {"euc-kr", <<0xC7, 0xD1, 0xB1, 0xB9, 0xBE, 0xEE>>, "한국어"}
          ] do
        assert decode(label, "a" <> bytes <> "b") == "a" <> text <> "b"
        assert decode(label, Uint8Array.from(bytes), %{fatal: true}) == text
      end
    end

    property "gives ASCII with no change, except the escape and shift bytes of ISO-2022-JP" do
      check all(encoding <- member_of(@encodings), ascii <- string(:ascii)) do
        ascii =
          if encoding == "iso-2022-jp",
            do: String.replace(ascii, ["\x0E", "\x0F", "\e"], ""),
            else: ascii

        assert decode(encoding, ascii, %{fatal: true}) == ascii
      end
    end

    property "gives valid text, and the same text for each division of the bytes into chunks" do
      check all(
              encoding <- member_of(@encodings),
              bytes <- bytes(),
              sizes <- list_of(integer(0..4), max_length: 10)
            ) do
        text = decode(encoding, bytes)
        assert String.valid?(text)
        assert decode_stream(encoding, divide(bytes, sizes)) == text
      end
    end

    property "with the option fatal, gives the text or TypeError, for each division of the bytes" do
      check all(
              encoding <- member_of(@encodings),
              bytes <- bytes(),
              sizes <- list_of(integer(0..4), max_length: 10)
            ) do
        fatal = result(fn -> decode(encoding, bytes, %{fatal: true}) end)
        assert fatal in [decode(encoding, bytes), :error]

        assert result(fn -> decode_stream(encoding, divide(bytes, sizes), %{fatal: true}) end) ==
                 fatal
      end
    end

    test "gives U+FFFD for a lead byte at the end of the data, and keeps it with stream: true" do
      for {encoding, lead, trail, text} <- [
            {"gb18030", <<0x81>>, <<0x40>>, "丂"},
            {"gb18030", <<0x81, 0x30>>, <<0x81, 0x30>>, "\u0080"},
            {"gb18030", <<0x81, 0x30, 0x81>>, <<0x30>>, "\u0080"},
            {"big5", <<0xA4>>, <<0xA4>>, "中"},
            {"euc-jp", <<0x8F>>, <<0xA2, 0xAF>>, "\u02D8"},
            {"euc-jp", <<0x8F, 0xA2>>, <<0xAF>>, "\u02D8"},
            {"euc-jp", <<0x8E>>, <<0xB1>>, "\uFF71"},
            {"iso-2022-jp", <<0x1B, ?$, ?B, 0x46>>, <<0x7C>>, "日"},
            {"shift_jis", <<0x93>>, <<0xFA>>, "日"},
            {"euc-kr", <<0xC7>>, <<0xD1>>, "한"}
          ] do
        assert decode(encoding, lead) == "\uFFFD"

        assert_raise TypeError, "The encoded data was not valid #{encoding}", fn ->
          decode(encoding, lead, %{fatal: true})
        end

        decoder = TextDecoder.new(encoding, %{fatal: true})
        assert TextDecoder.decode(decoder, lead, %{stream: true}) == ""
        assert TextDecoder.decode(decoder, "", %{stream: true}) == ""
        assert TextDecoder.decode(decoder, trail) == text

        decoder = TextDecoder.new(encoding)
        assert TextDecoder.decode(decoder, lead, %{stream: true}) == ""
        assert TextDecoder.decode(decoder) == "\uFFFD"
        # The end of the data starts a new decoder.
        assert TextDecoder.decode(decoder, trail) != text
      end
    end

    test "gives the ASCII byte after a lead byte back to the data, after U+FFFD" do
      for {encoding, lead} <- [
            {"gbk", 0x81},
            {"gb18030", 0x81},
            {"big5", 0x81},
            {"euc-jp", 0xA1},
            {"shift_jis", 0x81},
            {"euc-kr", 0x81}
          ] do
        assert decode(encoding, <<lead, 0x3A>>) == "\uFFFD:"
        assert decode(encoding, <<lead, 0x3A, lead>>) == "\uFFFD:\uFFFD"
        assert decode_stream(encoding, [<<lead>>, <<0x3A>>]) == "\uFFFD:"
        # A byte that is not ASCII is part of the error.
        assert decode(encoding, <<lead, 0xFF, ?a>>) == "\uFFFDa"
      end
    end

    test "gives U+FFFD for a byte that cannot start a character" do
      for {encoding, byte} <- [
            {"gb18030", 0xFF},
            {"big5", 0x80},
            {"big5", 0xFF},
            {"euc-jp", 0x80},
            {"euc-jp", 0xFF},
            {"shift_jis", 0xA0},
            {"shift_jis", 0xFD},
            {"euc-kr", 0x80},
            {"euc-kr", 0xFF}
          ] do
        assert decode(encoding, <<?a, byte, ?b>>) == "a\uFFFDb"

        assert_raise TypeError, fn -> decode(encoding, <<byte>>, %{fatal: true}) end
      end
    end

    # The Standard sets "do not flush" to false at an error. Thus the
    # subsequent call makes a new decoder, also after a call with
    # stream: true.
    test "starts a new decoder after an error with the option fatal" do
      decoder = TextDecoder.new("euc-jp", %{fatal: true})
      assert TextDecoder.decode(decoder, <<0x8F>>, %{stream: true}) == ""

      assert_raise TypeError, fn ->
        TextDecoder.decode(decoder, <<0xA2, 0x20>>, %{stream: true})
      end

      assert TextDecoder.decode(decoder, <<0xA1, 0xA1>>) == "\u3000"

      decoder = TextDecoder.new("iso-2022-jp", %{fatal: true})
      assert TextDecoder.decode(decoder, <<0x1B, ?(, ?J>>, %{stream: true}) == ""
      assert_raise TypeError, fn -> TextDecoder.decode(decoder, <<0xFF>>, %{stream: true}) end
      assert TextDecoder.decode(decoder, "~") == "~"
    end
  end

  describe "gb18030 and GBK" do
    property "decode each two-byte pointer of index gb18030, with the same decoder" do
      check all(pointer <- integer(0..23_939)) do
        trail = rem(pointer, 190)
        bytes = <<div(pointer, 190) + 0x81, trail + if(trail < 0x3F, do: 0x40, else: 0x41)>>
        text = <<Indexes.gb18030(pointer)::utf8>>

        assert decode("gb18030", bytes) == text
        assert decode("gbk", bytes) == text
      end
    end

    property "decode each four-byte pointer of index gb18030 ranges" do
      check all(pointer <- one_of([integer(0..39_419), integer(189_000..1_237_575)])) do
        bytes =
          <<div(pointer, 12_600) + 0x81, div(rem(pointer, 12_600), 1260) + 0x30,
            div(rem(pointer, 1260), 10) + 0x81, rem(pointer, 10) + 0x30>>

        assert decode("gb18030", bytes, %{fatal: true}) ==
                 <<Indexes.gb18030_ranges(pointer)::utf8>>
      end
    end

    test "follow the tests of the Standard" do
      for {bytes, text} <- [
            {<<0x80>>, "\u20AC"},
            {<<0xA3, 0xA0>>, "\u3000"},
            {<<0x81, 0x35, 0xF4, 0x37>>, "\uE7C7"},
            {<<0x84, 0x31, 0xA4, 0x39>>, "\uFFFF"},
            {<<0x84, 0x31, 0xA5, 0x30>>, "\uFFFD"},
            {<<0x90, 0x30, 0x81, 0x30>>, "\u{10000}"},
            {<<0xE3, 0x32, 0x9A, 0x35>>, "\u{10FFFF}"},
            {<<0xE3, 0x32, 0x9A, 0x36>>, "\uFFFD"},
            {<<0x81, 0x7F>>, "\uFFFD\u007F"},
            {<<0x81, 0x30, 0xFF>>, "\uFFFD0\uFFFD"},
            {<<0x81, 0x30, 0xFE, 0x29>>, "\uFFFD0\uFFFD)"},
            {<<0xA0, 0x30, 0x2B>>, "\uFFFD0+"},
            {<<0xFE, 0x39, 0xFE, 0x40>>, "\uFFFD9\uFA0C"}
          ] do
        assert decode("gb18030", bytes) == text
        assert decode("gbk", bytes) == text
      end
    end
  end

  describe "Big5" do
    property "decodes each pointer of index Big5" do
      check all(pointer <- integer(0..19_781)) do
        trail = rem(pointer, 157)
        trail = trail + if trail < 0x3F, do: 0x40, else: 0x62
        bytes = <<div(pointer, 157) + 0x81, trail>>

        expected =
          case {pointer, Indexes.big5(pointer)} do
            {1133, _code_point} -> "\u00CA\u0304"
            {1135, _code_point} -> "\u00CA\u030C"
            {1164, _code_point} -> "\u00EA\u0304"
            {1166, _code_point} -> "\u00EA\u030C"
            {_pointer, nil} when trail < 0x80 -> <<"\uFFFD", trail>>
            {_pointer, nil} -> "\uFFFD"
            {_pointer, code_point} -> <<code_point::utf8>>
          end

        assert decode("big5", bytes) == expected
      end
    end

    test "gives two code points for four pointers, and code points above U+FFFF" do
      assert decode("big5", <<0x88, 0x62, 0x88, 0x64, 0x88, 0xA3, 0x88, 0xA5>>) ==
               "\u00CA\u0304\u00CA\u030C\u00EA\u0304\u00EA\u030C"

      assert decode("big5", <<0x87, 0x45, 0xFE, 0x40>>) == "\u{27267}鑂"
      assert decode("big5", <<0x87, 0x87, 0x40>>) == "\uFFFD@"
    end
  end

  describe "EUC-JP" do
    test "decodes half-width katakana, index jis0212, and index jis0208" do
      assert decode("euc-jp", <<0x8E, 0xA1, 0x8E, 0xDF>>) == "\uFF61\uFF9F"
      assert decode("euc-jp", <<0x8E, 0xE0, ?a>>) == "\uFFFDa"
      assert decode("euc-jp", <<0x8F, 0xA2, 0xAF, 0xA1, 0xA1>>) == "\u02D8\u3000"
      assert decode("euc-jp", <<0xA1, 0xDD, 0x5C, 0x7E>>) == "\uFF0D\\~"
    end

    test "uses index jis0212 only for the character after 0x8F" do
      for {bytes, text} <- [
            {<<0x8F, 0xA2, 0x20, 0xA1, 0xA1>>, "\uFFFD \u3000"},
            {<<0x8F, 0xA2, 0xA0, 0xA1, 0xA1>>, "\uFFFD\u3000"},
            {<<0x8F, 0xA2, 0xFF, 0xB0, 0xA1>>, "\uFFFD亜"},
            {<<0x8F, 0xA1, 0xA1, 0xA1, 0xA1>>, "\uFFFD\u3000"}
          ] do
        assert decode("euc-jp", bytes) == text

        for split <- 1..(byte_size(bytes) - 1) do
          <<first::binary-size(^split), second::binary>> = bytes
          assert decode_stream("euc-jp", [first, second]) == text
        end
      end
    end

    property "decodes each pointer of index jis0208 and index jis0212" do
      check all(pointer <- integer(0..8835), jis0212 <- boolean()) do
        pair = <<div(pointer, 94) + 0xA1, rem(pointer, 94) + 0xA1>>

        {bytes, code_point} =
          if jis0212,
            do: {<<0x8F>> <> pair, Indexes.jis0212(pointer)},
            else: {pair, Indexes.jis0208(pointer)}

        expected = if code_point, do: <<code_point::utf8>>, else: "\uFFFD"
        assert decode("euc-jp", bytes) == expected
      end
    end
  end

  describe "ISO-2022-JP" do
    test "follows the tests of the Standard" do
      for {bytes, text} <- [
            {<<0x1B, 0x24>>, "\uFFFD$"},
            {<<0x1B, 0x28, 0x42, 0x50>>, "P"},
            {<<0x1B, 0x28, 0x42, 0x1B, 0x28, 0x42, 0x50>>, "\uFFFDP"},
            {<<0x5C, 0x5D, 0x7E>>, "\\]~"},
            {<<0x0D, 0x0E, 0x0F, 0x10>>, "\r\uFFFD\uFFFD\x10"},
            {<<0x1B, 0x28, 0x4A, 0x5C, 0x5D, 0x7E>>, "\u00A5]\u203E"},
            {<<0x1B, 0x28, 0x4A, 0x0E, 0x10>>, "\uFFFD\x10"},
            {<<0x1B, 0x28, 0x4A, 0x1B, 0x1B, 0x28, 0x49, 0x50>>, "\uFFFD\uFF90"},
            {<<0x1B, 0x28, 0x49, 0x50, 0x0D>>, "\uFF90\uFFFD"},
            {<<0x1B, 0x28, 0x49, 0x1B, 0x24, 0x50>>, "\uFFFD\uFF64\uFF90"},
            {<<0x1B, 0x24, 0x40, 0x50, 0x50>>, "佩"},
            {<<0x1B, 0x24, 0x42, 0x1B, 0x50, 0x50>>, "\uFFFD佩"},
            {<<0x1B, 0x24, 0x40, 0x1B, 0x24, 0x50, 0x50>>, "\uFFFDば\uFFFD"},
            {<<0x1B, 0x24, 0x40, 0x50, 0x1B, 0x24, 0x40, 0x50, 0x50>>, "\uFFFD佩"},
            {<<0x1B, 0x24, 0x40, 0x20, 0x50>>, "\uFFFD\uFFFD"},
            {<<0x1B, 0x24, 0x40, 0x50, 0x20>>, "\uFFFD"},
            {<<0x1B, 0x24, 0x40, 0x22, 0x2F>>, "\uFFFD"},
            {<<0x1B, 0x24, 0x40, 0x50>>, "\uFFFD"},
            {<<0x50, 0x1B>>, "P\uFFFD"},
            {<<0x50, 0x1B, 0x28>>, "P\uFFFD("},
            {<<0x50, 0x1B, 0x28, 0x49>>, "P"},
            {<<0x1B, 0x24, 0x40, 0x1B, 0x24>>, "\uFFFD\uFFFD"}
          ] do
        assert decode("iso-2022-jp", bytes) == text
      end
    end

    test "gives an error for two escape sequences with no character between them" do
      once = <<0x1B, 0x28, 0x4A, 0x5C, 0x1B, 0x28, 0x42>>
      assert decode("iso-2022-jp", once, %{fatal: true}) == "\u00A5"
      assert decode("iso-2022-jp", once <> once) == "\u00A5\uFFFD\u00A5"

      assert_raise TypeError, "The encoded data was not valid iso-2022-jp", fn ->
        decode("iso-2022-jp", once <> once, %{fatal: true})
      end
    end

    test "keeps its state between two calls with stream: true, and starts again at the end" do
      decoder = TextDecoder.new("iso-2022-jp")
      assert TextDecoder.decode(decoder, <<0x1B, 0x28>>, %{stream: true}) == ""
      assert TextDecoder.decode(decoder, <<0x49, 0x21>>, %{stream: true}) == "\uFF61"
      assert TextDecoder.decode(decoder, <<0x21>>) == "\uFF61"
      assert TextDecoder.decode(decoder, <<0x21>>) == "!"

      assert TextDecoder.decode(decoder, <<0x1B, 0x28, 0x49>>, %{stream: true}) == ""
      assert TextDecoder.decode(decoder) == ""
      assert TextDecoder.decode(decoder, <<0x21>>) == "!"
    end
  end

  describe "Shift_JIS" do
    test "decodes 0x80, half-width katakana, and the Private Use Area of Windows" do
      assert decode("shift_jis", <<0x80, 0xA1, 0xDF>>) == "\u0080\uFF61\uFF9F"
      assert decode("shift_jis", <<0xF0, 0x40, 0xF9, 0xFC>>) == "\uE000\uE757"
      assert decode("shift_jis", <<0x81, 0x7C, 0x81, 0x87>>) == "\uFF0D\u221E"
    end

    property "decodes each pointer of index jis0208" do
      check all(pointer <- integer(0..11_279)) do
        lead = div(pointer, 188)
        trail = rem(pointer, 188)
        lead = lead + if lead < 0x1F, do: 0x81, else: 0xC1
        trail = trail + if trail < 0x3F, do: 0x40, else: 0x41

        expected =
          case Indexes.jis0208(pointer) do
            _code_point when pointer in 8836..10_715 -> <<0xE000 - 8836 + pointer::utf8>>
            nil when trail < 0x80 -> <<"\uFFFD", trail>>
            nil -> "\uFFFD"
            code_point -> <<code_point::utf8>>
          end

        assert decode("shift_jis", <<lead, trail>>) == expected
      end
    end
  end

  describe "EUC-KR" do
    property "decodes each pointer of index EUC-KR" do
      check all(pointer <- integer(0..23_749)) do
        trail = rem(pointer, 190) + 0x41
        bytes = <<div(pointer, 190) + 0x81, trail>>

        expected =
          case Indexes.euc_kr(pointer) do
            nil when trail < 0x80 -> <<"\uFFFD", trail>>
            nil -> "\uFFFD"
            code_point -> <<code_point::utf8>>
          end

        assert decode("euc-kr", bytes) == expected
      end
    end
  end

  describe "TextDecoderStream" do
    test "decodes the chunks of a multi-byte encoding, and joins a character that is divided" do
      bytes = <<0x1B, ?$, ?B, 0x46, 0x7C, 0x4B, 0x5C, 0x1B, ?(, ?B, ?!>>
      chunks = for <<byte <- bytes>>, do: Uint8Array.from(<<byte>>)

      result =
        chunks
        |> ReadableStream.from()
        |> ReadableStream.pipe_through(TextDecoderStream.new("iso-2022-jp"))
        |> Enum.join()

      assert result == "日本!"
    end
  end
end
