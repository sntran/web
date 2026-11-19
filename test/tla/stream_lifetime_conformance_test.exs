defmodule Web.TLA.StreamLifetimeConformanceTest do
  # Compares a real `Web.ReadableStream` with the specification
  # `tla/StreamLifetime.tla`.
  #
  # The test makes a random list of operations. It does each operation on a
  # real stream and on the specification, and it compares the two states.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.ReadableStream
  alias Web.Test.SpecModel

  @procs [:owner, :other]
  @linger 15

  defp command do
    proc = member_of(@procs)

    frequency([
      {5, constant(:enqueue)},
      {1, constant(:close)},
      {1, constant(:fail)},
      {4, tuple({constant(:lock), proc})},
      {2, tuple({constant(:unlock), proc})},
      {5, tuple({constant(:read), proc})},
      {1, tuple({constant(:cancel), proc})},
      {1, tuple({constant(:proc_stop), proc})},
      {2, constant(:pause)}
    ])
  end

  property "the stream does each step as the specification permits" do
    check all(commands <- list_of(command(), max_length: 16), max_runs: 100) do
      system = start_system()

      try do
        Enum.reduce(commands, {SpecModel.start("StreamLifetime"), []}, fn command,
                                                                          {model, queue} ->
          {model, queue} = run(command, model, queue, system)
          model = follow_stop(model, system)
          assert_same_state(model, queue, system)
          {model, queue}
        end)
      after
        stop_system(system)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The real system: an owner that makes the stream, and one more process
  # ---------------------------------------------------------------------------

  defp start_system do
    test = self()

    procs =
      Map.new(@procs, fn name ->
        {name, spawn(fn -> proc(test) end)}
      end)

    # The owner makes the stream. The source has no pull function, thus the
    # test gives each chunk.
    send(
      procs.owner,
      {:run, fn -> ReadableStream.new(%{}, linger: @linger, high_water_mark: 10) end}
    )

    assert_receive {:result, stream}

    %{procs: procs, stream: stream, pid: stream.controller_pid}
  end

  defp stop_system(system) do
    Enum.each(system.procs, fn {_name, pid} -> Process.exit(pid, :kill) end)
  end

  # A process that does one function at a time, and gives the result.
  defp proc(test) do
    receive do
      {:run, fun} ->
        send(test, {:result, fun.()})
        proc(test)

      # A normal stop. The stream gives the handoff time only for this.
      :stop ->
        :ok
    end
  end

  defp call(system, proc, fun) do
    send(system.procs[proc], {:run, fun})

    receive do
      {:result, result} -> result
    after
      2_000 -> flunk("the process #{proc} gave no result")
    end
  end

  # ---------------------------------------------------------------------------
  # One operation, on the real stream and on the specification
  # ---------------------------------------------------------------------------

  defp run(:enqueue, model, queue, system) do
    if SpecModel.enabled?(model, "Enqueue") do
      chunk = System.unique_integer([:positive])
      ReadableStream.enqueue(system.pid, chunk)
      {SpecModel.step!(model, "Enqueue"), queue ++ [chunk]}
    else
      {model, queue}
    end
  end

  defp run(:close, model, queue, system) do
    if SpecModel.enabled?(model, "Close") do
      ReadableStream.close(system.pid)
      {SpecModel.step!(model, "Close"), queue}
    else
      {model, queue}
    end
  end

  defp run(:fail, model, queue, system) do
    if SpecModel.enabled?(model, "Fail") do
      ReadableStream.error(system.pid, :source_failure)
      {SpecModel.step!(model, "Fail"), queue}
    else
      {model, queue}
    end
  end

  defp run({:lock, proc}, model, queue, system) do
    if SpecModel.enabled?(model, "Lock", [to_string(proc)]) do
      assert call(system, proc, fn -> ReadableStream.get_reader(system.pid) end) == :ok
      {SpecModel.step!(model, "Lock", [to_string(proc)]), queue}
    else
      {model, queue}
    end
  end

  defp run({:unlock, proc}, model, queue, system) do
    if SpecModel.enabled?(model, "Unlock", [to_string(proc)]) do
      assert call(system, proc, fn -> ReadableStream.release_lock(system.pid) end) == :ok
      {SpecModel.step!(model, "Unlock", [to_string(proc)]), queue}
    else
      {model, queue}
    end
  end

  # A read gives the oldest chunk. Thus no chunk is lost, added, or moved.
  defp run({:read, proc}, model, queue, system) do
    if SpecModel.enabled?(model, "Read", [to_string(proc)]) do
      [chunk | rest] = queue
      assert call(system, proc, fn -> ReadableStream.read(system.pid) end) == {:ok, chunk}
      {SpecModel.step!(model, "Read", [to_string(proc)]), rest}
    else
      {model, queue}
    end
  end

  defp run({:cancel, proc}, model, queue, system) do
    if SpecModel.enabled?(model, "Cancel", [to_string(proc)]) do
      cancel = fn -> Web.Stream.terminate_and_wait(system.pid, :cancel, :not_necessary) end
      assert call(system, proc, cancel) == :ok
      {SpecModel.step!(model, "Cancel", [to_string(proc)]), []}
    else
      {model, queue}
    end
  end

  defp run({:proc_stop, proc}, model, queue, system) do
    if SpecModel.enabled?(model, "ProcStop", [to_string(proc)]) do
      pid = system.procs[proc]
      monitor = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
      {SpecModel.step!(model, "ProcStop", [to_string(proc)]), queue}
    else
      {model, queue}
    end
  end

  # The test waits for more than the linger time. After that time, the
  # stream did each stop step that the specification permits.
  defp run(:pause, model, queue, system) do
    Process.sleep(4 * @linger)
    stopped = stop_steps(model)

    assert Process.alive?(system.pid) == SpecModel.get(stopped, "running"),
           "after the linger time, the stream is " <>
             "#{if Process.alive?(system.pid), do: "alive", else: "stopped"}: " <>
             inspect(SpecModel.to_map(model))

    {stopped, if(SpecModel.get(stopped, "queue") == 0, do: [], else: queue)}
  end

  # Does each stop step that the specification permits.
  defp stop_steps(model) do
    cond do
      SpecModel.enabled?(model, "StopComplete") ->
        stop_steps(SpecModel.step!(model, "StopComplete"))

      SpecModel.enabled?(model, "OwnerDownExpire") ->
        stop_steps(SpecModel.step!(model, "OwnerDownExpire"))

      true ->
        model
    end
  end

  # The specification permits the stop steps at each time when they are
  # possible. Thus the model does them when the real stream stopped.
  defp follow_stop(model, system) do
    state = SpecModel.to_map(model)

    cond do
      not state["running"] ->
        model

      # The owner stopped, the stream is complete, and no process holds the
      # lock. The stream stops after the linger time. The test waits for the
      # stop, thus the subsequent operations get a stream that is stopped.
      stops_soon?(state) ->
        monitor = Process.monitor(system.pid)
        assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 1_000
        stop_steps(model)

      # The linger time can be complete at this moment.
      not Process.alive?(system.pid) ->
        stop_steps(model)

      true ->
        model
    end
  end

  defp stops_soon?(state) do
    complete? =
      state["phase"] == "errored" or (state["phase"] == "closed" and state["queue"] == 0)

    "owner" not in state["live"] and complete? and state["lock"] == "none"
  end

  # ---------------------------------------------------------------------------
  # The comparison of the two states
  # ---------------------------------------------------------------------------

  defp assert_same_state(model, _queue, system) do
    state = SpecModel.to_map(model)

    # A stream that the specification stopped is stopped. A stream that the
    # specification keeps can be stopped only if a stop step is possible:
    # then the linger time was complete at this moment.
    if state["running"] do
      assert Process.alive?(system.pid) or not SpecModel.get(stop_steps(model), "running"),
             "the stream is stopped, but the specification has #{inspect(state)}"
    else
      refute Process.alive?(system.pid),
             "the stream is alive, but the specification has #{inspect(state)}"
    end

    with true <- state["running"], slots when is_map(slots) <- slots(system) do
      assert phase(slots.state) == state["phase"]
      assert slots.disturbed == state["disturbed"]
      assert lock_name(slots.reader_pid, system) == state["lock"]

      # An errored stream keeps its chunks, but no process can read them.
      assert :queue.len(slots.queue) == state["queue"]
    end
  end

  # The stream can stop between the two calls. Then there are no slots.
  defp slots(system) do
    ReadableStream.__get_slots__(system.pid)
  catch
    :exit, _reason -> nil
  end

  defp phase(:readable), do: "active"
  defp phase(:closed), do: "closed"
  defp phase(:errored), do: "errored"

  defp lock_name(nil, _system), do: "none"

  defp lock_name(pid, system) do
    {name, ^pid} = Enum.find(system.procs, fn {_name, proc} -> proc == pid end)
    to_string(name)
  end
end
