defmodule Web.BodyJSONTextTest do
  # The reader `text/1` of a body, as the Fetch Standard specifies it: the
  # UTF-8 decode of the bytes.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.Response

  defp chunked(binaries) do
    Response.new(body: Web.ReadableStream.from(Enum.map(binaries, &Web.Uint8Array.from/1)))
  end

  describe "text/1" do
    test "gives valid UTF-8 with no change" do
      text = "plain ASCII, then café and 😀"
      assert await(Response.text(Response.new(body: text))) == text
    end

    test "removes a byte order mark at the start, and only there" do
      bom = <<0xEF, 0xBB, 0xBF>>
      assert await(Response.text(Response.new(body: bom <> "x" <> bom))) == "x﻿"
      assert await(Response.text(chunked([<<0xEF, 0xBB>>, <<0xBF, ?y>>]))) == "y"
    end

    test "replaces each invalid sequence with U+FFFD" do
      body = <<?a, 0xFF, ?b, 0xE2, 0x82, ?c, 0xED, 0xA0, 0x80>>

      assert await(Response.text(Response.new(body: body))) ==
               "a�b�c���"
    end

    test "joins the chunks of a body, also a character across two chunks" do
      assert await(Response.text(chunked(["caf", <<0xC3>>, <<0xA9, ?!>>]))) == "café!"
      assert await(Response.text(chunked([]))) == ""
    end

    property "gives the same text as the decoder of the Encoding Standard" do
      check all(
              bytes <- binary(max_length: 64),
              cut <- integer(0..64),
              max_runs: 300
            ) do
        cut = min(cut, byte_size(bytes))
        parts = [binary_part(bytes, 0, cut), binary_part(bytes, cut, byte_size(bytes) - cut)]
        decoder = Web.TextDecoder.new()
        expected = Web.TextDecoder.decode(decoder, bytes)
        Web.TextDecoder.dispose(decoder)

        assert await(Response.text(chunked(parts))) == expected
      end
    end
  end

  describe "Web.Blob" do
    test "array_buffer/1 gives the bytes with no decode" do
      bytes = <<0xEF, 0xBB, 0xBF, 0xFF>>
      {:ok, buffer} = Web.Blob.array_buffer(Web.Blob.new([bytes]))
      assert Web.ArrayBuffer.data(buffer) == bytes
    end
  end
end
