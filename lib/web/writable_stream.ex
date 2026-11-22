defmodule Web.WritableStream do
  @moduledoc """
  A writable stream, as `WritableStream` of the Streams Standard.

  The stream is a process, as a `Web.ReadableStream` is. The process keeps
  the slots of the stream, and the functions of the underlying sink run in
  the worker of the stream. A writer from `get_writer/1` has the lock: only
  that writer can write to the stream.
  """

  use Web.Stream

  defstruct [:controller_pid]

  @typedoc "A writable stream. The field is private."
  @type t :: %__MODULE__{controller_pid: pid()}

  alias Web.Internal.QueuingStrategy
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

  # An abort, an error, or a cancel: the sink gets the reason.
  def terminate({_type, reason}, %{sink: sink}) do
    invoke_abort(sink, reason)
  end

  @doc false
  # `error` of the controller of the stream.
  def error(pid, reason) when is_pid(pid) do
    Web.Stream.control_cast(pid, {:error, reason})
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new WritableStream with the given underlying sink, as
  `new WritableStream(underlyingSink, strategy)`.

  ## The underlying sink

  A map with the functions of the dictionary `UnderlyingSink` of the
  Streams Standard: `start: fn controller -> ... end`,
  `write: fn chunk, controller -> ... end`, `close: fn controller -> ... end`,
  and `abort: fn reason -> ... end`. Each function returns a value or a
  `Web.Promise`. The controller is a `Web.WritableStreamDefaultController`.

  ## The queuing strategy

  The strategy is the dictionary `QueuingStrategy` of the Streams Standard:
  a keyword list or a map with these keys, or a `Web.CountQueuingStrategy`
  or a `Web.ByteLengthQueuingStrategy`.

    * `:high_water_mark` - the limit of the queue of writes: a number that
      is not below zero, or `:infinity`. The default is 1.
    * `:size` - a function that gives the size of a chunk. The default
      counts each chunk as 1. The function runs in the process that writes
      the chunk. A size that is not valid puts the stream in the errored
      state, and the write rejects.

  Raises `Web.RangeError` for a high water mark that is NaN or below zero,
  and for a sink with the key `:type`. Raises `Web.TypeError` for a size
  that is not a function, and for a sink that is not a map.
  """
  def new(underlying_sink \\ %{}, strategy \\ [])

  def new(underlying_sink, strategy)
      when is_map(underlying_sink) and not is_struct(underlying_sink) do
    :ok = validate_sink!(underlying_sink)
    {hwm, size} = QueuingStrategy.extract!(strategy, 1)
    hwm = QueuingStrategy.high_water_mark!(hwm, 1)
    start_fn = Map.get(underlying_sink, :start)

    {:ok, pid} =
      start_link(
        underlying_sink: underlying_sink,
        high_water_mark: hwm,
        strategy: %Web.CountQueuingStrategy{high_water_mark: hwm},
        size: size,
        has_start: is_function(start_fn)
      )

    if start_fn do
      Web.Stream.run_start(pid, start_fn, %WritableStreamDefaultController{pid: pid})
    end

    %__MODULE__{controller_pid: pid}
  end

  def new(underlying_sink, _strategy) do
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
  Returns `true` when the stream is locked to a writer, as the attribute
  `locked`.
  """
  @spec locked?(t()) :: boolean()
  def locked?(%__MODULE__{controller_pid: pid}),
    do: Web.Stream.call(pid, {:locked?, :writer}, false)

  @doc """
  Locks the stream and returns a `Web.WritableStreamDefaultWriter`, as
  `getWriter()`.

  Raises `Web.TypeError` if the stream is locked.
  """
  @spec get_writer(t()) :: WritableStreamDefaultWriter.t()
  def get_writer(%__MODULE__{} = stream), do: get_writer(stream, :writer)

  @doc false
  # The kind `:pipe` is for the writer lock of a pipe. Such a lock does not
  # keep the stream after its owner stopped. The writer keeps the reference
  # of its lock: see `Web.WritableStreamDefaultWriter`.
  def get_writer(%__MODULE__{controller_pid: pid}, kind) when kind in [:writer, :pipe] do
    case lock_writer(pid, kind) do
      {:ok, lock} ->
        %WritableStreamDefaultWriter{controller_pid: pid, owner_pid: self(), lock: lock}

      {:error, :already_locked} ->
        raise TypeError, "WritableStream is already locked"

      {:error, :released} ->
        raise TypeError, "The stream is not available. It ended, or its owner stopped."
    end
  end

  # Takes the writer lock for this process. Returns `{:ok, lock}` with the
  # reference of the lock, or `{:error, reason}`.
  defp lock_writer(pid, kind) do
    Web.Stream.call(pid, {:get_writer, self(), kind}, {:error, :released})
  end

  @doc """
  Closes the stream, as `close()`. Returns a `Web.Promise` that fulfils
  when the sink closed.

  The promise rejects with `Web.TypeError` when the stream is locked (use
  the close function of the writer), and when the stream is closing,
  closed, or errored.
  """
  @spec close(t()) :: Web.Promise.t()
  def close(%__MODULE__{controller_pid: pid}) do
    terminate_unlocked(pid, :close, nil)
  end

  @doc """
  Aborts the stream, as `abort(reason)`. The function `abort` of the sink
  gets the reason. The default reason is `nil`, as `undefined` in the
  Streams Standard.

  The listeners of the signal of the controller run in the calling process
  before this function returns, as the Streams Standard specifies. The
  promise rejects with `Web.TypeError` when the stream is locked: use the
  abort function of the writer.
  """
  @spec abort(t(), term()) :: Web.Promise.t()
  def abort(%__MODULE__{controller_pid: pid}, reason \\ nil) do
    Web.Stream.__abort__(
      pid,
      {{:abort_first_steps, nil, reason}, {:terminate_unlocked, :abort, reason}},
      reason,
      :ok,
      &unlocked_result(:abort, &1)
    )
  end

  defp terminate_unlocked(pid, type, reason) do
    Web.Stream.promise_call(
      pid,
      {:terminate_unlocked, type, reason},
      :ok,
      &unlocked_result(type, &1)
    )
  end

  defp unlocked_result(_type, :ok), do: {:ok, :ok}

  defp unlocked_result(type, {:error, :locked}),
    do: {:error, TypeError.exception("Cannot #{type} a locked stream.")}

  defp unlocked_result(_type, {:error, :closing}),
    do: {:error, TypeError.exception("The stream is closing.")}

  defp unlocked_result(_type, {:error, :closed}),
    do: {:error, TypeError.exception("The stream is closed.")}

  defp unlocked_result(_type, {:error, :errored}),
    do: {:error, TypeError.exception("The stream is errored.")}

  defp unlocked_result(_type, {:error, {:errored, reason}}), do: {:error, reason}
  defp unlocked_result(_type, {:error, thrown}), do: {:error, thrown}

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
