defmodule Web.ConsoleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  doctest Web.Console

  defmodule SampleRow do
    defstruct [:name, :score]
  end

  test "logging helpers, alias helpers, grouping, timing, and table formatting are covered" do
    log =
      capture_log(fn ->
        Web.Console.log(["hello", "world"])
        Web.Console.debug(:debugging)
        Web.Console.error(:boom)
        Web.Console.assert(false, "assertion failed")
        Web.Console.group()
        Web.Console.info("inside")
        Web.Console.groupCollapsed("nested")
        Web.Console.table([%{name: "Ada", score: 10}, %{name: "Linus", score: 8}])
        Web.Console.count(:rows)
        Web.Console.count(:rows)
        Web.Console.timeLog(:query, "checkpoint")
        Web.Console.groupEnd()
        Web.Console.time(:query)
        Process.sleep(2)
        Web.Console.timeEnd(:query)
        Web.Console.groupEnd()
      end)

    assert log =~ "hello world"
    assert log =~ "debugging"
    assert log =~ "boom"
    assert log =~ "assertion failed"
    assert log =~ "  inside"
    assert log =~ "  nested"
    assert log =~ "| name"
    assert log =~ "| score"
    assert log =~ "rows: 1"
    assert log =~ "rows: 2"
    assert log =~ "Timer 'query' does not exist"
    assert log =~ "query: "
  end

  test "warns when timeEnd is called without a matching timer" do
    log =
      capture_log(fn ->
        Web.Console.warn("careful")
        Web.Console.timeEnd("missing")
        Web.Console.countReset("missing-counter")
      end)

    assert log =~ "careful"
    assert log =~ "Timer 'missing' does not exist"
    assert log =~ "Count for 'missing-counter' does not exist"
  end

  test "table handles empty lists, structs, maps, scalar values, and keyword data" do
    log =
      capture_log(fn ->
        Web.Console.table([])
        Web.Console.table(%SampleRow{name: "Grace", score: 11})
        Web.Console.table(%{team: "beam", active: true})
        Web.Console.table(123)
        Web.Console.info(status: :ok)
      end)

    assert log =~ "(empty)"
    assert log =~ "Grace"
    assert log =~ "beam"
    assert log =~ "123"
    assert log =~ "[status: :ok]"
  end

  test "groupEnd does not drop below zero indentation" do
    log =
      capture_log(fn ->
        Web.Console.groupEnd()
        Web.Console.info("flat")
      end)

    assert log =~ "flat"
    refute log =~ "  flat"
  end

  test "snake_case timer and grouping helpers also work directly" do
    log =
      capture_log(fn ->
        Web.Console.group_collapsed("direct")
        Web.Console.time("direct-timer")
        Process.sleep(1)
        Web.Console.time_log("direct-timer", "midway")
        Web.Console.time_end("direct-timer")
        Web.Console.count("direct-counter")
        Web.Console.count_reset("direct-counter")
        Web.Console.group_end()
      end)

    assert log =~ "direct"
    assert log =~ "midway"
    assert log =~ "direct-timer: "
    assert log =~ "direct-counter: 1"
  end

  test "trace logs a JS-style stack trace header" do
    log =
      capture_log(fn ->
        Web.Console.trace()
      end)

    assert log =~ "Trace"
    assert log =~ "at "
  end

  test "assert defaults, timer aliases, counter reset, and logger metadata restoration all work" do
    :logger.set_process_metadata(%{existing: :value})

    log =
      capture_log(fn ->
        assert :ok == Web.Console.assert(true, "ignored")
        Web.Console.assert(false, nil)
        Web.Console.time(:alias_timer)
        Web.Console.timeLog(:alias_timer)
        Web.Console.count()
        assert :ok == Web.Console.countReset()
      end)

    assert log =~ "Assertion failed"
    assert log =~ "alias_timer: "
    assert log =~ "default: 1"
    assert %{existing: :value} = :logger.get_process_metadata()
  after
    :logger.unset_process_metadata()
  end

  test "console restores process metadata after logging" do
    :logger.set_process_metadata(%{existing: :value})

    log =
      capture_log(fn ->
        Web.Console.info("metadata check")
      end)

    assert log =~ "metadata check"
    assert %{existing: :value} = :logger.get_process_metadata()
  after
    :logger.unset_process_metadata()
  end

  test "format_stacktrace_line handles file-only and missing location metadata" do
    assert Web.Console.format_stacktrace_line({Demo, :run, 1, file: ~c"demo.ex"}) =~
             "(demo.ex)"

    assert Web.Console.format_stacktrace_line({Demo, :run, 1, []}) ==
             "    at Demo.run/1"
  end
end
