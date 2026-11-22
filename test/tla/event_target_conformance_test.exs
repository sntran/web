defmodule Web.TLA.EventTargetConformanceTest do
  # Compares the listener steps of each kind of event target with the
  # specification `tla/EventTarget.tla`: a target of `Web.EventTarget.new/0`,
  # a signal, a message port, and a broadcast channel.
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
  # A listener can dispatch a new event to its target. The listeners of
  # that event only write their names: the specification gives the
  # sequence of their calls in one step.
  #
  # Only a target of `new/0` has the lifetime of the specification. A signal
  # removes the listeners of a process that stopped, and a store of a port
  # or a channel keeps them: the test stops a process only for the targets
  # that remove its listeners.
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
  @options {__MODULE__, :options}

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
      {1, constant(:nested_new)},
      {2, constant(:cancel)},
      {2, constant(:none)}
    ])
  end

  defp command(kind) do
    common = [
      {2, constant({:add, :p1, "l1"})},
      {3, tuple({constant(:add), constant(:main), listener()})},
      {2, tuple({constant(:remove), listener()})},
      {5, tuple({constant(:dispatch), list_of(in_call(), max_length: 4)})},
      {1, constant(:dispatch_raw)}
    ]

    lifetime =
      case kind do
        :new -> [{1, constant(:proc_stop)}, {1, constant(:owner_stop)}, {1, constant(:pause)}]
        :signal -> [{1, constant(:proc_stop)}]
        _port_or_channel -> []
      end

    frequency(common ++ lifetime)
  end

  # With capture, l2 runs in the capturing pass, and l1 in the bubbling
  # pass. With no capture, the two listeners run in one pass: a listener
  # can remove the other one before its call. With passive, l2 cannot
  # cancel the event.
  property "each target and its dispatch do each step as the specification permits" do
    check all(
            kind <- member_of([:new, :signal, :port, :channel]),
            capture <- boolean(),
            passive <- boolean(),
            commands <- list_of(command(kind), max_length: 14),
            max_runs: 160
          ) do
      system = start_system(kind, capture, passive)

      config =
        Enum.reject(
          [
            if(not capture, do: {"Capture = {l2}", "Capture = {}"}),
            if(not passive, do: {"Passive = {l2}", "Passive = {}"})
          ],
          &is_nil/1
        )

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

  defp start_system(kind, capture, passive) do
    Process.put(@options, %{capture: capture, passive: passive})
    test = self()

    owner =
      spawn(fn ->
        send(test, {:target, make_target(kind)})
        Process.sleep(:infinity)
      end)

    assert_receive {:target, target}
    p1 = spawn(fn -> proc(target) end)
    %{kind: kind, owner: owner, target: target, p1: p1}
  end

  defp make_target(:new), do: EventTarget.new()
  defp make_target(:signal), do: Web.AbortController.new().signal
  defp make_target(:port), do: Web.MessageChannel.new().port2

  defp make_target(:channel),
    do: Web.BroadcastChannel.new("conformance-#{System.unique_integer([:positive])}")

  defp stop_system(system) do
    Process.exit(system.owner, :kill)
    Process.exit(system.p1, :kill)
    Process.delete(@key)
    Process.delete(@options)
  end

  # The process that keeps the listeners.
  defp store(%{kind: :new, target: target}), do: target.pid
  defp store(%{kind: :signal, target: signal}), do: signal.pid
  defp store(%{target: handle}), do: :sys.get_state(handle.address).target.store

  # The process p1 adds the listener l1 on request.
  defp proc(target) do
    receive do
      {:add, from} ->
        add(target, "l1")
        send(from, {:added, self()})
        proc(target)
    end
  end

  # The listeners: l1 has once, and l2 can have capture and passive. A
  # remote function is the same callback in each process. Only the test
  # process adds l2.
  defp add(target, "l1"),
    do: EventTarget.add_event_listener(target, "x", &__MODULE__.l1/1, once: true)

  defp add(target, "l2") do
    %{capture: capture, passive: passive} = Process.get(@options)

    EventTarget.add_event_listener(target, "x", &__MODULE__.l2/1,
      capture: capture,
      passive: passive
    )
  end

  defp remove(target, "l1"), do: EventTarget.remove_event_listener(target, "x", &__MODULE__.l1/1)

  defp remove(target, "l2"),
    do:
      EventTarget.remove_event_listener(
        target,
        "x",
        &__MODULE__.l2/1,
        Process.get(@options).capture
      )

  @doc false
  def l1(event), do: called("l1", event)

  @doc false
  def l2(event), do: called("l2", event)

  # ---------------------------------------------------------------------------
  # The dispatch
  # ---------------------------------------------------------------------------

  # A listener runs. In the dispatch of a new event of a listener, it only
  # writes its name. Else the specification goes to its next call, and the
  # listener does its action of the script.
  defp called(name, event) do
    case Process.get(@key) do
      %{inner: inner} = run when is_list(inner) ->
        Process.put(@key, %{run | inner: [name | inner]})

      %{model: model, script: script, target: target} = run ->
        model = to_next_call(model)

        case SpecModel.get(model, "in_call") do
          ^name ->
            {action, script} = List.pop_at(script, 0, :none)
            Process.put(@key, %{run | model: model, script: script})
            model = model |> act(action, target, event) |> SpecModel.step!("Return")
            Process.put(@key, %{Process.get(@key) | model: model})

          other ->
            note_difference({:called, name, other})
        end
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

  # A dispatch of a new event in the dispatch runs to its end.
  defp act(model, :nested_new, target, _event) do
    Process.put(@key, %{Process.get(@key) | inner: []})
    {_target, true} = EventTarget.dispatch_event(target, Event.new("x"))
    %{inner: inner} = run = Process.get(@key)
    Process.put(@key, %{run | inner: nil})

    model = SpecModel.step!(model, "NestedNew")
    expected = SpecModel.get(model, "inner")
    if Enum.reverse(inner) != expected, do: note_difference({:inner, inner, expected})
    model
  end

  # The listener cancels the event: the flag tells if a listener canceled
  # it.
  defp act(model, :cancel, _target, event) do
    :ok = Event.prevent_default(event)
    model = SpecModel.step!(model, "Cancel")
    canceled = SpecModel.get(model, "cancels") != MapSet.new()

    if Event.default_prevented?(event) != canceled,
      do: note_difference({:canceled, Event.default_prevented?(event), canceled})

    model
  end

  defp act(model, :none, _target, _event), do: model

  defp run({:dispatch, script}, model, system) do
    model = SpecModel.step!(model, "Begin")

    Process.put(@key, %{
      model: model,
      script: script,
      target: system.target,
      inner: nil,
      differences: []
    })

    event = Event.new("x", cancelable: true)
    _log = capture_log(fn -> send(self(), EventTarget.dispatch_event(system.target, event)) end)
    assert_received {_target, result}

    %{model: model, differences: differences} = Process.delete(@key)
    assert differences == []

    # The rest of the dispatch calls no listener.
    model = to_next_call(model)
    assert SpecModel.get(model, "in_call") == "none"
    model = SpecModel.step!(model, "End")
    assert to_string(result) == SpecModel.get(model, "result")
    model
  end

  # An event that is not initialized raises an error, and calls no
  # listener.
  defp run(:dispatch_raw, model, system) do
    Process.put(@key, %{
      model: model,
      script: [],
      target: system.target,
      inner: nil,
      differences: []
    })

    error = catch_error(EventTarget.dispatch_event(system.target, %Event{type: "x"}))
    assert %Web.DOMException{name: "InvalidStateError"} = error
    assert %{differences: []} = Process.delete(@key)
    SpecModel.step!(model, "BeginRaw")
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

  # The store gets the stop of p1 from the system: the test waits until the
  # store removed its listeners.
  defp await_removal(model, system) do
    if SpecModel.get(model, "running"),
      do: eventually(fn -> real_list(system) == expected_list(model, system) end)

    model
  end

  # The linger time of a target of `new/0` can be complete at this moment.
  defp follow_stop(model, %{kind: :new} = system) do
    if not Process.alive?(system.target.pid) and SpecModel.get(model, "running") and
         SpecModel.enabled?(model, "Expire"),
       do: SpecModel.step!(model, "Expire"),
       else: model
  end

  defp follow_stop(model, _system), do: model

  # ---------------------------------------------------------------------------
  # The comparison of the two states
  # ---------------------------------------------------------------------------

  defp assert_same_state(model, system) do
    state = SpecModel.to_map(model)
    assert Process.alive?(store(system)) == state["running"], inspect(state)
    if state["running"], do: assert(real_list(system) == expected_list(model, system))
  end

  # The listeners of the store, with their owners, in their sequence.
  defp real_list(system) do
    for entry <- :sys.get_state(store(system)).listeners.entries do
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
