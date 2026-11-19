defmodule Web.StreamFlatMemoryTest do
  # A read of all the chunks of a stream must not keep the chunks, and must
  # not keep one process for each chunk.
  #
  # The tests count the processes and the binary memory of the VM, thus they
  # cannot run at the same time as other tests.
  use ExUnit.Case, async: false

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.WritableStream

  @chunks 2_000

  # A stream that gives `count` chunks. `make` makes the chunk of an index.
  defp source(count, make) do
    counter = :counters.new(1, [])

    ReadableStream.new(%{
      pull: fn controller ->
        :counters.add(counter, 1, 1)
        index = :counters.get(counter, 1)

        if index <= count do
          ReadableStreamDefaultController.enqueue(controller, make.(index))
        else
          ReadableStreamDefaultController.close(controller)
        end
      end
    })
  end

  defp processes, do: length(Process.list())

  test "an enumeration keeps no process for each chunk" do
    stream = source(@chunks, & &1)
    processes_before = processes()

    assert Enum.reduce(stream, 0, &(&1 + &2)) == div(@chunks * (@chunks + 1), 2)

    # With one promise for each chunk, 2000 processes stayed for 5 seconds.
    assert processes() - processes_before < 50
  end

  test "an enumeration that halts, and one that is suspended, keep no process" do
    processes_before = processes()

    assert Enum.take(source(@chunks, & &1), 1_000) == Enum.to_list(1..1_000)

    assert source(@chunks, & &1) |> Stream.zip(1..@chunks) |> Enum.count() == @chunks

    assert processes() - processes_before < 50
  end

  test "a pipe keeps no process for each chunk" do
    test = self()
    stream = source(@chunks, & &1)

    sink =
      WritableStream.new(%{
        write: fn chunk, _controller -> if chunk == @chunks, do: send(test, :last_chunk) end
      })

    processes_before = processes()

    assert :ok = Web.await(ReadableStream.pipe_to(stream, sink))
    assert_received :last_chunk

    assert processes() - processes_before < 50
  end

  test "an enumeration does not keep the chunks" do
    chunk_size = 65_536
    count = 1_000
    total = chunk_size * count
    # Each chunk is a new binary of 64 KiB.
    stream = source(count, fn index -> :binary.copy(<<rem(index, 256)>>, chunk_size) end)

    :erlang.garbage_collect()
    binary_before = :erlang.memory(:binary)

    assert Enum.reduce(stream, 0, &(byte_size(&1) + &2)) == total

    :erlang.garbage_collect()
    :erlang.garbage_collect(stream.controller_pid)
    kept = :erlang.memory(:binary) - binary_before

    # With one promise for each chunk, the VM kept all the 64 MiB for
    # 5 seconds.
    assert kept < div(total, 8)
  end

  test "the stack of an enumeration does not increase with the number of chunks" do
    stream = source(20_000, & &1)

    largest =
      Enum.reduce(stream, 0, fn _chunk, largest ->
        {:stack_size, size} = Process.info(self(), :stack_size)
        max(size, largest)
      end)

    # The first code had one stack frame for each chunk.
    assert largest < 1_000
  end
end
