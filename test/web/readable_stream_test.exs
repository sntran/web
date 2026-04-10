defmodule Web.ReadableStreamTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.ReadableStreamDefaultReader
  alias Web.TypeError

  setup do
    {:ok, pid} = ReadableStream.start_link(high_water_mark: 2)
    stream = %ReadableStream{controller_pid: pid}
    %{stream: stream, controller_pid: pid}
  end

  describe "ReadableStream" do
    test "get_reader locked", %{stream: stream} do
      ReadableStream.get_reader(stream)
      assert_raise TypeError, ~r/already locked/, fn -> ReadableStream.get_reader(stream) end
    end

    test "Enumerable protocols methods", %{stream: stream} do
      # These 3 lines are the fallbacks in lib/web/readable_stream.ex
      assert {:error, _} = Enumerable.Web.ReadableStream.count(stream)
      assert {:error, _} = Enumerable.Web.ReadableStream.member?(stream, "a")
      assert {:error, _} = Enumerable.Web.ReadableStream.slice(stream)
    end

    test "Enumerable reduce variants", %{stream: stream, controller_pid: pid} do
      ReadableStream.enqueue(pid, "a")
      ReadableStream.close(pid)
      assert Enum.to_list(stream) == ["a"]
    end

    test "Enumerable exception cleanup", %{stream: stream, controller_pid: pid} do
      ReadableStream.enqueue(pid, "a")

      assert_raise RuntimeError, fn ->
        Enum.each(stream, fn _ -> raise "error" end)
      end

      Process.sleep(50)
      assert ReadableStream.__get_slots__(pid).reader_pid == nil
    end

    test "Enumerable halt", %{stream: stream, controller_pid: pid} do
      ReadableStream.enqueue(pid, "a")
      ReadableStream.enqueue(pid, "b")
      assert Enum.take(stream, 1) == ["a"]
      Process.sleep(50)
      assert ReadableStream.__get_slots__(pid).reader_pid == nil
    end

    test "Enumerable suspend", %{stream: stream, controller_pid: pid} do
      ReadableStream.enqueue(pid, "a")
      ReadableStream.enqueue(pid, "b")
      ReadableStream.close(pid)

      {:suspended, "a", next} =
        Enumerable.reduce(stream, {:cont, ""}, fn
          x, "" -> {:suspend, x}
          x, acc -> {:cont, acc <> x}
        end)

      assert {:done, "ab"} = next.({:cont, "a"})
    end

    test "Enumerable release_lock rescues", %{stream: stream, controller_pid: pid} do
      ReadableStream.enqueue(pid, "a")
      # Rescue in halt
      Enum.reduce_while(stream, 0, fn _x, _acc ->
        ReadableStream.release_lock(pid)
        {:halt, :stopped}
      end)

      # Rescue in done
      {:ok, p2} = ReadableStream.start_link()
      s2 = %ReadableStream{controller_pid: p2}
      ReadableStream.enqueue(p2, "a")
      ReadableStream.close(p2)

      Enum.each(s2, fn _ ->
        ReadableStream.error(p2, :force_unexpected_release)
      end)

      # Rescue in error/rescue
      {:ok, p3} = ReadableStream.start_link()
      s3 = %ReadableStream{controller_pid: p3}
      ReadableStream.enqueue(p3, "a")

      assert_raise RuntimeError, fn ->
        Enum.each(s3, fn _ ->
          ReadableStream.error(p3, :force_unexpected_release)
          raise "bomb"
        end)
      end
    end
  end

  describe "ReadableStream process" do
    test "various sources" do
      parent = self()

      # PID source
      {:ok, p1} = ReadableStream.start_link(source: parent)
      receive do: ({:pull, ^p1} -> :ok)
      assert :ok = Task.await(ReadableStream.cancel(p1, :r1).task, 1_000)
      receive do: ({:web_stream_cancel, ^p1, :r1} -> :ok)

      # Function source
      {:ok, p2} = ReadableStream.start_link(source: fn x -> send(parent, {:f, x}) end)
      receive do: ({:f, %Web.ReadableStreamDefaultController{pid: ^p2}} -> :ok)
      assert :ok = Task.await(ReadableStream.cancel(p2, :r2).task, 1_000)
      receive do: ({:f, :r2} -> :ok)

      # MFA source
      {:ok, p3} = ReadableStream.start_link(source: {Kernel, :send, [parent]})
      receive do: (%Web.ReadableStreamDefaultController{pid: ^p3} -> :ok)
      assert :ok = Task.await(ReadableStream.cancel(p3, :r3).task, 1_000)
      receive do: (:r3 -> :ok)

      # Nil source
      {:ok, p4} = ReadableStream.start_link(source: nil)
      ReadableStream.enqueue(p4, "a")
      assert :ok = Task.await(ReadableStream.cancel(p4, :r4).task, 1_000)
    end

    test "internal events and desired size", %{controller_pid: pid} do
      assert ReadableStream.get_desired_size(pid) == 2
      send(pid, {:internal, :maybe_pull})
      ReadableStream.close(pid)
      send(pid, {:internal, :maybe_pull})
      send(pid, {:internal, :flush_requests})
      ReadableStream.error(pid, :fail)
      send(pid, {:internal, :maybe_pull})
      send(pid, {:internal, :flush_requests})
    end

    test "DOWN monitoring" do
      {:ok, pid} = ReadableStream.start_link()
      stream = %ReadableStream{controller_pid: pid}
      parent = self()

      spawn(fn ->
        ReadableStream.get_reader(stream)
        send(parent, :locked)
      end)

      receive do: (:locked -> :ok)
      Process.sleep(100)
      assert ReadableStream.__get_slots__(pid).reader_pid == nil

      # Send a DOWN message with a ref that doesn't match
      send(pid, {:DOWN, make_ref(), :process, self(), :normal})
    end

    test "unknown generic", %{controller_pid: pid} do
      :gen_statem.cast(pid, :unknown)
      send(pid, :unknown)

      ReadableStream.close(pid)
      send(pid, :unknown)
    end

    test "unlocked actions", %{controller_pid: pid} do
      assert {:error, :not_locked_by_reader} = ReadableStream.read(pid)
      assert {:error, :not_locked_by_reader} = ReadableStream.release_lock(pid)
    end

    test "disturbed?/1, locked?/1, and read_all/1 helpers" do
      stream =
        ReadableStream.new(%{
          start: fn controller ->
            Web.ReadableStreamDefaultController.enqueue(controller, "he")
            Web.ReadableStreamDefaultController.enqueue(controller, "llo")
            Web.ReadableStreamDefaultController.close(controller)
          end
        })

      assert ReadableStream.disturbed?(stream) == false
      assert ReadableStream.locked?(stream) == false
      reader = ReadableStream.get_reader(stream)
      assert ReadableStream.locked?(stream) == true
      assert Web.ReadableStreamDefaultReader.read(reader) == "he"
      assert ReadableStream.disturbed?(stream) == true
      assert :ok = Web.ReadableStreamDefaultReader.release_lock(reader)

      stream =
        ReadableStream.new(%{
          start: fn controller ->
            Web.ReadableStreamDefaultController.enqueue(controller, "hello")
            Web.ReadableStreamDefaultController.close(controller)
          end
        })

      assert "hello" = Enum.join(stream, "")
      assert ReadableStream.disturbed?(stream) == true
    end

    test "from/1 normalizes enumerables using pull" do
      stream = ReadableStream.from(["a", "b", "c"])
      assert "abc" = Enum.join(stream, "")
    end

    test "from/1 normalizes URLSearchParams, Blob, ArrayBuffer, and Uint8Array" do
      params = Web.URLSearchParams.new(%{"a" => "1", "b" => "2"})
      assert "a=1&b=2" = params |> ReadableStream.from() |> Enum.join("")

      blob = Web.Blob.new(["he", "ll", "o"])
      assert "hello" = blob |> ReadableStream.from() |> Enum.join("")

      buffer = Web.ArrayBuffer.new("hello")
      assert "hello" = buffer |> ReadableStream.from() |> Enum.join("")

      bytes = Web.Uint8Array.new(Web.ArrayBuffer.new("hello"), 1, 3)
      assert "ell" = bytes |> ReadableStream.from() |> Enum.join("")

      nested_blob = Web.Blob.new(["a", Web.Blob.new(["b", "c"]), "d"])
      assert "abcd" = nested_blob |> ReadableStream.from() |> Enum.join("")
    end

    test "from/1 streams blob parts lazily across multiple pull cycles" do
      parts = Enum.map(1..1_000, &Integer.to_string/1)
      blob = Web.Blob.new(parts)
      stream = ReadableStream.from(blob)
      reader = ReadableStream.get_reader(stream)

      assert :queue.len(ReadableStream.__get_slots__(stream.controller_pid).queue) <= 1
      assert ReadableStreamDefaultReader.read(reader) == "1"
      assert ReadableStreamDefaultReader.read(reader) == "2"

      remaining =
        3..1_000
        |> Enum.map(fn expected ->
          assert ReadableStreamDefaultReader.read(reader) == Integer.to_string(expected)
        end)

      assert length(remaining) == 998
      assert ReadableStreamDefaultReader.read(reader) == :done
      assert :ok = ReadableStreamDefaultReader.release_lock(reader)
    end

    test "from/1 traverses nested blobs lazily without preloading controller queue" do
      chunk_a = :binary.copy("a", 64_000)
      chunk_b = :binary.copy("b", 64_000)
      chunk_c = :binary.copy("c", 64_000)

      blob =
        Web.Blob.new([
          Web.Blob.new([
            Web.Blob.new([chunk_a]),
            Web.Blob.new([chunk_b])
          ]),
          Web.Blob.new([chunk_c])
        ])

      stream = ReadableStream.from(blob)
      reader = ReadableStream.get_reader(stream)

      assert :queue.len(ReadableStream.__get_slots__(stream.controller_pid).queue) <= 1
      assert ReadableStreamDefaultReader.read(reader) == chunk_a
      assert :queue.len(ReadableStream.__get_slots__(stream.controller_pid).queue) <= 1
      assert ReadableStreamDefaultReader.read(reader) == chunk_b
      assert :queue.len(ReadableStream.__get_slots__(stream.controller_pid).queue) <= 1
      assert ReadableStreamDefaultReader.read(reader) == chunk_c
      assert ReadableStreamDefaultReader.read(reader) == :done
      assert :ok = ReadableStreamDefaultReader.release_lock(reader)
    end

    test "from/1 normalizes Stream structs and rejects unsupported values" do
      stream_struct = Stream.map(["a"], & &1)

      assert %ReadableStream{} = ReadableStream.from(stream_struct)
      assert "a" = stream_struct |> ReadableStream.from() |> Enum.join("")
      assert "" = [] |> ReadableStream.from() |> Enum.join("")

      assert %ReadableStream{} =
               ReadableStream.from(fn acc, fun -> Enumerable.List.reduce(["a"], acc, fun) end)

      assert_raise ArgumentError, ~r/cannot normalize body/, fn -> ReadableStream.from(123) end
    end

    test "from/1 wraps enumerable functions in a readable stream with tee support" do
      enumerable = fn acc, fun -> Enumerable.List.reduce(["a", "b"], acc, fun) end
      stream = ReadableStream.from(enumerable)

      assert ReadableStream.disturbed?(stream) == false

      [left, right] = ReadableStream.tee(stream)

      left_task = Task.async(fn -> Enum.join(left, "") end)
      right_task = Task.async(fn -> Enum.join(right, "") end)

      assert "ab" = Task.await(left_task, 5_000)
      assert "ab" = Task.await(right_task, 5_000)
    end

    test "from/1 enumerable cancellation and nil-source cancel paths do not crash" do
      stream = ReadableStream.from(1..10)
      assert :ok = Task.await(ReadableStream.cancel(stream.controller_pid, :stop_now).task, 1_000)

      {:ok, nil_pid} = ReadableStream.start_link(source: nil)
      assert :ok = Task.await(ReadableStream.cancel(nil_pid, :noop).task, 1_000)
      assert ReadableStream.__get_slots__(nil_pid).state == :closed
    end

    test "from/1 blob cancellation stops the lazy parts queue" do
      stream = ReadableStream.from(Web.Blob.new(["a", "b", "c"]))

      assert :ok = Task.await(ReadableStream.cancel(stream.controller_pid, :stop_now).task, 1_000)

      assert ReadableStream.__get_slots__(stream.controller_pid).state == :closed
    end

    test "error callback is callable" do
      callback_state = %{source: %{}, pid: self(), started: false}
      assert {:ok, ^callback_state} = ReadableStream.error(:boom, callback_state)
    end

    test "default controller error helper transitions stream to errored" do
      stream = ReadableStream.new()
      controller = %ReadableStreamDefaultController{pid: stream.controller_pid}

      ReadableStreamDefaultController.error(controller, :controller_boom)

      assert ReadableStream.__get_slots__(stream.controller_pid).state == :errored
    end

    test "tee/1 raises when called on a locked struct stream" do
      stream = ReadableStream.new()
      _reader = ReadableStream.get_reader(stream)

      assert_raise TypeError, ~r/already locked/, fn ->
        ReadableStream.tee(stream)
      end
    end

    test "tee/1 propagates errored state to its branches" do
      {:ok, pid} = ReadableStream.start_link()
      stream = %ReadableStream{controller_pid: pid}
      ReadableStream.error(pid, :boom)

      [left, right] = ReadableStream.tee(stream)

      assert_raise TypeError, "The stream is errored.", fn -> Enum.to_list(left) end
      assert_raise TypeError, "The stream is errored.", fn -> Enum.to_list(right) end
    end

    test "tee/1 marks the source as disturbed" do
      stream = ReadableStream.from("hello")
      assert ReadableStream.disturbed?(stream) == false

      _branches = ReadableStream.tee(stream)
      Process.sleep(50)

      assert ReadableStream.disturbed?(stream) == true
    end

    test "pull tasks cover normal and errored completion paths" do
      parent = self()

      {:ok, ok_pid} =
        ReadableStream.start_link(
          source: %{
            pull: fn _controller ->
              send(parent, :pull_completed)
              :ok
            end
          }
        )

      send(ok_pid, {:internal, :maybe_pull})
      assert_receive :pull_completed
      wait_for_stream_state(ok_pid, :readable)

      {:ok, error_pid} =
        ReadableStream.start_link(
          source: %{
            pull: fn _controller ->
              raise "pull failed"
            end
          }
        )

      send(error_pid, {:internal, :maybe_pull})
      wait_for_stream_state(error_pid, :errored)
    end

    test "start callbacks that throw transition the stream to errored" do
      {:ok, pid} =
        ReadableStream.start_link(
          source: %{
            start: fn _controller ->
              throw(:start_thrown)
            end
          }
        )

      Process.sleep(50)
      assert ReadableStream.__get_slots__(pid).state == :errored
    end

    test "task down paths handle normal and abnormal exits" do
      sleeper = fn _controller -> Process.sleep(5_000) end

      {:ok, normal_pid} = ReadableStream.start_link(source: %{pull: sleeper})
      send(normal_pid, {:internal, :maybe_pull})
      Process.sleep(50)
      normal_ref = ReadableStream.__get_slots__(normal_pid).task_ref
      send(normal_pid, {:DOWN, normal_ref, :process, self(), :normal})
      Process.sleep(50)
      assert ReadableStream.__get_slots__(normal_pid).state == :readable

      {:ok, abnormal_pid} = ReadableStream.start_link(source: %{pull: sleeper})
      send(abnormal_pid, {:internal, :maybe_pull})
      Process.sleep(50)
      abnormal_ref = ReadableStream.__get_slots__(abnormal_pid).task_ref
      send(abnormal_pid, {:DOWN, abnormal_ref, :process, self(), :kaboom})
      Process.sleep(50)
      assert ReadableStream.__get_slots__(abnormal_pid).state == :errored
    end

    test "fulfillment", %{controller_pid: pid} do
      parent = self()

      spawn_link(fn ->
        ReadableStream.get_reader(pid)
        res = ReadableStream.read(pid)
        send(parent, {:res, res})
      end)

      Process.sleep(50)
      ReadableStream.enqueue(pid, "v")
      receive do: ({:res, {:ok, "v"}} -> :ok)
    end

    test "edge cases" do
      # maybe_pull when queue full
      {:ok, p1} = ReadableStream.start_link(high_water_mark: 1)
      ReadableStream.enqueue(p1, "a")
      send(p1, {:internal, :maybe_pull})

      # flush_requests when queue NOT empty
      {:ok, p2} = ReadableStream.start_link()
      ReadableStream.enqueue(p2, "a")
      # This sends flush_requests, but queue not empty
      ReadableStream.close(p2)

      # force_unknown_error
      assert {:error, :unexpected} = ReadableStream.force_unknown_error(p1)

      # disturbed and desired size
      {:ok, p3} = ReadableStream.start_link(high_water_mark: 5)
      assert ReadableStream.__get_slots__(p3).disturbed == false
      assert ReadableStream.get_desired_size(p3) == 5
      ReadableStream.enqueue(p3, "a")
      assert ReadableStream.__get_slots__(p3).disturbed == false
      assert ReadableStream.get_desired_size(p3) == 4

      # HWM else branch coverage (read when queue still >= hwm)
      {:ok, p4} = ReadableStream.start_link(high_water_mark: 1)
      ReadableStream.enqueue(p4, "a")
      ReadableStream.enqueue(p4, "b")
      ReadableStream.get_reader(p4)
      # queue was 2, now 1. 1 < 1 is false.
      ReadableStream.read(p4)

      # One pending request on close
      {:ok, p5} = ReadableStream.start_link()
      parent = self()

      spawn_link(fn ->
        ReadableStream.get_reader(p5)
        send(parent, :locked)
        send(parent, {:r1, ReadableStream.read(p5)})
      end)

      receive do: (:locked -> :ok)
      Process.sleep(50)
      ReadableStream.close(p5)
      assert_receive {:r1, :done}

      # One pending request on error
      {:ok, p6} = ReadableStream.start_link()

      spawn_link(fn ->
        ReadableStream.get_reader(p6)
        send(parent, :locked_too)
        send(parent, {:r3, ReadableStream.read(p6)})
      end)

      receive do: (:locked_too -> :ok)
      Process.sleep(50)
      ReadableStream.error(p6, :boom)
      assert_receive {:r3, {:error, {:errored, :boom}}}
    end

    test "closed enqueue" do
      {:ok, pid} = ReadableStream.start_link()
      ReadableStream.close(pid)
      ReadableStream.enqueue(pid, "ignored")
      assert :queue.is_empty(ReadableStream.__get_slots__(pid).queue)
    end
  end

  describe "Reader" do
    test "errors", %{stream: stream, controller_pid: pid} do
      reader = ReadableStream.get_reader(stream)

      # Errored with reason
      ReadableStream.error(pid, :fail)
      # Sync to ensure reason is set
      ReadableStream.__get_slots__(pid)

      assert_raise TypeError, "The stream is errored.", fn ->
        ReadableStreamDefaultReader.read(reader)
      end

      # Errored WITHOUT reason (forced)
      {:ok, p2} = ReadableStream.start_link()
      s2 = %ReadableStream{controller_pid: p2}
      r2 = ReadableStream.get_reader(s2)
      ReadableStream.error(p2, :force_error_no_reason)
      ReadableStream.__get_slots__(p2)

      assert_raise TypeError, "The stream is errored.", fn ->
        ReadableStreamDefaultReader.read(r2)
      end

      # Unexpected read
      {:ok, p3} = ReadableStream.start_link()
      s3 = %ReadableStream{controller_pid: p3}
      r3 = ReadableStream.get_reader(s3)
      ReadableStream.error(p3, :force_unexpected_read)
      ReadableStream.__get_slots__(p3)
      assert_raise TypeError, ~r/Unknown error/, fn -> ReadableStreamDefaultReader.read(r3) end

      # Unexpected release
      {:ok, p4} = ReadableStream.start_link()
      s4 = %ReadableStream{controller_pid: p4}
      r4 = ReadableStream.get_reader(s4)
      ReadableStream.error(p4, :force_unexpected_release)
      ReadableStream.__get_slots__(p4)

      assert_raise TypeError, ~r/Unknown error/, fn ->
        ReadableStreamDefaultReader.release_lock(r4)
      end
    end

    test "PID mismatch", %{controller_pid: pid} do
      r = %ReadableStreamDefaultReader{controller_pid: pid}
      assert_raise TypeError, ~r/longer locked/, fn -> ReadableStreamDefaultReader.read(r) end

      assert_raise TypeError, ~r/longer locked/, fn ->
        ReadableStreamDefaultReader.release_lock(r)
      end
    end

    test "cancel", %{stream: stream} do
      reader = ReadableStream.get_reader(stream)
      assert :ok == ReadableStreamDefaultReader.cancel(reader)
    end

    test "The Finite Counter" do
      use Web
      {:ok, counter} = Agent.start_link(fn -> 1 end)

      stream =
        new(ReadableStream, %{
          pull: fn controller ->
            count = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

            if count <= 5 do
              ReadableStreamDefaultController.enqueue(controller, "#{count}")
            else
              ReadableStreamDefaultController.close(controller)
            end
          end
        })

      assert Enum.to_list(stream) == ["1", "2", "3", "4", "5"]
      Agent.stop(counter)
    end

    test "The Crash Test" do
      use Web

      stream =
        new(ReadableStream, %{
          pull: fn _controller ->
            raise "Ouch!"
          end
        })

      # The controller should catch the error and become errored
      # Enum.to_list calls get_reader then read.
      assert_raise TypeError, ~r/errored/, fn ->
        Enum.to_list(stream)
      end
    end

    test "The Tee Test" do
      use Web
      {:ok, pid} = ReadableStream.start_link(high_water_mark: 10)
      stream = %ReadableStream{controller_pid: pid}

      ReadableStream.enqueue(pid, 1)
      ReadableStream.enqueue(pid, 2)
      ReadableStream.enqueue(pid, 3)
      ReadableStream.close(pid)

      [branch_a, branch_b] = ReadableStream.tee(stream)

      left_task = Task.async(fn -> Enum.to_list(branch_a) end)
      right_task = Task.async(fn -> Enum.to_list(branch_b) end)

      assert [1, 2, 3] = Task.await(left_task, 5_000)
      assert [1, 2, 3] = Task.await(right_task, 5_000)
    end

    test "Tee Independence and Cancellation" do
      use Web
      parent = self()

      source = %{
        pull: fn controller ->
          send(parent, :pull_called)
          ReadableStreamDefaultController.enqueue(controller, "data")
        end,
        cancel: fn _reason ->
          send(parent, :original_cancelled)
        end
      }

      stream = new(ReadableStream, source)

      [branch_a, branch_b] = ReadableStream.tee(stream)

      # Cancel branch A
      reader_a = ReadableStream.get_reader(branch_a)
      ReadableStreamDefaultReader.cancel(reader_a)

      # Branch B should still be able to get data
      reader_b = ReadableStream.get_reader(branch_b)
      # Wait a bit for async start/pull to complete if needed
      Process.sleep(50)
      assert ReadableStreamDefaultReader.read(reader_b) == "data"
      assert_receive :pull_called

      # Cancel branch B
      ReadableStreamDefaultReader.cancel(reader_b)

      # Composed tee keeps source lifecycle independent of branch cancellation.
      refute_receive :original_cancelled
    end

    test "tee branch cancellation during flow keeps other branch and source active" do
      use Web
      parent = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      source = %{
        pull: fn controller ->
          index = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

          if index < 6 do
            send(parent, {:source_pull, index})
            ReadableStreamDefaultController.enqueue(controller, index)
          else
            ReadableStreamDefaultController.close(controller)
          end
        end
      }

      stream = new(ReadableStream, source)
      [left, right] = ReadableStream.tee(stream)

      left_reader = ReadableStream.get_reader(left)
      right_reader = ReadableStream.get_reader(right)

      assert ReadableStreamDefaultReader.read(left_reader) == 0
      assert ReadableStreamDefaultReader.read(right_reader) == 0

      assert :ok = ReadableStreamDefaultReader.cancel(left_reader)

      assert ReadableStreamDefaultReader.read(right_reader) == 1
      assert ReadableStreamDefaultReader.read(right_reader) == 2
      assert ReadableStreamDefaultReader.read(right_reader) == 3

      assert_receive {:source_pull, _}, 1_000
      assert_receive {:source_pull, _}, 1_000
      assert_receive {:source_pull, _}, 1_000

      assert Agent.get(counter, & &1) > 3
      assert :ok = ReadableStreamDefaultReader.release_lock(right_reader)
      Agent.stop(counter)
    end

    test "Tee locking", %{stream: stream} do
      ReadableStream.tee(stream)
      assert_raise TypeError, ~r/already locked/, fn -> ReadableStream.get_reader(stream) end
      assert_raise TypeError, ~r/already locked/, fn -> ReadableStream.tee(stream) end
    end

    test "Task Leak Test" do
      use Web
      parent = self()
      {:ok, counter} = Agent.start_link(fn -> nil end)

      stream =
        new(ReadableStream, %{
          pull: fn _controller ->
            task_pid = self()
            Agent.update(counter, fn _ -> task_pid end)
            send(parent, :pull_started)
            # Very slow pull
            Process.sleep(5000)
          end
        })

      # Trigger first pull
      ReadableStream.get_reader(stream)
      assert_receive :pull_started, 1000

      task_pid = Agent.get(counter, & &1)
      assert Process.alive?(task_pid)

      # Cancel stream
      assert :ok = Task.await(ReadableStream.cancel(stream.controller_pid, :abort).task, 1_000)

      # Task should be shut down
      Process.sleep(100)
      refute Process.alive?(task_pid)
      Agent.stop(counter)
    end

    test "Branch Survival" do
      use Web

      source = %{
        pull: fn controller ->
          ReadableStreamDefaultController.enqueue(controller, "data")
        end
      }

      [branch_a, branch_b] = ReadableStream.new(source) |> ReadableStream.tee()

      # Cancel A
      reader_a = ReadableStream.get_reader(branch_a)
      ReadableStreamDefaultReader.cancel(reader_a)

      # B should still work
      reader_b = ReadableStream.get_reader(branch_b)
      assert ReadableStreamDefaultReader.read(reader_b) == "data"
    end

    test "tee/1 allows 16 chunks to queue on the fast branch" do
      check all(
              chunk_count <- StreamData.integer(16..16),
              delay_ms <- StreamData.integer(50..80),
              max_runs: 10
            ) do
        {:ok, counter} = Agent.start_link(fn -> 1 end)

        try do
          source = %{
            pull: fn controller ->
              index = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

              if index <= chunk_count do
                ReadableStreamDefaultController.enqueue(controller, index)
              else
                ReadableStreamDefaultController.close(controller)
              end
            end
          }

          stream = ReadableStream.new(source)
          [fast_branch, slow_branch] = ReadableStream.tee(stream)

          expected = Enum.to_list(1..chunk_count)
          started_at = System.monotonic_time(:millisecond)

          fast_task = Task.async(fn -> Enum.to_list(fast_branch) end)

          slow_task =
            Task.async(fn -> Enum.each(slow_branch, fn _ -> Process.sleep(delay_ms) end) end)

          assert {:ok, ^expected} = Task.yield(fast_task, 10_000)
          fast_elapsed_ms = System.monotonic_time(:millisecond) - started_at
          assert :ok = Task.await(slow_task, 10_000)
          slow_elapsed_ms = System.monotonic_time(:millisecond) - started_at

          # The fast branch must complete long before the slow branch finishes.
          # With HWM=16, all chunks buffer into the fast branch so it completes
          # without waiting for the slow branch to process each chunk.
          # The slow branch takes ~chunk_count * delay_ms. The fast branch
          # should finish in a fraction of that time.
          assert fast_elapsed_ms < slow_elapsed_ms / 4
        after
          if Process.alive?(counter), do: Agent.stop(counter)
        end
      end
    end
  end

  describe "coverage gaps" do
    # --- pull callbacks that return a Promise (lines 64, 83) ---

    test "pull callback returning a Promise is awaited before continuing" do
      {:ok, pid} =
        ReadableStream.start_link(
          source: %{
            pull: fn ctrl ->
              # Returning a Promise from a pull callback exercises line 64
              Web.Promise.new(fn resolve, _reject ->
                Web.ReadableStreamDefaultController.enqueue(ctrl, "from_promise")
                Web.ReadableStreamDefaultController.close(ctrl)
                resolve.(:ok)
              end)
            end
          }
        )

      stream = %ReadableStream{controller_pid: pid}
      assert "from_promise" == Enum.join(stream, "")
    end

    test "function source pull returning a Promise is awaited (line 83)" do
      # Function source (not %{pull: fn}) that returns a Promise
      {:ok, pid} =
        ReadableStream.start_link(
          source: fn ctrl ->
            Web.Promise.new(fn resolve, _reject ->
              Web.ReadableStreamDefaultController.enqueue(ctrl, "fn_promise")
              Web.ReadableStreamDefaultController.close(ctrl)
              resolve.(:ok)
            end)
          end
        )

      stream = %ReadableStream{controller_pid: pid}
      assert "fn_promise" == Enum.join(stream, "")
    end

    # --- non-cancel terminate (line 101) ---

    test "terminate/2 is called with non-cancel reason on Web.Stream.terminate(:error)" do
      parent = self()

      {:ok, pid} =
        ReadableStream.start_link(
          source: %{
            cancel: fn reason -> send(parent, {:terminated, reason}) end
          }
        )

      Process.sleep(20)
      Web.Stream.terminate(pid, :error, :force_terminate)
      assert_receive {:terminated, {:error, :force_terminate}}, 500
    end

    # --- disturbed?/1, locked?/1 catch-all clauses ---

    test "disturbed?/1 returns false for nil, binary, list, and unknown types" do
      assert ReadableStream.disturbed?(nil) == false
      assert ReadableStream.disturbed?("binary") == false
      assert ReadableStream.disturbed?(["list"]) == false
      # Catch-all clause (line 371): non-stream, non-pid, non-binary, non-nil
      assert ReadableStream.disturbed?(:some_atom) == false
    end

    test "locked?/1 returns false for nil, binary, list, and unknown types" do
      assert ReadableStream.locked?(nil) == false
      assert ReadableStream.locked?("binary") == false
      assert ReadableStream.locked?(["list"]) == false
      # Catch-all clause (line 387)
      assert ReadableStream.locked?(:some_atom) == false
    end

    # --- cancel/2 struct overload (line 453) ---

    test "cancel/2 accepts a %ReadableStream{} struct directly" do
      {:ok, pid} = ReadableStream.start_link()
      stream = %ReadableStream{controller_pid: pid}
      result = ReadableStream.cancel(stream, :test_cancel)
      assert :ok == Task.await(result.task, 1_000)
    end

    # --- await_stream_state retry loop (lines 741-742) ---

    test "cancel/2 waits until stream is closed before resolving" do
      # Ensure the retry loop (Process.sleep + recursive call) is exercised
      # by providing a slow-to-close stream
      {:ok, pid} = ReadableStream.start_link()
      stream = %ReadableStream{controller_pid: pid}
      ReadableStream.enqueue(pid, "a")
      cancel_promise = ReadableStream.cancel(stream, :slow_cancel)
      assert :ok == Task.await(cancel_promise.task, 2_000)
    end

    # --- safe_get_slots dead-pid catch (line 749) ---

    test "cancel/2 resolves even when stream pid is already dead" do
      {:ok, pid} = ReadableStream.start_link()
      stream = %ReadableStream{controller_pid: pid}
      # Use a non-linked shutdown to kill the stream cleanly
      :gen_statem.stop(pid)
      Process.sleep(20)
      refute Process.alive?(pid)
      cancel_promise = ReadableStream.cancel(stream, :already_dead)
      assert :ok == Task.await(cancel_promise.task, 1_000)
    end

    # --- desired_size/1 (ReadableStreamDefaultController line 61) ---

    test "desired_size/1 returns positive size for new controller" do
      pid =
        ReadableStream.new(%{
          start: fn controller ->
            size = Web.ReadableStreamDefaultController.desired_size(controller)
            assert is_integer(size)
            Web.ReadableStreamDefaultController.close(controller)
          end
        }).controller_pid

      Process.sleep(50)
      assert ReadableStream.__get_slots__(pid).state == :closed
    end
  end

  defp wait_for_stream_state(pid, expected_state, attempts \\ 20)

  defp wait_for_stream_state(pid, expected_state, attempts) when attempts > 0 do
    if ReadableStream.__get_slots__(pid).state == expected_state do
      :ok
    else
      Process.sleep(25)
      wait_for_stream_state(pid, expected_state, attempts - 1)
    end
  end

  defp wait_for_stream_state(pid, expected_state, 0) do
    assert ReadableStream.__get_slots__(pid).state == expected_state
  end
end
