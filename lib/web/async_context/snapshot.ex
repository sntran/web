defmodule Web.AsyncContext.Snapshot do
  @moduledoc """
  Captures and re-enters asynchronous execution context.

  A snapshot is a lightweight, immutable record of:

    * All registered `Web.AsyncContext.Variable` values
    * Erlang `:logger` metadata (OpenTelemetry trace IDs, custom fields, etc.)
    * Elixir `$callers` — the supervision ancestry chain

  Snapshots are the mechanism by which `Web.Promise` and `Web.Stream` propagate
  context invisibly across BEAM process boundaries.

  ## Taking a Snapshot

      iex> :logger.update_process_metadata(%{request_id: "abc"})
      :ok
      iex> snap = Web.AsyncContext.Snapshot.take()
      iex> is_map(snap.logger_metadata)
      true
      iex> snap.logger_metadata[:request_id]
      "abc"

  ## Running Inside a Snapshot

  `run/2` temporarily installs the snapshot's captured context for the duration
  of a callback, then restores the previous process context afterward:

      snapshot = Web.AsyncContext.Snapshot.take()

      Task.Supervisor.async_nolink(Web.TaskSupervisor, fn ->
        Web.AsyncContext.Snapshot.run(snapshot, fn ->
          # Logger metadata, $callers, and all Variables are now available.
        end)
      end)

  ## Performance

  Snapshots capture only explicitly-registered variable keys — not the entire
  process dictionary. This keeps overhead at $O(k)$ where $k$ is the number of
  registered variables (typically < 10), preserving $O(1)$ per-chunk stream
  performance.
  """

  alias Web.AsyncContext
  alias Web.AsyncContext.Variable

  defstruct variables: %{},
            variable_registry: MapSet.new(),
            logger_metadata: %{},
            callers: [],
            ambient_signal: nil

  @type t :: %__MODULE__{
          variables: %{optional(term()) => term()},
          variable_registry: MapSet.t(),
          logger_metadata: map(),
          callers: [pid()],
          ambient_signal: Web.AbortSignal.t() | nil
        }

  @doc """
  Captures the current async context as an immutable snapshot.

  Collects:

    1. All `Web.AsyncContext.Variable` values currently in scope
    2. Erlang `:logger` process metadata
    3. The Elixir `$callers` list

  This is an $O(k)$ operation where $k$ is the number of registered context
  variables.

  ## Examples

      iex> snap = Web.AsyncContext.Snapshot.take()
      iex> is_struct(snap, Web.AsyncContext.Snapshot)
      true
  """
  @spec take() :: t()
  def take do
    registry_key = Variable.registry_key()
    registry = Process.get(registry_key, MapSet.new())

    %__MODULE__{
      variables: capture_variables(registry),
      variable_registry: registry,
      logger_metadata: capture_logger_metadata(),
      callers: capture_callers(),
      ambient_signal: Process.get(AsyncContext.ambient_signal_key())
    }
  end

  @doc """
  Runs `fun` with this snapshot installed as the current async context.

  This mirrors the TC39 `snapshot.run(callback)` shape: variable bindings,
  logger metadata, `$callers`, and the ambient abort signal are made current for
  `fun`, and the previous process context is restored afterward.

  The installed context is exact for the duration of the callback: values not
  present in the snapshot are treated as unset while `fun` runs.

  ## Examples

      iex> var = Web.AsyncContext.Variable.new("color")
      iex> snap = Web.AsyncContext.Variable.run(var, :blue, fn ->
      ...>   Web.AsyncContext.Snapshot.take()
      ...> end)
      iex> Web.AsyncContext.Snapshot.run(snap, fn ->
      ...>   Web.AsyncContext.Variable.get(var)
      ...> end)
      :blue
  """
  @spec run(t(), (-> result)) :: result when result: var
  def run(%__MODULE__{} = snapshot, fun) when is_function(fun, 0) do
    state = capture_run_state(snapshot)

    install_snapshot_for_run(snapshot, state.managed_registry)

    try do
      fun.()
    after
      restore_run_state(state)
    end
  end

  @doc false
  @spec restore(t()) :: :ok
  def restore(%__MODULE__{} = snapshot) do
    restore_variables(snapshot.variables)
    restore_variable_registry(snapshot.variable_registry)
    restore_logger_metadata(snapshot.logger_metadata)
    restore_callers(snapshot.callers)
    restore_ambient_signal(snapshot.ambient_signal)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Variable capture/restore — O(k) where k = registered variable count
  # ---------------------------------------------------------------------------

  defp capture_variables(registry) do
    Enum.reduce(registry, %{}, fn key, acc ->
      case Process.get(key, :__async_context_unset__) do
        :__async_context_unset__ -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp restore_variables(variables) do
    Enum.each(variables, fn {key, value} ->
      Process.put(key, value)
    end)
  end

  defp restore_variable_registry(registry) do
    registry_key = Variable.registry_key()
    existing = Process.get(registry_key, MapSet.new())
    Process.put(registry_key, MapSet.union(existing, registry))
  end

  # ---------------------------------------------------------------------------
  # Logger metadata
  # ---------------------------------------------------------------------------

  defp capture_logger_metadata do
    case :logger.get_process_metadata() do
      :undefined -> %{}
      metadata -> metadata
    end
  end

  defp restore_logger_metadata(metadata) when map_size(metadata) == 0, do: :ok

  defp restore_logger_metadata(metadata) do
    :logger.update_process_metadata(metadata)
  end

  # ---------------------------------------------------------------------------
  # $callers (Elixir supervision ancestry)
  # ---------------------------------------------------------------------------

  defp capture_callers do
    Process.get(:"$callers", [])
  end

  defp restore_callers([]), do: :ok

  defp restore_callers(callers) do
    Process.put(:"$callers", callers)
  end

  # ---------------------------------------------------------------------------
  # Ambient signal
  # ---------------------------------------------------------------------------

  defp restore_ambient_signal(nil), do: :ok

  defp restore_ambient_signal(signal) do
    Process.put(AsyncContext.ambient_signal_key(), signal)
  end

  # ---------------------------------------------------------------------------
  # Scoped run/2 helpers
  # ---------------------------------------------------------------------------

  defp capture_run_state(%__MODULE__{} = snapshot) do
    registry_key = Variable.registry_key()
    previous_registry = Process.get(registry_key, MapSet.new())
    managed_registry = MapSet.union(previous_registry, snapshot.variable_registry)

    %{
      registry_key: registry_key,
      previous_registry: previous_registry,
      managed_registry: managed_registry,
      previous_values: capture_variable_states(managed_registry),
      previous_logger_metadata: capture_raw_logger_metadata(),
      previous_callers: capture_process_value(:"$callers"),
      previous_ambient_signal: capture_process_value(AsyncContext.ambient_signal_key())
    }
  end

  defp install_snapshot_for_run(%__MODULE__{} = snapshot, managed_registry) do
    Process.put(Variable.registry_key(), managed_registry)
    apply_variable_states(managed_registry, snapshot.variables)
    apply_logger_metadata(snapshot.logger_metadata)
    apply_process_value(:"$callers", snapshot.callers)
    apply_process_value(AsyncContext.ambient_signal_key(), snapshot.ambient_signal)
  end

  defp restore_run_state(state) do
    restore_variable_states(state.previous_values)

    restore_registry_after_run(
      state.registry_key,
      state.previous_registry,
      state.managed_registry
    )

    restore_raw_logger_metadata(state.previous_logger_metadata)
    restore_process_value(:"$callers", state.previous_callers)
    restore_process_value(AsyncContext.ambient_signal_key(), state.previous_ambient_signal)
  end

  defp capture_variable_states(registry) do
    Enum.into(registry, %{}, fn key ->
      {key, Process.get(key, :__async_context_unset__)}
    end)
  end

  defp apply_variable_states(registry, variables) do
    Enum.each(registry, fn key ->
      case Map.fetch(variables, key) do
        {:ok, value} -> Process.put(key, value)
        :error -> Process.delete(key)
      end
    end)
  end

  defp restore_variable_states(previous_values) do
    Enum.each(previous_values, fn
      {key, :__async_context_unset__} -> Process.delete(key)
      {key, value} -> Process.put(key, value)
    end)
  end

  defp restore_registry_after_run(registry_key, previous_registry, managed_registry) do
    current_registry = Process.get(registry_key, MapSet.new())
    new_keys = MapSet.difference(current_registry, managed_registry)
    Process.put(registry_key, MapSet.union(previous_registry, new_keys))
  end

  defp capture_raw_logger_metadata do
    case :logger.get_process_metadata() do
      :undefined -> :undefined
      metadata -> metadata
    end
  end

  defp apply_logger_metadata(metadata) when map_size(metadata) == 0 do
    :logger.unset_process_metadata()
  end

  defp apply_logger_metadata(metadata) do
    :logger.set_process_metadata(metadata)
  end

  defp restore_raw_logger_metadata(:undefined), do: :logger.unset_process_metadata()
  defp restore_raw_logger_metadata(metadata), do: :logger.set_process_metadata(metadata)

  defp capture_process_value(key) do
    Process.get(key, :__async_context_unset__)
  end

  defp apply_process_value(key, nil), do: Process.delete(key)
  defp apply_process_value(:"$callers", []), do: Process.delete(:"$callers")
  defp apply_process_value(key, value), do: Process.put(key, value)

  defp restore_process_value(key, :__async_context_unset__), do: Process.delete(key)
  defp restore_process_value(key, value), do: Process.put(key, value)
end
