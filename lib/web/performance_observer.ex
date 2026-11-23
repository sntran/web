defmodule Web.PerformanceObserver do
  @moduledoc ~S"""
  An observer of the marks and the measures, as `PerformanceObserver` of
  the Performance Timeline Standard.

      observer =
        Web.PerformanceObserver.new(fn list, _observer, _options ->
          for entry <- Web.PerformanceObserverEntryList.get_entries(list) do
            IO.puts("#{entry.name}: #{entry.duration} ms")
          end
        end)

      Web.PerformanceObserver.observe(observer, entry_types: ["measure"])

      Web.Performance.mark("start")
      Web.Performance.measure("query", "start")
      # Prints "query: 0.012 ms" after the call.

  ## The global object

  Each process is a global object of the Standards: it has its own
  performance entry buffer (see `Web.Performance`). An observer belongs to
  the global object of the process that calls `new/1`, as the relevant
  global object of the Standard. It observes that global object only:
  `observe/2`, `disconnect/1`, and `take_records/1` act on the same
  observer from each process, and `observe/2` registers the observer in
  its global object, not in the calling process.

  ## The callback

  The callback runs in a process of the global object, after the call that
  made the entry, not in the call of `Web.Performance.mark/2` or
  `Web.Performance.measure/3`. One callback gets each entry that came
  before it runs. The callbacks of the observers of a global object run one
  at a time, in the sequence of their registration, as one task of the
  Standard. A disconnect and a new call of `observe/2` put an observer at
  the end.

  The callback gets three arguments, as the `PerformanceObserverCallback`
  of the Standard. A function with fewer arguments gets the first ones:

    * the entry list, a `Web.PerformanceObserverEntryList`;
    * the observer;
    * the options of the callback: `%{dropped_entries_count: 0}` in the
      first callback after a call to `observe/2`, and `%{}` in the other
      callbacks. The registry of the entry types gives "mark" and "measure"
      no buffer limit: no entry is dropped, thus the count is always 0.

  The callback runs with the global object of the observer. Thus
  `Web.Performance.mark/2`, `Web.Performance.measure/3`, the functions
  `get_entries*` and `clear_*` of `Web.Performance`, and
  `Web.Performance.now/0` in the callback act on that global object: its
  timeline, and its time origin, which is the same for each process. The
  observers of that global object get the entries that the callback
  makes. A new observer of the callback belongs to the same global object.
  The callback can call each function of this module. A value that the
  callback throws goes to the log, and the observer continues. The
  callback runs in the empty context of `Web.AsyncContext`, as the
  proposal specifies for the callback of an observer.

  ## Lifetime

  The observer stops when its global object stops: a callback that did
  not start does not run. After that, `observe/2` and `disconnect/1` have
  no effect, and `take_records/1` returns `[]`.
  """

  alias Web.Internal.PerformanceObserver, as: Engine
  alias Web.Internal.PerformanceTimeline
  alias Web.PerformanceObserverEntryList

  @enforce_keys [:address, :token]
  defstruct [:address, :token]

  @typedoc "A handle to one observer. The fields are private."
  @type t :: %__MODULE__{address: pid(), token: reference()}

  @typedoc """
  The options of the callback, as `PerformanceObserverCallbackOptions`.
  """
  @type callback_options :: %{optional(:dropped_entries_count) => non_neg_integer()}

  @typedoc """
  The callback, as `PerformanceObserverCallback`. It can have 0 to 3
  arguments.
  """
  @type callback ::
          (PerformanceObserverEntryList.t(), t(), callback_options() -> any())
          | (PerformanceObserverEntryList.t(), t() -> any())
          | (PerformanceObserverEntryList.t() -> any())
          | (-> any())

  @doc """
  Makes an observer, as the constructor `new PerformanceObserver(callback)`.

  The observer belongs to the global object of the calling process, and
  stops when that global object stops. It observes nothing until a
  process calls `observe/2`.

  Raises `Web.TypeError` when the callback is not a function with 0 to 3
  arguments.

  ## Examples

  The callback sees the entries of the global object of the observer, and
  a mark of the callback is an entry of that global object:

      iex> test = self()
      iex> observer =
      ...>   Web.PerformanceObserver.new(fn _list ->
      ...>     Web.Performance.mark("from the callback")
      ...>     send(test, {:seen, Enum.map(Web.Performance.get_entries(), & &1.name)})
      ...>   end)
      iex> Web.PerformanceObserver.observe(observer, type: "measure")
      :ok
      iex> _measure = Web.Performance.measure("query")
      iex> receive do
      ...>   {:seen, names} -> names
      ...> end
      ["query", "from the callback"]
      iex> Enum.map(Web.Performance.get_entries_by_type("mark"), & &1.name)
      ["from the callback"]
      iex> Web.Performance.clear_marks()
      iex> Web.Performance.clear_measures()
      :ok
  """
  @spec new(callback()) :: t()
  def new(callback)
      when is_function(callback, 0) or is_function(callback, 1) or is_function(callback, 2) or
             is_function(callback, 3) do
    PerformanceTimeline.new_observer(callback)
  end

  def new(callback) do
    raise Web.TypeError,
          "The callback must be a function with 0 to 3 arguments, got: #{inspect(callback)}"
  end

  @doc """
  Observes the entries of the global object of the observer, as
  `observe(options)`. The calling process can be a different process: the
  observer observes its own global object, not the calling process.

  ## Options

  The options are the members of `PerformanceObserverInit`. The function
  ignores each other option.

    * `:entry_types` - a list of entry types. The options of a call take the
      place of the options of the calls before it. No other option can be
      there;
    * `:type` - one entry type. Each call adds its type, and the options
      of a call with the same type take the place of the old options;
    * `:buffered` - with `:type`. When it is `true`, the observer also gets
      the entries of that type that its global object made before the
      call.

  An observer observes with `:entry_types` or with `:type`, not with the
  two. The observer ignores an entry type that is not in
  `supported_entry_types/0`, and writes a warning to the log.

  Raises `Web.TypeError` when the options have no `:entry_types` and no
  `:type`, or `:entry_types` with an other option. Raises
  `Web.DOMException` with the name `InvalidModificationError` when the
  observer observed with the other option before.

  ## Examples

      iex> test = self()
      iex> observer = Web.PerformanceObserver.new(fn list -> send(test, list) end)
      iex> mark = Web.Performance.mark("before", start_time: 1.0)
      iex> Web.PerformanceObserver.observe(observer, type: "mark", buffered: true)
      :ok
      iex> receive do
      ...>   list -> Web.PerformanceObserverEntryList.get_entries(list) == [mark]
      ...> end
      true
      iex> Web.Performance.clear_marks()
      :ok
  """
  @spec observe(t(), keyword()) :: :ok
  def observe(%__MODULE__{} = observer, options \\ []), do: Engine.observe(observer, options)

  @doc """
  Stops the observation, as `disconnect()`. The observer leaves the list
  of the observers of its global object.

  The observer drops the entries that no callback got. A later call to
  `observe/2` starts the observation again.
  """
  @spec disconnect(t()) :: :ok
  def disconnect(%__MODULE__{} = observer), do: Engine.disconnect(observer)

  @doc """
  Returns the entries that no callback got, and removes them from the
  observer, as `takeRecords()`.

  The entries are in the sequence in which the observer got them. A
  callback does not get them.

  ## Examples

      iex> observer = Web.PerformanceObserver.new(fn _list -> :ok end)
      iex> Web.PerformanceObserver.observe(observer, entry_types: ["mark"])
      :ok
      iex> mark = Web.Performance.mark("now")
      iex> Web.PerformanceObserver.take_records(observer) == [mark]
      true
      iex> Web.PerformanceObserver.take_records(observer)
      []
      iex> Web.Performance.clear_marks()
      :ok
  """
  @spec take_records(t()) :: [Web.Performance.entry()]
  def take_records(%__MODULE__{} = observer), do: Engine.take_records(observer)

  @doc """
  Returns the entry types that an observer can observe, in alphabetical
  order, as the static attribute `supportedEntryTypes`.

  ## Examples

      iex> Web.PerformanceObserver.supported_entry_types()
      ["mark", "measure"]
  """
  @spec supported_entry_types() :: [String.t()]
  def supported_entry_types, do: PerformanceTimeline.supported_entry_types()
end
