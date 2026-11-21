defmodule Web.TLA.EventTargetConformanceTest do
  # Compares a real target of `Web.EventTarget.new/0` with the specification
  # `tla/EventTarget.tla`.
  #
  # The test makes a random list of operations. It does each operation on a
  # real target and on the specification, and it compares the two states.
  #
  # The test process is Main: it dispatches the events, and the listeners
  # run in it. Each call of a listener does the next steps of the dispatch
  # on the specification, until the specification calls a listener: that
  # listener must be the listener that runs. The listener then does its
  # actions of the script on the real target and on the specification. The
  # dispatch catches an error of a listener, thus a listener writes a
  # difference in the process dictionary, and the test examines it after
  # the dispatch.
  #
  # The test sets the linger time for the application. Thus it cannot run at
  # the same time as other tests.
  use ExUnit.Case, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Web.Event
  alias Web.EventTarget
  alias Web.Test.SpecModel

  @linger 15
  @listeners ["l1", "l2"]
  @key {__MODULE__, :run}

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

  defp listener, do: member_of(@listeners)

  defp in_call do
    frequency([
      {2, tuple({constant(:add), listener()})},
      {2, tuple({constant(:remove), listener()})},
      {1, constant(:nested)},
      {2, constant(:none)}
    ])
  end

  defp command do
    frequency([
      {2, constant({:add, :p1, "l1"})},
      {3, tuple({constant(:add), constant(:main), listener()})},
      {2, tuple({constant(:remove), listener()})},
      {5, tuple({constant(:dispatch), list_of(in_call(), max_length: 4)})},
      {1, constant(:proc_stop)},
      {1, constant(:owner_stop)},
      {1, constant(:pause)}
    ])
  end

  # With capture, l2 runs in the capturing pass, and l1 in the bubbling
  # pass. With no capture, the two listeners run in one pass: a listener
  # can remove the other one before its call.
  property "the target and the dispatch do each step as the specification permits" do
    check all(
            capture <- boolean(),
            commands <- list_of(command(), max_length: 14),
            max_runs: 100
          ) do
      system = start_system(capture)
      config = if capture, do: nil, else: {"Capture = {l2}", "Capture = {}"}

      try do
        Enum.reduce(commands, SpecModel.start("EventTarget", config), fn command, model ->
          model = command |> run(model, system) |> follow_stop(system)
          assert_same_state(model, system)
          model
        end)
      after
        stop_system(system)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The real system: the owner of the target, and the process p1
  # ---------------------------------------------------------------------------

  defp start_system(capture) do
    Process.put({__MODULE__, :capture}, capture)
    test = self()

    owner =
      spawn(fn ->
        send(test, {:target, EventTarget.new()})
        Process.sleep(:infinity)
      end)

    assert_receive {:target, target}
    p1 = spawn(fn -> proc(target) end)
    %{owner: owner, target: target, p1: p1}
  end

  defp stop_system(system) do
    Process.exit(system.owner, :kill)
    Process.exit(system.p1, :kill)
    Process.delete(@key)
    Process.delete({__MODULE__, :capture})
  end

  # The process p1 adds the listener l1 on request.
  defp proc(target) do
    receive do
      {:add, from} ->
        add(target, "l1")
        send(from, {:added, self()})
        proc(target)
    end
  end

  # The listeners: l1 has once, and l2 can have capture. A remote function
  # is the same callback in each process. Only the test process adds l2.
  defp add(target, "l1"),
    do: EventTarget.add_event_listener(target, "x", &__MODULE__.l1/1, once: true)

  defp add(target, "l2"),
    do: EventTarget.add_event_listener(target, "x", &__MODULE__.l2/1, capture: capture())

  defp remove(target, "l1"), do: EventTarget.remove_event_listener(target, "x", &__MODULE__.l1/1)

  defp remove(target, "l2"),
    do: EventTarget.remove_event_listener(target, "x", &__MODULE__.l2/1, capture: capture())

  defp capture, do: Process.get({__MODULE__, :capture}, false)

  @doc false
  def l1(event), do: called("l1", event)

  @doc false
  def l2(event), do: called("l2", event)

  # ---------------------------------------------------------------------------
  # The dispatch
  # ---------------------------------------------------------------------------

  # A listener runs: the specification goes to its next call, and the
  # listener does its action of the script.
  defp called(name, event) do
    %{model: model, script: script, target: target} = run = Process.get(@key)
    model = to_next_call(model)

    case SpecModel.get(model, "in_call") do
      ^name ->
        {action, script} = List.pop_at(script, 0, :none)
        model = model |> act(action, target, event) |> SpecModel.step!("Return")
        Process.put(@key, %{run | model: model, script: script})

      other ->
        note_difference({:called, name, other})
    end
  end

  defp note_difference(difference) do
    run = Process.get(@key)
    Process.put(@key, %{run | differences: [difference | run.differences]})
  end

  # The model value of a listener.
  defp l("l1"), do: :l1
  defp l("l2"), do: :l2

  # The steps of the specification up to its next call of a listener.
  defp to_next_call(model) do
    cond do
      SpecModel.get(model, "in_call") != "none" ->
        model

      SpecModel.enabled?(model, "Visit") ->
        model |> SpecModel.step!("Visit") |> to_next_call()

      SpecModel.enabled?(model, "NextPass") ->
        model |> SpecModel.step!("NextPass") |> to_next_call()

      true ->
        model
    end
  end

  defp act(model, {:add, name}, target, _event) do
    if SpecModel.enabled?(model, "Add", [:main, l(name)]) do
      add(target, name)
      SpecModel.step!(model, "Add", [:main, l(name)])
    else
      model
    end
  end

  defp act(model, {:remove, name}, target, _event) do
    if SpecModel.enabled?(model, "Remove", [l(name)]) do
      remove(target, name)
      SpecModel.step!(model, "Remove", [l(name)])
    else
      model
    end
  end

  # A dispatch of the same event in its dispatch raises an error.
  defp act(model, :nested, target, event) do
    case catch_error(EventTarget.dispatch_event(target, event)) do
      %Web.DOMException{name: "InvalidStateError"} -> :ok
      other -> note_difference({:nested, other})
    end

    SpecModel.step!(model, "Nested")
  end

  defp act(model, :none, _target, _event), do: model

  defp run({:dispatch, script}, model, system) do
    model = SpecModel.step!(model, "Begin")
    Process.put(@key, %{model: model, script: script, target: system.target, differences: []})

    _log = capture_log(fn -> EventTarget.dispatch_event(system.target, Event.new("x")) end)

    %{model: model, differences: differences} = Process.delete(@key)
    assert differences == []

    # The rest of the dispatch calls no listener.
    model = to_next_call(model)
    assert SpecModel.get(model, "in_call") == "none"
    SpecModel.step!(model, "End")
  end

  # ---------------------------------------------------------------------------
  # The other operations
  # ---------------------------------------------------------------------------

  defp run({:add, :p1, name}, model, system) do
    if SpecModel.enabled?(model, "Add", [:p1, l(name)]) do
      send(system.p1, {:add, self()})
      assert_receive {:added, _p1}
      SpecModel.step!(model, "Add", [:p1, l(name)])
    else
      model
    end
  end

  defp run({:add, :main, name}, model, system) do
    if SpecModel.enabled?(model, "Add", [:main, l(name)]) do
      add(system.target, name)
      SpecModel.step!(model, "Add", [:main, l(name)])
    else
      model
    end
  end

  defp run({:remove, name}, model, system) do
    if SpecModel.enabled?(model, "Remove", [l(name)]) do
      remove(system.target, name)
      SpecModel.step!(model, "Remove", [l(name)])
    else
      model
    end
  end

  defp run(:proc_stop, model, system) do
    if SpecModel.enabled?(model, "ProcStop", [:p1]) do
      monitor = Process.monitor(system.p1)
      Process.exit(system.p1, :kill)
      assert_receive {:DOWN, ^monitor, :process, _pid, :killed}
      model |> SpecModel.step!("ProcStop", [:p1]) |> await_removal(system)
    else
      model
    end
  end

  # The store gets the stop of p1 from the system: the test waits until the
  # store removed its listeners.
  defp await_removal(model, system) do
    if SpecModel.get(model, "running"),
      do: eventually(fn -> real_list(system) == expected_list(model, system) end)

    model
  end

  defp run(:owner_stop, model, system) do
    if SpecModel.enabled?(model, "OwnerStop") do
      Process.exit(system.owner, :kill)
      SpecModel.step!(model, "OwnerStop")
    else
      model
    end
  end

  # The test waits for more than the linger time. After that time, the store
  # stopped if, and only if, the specification permits the step Expire.
  defp run(:pause, model, system) do
    Process.sleep(3 * @linger)

    if SpecModel.enabled?(model, "Expire") do
      monitor = Process.monitor(system.target.pid)

      assert_receive {:DOWN, ^monitor, :process, _pid, _reason},
                     2_000,
                     "the target did not stop after the linger time"

      SpecModel.step!(model, "Expire")
    else
      model
    end
  end

  # The linger time can be complete at this moment.
  defp follow_stop(model, system) do
    if not Process.alive?(system.target.pid) and SpecModel.get(model, "running") and
         SpecModel.enabled?(model, "Expire"),
       do: SpecModel.step!(model, "Expire"),
       else: model
  end

  # ---------------------------------------------------------------------------
  # The comparison of the two states
  # ---------------------------------------------------------------------------

  defp assert_same_state(model, system) do
    state = SpecModel.to_map(model)
    assert Process.alive?(system.target.pid) == state["running"], inspect(state)
    if state["running"], do: assert(real_list(system) == expected_list(model, system))
  end

  # The listeners of the store, with their owners, in their sequence.
  defp real_list(system) do
    for entry <- :sys.get_state(system.target.pid).listeners.entries do
      name = if entry.callback == (&__MODULE__.l1/1), do: "l1", else: "l2"
      {name, entry.owner}
    end
  end

  defp expected_list(model, system) do
    owners = SpecModel.get(model, "owner")

    for name <- SpecModel.get(model, "list") do
      {name, if(owners[name] == "p1", do: system.p1, else: self())}
    end
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end
end
