defmodule Web.ByteChunksTest do
  # Each stream of bytes of the library gives its chunks as `Web.Uint8Array`
  # values, and each consumer of bytes accepts the usual forms of bytes.
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Web

  alias Web.Internal.Bytes
  alias Web.ReadableStreamDefaultReader, as: Reader

  defp chunks(stream), do: Enum.to_list(stream)

  defp assert_bytes(chunks, expected) do
    assert Enum.all?(chunks, &match?(%Uint8Array{}, &1))
    assert Enum.map_join(chunks, &to_string/1) == expected
  end

  describe "Uint8Array.from/1" do
    test "makes a view with a new buffer from each form of bytes" do
      for bytes <- ["abc", [?a, "b", [?c]], ArrayBuffer.new("abc"), Uint8Array.from("abc")] do
        view = Uint8Array.from(bytes)
        assert %Uint8Array{byte_offset: 0, byte_length: 3} = view
        assert to_string(view) == "abc"
      end

      # A view of a part of a buffer gives only that part.
      part = Uint8Array.new(ArrayBuffer.new("xabcx"), 1, 3)
      assert to_string(Uint8Array.from(part)) == "abc"
      assert Uint8Array.from(part).buffer != part.buffer
    end

    test "has a short form for inspect" do
      assert inspect(Uint8Array.from("hi")) == ~s(#Web.Uint8Array<"hi">)
      assert inspect(Uint8Array.from(<<0, 255>>)) == "#Web.Uint8Array<<<0, 255>>>"

      view = Uint8Array.from("hi")
      ArrayBuffer.detach(view.buffer)
      assert inspect(view) == "#Web.Uint8Array<detached>"
    end
  end

  describe "the internal conversion" do
    property "gives the same bytes for each form of a chunk" do
      check all(binary <- binary()) do
        assert Bytes.to_binary(binary) == {:ok, binary}
        assert Bytes.to_binary(Uint8Array.from(binary)) == {:ok, binary}
        assert Bytes.to_binary(ArrayBuffer.new(binary)) == {:ok, binary}
        assert Bytes.to_binary([binary]) == {:ok, binary}
        assert Bytes.to_binary(:binary.bin_to_list(binary)) == {:ok, binary}
        assert to_string(Bytes.chunk(binary)) == binary
      end
    end

    test "refuses a value that is not a chunk of bytes" do
      for value <- [1, :atom, %{}, [:atom], {1, 2}] do
        assert Bytes.to_binary(value) == :error

        assert_raise TypeError, ~r/^The test chunk must be/, fn ->
          Bytes.to_binary!(value, "The test")
        end
      end

      assert Bytes.chunk(:other) == :other
    end
  end

  describe "the body of a response or a request" do
    test "gives a Uint8Array for each form of the body" do
      for body <- [
            "hello",
            Blob.new(["hel", "lo"]),
            ArrayBuffer.new("hello"),
            Uint8Array.from("hello"),
            ["hel", "lo"],
            Stream.map(["hel", "lo"], & &1)
          ] do
        assert_bytes(chunks(Response.new(body).body), "hello")

        request = Request.new("https://example.com/", method: "POST", body: body, duplex: "half")
        assert_bytes(chunks(request.body), "hello")
      end

      params = URLSearchParams.new(%{"a" => "1"})
      assert_bytes(chunks(Response.new(params).body), "a=1")
    end

    test "raises a TypeError for a body that is not bytes and not a stream" do
      assert_raise TypeError, ~r/Cannot make a ReadableStream/, fn -> Response.new(123) end
    end

    test "keeps the chunks of a stream from the caller, and reads each form of bytes" do
      mixed = ["ab", Uint8Array.from("cd"), ArrayBuffer.new("ef"), [?g, "h"]]
      stream = ReadableStream.from(mixed)
      response = Response.new(stream)

      assert response.body == stream
      assert await(Response.text(response)) == "abcdefgh"

      for read <- [&Response.bytes/1, &Response.array_buffer/1, &Response.blob/1] do
        result = await(read.(Response.new(ReadableStream.from(mixed))))

        bytes =
          case result do
            %Uint8Array{} = view -> to_string(view)
            %ArrayBuffer{} = buffer -> to_string(buffer)
            %Blob{} = blob -> Blob.to_binary(blob)
          end

        assert bytes == "abcdefgh"
      end
    end

    test "rejects with a TypeError for a chunk that is not bytes" do
      for read <- [&Response.text/1, &Response.bytes/1] do
        response = Response.new(ReadableStream.from(["ok", :not_bytes]))
        assert %TypeError{} = catch_exit(await(read.(response)))
      end
    end

    test "gives the two branches of a clone the same views" do
      {response, clone} = Response.clone(Response.new("hello"))
      assert_bytes(chunks(response.body), "hello")
      assert_bytes(chunks(clone.body), "hello")
    end
  end

  describe "a blob" do
    test "gives a stream of Uint8Array values" do
      blob = Blob.new(["ab", Blob.new(["cd"]), Uint8Array.from("ef"), ArrayBuffer.new("gh")])
      assert blob.size == 8
      assert_bytes(chunks(Blob.stream(blob)), "abcdefgh")
      assert Web.await(Blob.text(Blob.slice(blob, 3, 7))) == "defg"
    end
  end

  describe "a byte stream" do
    test "gives a Uint8Array to a default read, for each form that the source enqueues" do
      stream =
        ReadableStream.new(%{
          type: "bytes",
          start: fn controller ->
            ReadableByteStreamController.enqueue(controller, "ab")
            ReadableByteStreamController.enqueue(controller, Uint8Array.from("cd"))
            ReadableByteStreamController.close(controller)
          end
        })

      reader = ReadableStream.get_reader(stream)
      assert %{value: %Uint8Array{} = first} = await(Reader.read(reader))
      assert %{value: %Uint8Array{} = second} = await(Reader.read(reader))
      assert %{done: true} = await(Reader.read(reader))
      assert {to_string(first), to_string(second)} == {"ab", "cd"}
    end

    test "takes the buffer of a view that the source enqueues" do
      test = self()
      view = Uint8Array.from("abc")

      stream =
        ReadableStream.new(%{
          type: "bytes",
          start: fn controller ->
            ReadableByteStreamController.enqueue(controller, view)
            send(test, :enqueued)
          end
        })

      assert_receive :enqueued
      assert ArrayBuffer.detached?(view.buffer)

      # A BYOB read takes a part of the chunk.
      reader = ReadableStream.get_reader(stream, mode: "byob")

      assert %{value: value} =
               await(ReadableStreamBYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(2))))

      assert to_string(value) == "ab"
    end
  end

  describe "the transform streams of bytes" do
    test "give Uint8Array values" do
      compressed =
        ["hello"]
        |> ReadableStream.from()
        |> ReadableStream.pipe_through(CompressionStream.new("gzip"))
        |> chunks()

      assert Enum.all?(compressed, &match?(%Uint8Array{}, &1))

      # The views go into the next stream with no conversion.
      decompressed =
        compressed
        |> ReadableStream.from()
        |> ReadableStream.pipe_through(DecompressionStream.new("gzip"))
        |> chunks()

      assert_bytes(decompressed, "hello")

      encoded =
        ["hé", "llo"]
        |> ReadableStream.from()
        |> ReadableStream.pipe_through(TextEncoderStream.new())
        |> chunks()

      assert_bytes(encoded, "héllo")
    end
  end
end
