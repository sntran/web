defmodule Web.ReadableByteStreamTest do
  use ExUnit.Case, async: true

  import Web, only: [await: 1]

  alias Web.AbortController
  alias Web.ArrayBuffer
  alias Web.AsyncContext
  alias Web.DecompressionStream
  alias Web.ReadableByteStreamController
  alias Web.ReadableStream
  alias Web.ReadableStreamBYOBReader
  alias Web.ReadableStreamBYOBRequest
  alias Web.TextDecoderStream
  alias Web.Uint8Array

  test "BYOB readers consume queued bytes and preserve queued remainders" do
    stream = ReadableStream.new(%{type: "bytes"})
    reader = ReadableStream.get_reader(stream, mode: "byob")

    ReadableStream.enqueue(stream.controller_pid, "hello")

    first = Uint8Array.new(ArrayBuffer.new(3))
    second = Uint8Array.new(ArrayBuffer.new(3))

    assert %{value: first_chunk, done: false} =
             await(ReadableStreamBYOBReader.read(reader, first))

    assert Uint8Array.to_binary(first_chunk) == "hel"

    assert %{value: second_chunk, done: false} =
             await(ReadableStreamBYOBReader.read(reader, second))

    assert Uint8Array.to_binary(second_chunk) == "lo"
  end

  test "ReadableByteStreamController exposes the current BYOB request" do
    parent = self()

    stream =
      ReadableStream.new(%{
        type: "bytes",
        pull: fn controller ->
          send(parent, {:pull, controller, ReadableByteStreamController.byob_request(controller)})
        end
      })

    view = Uint8Array.new(ArrayBuffer.new(5))

    spawn(fn ->
      reader = ReadableStream.get_reader(stream, mode: "byob")
      send(parent, {:read_result, await(ReadableStreamBYOBReader.read(reader, view))})
    end)

    assert_receive {:pull, %ReadableByteStreamController{pid: pid},
                    %ReadableStreamBYOBRequest{} = request},
                   1_000

    assert pid == stream.controller_pid
    assert is_reference(request.address)
    assert request.view_byte_offset == view.byte_offset
    assert request.view_byte_length == view.byte_length
    assert ReadableByteStreamController.desired_size(%ReadableByteStreamController{pid: pid}) == 1

    assert_raise ArgumentError,
                 ~r/BYOB requests must respond with a binary payload sent through the request capability/,
                 fn ->
                   ReadableStreamBYOBRequest.respond(request, 5)
                 end

    assert :ok = ReadableStreamBYOBRequest.respond(request, "hello")

    assert_receive {:read_result, %{value: response_view, done: false}}, 1_000
    assert Uint8Array.to_binary(response_view) == "hello"
  end

  test "BYOB requests can respond with a replacement view" do
    parent = self()

    stream =
      ReadableStream.new(%{
        type: "bytes",
        pull: fn controller ->
          send(parent, ReadableByteStreamController.byob_request(controller))
        end
      })

    spawn(fn ->
      reader = ReadableStream.get_reader(stream, mode: "byob")

      send(
        parent,
        {:read_result,
         await(ReadableStreamBYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(1))))}
      )
    end)

    assert_receive %ReadableStreamBYOBRequest{} = request, 1_000
    assert :ok = ReadableStreamBYOBRequest.respond_with_new_view(request, "abc")

    assert_receive {:read_result, %{value: chunk_view, done: false}}, 1_000
    assert Uint8Array.to_binary(chunk_view) == "abc"
  end

  test "BYOB request aliases are revoked after fulfillment" do
    parent = self()
    stream = ReadableStream.new(%{type: "bytes"})

    worker =
      spawn(fn ->
        reader = ReadableStream.get_reader(stream, mode: "byob")

        send(
          parent,
          {:first_read,
           await(ReadableStreamBYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(2))))}
        )

        receive do
          :second_read ->
            send(
              parent,
              {:second_read,
               await(ReadableStreamBYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(2))))}
            )
        end
      end)

    first_request = await_byob_request(stream.controller_pid)
    first_address = first_request.address

    assert :ok = ReadableStreamBYOBRequest.respond(first_request, "ok")

    assert_receive {:first_read, %{value: first_chunk, done: false}}, 1_000
    assert Uint8Array.to_binary(first_chunk) == "ok"

    send(worker, :second_read)

    second_request = await_byob_request(stream.controller_pid)
    assert second_request.address != first_address

    send(first_address, {:web_stream_byob_response, first_address, {:chunk, "zz"}})
    Process.sleep(25)

    assert ReadableStream.__get_slots__(stream.controller_pid).pending_byob_request.address ==
             second_request.address

    refute_receive {:second_read, _result}, 50

    ReadableStream.close(stream.controller_pid)
    assert_receive {:second_read, %{done: true}}, 1_000
  end

  test "ReadableByteStreamController wait_for_capacity unblocks when readers drain queued bytes" do
    stream = ReadableStream.new(%{type: "bytes"})
    controller = %ReadableByteStreamController{pid: stream.controller_pid}

    ReadableStream.enqueue(stream.controller_pid, "ab")

    waiter = Task.async(fn -> ReadableByteStreamController.wait_for_capacity(controller) end)
    assert Task.yield(waiter, 20) == nil

    reader = ReadableStream.get_reader(stream)
    assert %{value: "ab", done: false} = await(Web.ReadableStreamDefaultReader.read(reader))
    assert {:ok, :ok} = Task.yield(waiter, 1_000)
  end

  test "ReadableByteStreamController wait_for_capacity returns when the stream errors" do
    stream = ReadableStream.new(%{type: "bytes"})
    controller = %ReadableByteStreamController{pid: stream.controller_pid}

    ReadableStream.enqueue(stream.controller_pid, "ab")

    waiter = Task.async(fn -> ReadableByteStreamController.wait_for_capacity(controller) end)
    assert Task.yield(waiter, 20) == nil

    ReadableStream.error(stream.controller_pid, :boom)
    assert {:ok, :ok} = Task.yield(waiter, 1_000)
  end

  test "close and error resolve pending BYOB reads" do
    closed_stream =
      ReadableStream.new(%{
        type: "bytes",
        pull: fn controller ->
          ReadableByteStreamController.close(controller)
        end
      })

    closed_reader = ReadableStream.get_reader(closed_stream, mode: "byob")
    closed_view = Uint8Array.new(ArrayBuffer.new(2))

    assert await(ReadableStreamBYOBReader.read(closed_reader, closed_view)) ==
             %{value: closed_view, done: true}

    errored_stream =
      ReadableStream.new(%{
        type: "bytes",
        pull: fn controller ->
          ReadableByteStreamController.error(controller, :boom)
        end
      })

    errored_reader = ReadableStream.get_reader(errored_stream, mode: "byob")
    errored_view = Uint8Array.new(ArrayBuffer.new(2))

    assert :boom = catch_exit(await(ReadableStreamBYOBReader.read(errored_reader, errored_view)))
  end

  test "BYOB reader release_lock and cancel delegate to the readable stream" do
    stream = ReadableStream.new(%{type: "bytes"})
    reader = ReadableStream.get_reader(stream, mode: "byob")

    assert :ok = ReadableStreamBYOBReader.release_lock(reader)

    reader = ReadableStream.get_reader(stream, mode: "byob")
    assert :ok = await(ReadableStreamBYOBReader.cancel(reader, :stop))
  end

  test "BYOB readers surface stale locks and protocol validation errors" do
    stream = ReadableStream.new(%{type: "bytes"})
    reader = ReadableStream.get_reader(stream, mode: "byob")

    assert %Web.TypeError{message: "BYOB reads require a Uint8Array view."} =
             catch_exit(await(ReadableStreamBYOBReader.read(reader, :invalid)))

    assert :ok = ReadableStreamBYOBReader.release_lock(reader)

    assert %Web.TypeError{message: "This BYOB reader is no longer locked."} =
             catch_exit(
               await(ReadableStreamBYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(1))))
             )

    assert_raise Web.TypeError, ~r/no longer locked/, fn ->
      ReadableStreamBYOBReader.release_lock(reader)
    end

    invalid_pid =
      start_byob_reader_server(fn {:byob_read, _owner, _view} -> {:error, :invalid_byob_view} end)

    assert %Web.TypeError{message: "BYOB reads require a Uint8Array view."} =
             catch_exit(
               await(
                 ReadableStreamBYOBReader.read(
                   %ReadableStreamBYOBReader{controller_pid: invalid_pid},
                   Uint8Array.new(ArrayBuffer.new(1))
                 )
               )
             )

    generic_pid = start_byob_reader_server(fn {:byob_read, _owner, _view} -> {:error, :weird} end)

    assert :weird =
             catch_exit(
               await(
                 ReadableStreamBYOBReader.read(
                   %ReadableStreamBYOBReader{controller_pid: generic_pid},
                   Uint8Array.new(ArrayBuffer.new(1))
                 )
               )
             )

    release_pid = start_byob_reader_server(fn {:release_lock, _owner} -> {:error, :weird} end)

    assert_raise Web.TypeError, ~r/Unknown error: :weird/, fn ->
      ReadableStreamBYOBReader.release_lock(%ReadableStreamBYOBReader{
        controller_pid: release_pid
      })
    end
  end

  test "BYOB readers propagate stream errors and default cancel reasons" do
    parent = self()

    cancel_stream =
      ReadableStream.new(%{
        type: "bytes",
        cancel: fn reason -> send(parent, {:cancelled, reason}) end
      })

    cancel_reader = ReadableStream.get_reader(cancel_stream, mode: "byob")
    assert :ok = await(ReadableStreamBYOBReader.cancel(cancel_reader))
    assert_receive {:cancelled, :cancelled}

    errored_stream = ReadableStream.new(%{type: "bytes"})
    errored_reader = ReadableStream.get_reader(errored_stream, mode: "byob")
    ReadableStream.error(errored_stream.controller_pid, :boom)

    assert :boom =
             catch_exit(
               await(
                 ReadableStreamBYOBReader.read(
                   errored_reader,
                   Uint8Array.new(ArrayBuffer.new(1))
                 )
               )
             )
  end

  test "direct enqueue fulfills pending BYOB reads with exact fits and queued overflow" do
    parent = self()
    exact_stream = ReadableStream.new(%{type: "bytes"})

    spawn(fn ->
      reader = ReadableStream.get_reader(exact_stream, mode: "byob")

      send(
        parent,
        {:exact_result,
         await(ReadableStreamBYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(2))))}
      )
    end)

    _request = await_byob_request(exact_stream.controller_pid)
    ReadableStream.enqueue(exact_stream.controller_pid, "ok")

    assert_receive {:exact_result, %{value: exact_chunk, done: false}}, 1_000
    assert Uint8Array.to_binary(exact_chunk) == "ok"
    assert :queue.is_empty(ReadableStream.__get_slots__(exact_stream.controller_pid).queue)

    overflow_stream = ReadableStream.new(%{type: "bytes"})

    spawn(fn ->
      reader = ReadableStream.get_reader(overflow_stream, mode: "byob")

      send(
        parent,
        {:overflow_first,
         await(ReadableStreamBYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(2))))}
      )

      send(
        parent,
        {:overflow_second,
         await(ReadableStreamBYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(3))))}
      )
    end)

    _request = await_byob_request(overflow_stream.controller_pid)
    ReadableStream.enqueue(overflow_stream.controller_pid, "hello")

    assert_receive {:overflow_first, %{value: first_chunk, done: false}}, 1_000
    assert Uint8Array.to_binary(first_chunk) == "he"

    assert_receive {:overflow_second, %{value: second_chunk, done: false}}, 1_000
    assert Uint8Array.to_binary(second_chunk) == "llo"
  end

  test "raw byte-stream calls validate views, locks, closed reads, and BYOB response state" do
    stream = ReadableStream.new(%{type: "bytes"})
    _reader = ReadableStream.get_reader(stream, mode: "byob")

    assert {:error, :invalid_byob_view} =
             :gen_statem.call(stream.controller_pid, {:byob_read, self(), :invalid})

    assert {:error, :not_locked_by_reader} = ReadableStream.read(stream.controller_pid)

    ReadableStream.close(stream.controller_pid)

    assert :done =
             ReadableStream.byob_read(stream.controller_pid, Uint8Array.new(ArrayBuffer.new(1)))

    pending_stream = ReadableStream.new(%{type: "bytes"})
    parent = self()

    spawn(fn ->
      reader = ReadableStream.get_reader(pending_stream, mode: "byob")

      send(
        parent,
        {:pending_read,
         await(ReadableStreamBYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(2))))}
      )
    end)

    _request = await_byob_request(pending_stream.controller_pid)

    assert {:error, :byob_capability_required} =
             Web.Stream.control_call(pending_stream.controller_pid, {:byob_respond, 3})

    assert {:error, :byob_capability_required} =
             Web.Stream.control_call(
               pending_stream.controller_pid,
               {:byob_respond_with_new_view, :invalid}
             )

    ReadableStream.close(pending_stream.controller_pid)
    assert_receive {:pending_read, %{done: true}}, 1_000

    assert {:error, :byob_capability_required} =
             Web.Stream.control_call(pending_stream.controller_pid, {:byob_respond, 1})

    assert {:error, :byob_capability_required} =
             Web.Stream.control_call(
               pending_stream.controller_pid,
               {:byob_respond_with_new_view, Uint8Array.new(ArrayBuffer.new(1))}
             )
  end

  test "errored byte streams reject pending BYOB requests" do
    stream = ReadableStream.new(%{type: "bytes"})
    parent = self()

    spawn(fn ->
      reader = ReadableStream.get_reader(stream, mode: "byob")

      send(
        parent,
        {:errored_pending_read,
         catch_exit(
           await(ReadableStreamBYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(2))))
         )}
      )
    end)

    _request = await_byob_request(stream.controller_pid)
    ReadableStream.error(stream.controller_pid, :boom)

    assert_receive {:errored_pending_read, :boom}, 1_000
  end

  test "invalid BYOB response payloads error pending reads while unrelated messages are ignored" do
    stream = ReadableStream.new(%{type: "bytes"})
    parent = self()

    spawn(fn ->
      reader = ReadableStream.get_reader(stream, mode: "byob")

      send(
        parent,
        {:invalid_payload_read,
         catch_exit(
           await(ReadableStreamBYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(2))))
         )}
      )
    end)

    request = await_byob_request(stream.controller_pid)

    send(stream.controller_pid, {:web_stream_byob_response, make_ref(), {:chunk, "ignored"}})
    Process.sleep(25)

    assert ReadableStream.__get_slots__(stream.controller_pid).pending_byob_request.address ==
             request.address

    send(
      stream.controller_pid,
      {:web_stream_byob_response, request.address, {:invalid, :payload}}
    )

    assert_receive {:invalid_payload_read, :invalid_byob_response}, 1_000
    assert ReadableStream.__get_slots__(stream.controller_pid).pending_byob_request == nil
    assert ReadableStream.__get_slots__(stream.controller_pid).state == :errored
  end

  test "invalid BYOB replacement views error pending reads" do
    stream = ReadableStream.new(%{type: "bytes"})
    parent = self()

    spawn(fn ->
      reader = ReadableStream.get_reader(stream, mode: "byob")

      send(
        parent,
        {:invalid_view_read,
         catch_exit(
           await(ReadableStreamBYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(2))))
         )}
      )
    end)

    request = await_byob_request(stream.controller_pid)

    send(
      stream.controller_pid,
      {:web_stream_byob_response, request.address, {:view, :invalid}}
    )

    assert_receive {:invalid_view_read, :invalid_byob_response}, 1_000
    assert ReadableStream.__get_slots__(stream.controller_pid).pending_byob_request == nil
    assert ReadableStream.__get_slots__(stream.controller_pid).state == :errored
  end

  test "raw BYOB stream internals handle non-byte locks and binary replacement views" do
    {:ok, default_pid} = ReadableStream.start_link()
    owner = self()

    :sys.replace_state(default_pid, fn {state, data} ->
      {state, %{data | reader_pid: owner, reader_mode: :byob}}
    end)

    assert {:error, :not_byte_stream} =
             ReadableStream.byob_read(default_pid, Uint8Array.new(ArrayBuffer.new(1)))

    binary_stream = ReadableStream.new(%{type: "bytes"})
    parent = self()

    spawn(fn ->
      reader = ReadableStream.get_reader(binary_stream, mode: "byob")

      send(
        parent,
        {:binary_result,
         await(ReadableStreamBYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(2))))}
      )
    end)

    request = await_byob_request(binary_stream.controller_pid)

    send(
      binary_stream.controller_pid,
      {:web_stream_byob_response, request.address, {:view, "ok"}}
    )

    assert_receive {:binary_result, %{value: binary_view, done: false}}, 1_000
    assert Uint8Array.to_binary(binary_view) == "ok"

    fresh_stream = ReadableStream.new(%{type: "bytes"})

    assert {:error, :byob_capability_required} =
             Web.Stream.control_call(
               fresh_stream.controller_pid,
               {:byob_respond_with_new_view, Uint8Array.new(ArrayBuffer.new(1))}
             )
  end

  test "ambient abort tears down pending BYOB aliases before the signal is observed" do
    controller = AbortController.new()
    parent = self()

    stream =
      AsyncContext.with_signal(controller.signal, fn ->
        ReadableStream.new(%{type: "bytes"})
      end)

    spawn(fn ->
      reader = ReadableStream.get_reader(stream, mode: "byob")

      send(
        parent,
        {:aborting_read,
         await(ReadableStreamBYOBReader.read(reader, Uint8Array.new(ArrayBuffer.new(2))))}
      )
    end)

    request = await_byob_request(stream.controller_pid)
    address = request.address

    assert :ok = AbortController.abort(controller, :byob_abort)
    assert_receive {:aborting_read, %{done: true}}, 1_000
    assert ReadableStream.__get_slots__(stream.controller_pid).pending_byob_request == nil

    send(address, {:web_stream_byob_response, address, {:chunk, "zz"}})
    Process.sleep(25)
    assert :queue.is_empty(ReadableStream.__get_slots__(stream.controller_pid).queue)

    exception =
      assert_raise Web.DOMException, fn ->
        Web.AbortSignal.throw_if_aborted(controller.signal)
      end

    assert exception.name == "AbortError"
    assert exception.message == ":byob_abort"
  end

  test "byte streams pipe through decompression and text decoding" do
    compressed = :zlib.gzip("hello byte stream")

    stream =
      ReadableStream.new(%{
        type: "bytes",
        start: fn controller ->
          ReadableByteStreamController.enqueue(controller, compressed)
          ReadableByteStreamController.close(controller)
        end
      })

    decoded =
      stream
      |> ReadableStream.pipe_through(DecompressionStream.new("gzip"))
      |> ReadableStream.pipe_through(TextDecoderStream.new())

    assert Enum.join(decoded, "") == "hello byte stream"
  end

  defp start_byob_reader_server(reply_fun) do
    spawn(fn ->
      receive do
        {:"$gen_call", {from, ref}, request} ->
          send(from, {ref, reply_fun.(request)})
      end
    end)
  end

  defp await_byob_request(pid, attempts \\ 50)

  defp await_byob_request(pid, attempts) when attempts > 0 do
    case Web.Stream.control_call(pid, :get_byob_request) do
      %ReadableStreamBYOBRequest{} = request ->
        request

      _other ->
        Process.sleep(10)
        await_byob_request(pid, attempts - 1)
    end
  end

  defp await_byob_request(_pid, 0), do: flunk("expected a pending BYOB request")
end
