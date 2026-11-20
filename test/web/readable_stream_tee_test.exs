defmodule Web.ReadableStreamTeeTest do
  # These tests set the linger time for the application. Thus they cannot
  # run at the same time as other tests.
  use ExUnit.Case, async: false
  use ExUnitProperties
  use Web

  alias Web.ArrayBuffer
  alias Web.Internal.ReadableStreamTee
  alias Web.ReadableStreamBYOBReader
  alias Web.Uint8Array

  @linger 100

  setup do
    previous = Application.get_env(:web, :linger)
    Application.put_env(:web, :linger, @linger)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:web, :linger)
      else
        Application.put_env(:web, :linger, previous)
      end
    end)
  end

  defp assert_down(pid, timeout \\ 2_000) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, timeout
  end

  # A source that gives the integers from 0 with no end, and tells the test
  # each pull and its cancel.
  defp counting_source(parent) do
    # A counter with no process. It stays when the process that made it stops.
    counter = :counters.new(1, [])

    %{
      pull: fn controller ->
        index = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        send(parent, {:pulled, index})
        ReadableStreamDefaultController.enqueue(controller, index)
      end,
      cancel: fn reason -> send(parent, {:cancelled, reason}) end
    }
  end

  defp read(reader), do: await(ReadableStreamDefaultReader.read(reader))

  # The process that holds the reader lock of the stream: the tee process.
  defp tee_process(stream), do: ReadableStream.__get_slots__(stream.controller_pid).reader_pid

  describe "the chunks" do
    test "go to the two branches in sequence" do
      [left, right] = ReadableStream.tee(ReadableStream.from(["a", "b", "c"]))
      assert Enum.to_list(left) == ["a", "b", "c"]
      assert Enum.to_list(right) == ["a", "b", "c"]
    end

    test "are the same terms in the two branches" do
      chunk = %{nested: [1, {:two, "three"}]}
      [left, right] = ReadableStream.tee(ReadableStream.from([chunk]))
      assert Enum.to_list(left) == [chunk]
      assert Enum.to_list(right) == [chunk]
    end

    test "can be read from the two branches in turn" do
      [left, right] = ReadableStream.tee(ReadableStream.from([1, 2, 3]))
      left_reader = ReadableStream.get_reader(left)
      right_reader = ReadableStream.get_reader(right)

      assert read(left_reader) == %{value: 1, done: false}
      assert read(right_reader) == %{value: 1, done: false}
      assert read(right_reader) == %{value: 2, done: false}
      assert read(left_reader) == %{value: 2, done: false}
      assert read(left_reader) == %{value: 3, done: false}
      assert read(left_reader) == %{value: nil, done: true}
      assert read(right_reader) == %{value: 3, done: false}
      assert read(right_reader) == %{value: nil, done: true}
    end

    test "can be read from the two branches at the same time" do
      chunks = Enum.to_list(1..200)
      [left, right] = ReadableStream.tee(ReadableStream.from(chunks))

      tasks = for branch <- [left, right], do: Task.async(fn -> Enum.to_list(branch) end)
      assert Task.await_many(tasks, 10_000) == [chunks, chunks]
    end

    property "are the same in the two branches as in the stream" do
      check all(chunks <- list_of(term(), max_length: 30), max_runs: 50) do
        [left, right] = ReadableStream.tee(ReadableStream.from(chunks))
        assert Enum.to_list(right) == chunks
        assert Enum.to_list(left) == chunks
      end
    end

    property "are complete for each sequence of reads from the two branches" do
      check all(
              chunks <- list_of(integer(), max_length: 20),
              turns <- list_of(member_of([:left, :right]), max_length: 60),
              max_runs: 50
            ) do
        [left, right] = ReadableStream.tee(ReadableStream.from(chunks))

        readers = %{
          left: ReadableStream.get_reader(left),
          right: ReadableStream.get_reader(right)
        }

        seen =
          Enum.reduce(turns, %{left: [], right: []}, fn side, seen ->
            case read(readers[side]) do
              %{value: value, done: false} -> Map.update!(seen, side, &[value | &1])
              %{done: true} -> seen
            end
          end)

        # Each branch gives a prefix of the chunks. Its length is the number
        # of reads from that branch, or the number of chunks.
        for side <- [:left, :right] do
          reads = Enum.count(turns, &(&1 == side))
          assert Enum.reverse(seen[side]) == Enum.take(chunks, reads)
        end

        for {_side, reader} <- readers, do: ReadableStreamDefaultReader.cancel(reader)
      end
    end
  end

  describe "a branch that no process reads" do
    test "does not slow down the other branch, and keeps each chunk" do
      chunks = Enum.to_list(1..2_000)
      [left, right] = ReadableStream.tee(ReadableStream.from(chunks))

      # The queue of the second branch has no limit, as in the Streams
      # Standard. A branch with a limit would stop this read.
      assert Enum.to_list(left) == chunks
      assert Enum.to_list(right) == chunks
    end
  end

  describe "the stream" do
    test "is locked immediately, and tee/1 raises for a locked stream" do
      stream = ReadableStream.from(["a"])
      [_left, _right] = ReadableStream.tee(stream)

      assert ReadableStream.locked?(stream)
      assert_raise Web.TypeError, ~r/already locked/, fn -> ReadableStream.tee(stream) end
      assert_raise Web.TypeError, ~r/already locked/, fn -> ReadableStream.get_reader(stream) end

      held = ReadableStream.from(["a"])
      _reader = ReadableStream.get_reader(held)
      assert_raise Web.TypeError, ~r/already locked/, fn -> ReadableStream.tee(held) end
    end

    test "can be disturbed: the branches give the chunks that are not read" do
      stream = ReadableStream.from([1, 2, 3])
      reader = ReadableStream.get_reader(stream)
      assert read(reader) == %{value: 1, done: false}
      ReadableStreamDefaultReader.release_lock(reader)

      [left, right] = ReadableStream.tee(stream)
      assert Enum.to_list(left) == [2, 3]
      assert Enum.to_list(right) == [2, 3]
    end

    test "raises for a stream that stopped" do
      stream = ReadableStream.from([])
      assert Enum.to_list(stream) == []
      assert_down(stream.controller_pid)

      assert_raise Web.TypeError, ~r/not available/, fn -> ReadableStream.tee(stream) end
    end

    test "is read only when a branch needs a chunk" do
      stream = ReadableStream.new(counting_source(self()))
      [left, _right] = ReadableStream.tee(stream)
      reader = ReadableStream.get_reader(left)

      assert read(reader) == %{value: 0, done: false}
      assert read(reader) == %{value: 1, done: false}
      Process.sleep(100)

      # The source filled its own queue and the queues of the branches. It
      # did not continue without a read.
      pulls =
        for _ <- 1..20,
            (receive do
               {:pulled, index} -> index
             after
               0 -> nil
             end) != nil,
            do: 1

      assert length(pulls) <= 6
    end

    test "gives its error to the two branches immediately, and they discard their chunks" do
      stream = ReadableStream.new(%{})
      ReadableStream.enqueue(stream.controller_pid, "first")

      [left, right] = ReadableStream.tee(stream)
      left_reader = ReadableStream.get_reader(left)
      right_reader = ReadableStream.get_reader(right)

      assert read(left_reader) == %{value: "first", done: false}

      # The second branch has the chunk in its queue. No read is in progress.
      ReadableStream.error(stream.controller_pid, :source_failed)

      assert catch_exit(await(ReadableStreamDefaultReader.closed(left_reader))) == :source_failed
      assert catch_exit(read(left_reader)) == :source_failed

      # The two branches get the error in sequence. Wait for the second one.
      assert catch_exit(await(ReadableStreamDefaultReader.closed(right_reader))) == :source_failed
      assert catch_exit(read(right_reader)) == :source_failed
    end

    test "gives the error of a pull to the two branches" do
      stream =
        ReadableStream.new(%{
          pull: fn controller ->
            ReadableStreamDefaultController.error(controller, :pull_failed)
          end
        })

      [left, right] = ReadableStream.tee(stream)

      assert catch_exit(read(ReadableStream.get_reader(left))) == :pull_failed
      assert catch_exit(read(ReadableStream.get_reader(right))) == :pull_failed
    end

    test "that stops with a failure gives an error to the two branches" do
      stream = ReadableStream.new(%{})
      [left, right] = ReadableStream.tee(stream)
      tee = tee_process(stream)

      pending =
        Task.async(fn ->
          try do
            Enum.to_list(left)
          rescue
            error -> error
          end
        end)

      Process.sleep(50)

      # A message that is not for the tee has no effect.
      send(tee, :not_for_the_tee)

      Process.exit(stream.controller_pid, :kill)

      assert %Web.TypeError{message: message} = Task.await(pending)
      assert message =~ "not available"
      assert_raise Web.TypeError, ~r/not available/, fn -> Enum.to_list(right) end
      assert_down(tee)
    end

    test "that a tee completed ignores the messages that come later" do
      stream = ReadableStream.from(["a"])
      [left, right] = ReadableStream.tee(stream)
      tee = tee_process(stream)

      assert Enum.to_list(left) == ["a"]
      assert Enum.to_list(right) == ["a"]

      send(tee, :not_for_the_tee)
      ReadableStreamTee.pull(tee, 1)
      ReadableStreamTee.cancel(tee, 1, :late)
      assert Process.alive?(tee)
      assert_down(tee)
    end

    test "that is a byte stream gives two byte streams" do
      stream = ReadableStream.new(%{type: "bytes"})
      ReadableStream.enqueue(stream.controller_pid, "hello world")
      ReadableStream.close(stream.controller_pid)

      [left, right] = ReadableStream.tee(stream)
      reader = ReadableStream.get_reader(left, mode: "byob")

      assert %{value: value, done: false} =
               await(ReadableStreamBYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(5))))

      assert Uint8Array.to_binary(value) == "hello"
      assert Web.TestBytes.join(right) == "hello world"
    end
  end

  describe "a cancel" do
    test "of one branch has no effect on the stream and on the other branch" do
      stream = ReadableStream.new(counting_source(self()))
      [left, right] = ReadableStream.tee(stream)
      right_reader = ReadableStream.get_reader(right)

      left_cancel = ReadableStream.cancel(left, :left_reason)
      refute_receive {:cancelled, _reason}, 100

      assert read(right_reader) == %{value: 0, done: false}
      assert read(right_reader) == %{value: 1, done: false}
      assert read(right_reader) == %{value: 2, done: false}

      # The promise of the cancel stays pending until the second branch is
      # cancelled, as in the Streams Standard.
      assert Promise.peek(left_cancel) == :pending
      assert await(ReadableStreamDefaultReader.cancel(right_reader, :right_reason)) == :ok
      assert await(left_cancel) == :ok
    end

    test "of one branch settles when the stream ends" do
      stream = ReadableStream.from([1, 2])
      [left, right] = ReadableStream.tee(stream)

      left_cancel = ReadableStream.cancel(left, :left_reason)
      assert Enum.to_list(right) == [1, 2]
      assert await(left_cancel) == :ok
    end

    test "rejects for the two branches with the value that the cancel callback throws" do
      stream = ReadableStream.new(%{cancel: fn _reason -> raise "cancel failed" end})
      [left, right] = ReadableStream.tee(stream)

      left_cancel = ReadableStream.cancel(left, :one)
      right_cancel = ReadableStream.cancel(right, :two)

      assert %RuntimeError{message: "cancel failed"} = catch_exit(await(left_cancel))
      assert %RuntimeError{message: "cancel failed"} = catch_exit(await(right_cancel))
    end

    test "of the two branches cancels the stream with the list of the two reasons" do
      stream = ReadableStream.new(counting_source(self()))
      [left, right] = ReadableStream.tee(stream)
      tee = tee_process(stream)

      left_cancel = ReadableStream.cancel(left, :left_reason)
      assert await(ReadableStream.cancel(right, :right_reason)) == :ok
      assert await(left_cancel) == :ok

      # The two promises settle after the cancel callback of the stream.
      assert_received {:cancelled, [:left_reason, :right_reason]}
      assert_down(tee)
    end

    test "gives the reason of the first branch first, for each sequence of the cancels" do
      stream = ReadableStream.new(counting_source(self()))
      [left, right] = ReadableStream.tee(stream)

      right_cancel = ReadableStream.cancel(right, :right_reason)
      refute_receive {:cancelled, _reason}, 100
      assert await(ReadableStream.cancel(left, :left_reason)) == :ok
      assert await(right_cancel) == :ok

      assert_received {:cancelled, [:left_reason, :right_reason]}
    end

    test "of the two branches is possible while a read is in progress" do
      parent = self()

      # The source gives no chunk. Thus the read of the tee stays pending.
      stream = ReadableStream.new(%{cancel: fn reason -> send(parent, {:cancelled, reason}) end})
      [left, right] = ReadableStream.tee(stream)

      pending = Task.async(fn -> Enum.to_list(left) end)
      Process.sleep(50)

      first = ReadableStream.cancel(left.controller_pid, :one)
      assert await(ReadableStream.cancel(right, :two)) == :ok
      assert await(first) == :ok

      assert_received {:cancelled, [:one, :two]}
      assert Task.await(pending) == []
    end

    test "comes from a halt of an enumeration" do
      stream = ReadableStream.new(counting_source(self()))
      [left, right] = ReadableStream.tee(stream)

      assert Enum.take(left, 2) == [0, 1]
      refute_receive {:cancelled, _reason}, 100
      assert Enum.take(right, 3) == [0, 1, 2]

      assert_receive {:cancelled, [:halted, :halted]}
    end
  end

  # A process in the place of a branch. It answers the question of the tee
  # about a chunk, and ignores each other message.
  defp wanting_branch(wants? \\ true) do
    receive do
      {:"$gen_call", from, :wants_chunk?} -> :gen_statem.reply(from, wants?)
      _other -> :ok
    end

    wanting_branch(wants?)
  end

  describe "the processes of a tee" do
    test "do no read for a pull of a branch that has its chunk already" do
      # A pull is a message: it can come after the read that gave the
      # branch its chunk. The Streams Standard drops such a pull.
      parent = self()
      stream = ReadableStream.new(counting_source(parent), high_water_mark: 0)
      {:ok, tee} = ReadableStreamTee.start(stream.controller_pid)

      full = spawn(fn -> wanting_branch(false) end)
      wanting = spawn(fn -> wanting_branch(true) end)
      assert :ok = ReadableStreamTee.attach(tee, full, wanting)

      ReadableStreamTee.pull(tee, 1)
      refute_receive {:pulled, _index}, 50

      ReadableStreamTee.pull(tee, 2)
      assert_receive {:pulled, 0}

      Enum.each([full, wanting], &Process.exit(&1, :kill))
    end

    test "do no read of the source before a branch pulls" do
      parent = self()
      stream = ReadableStream.new(counting_source(parent), high_water_mark: 0)
      {:ok, tee} = ReadableStreamTee.start(stream.controller_pid)

      # Two branches that do not pull. They tell the tee that they want a
      # chunk.
      branches = for _index <- 1..2, do: spawn(fn -> wanting_branch() end)
      [branch1, branch2] = branches
      assert :ok = ReadableStreamTee.attach(tee, branch1, branch2)
      refute_receive {:pulled, _index}, 50

      ReadableStreamTee.pull(tee, 1)
      assert_receive {:pulled, 0}

      Enum.each(branches, &Process.exit(&1, :kill))
    end

    test "stop when the stream ends" do
      stream = ReadableStream.from(["a", "b"])
      [left, right] = ReadableStream.tee(stream)
      tee = tee_process(stream)
      assert is_pid(tee)

      assert Enum.to_list(left) == ["a", "b"]
      assert Enum.to_list(right) == ["a", "b"]

      # The stream stays locked until it stops, as in the Streams Standard.
      assert ReadableStream.locked?(stream)

      for pid <- [left.controller_pid, right.controller_pid, stream.controller_pid, tee] do
        assert_down(pid)
      end
    end

    test "stop when the owner stops and no process reads the branches" do
      parent = self()

      owner =
        spawn(fn ->
          stream = ReadableStream.new(counting_source(parent))
          branches = ReadableStream.tee(stream)
          send(parent, {:tee, stream, branches, tee_process(stream)})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:tee, stream, [left, right], tee}
      send(owner, :stop)

      assert_receive {:cancelled, [{:owner_down, :normal}, {:owner_down, :normal}]}, 2_000

      for pid <- [tee, left.controller_pid, right.controller_pid, stream.controller_pid] do
        assert_down(pid)
      end
    end

    test "stop immediately when the owner stops with a failure" do
      parent = self()

      owner =
        spawn(fn ->
          stream = ReadableStream.new(counting_source(parent), linger: 60_000)
          branches = ReadableStream.tee(stream)
          send(parent, {:tee, stream, branches, tee_process(stream)})
          Process.sleep(:infinity)
        end)

      assert_receive {:tee, stream, [left, right], tee}
      Process.exit(owner, :kill)

      assert_receive {:cancelled, [{:owner_down, :killed}, {:owner_down, :killed}]}, 1_000

      for pid <- [tee, left.controller_pid, right.controller_pid, stream.controller_pid] do
        assert_down(pid, 1_000)
      end
    end

    test "continue for a different process that reads one branch" do
      parent = self()

      owner =
        spawn(fn ->
          stream = ReadableStream.from(Enum.to_list(1..50))
          send(parent, {:branches, ReadableStream.tee(stream)})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:branches, [left, right]}
      reader = ReadableStream.get_reader(left)
      send(owner, :stop)
      assert_down(owner)

      # The branch that no process reads is cancelled after the linger time.
      assert_down(right.controller_pid)

      values =
        Stream.repeatedly(fn -> read(reader) end)
        |> Enum.take_while(&(not &1.done))
        |> Enum.map(& &1.value)

      assert values == Enum.to_list(1..50)
    end

    test "count a branch that stopped with a failure as a cancelled branch" do
      stream = ReadableStream.new(counting_source(self()))
      [left, right] = ReadableStream.tee(stream)
      tee = tee_process(stream)

      Process.exit(left.controller_pid, :kill)
      assert_down(left.controller_pid)
      refute_receive {:cancelled, _reason}, 100

      reader = ReadableStream.get_reader(right)
      assert %{done: false} = read(reader)

      Process.exit(right.controller_pid, :kill)
      assert_receive {:cancelled, [{:branch_down, :killed}, {:branch_down, :killed}]}
      assert_down(tee)
    end

    test "stop when the process that calls tee/1 stops before the branches exist" do
      stream = ReadableStream.from(["a"])
      test = self()

      caller =
        spawn(fn ->
          {:ok, tee} = ReadableStreamTee.start(stream.controller_pid)
          send(test, {:tee, tee})
          Process.sleep(:infinity)
        end)

      assert_receive {:tee, tee}
      assert ReadableStream.locked?(stream)

      # A message that is not for the tee has no effect.
      send(tee, :not_for_the_tee)
      assert Process.alive?(tee)

      Process.exit(caller, :kill)
      assert_down(tee)
      refute ReadableStream.locked?(stream)
    end
  end

  describe "a clone of a response" do
    test "can be read to its end while the other response is not read" do
      body = String.duplicate("x", 500_000)
      chunks = for <<part::binary-size(1_000) <- body>>, do: part
      response = Response.new(body: ReadableStream.from(chunks))

      {response, clone} = Response.clone(response)
      assert await(Response.text(clone)) == body
      assert await(Response.text(response)) == body
    end
  end
end
