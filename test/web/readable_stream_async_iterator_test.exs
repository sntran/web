defmodule Web.ReadableStreamAsyncIteratorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.ReadableStream
  alias Web.ReadableStreamAsyncIterator, as: Iterator
  alias Web.ReadableStreamDefaultController, as: Controller
  alias Web.ReadableStreamDefaultReader, as: Reader
  alias Web.TypeError

  defp next(iterator), do: await(Iterator.next(iterator))

  defp source(chunks, extra \\ %{}) do
    Map.merge(
      %{
        start: fn controller ->
          Enum.each(chunks, &Controller.enqueue(controller, &1))
          Controller.close(controller)
        end
      },
      extra
    )
  end

  property "gives the chunks of the stream in their sequence, and then the end" do
    check all(chunks <- list_of(term(), max_length: 10)) do
      iterator = chunks |> source() |> ReadableStream.new() |> ReadableStream.values()

      results = Enum.map(chunks, fn _chunk -> next(iterator) end)
      assert results == Enum.map(chunks, &%{value: &1, done: false})
      assert next(iterator) == %{value: nil, done: true}
    end
  end

  test "has the lock of the stream until the end" do
    stream = ReadableStream.new(source(["a"]))
    iterator = ReadableStream.values(stream)
    assert ReadableStream.locked?(stream)
    assert_raise TypeError, fn -> ReadableStream.values(stream) end

    assert next(iterator) == %{value: "a", done: false}
    assert ReadableStream.locked?(stream)
    assert next(iterator) == %{value: nil, done: true}
    refute ReadableStream.locked?(stream)

    # The iterator is finished.
    assert next(iterator) == %{value: nil, done: true}
  end

  test "rejects with the error of the stream, and releases the lock" do
    stream = ReadableStream.new(%{pull: fn controller -> Controller.error(controller, :boom) end})
    iterator = ReadableStream.values(stream)

    assert catch_exit(next(iterator)) == :boom
    refute ReadableStream.locked?(stream)
    assert catch_exit(next(iterator)) == :boom
  end

  test "return cancels the stream with the value, and releases the lock" do
    test = self()
    stream = ReadableStream.new(source(["a", "b"], %{cancel: &send(test, {:cancel, &1})}))
    iterator = ReadableStream.values(stream)

    assert next(iterator) == %{value: "a", done: false}
    assert await(Iterator.return(iterator, :stop)) == %{value: :stop, done: true}
    assert_received {:cancel, :stop}
    refute ReadableStream.locked?(stream)
    assert next(iterator) == %{value: nil, done: true}
    assert await(Iterator.return(iterator)) == %{value: nil, done: true}
  end

  test "return rejects with the reason of a cancel that fails" do
    stream = ReadableStream.new(%{cancel: fn _reason -> throw(:no_cancel) end})
    iterator = ReadableStream.values(stream)

    assert catch_exit(await(Iterator.return(iterator, :stop))) == :no_cancel
    refute ReadableStream.locked?(stream)
  end

  test "return of an errored stream rejects with the error" do
    stream =
      ReadableStream.new(%{start: fn controller -> Controller.error(controller, :boom) end})

    iterator = ReadableStream.values(stream)

    assert catch_exit(await(Iterator.return(iterator, :stop))) == :boom
  end

  test "with prevent_cancel, return releases the lock and does not cancel" do
    test = self()
    stream = ReadableStream.new(source(["a", "b"], %{cancel: &send(test, {:cancel, &1})}))
    iterator = ReadableStream.values(stream, prevent_cancel: true)

    assert next(iterator) == %{value: "a", done: false}
    assert await(Iterator.return(iterator, :stop)) == %{value: :stop, done: true}
    refute_received {:cancel, _reason}

    reader = ReadableStream.get_reader(stream)
    assert await(Reader.read(reader)) == %{value: "b", done: false}
  end

  test "of a stream that stops is finished" do
    stream = ReadableStream.new()
    iterator = ReadableStream.values(stream)
    Web.Stream.stop(stream.controller_pid)

    assert next(iterator) == %{value: nil, done: true}
  end
end
