defmodule Web.ConsoleTest do
  # Each test adds a logger handler and removes it, and the capture of the
  # log adds a handler too. When two processes change the handlers at the
  # same time, the logger of Erlang/OTP can lose a handler: it handles a
  # remove while an add is in progress, and then it puts back the list of
  # handlers from before the add. Thus these tests do not run at the same
  # time as other tests.
  use ExUnit.Case, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Web.Console
  alias Web.TestSupport.LogForwarder

  doctest Web.Console

  # The messages of the tests do not go to the terminal.
  @moduletag capture_log: true

  defmodule SampleRow do
    defstruct [:name, :score]
  end

  setup do
    handler = LogForwarder.attach(self())
    on_exit(fn -> LogForwarder.detach(handler) end)
    :ok
  end

  # The next message of the console of this process.
  defp output do
    assert_received {:console, level, text, meta}
    {level, text, meta.console_method}
  end

  defp text do
    {_level, text, _method} = output()
    text
  end

  defp no_output, do: refute_received({:console, _level, _text, _meta})

  # ---------------------------------------------------------------------------
  # Logging
  # ---------------------------------------------------------------------------

  describe "the functions that write a message" do
    test "have the levels of the documentation" do
      assert :ok = Console.debug("d")
      assert output() == {:debug, "d", :debug}
      assert :ok = Console.info("i")
      assert output() == {:info, "i", :info}
      assert :ok = Console.log("l")
      assert output() == {:notice, "l", :log}
      assert :ok = Console.dirxml("x")
      assert output() == {:notice, "x", :dirxml}
      assert :ok = Console.warn("w")
      assert output() == {:warning, "w", :warn}
      assert :ok = Console.error("e")
      assert output() == {:error, "e", :error}
    end

    test "write an empty message with no data" do
      for function <- [:debug, :info, :log, :dirxml, :warn, :error] do
        assert :ok = apply(Console, function, [])
        assert text() == ""
      end
    end

    test "write a string as it is, and each other value with inspect" do
      Console.log("a string")
      assert text() == "a string"

      Console.log(:atom)
      assert text() == ":atom"

      Console.log(%{key: {1, 2.5}})
      assert text() == "%{key: {1, 2.5}}"

      Console.log(nil)
      assert text() == "nil"
    end

    test "a list is the list of the arguments, and a keyword list is one argument" do
      Console.log(["user", %{id: 7}, 3])
      assert text() == "user %{id: 7} 3"

      Console.info(status: :ok)
      assert text() == "[status: :ok]"

      Console.log([[1, 2, 3]])
      assert text() == "[1, 2, 3]"

      Console.log([])
      assert text() == ""
    end

    test "a message is not a format of the logger" do
      Console.log("100% ~p ~s")
      assert text() == "100% ~p ~s"

      assert capture_log(fn -> Console.log("tilde ~p here") end) =~ "tilde ~p here"
    end

    test "the metadata has the method and the depth of the groups" do
      Console.group("label")
      Console.warn("inside")

      assert_received {:console, :notice, "label", %{console: true, group_depth: 0}}

      assert_received {:console, :warning, "  inside",
                       %{console: true, console_method: :warn, group_depth: 1}}

      Console.clear()
    end

    test "the metadata of the logger of the process stays" do
      :logger.update_process_metadata(%{existing: :value})

      Console.info("metadata check")

      assert_received {:console, :info, "metadata check", %{existing: :value}}
      assert %{existing: :value} = :logger.get_process_metadata()
    end
  end

  describe "the format" do
    test "applies when the first of two or more arguments is a string" do
      Console.log(["%s has %d items, %f, %i", "Ann", 3, 2, 7.9])
      assert text() == "Ann has 3 items, 2.0, 7"

      Console.log(["%o and %O", %{a: 1}, [1, 2]])
      assert text() == "%{a: 1} and [1, 2]"

      Console.log(["%s %s", :atom, {1, 2}])
      assert text() == "atom {1, 2}"
    end

    test "the arguments that the format does not use come after it" do
      Console.log(["%s:", "label", 1, "two", :three])
      assert text() == "label: 1 two :three"
    end

    test "a specifier with no argument, and a specifier that is not known, stay" do
      Console.log(["%s and %s", "one"])
      assert text() == "one and %s"

      Console.log(["100%x %s", "done"])
      assert text() == "100%x done"

      Console.log(["ends with %", "next"])
      assert text() == "ends with % next"
    end

    test "%% is one character, and %c uses one argument" do
      Console.log(["%d%% %cdone", 50, "color: red"])
      assert text() == "50% done"
    end

    test "a value that is not a number gives NaN" do
      Console.log(["%d %i %f", "text", nil, :atom])
      assert text() == "NaN NaN NaN"
    end

    test "does not apply to one argument" do
      Console.log("%s %d %%")
      assert text() == "%s %d %%"

      Console.log([:not_a_string, "%s", 1])
      assert text() == ":not_a_string %s 1"
    end
  end

  describe "dir" do
    test "writes one value with inspect, also a string, with no limit" do
      Console.dir("text")
      assert output() == {:notice, ~s("text"), :dir}

      list = Enum.to_list(1..200)
      Console.dir(list, depth: 2)
      assert text() == inspect(list, pretty: true, limit: :infinity)
    end
  end

  describe "assert" do
    test "writes nothing for a value that is not false and not nil" do
      for value <- [true, 1, 0, "", [], :ok] do
        assert :ok = Console.assert(value, "not written")
      end

      no_output()
    end

    test "writes an error for false and nil" do
      Console.assert(false)
      assert output() == {:error, "Assertion failed", :assert}

      Console.assert(nil, "the list is empty")
      assert output() == {:error, "Assertion failed: the list is empty", :assert}

      Console.assert(false, ["%s is not %d", "x", 1])
      assert text() == "Assertion failed: x is not 1"

      Console.assert(false, %{code: 7})
      assert text() == "Assertion failed %{code: 7}"
    end
  end

  describe "trace" do
    test "writes the stack of the process" do
      Console.trace()
      {level, text, method} = output()

      assert {level, method} == {:notice, :trace}
      assert [header | lines] = String.split(text, "\n")
      assert header == "Trace"
      assert Enum.any?(lines, &(&1 =~ "    at Web.ConsoleTest."))
      refute Enum.any?(lines, &(&1 =~ "Web.Console.trace"))
    end

    test "writes the data after the header" do
      Console.trace(["%s failed", "step 2"])
      assert "Trace: step 2 failed\n" <> _stack = text()
    end

    test "format_stacktrace_line accepts each form of a location" do
      assert Console.format_stacktrace_line({Demo, :run, 1, file: ~c"demo.ex", line: 7}) ==
               "    at Demo.run/1 (demo.ex:7)"

      assert Console.format_stacktrace_line({Demo, :run, 1, file: ~c"demo.ex"}) ==
               "    at Demo.run/1 (demo.ex)"

      assert Console.format_stacktrace_line({Demo, :run, [:a, :b], []}) == "    at Demo.run/2"
    end
  end

  # ---------------------------------------------------------------------------
  # Tables
  # ---------------------------------------------------------------------------

  describe "table" do
    test "a list of maps has one row for each map" do
      Console.table([%{name: "Ada", score: 10}, %{name: "Linus", score: 8}])

      assert {:notice, table, :table} = output()

      assert table == """
             | (index) | name    | score |
             |---------|---------|-------|
             | 0       | "Ada"   | 10    |
             | 1       | "Linus" | 8     |\
             """
    end

    test "rows with different keys, structs, and values" do
      Console.table([%SampleRow{name: "Grace", score: 11}, %{team: "beam"}, 42, {1, 2}, [a: 1]])

      assert text() == """
             | (index) | name    | score | team   | 0 | 1 | a | Values |
             |---------|---------|-------|--------|---|---|---|--------|
             | 0       | "Grace" | 11    |        |   |   |   |        |
             | 1       |         |       | "beam" |   |   |   |        |
             | 2       |         |       |        |   |   |   | 42     |
             | 3       |         |       |        | 1 | 2 |   |        |
             | 4       |         |       |        |   |   | 1 |        |\
             """
    end

    test "a map, a struct, and a keyword list have one row for each pair" do
      Console.table(%{team: "beam", active: true})

      assert text() == """
             | (index) | Values |
             |---------|--------|
             | active  | true   |
             | team    | "beam" |\
             """

      Console.table(%SampleRow{name: "Grace", score: 11})
      assert text() =~ ~s(| name    | "Grace" |)

      Console.table(first: %{x: 1}, second: %{x: 2})

      assert text() == """
             | (index) | x |
             |---------|---|
             | first   | 1 |
             | second  | 2 |\
             """
    end

    test "the columns to show" do
      Console.table([%{a: 1, b: 2, c: 3}, %{a: 4, b: 5, c: 6}], [:c, "a", :missing])

      assert text() == """
             | (index) | c | a | missing |
             |---------|---|---|---------|
             | 0       | 3 | 1 |         |
             | 1       | 6 | 4 |         |\
             """
    end

    test "data with no rows" do
      Console.table([])
      assert text() == "| (index) |\n|---------|"
    end

    test "data that is not a table is written as a message" do
      Console.table(123)
      assert output() == {:notice, "123", :table}

      Console.table("text")
      assert text() == "text"
    end

    test "a table in a group has the indent on each line" do
      Console.group()
      Console.table([1])
      Console.group_end()

      assert text() == "  | (index) | Values |\n  |---------|--------|\n  | 0       | 1      |"
    end
  end

  # ---------------------------------------------------------------------------
  # Groups
  # ---------------------------------------------------------------------------

  describe "groups" do
    test "each open group adds two spaces" do
      Console.group("outer")
      Console.log("in outer")
      Console.group_collapsed(["%s", "inner"])
      Console.log("in inner\nsecond line")
      Console.group_end()
      Console.log("in outer again")
      Console.group_end()
      Console.log("outside")

      assert output() == {:notice, "outer", :group}
      assert text() == "  in outer"
      assert text() == "  inner"
      assert text() == "    in inner\n    second line"
      assert text() == "  in outer again"
      assert text() == "outside"
    end

    test "a group with no label writes nothing" do
      Console.group()
      no_output()
      Console.log("inside")
      assert text() == "  inside"
      Console.group_end()
    end

    test "group_end with no open group has no effect" do
      assert :ok = Console.group_end()
      Console.log("flat")
      assert text() == "flat"
    end

    test "clear closes all the groups" do
      Console.group()
      Console.group()
      assert :ok = Console.clear()
      Console.log("flat")
      assert text() == "flat"
    end

    test "group_collapsed/1 opens a group, as group/1" do
      Console.group_collapsed("label")
      Console.log("inside")
      Console.group_end()
      Console.log("outside")

      assert text() == "label"
      assert text() == "  inside"
      assert text() == "outside"
    end

    test "the depth goes into the callback of a promise" do
      handler = LogForwarder.attach(self(), all: true)
      :logger.update_process_metadata(%{console_test: self()})

      Console.group()

      Web.Promise.resolve(:ok)
      |> Web.Promise.then(fn _value -> Console.log("in the callback") end)
      |> Web.Promise.await()

      Console.group_end()
      LogForwarder.detach(handler)

      assert_received {:console, :notice, "  in the callback", %{group_depth: 1}}
    end
  end

  # ---------------------------------------------------------------------------
  # Timers
  # ---------------------------------------------------------------------------

  describe "timers" do
    test "time_log writes the time and the data, and the timer continues" do
      assert :ok = Console.time("query")
      no_output()
      Process.sleep(2)

      Console.time_log("query", ["rows", 3])
      assert {:info, text, :time_log} = output()
      assert [_all, first] = Regex.run(~r/^query: (\d+\.\d{3}) ms rows 3$/, text)

      Console.time_end("query")
      assert {:info, text, :time_end} = output()
      assert [_all, second] = Regex.run(~r/^query: (\d+\.\d{3}) ms$/, text)

      assert String.to_float(first) >= 2.0
      assert String.to_float(second) >= String.to_float(first)
    end

    test "a timer that runs is not started again" do
      Console.time(:t)
      Process.sleep(5)
      Console.time(:t)
      assert output() == {:warning, "Timer 't' already exists", :time}

      Console.time_end(:t)
      assert [_all, elapsed] = Regex.run(~r/^t: (\d+\.\d{3}) ms$/, text())
      assert String.to_float(elapsed) >= 5.0
    end

    test "a timer that does not exist gives a warning" do
      Console.time_log("missing")
      assert output() == {:warning, "Timer 'missing' does not exist", :time_log}

      Console.time_end("missing")
      assert output() == {:warning, "Timer 'missing' does not exist", :time_end}

      # A timer that ended does not exist.
      Console.time("once")
      Console.time_end("once")
      _elapsed = text()
      Console.time_end("once")
      assert text() == "Timer 'once' does not exist"
    end

    test "the default label" do
      Console.time()
      Console.time_log()
      assert "default: " <> _time = text()
      Console.time_log("default", "data")
      assert text() =~ ~r/^default: .* ms data$/
      Console.time_end()
      assert {:info, "default: " <> _time, :time_end} = output()
      Console.time_end("default")
      assert text() == "Timer 'default' does not exist"
    end

    test "a label is not a format" do
      Console.time("50%s")
      Console.time_log("50%s", "data")
      assert text() =~ ~r/^50%s: .* ms data$/
      Console.time_end("50%s")
    end
  end

  # ---------------------------------------------------------------------------
  # Counters
  # ---------------------------------------------------------------------------

  describe "counters" do
    test "count adds one for each label" do
      Console.count(:rows)
      Console.count("rows")
      Console.count()
      Console.count({:a, 1})

      assert output() == {:info, "rows: 1", :count}
      assert text() == "rows: 2"
      assert text() == "default: 1"
      assert text() == "{:a, 1}: 1"
    end

    test "count_reset sets the counter to zero" do
      Console.count("rows")
      Console.count("rows")
      assert :ok = Console.count_reset("rows")
      Console.count("rows")

      assert text() == "rows: 1"
      assert text() == "rows: 2"
      assert text() == "rows: 1"
    end

    test "a counter that does not exist gives a warning" do
      Console.count_reset("missing")
      assert output() == {:warning, "Count for 'missing' does not exist", :count_reset}

      Console.count_reset()
      assert text() == "Count for 'default' does not exist"
    end
  end

  describe "the state" do
    test "is the state of the process" do
      Console.group()
      Console.time("shared")
      Console.count("shared")
      _count = text()
      test = self()

      task =
        Task.async(fn ->
          handler = LogForwarder.attach(self())
          Console.time_end("shared")
          Console.count("shared")
          LogForwarder.detach(handler)

          for _index <- 1..2 do
            receive do
              {:console, level, text, _meta} -> send(test, {:task, level, text})
            end
          end
        end)

      Task.await(task)

      # The task has no timer and no counter of this process.
      assert_received {:task, :warning, "Timer 'shared' does not exist"}
      assert_received {:task, :info, "shared: 1"}
      Console.clear()
    end
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  describe "properties" do
    property "each message has the indent of the open groups, on each line" do
      check all(
              commands <- list_of(member_of([:group, :group_end, :log, :clear]), max_length: 30),
              max_runs: 100
            ) do
        Console.clear()

        Enum.reduce(commands, 0, fn
          :group, depth ->
            Console.group()
            depth + 1

          :group_end, depth ->
            Console.group_end()
            max(depth - 1, 0)

          :clear, _depth ->
            Console.clear()
            0

          :log, depth ->
            Console.log("first\nsecond")
            indent = String.duplicate("  ", depth)
            assert text() == "#{indent}first\n#{indent}second"
            depth
        end)

        Console.clear()
      end
    end

    property "a counter has the number of the calls after the last reset" do
      check all(
              commands <-
                list_of(tuple({member_of([:count, :reset]), member_of(["a", "b"])}),
                  max_length: 30
                ),
              max_runs: 100
            ) do
        Enum.each(["a", "b"], &Console.count_reset/1)
        flush()

        Enum.reduce(commands, %{}, fn
          {:count, label}, counts ->
            Console.count(label)
            value = Map.get(counts, label, 0) + 1
            assert output() == {:info, "#{label}: #{value}", :count}
            Map.put(counts, label, value)

          {:reset, label}, counts ->
            Console.count_reset(label)

            if is_map_key(counts, label) do
              no_output()
            else
              assert {:warning, _text, :count_reset} = output()
            end

            Map.delete(counts, label)
        end)
      end
    end

    property "a message with one argument is the argument" do
      check all(text <- string(:printable, max_length: 40), max_runs: 200) do
        Console.log(text)
        assert text() == text

        Console.log([text])
        assert text() == text
      end
    end

    property "a format with no specifier, and other arguments, keeps all the text" do
      check all(
              format <- string([?a..?z, ?\s], max_length: 20),
              args <- list_of(integer(), min_length: 1, max_length: 4),
              max_runs: 100
            ) do
        Console.log([format | args])
        assert text() == Enum.join([format | Enum.map(args, &Integer.to_string/1)], " ")
      end
    end
  end

  defp flush do
    receive do
      {:console, _level, _text, _meta} -> flush()
    after
      0 -> :ok
    end
  end
end
