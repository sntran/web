defmodule Web.StreamPullRulesTest do
  # The pulls that a source sees, and the times that an enumerable advances,
  # for each internal reader of the library. The internal readers take the
  # chunks in batches, but a source must not see a difference from the
  # Streams Standard:
  #
  #   * the stream pulls while its desired size is above 0, or for a read
  #     that waits. A source with one chunk for each pull thus sees a
  #     desired size from 1 to the high water mark, or 0 for the high water
  #     mark 0;
  #   * before the first read, the stream pulls to its high water mark;
  #   * `ReadableStream.from/1` has the high water mark 0, and takes one
  #     element of the enumerable for each read.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.WritableStream

  @chunks 40

  # A source with one chunk for each pull. It records the desired size that
  # each pull sees.
  defp recording_source(count) do
    pulls = :counters.new(1, [])
    desired = :ets.new(:desired, [:public, :duplicate_bag])

    source = %{
      pull: fn controller ->
        :counters.add(pulls, 1, 1)
        index = :counters.get(pulls, 1)
        :ets.insert(desired, {:desired, ReadableStreamDefaultController.desired_size(controller)})

        if index <= count do
          ReadableStreamDefaultController.enqueue(controller, index)
        else
          ReadableStreamDefaultController.close(controller)
        end
      end
    }

    {source, pulls, desired}
  end

  defp desired_sizes(table), do: for({:desired, size} <- :ets.tab2list(table), do: size)

  # The desired sizes that the Standard permits at a pull.
  defp assert_standard_pulls(table, 0), do: assert(Enum.all?(desired_sizes(table), &(&1 == 0)))

  defp assert_standard_pulls(table, high_water_mark) do
    for size <- desired_sizes(table), do: assert(size in 1..high_water_mark)
  end

  # Waits until the stream has no pull that runs and its queue does not
  # change. The stream starts its first pull before it handles a call, and
  # it starts the next pull in the same step as the end of a pull. Thus a
  # stream with no pull that runs has no more work before a read.
  defp settle(stream, attempts \\ 200) do
    slots = ReadableStream.__get_slots__(stream.controller_pid)

    cond do
      not slots.pulling -> slots
      attempts == 0 -> flunk("the stream did not stop its pulls")
      true -> Process.sleep(5) && settle(stream, attempts - 1)
    end
  end

  defp wait_for_queue(stream, size, attempts \\ 200) do
    queue = ReadableStream.__get_slots__(stream.controller_pid).queue

    cond do
      :queue.len(queue) >= size -> :ok
      attempts == 0 -> flunk("the queue of the stream did not get #{size} chunks")
      true -> Process.sleep(5) && wait_for_queue(stream, size, attempts - 1)
    end
  end

  defp readers do
    [
      enum: fn stream -> Enum.to_list(stream) end,
      for: fn stream -> for chunk <- stream, do: chunk end,
      pipe_1: fn stream -> pipe(stream, 1) end,
      pipe_4: fn stream -> pipe(stream, 4) end,
      tee: fn stream ->
        [left, right] = ReadableStream.tee(stream)
        other = Task.async(fn -> Enum.to_list(right) end)
        chunks = Enum.to_list(left)
        assert Task.await(other) == chunks
        chunks
      end
    ]
  end

  defp pipe(stream, high_water_mark) do
    test = self()

    sink =
      WritableStream.new(
        %{
          write: fn chunk, _controller -> send(test, {:w, chunk}) end
        },
        high_water_mark: high_water_mark
      )

    assert :ok = await(ReadableStream.pipe_to(stream, sink))
    for _index <- 1..@chunks, do: receive(do: ({:w, chunk} -> chunk))
  end

  describe "a source with one chunk for each pull" do
    for high_water_mark <- [0, 1, 4] do
      @high_water_mark high_water_mark

      test "pulls to the high water mark #{high_water_mark} before a read" do
        {source, pulls, desired} = recording_source(@chunks)
        stream = ReadableStream.new(source, high_water_mark: @high_water_mark)

        slots = settle(stream)
        assert :counters.get(pulls, 1) == @high_water_mark
        assert slots.total_queued_size == @high_water_mark
        assert_standard_pulls(desired, @high_water_mark)
      end

      for reader <- [:enum, :for, :pipe_1, :pipe_4, :tee] do
        @reader reader

        test "sees the pulls of the Standard with #{reader}, high water mark #{high_water_mark}" do
          {source, pulls, desired} = recording_source(@chunks)
          stream = ReadableStream.new(source, high_water_mark: @high_water_mark)

          assert Keyword.fetch!(readers(), @reader).(stream) == Enum.to_list(1..@chunks)

          # One pull for each chunk, and one pull that closes the stream.
          assert :counters.get(pulls, 1) == @chunks + 1
          assert_standard_pulls(desired, @high_water_mark)
        end
      end
    end
  end

  describe "a byte stream" do
    test "has the high water mark 0: a pull comes only for a read" do
      test = self()

      stream =
        ReadableStream.new(%{
          type: "bytes",
          pull: fn controller ->
            send(test, {:pull, Web.ReadableByteStreamController.desired_size(controller)})
            Web.ReadableByteStreamController.enqueue(controller, Web.Uint8Array.from("ab"))
            Web.ReadableByteStreamController.close(controller)
          end
        })

      settle(stream)
      refute_received {:pull, _desired}

      assert Enum.map(stream, &Web.Uint8Array.to_binary/1) == ["ab"]
      assert_received {:pull, 0}
    end
  end

  describe "a stream from an enumerable" do
    defp counting_enumerable(counter) do
      Stream.map(1..@chunks, fn index ->
        :counters.add(counter, 1, 1)
        index
      end)
    end

    test "does not advance the enumerable before a read" do
      counter = :counters.new(1, [])
      stream = ReadableStream.from(counting_enumerable(counter))

      settle(stream)
      assert :counters.get(counter, 1) == 0
    end

    test "advances one element for each chunk of an enumeration" do
      counter = :counters.new(1, [])

      Enum.reduce(ReadableStream.from(counting_enumerable(counter)), 1, fn chunk, expected ->
        assert chunk == expected
        assert :counters.get(counter, 1) == chunk
        expected + 1
      end)
    end

    test "advances one element for each chunk of a for loop" do
      counter = :counters.new(1, [])

      for chunk <- ReadableStream.from(counting_enumerable(counter)) do
        assert :counters.get(counter, 1) == chunk
      end
    end

    test "advances no more than the destination of a pipe wants" do
      counter = :counters.new(1, [])
      test = self()

      sink =
        WritableStream.new(
          %{
            write: fn chunk, _controller -> send(test, {:w, chunk, :counters.get(counter, 1)}) end
          },
          high_water_mark: 2
        )

      stream = ReadableStream.from(counting_enumerable(counter))
      assert :ok = await(ReadableStream.pipe_to(stream, sink))

      # At the write of a chunk, the pipe read the chunks that the
      # destination wanted: the chunk, and the free places of its queue.
      for index <- 1..@chunks do
        assert_received {:w, ^index, advanced}
        assert advanced <= index + 2
      end
    end

    test "advances one element for each pull of a tee branch" do
      counter = :counters.new(1, [])
      [left, _right] = ReadableStream.tee(ReadableStream.from(counting_enumerable(counter)))

      # Each branch has the high water mark 1: the tee reads one chunk for
      # the pull at the start of a branch. The pull of a branch is complete
      # when the tee starts its read, before the chunk comes, thus the test
      # waits for the chunk in the queue of the branch.
      wait_for_queue(left, 1)
      settle(left)
      assert :counters.get(counter, 1) == 1

      # The enumerable can be ahead of the chunk that the reader has by the
      # chunk in the queue of the branch (the high water mark 1), and by a
      # read of the tee that is in progress. It never stays behind.
      for chunk <- left do
        assert :counters.get(counter, 1) in chunk..(chunk + 2)
      end
    end

    property "an enumeration advances the enumerable one element for each chunk" do
      check all(count <- integer(0..60), max_runs: 50) do
        counter = :counters.new(1, [])

        enumerable =
          Stream.map(1..count//1, fn index ->
            :counters.add(counter, 1, 1)
            index
          end)

        chunks =
          for chunk <- ReadableStream.from(enumerable) do
            assert :counters.get(counter, 1) == chunk
            chunk
          end

        assert chunks == Enum.to_list(1..count//1)
      end
    end
  end
end
