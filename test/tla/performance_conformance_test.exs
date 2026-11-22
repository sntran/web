defmodule Web.TLA.PerformanceConformanceTest do
  # Compares the real `Web.Performance` with the specification
  # `tla/Performance.tla`.
  #
  # The test makes a random list of calls. It does each call on the real
  # module and on the specification, and it compares the entries.
  #
  # The clock of the specification is a counter. The test gives the same
  # numbers to the times that the real calls read, in their sequence.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Performance
  alias Web.Test.SpecModel

  @names ["a", "b"]
  @constants [{"MaxClock = 3", "MaxClock = 40"}, {"MaxEntries = 3", "MaxEntries = 40"}]

  defp command do
    name = member_of(@names)
    moment = member_of(["none" | @names])

    frequency([
      {4, tuple({constant("Mark"), name})},
      {4, tuple({constant("Measure"), name, moment, moment})},
      {1, tuple({constant("ClearMarks"), moment})},
      {1, tuple({constant("ClearMeasures"), moment})}
    ])
  end

  property "the module does each call as the specification permits" do
    check all(commands <- list_of(command(), max_length: 25), max_runs: 150) do
      Performance.clear_marks()
      Performance.clear_measures()

      Enum.reduce(commands, {SpecModel.start("Performance", @constants), []}, fn
        command, {model, samples} ->
          [action | args] = Tuple.to_list(command)
          model = SpecModel.step!(model, action, args)
          samples = samples ++ call(command, SpecModel.get(model, "last"), samples)

          assert entries(samples) == expected(model), "after #{inspect(command)}"
          {model, samples}
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # The real module
  # ---------------------------------------------------------------------------

  # Does the call, and returns the times that it read from the clock.
  defp call({"Mark", name}, _last, samples) do
    wait_for_new_time(samples)
    [Performance.mark(name).start_time]
  end

  defp call({"Measure", name, from, to}, %{"ok" => true}, samples) do
    wait_for_new_time(samples)
    measure = Performance.measure(name, moment(from), moment(to))
    if to == "none", do: [measure.start_time + measure.duration], else: []
  end

  defp call({"Measure", name, from, to}, %{"ok" => false}, _samples) do
    exception =
      assert_raise Web.DOMException, fn -> Performance.measure(name, moment(from), moment(to)) end

    assert exception.name == "SyntaxError"
    []
  end

  defp call({"ClearMarks", name}, _last, _samples) do
    :ok = Performance.clear_marks(moment(name))
    []
  end

  defp call({"ClearMeasures", name}, _last, _samples) do
    :ok = Performance.clear_measures(moment(name))
    []
  end

  defp moment("none"), do: nil
  defp moment(name), do: name

  # Each call that reads the clock gets a time after the last one.
  defp wait_for_new_time([]), do: :ok

  defp wait_for_new_time(samples) do
    if Performance.now() > List.last(samples), do: :ok, else: wait_for_new_time(samples)
  end

  # The real entries, with the numbers of the clock of the specification.
  defp entries(samples) do
    Enum.map(Performance.get_entries(), fn entry ->
      %{
        "name" => entry.name,
        "type" => entry.entry_type,
        "start" => clock(entry.start_time, samples),
        "finish" => clock(entry.start_time + entry.duration, samples)
      }
    end)
  end

  # The time origin is 0. The first time that a call read is 1.
  defp clock(time, _samples) when time == 0.0, do: 0

  defp clock(time, samples) do
    # The sum of a start and a duration can be different from the time in
    # its last digit.
    index = Enum.find_index(samples, &(abs(&1 - time) < 0.000_5))
    assert index != nil, "the time #{time} is not a time that a call read"
    index + 1
  end

  # The specification has the entries in the sequence of the calls. The
  # module gives them in the sequence of their start times.
  defp expected(model) do
    model
    |> SpecModel.get("entries")
    |> Enum.sort_by(& &1["start"])
  end
end
