defmodule Web.ReadableStreamPropertyTest do
  # Properties of the streams for random chunks: no chunk is lost, added, or
  # moved, and the queue does not go above its limit.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.ReadableStreamDefaultReader
  alias Web.Response
  alias Web.TransformStream

  defp chunks, do: list_of(binary(max_length: 8), max_length: 12)

  # Reads the stream to its end with the reader functions.
  defp read_all(stream) do
    reader = ReadableStream.get_reader(stream)
    read_all(reader, [])
  end

  defp read_all(reader, acc) do
    case await(ReadableStreamDefaultReader.read(reader)) do
      %{done: true} -> Enum.reverse(acc)
      %{value: chunk, done: false} -> read_all(reader, [chunk | acc])
    end
  end

  # Splits a binary at random positions.
  defp split(binary, []), do: [binary]

  defp split(binary, [size | sizes]) do
    size = min(size, byte_size(binary))
    <<head::binary-size(^size), rest::binary>> = binary
    [head | split(rest, sizes)]
  end

  # ---------------------------------------------------------------------------
  # from/1
  # ---------------------------------------------------------------------------

  property "from/1 gives the elements of a list in sequence" do
    check all(chunks <- chunks()) do
      assert Enum.to_list(ReadableStream.from(chunks)) == chunks
      assert read_all(ReadableStream.from(chunks)) == chunks
    end
  end

  property "from/1 gives each term of an enumerable, also nil and atoms" do
    term = one_of([binary(), integer(), constant(nil), constant(:done), constant({:chunk, 1})])

    check all(terms <- list_of(term, max_length: 10)) do
      assert Enum.to_list(ReadableStream.from(Stream.map(terms, & &1))) == terms
    end
  end

  property "from/1 follows an enumerable that halts itself" do
    check all(chunks <- chunks(), count <- integer(0..14)) do
      assert Enum.to_list(ReadableStream.from(Stream.take(chunks, count))) ==
               Enum.take(chunks, count)

      short = &(byte_size(&1) < 5)

      assert Enum.to_list(ReadableStream.from(Stream.take_while(chunks, short))) ==
               Enum.take_while(chunks, short)
    end
  end

  # `Enum.take/2` with the count 0 does not use the enumerable. Thus the
  # count starts at 1.
  property "a halt gives the first elements and stops the source" do
    check all(chunks <- chunks(), count <- integer(1..14)) do
      test = self()
      ref = make_ref()

      enumerable =
        Stream.resource(
          fn -> chunks end,
          fn
            [] -> {:halt, []}
            [chunk | rest] -> {[chunk], rest}
          end,
          fn _rest -> send(test, {:source_closed, ref}) end
        )

      assert Enum.take(ReadableStream.from(enumerable), count) == Enum.take(chunks, count)
      assert_receive {:source_closed, ^ref}, 1_000
    end
  end

  # ---------------------------------------------------------------------------
  # Readers
  # ---------------------------------------------------------------------------

  property "readers that take the lock in turn get each chunk one time, in sequence" do
    check all(chunks <- chunks(), turns <- list_of(integer(0..4), max_length: 6)) do
      stream = ReadableStream.from(chunks)

      # Each turn takes the lock, reads some chunks, and releases the lock.
      {read, done?} =
        Enum.reduce(turns, {[], false}, fn count, {acc, done?} ->
          if done?, do: {acc, true}, else: read_turn(stream, count, acc)
        end)

      rest = if done?, do: [], else: read_all(stream)
      assert Enum.reverse(read) ++ rest == chunks
    end
  end

  defp read_turn(stream, count, acc) do
    reader = ReadableStream.get_reader(stream)

    result =
      Enum.reduce_while(List.duplicate(:read, count), {acc, false}, fn :read, {acc, _done?} ->
        case await(ReadableStreamDefaultReader.read(reader)) do
          %{done: true} -> {:halt, {acc, true}}
          %{value: chunk, done: false} -> {:cont, {[chunk | acc], false}}
        end
      end)

    :ok = ReadableStreamDefaultReader.release_lock(reader)
    result
  end

  # ---------------------------------------------------------------------------
  # Pipes
  # ---------------------------------------------------------------------------

  property "an identity transform gives the same chunks, for each queue limit" do
    check all(chunks <- chunks(), limit <- integer(1..4), max_runs: 50) do
      result =
        chunks
        |> ReadableStream.from()
        |> ReadableStream.pipe_through(TransformStream.new(%{}, high_water_mark: limit))
        |> Enum.to_list()

      assert result == chunks
    end
  end

  property "a chain of transforms gives the composition of its functions" do
    check all(
            numbers <- list_of(integer(), max_length: 10),
            additions <- list_of(integer(-3..3), max_length: 3),
            max_runs: 50
          ) do
      piped =
        Enum.reduce(additions, ReadableStream.from(numbers), fn addition, stream ->
          transform =
            TransformStream.new(%{
              transform: fn chunk, controller ->
                ReadableStreamDefaultController.enqueue(controller, chunk + addition)
              end
            })

          ReadableStream.pipe_through(stream, transform)
        end)

      assert Enum.to_list(piped) == Enum.map(numbers, &(&1 + Enum.sum(additions)))
    end
  end

  property "a transform can give zero or more chunks for each input chunk" do
    check all(counts <- list_of(integer(0..3), max_length: 10), max_runs: 50) do
      transform =
        TransformStream.new(%{
          transform: fn count, controller ->
            for index <- 1..count//1 do
              ReadableStreamDefaultController.enqueue(controller, {count, index})
            end
          end
        })

      result = counts |> ReadableStream.from() |> ReadableStream.pipe_through(transform)

      assert Enum.to_list(result) ==
               for(count <- counts, index <- 1..count//1, do: {count, index})
    end
  end

  property "the two branches of tee/1 give the chunks of the source" do
    check all(chunks <- chunks(), max_runs: 50) do
      [first, second] = ReadableStream.tee(ReadableStream.from(chunks))

      tasks = [
        Task.async(fn -> Enum.to_list(first) end),
        Task.async(fn -> Enum.to_list(second) end)
      ]

      assert Task.await_many(tasks) == [chunks, chunks]
    end
  end

  # ---------------------------------------------------------------------------
  # Bodies
  # ---------------------------------------------------------------------------

  property "a body gives the bytes of its chunks" do
    check all(chunks <- chunks()) do
      bytes = IO.iodata_to_binary(chunks)
      response = fn -> Response.new(body: ReadableStream.from(Stream.map(chunks, & &1))) end

      assert await(Response.array_buffer(response.())).data == bytes
      assert await(Response.blob(response.())).size == byte_size(bytes)
    end
  end

  property "text/1 gives the same text for each split of its bytes" do
    check all(
            text <- string(:utf8, max_length: 30),
            sizes <- list_of(integer(0..5), max_length: 8)
          ) do
      parts = split(text, sizes)
      response = Response.new(body: ReadableStream.from(Stream.map(parts, & &1)))

      assert await(Response.text(response)) == text
    end
  end

  property "a clone of a response gives the same body two times" do
    check all(text <- string(:utf8, max_length: 30), max_runs: 30) do
      {first, second} = Response.clone(Response.new(body: text))

      assert await(Response.text(first)) == text
      assert await(Response.text(second)) == text
    end
  end

  # ---------------------------------------------------------------------------
  # Backpressure
  # ---------------------------------------------------------------------------

  property "a stream that no process reads does not pull more than its queue limit" do
    check all(limit <- integer(1..5), max_runs: 25) do
      test = self()
      ref = make_ref()

      stream =
        ReadableStream.new(
          %{
            pull: fn controller ->
              send(test, {:pulled, ref})
              ReadableStreamDefaultController.enqueue(controller, :chunk)
            end
          },
          high_water_mark: limit
        )

      # The stream pulls until its queue has `limit` chunks, and not more.
      for _ <- 1..limit, do: assert_receive({:pulled, ^ref}, 1_000)
      Process.sleep(30)
      assert count_pulls(ref) == 0

      # Each read lets the stream pull one more chunk.
      reader = ReadableStream.get_reader(stream)
      assert %{value: :chunk} = await(ReadableStreamDefaultReader.read(reader))
      assert_receive {:pulled, ^ref}, 1_000
      Process.sleep(10)
      assert count_pulls(ref) == 0
    end
  end

  defp count_pulls(ref, count \\ 0) do
    receive do
      {:pulled, ^ref} -> count_pulls(ref, count + 1)
    after
      0 -> count
    end
  end
end
