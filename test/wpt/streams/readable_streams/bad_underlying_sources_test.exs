# Port of the web-platform-tests file
# streams/readable-streams/bad-underlying-sources.any.js
# at the revision 61ad038e419a0bfacee26801e584b5057c3fbd60.
#
# Each ExUnit test has the name of its WPT test.
#
# Mapping of the JS API:
#
#   * `undefined` is `nil`.
#   * `new Error(message)` is a `RuntimeError` with that message. A `throw`
#     of such an error is a `raise`. A `throw` of a different value, such as
#     `{ name: 'error1' }`, is a `throw` of a map.
#   * The function `start` runs in the process that makes the stream, as in
#     JS. The functions `pull` and `cancel` run in a different process, thus
#     a value that they share with the test is in `:counters` or `:atomics`,
#     or it goes to the test in a message.
#   * The flag `startCalled` of the WPT file is the message `:start_called`.
#
# Not ported (not applicable):
#
#   * "Underlying source start: throwing getter": a getter that throws. An
#     Elixir map has no getters.
#   * "Underlying source: throwing pull getter (initial pull)": a getter that
#     throws.
#   * "Underlying source pull: throwing getter (second pull does not result in
#     a second get)": a getter that counts the times that it runs.
#   * "Underlying source cancel: throwing getter": a getter that throws.
defmodule Web.WPT.Streams.BadUnderlyingSourcesTest do
  use ExUnit.Case, async: true

  import Web, only: [await: 1]

  alias Web.Promise
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.ReadableStreamDefaultReader
  alias Web.TypeError

  test "Underlying source start: throwing method" do
    the_error = %RuntimeError{message: "a unique string"}

    error =
      assert_raise RuntimeError, fn ->
        ReadableStream.new(%{start: fn _c -> raise the_error end})
      end

    assert error == the_error, "constructing the stream should re-throw the error"
  end

  test "Underlying source: throwing pull method (initial pull)" do
    the_error = %RuntimeError{message: "a unique string"}
    rs = ReadableStream.new(%{pull: fn _c -> raise the_error end})

    closed = ReadableStreamDefaultReader.closed(ReadableStream.get_reader(rs))
    assert catch_exit(await(closed)) == the_error
  end

  test "Underlying source pull: throwing method (second pull)" do
    the_error = %RuntimeError{message: "a unique string"}

    counter = :counters.new(1, [])

    rs =
      ReadableStream.new(%{
        pull: fn c ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) == 1 do
            ReadableStreamDefaultController.enqueue(c, "a")
          else
            raise the_error
          end
        end
      })

    reader = ReadableStream.get_reader(rs)

    read = ReadableStreamDefaultReader.read(reader)
    closed = ReadableStreamDefaultReader.closed(reader)

    assert await(read) == %{value: "a", done: false}, "the chunk read should be correct"
    assert catch_exit(await(closed)) == the_error
  end

  test "Underlying source cancel: throwing method" do
    the_error = %RuntimeError{message: "a unique string"}
    rs = ReadableStream.new(%{cancel: fn _reason -> raise the_error end})

    assert catch_exit(await(ReadableStream.cancel(rs))) == the_error
  end

  test "Underlying source: calling enqueue on an empty canceled stream should throw" do
    parent = self()
    rs = ReadableStream.new(%{start: fn c -> send(parent, {:controller, c}) end})
    assert_received {:controller, controller}

    ReadableStream.cancel(rs)

    assert_raise TypeError,
                 fn -> ReadableStreamDefaultController.enqueue(controller, "a") end

    await(ReadableStreamDefaultReader.closed(ReadableStream.get_reader(rs)))
  end

  test "Underlying source: calling enqueue on a non-empty canceled stream should throw" do
    parent = self()

    rs =
      ReadableStream.new(%{
        start: fn c ->
          ReadableStreamDefaultController.enqueue(c, "a")
          ReadableStreamDefaultController.enqueue(c, "b")
          send(parent, {:controller, c})
        end
      })

    assert_received {:controller, controller}

    ReadableStream.cancel(rs)

    assert_raise TypeError,
                 fn -> ReadableStreamDefaultController.enqueue(controller, "c") end

    await(ReadableStreamDefaultReader.closed(ReadableStream.get_reader(rs)))
  end

  test "Underlying source: calling enqueue on a closed stream should throw" do
    rs =
      ReadableStream.new(%{
        start: fn c ->
          ReadableStreamDefaultController.close(c)

          assert_raise TypeError,
                       fn -> ReadableStreamDefaultController.enqueue(c, "a") end
        end
      })

    await(ReadableStreamDefaultReader.closed(ReadableStream.get_reader(rs)))
  end

  test "Underlying source: calling enqueue on an errored stream should throw" do
    the_error = %RuntimeError{message: "boo"}

    rs =
      ReadableStream.new(%{
        start: fn c ->
          ReadableStreamDefaultController.error(c, the_error)

          assert_raise TypeError,
                       fn -> ReadableStreamDefaultController.enqueue(c, "a") end
        end
      })

    closed = ReadableStreamDefaultReader.closed(ReadableStream.get_reader(rs))
    assert catch_exit(await(closed)) == the_error
  end

  test "Underlying source: calling close twice on an empty stream should throw the second time" do
    rs =
      ReadableStream.new(%{
        start: fn c ->
          ReadableStreamDefaultController.close(c)

          assert_raise TypeError,
                       fn -> ReadableStreamDefaultController.close(c) end
        end
      })

    await(ReadableStreamDefaultReader.closed(ReadableStream.get_reader(rs)))
  end

  test "Underlying source: calling close twice on a non-empty stream should throw the second time" do
    parent = self()

    reader =
      ReadableStream.new(%{
        start: fn c ->
          ReadableStreamDefaultController.enqueue(c, "a")
          ReadableStreamDefaultController.close(c)

          assert_raise TypeError,
                       fn -> ReadableStreamDefaultController.close(c) end

          send(parent, :start_called)
        end
      })
      |> ReadableStream.get_reader()

    read = ReadableStreamDefaultReader.read(reader)
    closed = ReadableStreamDefaultReader.closed(reader)

    # In JS, the reaction of `read` sets the flag `readCalled`, and the
    # reaction of `closed` runs after it and examines the flag. The port
    # awaits `read` before `closed`, in the same sequence. Thus the flag
    # `readCalled` is not necessary.
    assert await(read) == %{value: "a", done: false}, "read() should read the enqueued chunk"

    await(closed)
    assert_received :start_called
  end

  test "Underlying source: calling close on an empty canceled stream should throw" do
    parent = self()

    rs =
      ReadableStream.new(%{
        start: fn c ->
          send(parent, {:controller, c})
          send(parent, :start_called)
        end
      })

    assert_received {:controller, controller}

    ReadableStream.cancel(rs)

    assert_raise TypeError,
                 fn -> ReadableStreamDefaultController.close(controller) end

    await(ReadableStreamDefaultReader.closed(ReadableStream.get_reader(rs)))
    assert_received :start_called
  end

  test "Underlying source: calling close on a non-empty canceled stream should throw" do
    parent = self()

    rs =
      ReadableStream.new(%{
        start: fn c ->
          send(parent, {:controller, c})
          ReadableStreamDefaultController.enqueue(c, "a")
          send(parent, :start_called)
        end
      })

    assert_received {:controller, controller}

    ReadableStream.cancel(rs)

    assert_raise TypeError,
                 fn -> ReadableStreamDefaultController.close(controller) end

    await(ReadableStreamDefaultReader.closed(ReadableStream.get_reader(rs)))
    assert_received :start_called
  end

  test "Underlying source: calling close after error should throw" do
    parent = self()
    the_error = %RuntimeError{message: "boo"}

    rs =
      ReadableStream.new(%{
        start: fn c ->
          ReadableStreamDefaultController.error(c, the_error)

          assert_raise TypeError,
                       fn -> ReadableStreamDefaultController.close(c) end

          send(parent, :start_called)
        end
      })

    closed = ReadableStreamDefaultReader.closed(ReadableStream.get_reader(rs))

    e = catch_exit(await(closed))
    assert_received :start_called
    assert e == the_error, "closed should reject with the error"
  end

  test "Underlying source: calling error twice should not throw" do
    parent = self()
    the_error = %RuntimeError{message: "boo"}

    rs =
      ReadableStream.new(%{
        start: fn c ->
          ReadableStreamDefaultController.error(c, the_error)
          ReadableStreamDefaultController.error(c, nil)
          send(parent, :start_called)
        end
      })

    closed = ReadableStreamDefaultReader.closed(ReadableStream.get_reader(rs))

    e = catch_exit(await(closed))
    assert_received :start_called
    assert e == the_error, "closed should reject with the error"
  end

  test "Underlying source: calling error after close should not throw" do
    parent = self()

    rs =
      ReadableStream.new(%{
        start: fn c ->
          ReadableStreamDefaultController.close(c)
          ReadableStreamDefaultController.error(c, nil)
          send(parent, :start_called)
        end
      })

    await(ReadableStreamDefaultReader.closed(ReadableStream.get_reader(rs)))
    assert_received :start_called
  end

  test "Underlying source: calling error and returning a rejected promise from start should cause the stream to error with the first error" do
    parent = self()
    first_error = %RuntimeError{message: "1"}
    second_error = %RuntimeError{message: "2"}

    rs =
      ReadableStream.new(%{
        start: fn c ->
          ReadableStreamDefaultController.error(c, first_error)
          send(parent, :start_called)
          Promise.reject(second_error)
        end
      })

    closed = ReadableStreamDefaultReader.closed(ReadableStream.get_reader(rs))

    e = catch_exit(await(closed))
    assert_received :start_called
    assert e == first_error, "closed should reject with the first error"
  end

  test "Underlying source: calling error and returning a rejected promise from pull should cause the stream to error with the first error" do
    parent = self()
    first_error = %RuntimeError{message: "1"}
    second_error = %RuntimeError{message: "2"}

    rs =
      ReadableStream.new(%{
        pull: fn c ->
          ReadableStreamDefaultController.error(c, first_error)
          send(parent, :start_called)
          Promise.reject(second_error)
        end
      })

    closed = ReadableStreamDefaultReader.closed(ReadableStream.get_reader(rs))

    e = catch_exit(await(closed))
    # The function `pull` runs in a different process. Thus the message can
    # come after the rejection of `closed`.
    #
    # Note: when the stream goes to the errored state, the library stops the
    # process of `pull`. Thus the code that comes after the call of `error`
    # in `pull` can fail to run. The Standard runs all of the function. This
    # test passes because the message is sent immediately after `error`.
    assert_receive :start_called
    assert e == first_error, "closed should reject with the first error"
  end

  test "read should not error if it dequeues and pull() throws" do
    parent = self()
    error1 = %{name: "error1"}

    pull_should_throw = :atomics.new(1, [])

    rs =
      ReadableStream.new(
        %{
          pull: fn controller ->
            if :atomics.get(pull_should_throw, 1) == 1 do
              throw(error1)
            end

            ReadableStreamDefaultController.enqueue(controller, 0)
            send(parent, :pulled)
          end
        },
        Web.CountQueuingStrategy.new(high_water_mark: 1)
      )

    reader = ReadableStream.get_reader(rs)

    # In JS, the first pull runs before the callback of
    # `Promise.resolve().then()`. The message `:pulled` gives the same point.
    assert_receive :pulled
    :atomics.put(pull_should_throw, 1, 1)

    read = ReadableStreamDefaultReader.read(reader)
    closed = ReadableStreamDefaultReader.closed(reader)

    assert {:fulfilled, _result} = Promise.wait(read)
    assert catch_exit(await(closed)) == error1, ".closed promise should reject"
  end
end
