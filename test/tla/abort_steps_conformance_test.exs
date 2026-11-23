defmodule Web.TLA.AbortStepsConformanceTest do
  # Compares the steps of the abort of a real `Web.AbortSignal` with the
  # specification `tla/AbortSteps.tla`.
  #
  # The test makes a random signal: with or without a listener, an abort
  # algorithm, and a dependent signal that runs or that stopped. It aborts
  # the signal in a random way, and compares the steps that the processes
  # see with the steps of the specification.
  #
  # Each step sends a message to the test, in the sequence of the steps:
  # the abort algorithm ("alg"), a first listener of the signal ("event"),
  # and a listener of the dependent signal ("dep_event"). The listener of
  # the specification is a second listener of the signal.
  #
  # The test sets the linger time for the application. Thus it cannot run at
  # the same time as other tests.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Web.AbortController
  alias Web.AbortSignal
  alias Web.EventTarget
  alias Web.Test.SpecModel

  @linger 15

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

  defp setup_step, do: member_of([:add_listener, :add_algorithm, :depend, :dep_expire])

  property "the abort does its steps as the specification permits" do
    check all(
            setup <- list_of(setup_step(), max_length: 5),
            mode <- member_of([:now, :later, :caller_stop, :again]),
            max_runs: 100
          ) do
      system = start_system()

      try do
        model = Enum.reduce(setup, SpecModel.start("AbortSteps"), &prepare(&1, &2, system))
        model = abort(mode, model, system)
        assert_stopped(model, system)
        assert_steps(model, if(mode in [:now, :again], do: 0, else: 2_000))
      after
        stop_system(system)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The real system
  # ---------------------------------------------------------------------------

  defp start_system do
    test = self()
    controller = AbortController.new()
    note = fn step -> fn -> send(test, {:step, step}) end end

    # The first listener tells the test that the event fires, and if the
    # dependent signal is aborted at that time.
    EventTarget.add_event_listener(controller.signal, "abort", fn ->
      send(test, {:step, "event"})
      dep = Process.get({__MODULE__, :dep})
      send(test, {:dep_aborted, dep && AbortSignal.aborted?(dep)})
      if Process.get({__MODULE__, :again}), do: :ok = AbortController.abort(controller, :again)
    end)

    %{controller: controller, signal: controller.signal, note: note}
  end

  defp stop_system(_system) do
    if maker = Process.delete({__MODULE__, :maker}), do: Process.exit(maker, :kill)
    Process.delete({__MODULE__, :dep})
    Process.delete({__MODULE__, :again})
  end

  defp prepare(:add_listener, model, system) do
    if SpecModel.enabled?(model, "AddListener") do
      EventTarget.add_event_listener(system.signal, "abort", system.note.(:heard))
      SpecModel.step!(model, "AddListener")
    else
      model
    end
  end

  defp prepare(:add_algorithm, model, system) do
    if SpecModel.enabled?(model, "AddAlgorithm") do
      :ok =
        AbortSignal.__add_algorithm__(system.signal, {Kernel, :send, [self(), {:step, "alg"}]})

      SpecModel.step!(model, "AddAlgorithm")
    else
      model
    end
  end

  # The maker of the dependent signal keeps it, and listens to it. The
  # system of the test is in the process dictionary: the maker and the
  # dependent signal are there.
  defp prepare(:depend, model, system) do
    if SpecModel.enabled?(model, "Depend") do
      test = self()
      maker = spawn(fn -> make_dependent(system.signal, test) end)
      assert_receive {:dependent, dep}
      Process.put({__MODULE__, :maker}, maker)
      Process.put({__MODULE__, :dep}, dep)
      SpecModel.step!(model, "Depend")
    else
      model
    end
  end

  # The maker stops: after the linger time, the dependent signal stops with
  # no abort, and the signal removes it.
  defp prepare(:dep_expire, model, system) do
    if SpecModel.enabled?(model, "DepExpire") do
      dep = Process.get({__MODULE__, :dep})
      monitor = Process.monitor(dep.pid)
      Process.exit(Process.get({__MODULE__, :maker}), :kill)
      assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 2_000
      eventually(fn -> :sys.get_state(system.signal.pid).dependents == [] end)
      Process.delete({__MODULE__, :dep})
      SpecModel.step!(model, "DepExpire")
    else
      model
    end
  end

  defp make_dependent(signal, test) do
    dep = AbortSignal.any([signal])
    EventTarget.add_event_listener(dep, "abort", fn -> send(test, {:step, "dep_event"}) end)
    send(test, {:dependent, dep})
    Process.sleep(:infinity)
  end

  # ---------------------------------------------------------------------------
  # The abort
  # ---------------------------------------------------------------------------

  defp abort(:now, model, system) do
    :ok = AbortController.abort(system.controller, :my_reason)
    model = model |> SpecModel.step!("Abort") |> settle()
    assert SpecModel.get(model, "returned")

    # The call returned after the steps: their messages are here.
    {:messages, messages} = Process.info(self(), :messages)
    steps = for {:step, step} <- messages, is_binary(step), do: step
    assert steps == SpecModel.get(model, "log")
    model
  end

  defp abort(:later, model, system) do
    :ok = AbortSignal.__signal_abort_later__(system.signal, :my_reason)

    # The signal is aborted when the call returns. A new process does the
    # steps.
    assert AbortSignal.aborted?(system.signal)
    model = SpecModel.step!(model, "AbortLater")
    assert SpecModel.get(model, "returned") and SpecModel.get(model, "aborted")
    settle(model)
  end

  # The process that aborts stops in a listener of the signal, after the
  # other listeners. The steps after the event do not come.
  defp abort(:caller_stop, model, system) do
    controller = system.controller

    {pid, monitor} =
      spawn_monitor(fn ->
        EventTarget.add_event_listener(controller.signal, "abort", fn ->
          Process.exit(self(), :kill)
        end)

        AbortController.abort(controller, :my_reason)
      end)

    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 2_000

    model =
      model
      |> SpecModel.step!("Abort")
      |> SpecModel.step!("Algorithms")
      |> SpecModel.step!("FireSignal")
      |> SpecModel.step!("CallerStop")

    refute SpecModel.get(model, "returned")
    model
  end

  # The first listener aborts the signal again: the second abort does
  # nothing.
  defp abort(:again, model, system) do
    Process.put({__MODULE__, :again}, true)
    :ok = AbortController.abort(system.controller, :my_reason)

    model =
      model
      |> SpecModel.step!("Abort")
      |> SpecModel.step!("Algorithms")
      |> SpecModel.step!("FireSignal")
      |> SpecModel.step!("AbortAgain")
      |> settle()

    assert AbortSignal.reason(system.signal) == :my_reason
    model
  end

  # The steps that the processes do with no command.
  defp settle(model) do
    SpecModel.settle(model, [
      {"Algorithms", []},
      {"FireSignal", []},
      {"FireDependent", []},
      {"Done", []}
    ])
  end

  # The messages of the steps are the steps of the specification, in the
  # same sequence. The test examines them after the stop of the processes:
  # thus no message of a step can come later. A step of a different process
  # can come late on a busy machine: the test waits `timeout` for it.
  defp assert_steps(model, timeout) do
    expected = SpecModel.get(model, "log")

    steps =
      for _step <- expected do
        receive do
          {:step, step} when is_binary(step) -> step
        after
          timeout -> :missing
        end
      end

    assert steps == expected

    refute Enum.any?(
             Process.info(self(), :messages) |> elem(1),
             &match?({:step, s} when is_binary(s), &1)
           )

    # The listener of the specification ran when its event fired.
    if SpecModel.get(model, "heard") do
      assert_receive {:step, :heard}, timeout
    else
      refute_received {:step, :heard}
    end

    # The dependent signal is aborted when the first listener runs. Only
    # the test process has the dependent signal in its dictionary.
    if "event" in expected do
      assert_receive {:dep_aborted, aborted?}, timeout
      assert aborted? in [nil, true]
    end
  end

  # The processes of the signals stop after the steps, or after the stop of
  # the process that does them.
  defp assert_stopped(model, system) do
    dep = Process.get({__MODULE__, :dep})
    assert_down(system.signal.pid)
    if dep, do: assert_down(dep.pid)

    model = SpecModel.settle(model, [{"SignalStop", []}, {"DepStop", []}])
    refute SpecModel.get(model, "running")
    assert SpecModel.get(model, "dep") in ["none", "stopped"]
  end

  defp assert_down(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 2_000
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end
end
