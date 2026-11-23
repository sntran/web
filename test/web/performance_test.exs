defmodule Web.PerformanceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.DOMException
  alias Web.Performance
  alias Web.Performance.Mark
  alias Web.Performance.Measure
  alias Web.PerformanceObserver

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

      from_origin = Performance.time_origin() + Performance.now()
      system = System.os_time(:microsecond) / 1000.0

      # The time origin is a time of Unix, not a value of the monotonic
      # clock.
      assert Performance.time_origin() > 1_600_000_000_000.0
      assert_in_delta from_origin, system, 5_000.0
    end

    test "to_json has the time origin" do
      assert Performance.to_json() == %{"timeOrigin" => Performance.time_origin()}
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

      assert %Mark{name: "start", entry_type: "mark", duration: +0.0, detail: nil} = mark
      assert mark.start_time >= before and mark.start_time <= later
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
      assert Performance.mark("early", start_time: 12.5).start_time == 12.5
      assert Performance.mark("integer", start_time: 3).start_time === 3.0

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
      assert to_string(mark.detail.buffer) == "bytes"
      refute mark.detail.buffer.id == buffer.id

      exception =
        assert_raise DOMException, fn -> Performance.mark("bad detail", detail: self()) end

      assert exception.name == "DataCloneError"
      assert names(Performance.get_entries()) == ["with detail"]
    end

    test "an option that is not a member of PerformanceMarkOptions has no effect" do
      # A dictionary of Web IDL ignores a member that it does not know.
      before = Performance.now()
      mark = Performance.mark("m", start: 1, detail: :kept)
      assert mark.start_time >= before
      assert mark.detail == :kept

      assert_raise Web.TypeError, ~r/keyword list/, fn -> Performance.mark("m", [1, 2]) end
    end

    test "Mark.new/2 makes a mark that is not an entry, as new PerformanceMark()" do
      mark = Mark.new("made", start_time: 4, detail: %{a: 1}, other: :ignored)
      assert %Mark{name: "made", start_time: 4.0, duration: +0.0, detail: %{a: 1}} = mark
      assert Performance.get_entries() == []

      before = Performance.now()
      assert Mark.new(:now).start_time >= before

      assert_raise Web.TypeError, ~r/not below zero/, fn -> Mark.new("m", start_time: -1) end
    end

    test "to_json/1 gives the attributes of PerformanceEntry" do
      mark = Performance.mark("json", start_time: 2, detail: :not_in_json)

      assert Mark.to_json(mark) == %{
               "name" => "json",
               "entryType" => "mark",
               "startTime" => 2.0,
               "duration" => 0.0
             }

      measure = Performance.measure("span", start: 2, end: 5)

      assert Measure.to_json(measure) == %{
               "name" => "span",
               "entryType" => "measure",
               "startTime" => 2.0,
               "duration" => 3.0
             }
    end
  end

  # ---------------------------------------------------------------------------
  # Measures
  # ---------------------------------------------------------------------------

  describe "measure" do
    test "with only a name is from the time origin to now" do
      before = Performance.now()
      measure = Performance.measure("all")

      assert %Measure{name: "all", entry_type: "measure", start_time: +0.0, detail: nil} = measure
      assert measure.duration >= before
      assert measure.duration <= Performance.now()
    end

    test "with a start mark is from the mark to now" do
      mark = Performance.mark("start")
      Process.sleep(3)
      measure = Performance.measure("elapsed", "start")

      assert measure.start_time == mark.start_time
      assert measure.duration >= 3.0
      assert measure.duration <= Performance.now() - mark.start_time
    end

    test "with two marks is the time between them" do
      Performance.mark("a", start_time: 10)
      Performance.mark("b", start_time: 25)

      measure = Performance.measure("a to b", "a", "b")
      assert {measure.start_time, measure.duration} == {10.0, 15.0}

      # The end can be before the start.
      assert Performance.measure("b to a", "b", "a").duration == -15.0

      # With no start mark, the measure starts at the time origin.
      assert %Measure{start_time: +0.0, duration: 25.0} = Performance.measure("to b", nil, "b")
    end

    test "uses the mark that was made last with a name" do
      Performance.mark("step", start_time: 50)
      Performance.mark("step", start_time: 20)

      assert Performance.measure("from step", "step", "step").start_time == 20.0
    end

    test "finds a mark when a measure has the same name" do
      Performance.mark("same", start_time: 5)
      Performance.measure("same", "same")

      assert Performance.measure("again", "same").start_time == 5.0
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

    test "a number in the place of a mark is the name of a mark, as a DOMString" do
      Performance.mark("4", start_time: 4)
      Performance.mark("10.5", start_time: 10.5)
      measure = Performance.measure("times", 4, 10.5)
      assert {measure.start_time, measure.duration} == {4.0, 6.5}

      exception = assert_raise DOMException, fn -> Performance.measure("negative", -1) end
      assert exception.name == "SyntaxError"

      exception = assert_raise DOMException, fn -> Performance.measure("end", "4", 7) end
      assert exception.name == "SyntaxError"
    end

    test "with the options :start and :end" do
      Performance.mark("a", start_time: 10)

      measure = Performance.measure("m", start: "a", end: 40, detail: [1, 2])
      assert {measure.start_time, measure.duration, measure.detail} == {10.0, 30.0, [1, 2]}

      before = Performance.now()
      measure = Performance.measure("to now", start: 5)
      assert measure.start_time == 5.0
      assert measure.start_time + measure.duration >= before

      assert %Measure{start_time: +0.0, duration: 10.0} = Performance.measure("m", end: "a")
    end

    test "with the option :duration" do
      assert %Measure{start_time: 10.0, duration: 5.0} =
               Performance.measure("m", start: 10, duration: 5)

      assert %Measure{start_time: 15.0, duration: 5.0} =
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

      assert_raise Web.TypeError, ~r/not below zero/, fn ->
        Performance.measure("m", start: 1, duration: -2)
      end

      assert Performance.get_entries() == []
    end

    test "an empty list of options is no options" do
      assert %Measure{start_time: +0.0} = Performance.measure("m", [])
    end

    test "an option that is not a member of PerformanceMeasureOptions has no effect" do
      Performance.mark("b", start_time: 25.0)

      # The member :finish is not known: the measure is from 1 to now.
      before = Performance.now()
      measure = Performance.measure("m", start: 1, finish: 2)
      assert measure.start_time == 1.0
      assert measure.start_time + measure.duration >= before

      # Options with no member are no options: the end mark is permitted.
      assert %Measure{start_time: +0.0, duration: 25.0} =
               Performance.measure("to b", [finish: 2], "b")

      before = Performance.now()
      measure = Performance.measure("to now", other: 1)
      assert measure.start_time == 0.0
      assert measure.duration >= before
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
    end

    test "can be read by type and by name" do
      Performance.mark("a", start_time: 1)
      Performance.mark("b", start_time: 2)
      Performance.measure("a", start: 3, end: 4)

      assert names(Performance.get_entries_by_type("mark")) == ["a", "b"]
      assert names(Performance.get_entries_by_type(:measure)) == ["a"]
      assert Performance.get_entries_by_type("other") == []

      assert [%Mark{name: "a"}, %Measure{name: "a"}] = Performance.get_entries_by_name("a")
      assert [%Measure{}] = Performance.get_entries_by_name(:a, "measure")
      assert [%Mark{}] = Performance.get_entries_by_name("a", :mark)
      assert Performance.get_entries_by_name("missing") == []
    end

    test "clear_marks removes the marks with a name, or all the marks" do
      Performance.mark("a")
      Performance.mark("b")
      Performance.measure("a")

      assert :ok = Performance.clear_marks("a")
      assert [%Mark{name: "b"}, %Measure{name: "a"}] = Enum.sort(Performance.get_entries())

      assert :ok = Performance.clear_marks()
      assert [%Measure{name: "a"}] = Performance.get_entries()
    end

    test "clear_measures removes the measures with a name, or all the measures" do
      Performance.mark("a")
      Performance.measure("a")
      Performance.measure("b")

      assert :ok = Performance.clear_measures(:a)
      assert names(Performance.get_entries_by_type("measure")) == ["b"]

      assert :ok = Performance.clear_measures("b")
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
  # The global object
  # ---------------------------------------------------------------------------

  # An operation of the timeline. The times do not come from the clock, thus
  # two runs of the same operations give the same entries.
  defp operation do
    name = member_of(["a", "b"])
    moment = one_of([member_of(["a", "b"]), integer(0..10)])

    one_of([
      tuple({constant(:mark), name, integer(0..10)}),
      tuple({constant(:measure), name, moment, moment}),
      tuple({constant(:clear_marks), member_of([nil, "a", "b"])}),
      tuple({constant(:clear_measures), member_of([nil, "a", "b"])})
    ])
  end

  # Does the operations, and returns the result of each and the entries.
  defp run_all(operations) do
    results = Enum.map(operations, &run_operation/1)
    {results, Performance.get_entries()}
  end

  defp run_operation({:mark, name, time}), do: Performance.mark(name, start_time: time)

  defp run_operation({:measure, name, from, to}) do
    Performance.measure(name, start: from, end: to)
  rescue
    error in DOMException -> {:error, error.name}
  end

  defp run_operation({:clear_marks, name}), do: Performance.clear_marks(name)
  defp run_operation({:clear_measures, name}), do: Performance.clear_measures(name)

  defp in_process(fun), do: fun |> Task.async() |> Task.await()

  describe "the global object" do
    property "an observer and its callback keep the entries as a process with no observer" do
      check all(operations <- list_of(operation(), max_length: 15), max_runs: 50) do
        alone = in_process(fn -> run_all(operations) end)

        # The global object has a server, and an observer of each type.
        observed =
          in_process(fn ->
            observer = PerformanceObserver.new(fn -> :ok end)
            PerformanceObserver.observe(observer, entry_types: ["mark", "measure"])
            run_all(operations)
          end)

        # The callback acts on the timeline of the global object: the global
        # object has the entries of the callback.
        in_callback =
          in_process(fn ->
            test = self()

            observer =
              PerformanceObserver.new(fn _list, observer ->
                PerformanceObserver.disconnect(observer)
                Performance.clear_marks("start")
                send(test, {:done, run_all(operations)})
              end)

            PerformanceObserver.observe(observer, type: "mark")
            Performance.mark("start")

            receive do
              {:done, {results, entries}} ->
                assert Performance.get_entries() == entries
                {results, entries}
            end
          end)

        assert observed == alone
        assert in_callback == alone
      end
    end

    test "a process does not see the entries of a different process" do
      Performance.mark("test process")

      in_process(fn ->
        observer = PerformanceObserver.new(fn -> :ok end)
        PerformanceObserver.observe(observer, type: "mark")
        Performance.mark("other process")
        assert names(Performance.get_entries()) == ["other process"]
      end)

      assert names(Performance.get_entries()) == ["test process"]
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
        assert Enum.map(entries, & &1.start_time) == Enum.sort(Enum.map(times, &(&1 * 1.0)))

        # Two marks with the same time stay in the sequence of their calls.
        for [first, second] <- Enum.chunk_every(entries, 2, 1, :discard),
            first.start_time == second.start_time do
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

        assert by_marks.start_time == start
        assert by_marks.duration == finish - start

        assert {by_times.start_time, by_times.duration} ==
                 {by_marks.start_time, by_marks.duration}

        assert by_duration.duration == abs(finish - start)
      end
    end

    property "the times of the marks do not go back" do
      check all(count <- integer(2..20), max_runs: 50) do
        times = for index <- 1..count, do: Performance.mark(index).start_time
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
