defmodule Web.PerformanceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.DOMException
  alias Web.Performance
  alias Web.Performance.Mark
  alias Web.Performance.Measure

  doctest Web.Performance

  # The entries are the state of the test process.
  setup do
    Performance.clear_marks()
    Performance.clear_measures()
  end

  defp names(entries), do: Enum.map(entries, & &1.name)

  # ---------------------------------------------------------------------------
  # Time
  # ---------------------------------------------------------------------------

  describe "time" do
    test "now is a float of milliseconds that does not go back" do
      # The sleep makes the time between the two calls. The test also
      # measures that time in microseconds. A busy machine can make the
      # sleep long, thus that measurement is the upper limit.
      started_us = :erlang.monotonic_time(:microsecond)
      first = Performance.now()
      Process.sleep(5)
      second = Performance.now()
      elapsed_us = :erlang.monotonic_time(:microsecond) - started_us

      assert is_float(first)
      assert first >= 0.0
      assert second - first >= 5.0
      assert round((second - first) * 1000) <= elapsed_us
    end

    test "the time origin and now give the time of the system" do
      assert is_float(Performance.time_origin())
      assert Performance.time_origin() == Performance.timeOrigin()

      from_origin = Performance.time_origin() + Performance.now()
      system = System.os_time(:microsecond) / 1000.0

      # The time origin is a time of Unix, not a value of the monotonic
      # clock.
      assert Performance.time_origin() > 1_600_000_000_000.0
      assert_in_delta from_origin, system, 5_000.0
    end

    test "to_json has the time origin" do
      assert Performance.to_json() == %{"timeOrigin" => Performance.time_origin()}
      assert Performance.toJSON() == Performance.to_json()
    end
  end

  # ---------------------------------------------------------------------------
  # Marks
  # ---------------------------------------------------------------------------

  describe "mark" do
    test "makes an entry at the time now" do
      before = Performance.now()
      mark = Performance.mark("start")
      later = Performance.now()

      assert %Mark{name: "start", entryType: "mark", duration: +0.0, detail: nil} = mark
      assert mark.startTime >= before and mark.startTime <= later
      assert Performance.get_entries() == [mark]
    end

    test "a name that is an atom or a number becomes a string" do
      assert Performance.mark(:atom).name == "atom"
      assert Performance.mark(42).name == "42"

      assert_raise Web.TypeError, ~r/A name must be a string/, fn ->
        Performance.mark({:not, :a_name})
      end
    end

    test "the option :start_time gives the time of the mark" do
      assert Performance.mark("early", start_time: 12.5).startTime == 12.5
      assert Performance.mark("integer", start_time: 3).startTime === 3.0

      assert_raise Web.TypeError, ~r/not below zero/, fn ->
        Performance.mark("negative", start_time: -1)
      end

      assert_raise Web.TypeError, fn -> Performance.mark("text", start_time: "soon") end
      assert names(Performance.get_entries()) == ["integer", "early"]
    end

    test "the option :detail keeps a structured clone" do
      buffer = Web.ArrayBuffer.new("bytes")
      mark = Performance.mark("with detail", detail: %{buffer: buffer, step: 1})

      assert mark.detail.step == 1
      assert Web.ArrayBuffer.data(mark.detail.buffer) == "bytes"
      refute mark.detail.buffer.id == buffer.id

      exception =
        assert_raise DOMException, fn -> Performance.mark("bad detail", detail: self()) end

      assert exception.name == "DataCloneError"
      assert names(Performance.get_entries()) == ["with detail"]
    end

    test "options that are not correct raise TypeError" do
      assert_raise Web.TypeError, ~r/Unknown options: \[:start\]/, fn ->
        Performance.mark("m", start: 1)
      end

      assert_raise Web.TypeError, ~r/keyword list/, fn -> Performance.mark("m", [1, 2]) end
    end
  end

  # ---------------------------------------------------------------------------
  # Measures
  # ---------------------------------------------------------------------------

  describe "measure" do
    test "with only a name is from the time origin to now" do
      before = Performance.now()
      measure = Performance.measure("all")

      assert %Measure{name: "all", entryType: "measure", startTime: +0.0, detail: nil} = measure
      assert measure.duration >= before
      assert measure.duration <= Performance.now()
    end

    test "with a start mark is from the mark to now" do
      mark = Performance.mark("start")
      Process.sleep(3)
      measure = Performance.measure("elapsed", "start")

      assert measure.startTime == mark.startTime
      assert measure.duration >= 3.0
      assert measure.duration <= Performance.now() - mark.startTime
    end

    test "with two marks is the time between them" do
      Performance.mark("a", start_time: 10)
      Performance.mark("b", start_time: 25)

      measure = Performance.measure("a to b", "a", "b")
      assert {measure.startTime, measure.duration} == {10.0, 15.0}

      # The end can be before the start.
      assert Performance.measure("b to a", "b", "a").duration == -15.0

      # With no start mark, the measure starts at the time origin.
      assert %Measure{startTime: +0.0, duration: 25.0} = Performance.measure("to b", nil, "b")
    end

    test "uses the mark that was made last with a name" do
      Performance.mark("step", start_time: 50)
      Performance.mark("step", start_time: 20)

      assert Performance.measure("from step", "step", "step").startTime == 20.0
    end

    test "finds a mark when a measure has the same name" do
      Performance.mark("same", start_time: 5)
      Performance.measure("same", "same")

      assert Performance.measure("again", "same").startTime == 5.0
    end

    test "a mark that does not exist raises SyntaxError, and adds no entry" do
      Performance.measure("only a measure")

      for arguments <- [["m", "missing"], ["m", nil, "missing"], ["m", "only a measure"]] do
        exception = assert_raise DOMException, fn -> apply(Performance, :measure, arguments) end
        assert exception.name == "SyntaxError"
        assert exception.code == 12
        assert exception.message =~ "does not exist"
      end

      assert names(Performance.get_entries()) == ["only a measure"]
    end

    test "a time is a moment too" do
      measure = Performance.measure("times", 4, 10.5)
      assert {measure.startTime, measure.duration} == {4.0, 6.5}

      assert_raise Web.TypeError, fn -> Performance.measure("negative", -1) end
    end

    test "with the options :start and :end" do
      Performance.mark("a", start_time: 10)

      measure = Performance.measure("m", start: "a", end: 40, detail: [1, 2])
      assert {measure.startTime, measure.duration, measure.detail} == {10.0, 30.0, [1, 2]}

      before = Performance.now()
      measure = Performance.measure("to now", start: 5)
      assert measure.startTime == 5.0
      assert measure.startTime + measure.duration >= before

      assert %Measure{startTime: +0.0, duration: 10.0} = Performance.measure("m", end: "a")
    end

    test "with the option :duration" do
      assert %Measure{startTime: 10.0, duration: 5.0} =
               Performance.measure("m", start: 10, duration: 5)

      assert %Measure{startTime: 15.0, duration: 5.0} =
               Performance.measure("m", end: 20, duration: 5)
    end

    test "options that are not correct raise TypeError" do
      assert_raise Web.TypeError, ~r/needs :start or :end/, fn ->
        Performance.measure("m", duration: 5)
      end

      assert_raise Web.TypeError, ~r/needs :start or :end/, fn ->
        Performance.measure("m", detail: 1)
      end

      assert_raise Web.TypeError, ~r/cannot have :start, :end, and :duration/, fn ->
        Performance.measure("m", start: 1, end: 2, duration: 1)
      end

      assert_raise Web.TypeError, ~r/cannot have an end mark/, fn ->
        # The call is not correct for the type checker too, thus the test
        # makes it at run time.
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Performance, :measure, ["m", [start: 1], "end"])
      end

      assert_raise Web.TypeError, ~r/Unknown options/, fn ->
        Performance.measure("m", start: 1, finish: 2)
      end

      assert_raise Web.TypeError, ~r/not below zero/, fn ->
        Performance.measure("m", start: 1, duration: -2)
      end

      assert Performance.get_entries() == []
    end

    test "an empty list of options is no options" do
      assert %Measure{startTime: +0.0} = Performance.measure("m", [])
    end
  end

  # ---------------------------------------------------------------------------
  # The entries
  # ---------------------------------------------------------------------------

  describe "the entries" do
    test "are in the sequence of their start times" do
      Performance.mark("third", start_time: 30)
      Performance.mark("first", start_time: 10)
      Performance.measure("second", start: 20, end: 25)
      Performance.mark("first again", start_time: 10)

      assert names(Performance.get_entries()) == ["first", "first again", "second", "third"]
      assert Performance.getEntries() == Performance.get_entries()
    end

    test "can be read by type and by name" do
      Performance.mark("a", start_time: 1)
      Performance.mark("b", start_time: 2)
      Performance.measure("a", start: 3, end: 4)

      assert names(Performance.get_entries_by_type("mark")) == ["a", "b"]
      assert names(Performance.get_entries_by_type(:measure)) == ["a"]
      assert Performance.getEntriesByType("mark") == Performance.get_entries_by_type("mark")
      assert Performance.get_entries_by_type("other") == []

      assert [%Mark{name: "a"}, %Measure{name: "a"}] = Performance.get_entries_by_name("a")
      assert [%Measure{}] = Performance.get_entries_by_name(:a, "measure")
      assert [%Mark{}] = Performance.getEntriesByName("a", :mark)
      assert Performance.getEntriesByName("a") == Performance.get_entries_by_name("a")
      assert Performance.get_entries_by_name("missing") == []
    end

    test "clear_marks removes the marks with a name, or all the marks" do
      Performance.mark("a")
      Performance.mark("b")
      Performance.measure("a")

      assert :ok = Performance.clear_marks("a")
      assert [%Mark{name: "b"}, %Measure{name: "a"}] = Enum.sort(Performance.get_entries())

      assert :ok = Performance.clearMarks()
      assert [%Measure{name: "a"}] = Performance.get_entries()
    end

    test "clear_measures removes the measures with a name, or all the measures" do
      Performance.mark("a")
      Performance.measure("a")
      Performance.measure("b")

      assert :ok = Performance.clear_measures(:a)
      assert names(Performance.get_entries_by_type("measure")) == ["b"]

      assert :ok = Performance.clearMeasures("b")
      assert [%Mark{name: "a"}] = Performance.get_entries()
      assert :ok = Performance.clear_measures()
    end

    test "are the state of the process" do
      Performance.mark("mine")

      assert Task.await(Task.async(fn -> Performance.get_entries() end)) == []
      assert names(Performance.get_entries()) == ["mine"]
    end
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  describe "properties" do
    property "the entries are in the sequence of their start times, with no entry lost" do
      check all(
              times <- list_of(integer(0..20), max_length: 20),
              max_runs: 100
            ) do
        Performance.clear_marks()

        marks =
          times
          |> Enum.with_index()
          |> Enum.map(fn {time, index} -> Performance.mark(index, start_time: time) end)

        entries = Performance.get_entries()

        assert Enum.sort(entries) == Enum.sort(marks)
        assert Enum.map(entries, & &1.startTime) == Enum.sort(Enum.map(times, &(&1 * 1.0)))

        # Two marks with the same time stay in the sequence of their calls.
        for [first, second] <- Enum.chunk_every(entries, 2, 1, :discard),
            first.startTime == second.startTime do
          assert String.to_integer(first.name) < String.to_integer(second.name)
        end
      end
    end

    property "a measure between two times has their difference" do
      check all(start <- integer(0..1_000), finish <- integer(0..1_000), max_runs: 100) do
        Performance.clear_marks()
        Performance.mark("start", start_time: start)
        Performance.mark("end", start_time: finish)

        by_marks = Performance.measure("m", "start", "end")
        by_times = Performance.measure("m", start: start, end: finish)
        by_duration = Performance.measure("m", start: start, duration: abs(finish - start))

        assert by_marks.startTime == start
        assert by_marks.duration == finish - start
        assert {by_times.startTime, by_times.duration} == {by_marks.startTime, by_marks.duration}
        assert by_duration.duration == abs(finish - start)
      end
    end

    property "the times of the marks do not go back" do
      check all(count <- integer(2..20), max_runs: 50) do
        times = for index <- 1..count, do: Performance.mark(index).startTime
        assert times == Enum.sort(times)
      end
    end
  end
end

defmodule Web.PerformanceTimeOriginTest do
  # The test changes the time origin of the VM, thus it cannot run at the
  # same time as other tests.
  use ExUnit.Case, async: false

  alias Web.Performance

  setup do
    origin = :persistent_term.get({Performance, :time_origin})
    on_exit(fn -> :persistent_term.put({Performance, :time_origin}, origin) end)
  end

  test "put_time_origin sets the start of the clock" do
    assert :ok = Performance.put_time_origin(:erlang.monotonic_time(:microsecond) - 2_500)

    assert Performance.now() >= 2.5
    assert Performance.now() < 250.0
    # The time origin is 2.5 ms before the time of the system.
    assert_in_delta Performance.time_origin(), System.os_time(:microsecond) / 1000.0 - 2.5, 250.0
  end

  test "a call before the start of the application sets the time origin" do
    :persistent_term.erase({Performance, :time_origin})

    assert Performance.now() >= 0.0
    assert Performance.now() < 250.0
    assert_in_delta Performance.time_origin(), System.os_time(:microsecond) / 1000.0, 250.0
  end
end
