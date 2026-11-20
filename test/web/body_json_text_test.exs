defmodule Web.BodyJSONTextTest do
  # The readers `text/1` and `json/1` of a body, as the Fetch Standard
  # specifies them: the UTF-8 decode of the bytes, then `JSON.parse` for
  # `json/1`.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.Response

  defp chunked(binaries) do
    Response.new(body: Web.ReadableStream.from(Enum.map(binaries, &Web.Uint8Array.from/1)))
  end

  defp json!(body), do: await(Response.json(Response.new(body: body)))
  defp json_error(body), do: catch_exit(await(Response.json(Response.new(body: body))))

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

  describe "json/1" do
    test "gives each JSON value" do
      assert json!(~s({"a":1,"b":[true,false,null],"c":{"d":"e"}})) ==
               %{"a" => 1, "b" => [true, false, nil], "c" => %{"d" => "e"}}

      assert json!("42") == 42
      assert json!("1.5e3") == 1.5e3
      assert json!(~s("text")) == "text"
      assert json!("null") == nil
      assert json!(" \t\n[1] \r\n") == [1]
      assert json!(~s("\\uD83D\\uDE00")) == "😀"
      assert json!("123456789012345678901234567890") == 123_456_789_012_345_678_901_234_567_890
    end

    test "keeps the last value of a key that is in an object two times, as ECMAScript" do
      assert json!(~s({"a":1,"b":2,"a":3})) == %{"a" => 3, "b" => 2}
      assert json!(~s([{"k":"first","k":"last"}])) == [%{"k" => "last"}]
    end

    test "decodes the bytes as UTF-8 first, as the Fetch Standard specifies" do
      # A byte order mark goes away, and an invalid byte becomes U+FFFD.
      assert json!(<<0xEF, 0xBB, 0xBF>> <> ~s({"ok":true})) == %{"ok" => true}
      assert json!(<<?", ?a, 0xFF, ?">>) == "a�"
    end

    test "rejects with SyntaxError for text that ECMAScript also refuses" do
      for body <- ["", "[1] x", "{'a':1}", "[1,]", ~s({"a"}), "NaN", <<?", 1, ?">>] do
        assert %Web.SyntaxError{message: "The body is not valid JSON: " <> _detail} =
                 error = json_error(body)

        assert %JSON.DecodeError{} = error.cause
      end
    end

    test "parses a large text in the process of the promise, with a large heap" do
      items = for index <- 1..5_000, do: %{"index" => index, "name" => "item-#{index}"}
      text = JSON.encode!(items)
      assert byte_size(text) > 65_536

      {:min_heap_size, before} = Process.info(self(), :min_heap_size)
      assert json!(text) == items

      # The heap setting is for the process of the promise, not for the
      # caller.
      assert Process.info(self(), :min_heap_size) == {:min_heap_size, before}
      assert {:ok, ^items} = Web.Blob.json(Web.Blob.new([text]))
      assert Process.info(self(), :min_heap_size) == {:min_heap_size, before}
    end

    test "rejects the values that a UTF-8 binary or a float cannot have" do
      # ECMAScript gives Infinity, and keeps a lone surrogate.
      assert %Web.SyntaxError{} = json_error("1e400")
      assert %Web.SyntaxError{} = json_error(~s("\\uD800"))
    end

    property "reads back the JSON of Response.json/2" do
      value =
        tree(one_of([integer(), float(), boolean(), string(:utf8), constant(nil)]), fn child ->
          one_of([list_of(child, max_length: 4), map_of(string(:utf8), child, max_length: 4)])
        end)

      check all(data <- value, max_runs: 100) do
        assert await(Response.json(Response.json(data))) == data
      end
    end
  end

  describe "Response.json/2" do
    defmodule NoJSON do
      defstruct [:a]
    end

    test "raises TypeError for a value that has no JSON form" do
      for value <- [{1, 2}, self(), %NoJSON{a: 1}, <<0xFF>>, %{"key" => <<0xFF>>}] do
        error =
          assert_raise Web.TypeError, ~r/cannot be changed to JSON/, fn ->
            Response.json(value)
          end

        assert is_exception(error.cause)
      end
    end
  end

  describe "Web.Blob" do
    test "json/1 gives the value or the decode error" do
      assert Web.Blob.json(Web.Blob.new([~s({"a":1,"a":2})])) == {:ok, %{"a" => 2}}
      assert {:error, %JSON.DecodeError{}} = Web.Blob.json(Web.Blob.new(["{"]))
    end

    test "array_buffer/1 gives the bytes with no decode" do
      bytes = <<0xEF, 0xBB, 0xBF, 0xFF>>
      {:ok, buffer} = Web.Blob.array_buffer(Web.Blob.new([bytes]))
      assert Web.ArrayBuffer.data(buffer) == bytes
    end
  end
end
