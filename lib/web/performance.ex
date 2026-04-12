defmodule Web.Performance do
  @moduledoc """
  High-resolution monotonic timing utilities with User Timing entry storage.
  """

  defmodule Mark do
    @moduledoc false

    defstruct name: "", entryType: "mark", startTime: 0.0, duration: 0.0

    @type t :: %__MODULE__{
            name: String.t(),
            entryType: String.t(),
            startTime: float(),
            duration: float()
          }
  end

  defmodule Measure do
    @moduledoc false

    defstruct name: "", entryType: "measure", startTime: 0.0, duration: 0.0

    @type t :: %__MODULE__{
            name: String.t(),
            entryType: String.t(),
            startTime: float(),
            duration: float()
          }
  end

  @time_origin_key {__MODULE__, :time_origin_us}
  @entries_key {__MODULE__, :entries}

  @type entry :: Mark.t() | Measure.t()

  @doc false
  def put_time_origin(origin_us \\ :erlang.monotonic_time(:microsecond)) do
    :persistent_term.put(@time_origin_key, origin_us)
    :ok
  end

  @doc """
  Returns milliseconds elapsed since the VM-local time origin.
  """
  @spec now() :: float()
  def now do
    current_us = :erlang.monotonic_time(:microsecond)
    origin_us = time_origin_us(current_us)
    to_ms(current_us - origin_us)
  end

  @doc """
  Returns the VM-local time origin in milliseconds.
  """
  @spec time_origin() :: float()
  def time_origin do
    time_origin_us()
    |> to_ms()
  end

  @doc """
  Creates and stores a performance mark for the current time.
  """
  @spec mark(String.t() | atom()) :: Mark.t()
  def mark(name) do
    entry = %Mark{name: normalize_name(name), startTime: now()}
    put_entry(entry)
    entry
  end

  @doc """
  Creates and stores a performance measure.
  """
  @spec measure(String.t() | atom()) :: Measure.t()
  def measure(name), do: measure(name, nil, nil)

  @spec measure(String.t() | atom(), String.t() | atom() | nil) :: Measure.t()
  def measure(name, start_mark), do: measure(name, start_mark, nil)

  @spec measure(String.t() | atom(), String.t() | atom() | nil, String.t() | atom() | nil) ::
          Measure.t()
  def measure(name, start_mark, end_mark) do
    start_time = resolve_timestamp(start_mark, :start)
    end_time = resolve_timestamp(end_mark, :end)

    entry = %Measure{
      name: normalize_name(name),
      startTime: start_time,
      duration: end_time - start_time
    }

    put_entry(entry)
    entry
  end

  @doc """
  Returns all locally stored performance entries.
  """
  @spec get_entries() :: [entry()]
  def get_entries do
    Process.get(@entries_key, [])
  end

  def unquote(:getEntries)(), do: get_entries()

  @doc """
  Returns all locally stored entries matching the given type.
  """
  @spec get_entries_by_type(String.t() | atom()) :: [entry()]
  def get_entries_by_type(type) do
    normalized = normalize_name(type)
    Enum.filter(get_entries(), &(&1.entryType == normalized))
  end

  def unquote(:getEntriesByType)(type), do: get_entries_by_type(type)

  @doc """
  Returns all locally stored entries matching the given name.
  """
  @spec get_entries_by_name(String.t() | atom()) :: [entry()]
  def get_entries_by_name(name) do
    normalized = normalize_name(name)
    Enum.filter(get_entries(), &(&1.name == normalized))
  end

  def unquote(:getEntriesByName)(name), do: get_entries_by_name(name)

  @doc """
  Clears stored mark entries, optionally filtering by name.
  """
  @spec clear_marks(String.t() | atom() | nil) :: :ok
  def clear_marks(name \\ nil) do
    clear_entries("mark", name)
  end

  def unquote(:clearMarks)(name \\ nil), do: clear_marks(name)

  @doc """
  Clears stored measure entries, optionally filtering by name.
  """
  @spec clear_measures(String.t() | atom() | nil) :: :ok
  def clear_measures(name \\ nil) do
    clear_entries("measure", name)
  end

  def unquote(:clearMeasures)(name \\ nil), do: clear_measures(name)

  defp resolve_timestamp(nil, :start), do: 0.0
  defp resolve_timestamp(nil, :end), do: now()

  defp resolve_timestamp(mark_name, _position) do
    normalized = normalize_name(mark_name)

    case Enum.reverse(get_entries_by_name(normalized)) do
      [%{entryType: "mark", startTime: start_time} | _] ->
        start_time

      [%{entryType: other_type} | _] ->
        raise ArgumentError,
              "cannot measure from entry #{inspect(normalized)} of type #{inspect(other_type)}"

      [] ->
        raise ArgumentError, "unknown performance mark: #{inspect(normalized)}"
    end
  end

  defp put_entry(entry) do
    Process.put(@entries_key, get_entries() ++ [entry])
    :ok
  end

  defp clear_entries(entry_type, nil) do
    entries = Enum.reject(get_entries(), &(&1.entryType == entry_type))
    Process.put(@entries_key, entries)
    :ok
  end

  defp clear_entries(entry_type, name) do
    normalized = normalize_name(name)

    entries =
      Enum.reject(get_entries(), fn entry ->
        entry.entryType == entry_type and entry.name == normalized
      end)

    Process.put(@entries_key, entries)
    :ok
  end

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name), do: to_string(name)

  defp time_origin_us(default \\ :erlang.monotonic_time(:microsecond)) do
    :persistent_term.get(@time_origin_key, default)
  end

  defp to_ms(value_us), do: value_us / 1000.0
end
