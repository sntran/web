defmodule Web.Internal.LazyStreamTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Internal.LazyStream
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultReader
  alias Web.Uint8Array

  defp read_all(reader) do
    case Web.await(ReadableStreamDefaultReader.read(reader)) do
      %{done: true} -> []
      %{value: chunk} -> [Uint8Array.to_binary(chunk) | read_all(reader)]
    end
  end

  defp text(body), do: Web.await(Web.Response.text(%Web.Response{body: body}))

  defp stop(pid) do
    ref = Process.monitor(pid)
    Web.Stream.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  # A process that registers itself as the stream process of `lazy`, and
  # tells it to `parent`. It answers each call, such as the keep of a copy,
  # with `:ok`.
  defp fake_stream(lazy, parent) do
    spawn(fn ->
      {:ok, _owner} = Registry.register(LazyStream.registry(), lazy.ref, nil)
      send(parent, :registered)
      fake_loop()
    end)
  end

  defp fake_loop do
    receive do
      {:"$gen_call", from, _request} ->
        GenServer.reply(from, :ok)
        fake_loop()

      :stop ->
        :ok
    end
  end

  # The process waits for the answer of a call.
  defp calls?(pid) do
    Process.info(pid, :current_function) == {:current_function, {:gen, :do_call, 4}}
  end

  # The process waits for the end of a starter.
  defp waits_for_down?(pid) do
    Process.info(pid, :current_function) == {:current_function, {LazyStream, :await_down, 1}}
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && wait_until(fun, attempts - 1)
    end
  end

  describe "a stream of bytes with no process" do
    test "has no process until a stream read, and each copy finds the process" do
      stream = ReadableStream.from("hello")
      assert stream.controller_pid == nil
      assert LazyStream.state(stream.lazy) == :readable

      copy = Task.async(fn -> stream end) |> Task.await()
      reader = ReadableStream.get_reader(stream, [])

      assert {:process, pid} = LazyStream.state(copy.lazy)
      assert pid == reader.controller_pid
      assert ReadableStream.locked?(copy)
      assert read_all(reader) == ["hello"]
    end

    test "gives a closed stream to a stream read after a cancel" do
      stream = ReadableStream.from("hello")
      assert :ok = Web.await(ReadableStream.cancel(stream))
      assert LazyStream.state(stream.lazy) == :canceled
      assert ReadableStream.disturbed?(stream)

      assert ReadableStream.get_reader(stream) |> read_all() == []
    end

    test "a cancel of a stream that was read to its end has no effect" do
      stream = ReadableStream.from("hello")
      assert Enum.map(stream, &Uint8Array.to_binary/1) == ["hello"]

      assert :ok = Web.await(ReadableStream.cancel(stream))
      assert LazyStream.state(stream.lazy) == :consumed
    end

    test "a cancel after the start of the process cancels the process" do
      stream = ReadableStream.from("hello")
      reader = ReadableStream.get_reader(stream)
      :ok = ReadableStreamDefaultReader.release_lock(reader)

      assert :ok = Web.await(ReadableStream.cancel(stream))
      assert Enum.to_list(stream) == []
    end

    test "an enumeration after the start of the process reads the process" do
      stream = ReadableStream.from("hello")
      reader = ReadableStream.get_reader(stream)
      :ok = ReadableStreamDefaultReader.release_lock(reader)

      assert Enum.map(stream, &Uint8Array.to_binary/1) == ["hello"]
    end

    test "a halt before the chunk cancels the stream" do
      stream = ReadableStream.from("hello")

      assert {:halted, :acc} =
               Enumerable.reduce(stream, {:halt, :acc}, fn _, acc -> {:cont, acc} end)

      assert LazyStream.state(stream.lazy) == :canceled
    end

    test "the source of a tee is locked" do
      stream = ReadableStream.from("hello")
      [left, right] = ReadableStream.tee(stream)

      assert ReadableStream.locked?(stream)
      assert LazyStream.take(stream.lazy) == :locked
      assert_raise Web.TypeError, ~r/locked/, fn -> ReadableStream.get_reader(stream) end
      assert_raise Web.TypeError, ~r/locked/, fn -> ReadableStream.tee(stream) end
      assert_raise Web.TypeError, ~r/locked/, fn -> Enum.to_list(stream) end
      assert %Web.TypeError{} = catch_exit(Web.await(ReadableStream.cancel(stream)))

      assert Enum.map(left, &Uint8Array.to_binary/1) == ["hello"]
      assert Enum.map(right, &Uint8Array.to_binary/1) == ["hello"]
    end

    test "gives the bytes to the next read when its process stopped before a read" do
      stream = ReadableStream.from("hello")
      {:ok, pid} = ReadableStream.__process__(stream)
      stop(pid)

      # No read came: the process took no bytes from the other copies.
      assert LazyStream.state(stream.lazy) == :readable
      refute ReadableStream.disturbed?(stream)
      assert {:ok, new_pid} = ReadableStream.__process__(stream)
      assert new_pid != pid
      assert read_all(ReadableStream.get_reader(stream)) == ["hello"]
    end

    test "gives the bytes to a claim when its process stopped before a read" do
      stream = ReadableStream.from("hello")
      {:ok, pid} = ReadableStream.__process__(stream)
      stop(pid)

      assert text(stream) == "hello"
      assert LazyStream.state(stream.lazy) == :locked
    end

    test "is not available when its process stopped after a read" do
      stream = ReadableStream.from("hello")
      reader = ReadableStream.get_reader(stream)
      assert read_all(reader) == ["hello"]
      stop(reader.controller_pid)

      assert LazyStream.state(stream.lazy) == :gone
      assert ReadableStream.disturbed?(stream)
      assert ReadableStream.__process__(stream) == {:error, :released}
      assert_raise Web.TypeError, ~r/not available/, fn -> ReadableStream.get_reader(stream) end

      # Some time later, the registry has no key for the process.
      wait_until(fn -> Registry.lookup(LazyStream.registry(), stream.lazy.ref) == [] end)
      assert LazyStream.state(stream.lazy) == :gone
    end

    test "a cancel of its process takes the bytes" do
      stream = ReadableStream.from("hello")
      {:ok, pid} = ReadableStream.__process__(stream)
      Web.await(ReadableStream.cancel(stream))
      stop(pid)

      assert LazyStream.state(stream.lazy) == :gone
    end

    test "a copy waits for the end of the starter that has the key" do
      lazy = ReadableStream.from("hello").lazy
      test = self()

      # A process in the place of a starter: it has the key and the state
      # "starting". After the message :go, a second process registers
      # itself as the stream process, and the first one sets "process".
      starter =
        spawn(fn ->
          {:ok, _owner} = Registry.register(LazyStream.registry(), {lazy.ref, :start}, nil)
          :atomics.put(lazy.ref, 1, 4)
          send(test, :starting)

          receive do
            :go ->
              send(test, {:stream, fake_stream(lazy, self())})

              receive do
                :registered -> :atomics.put(lazy.ref, 1, 5)
              end
          end
        end)

      assert_receive :starting

      # The state has no change: no process took the bytes.
      assert LazyStream.state(lazy) == :readable
      copy = Task.async(fn -> LazyStream.take(lazy) end)

      # A claim waits for the end of the starter, with no time limit.
      wait_until(fn -> waits_for_down?(copy.pid) end)
      send(starter, :go)
      assert_receive {:stream, stream_pid}
      assert Task.await(copy) == {:process, stream_pid}
      send(stream_pid, :stop)
    end

    test "a claim that waits for a start gets the bytes when the new process stopped" do
      lazy = ReadableStream.from("hello").lazy
      test = self()

      # A process in the place of a starter: it has the key and the state
      # "starting". After the message :go, it sets "process" with no stream
      # process: the stream process stopped before a read.
      starter =
        spawn(fn ->
          {:ok, _owner} = Registry.register(LazyStream.registry(), {lazy.ref, :start}, nil)
          :atomics.put(lazy.ref, 1, 4)
          send(test, :starting)

          receive do
            :go -> :atomics.put(lazy.ref, 1, 5)
          end
        end)

      assert_receive :starting
      copy = Task.async(fn -> LazyStream.take(lazy) end)
      wait_until(fn -> waits_for_down?(copy.pid) end)
      send(starter, :go)
      assert Task.await(copy) == {:ok, "hello"}
    end

    test "a starter that finds the key of a different starter waits for its end" do
      stream = ReadableStream.from("hello")
      lazy = stream.lazy
      test = self()

      holder =
        spawn(fn ->
          {:ok, _owner} = Registry.register(LazyStream.registry(), {lazy.ref, :start}, nil)
          send(test, :registered)

          receive do
            :go -> :ok
          end
        end)

      assert_receive :registered
      copy = Task.async(fn -> LazyStream.process(lazy, test) end)
      wait_until(fn -> waits_for_down?(copy.pid) end)
      assert LazyStream.state(lazy) == :readable

      send(holder, :go)
      assert {:ok, pid} = Task.await(copy)
      assert LazyStream.state(lazy) == {:process, pid}
      assert read_all(ReadableStream.get_reader(stream)) == ["hello"]
    end

    test "a copy asks again when the stream process stops before the copy keeps it" do
      stream = ReadableStream.from("hello")
      {:ok, pid} = ReadableStream.__process__(stream)

      # The stream process does not answer: the keep of the second copy
      # waits. Then the process stops before the keep.
      :erlang.suspend_process(pid)
      copy = Task.async(fn -> LazyStream.take(stream.lazy) end)
      wait_until(fn -> calls?(copy.pid) end)
      Process.exit(pid, :kill)

      # No read disturbed the process: the claim gets the bytes.
      assert Task.await(copy) == {:ok, "hello"}
    end

    test "a start of a stream process after the bytes went out stops in its start" do
      stream = ReadableStream.from("hello")
      assert text(stream) == "hello"

      assert Web.ReadableStream.__new__(%{type: "bytes"}, [], registry_key: stream.lazy.ref) ==
               :ignore

      assert Registry.lookup(LazyStream.registry(), stream.lazy.ref) == []
      assert LazyStream.state(stream.lazy) == :locked
    end

    test "a cancel of a stream process that a reader locked rejects" do
      stream = ReadableStream.from("hello")
      _reader = ReadableStream.get_reader(stream)

      assert %Web.TypeError{message: "Cannot cancel a locked stream."} =
               catch_exit(Web.await(ReadableStream.cancel(stream)))
    end

    test "a copy continues the start of a starter that stopped before the stream process" do
      stream = ReadableStream.from("hello")

      # The cell has "starting", and no process has the key.
      :atomics.put(stream.lazy.ref, 1, 4)
      assert {:ok, pid} = ReadableStream.__process__(stream)
      assert LazyStream.state(stream.lazy) == {:process, pid}
      assert read_all(ReadableStream.get_reader(stream)) == ["hello"]
    end

    test "a copy sets the state of a stream process whose starter stopped" do
      lazy = ReadableStream.from("hello").lazy

      # The stream process registered itself, and its starter stopped before
      # it set "process".
      stream_pid = fake_stream(lazy, self())
      assert_receive :registered
      :atomics.put(lazy.ref, 1, 4)

      # The state tells the process, with no change. A stream read sets the
      # state.
      assert LazyStream.state(lazy) == {:process, stream_pid}
      assert :atomics.get(lazy.ref, 1) == 4
      assert LazyStream.process(lazy, self()) == {:ok, stream_pid}
      assert :atomics.get(lazy.ref, 1) == 5
      send(stream_pid, :stop)
    end

    # The cell of a start that stopped, the state of the bytes, and the
    # chunks of a later read.
    @stopped_starts [
      {4, :readable, false, ["hello"]},
      {6, :consumed, true, []}
    ]

    property "a look at the state after a start that stopped starts no process" do
      check all({cell, state, disturbed?, chunks} <- member_of(@stopped_starts)) do
        stream = ReadableStream.from("hello")

        # The cell has the value of a start, no process has the key, and the
        # registry has no stream process.
        :atomics.put(stream.lazy.ref, 1, cell)

        assert LazyStream.state(stream.lazy) == state
        assert ReadableStream.disturbed?(stream) == disturbed?
        refute ReadableStream.locked?(stream)
        assert Web.Response.body_used?(%Web.Response{body: stream}) == disturbed?
        assert Registry.lookup(LazyStream.registry(), stream.lazy.ref) == []
        assert Registry.lookup(LazyStream.registry(), {stream.lazy.ref, :start}) == []
        assert :atomics.get(stream.lazy.ref, 1) == cell

        # A stream read continues the start.
        assert read_all(ReadableStream.get_reader(stream)) == chunks
      end
    end
  end

  describe "a body with no bytes" do
    test "closes its stream process at the start, with no read" do
      stream = ReadableStream.__bytes__("")
      assert stream.controller_pid == nil
      reader = ReadableStream.get_reader(stream)
      assert Web.await(ReadableStreamDefaultReader.closed(reader)) == :ok
      assert read_all(reader) == []
    end

    test "gives its error to its stream process at the start, with no read" do
      error = %Web.TypeError{message: "the connection failed"}
      stream = %ReadableStream{lazy: LazyStream.new({:error, error}, nil)}
      reader = ReadableStream.get_reader(stream)
      assert catch_exit(Web.await(ReadableStreamDefaultReader.closed(reader))) == error
      assert catch_exit(Web.await(ReadableStreamDefaultReader.read(reader))) == error
    end
  end

  describe "the close of a byte stream" do
    test "gives the end to a read of a BYOB reader that waits" do
      stream = ReadableStream.new(%{type: "bytes"})
      controller = %Web.ReadableByteStreamController{pid: stream.controller_pid}
      reader = ReadableStream.get_reader(stream, mode: "byob")
      read = Web.ReadableStreamBYOBReader.read(reader, Uint8Array.new(Web.ArrayBuffer.new(8)))
      wait_until(fn -> Web.ReadableByteStreamController.byob_request(controller) != nil end)

      assert LazyStream.__close__(stream.controller_pid) == :ok
      assert %{done: true} = Web.await(read)
    end
  end

  describe "a body of a view" do
    test "gives the bytes of the view to a read of all the bytes" do
      body = ReadableStream.from(Uint8Array.from("view"))
      assert text(body) == "view"
      assert %Web.TypeError{message: "body already used"} = catch_exit(text(body))
    end

    test "the source of a tee is locked for a read of all the bytes" do
      body = ReadableStream.from(Uint8Array.from("view"))
      [_left, _right] = ReadableStream.tee(body)

      assert ReadableStream.locked?(body)
      assert %Web.TypeError{message: "body already used"} = catch_exit(text(body))
    end
  end

  describe "a copy on a different node" do
    @describetag :cluster

    test "uses the state on the node of the array" do
      {peer, node} = Web.TestCluster.start_peer()

      # An agent on the second node keeps one copy of each stream there.
      start = fn bytes ->
        {:ok, agent} = :erpc.call(node, Agent, :start, [ReadableStream, :from, [bytes]])
        :erpc.call(node, Agent, :get, [agent, Function, :identity, []])
      end

      taken = start.("taken")
      assert node(taken.lazy.ref) == node
      refute ReadableStream.disturbed?(taken)
      refute ReadableStream.locked?(taken)

      assert Enum.map(taken, &Uint8Array.to_binary/1) == ["taken"]
      assert ReadableStream.disturbed?(taken)

      # The process of a stream read starts on the node of the array.
      read = start.("read")
      reader = ReadableStream.get_reader(read)
      assert node(reader.controller_pid) == node
      assert read_all(reader) == ["read"]

      # With no node, the stream is not available.
      gone = start.("gone")
      :peer.stop(peer)
      assert ReadableStream.disturbed?(gone)
      assert ReadableStream.__process__(gone) == {:error, :released}
    end
  end
end
