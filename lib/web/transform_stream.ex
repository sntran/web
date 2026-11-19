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

  alias Web.TransformStreamDefaultController, as: Controller

  @enforce_keys [:readable, :writable]
  defstruct [:readable, :writable]

  @type t :: %__MODULE__{readable: %Web.ReadableStream{}, writable: %Web.WritableStream{}}

  use Web.Stream

  # ---------------------------------------------------------------------------
  # Web.Stream behavior callbacks
  # ---------------------------------------------------------------------------

  @impl Web.Stream
  def start(pid, opts) do
    transformer = Keyword.get(opts, :transformer, %{})
    state = %{transformer: transformer, pid: pid}

    # The function `start` runs in the process of the stream. Thus a process
    # that it starts with a link follows the life of the stream. A value that
    # it throws stops the start of the stream, and `new/2` throws that value.
    case Map.get(transformer, :start) do
      start_fn when is_function(start_fn, 1) ->
        case start_fn.(%Controller{pid: pid}) do
          %Web.Promise{} = promise -> Web.Promise.await(promise)
          _ -> :ok
        end

      _ ->
        :ok
    end

    {:producer_consumer, state}
  end

  @impl Web.Stream
  def write(chunk, _ctrl, %{transformer: transformer, pid: pid} = state) do
    ctrl = %Controller{pid: pid}

    result =
      case Map.get(transformer, :transform) do
        transform when is_function(transform, 2) ->
          transform.(chunk, ctrl)

        _ ->
          # The default transform gives the chunk with no change.
          Controller.enqueue(ctrl, chunk)
          :ok
      end

    case result do
      %Web.Promise{} = promise -> Web.Promise.await(promise)
      _ -> :ok
    end

    {:ok, state}
  end

  @impl Web.Stream
  def flush(_ctrl, %{transformer: transformer, pid: pid} = state) do
    ctrl = %Controller{pid: pid}

    result =
      case Map.get(transformer, :flush) do
        flush_fn when is_function(flush_fn, 1) ->
          flush_fn.(ctrl)

        _ ->
          :ok
      end

    case result do
      %Web.Promise{} = promise -> Web.Promise.await(promise)
      _ -> :ok
    end

    {:ok, state}
  end

  @impl Web.Stream
  # A cancel of the readable side, and an abort of the writable side, call
  # the function `cancel` of the transformer with the reason.
  def terminate({type, reason}, %{transformer: transformer}) when type in [:cancel, :abort] do
    do_terminate(reason, transformer)
  end

  def terminate(_event, _state), do: :ok

  defp do_terminate(reason, transformer) do
    case Map.get(transformer, :cancel) do
      cancel when is_function(cancel, 1) -> cancel.(reason)
      _ -> :ok
    end
  end

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

  Raises `Web.TypeError` for a transformer that is not a map, or for a
  callback that is not a function with the correct number of arguments.
  Raises `Web.RangeError` for a transformer with the key `:readable_type` or
  `:writable_type`, as the Streams Standard specifies.
  """
  @spec new(map(), keyword()) :: t()
  def new(transformer \\ %{}, opts \\ []) do
    :ok = validate_transformer!(transformer)

    writable_hwm =
      case Keyword.get(opts, :writable_strategy) do
        %{high_water_mark: hwm} when is_number(hwm) -> hwm
        _ -> Keyword.get(opts, :high_water_mark, 1)
      end

    readable_strategy = Keyword.get(opts, :readable_strategy, Web.CountQueuingStrategy.new(0))

    opts =
      opts
      |> Keyword.drop([:writable_strategy, :readable_strategy])
      |> Keyword.put(:transformer, transformer)
      |> Keyword.put(:high_water_mark, writable_hwm)
      |> Keyword.put(:strategy, readable_strategy)

    case start_link(opts) do
      {:ok, pid} ->
        %__MODULE__{
          readable: %Web.ReadableStream{controller_pid: pid},
          writable: %Web.WritableStream{controller_pid: pid}
        }

      # The function `start` of the transformer threw a value. This process
      # throws the same value.
      {:error, {:shutdown, {:start_failed, {kind, value, stacktrace}}}} ->
        :erlang.raise(kind, value, stacktrace)
    end
  end

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
