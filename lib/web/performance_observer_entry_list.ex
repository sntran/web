defmodule Web.PerformanceObserverEntryList do
  @moduledoc """
  The entries that one callback of a `Web.PerformanceObserver` gets, as
  `PerformanceObserverEntryList` of the Performance Timeline Standard.

  Each function returns the entries in the sequence of their start times,
  as the steps "filter buffer by name and type" specify. Two entries with
  the same start time stay in the sequence in which the observer got them.
  """

  @enforce_keys [:entries]
  defstruct [:entries]

  @typedoc "An entry list. The field is private: use the functions."
  @type t :: %__MODULE__{entries: [Web.Performance.entry()]}

  @doc """
  Returns the entries of the list, as `getEntries()`.

  ## Examples

      iex> Web.Performance.mark("late", start_time: 9.0)
      iex> Web.Performance.mark("early", start_time: 1.0)
      iex> test = self()
      iex> observer = Web.PerformanceObserver.new(fn list -> send(test, list) end)
      iex> Web.PerformanceObserver.observe(observer, type: "mark", buffered: true)
      :ok
      iex> receive do
      ...>   list -> list |> Web.PerformanceObserverEntryList.get_entries() |> Enum.map(& &1.name)
      ...> end
      ["early", "late"]
      iex> Web.Performance.clear_marks()
      :ok
  """
  @spec get_entries(t()) :: [Web.Performance.entry()]
  def get_entries(%__MODULE__{entries: entries}),
    do: Web.Performance.__filter__(entries, nil, nil)

  @doc """
  Returns the entries of the list with the given type, as
  `getEntriesByType(type)`.
  """
  @spec get_entries_by_type(t(), Web.Performance.name()) :: [Web.Performance.entry()]
  def get_entries_by_type(%__MODULE__{entries: entries}, type) do
    Web.Performance.__filter__(entries, nil, Web.Performance.__text__(type))
  end

  @doc """
  Returns the entries of the list with the given name, and with the given
  type when there is one, as `getEntriesByName(name, type)`.
  """
  @spec get_entries_by_name(t(), Web.Performance.name(), Web.Performance.name() | nil) ::
          [Web.Performance.entry()]
  def get_entries_by_name(%__MODULE__{entries: entries}, name, type \\ nil) do
    type = type && Web.Performance.__text__(type)
    Web.Performance.__filter__(entries, Web.Performance.__text__(name), type)
  end
end
