defmodule Web.PerformanceTest do
  use ExUnit.Case, async: true

  doctest Web.Performance

  test "put_time_origin sets the baseline used by now" do
    now_us = :erlang.monotonic_time(:microsecond)
    assert :ok = Web.Performance.put_time_origin(now_us - 2_500)

    measured = Web.Performance.now()

    assert is_float(measured)
    assert measured >= 2.0
    assert measured < 250.0
  end

  test "now is monotonic and float-based" do
    Web.Performance.put_time_origin()
    start_ms = Web.Performance.now()
    Process.sleep(5)
    stop_ms = Web.Performance.now()

    assert is_float(start_ms)
    assert stop_ms > start_ms
  end

  test "mark, measure, and entry lookup APIs store process-local user timing entries" do
    Web.Performance.clearMarks()
    Web.Performance.clearMeasures()

    mark = Web.Performance.mark("start")
    Process.sleep(2)
    measure = Web.Performance.measure("elapsed", "start")

    assert %Web.Performance.Mark{name: "start", entryType: "mark"} = mark
    assert mark.duration == 0.0
    assert %Web.Performance.Measure{name: "elapsed", entryType: "measure"} = measure
    assert measure.duration >= 0.0
    assert measure.startTime == mark.startTime

    assert [^mark, ^measure] = Web.Performance.getEntries()
    assert [^mark] = Web.Performance.getEntriesByType("mark")
    assert [^measure] = Web.Performance.getEntriesByType(:measure)
    assert [^mark] = Web.Performance.getEntriesByName(:start)
    assert [^measure] = Web.Performance.getEntriesByName("elapsed")
  end

  test "clear helpers remove matching entries without disturbing the other entry type" do
    Web.Performance.clearMarks()
    Web.Performance.clearMeasures()

    _first = Web.Performance.mark("first")
    second = Web.Performance.mark("second")
    measure = Web.Performance.measure("window", "first", "second")

    Web.Performance.clearMarks("first")
    assert [^second] = Web.Performance.getEntriesByType("mark")
    assert [^measure] = Web.Performance.getEntriesByType("measure")

    Web.Performance.clearMeasures()
    assert [] = Web.Performance.getEntriesByType("measure")

    Web.Performance.clearMarks()
    assert [] = Web.Performance.getEntries()
  end

  test "measure uses time origin and current time defaults when marks are omitted" do
    Web.Performance.clearMarks()
    Web.Performance.clearMeasures()
    Web.Performance.put_time_origin(:erlang.monotonic_time(:microsecond) - 5_000)

    measure = Web.Performance.measure("boot")

    assert %Web.Performance.Measure{name: "boot"} = measure
    assert measure.startTime == 0.0
    assert measure.duration >= 4.0
  end

  test "measure raises for unknown or non-mark references" do
    Web.Performance.clearMarks()
    Web.Performance.clearMeasures()
    Web.Performance.measure("baseline")

    assert_raise ArgumentError, ~r/unknown performance mark/, fn ->
      Web.Performance.measure("missing-window", "missing")
    end

    assert_raise ArgumentError, ~r/cannot measure from entry/, fn ->
      Web.Performance.measure("bad-window", "baseline")
    end
  end

  test "time_origin and camelCase aliases expose the same stored data" do
    Web.Performance.clearMarks()
    Web.Performance.clearMeasures()

    origin_us = :erlang.monotonic_time(:microsecond) - 3_000
    assert :ok = Web.Performance.put_time_origin(origin_us)
    assert Web.Performance.time_origin() <= Web.Performance.now() + Web.Performance.time_origin()

    mark = Web.Performance.mark(:alias_start)
    measure = Web.Performance.measure(:alias_measure, :alias_start)

    assert [^mark, ^measure] = Web.Performance.getEntries()
    assert [^mark] = Web.Performance.getEntriesByType(:mark)
    assert [^measure] = Web.Performance.getEntriesByName(:alias_measure)

    assert :ok = Web.Performance.clearMeasures(:alias_measure)
    assert [] = Web.Performance.getEntriesByType("measure")

    assert :ok = Web.Performance.clearMarks(:alias_start)
    assert [] = Web.Performance.getEntries()
  end
end
