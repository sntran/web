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

    # The function `start` of the sink runs in the process that makes the
    # stream: see `Web.Stream.run_start/3`. This process waits for it.
    {:consumer, state, Web.Stream.start_actions(opts)}
  end

  @impl Web.Stream
  def write(chunk, _ctrl, %{sink: sink, pid: pid} = state) do
    ctrl = %WritableStreamDefaultController{pid: pid}

    case invoke_sink_callback(sink, :write, [chunk, ctrl]) do
      %Web.Promise{} = promise -> Web.Promise.await(promise)
      _ -> :ok
    end

    {:ok, state}
  end

  def write(pid, owner_pid, chunk) when is_pid(pid) and is_pid(owner_pid) do
    Web.Stream.call(pid, {:write, owner_pid, chunk}, {:error, :released})
  end

  @impl Web.Stream
  def flush(_ctrl, %{sink: sink, pid: pid} = state) do
    ctrl = %WritableStreamDefaultController{pid: pid}

    case invoke_sink_callback(sink, :close, [ctrl]) do
      %Web.Promise{} = promise -> Web.Promise.await(promise)
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
    Web.Stream.control_cast(pid, {:error, reason})
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new WritableStream with the given underlying sink.
  """
  def new(underlying_sink \\ %{})

  def new(underlying_sink) when is_map(underlying_sink) and not is_struct(underlying_sink) do
    :ok = validate_sink!(underlying_sink)
    hwm = Map.get(underlying_sink, :high_water_mark, 1)

    if not is_number(hwm) or hwm < 0 do
      raise Web.RangeError, "Invalid high water mark: #{inspect(hwm)}"
    end

    start_fn = Map.get(underlying_sink, :start)

    {:ok, pid} =
      start_link(
        underlying_sink: underlying_sink,
        high_water_mark: hwm,
        strategy: Web.CountQueuingStrategy.new(hwm),
        has_start: is_function(start_fn)
      )

    if start_fn do
      Web.Stream.run_start(pid, start_fn, %WritableStreamDefaultController{pid: pid})
    end

    %__MODULE__{controller_pid: pid}
  end

  def new(underlying_sink) do
    raise Web.TypeError, "The underlying sink must be a map, got: #{inspect(underlying_sink)}"
  end

  @sink_callbacks [start: 1, write: 2, close: 1, abort: 1]

  # The checks of the Streams Standard for an underlying sink.
  defp validate_sink!(sink) do
    if is_map_key(sink, :type) do
      raise Web.RangeError, "The underlying sink key :type is not permitted"
    end

    for {name, arity} <- @sink_callbacks, callback = Map.get(sink, name), not is_nil(callback) do
      if not is_function(callback, arity) do
        raise Web.TypeError,
              "The underlying sink function #{inspect(name)} must be a function with " <>
                "#{arity} argument(s), got: #{inspect(callback)}"
      end
    end

    :ok
  end

  @doc """
  Returns whether the stream has an active writer lock.
  """
  def locked?(%__MODULE__{controller_pid: pid}), do: locked?(pid)
  def locked?(pid) when is_pid(pid), do: Web.Stream.call(pid, {:locked?, :writer}, false)

  @doc """
  Returns the stream desired size or `nil` once it is closed or errored.
  """
  def desired_size(%__MODULE__{controller_pid: pid}), do: desired_size(pid)
  def desired_size(pid) when is_pid(pid), do: Web.Stream.call(pid, :desired_size, nil)

  @doc """
  Returns whether the stream is currently applying backpressure.
  """
  def backpressure?(%__MODULE__{controller_pid: pid}), do: backpressure?(pid)
  def backpressure?(pid) when is_pid(pid), do: Web.Stream.call(pid, :backpressure?, false)

  @doc """
  Locks the stream and returns a default writer.
  """
  def get_writer(target), do: get_writer(target, :writer)

  @doc false
  # The kind `:pipe` is for the writer lock of a pipe. Such a lock does not
  # keep the stream after its owner stopped.
  def get_writer(pid, kind) when is_pid(pid) and kind in [:writer, :pipe] do
    case Web.Stream.call(pid, {:get_writer, self(), kind}, {:error, :released}) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def get_writer(%__MODULE__{controller_pid: pid}, kind) do
    case get_writer(pid, kind) do
      :ok ->
        %WritableStreamDefaultWriter{controller_pid: pid, owner_pid: self()}

      {:error, :already_locked} ->
        raise TypeError, "WritableStream is already locked"

      {:error, :released} ->
        raise TypeError, "The stream is not available. It ended, or its owner stopped."
    end
  end

  def write(pid, chunk) when is_pid(pid) do
    Web.Stream.call(pid, {:write, self(), chunk}, {:error, :released})
  end

  def ready(pid) when is_pid(pid) do
    ready(pid, self())
  end

  def ready(pid, owner_pid) when is_pid(pid) and is_pid(owner_pid) do
    ref = make_ref()
    monitor = Process.monitor(pid)
    Web.Stream.control_cast(pid, {:register_ready_waiter, self(), owner_pid, ref})

    receive do
      {:ready, ^ref} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:stream_error, ^ref, reason} ->
        Process.demonitor(monitor, [:flush])
        {:error, reason}

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :released}
    end
  end

  # A close of the stream object. The Streams Standard refuses it when the
  # stream has a writer: use the close function of the writer.
  def close(%__MODULE__{controller_pid: pid}) do
    terminate_unlocked(pid, :close, nil)
  end

  def close(pid) when is_pid(pid) do
    Web.Stream.promise_call(pid, {:terminate, :close, nil}, :ok, fn
      :ok -> {:ok, :ok}
      {:error, thrown} -> {:error, thrown}
    end)
  end

  def close(pid, owner_pid) when is_pid(pid) and is_pid(owner_pid) do
    Web.Stream.control_call(pid, {:close, owner_pid})
  end

  def abort(%__MODULE__{controller_pid: pid}, reason) do
    terminate_unlocked(pid, :abort, reason)
  end

  def abort(pid, reason) when is_pid(pid) do
    Web.Stream.promise_call(pid, {:terminate, :abort, reason}, :ok, fn
      :ok -> {:ok, :ok}
      {:error, thrown} -> {:error, thrown}
    end)
  end

  def abort(pid, owner_pid, reason) when is_pid(pid) and is_pid(owner_pid) do
    Web.Stream.control_call(pid, {:abort, owner_pid, reason})
  end

  def release_lock(pid) when is_pid(pid) do
    Web.Stream.call(pid, {:release_lock, :writer, self()}, :ok)
  end

  def release_lock(pid, owner_pid) when is_pid(pid) and is_pid(owner_pid) do
    Web.Stream.call(pid, {:release_lock, :writer, owner_pid}, :ok)
  end

  defp terminate_unlocked(pid, type, reason) do
    Web.Stream.promise_call(pid, {:terminate_unlocked, type, reason}, :ok, fn
      :ok -> {:ok, :ok}
      {:error, :locked} -> {:error, TypeError.exception("Cannot #{type} a locked stream.")}
      {:error, :closing} -> {:error, TypeError.exception("The stream is closing.")}
      {:error, :closed} -> {:error, TypeError.exception("The stream is closed.")}
      {:error, :errored} -> {:error, TypeError.exception("The stream is errored.")}
      {:error, {:errored, reason}} -> {:error, reason}
      {:error, thrown} -> {:error, thrown}
    end)
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

  # A value that the callback throws is the rejection reason of the abort.
  defp invoke_abort(%{abort: abort}, reason) when is_function(abort, 1), do: abort.(reason)

  defp invoke_abort(_sink, _reason), do: :ok
end
