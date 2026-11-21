defmodule Web.ReadableByteStreamTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.AbortController
  alias Web.ArrayBuffer
  alias Web.AsyncContext
  alias Web.DecompressionStream
  alias Web.RangeError
  alias Web.ReadableByteStreamController, as: Controller
  alias Web.ReadableStream
  alias Web.ReadableStreamBYOBReader, as: BYOBReader
  alias Web.ReadableStreamBYOBRequest, as: Request
  alias Web.ReadableStreamDefaultReader, as: Reader
  alias Web.TextDecoderStream
  alias Web.TypeError
  alias Web.Uint8Array

  # A byte stream with no callbacks, and its controller.
  defp byte_stream(source \\ %{}) do
    test = self()
    source = Map.merge(%{type: "bytes", start: &send(test, {:controller, &1})}, source)
    stream = ReadableStream.new(source)
    assert_receive {:controller, controller}
    {stream, controller}
  end

  defp view(length), do: Uint8Array.new(ArrayBuffer.new(length))
  defp bytes(%Uint8Array{} = view), do: Uint8Array.to_binary(view)

  # The read waits in a different process. The stream has the read when
  # this function returns: the call of `Web.Stream.call/3` comes after it.
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

  defp read_result(ref) do
    assert_receive {^ref, outcome}, 1_000
    outcome
  end

  describe "the buffer of a BYOB read" do
    test "moves into the stream: the buffer of the reader becomes detached" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      Controller.enqueue(controller, "hello")

      view = view(8)
      assert %{value: value, done: false} = await(BYOBReader.read(reader, view))

      assert ArrayBuffer.detached?(view.buffer)
      refute ArrayBuffer.detached?(value.buffer)
      assert bytes(value) == "hello"

      # The new buffer has the length of the first buffer.
      assert ArrayBuffer.data(value.buffer) == <<"hello", 0, 0, 0>>
    end

    test "can be used again for the subsequent read" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      Controller.enqueue(controller, "abcdefgh")
      Controller.close(controller)

      read_all = fn read_all, view, acc ->
        case await(BYOBReader.read(reader, view)) do
          %{value: value, done: false} ->
            read_all.(read_all, Uint8Array.new(value.buffer), [bytes(value) | acc])

          %{value: value, done: true} ->
            assert value.byte_length == 0
            assert ArrayBuffer.byte_length(value.buffer) == 3
            Enum.reverse(acc)
        end
      end

      assert read_all.(read_all, view(3), []) == ["abc", "def", "gh"]
    end

    test "keeps the bytes that are not in the view" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      Controller.enqueue(controller, "XYZ")

      view = Uint8Array.new(ArrayBuffer.new("0123456789"), 4, 4)
      assert %{value: value, done: false} = await(BYOBReader.read(reader, view))

      assert {value.byte_offset, value.byte_length} == {4, 3}
      assert bytes(value) == "XYZ"
      assert ArrayBuffer.data(value.buffer) == "0123XYZ789"
    end

    test "stays attached when the read is refused" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      Controller.enqueue(controller, "hello")

      empty_view = Uint8Array.new(ArrayBuffer.new(8), 0, 0)
      assert %TypeError{} = catch_exit(await(BYOBReader.read(reader, empty_view)))
      refute ArrayBuffer.detached?(empty_view.buffer)
      refute ReadableStream.disturbed?(stream)

      BYOBReader.release_lock(reader)
      view = view(8)
      assert %TypeError{} = catch_exit(await(BYOBReader.read(reader, view)))
      refute ArrayBuffer.detached?(view.buffer)
    end
  end

  describe "the checks of a BYOB read" do
    setup do
      {stream, controller} = byte_stream()
      Controller.enqueue(controller, "hello")
      %{reader: ReadableStream.get_reader(stream, mode: "byob")}
    end

    test "refuse a view with no bytes, a detached buffer, and a view that is not a view",
         %{reader: reader} do
      detached = view(4)
      ArrayBuffer.transfer(detached.buffer)

      for view <- [Uint8Array.new(ArrayBuffer.new(0)), detached, :view] do
        assert %TypeError{} = catch_exit(await(BYOBReader.read(reader, view)))
      end
    end

    test "refuse the option min when it is 0, not a number, or larger than the view",
         %{reader: reader} do
      assert %TypeError{} = catch_exit(await(BYOBReader.read(reader, view(4), min: 0)))
      assert %TypeError{} = catch_exit(await(BYOBReader.read(reader, view(4), min: 1.5)))
      assert %RangeError{} = catch_exit(await(BYOBReader.read(reader, view(4), min: 5)))
      assert %{value: value} = await(BYOBReader.read(reader, view(4), min: 4))
      assert bytes(value) == "hell"
    end

    test "refuse a view that a different process detached after the checks", %{reader: reader} do
      view = view(4)
      pid = reader.controller_pid

      # The stream gets the read after the detach.
      :erlang.suspend_process(pid)
      promise = BYOBReader.read(reader, view)
      ArrayBuffer.transfer(view.buffer)
      :erlang.resume_process(pid)

      assert %TypeError{} = catch_exit(await(promise))
    end

    test "of a reader struct with no lock have no effect on the stream", %{reader: reader} do
      # The lock belongs to the reader, not to its process.
      other = %BYOBReader{controller_pid: reader.controller_pid, owner_pid: self()}
      assert %TypeError{} = catch_exit(await(BYOBReader.read(other, view(5))))
      assert :ok = BYOBReader.release_lock(other)

      assert %{value: value} = await(BYOBReader.read(reader, view(5)))
      assert bytes(value) == "hello"
    end

    test "lock the stream for BYOB reads only", %{reader: reader} do
      assert ReadableStream.read(reader.controller_pid) == {:error, :not_locked_by_reader}
    end
  end

  describe "the option min of a BYOB read" do
    test "waits for the minimum number of bytes" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      ref = start_read(fn -> BYOBReader.read(reader, view(5), min: 3) end)

      Controller.enqueue(controller, "a")
      Controller.enqueue(controller, "b")
      refute_received {^ref, _outcome}
      Controller.enqueue(controller, "cdef")

      assert {:fulfilled, %{value: value, done: false}} = read_result(ref)
      assert bytes(value) == "abcde"
      assert %{value: value} = await(BYOBReader.read(reader, view(5)))
      assert bytes(value) == "f"
    end

    test "gives the bytes that the stream has when it closes" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      ref = start_read(fn -> BYOBReader.read(reader, view(3), min: 3) end)

      request = Controller.byob_request(controller)
      :ok = Request.respond(request, "a")
      Controller.close(controller)
      :ok = Request.respond(Controller.byob_request(controller), 0)

      assert {:fulfilled, %{value: value, done: true}} = read_result(ref)
      assert bytes(value) == "a"
    end

    test "errors a stream that has a close request and not the minimum bytes" do
      {stream, controller} = byte_stream()
      Controller.enqueue(controller, "ab")
      Controller.close(controller)
      reader = ReadableStream.get_reader(stream, mode: "byob")

      assert %TypeError{} = catch_exit(await(BYOBReader.read(reader, view(3), min: 3)))
      assert %TypeError{} = catch_exit(await(BYOBReader.closed(reader)))
    end
  end

  describe "a BYOB request" do
    test "has the view of the read, and a response gives the bytes of the view" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      ref = start_read(fn -> BYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new("xyz"))) end)

      request = Controller.byob_request(controller)
      # The getter gives the same request until a response.
      assert Controller.byob_request(controller) == request
      view = Request.view(request)
      assert {view.byte_offset, view.byte_length, bytes(view)} == {0, 3, "xyz"}

      :ok = Request.respond(request, 2)
      assert Request.view(request) == nil
      assert Controller.byob_request(controller) == nil
      assert ArrayBuffer.detached?(view.buffer)

      assert {:fulfilled, %{value: value, done: false}} = read_result(ref)
      assert bytes(value) == "xy"
    end

    test "gives the bytes that the source wrote into the buffer of the view" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      ref = start_read(fn -> BYOBReader.read(reader, view(4)) end)

      request = Controller.byob_request(controller)
      written = %{request.view | buffer: ArrayBuffer.replace(request.view.buffer, 0, "ab")}
      :ok = Request.respond(%{request | view: written}, 2)

      assert {:fulfilled, %{value: value}} = read_result(ref)
      assert bytes(value) == "ab"
    end

    test "refuses a second response, a response of 0, and a response that is too large" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      _ref = start_read(fn -> BYOBReader.read(reader, view(2)) end)
      request = Controller.byob_request(controller)

      assert_raise TypeError, fn -> Request.respond(request, 0) end
      assert_raise RangeError, fn -> Request.respond(request, 3) end
      assert_raise RangeError, fn -> Request.respond(request, "abc") end
      assert_raise TypeError, fn -> Request.respond(request, -1) end
      :ok = Request.respond(request, 1)
      assert_raise TypeError, fn -> Request.respond(request, 1) end
      assert_raise TypeError, fn -> Request.respond_with_new_view(request, view(1)) end
    end

    test "refuses a response when the buffer of the view is detached" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      _ref = start_read(fn -> BYOBReader.read(reader, view(2)) end)
      request = Controller.byob_request(controller)

      ArrayBuffer.transfer(request.view.buffer)
      assert_raise TypeError, fn -> Request.respond(request, 1) end
      assert_raise TypeError, fn -> Controller.enqueue(controller, "a") end
      assert_raise TypeError, fn -> Request.respond_with_new_view(request, request.view) end
    end

    test "of a closed stream needs the response 0, and ends the read with its buffer" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      ref = start_read(fn -> BYOBReader.read(reader, view(2)) end)

      Controller.close(controller)
      request = Controller.byob_request(controller)
      assert_raise TypeError, fn -> Request.respond(request, 1) end
      refute_received {^ref, _outcome}
      :ok = Request.respond(request, 0)

      assert {:fulfilled, %{value: value, done: true}} = read_result(ref)
      assert {value.byte_length, ArrayBuffer.byte_length(value.buffer)} == {0, 2}
    end

    test "takes a new view with the bounds of the request" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")

      ref =
        start_read(fn -> BYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(4), 1, 2)) end)

      request = Controller.byob_request(controller)

      other_offset = Uint8Array.new(ArrayBuffer.new(4), 0, 1)
      other_length = Uint8Array.new(ArrayBuffer.new(5), 1, 1)
      too_large = Uint8Array.new(ArrayBuffer.new(4), 1, 3)

      for view <- [other_offset, other_length, too_large] do
        assert_raise RangeError, fn -> Request.respond_with_new_view(request, view) end
      end

      assert_raise TypeError, fn ->
        Request.respond_with_new_view(request, Uint8Array.new(ArrayBuffer.new(4), 1, 0))
      end

      assert_raise TypeError, fn -> Request.respond_with_new_view(request, :view) end

      new_view = Uint8Array.new(ArrayBuffer.new("abcd"), 1, 1)
      :ok = Request.respond_with_new_view(request, new_view)
      assert ArrayBuffer.detached?(new_view.buffer)

      assert {:fulfilled, %{value: value}} = read_result(ref)
      assert {value.byte_offset, bytes(value)} == {1, "b"}
    end

    test "of a closed stream takes a new view of 0 bytes" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      ref = start_read(fn -> BYOBReader.read(reader, view(2)) end)
      Controller.close(controller)
      request = Controller.byob_request(controller)

      assert_raise TypeError, fn -> Request.respond_with_new_view(request, view(2)) end
      :ok = Request.respond_with_new_view(request, Uint8Array.new(ArrayBuffer.new(2), 0, 0))
      assert {:fulfilled, %{done: true}} = read_result(ref)
    end

    test "with a binary puts the bytes into the view" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      ref = start_read(fn -> BYOBReader.read(reader, view(4)) end)

      :ok = Request.respond_with_new_view(Controller.byob_request(controller), "ok")
      assert {:fulfilled, %{value: value}} = read_result(ref)
      assert ArrayBuffer.data(value.buffer) == <<"ok", 0, 0>>
    end

    test "is not valid after the stream stops" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      _ref = start_read(fn -> BYOBReader.read(reader, view(2)) end)
      request = Controller.byob_request(controller)

      Web.Stream.stop(stream.controller_pid)
      assert Request.view(request) == nil
      assert_raise TypeError, fn -> Request.respond(request, 1) end
      assert Controller.byob_request(controller) == nil
      assert_raise TypeError, fn -> Controller.enqueue(controller, "a") end
    end
  end

  describe "a release of the lock of a BYOB reader" do
    test "keeps the request, and its response goes to the next reader" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      first = start_read(fn -> BYOBReader.read(reader, view(3)) end)
      request = Controller.byob_request(controller)

      BYOBReader.release_lock(reader)
      assert {:rejected, %TypeError{}} = read_result(first)

      reader = ReadableStream.get_reader(stream, mode: "byob")
      second = start_read(fn -> BYOBReader.read(reader, view(3)) end)
      assert Controller.byob_request(controller) == request

      :ok = Request.respond(request, "ab")
      assert {:fulfilled, %{value: value}} = read_result(second)
      assert bytes(value) == "ab"
    end

    test "with no other reader puts the bytes of the response in the queue" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      _first = start_read(fn -> BYOBReader.read(reader, view(3)) end)
      request = Controller.byob_request(controller)
      BYOBReader.release_lock(reader)

      :ok = Request.respond(request, "ab")
      assert Request.view(request) == nil
      reader = ReadableStream.get_reader(stream)
      assert %{value: value} = await(Reader.read(reader))
      assert bytes(value) == "ab"
    end

    test "and an enqueue discard the request of the reader" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      _first = start_read(fn -> BYOBReader.read(reader, view(3)) end)
      request = Controller.byob_request(controller)
      BYOBReader.release_lock(reader)

      Controller.enqueue(controller, "c")
      assert Request.view(request) == nil
      assert Controller.byob_request(controller) == nil
      reader = ReadableStream.get_reader(stream)
      assert %{value: value} = await(Reader.read(reader))
      assert bytes(value) == "c"
    end

    test "of a reader that stops releases the request of the reader" do
      {stream, controller} = byte_stream()
      test = self()

      {pid, monitor} =
        spawn_monitor(fn ->
          reader = ReadableStream.get_reader(stream, mode: "byob")
          _read = BYOBReader.read(reader, view(2))
          send(test, :read_sent)
          receive do: (:stop -> :ok)
        end)

      assert_receive :read_sent
      request = Controller.byob_request(controller)
      send(pid, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

      reader = ReadableStream.get_reader(stream, mode: "byob")
      ref = start_read(fn -> BYOBReader.read(reader, view(2)) end)
      :ok = Request.respond(request, "zz")
      assert {:fulfilled, %{value: value}} = read_result(ref)
      assert bytes(value) == "zz"
    end
  end

  describe "the lock of a BYOB reader" do
    property "a reader that released its lock has no effect on the next reader of its process" do
      check all(operation <- member_of([:release_lock, :read, :closed, :cancel])) do
        {stream, controller} = byte_stream()
        old = ReadableStream.get_reader(stream, mode: "byob")
        assert :ok = BYOBReader.release_lock(old)
        new = ReadableStream.get_reader(stream, mode: "byob")

        # The operations of the Standard on a reader with no stream.
        case operation do
          :release_lock -> assert BYOBReader.release_lock(old) == :ok
          :read -> assert %TypeError{} = catch_exit(await(BYOBReader.read(old, view(2))))
          :closed -> assert %TypeError{} = catch_exit(await(BYOBReader.closed(old)))
          :cancel -> assert %TypeError{} = catch_exit(await(BYOBReader.cancel(old, :stop)))
        end

        # The new reader holds the lock, and reads.
        assert ReadableStream.locked?(stream)
        Controller.enqueue(controller, "ab")
        assert %{value: value, done: false} = await(BYOBReader.read(new, view(2)))
        assert bytes(value) == "ab"
      end
    end

    test "gives the same promise closed, and a release rejects it with a TypeError" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      closed = BYOBReader.closed(reader)
      assert BYOBReader.closed(reader) == closed

      # ReadableStreamReaderGenericRelease rejects the promise, and the
      # promise keeps its identity.
      assert :ok = BYOBReader.release_lock(reader)
      assert BYOBReader.closed(reader) == closed
      assert %TypeError{} = catch_exit(await(closed))

      # The next reader has its own promise. It fulfils at the close.
      reader = ReadableStream.get_reader(stream, mode: "byob")
      next = BYOBReader.closed(reader)
      assert next != closed
      Controller.close(controller)
      assert await(next) == :ok
      assert BYOBReader.closed(reader) == next
    end

    test "lets only the process of the BYOB lock read with a request of the engine" do
      {stream, _controller} = byte_stream()
      pid = stream.controller_pid

      # A request that names a process with no BYOB lock: the default lock
      # of this process, and no lock.
      :ok = ReadableStream.get_reader(pid)
      read = {:byob_read, self(), view(1), 1}
      assert :gen_statem.call(pid, read) == {:error, :not_locked_by_reader}
      :ok = ReadableStream.release_lock(pid)
      assert :gen_statem.call(pid, read) == {:error, :not_locked_by_reader}
    end

    test "gives a fulfilled promise closed for a stream that stopped" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      Controller.close(controller)
      Web.Stream.stop(stream.controller_pid)
      assert await(BYOBReader.closed(reader)) == :ok
    end
  end

  describe "auto_allocate_chunk_size" do
    test "gives a BYOB request to a default read" do
      {stream, controller} = byte_stream(%{auto_allocate_chunk_size: 4})
      reader = ReadableStream.get_reader(stream)
      ref = start_read(fn -> Reader.read(reader) end)

      request = Controller.byob_request(controller)
      assert Request.view(request).byte_length == 4
      :ok = Request.respond(request, "abc")

      assert {:fulfilled, %{value: value, done: false}} = read_result(ref)
      assert {bytes(value), ArrayBuffer.byte_length(value.buffer)} == {"abc", 4}
    end

    test "gives a request that an enqueue discards" do
      {stream, controller} = byte_stream(%{auto_allocate_chunk_size: 4})
      reader = ReadableStream.get_reader(stream)
      ref = start_read(fn -> Reader.read(reader) end)
      request = Controller.byob_request(controller)

      Controller.enqueue(controller, "hello")
      assert Request.view(request) == nil
      assert {:fulfilled, %{value: value}} = read_result(ref)
      assert bytes(value) == "hello"
    end

    test "of a closed stream ends the default read, and the request takes the response 0" do
      {stream, controller} = byte_stream(%{auto_allocate_chunk_size: 4})
      reader = ReadableStream.get_reader(stream)
      ref = start_read(fn -> Reader.read(reader) end)
      request = Controller.byob_request(controller)

      Controller.close(controller)
      assert {:fulfilled, %{value: nil, done: true}} = read_result(ref)
      :ok = Request.respond(request, 0)
      assert Request.view(request) == nil
    end

    test "with a default reader that releases its lock puts the response in the queue" do
      {stream, controller} = byte_stream(%{auto_allocate_chunk_size: 4})
      reader = ReadableStream.get_reader(stream)
      _ref = start_read(fn -> Reader.read(reader) end)
      request = Controller.byob_request(controller)
      Reader.release_lock(reader)

      :ok = Request.respond(request, "ab")
      reader = ReadableStream.get_reader(stream, mode: "byob")
      assert %{value: value} = await(BYOBReader.read(reader, view(4)))
      assert bytes(value) == "ab"
    end

    test "must be an integer above 0" do
      for size <- [0, -1, 1.5, "4"] do
        assert_raise TypeError, fn ->
          ReadableStream.new(%{type: "bytes", auto_allocate_chunk_size: size})
        end
      end

      # A stream that is not a byte stream has no use for it.
      assert %ReadableStream{} = ReadableStream.new(%{auto_allocate_chunk_size: 0})
    end
  end

  describe "the controller" do
    test "takes the buffer of a chunk, and refuses a chunk with no bytes" do
      {stream, controller} = byte_stream()
      chunk = Uint8Array.new(ArrayBuffer.new("abcdef"), 1, 3)
      :ok = Controller.enqueue(controller, chunk)
      assert ArrayBuffer.detached?(chunk.buffer)

      assert_raise TypeError, fn -> Controller.enqueue(controller, chunk) end
      assert_raise TypeError, fn -> Controller.enqueue(controller, "") end
      assert_raise TypeError, fn -> Controller.enqueue(controller, view(0)) end

      assert_raise TypeError, fn ->
        Controller.enqueue(controller, Uint8Array.new(ArrayBuffer.new(4), 0, 0))
      end

      assert_raise TypeError, fn -> Controller.enqueue(controller, :chunk) end

      # A default read gives a view of the buffer of the chunk.
      reader = ReadableStream.get_reader(stream)
      assert %{value: value} = await(Reader.read(reader))
      assert {value.byte_offset, value.byte_length, bytes(value)} == {1, 3, "bcd"}
      assert ArrayBuffer.byte_length(value.buffer) == 6
    end

    test "closes the stream after a read takes the last bytes" do
      {stream, controller} = byte_stream()
      Controller.enqueue(controller, "ab")
      :ok = Controller.close(controller)

      assert_raise TypeError, fn -> Controller.close(controller) end
      assert_raise TypeError, fn -> Controller.enqueue(controller, "c") end
      assert Controller.desired_size(controller) == -2

      reader = ReadableStream.get_reader(stream)
      assert %{value: value, done: false} = await(Reader.read(reader))
      assert bytes(value) == "ab"
      assert %{done: true} = await(Reader.read(reader))
      assert Controller.desired_size(controller) == 0
      assert_raise TypeError, fn -> Controller.close(controller) end
    end

    test "gives the bytes of one chunk to many BYOB reads, and of many chunks to one read" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      first = start_read(fn -> BYOBReader.read(reader, view(2)) end)
      second = start_read(fn -> BYOBReader.read(reader, view(3)) end)

      Controller.enqueue(controller, "hello")
      assert {:fulfilled, %{value: value}} = read_result(first)
      assert bytes(value) == "he"
      assert {:fulfilled, %{value: value}} = read_result(second)
      assert bytes(value) == "llo"

      Controller.enqueue(controller, "a")
      Controller.enqueue(controller, "b")
      assert %{value: value} = await(BYOBReader.read(reader, view(4)))
      assert bytes(value) == "ab"
    end

    test "gives the bytes in the queue to a default read that waits, at the next chunk" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      _first = start_read(fn -> BYOBReader.read(reader, view(3)) end)
      request = Controller.byob_request(controller)
      BYOBReader.release_lock(reader)

      # The response goes to the queue: a default read with no BYOB request
      # waits for a chunk, as the Streams Standard specifies.
      reader = ReadableStream.get_reader(stream)
      ref = start_read(fn -> Reader.read(reader) end)
      :ok = Request.respond(request, "ab")
      refute_received {^ref, _outcome}

      Controller.enqueue(controller, "c")
      assert {:fulfilled, %{value: value}} = read_result(ref)
      assert bytes(value) == "ab"
      assert %{value: value} = await(Reader.read(reader))
      assert bytes(value) == "c"
    end

    test "pulls one time for a read that takes the bytes of start" do
      test = self()

      stream =
        ReadableStream.new(
          %{
            type: "bytes",
            start: &Controller.enqueue(&1, String.duplicate("x", 16)),
            pull: fn controller -> send(test, {:pull, Controller.desired_size(controller)}) end
          },
          high_water_mark: 8
        )

      reader = ReadableStream.get_reader(stream)
      assert %{value: value} = await(Reader.read(reader))
      assert value.byte_length == 16

      # The pull gives no bytes: at its end, the stream does not pull again.
      assert_receive {:pull, 8}
      await_end_of_pull(stream.controller_pid)
      refute_received {:pull, _size}
    end

    test "refuses a close of an errored stream" do
      {_stream, controller} = byte_stream()
      Controller.error(controller, :boom)
      assert_raise TypeError, fn -> Controller.close(controller) end
      assert Controller.desired_size(controller) == nil
    end

    test "waits for capacity until a read takes the bytes of the queue" do
      {stream, controller} = byte_stream(%{high_water_mark: 2})
      Controller.enqueue(controller, "ab")

      waiter = Task.async(fn -> Controller.wait_for_capacity(controller) end)
      assert Task.yield(waiter, 20) == nil

      reader = ReadableStream.get_reader(stream)
      assert %{value: value} = await(Reader.read(reader))
      assert bytes(value) == "ab"
      assert Task.await(waiter) == :ok
    end

    test "waits for capacity until the stream errors" do
      {_stream, controller} = byte_stream()
      Controller.enqueue(controller, "ab")

      waiter = Task.async(fn -> Controller.wait_for_capacity(controller) end)
      assert Task.yield(waiter, 20) == nil
      Controller.error(controller, :boom)
      assert Task.await(waiter) == :ok
    end

    test "gives the chunks to the default reads that wait" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream)
      first = start_read(fn -> Reader.read(reader) end)
      second = start_read(fn -> Reader.read(reader) end)

      Controller.enqueue(controller, "a")
      Controller.enqueue(controller, "b")
      assert {:fulfilled, %{value: a}} = read_result(first)
      assert {:fulfilled, %{value: b}} = read_result(second)
      assert {bytes(a), bytes(b)} == {"a", "b"}
    end

    test "of a stream that the code of this library feeds discards a chunk that it refuses" do
      {stream, _controller} = byte_stream()
      ReadableStream.enqueue(stream.controller_pid, "a")
      ReadableStream.close(stream.controller_pid)
      ReadableStream.enqueue(stream.controller_pid, "late")
      ReadableStream.enqueue(stream.controller_pid, "")

      assert Enum.map(stream, &bytes/1) == ["a"]
    end
  end

  describe "a cancel" do
    test "ends the BYOB reads that wait with no value" do
      test = self()
      {stream, _controller} = byte_stream(%{cancel: &send(test, {:cancelled, &1})})
      reader = ReadableStream.get_reader(stream, mode: "byob")
      ref = start_read(fn -> BYOBReader.read(reader, view(2)) end)

      assert :ok = await(BYOBReader.cancel(reader, :stop))
      assert_receive {:cancelled, :stop}
      assert {:fulfilled, %{value: nil, done: true}} = read_result(ref)
    end

    test "of an errored stream rejects with the error" do
      {stream, controller} = byte_stream()
      reader = ReadableStream.get_reader(stream, mode: "byob")
      Controller.error(controller, :boom)

      assert :boom = catch_exit(await(BYOBReader.cancel(reader, :stop)))
      assert :boom = catch_exit(await(BYOBReader.read(reader, view(1))))
    end
  end

  test "an error rejects the BYOB reads that wait" do
    {stream, controller} = byte_stream()
    reader = ReadableStream.get_reader(stream, mode: "byob")
    ref = start_read(fn -> BYOBReader.read(reader, view(2)) end)

    Controller.error(controller, :boom)
    assert {:rejected, :boom} = read_result(ref)
  end

  test "an ambient abort rejects the BYOB reads that wait" do
    controller = AbortController.new()

    stream =
      AsyncContext.with_signal(controller.signal, fn -> ReadableStream.new(%{type: "bytes"}) end)

    reader = ReadableStream.get_reader(stream, mode: "byob")
    ref = start_read(fn -> BYOBReader.read(reader, view(2)) end)

    :ok = AbortController.abort(controller, :byob_abort)
    assert {:rejected, :byob_abort} = read_result(ref)
  end

  test "a byte stream pipes through decompression and text decoding" do
    compressed = :zlib.gzip("hello byte stream")

    stream =
      ReadableStream.new(%{
        type: "bytes",
        start: fn controller ->
          Controller.enqueue(controller, compressed)
          Controller.close(controller)
        end
      })

    decoded =
      stream
      |> ReadableStream.pipe_through(DecompressionStream.new("gzip"))
      |> ReadableStream.pipe_through(TextDecoderStream.new())

    assert Enum.join(decoded, "") == "hello byte stream"
  end

  describe "the bytes of a byte stream" do
    property "go to the BYOB reads in their sequence, with no loss" do
      check all(
              chunks <- list_of(binary(min_length: 1, max_length: 8), max_length: 8),
              sizes <- list_of(integer(1..6), min_length: 1, max_length: 6)
            ) do
        {stream, controller} = byte_stream()
        Enum.each(chunks, &Controller.enqueue(controller, &1))
        Controller.close(controller)
        reader = ReadableStream.get_reader(stream, mode: "byob")

        read = fn read, [size | rest], acc ->
          case await(BYOBReader.read(reader, view(size))) do
            %{value: value, done: false} ->
              assert value.byte_length in 1..size
              read.(read, rest ++ [size], [bytes(value) | acc])

            %{value: value, done: true} ->
              assert value.byte_length == 0
              acc |> Enum.reverse() |> IO.iodata_to_binary()
          end
        end

        assert read.(read, sizes, []) == IO.iodata_to_binary(chunks)
      end
    end

    property "go to the reads with a minimum, from the responses and the chunks of the source" do
      check all(
              chunks <-
                list_of(binary(min_length: 1, max_length: 8), min_length: 1, max_length: 6),
              size <- integer(1..8),
              min <- integer(1..size)
            ) do
        agent = start_supervised!({Agent, fn -> chunks end}, id: make_ref())

        stream =
          ReadableStream.new(%{
            type: "bytes",
            pull: fn controller ->
              case Agent.get_and_update(agent, fn chunks -> Enum.split(chunks, 1) end) do
                [chunk] -> respond_or_enqueue(controller, chunk)
                [] -> close_and_respond(controller)
              end
            end
          })

        reader = ReadableStream.get_reader(stream, mode: "byob")

        read = fn read, acc ->
          case await(BYOBReader.read(reader, view(size), min: min)) do
            %{value: value, done: false} ->
              # Each result that is not the end has the minimum.
              assert value.byte_length in min..size
              read.(read, [bytes(value) | acc])

            %{value: value, done: true} ->
              [bytes(value) | acc] |> Enum.reverse() |> IO.iodata_to_binary()
          end
        end

        assert read.(read, []) == IO.iodata_to_binary(chunks)
      end
    end
  end

  # The end of a pull is a message of the worker of the stream. A pull that
  # follows starts in the same step as the end.
  defp await_end_of_pull(pid, attempts \\ 200) do
    case ReadableStream.__get_slots__(pid).pulling do
      false ->
        :ok

      true when attempts > 0 ->
        Process.sleep(5)
        await_end_of_pull(pid, attempts - 1)
    end
  end

  # A chunk that fits into the view of the request is the response. A larger
  # chunk goes to the queue.
  defp respond_or_enqueue(controller, chunk) do
    request = Controller.byob_request(controller)

    if byte_size(chunk) <= Request.view(request).byte_length,
      do: Request.respond(request, chunk),
      else: Controller.enqueue(controller, chunk)
  end

  defp close_and_respond(controller) do
    Controller.close(controller)

    case Controller.byob_request(controller) do
      nil -> :ok
      request -> Request.respond(request, 0)
    end
  end
end
