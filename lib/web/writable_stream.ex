defmodule Web.WritableStream do
  @moduledoc """
  An Elixir implementation of the WHATWG WritableStream standard.

  This process-backed stream mirrors the ReadableStream architecture in this project:
  a `Web.Stream` engine owns the internal slots, sink callbacks run in supervised tasks,
  and a writer lock grants exclusive write access.
  """

  use Web.Stream

  defstruct [:controller_pid]

  alias Web.TypeError
  alias Web.WritableStreamDefaultController
  alias Web.WritableStreamDefaultWriter

  # ---------------------------------------------------------------------------
  # Web.Stream behavior callbacks
  # ---------------------------------------------------------------------------

  @impl Web.Stream
  def start(pid, opts) do
    sink = Keyword.get(opts, :underlying_sink, %{})
    state = %{sink: sink, pid: pid}

    if is_map(sink) and is_function(sink[:start], 1) do
      ctrl = %WritableStreamDefaultController{pid: pid}
      fun = sink.start
      {:consumer, state, [{:next_event, :internal, {:start_task, fn -> fun.(ctrl) end}}]}
    else
      {:consumer, state}
    end
  end

  @impl Web.Stream
  def write(chunk, _ctrl, %{sink: sink, pid: pid} = state) do
    ctrl = %WritableStreamDefaultController{pid: pid}

    case invoke_sink_callback(sink, :write, [chunk, ctrl]) do
      %Web.Promise{task: task} -> Task.await(task, :infinity)
      _ -> :ok
    end

    {:ok, state}
  end

  def write(pid, owner_pid, chunk) when is_pid(pid) and is_pid(owner_pid) do
    :gen_statem.call(pid, {:write, owner_pid, chunk}, :infinity)
  end

  @impl Web.Stream
  def flush(_ctrl, %{sink: sink, pid: pid} = state) do
    ctrl = %WritableStreamDefaultController{pid: pid}

    case invoke_sink_callback(sink, :close, [ctrl]) do
      %Web.Promise{task: task} -> Task.await(task, :infinity)
      _ -> :ok
    end

    {:ok, state}
  end

  @impl Web.Stream
  def terminate({:close, _reason}, %{sink: sink, pid: pid}) do
    invoke_sink_callback(sink, :close, [%WritableStreamDefaultController{pid: pid}])
  end

  def terminate({type, reason}, %{sink: sink}) when type in [:abort, :error] do
    invoke_abort(sink, reason)
  end

  def terminate(reason, %{sink: sink}) do
    invoke_abort(sink, reason)
  end

  @impl Web.Stream
  def error(_reason, %{sink: _} = state) do
    {:ok, state}
  end

  def error(pid, reason) when is_pid(pid) do
    :gen_statem.cast(pid, {:error, reason})
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new WritableStream with the given underlying sink.
  """
  def new(underlying_sink \\ %{})

  def new(underlying_sink) when is_map(underlying_sink) do
    hwm = Map.get(underlying_sink, :high_water_mark, 1)
    {:ok, pid} =
      start_link(
        underlying_sink: underlying_sink,
        high_water_mark: hwm,
        strategy: Web.CountQueuingStrategy.new(hwm)
      )
    %__MODULE__{controller_pid: pid}
  end

  def new(underlying_sink) do
    raise ArgumentError, "underlying_sink must be a map, got: #{inspect(underlying_sink)}"
  end

  @doc """
  Returns whether the stream has an active writer lock.
  """
  def locked?(%__MODULE__{controller_pid: pid}), do: locked?(pid)
  def locked?(pid) when is_pid(pid), do: :gen_statem.call(pid, :locked?)

  @doc """
  Returns the stream desired size or `nil` once it is closed or errored.
  """
  def desired_size(%__MODULE__{controller_pid: pid}), do: desired_size(pid)
  def desired_size(pid) when is_pid(pid), do: :gen_statem.call(pid, :desired_size)

  @doc """
  Returns whether the stream is currently applying backpressure.
  """
  def backpressure?(%__MODULE__{controller_pid: pid}), do: backpressure?(pid)
  def backpressure?(pid) when is_pid(pid), do: :gen_statem.call(pid, :backpressure?)

  @doc """
  Locks the stream and returns a default writer.
  """
  def get_writer(pid) when is_pid(pid) do
    case :gen_statem.call(pid, {:get_writer, self()}) do
      :ok -> :ok
      {:error, :already_locked} -> {:error, :already_locked}
    end
  end

  def get_writer(%__MODULE__{controller_pid: pid}) do
    case get_writer(pid) do
      :ok ->
        %WritableStreamDefaultWriter{controller_pid: pid, owner_pid: self()}

      {:error, :already_locked} ->
        raise TypeError, "WritableStream is already locked"
    end
  end

  def write(pid, chunk) when is_pid(pid) do
    :gen_statem.call(pid, {:write, self(), chunk}, :infinity)
  end

  def ready(pid) when is_pid(pid) do
    :gen_statem.call(pid, {:ready, self()}, :infinity)
  end

  def ready(pid, owner_pid) when is_pid(pid) and is_pid(owner_pid) do
    :gen_statem.call(pid, {:ready, owner_pid}, :infinity)
  end

  def close(%__MODULE__{controller_pid: pid}) do
    close(pid)
  end

  def close(pid) when is_pid(pid) do
    Web.Promise.new(fn resolve, _reject ->
      Web.Stream.terminate(pid, :close)
      await_settled_state(pid, :closed)
      resolve.(:ok)
    end)
  end

  def close(pid, owner_pid) when is_pid(pid) and is_pid(owner_pid) do
    :gen_statem.call(pid, {:close, owner_pid}, :infinity)
  end

  def abort(%__MODULE__{controller_pid: pid}, reason) do
    abort(pid, reason)
  end

  def abort(pid, reason) when is_pid(pid) do
    Web.Promise.new(fn resolve, _reject ->
      Web.Stream.terminate(pid, :abort, reason)
      await_abort_completion(pid)
      resolve.(:ok)
    end)
  end

  def abort(pid, owner_pid, reason) when is_pid(pid) and is_pid(owner_pid) do
    :gen_statem.call(pid, {:abort, owner_pid, reason}, :infinity)
  end

  def release_lock(pid) when is_pid(pid) do
    :gen_statem.call(pid, {:release_lock, self()})
  end

  def release_lock(pid, owner_pid) when is_pid(pid) and is_pid(owner_pid) do
    :gen_statem.call(pid, {:release_lock, owner_pid})
  end

  @doc false
  def __get_slots__(pid) when is_pid(pid) do
    :gen_statem.call(pid, :get_slots)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp invoke_sink_callback(sink, name, args) do
    case Map.get(sink, name) do
      fun when is_function(fun, length(args)) ->
        apply(fun, args)

      _ ->
        :ok
    end
  end

  defp invoke_abort(%{abort: abort}, reason) when is_function(abort, 1) do
    try do
      abort.(reason)
      :ok
    rescue
      _error -> :ok
    catch
      _kind, _abort_reason -> :ok
    end
  end

  defp invoke_abort(_sink, _reason), do: :ok

  defp await_settled_state(pid, expected_state) do
    case safe_get_slots(pid) do
      %{state: ^expected_state, active_operation: nil} ->
        :ok

      _ ->
        # coveralls-ignore-next-line
        Process.sleep(10)
        # coveralls-ignore-next-line
        await_settled_state(pid, expected_state)
    end
  end

  defp await_abort_completion(pid) do
    case safe_get_slots(pid) do
      %{state: :errored, active_operation: nil} ->
        :ok

      _ ->
        # coveralls-ignore-next-line
        Process.sleep(10)
        # coveralls-ignore-next-line
        await_abort_completion(pid)
    end
  end

  defp safe_get_slots(pid) do
    __get_slots__(pid)
  catch
    :exit, _reason -> %{state: :errored, active_operation: nil}
  end
end
