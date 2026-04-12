defmodule Web.Console do
  @moduledoc """
  Console helpers backed by Erlang's native `:logger`.
  """

  @group_depth_key {__MODULE__, :group_depth}
  @timers_key {__MODULE__, :timers}
  @counters_key {__MODULE__, :counters}

  @spec log(term()) :: :ok
  def log(data), do: write(:notice, data)

  @spec info(term()) :: :ok
  def info(data), do: write(:info, data)

  @spec warn(term()) :: :ok
  def warn(data), do: write(:warning, data)

  @spec error(term()) :: :ok
  def error(data), do: write(:error, data)

  @spec debug(term()) :: :ok
  def debug(data), do: write(:debug, data)

  @spec group(term() | nil) :: :ok
  def group(label \\ nil) do
    if !is_nil(label), do: log(label)
    Process.put(@group_depth_key, group_depth() + 1)
    :ok
  end

  @spec group_collapsed(term() | nil) :: :ok
  def group_collapsed(label \\ nil), do: group(label)

  def unquote(:groupCollapsed)(label \\ nil), do: group_collapsed(label)

  @spec group_end() :: :ok
  def group_end do
    Process.put(@group_depth_key, max(group_depth() - 1, 0))
    :ok
  end

  def unquote(:groupEnd)(), do: group_end()

  @spec time(String.t() | atom()) :: :ok
  def time(label \\ "default") do
    timers = Process.get(@timers_key, %{})
    Process.put(@timers_key, Map.put(timers, normalize_label(label), monotonic_us()))
    :ok
  end

  @spec time_log(String.t() | atom(), term() | nil) :: :ok
  def time_log(label \\ "default", data \\ nil) do
    case Map.get(Process.get(@timers_key, %{}), normalize_label(label)) do
      nil ->
        warn("Timer '#{normalize_label(label)}' does not exist")

      started_at ->
        log_elapsed(label, started_at, data)
    end

    :ok
  end

  def unquote(:timeLog)(label \\ "default", data \\ nil), do: time_log(label, data)

  @spec time_end(String.t() | atom()) :: :ok
  def time_end(label \\ "default") do
    normalized = normalize_label(label)
    timers = Process.get(@timers_key, %{})

    case Map.pop(timers, normalized) do
      {nil, _timers} ->
        warn("Timer '#{normalized}' does not exist")

      {started_at, updated_timers} ->
        Process.put(@timers_key, updated_timers)
        log_elapsed(normalized, started_at)
    end

    :ok
  end

  def unquote(:timeEnd)(label \\ "default"), do: time_end(label)

  @spec count(String.t() | atom()) :: :ok
  def count(label \\ "default") do
    normalized = normalize_label(label)
    counters = Process.get(@counters_key, %{})
    value = Map.get(counters, normalized, 0) + 1
    Process.put(@counters_key, Map.put(counters, normalized, value))
    info("#{normalized}: #{value}")
  end

  @spec count_reset(String.t() | atom()) :: :ok
  def count_reset(label \\ "default") do
    normalized = normalize_label(label)
    counters = Process.get(@counters_key, %{})

    if Map.has_key?(counters, normalized) do
      Process.put(@counters_key, Map.delete(counters, normalized))
    else
      warn("Count for '#{normalized}' does not exist")
    end

    :ok
  end

  def unquote(:countReset)(label \\ "default"), do: count_reset(label)

  @spec table([map() | struct()] | map() | struct() | term()) :: :ok
  def table(data) do
    data
    |> normalize_table_rows()
    |> format_table()
    |> log()
  end

  @spec trace() :: :ok
  def trace do
    {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)
    stacktrace = Enum.drop(stacktrace, 1)

    lines =
      ["Trace"]
      |> Kernel.++(Enum.map(stacktrace, &format_stacktrace_line/1))
      |> Enum.join("\n")

    write(:notice, lines, action: :trace)
  end

  # coveralls-ignore-next-line
  def unquote(:assert)(condition, message \\ "Assertion failed")

  def unquote(:assert)(condition, _message) when condition, do: :ok

  def unquote(:assert)(_condition, message) do
    error(message || "Assertion failed")
  end

  defp write(level, data, extra_metadata \\ []) do
    metadata =
      [console: true, group_depth: group_depth()]
      |> Kernel.++(extra_metadata)
      |> Map.new()

    message = indent() <> format_data(data)

    previous_metadata = :logger.get_process_metadata()
    base_metadata = if previous_metadata == :undefined, do: %{}, else: previous_metadata

    try do
      :logger.set_process_metadata(Map.merge(base_metadata, metadata))
      apply(:logger, level, [message])
    after
      restore_process_metadata(previous_metadata)
    end

    :ok
  end

  defp log_elapsed(label, started_at, data \\ nil) do
    elapsed = monotonic_us() - started_at
    elapsed_ms = :erlang.float_to_binary(elapsed / 1000.0, decimals: 3)

    suffix =
      case data do
        nil -> ""
        _ -> " " <> format_data(data)
      end

    info("#{normalize_label(label)}: #{elapsed_ms} ms#{suffix}")
  end

  defp group_depth, do: Process.get(@group_depth_key, 0)
  defp indent, do: String.duplicate("  ", group_depth())
  defp monotonic_us, do: :erlang.monotonic_time(:microsecond)
  defp normalize_label(label) when is_atom(label), do: Atom.to_string(label)
  defp normalize_label(label), do: to_string(label)

  defp format_data(data) when is_binary(data), do: data

  defp format_data(data) when is_list(data) do
    if Keyword.keyword?(data) do
      inspect(data, pretty: true)
    else
      Enum.map_join(data, " ", &format_data/1)
    end
  end

  defp format_data(data), do: inspect(data, pretty: true)

  defp normalize_table_rows(data) when is_list(data) do
    Enum.map(data, &normalize_table_row/1)
  end

  defp normalize_table_rows(%_{} = data), do: [normalize_table_row(data)]
  defp normalize_table_rows(%{} = data), do: [normalize_table_row(data)]
  defp normalize_table_rows(data), do: [%{"value" => format_data(data)}]

  defp normalize_table_row(%_{} = row) do
    row
    |> Map.from_struct()
    |> normalize_table_row()
  end

  defp normalize_table_row(%{} = row) do
    row
    |> Enum.map(fn {key, value} -> {to_string(key), format_data(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp format_table([]), do: "(empty)"

  defp format_table(rows) do
    headers =
      rows
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()

    widths =
      Enum.reduce(headers, %{}, fn header, acc ->
        width =
          rows
          |> Enum.map(fn row -> row |> Map.get(header, "") |> to_string() |> String.length() end)
          |> Enum.max()
          |> max(String.length(header))

        Map.put(acc, header, width)
      end)

    header_line = render_row(headers, widths)
    separator = render_separator(headers, widths)

    body =
      Enum.map_join(rows, "\n", fn row ->
        headers
        |> Enum.map(&Map.get(row, &1, ""))
        |> render_row(widths, headers)
      end)

    Enum.join([header_line, separator, body], "\n")
  end

  defp render_row(headers, widths), do: render_row(headers, widths, headers)

  defp render_row(values, widths, headers) do
    cells =
      values
      |> Enum.zip(headers)
      |> Enum.map(fn {value, header} ->
        value
        |> to_string()
        |> String.pad_trailing(Map.fetch!(widths, header))
      end)

    "| " <> Enum.join(cells, " | ") <> " |"
  end

  defp render_separator(headers, widths) do
    cells =
      Enum.map(headers, fn header ->
        String.duplicate("-", Map.fetch!(widths, header))
      end)

    "|-" <> Enum.join(cells, "-|-") <> "-|"
  end

  @doc false
  def format_stacktrace_line({module, function, arity, location}) do
    location_suffix =
      case Keyword.take(location, [:file, :line]) do
        [file: file, line: line] -> " (#{normalize_file(file)}:#{line})"
        [file: file] -> " (#{normalize_file(file)})"
        _ -> ""
      end

    "    at #{inspect(module)}.#{function}/#{arity}#{location_suffix}"
  end

  defp normalize_file(file), do: to_string(file)

  defp restore_process_metadata(:undefined), do: :logger.unset_process_metadata()
  defp restore_process_metadata(metadata), do: :logger.set_process_metadata(metadata)
end
