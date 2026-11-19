defmodule Web.StreamWorkerTest do
  # The callbacks of a stream run in one worker process, and the internal
  # readers read the chunks in batches.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.ReadableStreamDefaultReader
  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  # A source that gives the integers from 1 to `count`, and tells the test
  # the process and the demand of each pull.
  defp counting_source(test, count) do
    counter = :counters.new(1, [])

    %{
      pull: fn controller ->
        :counters.add(counter, 1, 1)
        index = :counters.get(counter, 1)
        send(test, {:pull, self(), index, Web.Stream.pull_demand()})

        if index <= count do
          ReadableStreamDefaultController.enqueue(controller, index)
        else
          ReadableStreamDefaultController.close(controller)
        end
      end
    }
  end

  defp pulls(acc \\ []) do
    receive do
      {:pull, pid, index, demand} -> pulls([{pid, index, demand} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "the worker" do
    test "runs each callback of a stream in one process" do
      stream = ReadableStream.new(counting_source(self(), 100))

      assert Enum.to_list(stream) == Enum.to_list(1..100)

      workers = pulls() |> Enum.map(fn {pid, _index, _demand} -> pid end) |> Enum.uniq()
      assert [worker] = workers
      refute worker == stream.controller_pid
      refute worker == self()
    end

    test "stops when the stream stops" do
      stream = ReadableStream.new(counting_source(self(), 3))
      monitor = Process.monitor(stream.controller_pid)

      assert Enum.to_list(stream) == [1, 2, 3]
      assert [{worker, _index, _demand} | _pulls] = pulls()

      assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 10_000
      eventually(fn -> not Process.alive?(worker) end)
    end

    test "is killed at a cancel while a pull waits, and a new worker runs the cancel" do
      test = self()

      stream =
        ReadableStream.new(%{
          pull: fn _controller ->
            send(test, {:pull, self()})

            receive do
              :never -> :ok
            end
          end,
          cancel: fn reason -> send(test, {:cancel, self(), reason}) end
        })

      assert_receive {:pull, pull_worker}

      assert :ok = await(ReadableStream.cancel(stream, :stop))
      assert_receive {:cancel, cancel_worker, :stop}

      refute Process.alive?(pull_worker)
      refute cancel_worker == pull_worker
    end

    test "a callback that raises does not stop the stream process" do
      stream = ReadableStream.new(%{pull: fn _controller -> raise "the pull failed" end})

      error = assert_raise RuntimeError, fn -> Enum.to_list(stream) end
      assert error.message == "the pull failed"

      # The stream is errored, and its process answers.
      assert Process.alive?(stream.controller_pid)
      assert ReadableStream.__get_slots__(stream.controller_pid).state == :errored
    end

    test "a worker that stops during a callback makes the stream errored" do
      test = self()

      sink =
        WritableStream.new(%{
          write: fn _chunk, _controller ->
            send(test, {:write, self()})

            receive do
              :never -> :ok
            end
          end
        })

      writer = WritableStream.get_writer(sink)
      write = WritableStreamDefaultWriter.write(writer, "chunk")
      assert_receive {:write, worker}

      Process.exit(worker, :the_worker_stopped)

      assert catch_exit(await(write)) == :the_worker_stopped
      assert WritableStream.__get_slots__(sink.controller_pid).state == :errored
    end
  end

  describe "a batch read" do
    test "gives the chunks of the queue in their sequence" do
      stream =
        ReadableStream.new(
          %{
            start: fn controller ->
              Enum.each(1..10, &ReadableStreamDefaultController.enqueue(controller, &1))
              ReadableStreamDefaultController.close(controller)
            end
          },
          high_water_mark: 0
        )

      reader = ReadableStream.get_reader(stream)

      assert ReadableStreamDefaultReader.read_batch_now(reader, 4) == {:ok, [1, 2, 3, 4]}
      assert ReadableStreamDefaultReader.read_batch_now(reader, 4) == {:ok, [5, 6, 7, 8]}
      assert {:ok, %{value: 9}} = ReadableStreamDefaultReader.read_now(reader)
      assert ReadableStreamDefaultReader.read_batch_now(reader, 4) == {:ok, [10]}
      assert ReadableStreamDefaultReader.read_batch_now(reader, 4) == :done
    end

    test "waits for one chunk when the queue is empty" do
      test = self()

      stream =
        ReadableStream.new(%{
          start: fn controller -> send(test, {:controller, controller}) end
        })

      assert_receive {:controller, controller}
      reader = ReadableStream.get_reader(stream)
      read = Task.async(fn -> ReadableStreamDefaultReader.read_batch_now(reader, 8) end)
      refute Task.yield(read, 50)

      ReadableStreamDefaultController.enqueue(controller, :first)
      assert Task.await(read) == {:ok, [:first]}
    end

    test "makes the source fill the queue, and the limit goes back at a release" do
      stream = ReadableStream.new(counting_source(self(), 1_000))
      reader = ReadableStream.get_reader(stream)

      assert {:ok, [1]} = ReadableStreamDefaultReader.read_batch_now(reader, 8)

      # The stream pulls until its queue has 8 chunks: a pull gives a demand
      # of more than one chunk.
      eventually(fn ->
        ReadableStream.__get_slots__(stream.controller_pid).total_queued_size == 8
      end)

      assert Enum.any?(pulls(), fn {_pid, _index, demand} -> demand > 1 end)

      assert {:ok, chunks} = ReadableStreamDefaultReader.read_batch_now(reader, 8)
      assert chunks == Enum.to_list(2..9)

      ReadableStreamDefaultReader.release_lock(reader)
      assert ReadableStream.__get_slots__(stream.controller_pid).read_ahead == 0
    end

    test "gives the error of the stream, and refuses a process that has no lock" do
      stream =
        ReadableStream.new(%{
          pull: fn controller -> ReadableStreamDefaultController.error(controller, :bad) end
        })

      reader = ReadableStream.get_reader(stream)
      assert ReadableStreamDefaultReader.read_batch_now(reader, 4) == {:error, :bad}

      other = ReadableStream.new()

      assert {:error, %Web.TypeError{}} =
               other.controller_pid
               |> ReadableStream.read_batch(self(), 4)
               |> ReadableStreamDefaultReader.batch_result()
    end

    test "a stream with a byte strategy does not read ahead" do
      source = %{
        pull: fn controller -> ReadableStreamDefaultController.enqueue(controller, "x") end
      }

      stream = ReadableStream.new(source, strategy: Web.ByteLengthQueuingStrategy.new(1))

      reader = ReadableStream.get_reader(stream)
      assert {:ok, _chunks} = ReadableStreamDefaultReader.read_batch_now(reader, 64)
      assert ReadableStream.__get_slots__(stream.controller_pid).read_ahead == 0
    end
  end

  describe "a stream from an enumerable" do
    test "gives each chunk of a pull when the enumerable gives it" do
      test = self()

      enumerable =
        Stream.map(1..5, fn index ->
          if index == 2, do: Process.sleep(100)
          send(test, {:produced, index, System.monotonic_time(:millisecond)})
          index
        end)

      reader = ReadableStream.get_reader(ReadableStream.from(enumerable))

      assert {:ok, [1]} = ReadableStreamDefaultReader.read_batch_now(reader, 4)
      read_at = System.monotonic_time(:millisecond)
      assert_receive {:produced, 2, produced_at}, 1_000

      # The first chunk did not wait for the slow second chunk.
      assert read_at < produced_at
    end

    test "a cancel stops the enumerable between two chunks of a pull" do
      test = self()

      enumerable =
        Stream.resource(
          fn -> 0 end,
          fn index ->
            Process.sleep(20)
            {[index], index + 1}
          end,
          fn _index -> send(test, :enumerable_ended) end
        )

      reader = ReadableStream.get_reader(ReadableStream.from(enumerable))
      assert {:ok, [0]} = ReadableStreamDefaultReader.read_batch_now(reader, 64)

      assert :ok = await(ReadableStreamDefaultReader.cancel(reader, :stop))
      assert_receive :enumerable_ended, 1_000
    end

    test "the enumerator stops when the stream process stops" do
      test = self()

      enumerable =
        Stream.resource(
          fn -> send(test, {:enumerator, self()}) end,
          fn acc -> {[1], acc} end,
          fn _acc -> send(test, :enumerable_ended) end
        )

      stream = ReadableStream.from(enumerable)
      assert_receive {:enumerator, enumerator}

      Process.exit(stream.controller_pid, :kill)

      assert_receive :enumerable_ended, 1_000
      eventually(fn -> not Process.alive?(enumerator) end)
    end
  end

  describe "a pipe" do
    test "reads no chunk that the destination does not want" do
      test = self()
      stream = ReadableStream.new(counting_source(test, 1_000))

      sink =
        WritableStream.new(%{
          high_water_mark: 2,
          write: fn chunk, _controller ->
            send(test, {:written, chunk})

            receive do
              :continue -> :ok
            end
          end
        })

      _pipe = ReadableStream.pipe_to(stream, sink)
      assert_receive {:written, 1}
      Process.sleep(50)

      # The pipe has the chunks of one batch at most: two, the limit of the
      # destination. The source has one more chunk for its own limit.
      assert length(pulls()) <= 2 + 1 + 1
    end

    test "sends the writes of a batch, and keeps their sequence" do
      test = self()

      sink =
        WritableStream.new(%{
          high_water_mark: 16,
          write: fn chunk, _controller -> send(test, {:written, chunk}) end
        })

      assert :ok = await(ReadableStream.pipe_to(ReadableStream.from(1..200), sink))

      for index <- 1..200, do: assert_received({:written, ^index})
    end

    test "rejects when the destination stops during a batch of writes" do
      test = self()
      counter = :counters.new(1, [])

      sink =
        WritableStream.new(%{
          high_water_mark: 4,
          write: fn _chunk, _controller ->
            :counters.add(counter, 1, 1)
            send(test, {:writing, self(), :counters.get(counter, 1)})

            # The first write waits for the test. The next writes wait with
            # no end.
            receive do
              :go -> :ok
            end
          end
        })

      # The queue of the source has 8 chunks when the first write ends.
      source = ReadableStream.from_enumerable(Stream.cycle([1]), high_water_mark: 8)
      pipe = ReadableStream.pipe_to(source, sink)
      assert_receive {:writing, worker, 1}

      eventually(fn ->
        ReadableStream.__get_slots__(source.controller_pid).total_queued_size == 8
      end)

      # The second batch has two chunks: the pipe sends their writes and
      # waits for the first of them.
      send(worker, :go)
      assert_receive {:writing, _worker, 2}
      Process.exit(sink.controller_pid, :kill)

      assert %Web.TypeError{} = catch_exit(await(pipe))
    end

    test "gives the first failure of a batch of writes" do
      sink =
        WritableStream.new(%{
          high_water_mark: 8,
          write: fn chunk, _controller -> if chunk == 3, do: raise("write #{chunk} failed") end
        })

      pipe = ReadableStream.pipe_to(ReadableStream.from(1..20), sink)

      assert %RuntimeError{message: "write 3 failed"} = catch_exit(await(pipe))
    end
  end

  describe "properties" do
    property "an enumeration gives the chunks of an enumerable in their sequence" do
      check all(
              chunks <- list_of(term(), max_length: 300),
              high_water_mark <- integer(0..8),
              max_runs: 100
            ) do
        stream = ReadableStream.from_enumerable(chunks, high_water_mark: high_water_mark)
        assert Enum.to_list(stream) == chunks
      end
    end

    property "batch reads and single reads together keep the sequence" do
      check all(
              count <- integer(0..200),
              sizes <- list_of(integer(0..10), min_length: 1, max_length: 40),
              max_runs: 100
            ) do
        reader = ReadableStream.get_reader(ReadableStream.from_enumerable(1..count//1, []))
        assert read_all(reader, sizes, sizes) == Enum.to_list(1..count//1)
      end
    end
  end

  # Reads all the chunks with the sizes of the list, again and again. A size
  # of 0 is a single read.
  defp read_all(reader, [], all), do: read_all(reader, all, all)

  defp read_all(reader, [size | sizes], all) do
    case read(reader, size) do
      :done ->
        []

      {:ok, chunks} ->
        assert length(chunks) <= max(size, 1)
        chunks ++ read_all(reader, sizes, all)
    end
  end

  defp read(reader, 0) do
    case ReadableStreamDefaultReader.read_now(reader) do
      {:ok, %{done: true}} -> :done
      {:ok, %{value: chunk}} -> {:ok, [chunk]}
    end
  end

  defp read(reader, size), do: ReadableStreamDefaultReader.read_batch_now(reader, size)
end
