defmodule Web.Performance do
  @moduledoc """
  Times with a high resolution, and marks and measures, as `performance`
  of the High Resolution Time and User Timing Standards.

      Web.Performance.mark("query start")
      rows = run_query()
      measure = Web.Performance.measure("query", "query start")
      measure.duration
      #=> 12.345

  ## Time

  `now/0` gives the milliseconds from the time origin, as a float with a
  resolution of one microsecond. The time origin is the start of the
  application `:web`. The clock is monotonic: a change of the time of the
  system does not change it.

  `time_origin/0` gives the time origin in milliseconds of Unix time. Thus
  `time_origin() + now()` is the time now.

  ## Entries

  `mark/2` makes an entry for one moment, and `measure/3` makes an entry
  for the time between two moments. An entry is a struct with the
  attributes of the Standard as fields, in snake_case: `name`,
  `entry_type`, `start_time`, `duration`, and `detail`.

  The entries are the state of the process that makes them. A different
  process has its own entries, and the entries of a process go away with
  the process. The list has no limit, as in a browser: a process that
  runs for a long time must call `clear_marks/1` and `clear_measures/1`.
  """

  alias Web.DOMException
  alias Web.TypeError

  defmodule Mark do
    @moduledoc """
    The entry of one moment, as `PerformanceMark`.
    """

    defstruct name: "", entry_type: "mark", start_time: 0.0, duration: 0.0, detail: nil

    @type t :: %__MODULE__{
            name: String.t(),
            entry_type: String.t(),
            start_time: float(),
            duration: float(),
            detail: term()
          }
  end

  defmodule Measure do
    @moduledoc """
    The entry of the time between two moments, as `PerformanceMeasure`.
    """

    defstruct name: "", entry_type: "measure", start_time: 0.0, duration: 0.0, detail: nil

    @type t :: %__MODULE__{
            name: String.t(),
            entry_type: String.t(),
            start_time: float(),
            duration: float(),
            detail: term()
          }
  end

  @time_origin_key {__MODULE__, :time_origin}
  @entries_key {__MODULE__, :entries}

  @type entry :: Mark.t() | Measure.t()

  @typedoc "A name. An atom and a number become a string."
  @type name :: String.t() | atom() | number()

  @typedoc "The name of a mark, or a time in milliseconds from the time origin."
  @type moment :: name()

  # ---------------------------------------------------------------------------
  # Time
  # ---------------------------------------------------------------------------

  @doc false
  # Sets the time origin. The application calls this at its start.
  # `monotonic_us` is a value of the monotonic clock, in microseconds.
  @spec put_time_origin(integer()) :: :ok
  def put_time_origin(monotonic_us \\ :erlang.monotonic_time(:microsecond)) do
    # The time of the system at the same moment.
    age_us = :erlang.monotonic_time(:microsecond) - monotonic_us
    system_us = :os.system_time(:microsecond) - age_us
    :persistent_term.put(@time_origin_key, {monotonic_us, system_us})
  end

  @doc """
  Returns the milliseconds from the time origin.

  ## Examples

      iex> first = Web.Performance.now()
      iex> second = Web.Performance.now()
      iex> second >= first
      true
  """
  @spec now() :: float()
  def now do
    {monotonic_us, _system_us} = time_origin_us()
    (:erlang.monotonic_time(:microsecond) - monotonic_us) / 1000.0
  end

  @doc """
  Returns the time origin, in milliseconds of Unix time.
  """
  @spec time_origin() :: float()
  def time_origin do
    {_monotonic_us, system_us} = time_origin_us()
    system_us / 1000.0
  end

  @doc """
  Returns the data of `toJSON()`: a map with the time origin.
  """
  @spec to_json() :: %{String.t() => float()}
  def to_json, do: %{"timeOrigin" => time_origin()}

  # The origin is there after the start of the application. A call before
  # that sets it.
  defp time_origin_us do
    case :persistent_term.get(@time_origin_key, nil) do
      nil ->
        put_time_origin()
        :persistent_term.get(@time_origin_key)

      origin ->
        origin
    end
  end

  # ---------------------------------------------------------------------------
  # Marks and measures
  # ---------------------------------------------------------------------------

  @doc """
  Makes a mark, adds it to the entries of the process, and returns it.

  ## Options

    * `:start_time` - the time of the mark, in milliseconds from the time
      origin. The default is `now/0`.
    * `:detail` - data for the mark. The mark has a structured clone of it:
      see `Web.structured_clone/2`.

  Raises `Web.TypeError` for a time that is not a number, or that is below
  zero.

  ## Examples

      iex> mark = Web.Performance.mark("start", detail: %{step: 1})
      iex> {mark.name, mark.entry_type, mark.duration, mark.detail}
      {"start", "mark", 0.0, %{step: 1}}
      iex> Web.Performance.clear_marks("start")
      :ok
  """
  @spec mark(name(), keyword()) :: Mark.t()
  def mark(name, options \\ []) do
    options = options!(options, [:start_time, :detail])

    start_time =
      case Keyword.fetch(options, :start_time) do
        {:ok, time} -> time!(time)
        :error -> now()
      end

    put_entry(%Mark{name: text(name), start_time: start_time, detail: detail(options)})
  end

  @doc """
  Makes a measure, adds it to the entries of the process, and returns it.

  The three forms are:

      measure(name)                        # from the time origin to now
      measure(name, start_mark)            # from a mark to now
      measure(name, start_mark, end_mark)  # between two marks
      measure(name, options)

  A mark is the name of the mark that was made last with that name.

  ## Options

    * `:start` and `:end` - the name of a mark, or a time in milliseconds
      from the time origin;
    * `:duration` - the time in milliseconds. Give it with `:start` or with
      `:end`, not with the two;
    * `:detail` - data for the measure, as for `mark/2`.

  With no `:start`, the measure starts at the time origin. With no `:end`,
  it ends now.

  Raises `Web.DOMException` with the name `SyntaxError` for a mark that
  does not exist. Raises `Web.TypeError` for options that are not correct.

  ## Examples

      iex> Web.Performance.mark("a", start_time: 10.0)
      iex> Web.Performance.mark("b", start_time: 25.0)
      iex> measure = Web.Performance.measure("a to b", "a", "b")
      iex> {measure.start_time, measure.duration}
      {10.0, 15.0}
      iex> Web.Performance.measure("by options", end: "b", duration: 5.0).start_time
      20.0
      iex> Web.Performance.clear_marks()
      iex> Web.Performance.clear_measures()
      :ok
  """
  @spec measure(name(), moment() | keyword() | nil, moment() | nil) :: Measure.t()
  def measure(name, start_or_options \\ nil, end_mark \\ nil)

  def measure(name, options, end_mark) when is_list(options) and options != [] do
    options = options!(options, [:start, :end, :duration, :detail])

    if end_mark != nil do
      raise TypeError, "A measure with options cannot have an end mark."
    end

    start = Keyword.get(options, :start)
    finish = Keyword.get(options, :end)
    duration = duration!(Keyword.get(options, :duration), start, finish)

    end_time = end_time(finish, start, duration)
    start_time = start_time(start, end_time, duration)
    put_measure(name, start_time, end_time, detail(options))
  end

  def measure(name, start_mark, end_mark) do
    start_mark = if start_mark == [], do: nil, else: start_mark
    end_time = if end_mark == nil, do: now(), else: moment!(end_mark)
    start_time = if start_mark == nil, do: 0.0, else: moment!(start_mark)
    put_measure(name, start_time, end_time, nil)
  end

  # The rules of the Standard for the options of a measure.
  defp duration!(_duration, nil, nil) do
    raise TypeError, "A measure with options needs :start or :end."
  end

  defp duration!(nil, _start, _finish), do: nil

  defp duration!(_duration, start, finish) when start != nil and finish != nil do
    raise TypeError, "A measure cannot have :start, :end, and :duration."
  end

  defp duration!(duration, _start, _finish), do: time!(duration)

  defp end_time(nil, start, duration) when duration != nil, do: moment!(start) + duration
  defp end_time(nil, _start, _duration), do: now()
  defp end_time(finish, _start, _duration), do: moment!(finish)

  defp start_time(nil, end_time, duration) when duration != nil, do: end_time - duration
  defp start_time(nil, _end_time, _duration), do: 0.0
  defp start_time(start, _end_time, _duration), do: moment!(start)

  defp put_measure(name, start_time, end_time, detail) do
    put_entry(%Measure{
      name: text(name),
      start_time: start_time,
      duration: end_time - start_time,
      detail: detail
    })
  end

  # ---------------------------------------------------------------------------
  # The entries
  # ---------------------------------------------------------------------------

  @doc """
  Returns the entries of the process, in the sequence of their start times.
  """
  @spec get_entries() :: [entry()]
  def get_entries do
    # The list has the last entry first. The sort keeps the sequence of
    # two entries with the same start time.
    @entries_key
    |> Process.get([])
    |> Enum.reverse()
    |> Enum.sort_by(& &1.start_time)
  end

  @doc """
  Returns the entries of the process with the given type: `"mark"` or
  `"measure"`.
  """
  @spec get_entries_by_type(name()) :: [entry()]
  def get_entries_by_type(type) do
    type = text(type)
    Enum.filter(get_entries(), &(&1.entry_type == type))
  end

  @doc """
  Returns the entries of the process with the given name, and with the
  given type when there is one.
  """
  @spec get_entries_by_name(name(), name() | nil) :: [entry()]
  def get_entries_by_name(name, type \\ nil) do
    name = text(name)
    type = type && text(type)

    Enum.filter(get_entries(), fn entry ->
      entry.name == name and (type == nil or entry.entry_type == type)
    end)
  end

  @doc """
  Removes the marks of the process with the given name, or all its marks.
  """
  @spec clear_marks(name() | nil) :: :ok
  def clear_marks(name \\ nil), do: clear_entries("mark", name)

  @doc """
  Removes the measures of the process with the given name, or all its
  measures.
  """
  @spec clear_measures(name() | nil) :: :ok
  def clear_measures(name \\ nil), do: clear_entries("measure", name)

  defp put_entry(entry) do
    Process.put(@entries_key, [entry | Process.get(@entries_key, [])])
    entry
  end

  defp clear_entries(type, name) do
    name = name && text(name)

    entries =
      Enum.reject(Process.get(@entries_key, []), fn entry ->
        entry.entry_type == type and (name == nil or entry.name == name)
      end)

    Process.put(@entries_key, entries)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Arguments
  # ---------------------------------------------------------------------------

  # The time of a moment: a number is a time, and each other value is the
  # name of a mark.
  defp moment!(moment) when is_number(moment), do: time!(moment)

  defp moment!(mark) do
    name = text(mark)

    # The list has the last entry first.
    case Enum.find(Process.get(@entries_key, []), &match?(%Mark{name: ^name}, &1)) do
      %Mark{start_time: start_time} ->
        start_time

      nil ->
        raise DOMException, name: "SyntaxError", message: "The mark '#{name}' does not exist."
    end
  end

  defp time!(time) when is_number(time) and time >= 0, do: time * 1.0

  defp time!(time) do
    raise TypeError, "A time must be a number that is not below zero, got: #{inspect(time)}"
  end

  defp options!(options, permitted) do
    if not Keyword.keyword?(options) do
      raise TypeError, "The options must be a keyword list, got: #{inspect(options)}"
    end

    case Keyword.keys(options) -- permitted do
      [] -> options
      unknown -> raise TypeError, "Unknown options: #{inspect(unknown)}"
    end
  end

  # The Standard keeps a structured clone of the detail.
  defp detail(options) do
    case Keyword.get(options, :detail) do
      nil -> nil
      detail -> Web.structured_clone(detail)
    end
  end

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_atom(value) or is_number(value), do: to_string(value)

  defp text(value) do
    raise TypeError, "A name must be a string, an atom, or a number, got: #{inspect(value)}"
  end
end
