defmodule Web.TLA.AbortTimeoutsConformanceTest do
  # Compares the real signals of `Web.AbortSignal.timeout/1` with the
  # specification `tla/AbortTimeouts.tla`.
  #
  # The test process makes the timeouts. Their times are long: the timers
  # do not end during the test. The test sends the message of a timer
  # itself, when the clock of the specification permits it. Thus no time
  # limit is in the test.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.AbortSignal
  alias Web.EventTarget
  alias Web.Test.SpecModel

  # A time of the specification, in milliseconds.
  @unit 1_000_000_000

  defp command do
    frequency([
      {3, tuple({constant(:make), member_of([1, 2])})},
      {2, constant(:tick)},
      {4, tuple({constant(:fire), member_of([1, 2])})},
      {1, tuple({constant(:drop), member_of([1, 2])})}
    ])
  end

  property "the timeouts abort in the sequence that the specification permits" do
    check all(commands <- list_of(command(), max_length: 12), max_runs: 100) do
      {model, signals} =
        Enum.reduce(commands, {SpecModel.start("AbortTimeouts"), %{}}, fn command,
                                                                          {model, signals} ->
          {model, signals} = run(command, model, signals)
          model = settle(model, signals)
          assert_same_state(model, signals)
          {model, signals}
        end)

      # The timeouts that the test did not end stop.
      for {_t, signal} <- signals, do: Process.exit(signal.pid, :kill)
      _ = model
    end
  end

  defp run({:make, ms}, model, signals) do
    t = map_size(signals) + 1

    if SpecModel.enabled?(model, "Make", [t, ms]) do
      signal = AbortSignal.timeout(ms * @unit)
      test = self()
      EventTarget.add_event_listener(signal, "abort", fn -> send(test, {:event, t}) end)
      {SpecModel.step!(model, "Make", [t, ms]), Map.put(signals, t, signal)}
    else
      {model, signals}
    end
  end

  defp run(:tick, model, signals) do
    if SpecModel.enabled?(model, "Tick"),
      do: {SpecModel.step!(model, "Tick"), signals},
      else: {model, signals}
  end

  # The time of timeout t is complete: the timer sends its message.
  defp run({:fire, t}, model, signals) do
    if SpecModel.enabled?(model, "Fire", [t]) do
      send(signals[t].pid, {:abort_signal_timeout, {:timeout, t}})
      {SpecModel.step!(model, "Fire", [t]), signals}
    else
      {model, signals}
    end
  end

  # The signal of timeout t has no use and stops with no abort.
  defp run({:drop, t}, model, signals) do
    if SpecModel.enabled?(model, "Drop", [t]) do
      pid = signals[t].pid
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
      {SpecModel.step!(model, "Drop", [t]), signals}
    else
      {model, signals}
    end
  end

  # The steps that the processes do with no command: the abort of a
  # timeout whose earlier timeouts stopped, and the stop after the abort.
  # The events of the real signals come in their sequence: the
  # specification must permit the abort of each one at its time.
  defp settle(model, signals) do
    if Enum.any?(Map.keys(signals), &SpecModel.enabled?(model, "Run", [&1])) do
      t =
        receive do
          {:event, t} -> t
        after
          2_000 -> flunk("no timeout aborted, but the specification permits an abort")
        end

      assert SpecModel.enabled?(model, "Run", [t]),
             "the timeout #{t} aborted, but the specification has #{inspect(SpecModel.to_map(model))}"

      assert AbortSignal.reason(signals[t]) == {:timeout, t}
      pid = signals[t].pid
      monitor = Process.monitor(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 2_000

      model |> SpecModel.step!("Run", [t]) |> SpecModel.step!("Stop", [t]) |> settle(signals)
    else
      model
    end
  end

  # A timeout that waits does not abort: no event comes. The signal of each
  # timeout that did not stop is alive.
  defp assert_same_state(model, signals) do
    # A function on 1..N is a sequence in TLA+.
    state = SpecModel.get(model, "state")
    refute_received {:event, _t}

    for {t, signal} <- signals do
      case Enum.at(state, t - 1) do
        "stopped" -> refute Process.alive?(signal.pid)
        "waiting" -> refute AbortSignal.aborted?(signal)
        "pending" -> refute AbortSignal.aborted?(signal)
      end
    end
  end
end
