defmodule Web.ArrayBufferTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.ArrayBuffer
  alias Web.Uint8Array

  describe "new/1" do
    test "makes a buffer from a binary or from a byte length" do
      assert to_string(ArrayBuffer.new("hello")) == "hello"

      buffer = ArrayBuffer.new(4)
      assert to_string(buffer) == <<0, 0, 0, 0>>
      assert ArrayBuffer.byte_length(buffer) == 4
      assert is_reference(ArrayBuffer.identity(buffer))
      refute ArrayBuffer.detached?(buffer)
    end

    test "gives each buffer its own identity" do
      refute ArrayBuffer.identity(ArrayBuffer.new("a")) ==
               ArrayBuffer.identity(ArrayBuffer.new("a"))
    end

    test "refuses input that is not a binary or a byte length" do
      for input <- [-1, 1.5, :atom, [1, 2], nil] do
        assert_raise Web.TypeError, ~r/ArrayBuffer input must be/, fn ->
          ArrayBuffer.new(input)
        end
      end
    end

    test "uses no table and no process" do
      buffers = for _ <- 1..1_000, do: ArrayBuffer.new("payload")

      assert length(buffers) == 1_000
      assert :ets.whereis(Web.ArrayBuffer) == :undefined
      assert Process.whereis(Web.ArrayBuffer.TableOwner) == nil
    end
  end

  describe "the detach of a buffer" do
    test "makes each copy of the buffer detached" do
      buffer = ArrayBuffer.new("hello")
      copy = buffer
      detached = ArrayBuffer.detach(buffer)

      assert detached.byte_length == 0
      assert detached.data == <<>>

      for value <- [buffer, copy, detached] do
        assert ArrayBuffer.detached?(value)
        assert ArrayBuffer.byte_length(value) == 0

        assert_raise Web.TypeError, "Cannot access a detached ArrayBuffer", fn ->
          to_string(value)
        end
      end
    end

    test "is visible in a different process, and from a different process" do
      buffer = ArrayBuffer.new("hello")
      test = self()

      holder =
        spawn(fn ->
          receive do
            :check -> send(test, {:detached?, ArrayBuffer.detached?(buffer)})
          end
        end)

      Task.await(Task.async(fn -> ArrayBuffer.detach(buffer) end))
      assert ArrayBuffer.detached?(buffer)

      send(holder, :check)
      assert_receive {:detached?, true}
    end

    test "can be done two times" do
      buffer = ArrayBuffer.new("hello")
      assert ArrayBuffer.detach(ArrayBuffer.detach(buffer)).byte_length == 0
      assert ArrayBuffer.detached?(buffer)
    end

    test "does not change a different buffer with the same bytes" do
      first = ArrayBuffer.new("same")
      second = ArrayBuffer.new("same")
      ArrayBuffer.detach(first)

      refute ArrayBuffer.detached?(second)
      assert to_string(second) == "same"
    end

    test "makes the views of the buffer not readable" do
      buffer = ArrayBuffer.new("hello")
      view = Uint8Array.new(buffer, 1, 3)
      ArrayBuffer.detach(buffer)

      assert_raise Web.TypeError, "Cannot access a detached ArrayBuffer", fn ->
        to_string(view)
      end

      assert_raise Web.TypeError, ~r/detached ArrayBuffer/, fn -> Uint8Array.new(buffer) end
    end
  end

  describe "a buffer with no flag on this node" do
    test "is never detached" do
      plain = %ArrayBuffer{id: nil, data: "plain", byte_length: 5}
      emptied = ArrayBuffer.detach(plain)

      assert ArrayBuffer.identity(plain) == nil
      assert to_string(plain) == "plain"
      assert ArrayBuffer.byte_length(plain) == 5
      refute ArrayBuffer.detached?(plain)
      assert emptied.data == <<>>
      assert emptied.byte_length == 0
    end

    test "is the result when the identity is a reference that is not a flag" do
      foreign = %ArrayBuffer{id: make_ref(), data: "foreign", byte_length: 7}

      refute ArrayBuffer.detached?(foreign)
      assert to_string(foreign) == "foreign"
      assert ArrayBuffer.detach(foreign).byte_length == 0
      refute ArrayBuffer.detached?(foreign)
      assert to_string(ArrayBuffer.transfer(foreign)) == "foreign"
    end
  end

  describe "to_string/1" do
    test "gives the bytes of a buffer and of a view, also in an interpolation" do
      buffer = ArrayBuffer.new("hello")
      view = Uint8Array.new(buffer, 1, 3)

      assert to_string(buffer) == "hello"
      assert to_string(view) == "ell"
      assert "#{buffer} #{view}" == "hello ell"
    end

    test "gives bytes that are not valid UTF-8 with no change" do
      bytes = <<0xFF, 0, 0xC3>>

      assert to_string(ArrayBuffer.new(bytes)) == bytes
      assert to_string(Uint8Array.from(bytes)) == bytes
    end
  end

  describe "transfer/2" do
    test "moves the bytes to a new buffer and detaches the first buffer" do
      buffer = ArrayBuffer.new("hello")
      moved = ArrayBuffer.transfer(buffer)

      assert to_string(moved) == "hello"
      refute ArrayBuffer.detached?(moved)
      assert ArrayBuffer.detached?(buffer)
      refute ArrayBuffer.identity(moved) == ArrayBuffer.identity(buffer)
    end

    test "cuts the bytes, or adds zero bytes, for a new length" do
      assert to_string(ArrayBuffer.transfer(ArrayBuffer.new("hello"), 2)) == "he"
      assert to_string(ArrayBuffer.transfer(ArrayBuffer.new("hello"), 0)) == ""
      assert to_string(ArrayBuffer.transfer(ArrayBuffer.new("hi"), 4)) == <<"hi", 0, 0>>
    end

    test "refuses a detached buffer and a length that is not valid" do
      buffer = ArrayBuffer.new("hello")
      ArrayBuffer.transfer(buffer)

      assert_raise Web.TypeError, "Cannot transfer a detached ArrayBuffer", fn ->
        ArrayBuffer.transfer(buffer)
      end

      for length <- [-1, 1.5, :all] do
        assert_raise Web.TypeError, ~r/Invalid ArrayBuffer length/, fn ->
          ArrayBuffer.transfer(ArrayBuffer.new("hello"), length)
        end
      end
    end
  end

  describe "properties" do
    property "a buffer gives the bytes and the length of its binary" do
      check all(data <- binary()) do
        buffer = ArrayBuffer.new(data)
        assert to_string(buffer) == data
        assert ArrayBuffer.byte_length(buffer) == byte_size(data)
      end
    end

    property "a transfer keeps the bytes for each new length" do
      check all(data <- binary(), length <- integer(0..64)) do
        buffer = ArrayBuffer.new(data)
        moved = ArrayBuffer.transfer(buffer, length)
        result = to_string(moved)

        assert byte_size(result) == length
        kept = min(length, byte_size(data))
        assert binary_part(result, 0, kept) == binary_part(data, 0, kept)
        assert binary_part(result, kept, length - kept) == :binary.copy(<<0>>, length - kept)
        assert ArrayBuffer.detached?(buffer)
      end
    end

    property "replace/3 changes only the bytes of the chunk" do
      check all(
              data <- binary(min_length: 1),
              offset <- integer(0..byte_size(data)),
              chunk <- binary(max_length: byte_size(data) - offset)
            ) do
        buffer = ArrayBuffer.new(data)
        result = to_string(ArrayBuffer.replace(buffer, offset, chunk))
        chunk_end = offset + byte_size(chunk)

        assert byte_size(result) == byte_size(data)
        assert binary_part(result, 0, offset) == binary_part(data, 0, offset)
        assert binary_part(result, offset, byte_size(chunk)) == chunk

        assert binary_part(result, chunk_end, byte_size(data) - chunk_end) ==
                 binary_part(data, chunk_end, byte_size(data) - chunk_end)
      end
    end

    property "a view gives the part of the buffer between its offset and its end" do
      check all(
              data <- binary(),
              offset <- integer(0..byte_size(data)),
              length <- integer(0..(byte_size(data) - offset))
            ) do
        view = Uint8Array.new(ArrayBuffer.new(data), offset, length)
        assert to_string(view) == binary_part(data, offset, length)

        assert to_string(Uint8Array.new(ArrayBuffer.new(data), offset)) ==
                 binary_part(data, offset, byte_size(data) - offset)
      end
    end
  end
end
