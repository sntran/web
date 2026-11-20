defmodule Web.ReadableByteStreamTeeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.ArrayBuffer
  alias Web.Internal.ReadableByteStreamTee
  alias Web.ReadableByteStreamController, as: Controller
  alias Web.ReadableStream
  alias Web.ReadableStreamBYOBReader, as: BYOBReader
  alias Web.ReadableStreamBYOBRequest, as: Request
  alias Web.ReadableStreamDefaultReader, as: Reader
  alias Web.Uint8Array

  # A byte stream with no callbacks, its controller, and its two branches.
  defp tee(source \\ %{}) do
    test = self()
    source = Map.merge(%{type: "bytes", start: &send(test, {:controller, &1})}, source)
    stream = ReadableStream.new(source)
    assert_receive {:controller, controller}
    [left, right] = ReadableStream.tee(stream)
    {stream, controller, left, right}
  end

  defp view(length), do: Uint8Array.new(ArrayBuffer.new(length))
  defp bytes(%Uint8Array{} = view), do: Uint8Array.to_binary(view)

  # The tee process holds the reader lock of the stream.
  defp tee_process(stream), do: ReadableStream.__get_slots__(stream.controller_pid).reader_pid

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

  # The read of a branch is a pull of the branch, then a message to the tee
  # process, then a BYOB read of the stream. The request of the stream comes
  # after these steps of other processes.
  defp await_request(controller, attempts \\ 200) do
    case Controller.byob_request(controller) do
      %Request{} = request ->
        request

      nil when attempts > 0 ->
        Process.sleep(5)
        await_request(controller, attempts - 1)
    end
  end

  # Waits until the process has a message.
  defp await_message(pid, attempts \\ 200) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, 0} when attempts > 0 ->
        Process.sleep(5)
        await_message(pid, attempts - 1)

      {:message_queue_len, count} when count > 0 ->
        :ok
    end
  end

  defp assert_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
  end

  # A pull that comes during a read of the other branch is rare: about one
  # case in 300 had it, thus the property has many runs.
  property "gives all the bytes to the two branches, for each kind and size of the reads" do
    check all(
            chunks <- list_of(binary(min_length: 1, max_length: 6), max_length: 6),
            left_size <- one_of([constant(:default), integer(1..4)]),
            right_size <- one_of([constant(:default), integer(1..4)]),
            max_runs: 500
          ) do
      {_stream, controller, left, right} = tee()
      Enum.each(chunks, &Controller.enqueue(controller, &1))
      Controller.close(controller)

      left_task = Task.async(fn -> read_all(left, left_size) end)
      right_task = Task.async(fn -> read_all(right, right_size) end)

      expected = IO.iodata_to_binary(chunks)
      assert Task.await(left_task) == expected
      assert Task.await(right_task) == expected
    end
  end

  defp read_all(stream, :default), do: stream |> Enum.map(&bytes/1) |> IO.iodata_to_binary()

  defp read_all(stream, size) do
    reader = ReadableStream.get_reader(stream, mode: "byob")

    read = fn read, acc ->
      case await(BYOBReader.read(reader, view(size))) do
        %{value: value, done: false} -> read.(read, [bytes(value) | acc])
        %{done: true} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
      end
    end

    read.(read, [])
  end

  describe "a BYOB read of a branch" do
    test "reads the stream into the view of the branch, and the other branch gets a copy" do
      {_stream, controller, left, right} = tee()
      left_reader = ReadableStream.get_reader(left, mode: "byob")
      left_view = Uint8Array.new(ArrayBuffer.new("____"), 1, 2)
      ref = start_read(fn -> BYOBReader.read(left_reader, left_view) end)

      # The request of the stream has the view of the branch.
      request = await_request(controller)
      assert {request.view.byte_offset, request.view.byte_length} == {1, 2}
      :ok = Request.respond(request, "ab")

      assert {:fulfilled, %{value: value, done: false}} = read_result(ref)
      assert ArrayBuffer.data(value.buffer) == "_ab_"

      right_reader = ReadableStream.get_reader(right)
      assert %{value: copy} = await(Reader.read(right_reader))
      assert bytes(copy) == "ab"
      assert ArrayBuffer.byte_length(copy.buffer) == 2
    end

    test "after a default read changes the reader of the stream" do
      {stream, controller, left, right} = tee()
      Controller.enqueue(controller, "abc")

      assert %{value: value} = await(Reader.read(ReadableStream.get_reader(left)))
      assert bytes(value) == "abc"

      # The other branch has a copy of the chunk in its queue.
      right_reader = ReadableStream.get_reader(right, mode: "byob")
      assert %{value: value} = await(BYOBReader.read(right_reader, view(3)))
      assert bytes(value) == "abc"

      Controller.enqueue(controller, "def")
      assert %{value: value} = await(BYOBReader.read(right_reader, view(2)))
      assert bytes(value) == "de"
      assert ReadableStream.__get_slots__(stream.controller_pid).reader_mode == :byob
    end

    test "ends with its view when the stream closes, and the other branch ends" do
      {_stream, controller, left, right} = tee()
      left_reader = ReadableStream.get_reader(left, mode: "byob")
      right_reader = ReadableStream.get_reader(right, mode: "byob")
      left_ref = start_read(fn -> BYOBReader.read(left_reader, view(2)) end)
      right_ref = start_read(fn -> BYOBReader.read(right_reader, view(3)) end)

      request = await_request(controller)
      Controller.close(controller)
      :ok = Request.respond(request, 0)

      assert {:fulfilled, %{value: left_value, done: true}} = read_result(left_ref)
      assert ArrayBuffer.byte_length(left_value.buffer) == 2
      assert {:fulfilled, %{value: right_value, done: true}} = read_result(right_ref)
      assert ArrayBuffer.byte_length(right_value.buffer) == 3
    end

    test "of a closed stream ends the two branches" do
      {_stream, controller, left, right} = tee()
      Controller.close(controller)

      reader = ReadableStream.get_reader(left, mode: "byob")
      assert %{value: value, done: true} = await(BYOBReader.read(reader, view(2)))
      assert ArrayBuffer.byte_length(value.buffer) == 2
      assert Enum.to_list(right) == []
    end

    test "that a cancel of the stream ends, ends the two branches" do
      {stream, _controller, left, right} = tee()
      left_reader = ReadableStream.get_reader(left, mode: "byob")
      right_reader = ReadableStream.get_reader(right, mode: "byob")
      left_ref = start_read(fn -> BYOBReader.read(left_reader, view(2)) end)
      right_ref = start_read(fn -> BYOBReader.read(right_reader, view(2)) end)

      # A cancel with no lock check: the cancel of a reader.
      :ok = await(ReadableStream.cancel(stream.controller_pid, :stop))

      assert {:fulfilled, %{done: true}} = read_result(left_ref)
      assert {:fulfilled, %{done: true}} = read_result(right_ref)
    end
  end

  describe "a cancel" do
    test "of one branch gives the bytes of the stream to the other branch only" do
      {_stream, controller, left, right} = tee()
      left_cancel = ReadableStream.cancel(left, :left)

      Controller.enqueue(controller, "ab")
      reader = ReadableStream.get_reader(right, mode: "byob")
      assert %{value: value} = await(BYOBReader.read(reader, view(4)))
      assert bytes(value) == "ab"

      Controller.enqueue(controller, "cd")
      assert %{value: value} = await(BYOBReader.read(reader, view(1)))
      assert bytes(value) == "c"

      # The promise of the cancel settles when a read gets the end.
      Controller.close(controller)
      assert %{value: value} = await(BYOBReader.read(reader, view(4)))
      assert bytes(value) == "d"
      assert %{done: true} = await(BYOBReader.read(reader, view(4)))
      assert :ok = await(left_cancel)
    end

    test "of the two branches cancels the stream with the two reasons" do
      test = self()
      {stream, _controller, left, right} = tee(%{cancel: &send(test, {:cancel, &1})})
      tee = tee_process(stream)

      left_cancel = ReadableStream.cancel(left, :left)
      assert :ok = await(ReadableStream.cancel(right, :right))
      assert :ok = await(left_cancel)
      assert_receive {:cancel, [:left, :right]}

      # The work of the tee is complete: it ignores the messages that come
      # later, and its promise settles at once.
      send(tee, :not_for_the_tee)
      ReadableByteStreamTee.pull(tee, 1, nil)
      assert :ok = await(ReadableByteStreamTee.cancel(tee, 1, :late))
      assert Process.alive?(tee)
    end

    test "of a branch during a BYOB read of the other branch" do
      {_stream, controller, left, right} = tee()
      left_reader = ReadableStream.get_reader(left, mode: "byob")
      ref = start_read(fn -> BYOBReader.read(left_reader, view(2)) end)
      request = await_request(controller)

      right_cancel = ReadableStream.cancel(right, :right)
      :ok = Request.respond(request, "ab")
      assert {:fulfilled, %{value: value}} = read_result(ref)
      assert bytes(value) == "ab"

      Controller.close(controller)
      assert %{done: true} = await(BYOBReader.read(left_reader, view(2)))
      assert :ok = await(right_cancel)
    end

    test "of the branch of a BYOB read gives the bytes to the other branch" do
      {_stream, controller, left, right} = tee()
      left_reader = ReadableStream.get_reader(left, mode: "byob")
      _ref = start_read(fn -> BYOBReader.read(left_reader, view(2)) end)
      request = await_request(controller)

      _left_cancel = ReadableStream.cancel(left, :left)
      :ok = Request.respond(request, "ab")

      assert %{value: value} = await(Reader.read(ReadableStream.get_reader(right)))
      assert bytes(value) == "ab"
    end

    test "rejects with the value that the cancel of the stream throws" do
      {_stream, _controller, left, right} = tee(%{cancel: fn _reason -> throw(:no_cancel) end})
      left_cancel = ReadableStream.cancel(left, :left)
      assert catch_exit(await(ReadableStream.cancel(right, :right))) == :no_cancel
      assert catch_exit(await(left_cancel)) == :no_cancel
    end

    test "comes from a branch that stops" do
      test = self()
      {_stream, _controller, left, right} = tee(%{cancel: &send(test, {:cancel, &1})})

      Web.Stream.stop(left.controller_pid)
      assert :ok = await(ReadableStream.cancel(right, :right))
      assert_receive {:cancel, [{:branch_down, :normal}, :right]}
    end
  end

  describe "an error" do
    test "of the stream goes to the two branches" do
      {_stream, controller, left, right} = tee()
      reader = ReadableStream.get_reader(left, mode: "byob")
      ref = start_read(fn -> BYOBReader.read(reader, view(2)) end)

      Controller.error(controller, :boom)
      assert {:rejected, :boom} = read_result(ref)
      assert catch_exit(await(Reader.read(ReadableStream.get_reader(right)))) == :boom
    end

    test "of a stream that is errored before the tee goes to the two branches" do
      stream = ReadableStream.new(%{type: "bytes", start: &Controller.error(&1, :boom)})
      [left, right] = ReadableStream.tee(stream)

      assert catch_exit(await(Reader.read(ReadableStream.get_reader(left)))) == :boom
      assert catch_exit(await(Reader.read(ReadableStream.get_reader(right)))) == :boom
    end

    test "of a branch makes the branch refuse the bytes of its BYOB read" do
      {_stream, controller, left, right} = tee()
      left_reader = ReadableStream.get_reader(left, mode: "byob")
      ref = start_read(fn -> BYOBReader.read(left_reader, view(2)) end)
      request = await_request(controller)

      ReadableStream.error(left.controller_pid, :left_failed)
      assert {:rejected, :left_failed} = read_result(ref)
      :ok = Request.respond(request, "ab")

      assert %{value: value} = await(Reader.read(ReadableStream.get_reader(right)))
      assert bytes(value) == "ab"
    end

    test "is the end of the branches when the stream stops" do
      {stream, _controller, left, right} = tee()
      tee = tee_process(stream)
      reader = ReadableStream.get_reader(left)
      ref = start_read(fn -> Reader.read(reader) end)

      Process.exit(stream.controller_pid, :kill)
      assert {:rejected, %Web.TypeError{}} = read_result(ref)
      assert_raise Web.TypeError, fn -> Enum.to_list(right) end
      assert_down(tee)

      # The work of a tee that stopped is complete.
      assert :ok = await(ReadableByteStreamTee.cancel(tee, 1, :late))
    end

    test "of a BYOB read into a view that a different process detached stops the read" do
      {stream, controller, left, _right} = tee()
      left_controller = %Controller{pid: left.controller_pid}
      pid = stream.controller_pid

      # The stream gets the read of the tee after the detach.
      :erlang.suspend_process(pid)
      reader = ReadableStream.get_reader(left, mode: "byob")
      ref = start_read(fn -> BYOBReader.read(reader, view(2)) end)
      await_message(pid)
      ArrayBuffer.transfer(Controller.byob_request(left_controller).view.buffer)
      :erlang.resume_process(pid)

      # The stream refuses the read. The read of the branch waits.
      assert Controller.byob_request(controller) == nil
      refute_received {^ref, _outcome}
    end
  end

  describe "the tee process" do
    test "does no read for a pull of a branch that has its bytes already" do
      test = self()
      {stream, controller, left, _right} = tee(%{pull: fn _controller -> send(test, :pulled) end})
      tee = tee_process(stream)

      ReadableByteStreamTee.pull(tee, 1, nil)
      assert ReadableStream.__get_slots__(stream.controller_pid).read_requests == :queue.new()
      refute_received :pulled

      Controller.enqueue(controller, "a")
      assert [_chunk] = Enum.take(left, 1)
    end

    test "stops when the process that calls tee stops before the branches exist" do
      stream = ReadableStream.new(%{type: "bytes"})
      test = self()

      spawn(fn ->
        {:ok, tee} = ReadableByteStreamTee.start(stream.controller_pid)
        send(test, {:tee, tee})
      end)

      assert_receive {:tee, tee}
      assert_down(tee)
    end

    test "cannot start for a stream that is locked" do
      stream = ReadableStream.new(%{type: "bytes"})
      _reader = ReadableStream.get_reader(stream)
      assert ReadableByteStreamTee.start(stream.controller_pid) == {:error, :already_locked}
    end
  end
end
