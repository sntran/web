defmodule Web.QueuingStrategyTest do
  # The queuing strategies of the streams, as the Streams Standard specifies
  # them: the high water mark, the size function of the user, and the total
  # size of a queue in double-precision arithmetic.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.ByteLengthQueuingStrategy
  alias Web.CountQueuingStrategy
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController, as: Controller
  alias Web.ReadableStreamDefaultReader, as: Reader
  alias Web.Test.StreamEngine
  alias Web.TransformStream
  alias Web.TransformStreamDefaultController, as: TransformController
  alias Web.WritableStream
  alias Web.WritableStreamDefaultController, as: WritableController
  alias Web.WritableStreamDefaultWriter, as: Writer

  # The largest integer that a double keeps with no change.
  @exact_limit 9_007_199_254_740_992

  defp rejection(promise), do: catch_exit(await(promise))

  # A readable stream and its controller. The test process keeps the
  # controller in its dictionary: a size function that runs in the test
  # process can use it.
  defp readable(opts) do
    test = self()
    stream = ReadableStream.new(%{start: fn c -> send(test, {:controller, c}) end}, opts)
    assert_receive {:controller, controller}
    Process.put(:controller, controller)
    {stream, controller}
  end

  # A writable stream whose sink holds each write until the test resolves
  # the promise `gate`.
  defp held_writable(strategy) do
    {gate, resolve, _reject} = Web.Promise.with_resolvers()
    stream = WritableStream.new(%{write: fn _chunk, _controller -> gate end}, strategy)
    writer = WritableStream.get_writer(stream)
    Process.put(:writer, writer)
    {stream, writer, resolve}
  end

  # Sends `message` to the test, and gives `size`.
  defp recorded(test, message, size) do
    send(test, message)
    size
  end

  # A value of the arithmetic of doubles: an integer result must be exact in
  # a double.
  defp assert_double(actual, expected) do
    assert is_float(actual) or abs(actual) <= @exact_limit
    assert actual == expected
  end

  describe "the strategy objects" do
    test "keep the high water mark with no check, as the Standard specifies" do
      for value <- [-1, 0.5, :infinity, :neg_infinity, :nan] do
        assert CountQueuingStrategy.new(high_water_mark: value).high_water_mark == value
        assert ByteLengthQueuingStrategy.new(high_water_mark: value).high_water_mark == value
      end
    end

    test "refuse an init that is not a dictionary QueuingStrategyInit" do
      for module <- [CountQueuingStrategy, ByteLengthQueuingStrategy] do
        for value <- ["1", :big] do
          assert_raise Web.TypeError, ~r/must be a number/, fn ->
            module.new(high_water_mark: value)
          end
        end

        # The member `highWaterMark` is required.
        for init <- [[], %{}, [size: 1], %{high_water_mark: nil}] do
          assert_raise Web.TypeError, ~r/needs the key :high_water_mark/, fn ->
            module.new(init)
          end
        end

        for init <- [4, nil, "init"] do
          assert_raise Web.TypeError, ~r/must be the dictionary QueuingStrategyInit/, fn ->
            module.new(init)
          end
        end

        # A map, also a strategy, is a dictionary.
        assert module.new(%{high_water_mark: 2}) == module.new(high_water_mark: 2)
        assert module.new(module.new(high_water_mark: 3)).high_water_mark == 3
      end
    end

    test "have the attribute size: the same function for each strategy" do
      count = CountQueuingStrategy.new(high_water_mark: 1)
      bytes = ByteLengthQueuingStrategy.new(high_water_mark: 1)

      assert count.size == CountQueuingStrategy.new(high_water_mark: 5).size
      assert bytes.size == ByteLengthQueuingStrategy.new(high_water_mark: 5).size
      assert count.size == %CountQueuingStrategy{}.size
      assert bytes.size == %ByteLengthQueuingStrategy{}.size

      assert count.size.(:any) == 1
      assert count.size.(nil) == 1
      assert bytes.size.("abc") == 3
      assert bytes.size.(%{byte_length: 7}) == 7
      assert bytes.size.(Web.ArrayBuffer.new(5)) == 5
      assert bytes.size.(Web.Uint8Array.from("ab")) == 2
      assert bytes.size.(:no_bytes) == nil
      assert_raise Web.TypeError, fn -> bytes.size.(nil) end
    end
  end

  describe "the high water mark of a stream" do
    test "can be infinity" do
      {_stream, controller} = readable(high_water_mark: :infinity)
      Controller.enqueue(controller, "a")
      assert Controller.desired_size(controller) == :infinity

      writable = WritableStream.new(%{}, high_water_mark: :infinity)
      assert StreamEngine.desired_size(writable) == :infinity

      transform = TransformStream.new(%{}, [], high_water_mark: :infinity)
      assert ReadableStream.get_desired_size(transform.readable.controller_pid) == :infinity
    end

    test "comes from a strategy object, or from a struct with the two fields" do
      {_stream, controller} = readable(CountQueuingStrategy.new(high_water_mark: 3))
      assert Controller.desired_size(controller) == 3

      {_stream, controller} = readable(ByteLengthQueuingStrategy.new(high_water_mark: 10))
      Controller.enqueue(controller, "abc")
      assert Controller.desired_size(controller) == 7

      writable = WritableStream.new(%{}, ByteLengthQueuingStrategy.new(high_water_mark: 10))
      writer = WritableStream.get_writer(writable)
      assert :ok = await(Writer.write(writer, "abc"))
      assert Writer.desired_size(writer) == 10

      # A struct of the user is a dictionary: a struct with no fields of a
      # strategy counts each chunk as 1, with the default limit.
      {_stream, controller} = readable(%URI{})
      assert Controller.desired_size(controller) == 1

      # The keys of a keyword list that are not members have no effect.
      {_stream, controller} = readable(strategy: CountQueuingStrategy.new(high_water_mark: 3))
      assert Controller.desired_size(controller) == 1
    end

    test "of a byte stream refuses the size function of a strategy object" do
      for strategy <- [
            CountQueuingStrategy.new(high_water_mark: 1),
            ByteLengthQueuingStrategy.new(high_water_mark: 1)
          ] do
        assert_raise Web.RangeError, ~r/size function/, fn ->
          ReadableStream.new(%{type: "bytes"}, strategy)
        end
      end

      assert %ReadableStream{} = ReadableStream.new(%{type: "bytes"}, %{high_water_mark: 4})
    end

    test "refuses a byte stream with a size function, and a size that is not a function" do
      assert_raise Web.RangeError, ~r/size function/, fn ->
        ReadableStream.new(%{type: "bytes"}, size: fn _chunk -> 1 end)
      end

      assert_raise Web.TypeError, ~r/must be a function/, fn ->
        ReadableStream.new(%{}, size: :not_a_function)
      end

      assert_raise Web.TypeError, ~r/must be a function/, fn ->
        WritableStream.new(%{}, size: 1)
      end

      for constructor <- [&ReadableStream.new/2, &WritableStream.new/2] do
        assert_raise Web.TypeError, ~r/Invalid queuing strategy/, fn ->
          constructor.(%{}, :not_a_strategy)
        end
      end
    end
  end

  describe "the size function of a readable stream" do
    test "runs in the process that enqueues, thus it can enqueue also" do
      size = fn chunk ->
        send(self(), {:size, chunk})
        if chunk == "a", do: Controller.enqueue(Process.get(:controller), "b")
        1
      end

      {stream, controller} = readable(size: size, high_water_mark: 5)
      Controller.enqueue(controller, "a")
      Controller.close(controller)

      # The enqueue in the size function completes first.
      assert Enum.to_list(stream) == ["b", "a"]
      assert_received {:size, "a"}
      assert_received {:size, "b"}
    end

    test "is not called for a chunk that a read that waits takes" do
      test = self()
      {stream, controller} = readable(size: fn _chunk -> recorded(test, :size, 1) end)
      reader = ReadableStream.get_reader(stream)
      read = Reader.read(reader)

      # The stream gets the read before the enqueue: `desired_size` is a call.
      _ = Controller.desired_size(controller)
      Controller.enqueue(controller, "a")
      assert await(read) == %{value: "a", done: false}
      refute_received :size
    end

    test "with a value that is not a valid size errors the stream, and enqueue raises" do
      for size <- [-1, :nan, :infinity, :neg_infinity, "1", nil] do
        {stream, controller} = readable(size: fn _chunk -> size end)

        error =
          assert_raise Web.RangeError, ~r/Invalid size/, fn ->
            Controller.enqueue(controller, :a)
          end

        reader = ReadableStream.get_reader(stream)
        assert rejection(Reader.read(reader)) == error
      end
    end

    test "that throws or raises errors the stream with that value" do
      {stream, controller} = readable(size: fn _chunk -> throw(:boom) end)
      assert catch_throw(Controller.enqueue(controller, :a)) == :boom
      assert rejection(Reader.read(ReadableStream.get_reader(stream))) == :boom

      {stream, controller} = readable(size: fn _chunk -> raise ArgumentError, "bad" end)
      assert_raise ArgumentError, "bad", fn -> Controller.enqueue(controller, :a) end
      assert %ArgumentError{} = rejection(Reader.read(ReadableStream.get_reader(stream)))
    end

    test "can error or close the stream: the chunk then has no effect" do
      size = fn _chunk ->
        Controller.error(Process.get(:controller), :first)
        throw(:second)
      end

      # The enqueue throws the error of the size, and the stream keeps its
      # first error.
      {stream, controller} = readable(size: size)
      assert catch_throw(Controller.enqueue(controller, :a)) == :second
      assert rejection(Reader.read(ReadableStream.get_reader(stream))) == :first

      size = fn _chunk ->
        Controller.close(Process.get(:controller))
        1
      end

      {stream, controller} = readable(size: size)
      assert :ok = Controller.enqueue(controller, :a)
      assert Enum.to_list(stream) == []

      size = fn _chunk ->
        Controller.close(Process.get(:controller))
        -1
      end

      {stream, controller} = readable(size: size)
      assert_raise Web.RangeError, fn -> Controller.enqueue(controller, :a) end
      assert Enum.to_list(stream) == []
    end

    test "adds the chunk at the end of the queue when a read waits for the next chunk" do
      size = fn _chunk ->
        send(self(), {:read, Reader.read(Process.get(:reader))})
        1
      end

      {stream, controller} = readable(size: size, high_water_mark: 0)
      Process.put(:reader, ReadableStream.get_reader(stream))
      Controller.enqueue(controller, "a")
      assert_received {:read, read}

      # The read that the size function made gets the next chunk, as in the
      # Standard. Its size is not called.
      Controller.enqueue(controller, "b")
      assert await(read) == %{value: "b", done: false}
      assert await(Reader.read(Process.get(:reader))) == %{value: "a", done: false}
    end

    test "that the stream does not answer: the error of the size is still raised" do
      size = fn chunk ->
        Web.Stream.stop(Process.get(:stream).controller_pid)
        chunk
      end

      {stream, controller} = readable(size: size)
      Process.put(:stream, stream)
      assert :ok = Controller.enqueue(controller, 1)

      {stream, controller} = readable(size: size)
      Process.put(:stream, stream)
      assert_raise Web.RangeError, fn -> Controller.enqueue(controller, -1) end
    end

    test "of a pull gives the error to the pull, which continues" do
      test = self()

      source = %{
        pull: fn controller ->
          try do
            Controller.enqueue(controller, :a)
          rescue
            error -> send(test, {:raised, error})
          end

          send(test, :continued)
        end
      }

      stream = ReadableStream.new(source, size: fn _chunk -> -1 end)
      assert_receive {:raised, %Web.RangeError{} = error}
      assert_receive :continued
      assert rejection(Reader.read(ReadableStream.get_reader(stream))) == error
    end
  end

  describe "the size of a strategy of the library" do
    test "that is not valid errors the stream, and enqueue raises" do
      {stream, controller} = readable(ByteLengthQueuingStrategy.new(high_water_mark: 10))
      assert_raise Web.RangeError, fn -> Controller.enqueue(controller, :no_bytes) end
      assert %Web.RangeError{} = rejection(Reader.read(ReadableStream.get_reader(stream)))

      {_stream, controller} = readable(ByteLengthQueuingStrategy.new(high_water_mark: 10))
      assert_raise Web.TypeError, fn -> Controller.enqueue(controller, nil) end
    end

    test "that is not valid errors a stream that gets its chunks from a process" do
      strategy = ByteLengthQueuingStrategy.new(high_water_mark: 4)
      {:ok, pid} = Web.Stream.start_link(ReadableStream, strategy: strategy, high_water_mark: 4)
      :ok = ReadableStream.enqueue(pid, :no_bytes)
      assert {:error, {:errored, %Web.RangeError{}}} = StreamEngine.read(pid)
    end
  end

  property "the desired size of a readable stream uses the arithmetic of doubles" do
    size =
      one_of([
        integer(0..4),
        constant(@exact_limit - 1),
        map(float(min: 0.0, max: 4.0), & &1),
        constant(1.0e-16),
        constant(2.0e-16)
      ])

    check all(
            sizes <- list_of(size, min_length: 1, max_length: 6),
            hwm <- one_of([integer(0..3), float(min: 0.0, max: 3.0)])
          ) do
      {stream, controller} = readable(high_water_mark: hwm, size: & &1)
      reader = ReadableStream.get_reader(stream)

      total =
        Enum.reduce(sizes, 0.0, fn size, total ->
          Controller.enqueue(controller, size)
          total = total + size
          assert_double(Controller.desired_size(controller), hwm - total)
          total
        end)

      # Each read removes the size of its chunk. A total below zero is zero.
      Enum.reduce(sizes, total, fn size, total ->
        assert await(Reader.read(reader)) == %{value: size, done: false}
        total = max(total - size, 0.0)
        assert_double(Controller.desired_size(controller), hwm - total)
        total
      end)
    end
  end

  describe "the size function of a writable stream" do
    test "runs in the process that writes, and gives the desired size" do
      test = self()
      size = fn chunk -> recorded(test, {:size, self()}, byte_size(chunk)) end
      {_stream, writer, resolve} = held_writable(high_water_mark: 10, size: size)

      first = Writer.write(writer, "abc")
      assert_received {:size, pid} when pid == test
      assert Writer.desired_size(writer) == 7

      second = Writer.write(writer, "de")
      assert Writer.desired_size(writer) == 5

      resolve.(:ok)
      assert :ok = await(first)
      assert :ok = await(second)
      assert Writer.desired_size(writer) == 10
    end

    test "runs in the stream for a write with no writer, as for a pipe" do
      test = self()
      stream = WritableStream.new(%{}, size: fn _chunk -> recorded(test, {:size, self()}, 1) end)
      assert %Web.WritableStreamDefaultWriter{} = WritableStream.get_writer(stream, :pipe)
      assert :ok = StreamEngine.write(stream.controller_pid, self(), "a")
      assert_received {:size, pid} when pid == stream.controller_pid
    end

    test "with a value that is not a valid size errors the stream, and the write rejects" do
      for size <- [-1, :nan, :infinity, "1"] do
        {_stream, writer, _resolve} = held_writable(size: fn _chunk -> size end)
        assert %Web.RangeError{} = error = rejection(Writer.write(writer, "a"))
        assert rejection(Writer.closed(writer)) == error
      end

      {_stream, writer, _resolve} = held_writable(size: fn _chunk -> throw(:boom) end)
      assert rejection(Writer.write(writer, "a")) == :boom
    end

    test "is not called after the stream is errored" do
      test = self()
      size = fn _chunk -> recorded(test, :size, 1) end
      start = fn controller -> send(test, {:controller, controller}) end
      stream = WritableStream.new(%{start: start}, size: size)
      assert_receive {:controller, controller}
      writer = WritableStream.get_writer(stream)

      # The error is a message: a call after it waits for its end.
      WritableController.error(controller, :stop)
      assert Writer.desired_size(writer) == nil
      assert rejection(Writer.write(writer, "a")) == :stop
      refute_received :size
    end

    # The start does not end, thus the error leaves the stream erroring.
    test "is not called after an error of the controller while the start runs" do
      test = self()
      size = fn _chunk -> recorded(test, :size, 1) end
      {start, _resolve, _reject} = Web.Promise.with_resolvers()

      begin = fn controller ->
        send(test, {:controller, controller})
        start
      end

      stream = WritableStream.new(%{start: begin}, size: size)
      assert_receive {:controller, controller}
      writer = WritableStream.get_writer(stream)

      WritableController.error(controller, :stop)
      assert Writer.desired_size(writer) == nil
      assert WritableStream.__get_slots__(stream.controller_pid).state == :erroring
      assert rejection(Writer.write(writer, "a")) == :stop
      refute_received :size
    end

    test "can close the stream: the write then rejects" do
      size = fn _chunk ->
        _ = Writer.close(Process.get(:writer))
        1
      end

      {_stream, writer, resolve} = held_writable(size: size)
      assert %Web.TypeError{} = rejection(Writer.write(writer, "a"))
      resolve.(:ok)
    end
  end

  describe "the strategies of a transform stream" do
    test "give each side its high water mark and its size function" do
      test = self()

      transform =
        TransformStream.new(
          %{},
          [high_water_mark: 4, size: &byte_size/1],
          %{
            high_water_mark: 6,
            size: fn chunk -> recorded(test, :size, 2 * byte_size(chunk)) end
          }
        )

      writer = WritableStream.get_writer(transform.writable)
      assert Writer.desired_size(writer) == 4
      assert :ok = await(Writer.write(writer, "ab"))
      assert_received :size
      assert ReadableStream.get_desired_size(transform.readable.controller_pid) == 2
    end

    test "make the controller throw the error of the stream for a size that is not valid" do
      test = self()
      start = fn controller -> send(test, {:controller, controller}) end

      # The size function errors the stream first: the controller throws
      # that error, not the RangeError.
      size = fn _chunk ->
        TransformController.error(Process.get(:controller), :first)
        -1
      end

      _transform = TransformStream.new(%{start: start}, [], size: size)
      assert_receive {:controller, controller}
      Process.put(:controller, controller)
      assert catch_throw(TransformController.enqueue(controller, "a")) == :first

      # With no error before, the controller raises the RangeError.
      _transform = TransformStream.new(%{start: start}, [], size: fn _ -> -1 end)
      assert_receive {:controller, controller}
      assert_raise Web.RangeError, fn -> TransformController.enqueue(controller, "a") end
    end
  end

  describe "a stream on a different node" do
    @describetag :cluster

    test "gets each write with no size from the writer" do
      {_peer, node} = Web.TestCluster.start_peer()

      {:ok, agent} =
        :erpc.call(node, Agent, :start, [WritableStream, :new, [%{}, [size: &byte_size/1]]])

      stream = :erpc.call(node, Agent, :get, [agent, Function, :identity, []])

      # The writer cannot read the dictionary of a process of a different
      # node: the stream calls the size function itself.
      assert Web.Stream.__writable_size__(stream.controller_pid) == nil
      writer = WritableStream.get_writer(stream)
      assert :ok = await(Writer.write(writer, "abc"))
    end
  end
end
