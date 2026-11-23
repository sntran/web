defmodule Web.Uint8ArrayTest do
  use ExUnit.Case, async: true

  alias Web.ArrayBuffer
  alias Web.Uint8Array

  test "new/3 defaults length to remaining bytes" do
    buffer = ArrayBuffer.new("hello")
    uint8 = Uint8Array.new(buffer, 2)

    assert uint8.byte_offset == 2
    assert uint8.byte_length == 3
    assert to_string(uint8) == "llo"
  end

  test "new/3 raises on invalid offset" do
    buffer = ArrayBuffer.new("hello")

    assert_raise ArgumentError, "invalid byte offset", fn ->
      Uint8Array.new(buffer, 6)
    end
  end

  test "the constant BYTES_PER_ELEMENT is the size of one element" do
    assert Uint8Array.bytes_per_element() == 1
    view = Uint8Array.from("hello")
    assert byte_size(to_string(view)) == view.byte_length * Uint8Array.bytes_per_element()
  end

  test "new/3 raises on invalid length" do
    buffer = ArrayBuffer.new("hello")

    assert_raise ArgumentError, "invalid byte length", fn ->
      Uint8Array.new(buffer, 4, 2)
    end
  end
end
