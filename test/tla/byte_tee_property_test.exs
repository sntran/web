defmodule Web.TLA.ByteTeePropertyTest do
  # Checks the properties of `tla/ByteTee.tla` on the real tee of a byte
  # stream. The test cannot control each message between the branches, the
  # tee, and the source. Thus it does random operations, waits until the
  # processes are at rest, ends the source, and then checks:
  #
  #   * ReadsEnd: each read of a branch ends. At rest, a read waits only
  #     while the tee has its read in the source.
  #   * NoLostBuffer: a BYOB read that the end of the source ends has a view
  #     of 0 bytes in a buffer of the size of its view.
  #   * The bytes of each branch are the bytes of the source, in their
  #     sequence.
  #
  # Branch 1 reads with a BYOB reader, and branch 2 with a default reader,
  # as in the specification.
  #
  # The defect "lost_pull" of the specification: in the library, a branch
  # sends the pull that the bytes of a read cause after the tee handled the
  # read, thus the tee handles it with no read in progress. A tee with no
  # flags readAgainForBranch1 and readAgainForBranch2 thus passes this test.
  # A branch that does not pull after the bytes of a read
  # (ReadableByteStreamControllerCallPullIfNeeded) fails it: a second BYOB
  # read of a branch does not pull, as the Standard specifies.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.ArrayBuffer
  alias Web.ReadableByteStreamController, as: Controller
  alias Web.ReadableStream
  alias Web.ReadableStreamBYOBReader, as: BYOBReader
  alias Web.ReadableStreamBYOBRequest, as: Request
  alias Web.ReadableStreamDefaultReader, as: Reader
  alias Web.Uint8Array

  defp operation do
    frequency([
      {4, tuple({constant(:read), member_of([1, 2]), integer(1..3)})},
      {3, tuple({constant(:chunk), binary(min_length: 1, max_length: 3)})},
      {1, tuple({constant(:cancel), member_of([1, 2])})}
    ])
  end

  property "each read of a branch ends, with its buffer, and the bytes keep their sequence" do
    check all(
            operations <- list_of(operation(), max_length: 8),
            ending <- member_of([:close, :error, :cancel_source]),
            max_runs: 150
          ) do
      system = Enum.reduce(operations, start_system(), &run/2)

      # ReadsEnd, before the end of the source.
      assert eventually(fn -> at_rest?(system) end),
             "a read of a branch waits, and the tee has no read in the source"

      end_source(system, ending)
      results = Enum.map(Enum.reverse(system.reads), &await_read/1)

      for {{1, size}, {:fulfilled, %{value: %Uint8Array{} = value, done: true}}} <- results do
        # NoLostBuffer.
        assert value.byte_length == 0
        assert ArrayBuffer.byte_length(value.buffer) == size
      end

      chunks = system.chunks |> Enum.reverse() |> IO.iodata_to_binary()

      for index <- [1, 2] do
        given =
          for {{^index, _size}, {:fulfilled, %{value: %Uint8Array{} = value, done: false}}} <-
                results,
              into: "",
              do: Uint8Array.to_binary(value)

        assert String.starts_with?(chunks, given)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The real system
  # ---------------------------------------------------------------------------

  defp start_system do
    test = self()
    source = ReadableStream.new(%{type: "bytes", start: &send(test, {:controller, &1})})
    assert_receive {:controller, controller}
    [left, right] = ReadableStream.tee(source)

    %{
      source: source,
      controller: controller,
      tee: ReadableStream.__get_slots__(source.controller_pid).reader_pid,
      readers: %{
        1 => ReadableStream.get_reader(left, mode: "byob"),
        2 => ReadableStream.get_reader(right)
      },
      canceled: MapSet.new(),
      chunks: [],
      # The reads that started, the last first: `{ref, {index, size}}`.
      reads: []
    }
  end

  defp run({:read, index, size}, system) do
    read =
      if index == 1,
        do: fn -> BYOBReader.read(system.readers[1], Uint8Array.new(ArrayBuffer.new(size))) end,
        else: fn -> Reader.read(system.readers[2]) end

    %{system | reads: [{start_read(read), {index, size}} | system.reads]}
  end

  # The source is canceled after the cancel of the two branches: it takes
  # no more chunks.
  defp run({:chunk, bytes}, system) do
    if MapSet.size(system.canceled) == 2 do
      system
    else
      Controller.enqueue(system.controller, bytes)
      %{system | chunks: [bytes | system.chunks]}
    end
  end

  # The cancel of a branch waits for the cancel of the other branch.
  defp run({:cancel, index}, system) do
    if index == 1,
      do: BYOBReader.cancel(system.readers[1], :stop),
      else: Reader.cancel(system.readers[2], :stop)

    %{system | canceled: MapSet.put(system.canceled, index)}
  end

  # Each read waits in a different process: a read can wait while a read
  # waits.
  defp start_read(fun) do
    test = self()
    ref = make_ref()

    spawn(fn ->
      promise = fun.()
      send(test, {ref, :sent})
      send(test, {ref, Web.Promise.wait(promise)})
    end)

    assert_receive {^ref, :sent}
    ref
  end

  defp await_read({ref, read}) do
    assert_receive {^ref, outcome}, 2_000, "a read of a branch did not end: #{inspect(read)}"
    {read, outcome}
  end

  # The processes are at rest: no read waits, or the tee waits for the
  # answer of the source to its read, and the source has no bytes. The work
  # of a tee whose two branches are canceled is complete.
  defp at_rest?(system) do
    tee = :sys.get_state(system.tee)
    source = ReadableStream.__get_slots__(system.source.controller_pid)

    cond do
      is_reference(tee.source_monitor) -> true
      Enum.all?(system.reads, &ended?/1) -> true
      true -> tee.read != nil and source.total_queued_size == 0 and idle?(system.tee)
    end
  end

  # A read ended when its result is in the mailbox of the test.
  defp ended?({ref, _read}) do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.any?(messages, &match?({^ref, {status, _value}} when status != :sent, &1))
  end

  defp idle?(pid), do: Process.info(pid, :message_queue_len) == {:message_queue_len, 0}

  # A helper that examines the condition until it is true, or until the
  # limit.
  defp eventually(fun, attempts \\ 400) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  # The underlying source closes, and responds with 0 bytes to the BYOB
  # read that waits, as the Streams Standard specifies: the close does not
  # end a read into a view.
  defp close_source(controller) do
    Controller.close(controller)

    case Controller.byob_request(controller) do
      %Request{} = request -> Request.respond(request, 0)
      nil -> :ok
    end
  end

  # The source of a tee whose two branches are canceled is canceled.
  defp end_source(system, ending) do
    if MapSet.size(system.canceled) < 2 do
      case ending do
        :close -> close_source(system.controller)
        :error -> Controller.error(system.controller, :failed)
        :cancel_source -> :ok = await(ReadableStream.cancel(system.source.controller_pid, :stop))
      end
    end
  end
end
