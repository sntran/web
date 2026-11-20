defmodule Web.Test.QuickJS.WPT do
  @moduledoc false

  # The expected results of the files of web-platform-tests that QuickJS
  # runs against the library: see `Web.Test.QuickJS.Bridge`.
  #
  # The file `test/wpt/quickjs/expectations/<path of the test>.json` lists
  # each test that does not pass, with the group of its cause. A test that is
  # not in the list must pass. A test in the list that passes is also an
  # error: remove it from the list, as the library now follows the Standard.
  #
  # With the environment variable `WPT_UPDATE=1`, a run writes the lists
  # again from its results.

  alias Web.Test.QuickJS.Bridge

  @root Path.expand("../../wpt/quickjs/expectations", __DIR__)
  @newer_standard "standard: the current Standard changed this test"

  @doc "Runs the WPT file at `path`, and compares the results with the list."
  def check!(path) do
    run = Bridge.run!(path)

    if System.get_env("WPT_UPDATE") in ["1", "true"] do
      write!(path, run)
    else
      compare!(path, run)
    end
  end

  defp compare!(path, run) do
    expected = read(path)

    problems =
      harness_problem(expected, run) ++
        for name <- run.order,
            {status, message} = run.results[name],
            problem = problem(name, status, message, expected["failures"]),
            do: problem

    if problems != [] do
      raise ExUnit.AssertionError,
        message:
          "#{length(problems)} results of #{path} differ from #{relative(file(path))}:\n" <>
            Enum.join(Enum.take(problems, 20), "\n") <> "\n" <> log(run)
    end

    :ok
  end

  defp harness_problem(expected, run) do
    if run.status == Map.get(expected, "harness", "OK"),
      do: [],
      else: ["  the harness: #{run.status} #{run.message}"]
  end

  defp problem(name, "PASS", _message, failures) do
    if Map.has_key?(failures, name),
      do: "  passes now, remove it from the list: #{name}",
      else: nil
  end

  defp problem(name, status, message, failures) do
    if Map.has_key?(failures, name),
      do: nil,
      else: "  #{status}: #{name}: #{message}"
  end

  defp log(%{log: ""}), do: ""
  defp log(%{log: log}), do: "The output of QuickJS:\n" <> String.slice(log, 0, 2_000)

  defp read(path) do
    case File.read(file(path)) do
      {:ok, text} -> JSON.decode!(text)
      {:error, :enoent} -> %{"harness" => "OK", "failures" => %{}}
    end
  end

  # The list has one line for each test, in the sequence of the names: a
  # change of the library shows as a small change of the file.
  defp write!(path, run) do
    failures =
      for name <- run.order, {status, message} = run.results[name], status != "PASS" do
        {name, cause(path, name, message)}
      end

    target = file(path)

    if failures == [] and run.status == "OK" do
      _ = File.rm(target)
    else
      lines =
        failures
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.sort()
        |> Enum.map_join(",\n", fn {name, cause} ->
          "    #{JSON.encode!(name)}: #{JSON.encode!(cause)}"
        end)

      File.mkdir_p!(Path.dirname(target))

      File.write!(target, """
      {
        "harness": #{JSON.encode!(run.status)},
        "failures": {
      #{lines}
        }
      }
      """)
    end

    :ok
  end

  defp file(path), do: Path.join(@root, path <> ".json")
  defp relative(path), do: Path.relative_to(path, File.cwd!())

  @doc """
  The group of the cause of a failure, from the path of the test, its name,
  and its message. The groups that start with `runner:` are things that the
  runner does not have yet. The groups that start with `library:` are
  differences of the library from the Standard. The group `standard:` is
  for a test of the pinned WPT commit that the current Standard changed.
  The group `scope:` is for a test of an API that the library will not
  have.
  """
  def cause(path, name, message) do
    message = message || ""
    Enum.find_value(causes(), "library: a different result", &match(&1, path, name, message))
  end

  # The rules, in their sequence: the first rule that gives a group wins.
  defp causes do
    [
      # The Encoding Standard now starts a new decoder after a fatal error
      # ("Set this's do not flush to false"). These tests expect the state
      # of the decoder after the error.
      {:test, "encoding/textdecoder-mistakes.any.js",
       "EUC-JP JIS0212 state after a fatal streaming error", @newer_standard},
      {:test, "encoding/textdecoder-mistakes.any.js", "fatal stream: iso-2022-jp",
       @newer_standard},
      # The conversion of WebIDL to an async sequence is not in the layer
      # yet: `ReadableStream.from()` needs it.
      {:text, ["async_sequence is not in the layer"], "runner: no async sequence"},
      # A string of Elixir is UTF-8: a lone surrogate of a JavaScript string
      # becomes U+FFFD before it comes to the library. These tests split a
      # character between two chunks.
      {:test, "encoding/streams/encode-utf8.any.js", ~r/surrogate|split/,
       "runner: no lone surrogate in a string"},
      # The runner has no `EventTarget`: an `AbortSignal` has no
      # `addEventListener`.
      {:text, ["TypeError: not a function"], "runner: no EventTarget"},
      # The runner times out a test only when the library is at rest, and
      # JavaScript has nothing to do: a promise of the library does not
      # settle.
      {:text, ["Test timed out"], "library: a promise does not settle"},
      {:text, ["Invalid high water mark"], "library: the checks of a high water mark"},
      # The library will not have `XMLHttpRequest`: `fetch` replaces it.
      {:text, ["'XMLHttpRequest' is not defined"], "scope: the library has no XMLHttpRequest"},
      {:text, ["no server of WPT"], "runner: no server of WPT"},
      {:name, ~r/'(\w+)' is not defined/, "runner: no "},
      {:text, ["structuredClone"], "runner: no structuredClone"},
      {:name, ~r/The library has no ([\w.?]+\/\d)/, "library: no "},
      {:text, ["ArgumentError", "TypeError"], "library: ArgumentError, not TypeError"}
    ]
  end

  defp match({:test, test_path, %Regex{} = regex, group}, path, name, _message),
    do: if(path == test_path and Regex.match?(regex, name), do: group)

  defp match({:test, test_path, test_name, group}, path, name, _message),
    do: if(path == test_path and name == test_name, do: group)

  defp match({:path, prefix, group}, path, _name, _message),
    do: if(String.starts_with?(path, prefix), do: group)

  defp match({:text, texts, group}, _path, _name, message),
    do: if(Enum.all?(texts, &String.contains?(message, &1)), do: group)

  defp match({:name, regex, group}, _path, _name, message) do
    case capture(regex, message) do
      nil -> nil
      name -> group <> name
    end
  end

  defp capture(regex, message) do
    case Regex.run(regex, message) do
      [_match, name] -> name
      nil -> nil
    end
  end
end
