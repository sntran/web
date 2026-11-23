defmodule Web.CompressionStandardTest do
  # The behaviour of the compression streams that the Compression Standard
  # specifies for data that is not complete or not valid.
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Web

  @formats ~w[brotli gzip deflate deflate-raw]

  # Gives the chunks of the readable side as binaries.
  defp through(chunks, transform) do
    chunks
    |> ReadableStream.from()
    |> ReadableStream.pipe_through(transform)
    |> Web.TestBytes.binaries()
  end

  defp compress(data, format),
    do: [data] |> through(CompressionStream.new(format)) |> IO.iodata_to_binary()

  defp decompress(chunks, format),
    do: chunks |> through(DecompressionStream.new(format)) |> IO.iodata_to_binary()

  # Splits a binary at the given positions.
  defp split(binary, []), do: [binary]

  defp split(binary, [size | sizes]) do
    size = min(size, byte_size(binary))
    <<head::binary-size(^size), rest::binary>> = binary
    [head | split(rest, sizes)]
  end

  # Reads until the end of the stream. The last result has `done: true`.
  defp read_to_end(reader) do
    case await(ReadableStreamDefaultReader.read(reader)) do
      %{done: true} = result -> [result]
      result -> [result | read_to_end(reader)]
    end
  end

  # Examines the condition until it is true, with a limit of 2 seconds for a
  # busy machine. Use it only when no message tells that a different process
  # did its step.
  defp wait_until(condition, attempts \\ 200) do
    cond do
      condition.() ->
        :ok

      attempts > 1 ->
        Process.sleep(10)
        wait_until(condition, attempts - 1)

      true ->
        flunk("The condition did not become true in the time limit.")
    end
  end

  describe "a decompression stream" do
    test "gives TypeError when the stream closes before the end of the data" do
      for format <- @formats do
        compressed = compress(String.duplicate("payload ", 2_000), format)

        for size <- [0, 1, 10, div(byte_size(compressed), 2), byte_size(compressed) - 1] do
          assert_raise TypeError, ~r/not complete|invalid data/, fn ->
            decompress([binary_part(compressed, 0, size)], format)
          end
        end
      end
    end

    test "gives TypeError when the stream closes with no data" do
      for format <- @formats do
        assert_raise TypeError, ~r/not complete/, fn -> decompress([], format) end
      end
    end

    test "gives TypeError for data after the end of the compressed data" do
      for format <- @formats do
        compressed = compress("payload", format)

        # In the same chunk, in a later chunk, and a second compressed stream.
        for chunks <- [[compressed <> "x"], [compressed, "x"], [compressed <> compressed]] do
          assert_raise TypeError, ~r/invalid data/, fn -> decompress(chunks, format) end
        end
      end
    end

    test "puts the two sides in the errored state for data that is not valid" do
      stream = DecompressionStream.new("gzip")
      writer = WritableStream.get_writer(stream.writable)
      read = ReadableStreamDefaultReader.read(ReadableStream.get_reader(stream.readable))

      assert %TypeError{} =
               catch_exit(await(WritableStreamDefaultWriter.write(writer, "not gzip")))

      assert %TypeError{} = catch_exit(await(read))
      assert %TypeError{} = catch_exit(await(WritableStreamDefaultWriter.write(writer, "more")))
    end

    property "gives the data for each division of the compressed bytes into chunks" do
      check all(
              data <- binary(max_length: 2_000),
              format <- member_of(@formats),
              sizes <- list_of(integer(1..64), max_length: 20),
              max_runs: 60
            ) do
        compressed = compress(data, format)
        assert decompress(split(compressed, sizes), format) == data
      end
    end

    property "gives TypeError for each prefix of the compressed bytes" do
      check all(
              data <- binary(min_length: 1, max_length: 500),
              format <- member_of(@formats),
              cut <- integer(1..40),
              max_runs: 60
            ) do
        compressed = compress(data, format)
        prefix = binary_part(compressed, 0, max(byte_size(compressed) - cut, 0))

        assert_raise TypeError, fn -> decompress([prefix], format) end
      end
    end
  end

  describe "a chunk of bytes" do
    test "can be a binary, a Uint8Array, or an ArrayBuffer" do
      for format <- @formats do
        chunks = ["ab", Uint8Array.new(ArrayBuffer.new("xcdx"), 1, 2), ArrayBuffer.new("ef")]
        compressed = chunks |> through(CompressionStream.new(format)) |> IO.iodata_to_binary()

        assert decompress([compressed], format) == "abcdef"
        assert decompress([ArrayBuffer.new(compressed)], format) == "abcdef"
        assert decompress([Uint8Array.new(ArrayBuffer.new(compressed))], format) == "abcdef"
      end
    end

    test "that is a different term gives TypeError" do
      for make <- [&CompressionStream.new/1, &DecompressionStream.new/1],
          chunk <- [123, :atom, %{}] do
        assert_raise TypeError, ~r/chunk must be a binary/, fn ->
          through([chunk], make.("gzip"))
        end
      end
    end
  end

  describe "the format" do
    test "must be one of the four formats of the Standard" do
      for make <- [&CompressionStream.new/1, &DecompressionStream.new/1] do
        for format <- @formats, do: assert(%{readable: _, writable: _} = make.(format))

        for format <- ["br", "BROTLI", "GZIP", "", :gzip, nil],
            do: assert_raise(TypeError, fn -> make.(format) end)
      end
    end
  end

  describe "the backpressure" do
    # The Compression Standard sets up each stream with the steps "set up a
    # TransformStream" of the Streams Standard: the writable side has the
    # high water mark 1, the readable side has the high water mark 0, and
    # the size of each chunk is 1.
    test "gives the two sides the high water marks and the sizes of the Standard" do
      for make <- [&CompressionStream.new/1, &DecompressionStream.new/1] do
        stream = make.("gzip")
        pid = stream.readable.controller_pid
        writer = WritableStream.get_writer(stream.writable)
        assert WritableStreamDefaultWriter.desired_size(writer) == 1
        assert ReadableStream.__get_slots__(pid).readable_desired_size == 0

        # A small chunk and a large chunk have the same size.
        for chunk <- ["x", :binary.copy("x", 100_000)],
            do: WritableStreamDefaultWriter.write(writer, chunk)

        assert WritableStreamDefaultWriter.desired_size(writer) == -1
      end

      # A close with no write puts the last chunks of the compressed data in
      # the queue of the readable side, with no read.
      stream = CompressionStream.new("gzip")
      writer = WritableStream.get_writer(stream.writable)
      assert :ok = await(WritableStreamDefaultWriter.close(writer))

      slots = ReadableStream.__get_slots__(stream.readable.controller_pid)
      chunks = :queue.to_list(slots.queue)
      assert chunks != []
      assert Enum.sum_by(chunks, fn {chunk, _size} -> chunk.byte_length end) > length(chunks)
      assert slots.total_queued_size == length(chunks)
    end

    # The step "compress and enqueue a chunk" puts all the output of a chunk
    # in the queue. Thus a read that waits lets a write complete, also when
    # the write gives more than one chunk.
    property "lets a write of a compression stream complete when a read waits" do
      check all(
              format <- member_of(@formats),
              sizes <- list_of(integer(0..100_000), min_length: 1, max_length: 3),
              seed <- integer(),
              max_runs: 30
            ) do
        :rand.seed(:exsss, seed)
        chunks = Enum.map(sizes, &:rand.bytes/1)
        stream = CompressionStream.new(format)
        pid = stream.readable.controller_pid
        writer = WritableStream.get_writer(stream.writable)
        reader = ReadableStream.get_reader(stream.readable)

        reads =
          Enum.flat_map(chunks, fn chunk ->
            # The reads take the chunks of the queue first. Then a read
            # waits for a chunk.
            queued = :queue.len(ReadableStream.__get_slots__(pid).queue)
            reads = for _ <- 0..queued//1, do: ReadableStreamDefaultReader.read(reader)
            assert :ok = await(WritableStreamDefaultWriter.write(writer, chunk))
            reads
          end)

        close = WritableStreamDefaultWriter.close(writer)
        output = Enum.map(reads, &await/1) ++ read_to_end(reader)
        assert :ok = await(close)

        compressed =
          for %{done: false, value: chunk} <- output,
              into: "",
              do: Uint8Array.to_binary(chunk)

        assert decompress([compressed], format) == IO.iodata_to_binary(chunks)
      end
    end

    test "holds the writes of a compression stream that no process reads" do
      stream = CompressionStream.new("gzip")
      pid = stream.readable.controller_pid
      writer = WritableStream.get_writer(stream.writable)

      writes =
        for _ <- 1..50,
            do: WritableStreamDefaultWriter.write(writer, :crypto.strong_rand_bytes(20_000))

      # The transform of a chunk waits for a read: no transform starts.
      slots = ReadableStream.__get_slots__(pid)
      assert slots.active_task == nil
      assert :queue.len(slots.queued_write_requests) == 50
      assert :queue.is_empty(slots.queue)
      assert Enum.all?(writes, &(Promise.peek(&1) == :pending))

      # A read starts the transforms. The read takes the first chunk of the
      # output, and the other chunks of that write go to the queue. Then
      # the stream does no more work before a read.
      read = ReadableStreamDefaultReader.read(ReadableStream.get_reader(stream.readable))
      assert %{done: false, value: %Uint8Array{}} = await(read)
      wait_until(fn -> ReadableStream.__get_slots__(pid).active_task == nil end)

      slots = ReadableStream.__get_slots__(pid)
      assert Enum.count(writes, &(Promise.peek(&1) == :pending)) >= 45
      assert :queue.len(slots.queued_write_requests) >= 45
      assert :queue.len(slots.queue) <= 2
    end
  end
end
