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

  The list has no limit, as the registry of the entry types specifies for
  "mark" and "measure": a process that runs for a long time must call
  `clear_marks/1` and `clear_measures/1`.

  ## The global object

  Each process is a global object of the Standards: it has its own
  performance entry buffer, and the entries of a process go away with the
  process. The functions act on the timeline of the global object of the
  calling process: for a usual process, the process itself. The time
  origin is the same for each global object.

  The callback of a `Web.PerformanceObserver` runs in a different process,
  but with the global object of its observer, as the Standard specifies:
  in the callback, the functions of this module act on the timeline of
  that global object, and its observers get the entries that the callback
  makes.

  ## Observers

  A `Web.PerformanceObserver` gets the later entries of its global object.
  A process with no observer keeps its entries in its process dictionary:
  `mark/2` and `measure/3` then send no message. The first observer of a
  process moves the entries to a server of the global object. After that,
  `mark/2` and `measure/3` send the entry to the server, and do not wait
  for it. A measure from the name of a mark asks the server for the mark.
  """

  alias Web.DOMException
  alias Web.Internal.PerformanceTimeline, as: Timeline
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

    @doc """
    Makes a mark, as the constructor `new PerformanceMark(markName,
    markOptions)`. The options are the options of `Web.Performance.mark/2`.

    The mark is not an entry of a global object: `Web.Performance.mark/2`
    makes a mark and adds it.

    ## Examples

        iex> mark = Web.Performance.Mark.new("loaded", start_time: 2.5)
        iex> {mark.name, mark.start_time}
        {"loaded", 2.5}
        iex> Web.Performance.get_entries_by_name("loaded")
        []
    """
    @spec new(Web.Performance.name(), keyword()) :: t()
    def new(name, options \\ []), do: Web.Performance.__mark__(name, options)

    @doc """
    Returns the data of `toJSON()`: a map with the attributes of
    `PerformanceEntry`.
    """
    @spec to_json(t()) :: %{String.t() => term()}
    def to_json(%__MODULE__{} = mark), do: Web.Performance.__entry_json__(mark)
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

    @doc """
    Returns the data of `toJSON()`: a map with the attributes of
    `PerformanceEntry`.
    """
    @spec to_json(t()) :: %{String.t() => term()}
    def to_json(%__MODULE__{} = measure), do: Web.Performance.__entry_json__(measure)
  end

  @time_origin_key {__MODULE__, :time_origin}

  @type entry :: Mark.t() | Measure.t()

  @typedoc "A name. An atom and a number become a string."
  @type name :: String.t() | atom() | number()

  @typedoc """
  The name of a mark, or a time in milliseconds from the time origin: the
  type of the options `:start` and `:end` of `measure/3`.
  """
  @type moment :: String.t() | atom() | number()

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
  Makes a mark, adds it to the entries of the global object of the
  process, and returns it.

  ## Options

    * `:start_time` - the time of the mark, in milliseconds from the time
      origin. The default is `now/0`.
    * `:detail` - data for the mark. The mark has a structured clone of it:
      see `Web.structured_clone/2`.

  The options are the members of `PerformanceMarkOptions`. As a dictionary
  of Web IDL, the function ignores each other option.

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
  def mark(name, options \\ []), do: name |> __mark__(options) |> put_entry()

  @doc false
  # The steps of the constructor of `PerformanceMark`: the mark is not an
  # entry of a global object.
  @spec __mark__(name(), keyword()) :: Mark.t()
  def __mark__(name, options) do
    options = options!(options, [:start_time, :detail])

    start_time =
      case Keyword.fetch(options, :start_time) do
        {:ok, time} -> time!(time)
        :error -> now()
      end

    %Mark{name: text(name), start_time: start_time, detail: detail(options)}
  end

  @doc false
  # The default `toJSON()` of `PerformanceEntry`.
  @spec __entry_json__(entry()) :: %{String.t() => term()}
  def __entry_json__(entry) do
    %{
      "name" => entry.name,
      "entryType" => entry.entry_type,
      "startTime" => entry.start_time,
      "duration" => entry.duration
    }
  end

  @doc """
  Makes a measure, adds it to the entries of the global object of the
  process, and returns it.

  The three forms are:

      measure(name)                        # from the time origin to now
      measure(name, start_mark)            # from a mark to now
      measure(name, start_mark, end_mark)  # between two marks
      measure(name, options)

  A mark is the name of the mark that was made last with that name. An
  atom and a number become the text of a name, as a `DOMString` of Web
  IDL: a time is only an option.

  ## Options

    * `:start` and `:end` - the name of a mark, or a time in milliseconds
      from the time origin;
    * `:duration` - the time in milliseconds. Give it with `:start` or with
      `:end`, not with the two;
    * `:detail` - data for the measure, as for `mark/2`.

  With no `:start`, the measure starts at the time origin. With no `:end`,
  it ends now. The options are the members of `PerformanceMeasureOptions`:
  the function ignores each other option. A list of options with no member
  is no options.

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
  @spec measure(name(), name() | keyword() | nil, name() | nil) :: Measure.t()
  def measure(name, start_or_options \\ nil, end_mark \\ nil)

  def measure(name, options, end_mark) when is_list(options) do
    case options!(options, [:start, :end, :duration, :detail]) do
      # Step 1: the rules of the options apply when at least one member
      # is there.
      [] -> measure(name, nil, end_mark)
      options -> measure_with_options(name, options, end_mark)
    end
  end

  def measure(name, start_mark, end_mark) do
    end_time = if end_mark == nil, do: now(), else: mark_time!(end_mark)
    start_time = if start_mark == nil, do: 0.0, else: mark_time!(start_mark)
    put_measure(name, start_time, end_time, nil)
  end

  defp measure_with_options(name, options, end_mark) do
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
  Returns the entries of the global object of the process, in the
  sequence of their start times.
  """
  @spec get_entries() :: [entry()]
  def get_entries, do: __filter__(Timeline.entries(), nil, nil)

  @doc """
  Returns the entries of the global object of the process with the given
  type: `"mark"` or `"measure"`.
  """
  @spec get_entries_by_type(name()) :: [entry()]
  def get_entries_by_type(type), do: __filter__(Timeline.entries(), nil, text(type))

  @doc """
  Returns the entries of the global object of the process with the given
  name, and with the given type when there is one.
  """
  @spec get_entries_by_name(name(), name() | nil) :: [entry()]
  def get_entries_by_name(name, type \\ nil) do
    __filter__(Timeline.entries(), text(name), type && text(type))
  end

  @doc false
  # The steps "filter buffer by name and type" of the Performance Timeline:
  # `name` and `type` are strings, or `nil` for null. The sort keeps the
  # sequence of two entries with the same start time.
  @spec __filter__([entry()], String.t() | nil, String.t() | nil) :: [entry()]
  def __filter__(buffer, name, type) do
    buffer
    |> Enum.filter(&((type == nil or &1.entry_type == type) and (name == nil or &1.name == name)))
    |> Enum.sort_by(& &1.start_time)
  end

  @doc """
  Removes the marks of the global object of the process with the given
  name, or all its marks.
  """
  @spec clear_marks(name() | nil) :: :ok
  def clear_marks(name \\ nil), do: clear_entries("mark", name)

  @doc """
  Removes the measures of the global object of the process with the given
  name, or all its measures.
  """
  @spec clear_measures(name() | nil) :: :ok
  def clear_measures(name \\ nil), do: clear_entries("measure", name)

  # The steps "queue a PerformanceEntry" and "add entry to the performance
  # entry buffer", on the timeline of the global object of the process.
  defp put_entry(entry) do
    :ok = Timeline.put(entry)
    entry
  end

  defp clear_entries(type, name), do: Timeline.clear(type, name && text(name))

  # ---------------------------------------------------------------------------
  # Arguments
  # ---------------------------------------------------------------------------

  # The steps "convert a mark to a timestamp" for a member of the options:
  # a number is a time, and each other value is the name of a mark.
  defp moment!(moment) when is_number(moment), do: time!(moment)
  defp moment!(mark), do: mark_time!(mark)

  # The same steps for a `DOMString`: a number is the text of a name. The
  # mark is the mark that the global object made last with the name.
  defp mark_time!(mark) do
    name = text(mark)

    case Timeline.last_mark(name) do
      nil ->
        raise DOMException, name: "SyntaxError", message: "The mark '#{name}' does not exist."

      start_time ->
        start_time
    end
  end

  defp time!(time) when is_number(time) and time >= 0, do: time * 1.0

  defp time!(time) do
    raise TypeError, "A time must be a number that is not below zero, got: #{inspect(time)}"
  end

  # A dictionary of Web IDL has only its members: each other option has no
  # effect.
  defp options!(options, members) do
    if not Keyword.keyword?(options) do
      raise TypeError, "The options must be a keyword list, got: #{inspect(options)}"
    end

    Keyword.take(options, members)
  end

  # The Standard keeps a structured clone of the detail.
  defp detail(options) do
    case Keyword.get(options, :detail) do
      nil -> nil
      detail -> Web.structured_clone(detail)
    end
  end

  @doc false
  # The conversion of a `DOMString`: an atom and a number become a string.
  @spec __text__(term()) :: String.t()
  def __text__(value), do: text(value)

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_atom(value) or is_number(value), do: to_string(value)

  defp text(value) do
    raise TypeError, "A name must be a string, an atom, or a number, got: #{inspect(value)}"
  end
end
