defmodule Web.ReadableStreamTest do
  use ExUnit.Case, async: true

  alias Web.ReadableStream
  alias Web.ReadableStream.Controller
  alias Web.ReadableStreamDefaultReader
  alias Web.TypeError

  setup do
    {:ok, pid} = Controller.start_link(high_water_mark: 2)
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
      Controller.enqueue(pid, "a")
      Controller.close(pid)
      assert Enum.to_list(stream) == ["a"]
    end

    test "Enumerable exception cleanup", %{stream: stream, controller_pid: pid} do
      Controller.enqueue(pid, "a")

      assert_raise RuntimeError, fn ->
        Enum.each(stream, fn _ -> raise "error" end)
      end

      Process.sleep(50)
      assert Controller.get_slots(pid).reader_pid == nil
    end

    test "Enumerable halt", %{stream: stream, controller_pid: pid} do
      Controller.enqueue(pid, "a")
      Controller.enqueue(pid, "b")
      assert Enum.take(stream, 1) == ["a"]
      Process.sleep(50)
      assert Controller.get_slots(pid).reader_pid == nil
    end

    test "Enumerable suspend", %{stream: stream, controller_pid: pid} do
      Controller.enqueue(pid, "a")
      Controller.enqueue(pid, "b")
      Controller.close(pid)

      {:suspended, "a", next} =
        Enumerable.reduce(stream, {:cont, ""}, fn
          x, "" -> {:suspend, x}
          x, acc -> {:cont, acc <> x}
        end)

      assert {:done, "ab"} = next.({:cont, "a"})
    end

    test "Enumerable release_lock rescues", %{stream: stream, controller_pid: pid} do
      Controller.enqueue(pid, "a")
      # Rescue in halt
      Enum.reduce_while(stream, 0, fn _x, _acc ->
        Controller.release_lock(pid)
        {:halt, :stopped}
      end)

      # Rescue in done
      {:ok, p2} = Controller.start_link()
      s2 = %ReadableStream{controller_pid: p2}
      Controller.enqueue(p2, "a")
      Controller.close(p2)

      Enum.each(s2, fn _ ->
        Controller.error(p2, :force_unexpected_release)
      end)

      # Rescue in error/rescue
      {:ok, p3} = Controller.start_link()
      s3 = %ReadableStream{controller_pid: p3}
      Controller.enqueue(p3, "a")

      assert_raise RuntimeError, fn ->
        Enum.each(s3, fn _ ->
          Controller.error(p3, :force_unexpected_release)
          raise "bomb"
        end)
      end
    end
  end

  describe "Controller" do
    test "various sources" do
      parent = self()

      # PID source
      {:ok, p1} = Controller.start_link(source: parent)
      receive do: ({:pull, ^p1} -> :ok)
      Controller.cancel(p1, :r1)
      receive do: ({:web_stream_cancel, ^p1, :r1} -> :ok)

      # Function source
      {:ok, p2} = Controller.start_link(source: fn x -> send(parent, {:f, x}) end)
      receive do: ({:f, %Web.ReadableStreamDefaultController{pid: ^p2}} -> :ok)
      Controller.cancel(p2, :r2)
      receive do: ({:f, :r2} -> :ok)

      # MFA source
      {:ok, p3} = Controller.start_link(source: {Kernel, :send, [parent]})
      receive do: (%Web.ReadableStreamDefaultController{pid: ^p3} -> :ok)
      Controller.cancel(p3, :r3)
      receive do: (:r3 -> :ok)

      # Nil source
      {:ok, p4} = Controller.start_link(source: nil)
      Controller.enqueue(p4, "a")
      Controller.cancel(p4, :r4)
    end

    test "internal events and desired size", %{controller_pid: pid} do
      assert Controller.get_desired_size(pid) == 2
      send(pid, {:internal, :maybe_pull})
      Controller.close(pid)
      send(pid, {:internal, :maybe_pull})
      send(pid, {:internal, :flush_requests})
      Controller.error(pid, :fail)
      send(pid, {:internal, :maybe_pull})
      send(pid, {:internal, :flush_requests})
    end

    test "DOWN monitoring" do
      {:ok, pid} = Controller.start_link()
      stream = %ReadableStream{controller_pid: pid}
      parent = self()

      spawn(fn ->
        ReadableStream.get_reader(stream)
        send(parent, :locked)
      end)

      receive do: (:locked -> :ok)
      Process.sleep(100)
      assert Controller.get_slots(pid).reader_pid == nil

      # Send a DOWN message with a ref that doesn't match
      send(pid, {:DOWN, make_ref(), :process, self(), :normal})
    end

    test "unknown generic", %{controller_pid: pid} do
      :gen_statem.cast(pid, :unknown)
      send(pid, :unknown)

      Controller.close(pid)
      send(pid, :unknown)
    end

    test "unlocked actions", %{controller_pid: pid} do
      assert {:error, :not_locked_by_reader} = Controller.read(pid)
      assert {:error, :not_locked_by_reader} = Controller.release_lock(pid)
    end

    test "fulfillment", %{controller_pid: pid} do
      parent = self()

      spawn_link(fn ->
        Controller.get_reader(pid)
        res = Controller.read(pid)
        send(parent, {:res, res})
      end)

      Process.sleep(50)
      Controller.enqueue(pid, "v")
      receive do: ({:res, {:ok, "v"}} -> :ok)
    end

    test "edge cases" do
      # maybe_pull when queue full
      {:ok, p1} = Controller.start_link(high_water_mark: 1)
      Controller.enqueue(p1, "a")
      send(p1, {:internal, :maybe_pull})

      # flush_requests when queue NOT empty
      {:ok, p2} = Controller.start_link()
      Controller.enqueue(p2, "a")
      # This sends flush_requests, but queue not empty
      Controller.close(p2)

      # force_unknown_error
      assert {:error, :unexpected} = Controller.force_unknown_error(p1)

      # disturbed and desired size
      {:ok, p3} = Controller.start_link(high_water_mark: 5)
      assert Controller.get_slots(p3).disturbed == false
      assert Controller.get_desired_size(p3) == 5
      Controller.enqueue(p3, "a")
      assert Controller.get_slots(p3).disturbed == true
      assert Controller.get_desired_size(p3) == 4

      # HWM else branch coverage (read when queue still >= hwm)
      {:ok, p4} = Controller.start_link(high_water_mark: 1)
      Controller.enqueue(p4, "a")
      Controller.enqueue(p4, "b")
      Controller.get_reader(p4)
      # queue was 2, now 1. 1 < 1 is false.
      Controller.read(p4)

      # One pending request on close
      {:ok, p5} = Controller.start_link()
      parent = self()

      spawn_link(fn ->
        Controller.get_reader(p5)
        send(parent, :locked)
        send(parent, {:r1, Controller.read(p5)})
      end)

      receive do: (:locked -> :ok)
      Process.sleep(50)
      Controller.close(p5)
      assert_receive {:r1, :done}

      # One pending request on error
      {:ok, p6} = Controller.start_link()

      spawn_link(fn ->
        Controller.get_reader(p6)
        send(parent, :locked_too)
        send(parent, {:r3, Controller.read(p6)})
      end)

      receive do: (:locked_too -> :ok)
      Process.sleep(50)
      Controller.error(p6, :boom)
      assert_receive {:r3, {:error, {:errored, :boom}}}
    end

    test "closed enqueue" do
      {:ok, pid} = Controller.start_link()
      Controller.close(pid)
      Controller.enqueue(pid, "ignored")
      assert :queue.is_empty(Controller.get_slots(pid).queue)
    end
  end

  describe "Reader" do
    test "errors", %{stream: stream, controller_pid: pid} do
      reader = ReadableStream.get_reader(stream)

      # Errored with reason
      Controller.error(pid, :fail)
      # Sync to ensure reason is set
      Controller.get_slots(pid)

      assert_raise TypeError, "The stream is errored.", fn ->
        ReadableStreamDefaultReader.read(reader)
      end

      # Errored WITHOUT reason (forced)
      {:ok, p2} = Controller.start_link()
      s2 = %ReadableStream{controller_pid: p2}
      r2 = ReadableStream.get_reader(s2)
      Controller.error(p2, :force_error_no_reason)
      Controller.get_slots(p2)

      assert_raise TypeError, "The stream is errored.", fn ->
        ReadableStreamDefaultReader.read(r2)
      end

      # Unexpected read
      {:ok, p3} = Controller.start_link()
      s3 = %ReadableStream{controller_pid: p3}
      r3 = ReadableStream.get_reader(s3)
      Controller.error(p3, :force_unexpected_read)
      Controller.get_slots(p3)
      assert_raise TypeError, ~r/Unknown error/, fn -> ReadableStreamDefaultReader.read(r3) end

      # Unexpected release
      {:ok, p4} = Controller.start_link()
      s4 = %ReadableStream{controller_pid: p4}
      r4 = ReadableStream.get_reader(s4)
      Controller.error(p4, :force_unexpected_release)
      Controller.get_slots(p4)

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
      {:ok, pid} = Controller.start_link(high_water_mark: 10)
      stream = %ReadableStream{controller_pid: pid}

      Controller.enqueue(pid, 1)
      Controller.enqueue(pid, 2)
      Controller.enqueue(pid, 3)
      Controller.close(pid)

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
      ReadableStream.Controller.cancel(stream.controller_pid, :abort)

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

    test "DefaultController.error", %{stream: stream, controller_pid: pid} do
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
      assert Controller.get_slots(s2.controller_pid).error_reason == :source_failed
    end

    test "Controller termimate with active task" do
      use Web
      parent = self()

      source = %{
        pull: fn _controller ->
          send(parent, :pulling)
          Process.sleep(10000)
        end
      }

      {:ok, pid} = Controller.start_link(source: source)
      # Trigger pull
      Controller.get_reader(pid)
      assert_receive :pulling
      # Stop the gen_statem
      GenServer.stop(pid)
      # Should call terminate and kill task
    end

    test "Controller branch_cancelled edge cases", %{controller_pid: pid} do
      # Branch cancelled when no branches actually exist (unexpected)
      send(pid, {:cast, {:branch_cancelled, self()}})
    end
  end
end
