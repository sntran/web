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
  # permits.
  #
  # The test does not depend on the time of the machine:
  #
  #   * The stream has the linger time 0. Each timer of the linger time
  #     fires at once: a timeout 0 of `:gen_statem` comes before the next
  #     message of the side. Thus the test waits for no timer.
  #   * After each operation, the test waits until the processes of the
  #     system are at rest: see `await_rest/1`. Then the sides did each step
  #     of their messages and of their timers. The test compares the state
  #     one time, and the real sides must have done each timer step that the
  #     specification permits.
  #   * Each wait for a message or a result has no time limit.
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
      {2, tuple({constant(:failing_owner), side})}
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
    group = spawn(fn -> group_leader_loop(Process.group_leader()) end)
    procs = Map.new(@procs, fn name -> {name, spawn_in_group(group, fn -> proc(test) end)} end)

    # The owner makes the stream. The function start puts one chunk in the
    # queue of the readable side: after a close, the readable side has a
    # chunk that no process read. The linger time 0 fires each timer at
    # once.
    make = fn ->
      TransformStream.new(%{start: &Controller.enqueue(&1, :chunk)}, linger: 0)
    end

    transform = call(procs, :owner, make)

    %{
      group: group,
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
    send(system.group, :stop)
  end

  # The group leader of the processes of the system: the two processes of
  # the test, and the processes that they start, for example the two sides
  # and their workers. It gives each request of input or output to the
  # group leader of the test.
  defp group_leader_loop(leader) do
    receive do
      :stop ->
        :ok

      message ->
        send(leader, message)
        group_leader_loop(leader)
    end
  end

  defp spawn_in_group(group, fun) do
    pid =
      spawn(fn ->
        receive do
          :go -> fun.()
        end
      end)

    Process.group_leader(pid, group)
    send(pid, :go)
    pid
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

      receive do
        {:DOWN, ^monitor, :process, ^pid, :normal} -> :ok
      end

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

  # The read of the last chunk drains the closed readable side: it is
  # complete, and it stops at once with the linger time 0.
  defp run({:read_all, proc}, model, system) do
    if SpecModel.enabled?(model, "ReadAll", [to_string(proc)]) do
      reader = Map.fetch!(system.handles, {proc, :readable})
      result = attempt(system, proc, fn -> await(Reader.read(reader)) end)
      assert result == %{value: :chunk, done: false}
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

      receive do
        {:DOWN, ^monitor, :process, ^owner, :killed} -> :ok
      end

      await_message(locked, &match?({:DOWN, _ref, :process, ^owner, _reason}, &1))
      await_message(other, &match?({:DOWN, _ref, :process, ^owner, _reason}, &1))

      # The side of the lock grants the lock, and then it gets the stop of
      # the owner: the call `observe_side/2` comes after them.
      :erlang.resume_process(locked)

      handle =
        receive do
          {:result, {:ok, handle}} -> handle
        end

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
  # gives true. The process can be suspended. The sender of the message
  # runs: the wait has no time limit.
  defp await_message(pid, fun) do
    {:messages, messages} = Process.info(pid, :messages)

    unless Enum.any?(messages, fun) do
      Process.sleep(1)
      await_message(pid, fun)
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

  # The owner stops, and then the other process stops. Thus a lock of the
  # other process keeps the two sides after the stop of the owner. After the
  # two stops, the two sides stop: the property NoOrphan.
  defp finish(model, system) do
    model =
      Enum.reduce(@procs, model, fn proc, model ->
        {model, _system} = step({:proc_stop, proc}, model, system)
        model
      end)

    state = SpecModel.to_map(model)
    assert state["running"] == %{"readable" => false, "writable" => false}
    refute Process.alive?(system.pids["readable"]) or Process.alive?(system.pids["writable"])
  end

  # ---------------------------------------------------------------------------
  # The hidden steps
  # ---------------------------------------------------------------------------

  # Finds the states that the steps of the operation, in their sequence,
  # and the hidden steps before and between and after them give from the
  # model. The processes of the system are at rest, thus each message
  # arrived, and each timer fired. Returns a state that has the state of the
  # real sides, with no message in the inboxes, and with no timer step that
  # the specification permits.
  defp follow(model, system, steps \\ []) do
    await_rest(system)
    observed = observe(system)

    states =
      for {state, []} <- reachable({model, steps}),
          inbox_length(state) == 0 and matches?(state, observed),
          do: state

    case Enum.reject(states, &timer_step?/1) do
      [state | _others] ->
        state

      [] when states == [] ->
        flunk(
          "the specification permits no state of the real sides: " <>
            "#{inspect(observed)}, from #{inspect(SpecModel.to_map(model))} " <>
            "with the steps #{inspect(steps)}"
        )

      [] ->
        flunk("the sides did not do a timer step: #{inspect(SpecModel.to_map(hd(states)))}")
    end
  end

  defp timer_step?(model),
    do: Enum.any?(@timers, fn {action, args} -> SpecModel.enabled?(model, action, args) end)

  # The processes of the system are at rest when two looks at them see the
  # same processes, each one waiting with an empty queue, and with the same
  # number of reductions: no process ran between the two looks. One look is
  # not sufficient: it sees the processes one after the other, and a message
  # can be on its way from a process that it saw to a process that it saw
  # before. The processes of the system have the group leader of the
  # system, as in the bridge of the WPT runner. The wait has no time limit.
  defp await_rest(system), do: await_rest(system, nil)

  defp await_rest(system, previous) do
    current = look(system.group)

    unless current != nil and current == previous do
      Process.sleep(1)
      await_rest(system, current)
    end
  end

  @at_rest [:group_leader, :status, :message_queue_len, :reductions]

  # The reductions of each process of the system, or `nil` when a process
  # runs or has a message.
  defp look(group) do
    Enum.reduce_while(Process.list(), %{}, fn pid, snapshot ->
      case Process.info(pid, @at_rest) do
        [group_leader: ^group, status: :waiting, message_queue_len: 0, reductions: reductions] ->
          {:cont, Map.put(snapshot, pid, reductions)}

        [{:group_leader, ^group} | _busy] ->
          {:halt, nil}

        _other ->
          {:cont, snapshot}
      end
    end)
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
