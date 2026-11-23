defmodule Web.TLA.ConsoleConformanceTest do
  # Compares the real `Web.Console` with the specification `tla/Console.tla`.
  #
  # The test makes a random list of calls. It does each call on the real
  # console and on the specification, and it compares the message of the
  # call: its kind, its level, its indent, and the value of a counter.
  #
  # Each test adds a logger handler and removes it. The logger of
  # Erlang/OTP can lose a handler that a different test adds at the same
  # time, for example the handler of `capture_log/1`: see
  # `test/web/console_test.exs`. Thus these tests do not run at the same
  # time as other tests.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Web.Console
  alias Web.Test.SpecModel
  alias Web.TestSupport.LogForwarder

  # The messages of the tests do not go to the terminal.
  @moduletag capture_log: true

  @labels ["a", "b"]
  @constants [{"MaxDepth = 2", "MaxDepth = 4"}, {"MaxCount = 2", "MaxCount = 6"}]

  # The levels of the specification, and the functions that have them.
  @levels %{
    "debug" => :debug,
    "info" => :info,
    "notice" => :log,
    "warning" => :warn,
    "error" => :error
  }

  setup do
    handler = LogForwarder.attach(self())
    on_exit(fn -> LogForwarder.detach(handler) end)
    :ok
  end

  defp command do
    label = member_of(@labels)

    frequency([
      {3, tuple({constant("Log"), member_of(Map.keys(@levels))})},
      {2, tuple({constant("Group"), boolean()})},
      {2, constant({"GroupEnd"})},
      {1, constant({"Clear"})},
      {2, tuple({constant("Time"), label})},
      {2, tuple({constant("TimeLog"), label})},
      {2, tuple({constant("TimeEnd"), label})},
      {3, tuple({constant("Count"), label})},
      {2, tuple({constant("CountReset"), label})}
    ])
  end

  property "the console does each call as the specification permits" do
    check all(commands <- list_of(command(), max_length: 30), max_runs: 150) do
      reset()

      Enum.reduce(commands, SpecModel.start("Console", @constants), fn command, model ->
        [action | args] = Tuple.to_list(command)

        # The specification has a limit for the groups and the counters.
        if SpecModel.enabled?(model, action, args) do
          call(command)
          model = SpecModel.step!(model, action, args)
          assert message() == expected(SpecModel.get(model, "out")), "after #{inspect(command)}"
          model
        else
          model
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # The real console
  # ---------------------------------------------------------------------------

  # The state of the console is the state of the test process.
  defp reset do
    Console.clear()

    for label <- @labels do
      Console.time_end(label)
      Console.count_reset(label)
    end

    flush()
  end

  defp call({"Log", level}), do: apply(Console, Map.fetch!(@levels, level), ["text"])
  defp call({"Group", true}), do: Console.group("label")
  defp call({"Group", false}), do: Console.group()
  defp call({"GroupEnd"}), do: Console.group_end()
  defp call({"Clear"}), do: Console.clear()
  defp call({"Time", label}), do: Console.time(label)
  defp call({"TimeLog", label}), do: Console.time_log(label)
  defp call({"TimeEnd", label}), do: Console.time_end(label)
  defp call({"Count", label}), do: Console.count(label)
  defp call({"CountReset", label}), do: Console.count_reset(label)

  # The message of the last call, in the form of the specification.
  defp message do
    receive do
      {:console, level, text, meta} ->
        refute_received {:console, _level, _text, _meta}
        indent = div(byte_size(text) - byte_size(String.trim_leading(text, " ")), 2)
        assert indent == meta.group_depth

        %{
          "kind" => kind(meta.console_method, level),
          "level" => Atom.to_string(level),
          "indent" => indent,
          "value" => value(meta.console_method, text)
        }
    after
      0 -> %{"kind" => "none", "level" => "none", "indent" => 0, "value" => 0}
    end
  end

  defp kind(:group, :notice), do: "group"
  defp kind(:time, :warning), do: "timer_exists"
  defp kind(method, :info) when method in [:time_log, :time_end], do: "elapsed"
  defp kind(method, :warning) when method in [:time_log, :time_end], do: "no_timer"
  defp kind(:count, :info), do: "count"
  defp kind(:count_reset, :warning), do: "no_counter"
  defp kind(method, _level) when method in [:debug, :info, :log, :warn, :error], do: "log"

  defp value(:count, text) do
    [_label, value] = String.split(String.trim(text), ": ")
    String.to_integer(value)
  end

  defp value(_method, _text), do: 0

  defp expected(out), do: Map.take(out, ["kind", "level", "indent", "value"])

  defp flush do
    receive do
      {:console, _level, _text, _meta} -> flush()
    after
      0 -> :ok
    end
  end
end
