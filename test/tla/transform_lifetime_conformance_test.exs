defmodule Web.TLA.TransformLifetimeConformanceTest do
  # Compares the two sides of a real `Web.TransformStream` with the
  # specification `tla/TransformLifetime.tla`.
  #
  # The test makes a random list of operations of two processes: the owner,
  # which made the stream, and one more process. It does each operation on
  # the real stream and on the specification. The two sides do some steps
  # at their own time: they send the changes of their locks, they get the
  # monitor message of a stop, and their timers of the linger time expire.
  # These steps are the hidden steps of the specification. After each
  # operation, the test finds the hidden steps that give the state of the
  # real sides. Thus the real sides do only steps that the specification
  # permits. After a pause longer than the linger time, the real sides must
  # have done each timer step that the specification permits.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultReader, as: Reader
  alias Web.Test.SpecModel
  alias Web.TransformStream
  alias Web.TransformStreamDefaultController, as: Controller
  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter, as: Writer

  @procs [:owner, :other]
  @sides ["readable", "writable"]
  @linger 15
  @hidden for side <- @sides,
              action <- ["Deliver", "OwnerExpire", "StopComplete"],
              do: {action, [side]}
  @timers for side <- @sides, action <- ["OwnerExpire", "StopComplete"], do: {action, [side]}

  defp command do
    proc = member_of(@procs)
    side = member_of([:readable, :writable])

    frequency([
      {4, tuple({constant(:lock), proc, side})},
      {3, tuple({constant(:unlock), proc, side})},
      {1, tuple({constant(:proc_stop), proc})},
      {1, constant(:close)},
      {2, tuple({constant(:read_all), proc})},
      {2, tuple({constant(:failing_owner), side})},
      {2, constant(:pause)}
    ])
  end

  property "the two sides do each step as the specification permits" do
    check all(commands <- list_of(command(), max_length: 12), max_runs: 40) do
      system = start_system()

      try do
        model = follow(SpecModel.start("TransformLifetime"), system)

        {model, system} =
          Enum.reduce(commands, {model, system}, fn command, {model, system} ->
            step(command, model, system)
          end)

        finish(model, system)
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
    procs = Map.new(@procs, fn name -> {name, spawn(fn -> proc(test) end)} end)

    # The owner makes the stream. The function start puts one chunk in the
    # queue of the readable side: after a close, the readable side has a
    # chunk that no process read.
    make = fn ->
      TransformStream.new(%{start: &Controller.enqueue(&1, :chunk)}, linger: @linger)
    end

    transform = call(procs, :owner, make)

    %{
      procs: procs,
      transform: transform,
      pids: %{
        "readable" => transform.readable.controller_pid,
        "writable" => transform.writable.controller_pid
      },
      handles: %{}
    }
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

  defp call(procs, proc, fun) do
    send(procs[proc], {:run, fun})

    receive do
      {:result, result} -> result
    after
      2_000 -> flunk("the process #{proc} gave no result")
    end
  end

  # The function runs in the process. A function that raises or exits gives
  # `{:error, value}`.
  defp attempt(system, proc, fun) do
    call(system.procs, proc, fn ->
      try do
        fun.()
      rescue
        error -> {:error, error}
      catch
        kind, value -> {:error, {kind, value}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # One operation, on the real stream and on the specification
  # ---------------------------------------------------------------------------

  # The test waits for more than the linger time. After that time, the
  # sides did each timer step that the specification permits.
  defp step(:pause, model, system) do
    Process.sleep(4 * @linger)
    {timers_done(follow(model, system), system), system}
  end

  # The real operation gives the steps of the specification. The hidden
  # steps can come before them and after them: see `follow/3`.
  defp step(command, model, system) do
    {steps, system} = run(command, model, system)
    {follow(model, system, steps), system}
  end

  defp run({:lock, proc, side}, model, system) do
    args = [to_string(proc), to_string(side)]

    with true <- SpecModel.enabled?(model, "Lock", args),
         {:ok, handle} <- attempt(system, proc, fn -> take_lock(system.transform, side) end) do
      {[{"Lock", args}], put_in(system.handles[{proc, side}], handle)}
    else
      # The side stopped at the end of its linger time: the hidden steps
      # give that state.
      _not_enabled_or_stopped -> {[], system}
    end
  end

  defp run({:unlock, proc, side}, model, system) do
    args = [to_string(proc), to_string(side)]

    if SpecModel.enabled?(model, "Unlock", args) do
      handle = Map.fetch!(system.handles, {proc, side})
      _result = attempt(system, proc, fn -> release(handle) end)
      {[{"Unlock", args}], system}
    else
      {[], system}
    end
  end

  defp run({:proc_stop, proc}, model, system) do
    if SpecModel.enabled?(model, "ProcStop", [to_string(proc)]) do
      pid = system.procs[proc]
      monitor = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
      {[{"ProcStop", [to_string(proc)]}], system}
    else
      {[], system}
    end
  end

  # The writable side closes: a process that holds the writer lock closes
  # with its writer. The flush closes the readable side, which keeps its
  # chunk.
  defp run(:close, model, system) do
    # A close that fails came after the end of a side: the hidden steps give
    # that state.
    if SpecModel.enabled?(model, "Close") and close(model, system) == :ok,
      do: {[{"Close", []}], system},
      else: {[], system}
  end

  defp run({:read_all, proc}, model, system) do
    if SpecModel.enabled?(model, "ReadAll", [to_string(proc)]) do
      reader = Map.fetch!(system.handles, {proc, :readable})

      result =
        attempt(system, proc, fn -> {await(Reader.read(reader)), await(Reader.read(reader))} end)

      assert result == {%{value: :chunk, done: false}, %{value: nil, done: true}}
      {[{"ReadAll", [to_string(proc)]}], system}
    else
      {[], system}
    end
  end

  # The owner fails while the other process takes the lock of one side. The
  # side of the lock gets the request for the lock, and then the stop of
  # the owner. The other side gets the stop of the owner before the message
  # of the lock. An owner that failed gives no linger time, thus that side
  # comes to the owner rule while its copy of the lock is late. The
  # handshake keeps the two sides.
  defp run({:failing_owner, side}, model, system) do
    args = ["other", to_string(side)]
    state = SpecModel.to_map(model)

    if SpecModel.enabled?(model, "Lock", args) and "owner" in state["live"] and
         Enum.all?(state["running"], fn {_side, running} -> running end) do
      locked = system.pids[to_string(side)]
      other = system.pids[other_side(side)]
      owner = system.procs.owner
      :erlang.suspend_process(locked)
      :erlang.suspend_process(other)

      send(system.procs.other, {:run, fn -> take_lock(system.transform, side) end})
      await_message(locked, &lock_request?/1)

      monitor = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
      await_message(locked, &match?({:DOWN, _ref, :process, ^owner, _reason}, &1))
      await_message(other, &match?({:DOWN, _ref, :process, ^owner, _reason}, &1))

      # The side of the lock grants the lock, and then it gets the stop of
      # the owner: the call `observe_side/2` comes after them.
      :erlang.resume_process(locked)
      assert_receive {:result, {:ok, handle}}, 2_000
      observe_side(to_string(side), system)
      :erlang.resume_process(other)

      {[{"Lock", args}, {"ProcStop", ["owner"]}], put_in(system.handles[{:other, side}], handle)}
    else
      {[], system}
    end
  end

  defp other_side(:readable), do: "writable"
  defp other_side(:writable), do: "readable"

  defp lock_request?({:"$gen_call", _from, request}) when is_tuple(request),
    do: elem(request, 0) in [:get_reader, :get_writer]

  defp lock_request?(_message), do: false

  # Waits until the mailbox of the process has a message for which `fun`
  # gives true. The process can be suspended.
  defp await_message(pid, fun, attempts \\ 400) do
    {:messages, messages} = Process.info(pid, :messages)

    cond do
      Enum.any?(messages, fun) -> :ok
      attempts == 0 -> flunk("the message did not come")
      true -> Process.sleep(5) && await_message(pid, fun, attempts - 1)
    end
  end

  defp close(model, system) do
    case SpecModel.get(model, "lock")["writable"] do
      # A close that fails is not an error of the test: see `run(:close, _, _)`.
      "none" ->
        case Web.Promise.wait(WritableStream.close(system.transform.writable)) do
          {:fulfilled, :ok} -> :ok
          {:rejected, reason} -> {:error, reason}
        end

      holder ->
        proc = String.to_existing_atom(holder)
        writer = Map.fetch!(system.handles, {proc, :writable})
        attempt(system, proc, fn -> await(Writer.close(writer)) end)
    end
  end

  defp take_lock(transform, :readable), do: {:ok, ReadableStream.get_reader(transform.readable)}
  defp take_lock(transform, :writable), do: {:ok, WritableStream.get_writer(transform.writable)}

  defp release(%Reader{} = reader), do: Reader.release_lock(reader)
  defp release(%Writer{} = writer), do: Writer.release_lock(writer)

  # The owner stops, and then the other process stops, each with a pause.
  # Thus a lock of the other process keeps the two sides after the stop of
  # the owner. After the two stops, the two sides stop: the property
  # NoOrphan.
  defp finish(model, system) do
    model =
      Enum.reduce(@procs, model, fn proc, model ->
        {model, _system} = step({:proc_stop, proc}, model, system)
        {model, _system} = step(:pause, model, system)
        model
      end)

    state = SpecModel.to_map(model)
    assert state["running"] == %{"readable" => false, "writable" => false}
    refute Process.alive?(system.pids["readable"]) or Process.alive?(system.pids["writable"])
  end

  # The timer steps that the specification permits are done: the real sides
  # did them. A busy machine can do them late, thus the test waits some
  # time.
  defp timers_done(model, system, attempts \\ 100) do
    model = follow(model, system)

    cond do
      not Enum.any?(@timers, fn {action, args} -> SpecModel.enabled?(model, action, args) end) ->
        model

      attempts == 0 ->
        flunk("the sides did not do a timer step: #{inspect(SpecModel.to_map(model))}")

      true ->
        Process.sleep(10)
        timers_done(model, system, attempts - 1)
    end
  end

  # ---------------------------------------------------------------------------
  # The hidden steps
  # ---------------------------------------------------------------------------

  # Finds the states that the steps of the operation, in their sequence,
  # and the hidden steps before and between and after them give from the
  # model. Returns a state that has the state of the real sides, with no
  # message in the inboxes: the real messages come in some microseconds.
  # The real sides can be in a step: the test looks again some times.
  defp follow(model, system, steps \\ [], attempts \\ 100) do
    observed = observe(system)

    states =
      for {state, []} <- reachable({model, steps}),
          inbox_length(state) == 0 and matches?(state, observed),
          do: state

    case states do
      [] when attempts > 0 ->
        Process.sleep(5)
        follow(model, system, steps, attempts - 1)

      [] ->
        flunk(
          "the specification permits no state of the real sides: " <>
            "#{inspect(observed)}, from #{inspect(SpecModel.to_map(model))} " <>
            "with the steps #{inspect(steps)}"
        )

      [state | _others] ->
        state
    end
  end

  defp reachable(start), do: reachable([start], MapSet.new([key(start)]), [start])

  defp reachable([], _seen, found), do: found

  defp reachable([{model, steps} | rest], seen, found) do
    hidden =
      for {action, args} <- @hidden,
          SpecModel.enabled?(model, action, args),
          do: {SpecModel.step!(model, action, args), steps}

    next =
      case steps do
        [{action, args} | later] ->
          if SpecModel.enabled?(model, action, args),
            do: [{SpecModel.step!(model, action, args), later} | hidden],
            else: hidden

        [] ->
          hidden
      end
      |> Enum.reject(&MapSet.member?(seen, key(&1)))
      |> Enum.uniq_by(&key/1)

    seen = Enum.reduce(next, seen, &MapSet.put(&2, key(&1)))
    reachable(rest ++ next, seen, found ++ next)
  end

  defp key({model, steps}), do: {SpecModel.to_map(model), steps}

  defp inbox_length(model) do
    model |> SpecModel.get("inbox") |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
  end

  # ---------------------------------------------------------------------------
  # The comparison of the two states
  # ---------------------------------------------------------------------------

  defp matches?(model, observed) do
    state = SpecModel.to_map(model)

    Enum.all?(@sides, fn side ->
      case observed[side] do
        :stopped ->
          not state["running"][side]

        %{phase: phase, lock: lock, copy: copy, ending: ending} ->
          state["running"][side] and state["phase"][side] == phase and
            state["lock"][side] == lock and state["copy"][side] == copy and
            state["asking"][side] == ending
      end
    end)
  end

  defp observe(system) do
    Map.new(@sides, fn side -> {side, observe_side(side, system)} end)
  end

  # A side can stop between the check and the call: then it is stopped.
  defp observe_side(side, system) do
    pid = system.pids[side]

    slots =
      try do
        if side == "readable",
          do: ReadableStream.__get_slots__(pid),
          else: WritableStream.__get_slots__(pid)
      catch
        :exit, _reason -> nil
      end

    case slots do
      %{} = slots ->
        %{
          phase: phase(side, slots),
          lock: lock_name(side, slots, system),
          copy: slots.transform.peer_locked,
          ending: slots.transform.ending
        }

      _stopped ->
        :stopped
    end
  end

  defp phase("readable", %{state: :readable}), do: "active"
  defp phase("readable", %{state: :errored}), do: "complete"

  defp phase("readable", %{state: :closed, queue: queue}),
    do: if(:queue.is_empty(queue), do: "complete", else: "unread")

  defp phase("writable", %{state: state}) when state in [:closed, :errored], do: "complete"
  defp phase("writable", _slots), do: "active"

  defp lock_name("readable", slots, system), do: proc_name(slots.reader_pid, system)

  defp lock_name("writable", %{writer_is_pipe: false} = slots, system),
    do: proc_name(slots.writer_pid, system)

  defp proc_name(nil, _system), do: "none"

  defp proc_name(pid, system) do
    case Enum.find(system.procs, fn {_name, proc} -> proc == pid end) do
      {name, ^pid} -> to_string(name)
      # The test process closes an unlocked writable side with no lock.
      nil -> "test"
    end
  end
end
