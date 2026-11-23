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

  ## The observed process

  The entries of `Web.Performance` are the state of the process that makes
  them. `observe/2` observes the process that calls it: a later mark or
  measure of that process goes to the observer. An observer can observe
  more than one process, when each of the processes calls `observe/2`.
  `disconnect/1` stops the observation of each process.

  ## The callback

  The callback runs in a process of the observer, after the call that
  made the entry, not in the call of `Web.Performance.mark/2` or
  `Web.Performance.measure/3`. One callback gets each entry that came
  before it runs, and the callbacks of an observer run one at a time.

  The callback gets three arguments, as the `PerformanceObserverCallback`
  of the Standard. A function with fewer arguments gets the first ones:

    * the entry list, a `Web.PerformanceObserverEntryList`;
    * the observer;
    * the options of the callback: `%{dropped_entries_count: 0}` in the
      first callback after a call to `observe/2`, and `%{}` in the other
      callbacks. The buffers of the marks and the measures have no limit,
      thus the count is 0.

  The callback can call each function of this module. A mark or a measure
  that the callback makes is an entry of the process of the callback. A
  value that the callback throws goes to the log, and the observer
  continues. The callback runs in the empty context of
  `Web.AsyncContext`, as the proposal specifies for the callback of an
  observer.

  ## Lifetime

  The process that calls `new/1` is the owner of the observer. The
  observer stops when its owner stops: a callback that did not start does
  not run. After that, `observe/2` and `disconnect/1` have no effect, and
  `take_records/1` returns `[]`. The entries that an observed process made
  before it stopped stay in the observer.
  """

  alias Web.Internal.PerformanceObserver, as: Engine
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

  The calling process is the owner of the observer: the observer stops
  when the process stops. The observer observes nothing until a process
  calls `observe/2`.

  Raises `Web.TypeError` when the callback is not a function with 0 to 3
  arguments.
  """
  @spec new(callback()) :: t()
  def new(callback)
      when is_function(callback, 0) or is_function(callback, 1) or is_function(callback, 2) or
             is_function(callback, 3) do
    Engine.start(callback, self())
  end

  def new(callback) do
    raise Web.TypeError,
          "The callback must be a function with 0 to 3 arguments, got: #{inspect(callback)}"
  end

  @doc """
  Observes the entries of the calling process, as `observe(options)`.

  ## Options

  The options are the members of `PerformanceObserverInit`. The function
  ignores each other option.

    * `:entry_types` - a list of entry types. The options of a call take the
      place of the options of the calls before it. No other option can be
      there;
    * `:type` - one entry type. Each call adds its type, and the options
      of a call with the same type take the place of the old options;
    * `:buffered` - with `:type`. When it is `true`, the observer also gets
      the entries of that type that the process made before the call.

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
  Stops the observation of each process, as `disconnect()`.

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
  def supported_entry_types, do: Engine.supported_entry_types()
end
