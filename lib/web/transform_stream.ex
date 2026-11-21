defmodule Web.TransformStream do
  @moduledoc """
  A transform stream, as `TransformStream` of the Streams Standard.

  A transform stream has a writable side and a readable side. A chunk that
  is written to the writable side goes through the function `transform`, and
  the results are read from the readable side.

  ## Backpressure

  The transform of a chunk starts only when the readable side wants a chunk:
  a read waits, or the queue of the readable side is below its limit. The
  default limit of the readable side is 0, as in the Streams Standard. Thus
  a write to a transform stream that no process reads stays pending:

      transform = Web.TransformStream.new()
      writer = Web.WritableStream.get_writer(transform.writable)

      # This promise fulfils when a process reads from `transform.readable`.
      Web.WritableStreamDefaultWriter.write(writer, "chunk")

  Do not await a write before a process reads the readable side. Write and
  close with no await, or read in a different process, or use
  `Web.ReadableStream.pipe_through/2`.

  ## The two sides

  The two sides have their own states, as in the Streams Standard. For
  example, an abort during a transform puts the writable side in the state
  "erroring": the readable side stays readable, the write completes, and
  then the function `cancel` runs. Only one of `flush` and `cancel` runs,
  also when a close, an abort, and a cancel come at the same time.

  ## Usage

      iex> ts = Web.TransformStream.new(%{
      ...>   transform: fn chunk, controller ->
      ...>     Web.TransformStreamDefaultController.enqueue(controller, String.upcase(chunk))
      ...>   end
      ...> })
      iex> writer = Web.WritableStream.get_writer(ts.writable)
      iex> Web.WritableStreamDefaultWriter.write(writer, "hello")
      iex> Web.WritableStreamDefaultWriter.close(writer)
      iex> Enum.join(ts.readable, "")
      "HELLO"
  """

  alias Web.Internal.QueuingStrategy
  alias Web.TransformStreamDefaultController, as: Controller

  @enforce_keys [:readable, :writable]
  defstruct [:readable, :writable]

  @type t :: %__MODULE__{readable: %Web.ReadableStream{}, writable: %Web.WritableStream{}}

  use Web.Stream

  # ---------------------------------------------------------------------------
  # Web.Stream behavior callbacks
  #
  # A transform stream has two stream processes, as in the Streams Standard:
  # the readable side is a `:producer`, and the writable side is a
  # `:consumer`. Each one has its own state. The engine keeps the slots that
  # the two sides share: see "The two sides of a transform stream" in
  # `Web.Stream`. The callbacks below are the algorithms of the Standard for
  # the underlying sink and the underlying source of the two sides. They run
  # in the worker of their side.
  # ---------------------------------------------------------------------------

  @impl Web.Stream
  def start(pid, opts) do
    {side, peer} =
      case Keyword.get(opts, :transform) do
        {:readable, writable, _cell} -> {:readable, writable}
        _writable -> {:writable, nil}
      end

    state = %{
      side: side,
      pid: pid,
      peer: peer,
      transformer: Keyword.get(opts, :transformer, %{})
    }

    # The function `start` of the transformer runs in the process that makes
    # the stream: see `Web.Stream.run_start/3`. The two sides wait for it.
    type = if side == :readable, do: :producer, else: :consumer
    {type, state, Web.Stream.start_actions(opts)}
  end

  # TransformStreamDefaultControllerPerformTransform. A transform that fails
  # puts the two sides in the errored state (TransformStreamError): the
  # write rejects, and the writable side gets the error from the rejection.
  @impl Web.Stream
  def write(chunk, _ctrl, state) do
    controller = controller(state)

    result =
      case Map.get(state.transformer, :transform) do
        nil -> outcome(fn -> Controller.enqueue(controller, chunk) end)
        transform -> outcome(fn -> transform.(chunk, controller) end)
      end

    case result do
      :ok ->
        {:ok, state}

      {:error, reason} ->
        Web.Stream.control_cast(controller.pid, {:transform_error, reason})
        {:error, reason}
    end
  end

  # TransformStreamDefaultSinkCloseAlgorithm.
  @impl Web.Stream
  def flush(_ctrl, state) do
    case finish(state, :flush, &callback(&1, state, :flush, [controller(state)])) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  # TransformStreamDefaultSinkAbortAlgorithm, for an abort of the writable
  # side.
  @impl Web.Stream
  def terminate({:abort, reason}, %{side: :writable} = state) do
    state
    |> finish({:abort, reason}, &callback(&1, state, :cancel, [reason]))
    |> terminal_result()
  end

  # TransformStreamDefaultSourceCancelAlgorithm, for a cancel of the
  # readable side. An abort of the readable side, for example by an ambient
  # `Web.AbortSignal`, does the same steps.
  def terminate({type, reason}, %{side: :readable} = state) when type in [:cancel, :abort] do
    state
    |> finish(:cancel, &source_cancel(&1, state, reason))
    |> terminal_result()
  end

  def terminate(_event, _state), do: :ok

  # The steps of TransformStreamDefaultSourceCancelAlgorithm after the
  # callback: the writable side gets the reason, or the error of the
  # callback, if it is not errored. The worker calls the writable side.
  defp source_cancel(run?, state, reason) do
    case callback(run?, state, :cancel, [reason]) do
      :ok ->
        case Web.Stream.call(state.peer, {:transform_error_if_needed, reason}, :ok) do
          :ok -> :ok
          {:errored, error} -> {:error, error}
        end

      {:error, error} ->
        _ = Web.Stream.call(state.peer, {:transform_error_if_needed, error}, :ok)
        {:error, error}
    end
  end

  # [[finishPromise]] of the controller: the readable side runs only the
  # first request. `fun` gets `true` when the transformer still has its
  # algorithms (TransformStreamDefaultControllerClearAlgorithms), and gives
  # `:ok` or `{:error, reason}`.
  defp finish(state, kind, fun) do
    readable = if state.side == :readable, do: state.pid, else: state.peer

    # A readable side that stopped is closed or errored: the two sides have
    # their end, and the request has no effect.
    case Web.Stream.call(readable, {:transform_finish, kind}, {:done, :ok}) do
      {:run, run?} ->
        outcome = fun.(run?)

        {:done, result} =
          Web.Stream.call(readable, {:transform_finished, kind, outcome}, {:done, outcome})

        result

      {:done, result} ->
        result
    end
  end

  defp callback(false, _state, _name, _args), do: :ok

  defp callback(true, state, name, args) do
    case Map.get(state.transformer, name) do
      nil -> :ok
      fun -> outcome(fn -> apply(fun, args) end)
    end
  end

  # The result of a callback, as the reaction to its promise: `:ok`, or
  # `{:error, reason}` with the reason of a rejection or the thrown value.
  defp outcome(fun) do
    case fun.() do
      %Web.Promise{} = promise ->
        case Web.Promise.wait(promise) do
          {:fulfilled, _value} -> :ok
          {:rejected, reason} -> {:error, reason}
        end

      _value ->
        :ok
    end
  rescue
    error -> {:error, error}
  catch
    _kind, reason -> {:error, reason}
  end

  # The engine takes a rejected promise as the failure of a cancel or an
  # abort.
  defp terminal_result(:ok), do: :ok
  defp terminal_result({:error, reason}), do: Web.Promise.reject(reason)

  # The callbacks of the writable side get the controller.
  defp controller(%{pid: writable, peer: readable}),
    do: %Controller{pid: readable, writable_pid: writable}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Makes a transform stream.

  ## The transformer

  A map with these optional functions. Each one returns `:ok` or a
  `Web.Promise`. The controller is a `Web.TransformStreamDefaultController`.

    * `start: fn controller -> ... end` - called when the stream is made;
    * `transform: fn chunk, controller -> ... end` - called for each chunk
      that is written. The default gives the chunk with no change;
    * `flush: fn controller -> ... end` - called when the writable side
      closes, before the readable side closes;
    * `cancel: fn reason -> ... end` - called when the readable side is
      cancelled, or the writable side is aborted.

  A value that `transform` or `flush` throws puts the two sides in the
  errored state. A value that `start` throws is thrown by this function.

  ## Options

    * `:writable_strategy` - the queuing strategy of the writable side. The
      default is `Web.CountQueuingStrategy.new(1)`.
    * `:readable_strategy` - the queuing strategy of the readable side. The
      default is `Web.CountQueuingStrategy.new(0)`.
    * `:high_water_mark` - the limit of the writable side, when
      `:writable_strategy` is not given.

  A strategy is a `Web.CountQueuingStrategy`, a
  `Web.ByteLengthQueuingStrategy`, or the dictionary `QueuingStrategy` of
  the Streams Standard: a keyword list or a map with the keys
  `:high_water_mark` and `:size`. See `Web.ReadableStream.new/2` and
  `Web.WritableStream.new/2`.

  Raises `Web.TypeError` for a transformer that is not a map, or for a
  callback that is not a function with the correct number of arguments.
  Raises `Web.RangeError` for a transformer with the key `:readable_type` or
  `:writable_type`, and for a high water mark that is NaN or below zero, as
  the Streams Standard specifies.
  """
  @spec new(map(), keyword()) :: t()
  def new(transformer \\ %{}, opts \\ []) do
    :ok = validate_transformer!(transformer)

    {readable_hwm, readable_size} =
      QueuingStrategy.extract!(Keyword.get(opts, :readable_strategy), 0)

    {writable_hwm, writable_size} =
      QueuingStrategy.extract!(
        Keyword.get(opts, :writable_strategy),
        Keyword.get(opts, :high_water_mark, 1)
      )

    writable_hwm = QueuingStrategy.high_water_mark!(writable_hwm, 1)
    start_fn = Map.get(transformer, :start)

    # The options of the engine for each side. Each other option, such as
    # `:timeout_ms`, goes to the two sides.
    opts =
      opts
      |> Keyword.drop([:writable_strategy, :readable_strategy, :high_water_mark])
      |> Keyword.merge(transformer: transformer, has_start: is_function(start_fn))

    # InitializeTransformStream. The two sides share [[backpressure]]: see
    # "The two sides of a transform stream" in `Web.Stream`. The readable
    # side sends messages to the writable side, thus the writable side
    # starts first.
    backpressure = Web.Stream.__transform_cell__()

    {:ok, writable} =
      start_link(
        opts ++
          [
            transform: {:writable, backpressure, default_transform?(transformer, readable_size)},
            high_water_mark: writable_hwm,
            strategy: Web.CountQueuingStrategy.new(writable_hwm),
            size: writable_size
          ]
      )

    {:ok, readable} =
      start_link(
        opts ++
          [
            transform: {:readable, writable, backpressure},
            high_water_mark: readable_hwm,
            strategy: Web.CountQueuingStrategy.new(readable_hwm),
            size: readable_size
          ]
      )

    :ok = Web.Stream.call(writable, {:transform_peer, readable}, :ok)
    controller = %Controller{pid: readable, writable_pid: writable}

    if start_fn do
      Web.Stream.run_start([readable, writable], start_fn, controller, await: true)
    end

    %__MODULE__{
      readable: %Web.ReadableStream{controller_pid: readable},
      writable: %Web.WritableStream{controller_pid: writable}
    }
  end

  # SetUpTransformStreamDefaultControllerFromTransformer: with no function
  # `transform`, the transform is an enqueue. The engine does it with no
  # worker, unless the readable side has the size function of the user:
  # that function must run in a worker.
  defp default_transform?(transformer, readable_size),
    do: is_nil(Map.get(transformer, :transform)) and not is_function(readable_size)

  @callbacks [start: 1, transform: 2, flush: 1, cancel: 1]

  defp validate_transformer!(transformer) when is_map(transformer) do
    for key <- [:readable_type, :writable_type], is_map_key(transformer, key) do
      raise Web.RangeError, "The transformer key #{inspect(key)} is not permitted"
    end

    for {name, arity} <- @callbacks,
        callback = Map.get(transformer, name),
        not is_nil(callback) do
      if not is_function(callback, arity) do
        raise Web.TypeError,
              "The transformer function #{inspect(name)} must be a function with " <>
                "#{arity} argument(s), got: #{inspect(callback)}"
      end
    end

    :ok
  end

  defp validate_transformer!(transformer) do
    raise Web.TypeError, "The transformer must be a map, got: #{inspect(transformer)}"
  end
end
