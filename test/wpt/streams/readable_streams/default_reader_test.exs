# Port of the web-platform-tests file
# streams/readable-streams/default-reader.any.js
# at the revision 61ad038e419a0bfacee26801e584b5057c3fbd60.
#
# Each ExUnit test has the name of its WPT test.
#
# Mapping of the JS API:
#
#   * `undefined` is `nil`. This library also gives `nil` as the value of a
#     read result with `done: true`.
#   * An error object of the WPT file, such as `{ name: 'unique error' }`,
#     is a map. `new Error(message)` is a `RuntimeError` with that message.
#   * The getter `closed` is `ReadableStreamDefaultReader.closed/1`.
#   * An argument that the JS code does not give gets the default value of
#     the Elixir function.
#
# Not ported (not applicable):
#
#   * "getReader() should call ToString() on mode": the mode is a JS object
#     with a method toString. Elixir has no ToString conversion of a value.
defmodule Web.WPT.Streams.DefaultReaderTest do
  use ExUnit.Case, async: true

  import Web, only: [await: 1]

  alias Web.Promise
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.ReadableStreamDefaultReader
  alias Web.TypeError

  # Makes a stream with an empty source, and gives its controller. The
  # function `start` runs in the process that makes the stream, thus the
  # message is in the mailbox when `new/1` returns.
  defp stream_with_controller do
    parent = self()
    rs = ReadableStream.new(%{start: fn c -> send(parent, {:controller, c}) end})
    assert_received {:controller, controller}
    {rs, controller}
  end

  test "ReadableStreamDefaultReader constructor should get a ReadableStream object as argument" do
    for value <- [nil, %{}, :stream] do
      assert_raise TypeError, fn -> ReadableStreamDefaultReader.new(value) end
    end
  end

  test "ReadableStreamDefaultReader closed should always return the same promise object" do
    rs_reader = ReadableStreamDefaultReader.new(ReadableStream.new())

    assert ReadableStreamDefaultReader.closed(rs_reader) ==
             ReadableStreamDefaultReader.closed(rs_reader),
           "closed should return the same promise"
  end

  test "Constructing a ReadableStreamDefaultReader directly should fail if the stream is already locked (via direct construction)" do
    rs = ReadableStream.new()
    ReadableStreamDefaultReader.new(rs)

    assert_raise TypeError, fn -> ReadableStreamDefaultReader.new(rs) end
  end

  test "Getting a ReadableStreamDefaultReader via getReader should fail if the stream is already locked (via direct construction)" do
    rs = ReadableStream.new()
    ReadableStreamDefaultReader.new(rs)

    assert_raise TypeError, fn -> ReadableStream.get_reader(rs) end
  end

  test "Constructing a ReadableStreamDefaultReader directly should fail if the stream is already locked (via getReader)" do
    rs = ReadableStream.new()
    ReadableStream.get_reader(rs)

    assert_raise TypeError, fn -> ReadableStreamDefaultReader.new(rs) end
  end

  test "Constructing a ReadableStreamDefaultReader directly should be OK if the stream is closed" do
    rs = ReadableStream.new(%{start: &ReadableStreamDefaultController.close/1})

    assert %ReadableStreamDefaultReader{} = ReadableStreamDefaultReader.new(rs)
  end

  test "Constructing a ReadableStreamDefaultReader directly should be OK if the stream is errored" do
    the_error = %RuntimeError{message: "boo!"}
    rs = ReadableStream.new(%{start: &ReadableStreamDefaultController.error(&1, the_error)})

    assert %ReadableStreamDefaultReader{} = ReadableStreamDefaultReader.new(rs)
  end

  test "Getting a ReadableStreamDefaultReader via getReader should fail if the stream is already locked (via getReader)" do
    rs = ReadableStream.new()
    # The first get_reader/1 must not raise.
    ReadableStream.get_reader(rs)

    assert_raise TypeError, fn -> ReadableStream.get_reader(rs) end
  end

  test "Reading from a reader for an empty stream will wait until a chunk is available" do
    {rs, controller} = stream_with_controller()
    reader = ReadableStream.get_reader(rs)

    promise = ReadableStreamDefaultReader.read(reader)

    ReadableStreamDefaultController.enqueue(controller, "a")

    assert await(promise) == %{value: "a", done: false},
           "read() should fulfill with the enqueued chunk"
  end

  test "cancel() on a reader does not release the reader" do
    parent = self()
    passed_reason = %RuntimeError{message: "it wasn't the right time, sorry"}

    # The function `cancel` uses the stream. The stream does not exist when
    # the source is made, thus an agent holds it.
    holder = start_supervised!({Agent, fn -> nil end})

    rs =
      ReadableStream.new(%{
        # This function runs in a different process. A failed assertion
        # rejects the promise of the cancel, as a throw in JS does.
        cancel: fn reason ->
          rs = Agent.get(holder, & &1)
          assert ReadableStream.locked?(rs), "the stream should still be locked"

          assert_raise TypeError,
                       fn -> ReadableStream.get_reader(rs) end

          assert reason == passed_reason,
                 "the cancellation reason is passed through to the underlying source"

          send(parent, :cancel_called)
        end
      })

    Agent.update(holder, fn _ -> rs end)

    reader = ReadableStream.get_reader(rs)
    await(ReadableStreamDefaultReader.cancel(reader, passed_reason))
    assert_receive :cancel_called
  end

  test "closed should be fulfilled after stream is closed (.closed access before acquiring)" do
    {rs, controller} = stream_with_controller()

    reader = ReadableStream.get_reader(rs)
    promise = ReadableStreamDefaultReader.closed(reader)

    ReadableStreamDefaultController.close(controller)
    await(promise)
  end

  test "closed should be rejected after reader releases its lock (multiple stream locks)" do
    {rs, controller} = stream_with_controller()

    reader1 = ReadableStream.get_reader(rs)

    ReadableStreamDefaultReader.release_lock(reader1)

    reader2 = ReadableStream.get_reader(rs)
    ReadableStreamDefaultController.close(controller)

    closed1 = ReadableStreamDefaultReader.closed(reader1)
    closed2 = ReadableStreamDefaultReader.closed(reader2)

    assert %TypeError{} = catch_exit(await(closed1))
    await(closed2)
  end

  test "closed is replaced when stream closes and reader releases its lock" do
    {rs, controller} = stream_with_controller()

    reader = ReadableStream.get_reader(rs)
    promise1 = ReadableStreamDefaultReader.closed(reader)

    ReadableStreamDefaultController.close(controller)

    ReadableStreamDefaultReader.release_lock(reader)
    promise2 = ReadableStreamDefaultReader.closed(reader)

    refute promise1 == promise2, ".closed should be replaced"
    await(promise1)

    assert %TypeError{} = catch_exit(await(promise2)),
           ".closed after releasing lock"
  end

  test "closed is replaced when stream errors and reader releases its lock" do
    the_error = %{name: "unique error"}
    {rs, controller} = stream_with_controller()

    reader = ReadableStream.get_reader(rs)
    promise1 = ReadableStreamDefaultReader.closed(reader)

    ReadableStreamDefaultController.error(controller, the_error)

    ReadableStreamDefaultReader.release_lock(reader)
    promise2 = ReadableStreamDefaultReader.closed(reader)

    refute promise1 == promise2, ".closed should be replaced"

    assert catch_exit(await(promise1)) == the_error,
           ".closed before releasing lock"

    assert %TypeError{} = catch_exit(await(promise2)),
           ".closed after releasing lock"
  end

  test "Multiple readers can access the stream in sequence" do
    rs =
      ReadableStream.new(%{
        start: fn c ->
          ReadableStreamDefaultController.enqueue(c, "a")
          ReadableStreamDefaultController.enqueue(c, "b")
          ReadableStreamDefaultController.close(c)
        end
      })

    reader1 = ReadableStream.get_reader(rs)
    promise1 = ReadableStreamDefaultReader.read(reader1)
    ReadableStreamDefaultReader.release_lock(reader1)

    reader2 = ReadableStream.get_reader(rs)
    promise2 = ReadableStreamDefaultReader.read(reader2)
    ReadableStreamDefaultReader.release_lock(reader2)

    assert await(promise1) == %{value: "a", done: false},
           "reading the first chunk from reader1 works"

    assert await(promise2) == %{value: "b", done: false},
           "reading the second chunk from reader2 works"
  end

  test "Cannot use an already-released reader to unlock a stream again" do
    rs =
      ReadableStream.new(%{
        start: fn c -> ReadableStreamDefaultController.enqueue(c, "a") end
      })

    reader1 = ReadableStream.get_reader(rs)
    ReadableStreamDefaultReader.release_lock(reader1)

    reader2 = ReadableStream.get_reader(rs)

    # This call must have no effect.
    ReadableStreamDefaultReader.release_lock(reader1)

    assert await(ReadableStreamDefaultReader.read(reader2)) == %{value: "a", done: false},
           "read() should still work on reader2 even after reader1 is released"
  end

  test "cancel() on a released reader is a no-op and does not pass through" do
    parent = self()

    rs =
      ReadableStream.new(%{
        start: fn c -> ReadableStreamDefaultController.enqueue(c, "a") end,
        cancel: fn _reason -> send(parent, :cancel_called) end
      })

    reader = ReadableStream.get_reader(rs)
    ReadableStreamDefaultReader.release_lock(reader)
    cancel_promise = ReadableStreamDefaultReader.cancel(reader)

    reader2 = ReadableStream.get_reader(rs)
    read_promise = ReadableStreamDefaultReader.read(reader2)

    assert %TypeError{} = catch_exit(await(cancel_promise))

    assert await(read_promise) == %{value: "a", done: false},
           "a new reader should be able to read a chunk"

    refute_received :cancel_called, "underlying source cancel should not be called"
  end

  test "Getting a second reader after erroring the stream and releasing the reader should succeed" do
    the_error = %{name: "unique error"}
    {rs, controller} = stream_with_controller()

    reader1 = ReadableStream.get_reader(rs)

    reader1_closed = ReadableStreamDefaultReader.closed(reader1)
    reader1_read = ReadableStreamDefaultReader.read(reader1)

    assert_raise TypeError, fn -> ReadableStream.get_reader(rs) end

    ReadableStreamDefaultController.error(controller, the_error)

    ReadableStreamDefaultReader.release_lock(reader1)

    reader2 = ReadableStream.get_reader(rs)

    reader2_closed = ReadableStreamDefaultReader.closed(reader2)
    reader2_read = ReadableStreamDefaultReader.read(reader2)

    assert catch_exit(await(reader1_closed)) == the_error
    assert catch_exit(await(reader1_read)) == the_error
    assert catch_exit(await(reader2_closed)) == the_error
    assert catch_exit(await(reader2_read)) == the_error
  end

  test "ReadableStreamDefaultReader closed promise should be rejected with undefined if that is the error" do
    {rs, controller} = stream_with_controller()

    promise = ReadableStreamDefaultReader.closed(ReadableStream.get_reader(rs))

    # `controller.error()` with no argument errors the stream with undefined.
    ReadableStreamDefaultController.error(controller, nil)

    assert catch_exit(await(promise)) == nil, "passed error should be undefined as it was"
  end

  test "ReadableStreamDefaultReader: if start rejects with no parameter, it should error the stream with an undefined error" do
    rs = ReadableStream.new(%{start: fn _c -> Promise.reject(nil) end})

    read = ReadableStreamDefaultReader.read(ReadableStream.get_reader(rs))

    assert catch_exit(await(read)) == nil, "passed error should be undefined as it was"
  end

  test "Erroring a ReadableStream after checking closed should reject ReadableStreamDefaultReader closed promise" do
    the_error = %{name: "unique string"}
    {rs, controller} = stream_with_controller()

    promise = ReadableStreamDefaultReader.closed(ReadableStream.get_reader(rs))

    ReadableStreamDefaultController.error(controller, the_error)
    assert catch_exit(await(promise)) == the_error
  end

  test "Erroring a ReadableStream before checking closed should reject ReadableStreamDefaultReader closed promise" do
    the_error = %{name: "unique string"}
    {rs, controller} = stream_with_controller()

    ReadableStreamDefaultController.error(controller, the_error)

    # Two calls of get_reader/1 for more coverage of this code path.
    ReadableStreamDefaultReader.release_lock(ReadableStream.get_reader(rs))

    closed = ReadableStreamDefaultReader.closed(ReadableStream.get_reader(rs))
    assert catch_exit(await(closed)) == the_error
  end

  test "Reading twice on a stream that gets closed" do
    {rs, controller} = stream_with_controller()
    reader = ReadableStream.get_reader(rs)

    read1 = ReadableStreamDefaultReader.read(reader)
    read2 = ReadableStreamDefaultReader.read(reader)
    closed = ReadableStreamDefaultReader.closed(reader)

    ReadableStreamDefaultController.close(controller)

    assert await(read1) == %{value: nil, done: true}, "read() should fulfill with close (1)"
    assert await(read2) == %{value: nil, done: true}, "read() should fulfill with close (2)"
    await(closed)
  end

  test "Reading twice on a closed stream" do
    {rs, controller} = stream_with_controller()

    ReadableStreamDefaultController.close(controller)
    reader = ReadableStream.get_reader(rs)

    read1 = ReadableStreamDefaultReader.read(reader)
    read2 = ReadableStreamDefaultReader.read(reader)
    closed = ReadableStreamDefaultReader.closed(reader)

    assert await(read1) == %{value: nil, done: true}, "read() should fulfill with close (1)"
    assert await(read2) == %{value: nil, done: true}, "read() should fulfill with close (2)"
    await(closed)
  end

  test "Reading twice on an errored stream" do
    {rs, controller} = stream_with_controller()

    my_error = %{name: "mashed potatoes"}
    ReadableStreamDefaultController.error(controller, my_error)

    reader = ReadableStream.get_reader(rs)

    read1 = ReadableStreamDefaultReader.read(reader)
    read2 = ReadableStreamDefaultReader.read(reader)
    closed = ReadableStreamDefaultReader.closed(reader)

    assert catch_exit(await(read1)) == my_error
    assert catch_exit(await(read2)) == my_error
    assert catch_exit(await(closed)) == my_error
  end

  test "Reading twice on a stream that gets errored" do
    {rs, controller} = stream_with_controller()

    my_error = %{name: "mashed potatoes"}
    reader = ReadableStream.get_reader(rs)

    read1 = ReadableStreamDefaultReader.read(reader)
    read2 = ReadableStreamDefaultReader.read(reader)
    closed = ReadableStreamDefaultReader.closed(reader)

    ReadableStreamDefaultController.error(controller, my_error)

    assert catch_exit(await(read1)) == my_error
    assert catch_exit(await(read2)) == my_error
    assert catch_exit(await(closed)) == my_error
  end

  test "controller.close() should clear the list of pending read requests" do
    rs =
      ReadableStream.new(%{
        pull: fn controller -> ReadableStreamDefaultController.close(controller) end
      })

    reader = ReadableStream.get_reader(rs)
    await(ReadableStreamDefaultReader.read(reader))

    # The test passes if release_lock/1 does not raise.
    ReadableStreamDefaultReader.release_lock(reader)
  end

  test "Second reader can read chunks after first reader was released with pending read requests" do
    {rs, controller} = stream_with_controller()

    reader1 = ReadableStream.get_reader(rs)
    promise1 = ReadableStreamDefaultReader.read(reader1)
    ReadableStreamDefaultReader.release_lock(reader1)

    ReadableStreamDefaultController.enqueue(controller, "a")

    reader2 = ReadableStream.get_reader(rs)
    promise2 = ReadableStreamDefaultReader.read(reader2)
    ReadableStreamDefaultReader.release_lock(reader2)

    assert %TypeError{} = catch_exit(await(promise1)),
           "read() from reader1 should reject when reader1 is released"

    assert await(promise2) == %{value: "a", done: false},
           "read() from reader2 should resolve with enqueued chunk"
  end
end
