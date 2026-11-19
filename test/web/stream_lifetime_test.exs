defmodule Web.StreamLifetimeTest do
  # These tests set the linger time for the application and count the
  # processes of the VM. Thus they cannot run at the same time as other tests.
  use ExUnit.Case, async: false

  use Web

  @linger 100
  @count 200
  @tolerance 20

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

  defp refute_down(pid, time) do
    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, time
    Process.demonitor(ref, [:flush])
  end

  # Runs `fun` in a process that stops immediately, and returns its result.
  defp in_short_process(fun) do
    parent = self()
    pid = spawn(fn -> send(parent, {:result, self(), fun.()}) end)
    assert_receive {:result, ^pid, result}
    assert_down(pid)
    result
  end

  defp process_count, do: :erlang.system_info(:process_count)

  defp settle(baseline, attempts \\ 150) do
    difference = process_count() - baseline

    if difference <= @tolerance or attempts == 0 do
      difference
    else
      Process.sleep(20)
      settle(baseline, attempts - 1)
    end
  end

  describe "a readable stream" do
    test "stops after the linger time when it is read to the end" do
      stream = ReadableStream.from(["a", "b"])
      assert Enum.to_list(stream) == ["a", "b"]

      assert Process.alive?(stream.controller_pid)
      assert_down(stream.controller_pid)
    end

    test "stays while its owner is alive and its chunks are not read" do
      stream = ReadableStream.from("hello")
      refute_down(stream.controller_pid, 4 * @linger)
      assert Enum.join(stream) == "hello"
    end

    test "gives safe results after it stopped" do
      stream = ReadableStream.from(["a"])
      assert Enum.to_list(stream) == ["a"]
      assert_down(stream.controller_pid)

      refute ReadableStream.locked?(stream)
      assert ReadableStream.disturbed?(stream)
      assert await(ReadableStream.cancel(stream)) == :ok
      assert ReadableStream.get_desired_size(stream.controller_pid) == nil
      assert ReadableStream.release_lock(stream.controller_pid) == :ok

      assert_raise TypeError, ~r/The stream is not available/, fn ->
        ReadableStream.get_reader(stream)
      end

      assert_raise TypeError, ~r/The stream is not available/, fn ->
        ReadableStream.get_reader(stream, mode: "byob")
      end

      assert_raise TypeError, ~r/The stream is not available/, fn ->
        Enum.to_list(stream)
      end
    end

    test "rejects a second read of a body after it stopped" do
      response = Response.new(body: "hello")
      assert await(Response.text(response)) == "hello"
      assert_down(response.body.controller_pid)

      assert %TypeError{message: "body already used"} =
               catch_exit(await(Response.text(response)))

      assert %TypeError{message: "body already used"} =
               catch_exit(await(Response.array_buffer(response)))
    end

    test "cancels and stops when the enumeration halts" do
      parent = self()

      stream =
        ReadableStream.new(%{
          pull: fn controller -> ReadableStreamDefaultController.enqueue(controller, "x") end,
          cancel: fn reason -> send(parent, {:cancelled, reason}) end
        })

      assert Enum.take(stream, 2) == ["x", "x"]
      assert_receive {:cancelled, :halted}
      assert_down(stream.controller_pid)
    end

    test "stops the enumerable of from/1 when the enumeration halts" do
      parent = self()

      enumerable =
        Stream.resource(
          fn -> 0 end,
          fn count -> {[count], count + 1} end,
          fn _count -> send(parent, :enumerable_closed) end
        )

      stream = ReadableStream.from(enumerable)

      assert Enum.take(stream, 3) == [0, 1, 2]
      assert_receive :enumerable_closed
      assert_down(stream.controller_pid)
    end

    test "cancels and stops when its owner stops and no process reads it" do
      parent = self()

      stream =
        in_short_process(fn ->
          ReadableStream.new(%{
            pull: fn controller -> ReadableStreamDefaultController.enqueue(controller, "x") end,
            cancel: fn reason -> send(parent, {:cancelled, reason}) end
          })
        end)

      assert_receive {:cancelled, {:owner_down, :normal}}, 2_000
      assert_down(stream.controller_pid)
    end

    test "continues when a different process reads it in the linger time" do
      response = in_short_process(fn -> Response.new(body: "handed over") end)
      assert await(Response.text(response)) == "handed over"
    end

    test "continues while a different process holds the reader lock" do
      parent = self()

      stream =
        in_short_process(fn ->
          ReadableStream.new(%{
            pull: fn controller -> ReadableStreamDefaultController.enqueue(controller, "x") end,
            cancel: fn reason -> send(parent, {:cancelled, reason}) end
          })
        end)

      reader_process =
        spawn(fn ->
          reader = ReadableStream.get_reader(stream)
          send(parent, {:read, await(ReadableStreamDefaultReader.read(reader))})
          Process.sleep(:infinity)
        end)

      assert_receive {:read, %{value: "x", done: false}}
      refute_down(stream.controller_pid, 4 * @linger)

      # The process that holds the lock stops, and no owner is alive.
      Process.exit(reader_process, :kill)
      assert_receive {:cancelled, {:owner_down, :normal}}, 2_000
      assert_down(stream.controller_pid)
    end

    test "gives the chunks that are not read to a reader after its owner stops" do
      stream = in_short_process(fn -> ReadableStream.from(["a", "b", "c"]) end)
      assert Enum.to_list(stream) == ["a", "b", "c"]
    end
  end

  describe "from/1" do
    test "accepts an enumerable that halts itself" do
      assert Enum.to_list(ReadableStream.from(Stream.take([1, 2, 3], 2))) == [1, 2]
      assert Enum.to_list(ReadableStream.from(Stream.take([1, 2, 3], 0))) == []
      assert Enum.to_list(ReadableStream.from(Stream.take_while([1, 2, 3], &(&1 < 3)))) == [1, 2]

      infinite = Stream.repeatedly(fn -> "x" end)
      assert Enum.to_list(ReadableStream.from(Stream.take(infinite, 3))) == ["x", "x", "x"]
    end

    test "accepts the chunks nil and :done" do
      assert Enum.to_list(ReadableStream.from([nil, :done, "a"])) == [nil, :done, "a"]
    end

    test "puts the stream in the errored state when the enumerable raises" do
      import ExUnit.CaptureLog

      enumerable =
        Stream.map([1, 2], fn
          1 -> 1
          2 -> raise "enumerable failure"
        end)

      stream = ReadableStream.from(enumerable)
      reader = ReadableStream.get_reader(stream)

      capture_log(fn ->
        assert await(ReadableStreamDefaultReader.read(reader)) == %{value: 1, done: false}

        assert %RuntimeError{message: "enumerable failure"} =
                 catch_exit(await(ReadableStreamDefaultReader.read(reader)))
      end)
    end
  end

  describe "from/1 with an enumerable that exits" do
    test "puts the stream in the errored state with the exit reason" do
      import ExUnit.CaptureLog

      stream = ReadableStream.from(Stream.map([1], fn _ -> exit(:enumerable_exit) end))
      reader = ReadableStream.get_reader(stream)

      capture_log(fn ->
        assert {:exit, :enumerable_exit} =
                 catch_exit(await(ReadableStreamDefaultReader.read(reader)))
      end)
    end
  end

  describe "a pipe" do
    test "rejects when the readable stream stopped" do
      source = ReadableStream.from(["a"])
      assert Enum.to_list(source) == ["a"]
      assert_down(source.controller_pid)

      sink = WritableStream.new()

      assert %TypeError{message: message} =
               catch_exit(
                 await(ReadableStream.pipe_to(source.controller_pid, sink.controller_pid))
               )

      assert message =~ "The stream is not available"
    end

    test "rejects when the writable stream stopped" do
      sink = WritableStream.new()
      assert await(WritableStream.close(sink)) == :ok
      assert_down(sink.controller_pid)

      source = ReadableStream.from(["a"])

      assert %TypeError{message: message} =
               catch_exit(
                 await(ReadableStream.pipe_to(source.controller_pid, sink.controller_pid))
               )

      assert message =~ "The stream is not available"
    end
  end

  describe "a text decoder" do
    test "stops its state process when its owner stops" do
      decoder = in_short_process(fn -> TextDecoder.new() end)
      assert_down(decoder.state_pid)

      assert_raise TypeError, ~r/The TextDecoder is not available/, fn ->
        TextDecoder.decode(decoder, "a")
      end

      assert TextDecoder.dispose(decoder) == :ok
    end

    test "stops its state process when its stream is cancelled" do
      baseline = process_count()

      for _ <- 1..@count do
        stream = TextDecoderStream.new()
        assert await(ReadableStream.cancel(stream.readable, :not_necessary)) == :ok
      end

      assert settle(baseline) <= @tolerance
    end
  end

  describe "a writable stream" do
    test "stops after the linger time when it is closed, also with a writer lock" do
      stream = WritableStream.new(%{write: fn _chunk, _controller -> :ok end})
      writer = WritableStream.get_writer(stream)

      assert await(WritableStreamDefaultWriter.write(writer, "x")) == :ok
      assert await(WritableStreamDefaultWriter.close(writer)) == :ok
      assert_down(stream.controller_pid)
    end

    test "gives safe results after it stopped" do
      stream = WritableStream.new()
      writer = WritableStream.get_writer(stream)
      assert await(WritableStreamDefaultWriter.close(writer)) == :ok
      assert_down(stream.controller_pid)

      refute WritableStream.locked?(stream)
      refute WritableStream.backpressure?(stream)
      assert WritableStream.desired_size(stream) == nil
      assert WritableStreamDefaultWriter.desired_size(writer) == nil
      assert WritableStreamDefaultWriter.release_lock(writer) == :ok
      assert await(WritableStream.close(stream)) == :ok
      assert await(WritableStream.abort(stream, :late)) == :ok
      assert WritableStream.ready(stream.controller_pid) == {:error, :released}

      assert %TypeError{message: message} =
               catch_exit(await(WritableStreamDefaultWriter.write(writer, "late")))

      assert message =~ "The stream is not available"

      assert_raise TypeError, ~r/The stream is not available/, fn ->
        WritableStream.get_writer(stream)
      end
    end

    test "aborts and stops when its owner stops" do
      parent = self()

      stream =
        in_short_process(fn ->
          WritableStream.new(%{abort: fn reason -> send(parent, {:aborted, reason}) end})
        end)

      assert_receive {:aborted, {:owner_down, :normal}}, 2_000
      assert_down(stream.controller_pid)
    end

    test "stays while its owner is alive" do
      stream = WritableStream.new()
      refute_down(stream.controller_pid, 4 * @linger)
    end
  end

  describe "a callback of a stream" do
    test "makes promises and streams that the stream owns" do
      parent = self()

      stream =
        ReadableStream.new(%{
          start: fn controller ->
            send(parent, {:owner, Web.Promise.owner()})
            ReadableStreamDefaultController.close(controller)
          end
        })

      assert_receive {:owner, owner}
      assert owner == stream.controller_pid
    end
  end

  describe "a process that stays alive" do
    test "does not keep the streams that it read to the end" do
      baseline = process_count()

      for _ <- 1..@count do
        assert Enum.to_list(ReadableStream.from(["a", "b"])) == ["a", "b"]
      end

      assert settle(baseline) <= @tolerance
    end

    test "does not keep the response bodies that it read" do
      baseline = process_count()

      for _ <- 1..@count do
        assert await(Response.text(Response.new(body: "hello"))) == "hello"
      end

      assert settle(baseline) <= @tolerance
    end

    test "does not keep a pipeline that it read to the end" do
      baseline = process_count()

      for _ <- 1..@count do
        result =
          ["a", "b"]
          |> ReadableStream.from()
          |> ReadableStream.pipe_through(TextEncoderStream.new())
          |> ReadableStream.pipe_through(TextDecoderStream.new())
          |> Enum.join()

        assert result == "ab"
      end

      assert settle(baseline) <= @tolerance
    end

    test "does not keep the two branches of a clone that it read" do
      baseline = process_count()

      for _ <- 1..@count do
        {first, second} = Response.clone(Response.new(body: "hello"))
        assert await(Response.text(first)) == "hello"
        assert await(Response.text(second)) == "hello"
      end

      assert settle(baseline) <= @tolerance
    end

    test "does not keep a stream that it read in part" do
      baseline = process_count()

      for _ <- 1..@count do
        stream = ReadableStream.from(Stream.repeatedly(fn -> "x" end))
        assert Enum.take(stream, 2) == ["x", "x"]
      end

      assert settle(baseline) <= @tolerance
    end

    test "does not keep the writable streams that it closed" do
      baseline = process_count()

      for _ <- 1..@count do
        stream = WritableStream.new(%{write: fn _chunk, _controller -> :ok end})
        writer = WritableStream.get_writer(stream)
        assert await(WritableStreamDefaultWriter.write(writer, "x")) == :ok
        assert await(WritableStreamDefaultWriter.close(writer)) == :ok
      end

      assert settle(baseline) <= @tolerance
    end
  end

  describe "a process that stops" do
    test "does not leave the response bodies that it did not read" do
      baseline = process_count()

      for _ <- 1..@count do
        in_short_process(fn -> Response.new(body: "not read") end)
      end

      assert settle(baseline) <= @tolerance
    end

    test "does not leave the streams that it read in part" do
      baseline = process_count()

      for _ <- 1..@count do
        in_short_process(fn ->
          reader =
            ReadableStream.get_reader(ReadableStream.from(Stream.repeatedly(fn -> "x" end)))

          await(ReadableStreamDefaultReader.read(reader))
        end)
      end

      assert settle(baseline) <= @tolerance
    end
  end
end
