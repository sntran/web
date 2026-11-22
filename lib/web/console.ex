defmodule Web.Console do
  @moduledoc """
  The functions of `console` of the Console Standard, for the `Logger` of
  Elixir.

      Web.Console.log("The server started")
      Web.Console.warn(["The disk is %d%% full", 91])
      Web.Console.error(%{reason: :timeout})

  Each function writes one message with `:logger`, thus the configuration
  of `Logger` applies: the level, the format, and the handlers. Each
  function returns `:ok`.

  ## The arguments

  The functions of ECMAScript take a variable number of arguments. In this
  module, `data` is one argument, or a list of arguments:

      Web.Console.log("one argument")
      Web.Console.log(["user", %{id: 7}])
      #=> user %{id: 7}

  A keyword list is one argument. To write a list as one argument, put it
  in a list: `Web.Console.log([[1, 2, 3]])`.

  A string is written as it is. Each other argument is written with
  `inspect/2`. The arguments have a space between them.

  When there are two or more arguments and the first one is a string, the
  string is a format, as in the Standard:

    * `%s` - the argument as a string;
    * `%d` and `%i` - the argument as an integer;
    * `%f` - the argument as a float;
    * `%o` and `%O` - the argument with `inspect/2`;
    * `%c` - uses one argument and writes nothing. It is for CSS in a
      browser;
    * `%%` - the character `%`.

  ## The levels

  | Function | Level of `Logger` |
  | --- | --- |
  | `debug/1` | `:debug` |
  | `info/1`, `count/1`, `time_log/2`, `time_end/1` | `:info` |
  | `log/1`, `dir/2`, `dirxml/1`, `table/2`, `trace/1`, `group/1` | `:notice` |
  | `warn/1`, and the warnings of the timers and the counters | `:warning` |
  | `error/1`, `assert/2` | `:error` |

  ## The metadata

  Each message has this metadata of `Logger`:

    * `console: true`;
    * `console_method` - the name of the function, such as `:log` or
      `:time_end`;
    * `group_depth` - the number of open groups.

  ## The state

  The groups, the timers, and the counters are the state of the process
  that calls the functions. A different process has its own state. The
  depth of the groups goes with `Web.AsyncContext` into the callbacks of a
  promise and of a stream.
  """

  @group_depth_key {__MODULE__, :group_depth}
  @timers_key {__MODULE__, :timers}
  @counters_key {__MODULE__, :counters}

  @typedoc "One argument, or a list of arguments."
  @type data :: term()

  @typedoc "The name of a timer or of a counter. It becomes a string."
  @type label :: term()

  # ---------------------------------------------------------------------------
  # Logging
  # ---------------------------------------------------------------------------

  @doc "Writes a message."
  @spec log(data()) :: :ok
  def log(data \\ []), do: write(:notice, :log, data)

  @doc "Writes a message of information."
  @spec info(data()) :: :ok
  def info(data \\ []), do: write(:info, :info, data)

  @doc "Writes a warning."
  @spec warn(data()) :: :ok
  def warn(data \\ []), do: write(:warning, :warn, data)

  @doc "Writes an error."
  @spec error(data()) :: :ok
  def error(data \\ []), do: write(:error, :error, data)

  @doc "Writes a message for a developer."
  @spec debug(data()) :: :ok
  def debug(data \\ []), do: write(:debug, :debug, data)

  @doc """
  Writes one value with `inspect/2`, with no limit of length. The format of
  `log/1` does not apply.
  """
  @spec dir(term(), keyword()) :: :ok
  def dir(item, _options \\ []) do
    emit(:notice, :dir, inspect(item, pretty: true, limit: :infinity))
  end

  @doc "Writes a message, as `log/1`."
  @spec dirxml(data()) :: :ok
  def dirxml(data \\ []), do: write(:notice, :dirxml, data)

  @doc """
  Writes an error when the condition is `false` or `nil`.

  The message starts with `Assertion failed`.
  """
  @spec assert(term(), data()) :: :ok
  def assert(condition, data \\ [])

  def assert(condition, data) do
    if condition do
      :ok
    else
      emit(:error, :assert, format(assertion(arguments(data))))
    end
  end

  defp assertion([]), do: ["Assertion failed"]
  defp assertion([first | rest]) when is_binary(first), do: ["Assertion failed: " <> first | rest]
  defp assertion(args), do: ["Assertion failed" | args]

  @doc """
  Closes all the groups. A log has no screen to clear.
  """
  @spec clear() :: :ok
  def clear, do: put_group_depth(0)

  @doc """
  Writes the stack of the process, after the line `Trace`.
  """
  @spec trace(data()) :: :ok
  def trace(data \\ []) do
    {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)

    header =
      case arguments(data) do
        [] -> "Trace"
        args -> "Trace: " <> format(args)
      end

    lines =
      stacktrace
      |> Enum.reject(fn {module, _function, _arity, _location} ->
        module in [__MODULE__, Process]
      end)
      |> Enum.map(&format_stacktrace_line/1)

    emit(:notice, :trace, Enum.join([header | lines], "\n"))
  end

  # ---------------------------------------------------------------------------
  # Tables
  # ---------------------------------------------------------------------------

  @doc """
  Writes data as a table.

  The rows are the elements of a list, or the pairs of a map. The columns
  are the keys of each row. A row that is not a map or a list is in the
  column `Values`. `columns` is the list of the columns to show.

  Data that is not a list or a map is written as with `log/1`.

      Web.Console.table([%{name: "Ada", score: 10}, %{name: "Linus", score: 8}])
      #=> | (index) | name    | score |
      #=> |---------|---------|-------|
      #=> | 0       | "Ada"   | 10    |
      #=> | 1       | "Linus" | 8     |
  """
  @spec table(term(), [term()] | nil) :: :ok
  def table(data, columns \\ nil)

  def table(data, columns) when is_list(data) or is_map(data) do
    if Keyword.keyword?(data) and data != [] do
      # A keyword list has pairs, as a map has.
      render_table(data, columns)
    else
      render_table(table_rows(data), columns)
    end
  end

  def table(data, _columns), do: write(:notice, :table, [data])

  defp table_rows(data) when is_list(data) do
    data |> Enum.with_index() |> Enum.map(fn {row, index} -> {index, row} end)
  end

  defp table_rows(%_{} = struct), do: struct |> Map.from_struct() |> table_rows()
  defp table_rows(%{} = map), do: Enum.sort_by(Map.to_list(map), &label(elem(&1, 0)))

  defp render_table(rows, columns) do
    rows = Enum.map(rows, fn {index, row} -> {label(index), table_cells(row)} end)

    headers =
      case columns do
        nil ->
          rows
          |> Enum.flat_map(fn {_index, cells} -> Enum.map(cells, &elem(&1, 0)) end)
          |> Enum.uniq()

        list ->
          Enum.map(list, &label/1)
      end

    headers = ["(index)" | sort_values_last(headers)]

    lines =
      Enum.map(rows, fn {index, cells} ->
        cells = Map.new(cells)
        [index | Enum.map(tl(headers), &Map.get(cells, &1, ""))]
      end)

    widths =
      Enum.map(Enum.zip_with([headers | lines], & &1), fn column ->
        column |> Enum.map(&String.length/1) |> Enum.max()
      end)

    separator = "|-" <> Enum.map_join(widths, "-|-", &String.duplicate("-", &1)) <> "-|"

    table =
      [render_row(headers, widths), separator | Enum.map(lines, &render_row(&1, widths))]
      |> Enum.join("\n")

    emit(:notice, :table, table)
  end

  # The cells of a row: a list of pairs of the column and the text.
  defp table_cells(%_{} = struct), do: struct |> Map.from_struct() |> table_cells()

  defp table_cells(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {label(key), display_cell(value)} end)
    |> Enum.sort()
  end

  defp table_cells(row) when is_tuple(row), do: table_cells(Tuple.to_list(row))

  defp table_cells(row) when is_list(row) and row != [] do
    if Keyword.keyword?(row) do
      Enum.map(row, fn {key, value} -> {label(key), display_cell(value)} end)
    else
      row
      |> Enum.with_index()
      |> Enum.map(fn {value, index} -> {label(index), display_cell(value)} end)
    end
  end

  defp table_cells(value), do: [{"Values", display_cell(value)}]

  defp display_cell(value), do: inspect(value)

  defp sort_values_last(headers) do
    {values, others} = Enum.split_with(headers, &(&1 == "Values"))
    others ++ values
  end

  defp render_row(cells, widths) do
    cells =
      cells
      |> Enum.zip(widths)
      |> Enum.map_join(" | ", fn {cell, width} -> String.pad_trailing(cell, width) end)

    "| " <> cells <> " |"
  end

  # ---------------------------------------------------------------------------
  # Groups
  # ---------------------------------------------------------------------------

  @doc """
  Opens a group. The messages after it have two more spaces at the start
  of each line, until `group_end/0`. `data` is the label of the group.
  """
  @spec group(data()) :: :ok
  def group(data \\ []) do
    case arguments(data) do
      [] -> :ok
      args -> emit(:notice, :group, format(args))
    end

    put_group_depth(group_depth() + 1)
  end

  @doc "Opens a group, as `group/1`. A log cannot collapse a group."
  @spec group_collapsed(data()) :: :ok
  def group_collapsed(data \\ []), do: group(data)

  @doc "Closes the group that was opened last. With no open group, it has no effect."
  @spec group_end() :: :ok
  def group_end, do: put_group_depth(max(group_depth() - 1, 0))

  # ---------------------------------------------------------------------------
  # Timers
  # ---------------------------------------------------------------------------

  @doc """
  Starts a timer. A timer that runs is not started again: the function
  writes a warning.
  """
  @spec time(label()) :: :ok
  def time(label \\ "default") do
    label = label(label)
    timers = Process.get(@timers_key, %{})

    if is_map_key(timers, label) do
      emit(:warning, :time, "Timer '#{label}' already exists")
    else
      Process.put(@timers_key, Map.put(timers, label, monotonic_us()))
      :ok
    end
  end

  @doc """
  Writes the time of a timer, and the data. The timer continues. With no
  such timer, the function writes a warning.
  """
  @spec time_log(label(), data()) :: :ok
  def time_log(label \\ "default", data \\ []) do
    label = label(label)

    case Process.get(@timers_key, %{}) do
      %{^label => started_at} -> emit_elapsed(:time_log, label, started_at, arguments(data))
      _timers -> emit(:warning, :time_log, "Timer '#{label}' does not exist")
    end
  end

  @doc """
  Writes the time of a timer, and stops it. With no such timer, the
  function writes a warning.
  """
  @spec time_end(label()) :: :ok
  def time_end(label \\ "default") do
    label = label(label)

    case Map.pop(Process.get(@timers_key, %{}), label) do
      {nil, _timers} ->
        emit(:warning, :time_end, "Timer '#{label}' does not exist")

      {started_at, timers} ->
        Process.put(@timers_key, timers)
        emit_elapsed(:time_end, label, started_at, [])
    end
  end

  defp emit_elapsed(method, label, started_at, args) do
    elapsed_ms = :erlang.float_to_binary((monotonic_us() - started_at) / 1000.0, decimals: 3)
    # The label is not a format.
    emit(
      :info,
      method,
      Enum.join(["#{label}: #{elapsed_ms} ms" | Enum.map(args, &display/1)], " ")
    )
  end

  # ---------------------------------------------------------------------------
  # Counters
  # ---------------------------------------------------------------------------

  @doc "Adds one to a counter, and writes its value."
  @spec count(label()) :: :ok
  def count(label \\ "default") do
    label = label(label)
    counters = Process.get(@counters_key, %{})
    value = Map.get(counters, label, 0) + 1
    Process.put(@counters_key, Map.put(counters, label, value))
    emit(:info, :count, "#{label}: #{value}")
  end

  @doc """
  Sets a counter to zero. With no such counter, the function writes a
  warning.
  """
  @spec count_reset(label()) :: :ok
  def count_reset(label \\ "default") do
    label = label(label)
    counters = Process.get(@counters_key, %{})

    if is_map_key(counters, label) do
      Process.put(@counters_key, Map.delete(counters, label))
      :ok
    else
      emit(:warning, :count_reset, "Count for '#{label}' does not exist")
    end
  end

  # ---------------------------------------------------------------------------
  # The arguments and the format
  # ---------------------------------------------------------------------------

  defp write(level, method, data), do: emit(level, method, format(arguments(data)))

  # A list is the list of the arguments. A keyword list is one argument.
  defp arguments([]), do: []

  defp arguments(data) when is_list(data) do
    if Keyword.keyword?(data), do: [data], else: data
  end

  defp arguments(data), do: [data]

  # The Formatter of the Console Standard: it applies only when there are
  # two or more arguments, and the first one is a string.
  defp format([first, _second | _rest] = args) when is_binary(first) do
    {text, rest} = specifiers(first, tl(args), [])
    Enum.join([text | Enum.map(rest, &display/1)], " ")
  end

  defp format(args), do: Enum.map_join(args, " ", &display/1)

  defp specifiers(text, args, done) do
    case :binary.split(text, "%") do
      [text] ->
        {IO.iodata_to_binary([done, text]), args}

      [before, <<?%, rest::binary>>] ->
        specifiers(rest, args, [done, before, "%"])

      [before, <<specifier, rest::binary>>] when specifier in ~c"sdifoOc" and args != [] ->
        [arg | args] = args
        specifiers(rest, args, [done, before, convert(specifier, arg)])

      [before, rest] ->
        specifiers(rest, args, [done, before, "%"])
    end
  end

  defp convert(?s, arg), do: text(arg)

  defp convert(specifier, arg) when specifier in ~c"di" and is_integer(arg),
    do: Integer.to_string(arg)

  defp convert(specifier, arg) when specifier in ~c"di" and is_float(arg),
    do: Integer.to_string(trunc(arg))

  defp convert(?f, arg) when is_number(arg), do: Float.to_string(arg * 1.0)
  defp convert(specifier, _arg) when specifier in ~c"dif", do: "NaN"
  defp convert(?c, _arg), do: ""
  defp convert(_object, arg), do: inspect(arg, pretty: true)

  defp display(arg) when is_binary(arg), do: arg
  defp display(arg), do: inspect(arg, pretty: true)

  # A value as a string, with no quotation marks where that is possible.
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp text(value), do: inspect(value)

  defp label(label), do: text(label)

  # ---------------------------------------------------------------------------
  # The output
  # ---------------------------------------------------------------------------

  defp emit(level, method, message) do
    depth = group_depth()
    indent = String.duplicate("  ", depth)
    message = indent <> String.replace(message, "\n", "\n" <> indent)

    :logger.log(level, message, %{console: true, console_method: method, group_depth: depth})
  end

  # The depth is also in the metadata of the logger of the process. Thus
  # the snapshot of `Web.AsyncContext` takes it to the callbacks that run in
  # a different process.
  defp group_depth do
    case Process.get(@group_depth_key) do
      nil -> logger_group_depth()
      depth -> depth
    end
  end

  defp logger_group_depth do
    case :logger.get_process_metadata() do
      %{group_depth: depth} when is_integer(depth) and depth >= 0 -> depth
      _other -> 0
    end
  end

  defp put_group_depth(depth) do
    Process.put(@group_depth_key, depth)
    :logger.update_process_metadata(%{group_depth: depth})
  end

  defp monotonic_us, do: :erlang.monotonic_time(:microsecond)

  @doc false
  def format_stacktrace_line({module, function, arity, location}) do
    arity = if is_list(arity), do: length(arity), else: arity

    place =
      case {Keyword.get(location, :file), Keyword.get(location, :line)} do
        {nil, _line} -> ""
        {file, nil} -> " (#{file})"
        {file, line} -> " (#{file}:#{line})"
      end

    "    at #{inspect(module)}.#{function}/#{arity}#{place}"
  end
end
