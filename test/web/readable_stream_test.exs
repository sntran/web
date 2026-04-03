defmodule Web.ReadableStreamTest do
  use ExUnit.Case, async: true

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultReader
  alias Web.TypeError

  setup do
    {:ok, pid} = ReadableStream.start_link(high_water_mark: 2)
    stream = %ReadableStream{controller_pid: pid}
    %{stream: stream, controller_pid: pid}
  end

  test "TypeError" do
    assert %TypeError{message: "m"}.message == "m"
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
      assert ReadableStream.get_slots(pid).reader_pid == nil
    end

    test "Enumerable halt", %{stream: stream, controller_pid: pid} do
      ReadableStream.enqueue(pid, "a")
      ReadableStream.enqueue(pid, "b")
      assert Enum.take(stream, 1) == ["a"]
      Process.sleep(50)
      assert ReadableStream.get_slots(pid).reader_pid == nil
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
      ReadableStream.cancel(p1, :r1)
      receive do: ({:web_stream_cancel, ^p1, :r1} -> :ok)

      # Function source
      {:ok, p2} = ReadableStream.start_link(source: fn x -> send(parent, {:f, x}) end)
      receive do: ({:f, %Web.ReadableStreamDefaultController{pid: ^p2}} -> :ok)
      ReadableStream.cancel(p2, :r2)
      receive do: ({:f, :r2} -> :ok)

      # MFA source
      {:ok, p3} = ReadableStream.start_link(source: {Kernel, :send, [parent]})
      receive do: (%Web.ReadableStreamDefaultController{pid: ^p3} -> :ok)
      ReadableStream.cancel(p3, :r3)
      receive do: (:r3 -> :ok)

      # Nil source
      {:ok, p4} = ReadableStream.start_link(source: nil)
      ReadableStream.enqueue(p4, "a")
      ReadableStream.cancel(p4, :r4)
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
      assert ReadableStream.get_slots(pid).reader_pid == nil

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

      assert {:ok, "hello"} = ReadableStream.read_all(stream)
      assert ReadableStream.disturbed?(stream) == true
    end

    test "from/1 normalizes enumerables using pull" do
      stream = ReadableStream.from(["a", "b", "c"])
      assert {:ok, "abc"} = ReadableStream.read_all(stream)
    end

    test "from/1 handles passthroughs, empty enumerables, and invalid values" do
      stream_struct = Stream.map(["a"], & &1)

      stream_fun =
        Stream.resource(
          fn -> ["a"] end,
          fn
            [] -> {:halt, []}
            [h | t] -> {[h], t}
          end,
          fn _ -> :ok end
        )

      assert ReadableStream.from(stream_struct) == stream_struct
      assert ReadableStream.from(stream_fun) == stream_fun
      assert {:ok, ""} = [] |> ReadableStream.from() |> ReadableStream.read_all()
      assert_raise ArgumentError, ~r/cannot normalize body/, fn -> ReadableStream.from(123) end
    end

    test "from/1 enumerable cancellation and nil-source cancel paths do not crash" do
      stream = ReadableStream.from(1..10)
      ReadableStream.cancel(stream.controller_pid, :stop_now)

      {:ok, nil_pid} = ReadableStream.start_link(source: nil)
      ReadableStream.cancel(nil_pid, :noop)
      assert ReadableStream.get_slots(nil_pid).state == :closed
    end

    test "helper fallbacks cover pid, enumerable, and non-readable bodies" do
      pid_stream =
        ReadableStream.new(%{start: fn c -> Web.ReadableStreamDefaultController.close(c) end})

      locked_stream = ReadableStream.new()
      _reader = ReadableStream.get_reader(locked_stream)

      assert ReadableStream.disturbed?(nil) == false
      assert ReadableStream.disturbed?("abc") == false
      assert ReadableStream.locked?(nil) == false
      assert ReadableStream.locked?(["a"]) == false
      assert {:ok, ""} = ReadableStream.read_all(nil)
      assert {:ok, "abc"} = ReadableStream.read_all("abc")
      assert {:ok, "ab"} = ReadableStream.read_all(["a", "b"])
      assert {:ok, ""} = ReadableStream.read_all(pid_stream.controller_pid)
      assert {:ok, "ab"} = ReadableStream.read_all(Stream.map(["a", "b"], & &1))
      assert {:error, %TypeError{message: "body is not readable"}} = ReadableStream.read_all(123)

      assert {:error, %TypeError{message: "ReadableStream is already locked"}} =
               ReadableStream.read_all(locked_stream)

      assert ReadableStream.disturbed?(%{}) == false
      assert ReadableStream.locked?(%{}) == false
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

      {left, right} = ReadableStream.tee(stream)

      assert_raise TypeError, "The stream is errored.", fn -> Enum.to_list(left) end
      assert_raise TypeError, "The stream is errored.", fn -> Enum.to_list(right) end
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
      Process.sleep(50)
      assert ReadableStream.get_slots(ok_pid).state == :readable

      {:ok, error_pid} =
        ReadableStream.start_link(
          source: %{
            pull: fn _controller ->
              raise "pull failed"
            end
          }
        )

      send(error_pid, {:internal, :maybe_pull})
      Process.sleep(50)
      assert ReadableStream.get_slots(error_pid).state == :errored
    end

    test "task down paths handle normal and abnormal exits" do
      sleeper = fn _controller -> Process.sleep(5_000) end

      {:ok, normal_pid} = ReadableStream.start_link(source: %{pull: sleeper})
      send(normal_pid, {:internal, :maybe_pull})
      Process.sleep(50)
      normal_ref = ReadableStream.get_slots(normal_pid).task_ref
      send(normal_pid, {:DOWN, normal_ref, :process, self(), :normal})
      Process.sleep(50)
      assert ReadableStream.get_slots(normal_pid).state == :readable

      {:ok, abnormal_pid} = ReadableStream.start_link(source: %{pull: sleeper})
      send(abnormal_pid, {:internal, :maybe_pull})
      Process.sleep(50)
      abnormal_ref = ReadableStream.get_slots(abnormal_pid).task_ref
      send(abnormal_pid, {:DOWN, abnormal_ref, :process, self(), :kaboom})
      Process.sleep(50)
      assert ReadableStream.get_slots(abnormal_pid).state == :errored
    end

    test "read_all/1 releases the lock when the stream errors mid-read" do
      stream = ReadableStream.new()

      task =
        Task.async(fn ->
          ReadableStream.read_all(stream)
        end)

      Process.sleep(50)
      ReadableStream.error(stream.controller_pid, :boom)

      assert {:ok, {:error, {:errored, :boom}}} = Task.yield(task, 1000)
      assert ReadableStream.locked?(stream) == false
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
      assert ReadableStream.get_slots(p3).disturbed == false
      assert ReadableStream.get_desired_size(p3) == 5
      ReadableStream.enqueue(p3, "a")
      assert ReadableStream.get_slots(p3).disturbed == false
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
      assert :queue.is_empty(ReadableStream.get_slots(pid).queue)
    end
  end

  describe "Reader" do
    test "errors", %{stream: stream, controller_pid: pid} do
      reader = ReadableStream.get_reader(stream)

      # Errored with reason
      ReadableStream.error(pid, :fail)
      # Sync to ensure reason is set
      ReadableStream.get_slots(pid)

      assert_raise TypeError, "The stream is errored.", fn ->
        ReadableStreamDefaultReader.read(reader)
      end

      # Errored WITHOUT reason (forced)
      {:ok, p2} = ReadableStream.start_link()
      s2 = %ReadableStream{controller_pid: p2}
      r2 = ReadableStream.get_reader(s2)
      ReadableStream.error(p2, :force_error_no_reason)
      ReadableStream.get_slots(p2)

      assert_raise TypeError, "The stream is errored.", fn ->
        ReadableStreamDefaultReader.read(r2)
      end

      # Unexpected read
      {:ok, p3} = ReadableStream.start_link()
      s3 = %ReadableStream{controller_pid: p3}
      r3 = ReadableStream.get_reader(s3)
      ReadableStream.error(p3, :force_unexpected_read)
      ReadableStream.get_slots(p3)
      assert_raise TypeError, ~r/Unknown error/, fn -> ReadableStreamDefaultReader.read(r3) end

      # Unexpected release
      {:ok, p4} = ReadableStream.start_link()
      s4 = %ReadableStream{controller_pid: p4}
      r4 = ReadableStream.get_reader(s4)
      ReadableStream.error(p4, :force_unexpected_release)
      ReadableStream.get_slots(p4)

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

      {branch_a, branch_b} = ReadableStream.tee(stream)

      assert Enum.to_list(branch_a) == [1, 2, 3]
      assert Enum.to_list(branch_b) == [1, 2, 3]
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

      {branch_a, branch_b} = ReadableStream.tee(stream)

      # Cancel branch A
      reader_a = ReadableStream.get_reader(branch_a)
      ReadableStreamDefaultReader.cancel(reader_a)

      # Branch B should still be able to get data
      reader_b = ReadableStream.get_reader(branch_b)
      # Wait a bit for async start/pull to complete if needed
      Process.sleep(50)
      assert ReadableStreamDefaultReader.read(reader_b) == "data"
      assert_receive :pull_called

      # Original should NOT be cancelled yet
      refute_receive :original_cancelled

      # Cancel branch B
      ReadableStreamDefaultReader.cancel(reader_b)

      # Now original should be cancelled
      assert_receive :original_cancelled
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
      ReadableStream.cancel(stream.controller_pid, :abort)

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

      {branch_a, branch_b} = ReadableStream.new(source) |> ReadableStream.tee()

      # Cancel A
      reader_a = ReadableStream.get_reader(branch_a)
      ReadableStreamDefaultReader.cancel(reader_a)

      # B should still work
      reader_b = ReadableStream.get_reader(branch_b)
      assert ReadableStreamDefaultReader.read(reader_b) == "data"
      assert ReadableStreamDefaultReader.read(reader_b) == "data"
    end

    test "DefaultController.error" do
      source = %{
        start: fn controller ->
          Web.ReadableStreamDefaultController.error(controller, :source_failed)
        end
      }

      s2 = ReadableStream.new(source)
      reader = ReadableStream.get_reader(s2)
      # Wait for async start to complete
      Process.sleep(50)
      assert_raise TypeError, ~r/errored/, fn -> ReadableStreamDefaultReader.read(reader) end
      assert ReadableStream.get_slots(s2.controller_pid).error_reason == :source_failed
    end

    test "ReadableStream terminate with active task" do
      use Web
      parent = self()

      source = %{
        pull: fn _controller ->
          send(parent, :pulling)
          Process.sleep(10000)
        end
      }

      {:ok, pid} = ReadableStream.start_link(source: source)
      # Trigger pull
      ReadableStream.get_reader(pid)
      assert_receive :pulling
      # Stop the gen_statem
      GenServer.stop(pid)
      # Should call terminate and kill task
    end

    test "branch_cancelled edge cases", %{controller_pid: pid} do
      # Branch cancelled when no branches actually exist (unexpected)
      send(pid, {:cast, {:branch_cancelled, self()}})
    end
  end
end
