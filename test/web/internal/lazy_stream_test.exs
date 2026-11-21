defmodule Web.Internal.LazyStreamTest do
  use ExUnit.Case, async: true

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

    test "is not available when its process stopped" do
      stream = ReadableStream.from("hello")
      {:ok, pid} = ReadableStream.__process__(stream)
      ref = Process.monitor(pid)
      Web.Stream.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      assert LazyStream.state(stream.lazy) == :gone
      assert ReadableStream.__process__(stream) == {:error, :released}
      assert_raise Web.TypeError, ~r/not available/, fn -> ReadableStream.get_reader(stream) end

      # Some time later, the registry has no key for the process.
      wait_until(fn -> Registry.lookup(LazyStream.registry(), stream.lazy.ref) == [] end)
      assert LazyStream.state(stream.lazy) == :gone
    end

    test "a copy waits while a different process starts the stream process" do
      stream = ReadableStream.from("hello")
      test = self()

      # The array has the state "starting". A different process registers
      # a process after some time, and sets the state "process".
      :atomics.put(stream.lazy.ref, 1, 4)

      starter =
        spawn(fn ->
          # A slow start: the copy must wait while the state is "starting".
          Process.sleep(5)
          {:ok, _owner} = Registry.register(LazyStream.registry(), stream.lazy.ref, nil)
          :atomics.put(stream.lazy.ref, 1, 5)
          send(test, :registered)

          receive do
            :stop -> :ok
          end
        end)

      assert LazyStream.state(stream.lazy) == {:process, starter}
      # The starter sends the message after it sets the state. Thus the
      # test must wait for the message.
      assert_receive :registered
      send(starter, :stop)
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
