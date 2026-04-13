defmodule Web.TransformStream do
  @moduledoc """
  An Elixir implementation of the WHATWG TransformStream standard.

  A TransformStream is a combined readable/writable stream where data written to
  the writable side is transformed and made available on the readable side.

  Internally it runs a single `Web.Stream` engine in `:producer_consumer` mode:
  the same process PID serves both the writable and the readable faces.

  ## Usage

  Pass a transformer map with an optional `transform` key:

      iex> ts = Web.TransformStream.new(%{
      ...>   transform: fn chunk, controller ->
      ...>     Web.ReadableStreamDefaultController.enqueue(controller, String.upcase(chunk))
      ...>   end
      ...> })
      iex> writer = Web.WritableStream.get_writer(ts.writable)
      iex> Web.await(Web.WritableStreamDefaultWriter.write(writer, "hello"))
      :ok
      iex> Web.await(Web.WritableStreamDefaultWriter.close(writer))
      :ok
      iex> Enum.join(ts.readable, "")
      "HELLO"
  """

  use Web.Stream

  # ---------------------------------------------------------------------------
  # Web.Stream behavior callbacks
  # ---------------------------------------------------------------------------

  @impl Web.Stream
  def start(pid, opts) do
    transformer = Keyword.get(opts, :transformer, %{})
    state = %{transformer: transformer, pid: pid}

    # If the transformer provides a `start` callback, invoke it now (in the
    # gen_statem's init process) so any resources it opens — e.g. Agent or
    # GenServer — are linked to the stream process and follow its lifecycle.
    # Per the WHATWG spec, start(controller) returns :ok or a Promise; no state.
    case Map.get(transformer, :start) do
      start_fn when is_function(start_fn, 1) ->
        ctrl = %Web.ReadableStreamDefaultController{pid: pid}

        case start_fn.(ctrl) do
          %Web.Promise{task: task} -> Task.await(task, :infinity)
          _ -> :ok
        end

      _ ->
        :ok
    end

    {:producer_consumer, state}
  end

  @impl Web.Stream
  def write(chunk, _ctrl, %{transformer: transformer, pid: pid} = state) do
    ctrl = %Web.ReadableStreamDefaultController{pid: pid}

    result =
      case Map.get(transformer, :transform) do
        transform when is_function(transform, 2) ->
          transform.(chunk, ctrl)

        _ ->
          # Default passthrough: enqueue chunk as-is
          Web.ReadableStreamDefaultController.enqueue(ctrl, chunk)
          :ok
      end

    case result do
      %Web.Promise{task: task} -> Task.await(task, :infinity)
      _ -> :ok
    end

    {:ok, state}
  end

  @impl Web.Stream
  def flush(_ctrl, %{transformer: transformer, pid: pid} = state) do
    ctrl = %Web.ReadableStreamDefaultController{pid: pid}

    result =
      case Map.get(transformer, :flush) do
        flush_fn when is_function(flush_fn, 1) ->
          flush_fn.(ctrl)

        _ ->
          :ok
      end

    case result do
      %Web.Promise{task: task} -> Task.await(task, :infinity)
      _ -> :ok
    end

    {:ok, state}
  end

  @impl Web.Stream
  def terminate({:cancel, reason}, %{transformer: transformer}) do
    do_terminate(reason, transformer)
  end

  def terminate(reason, %{transformer: transformer}) do
    do_terminate(reason, transformer)
  end

  defp do_terminate(reason, transformer) do
    case Map.get(transformer, :cancel) do
      # coveralls-ignore-start
      cancel when is_function(cancel, 1) ->
        cancel.(reason)

      # coveralls-ignore-stop
      _ ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new TransformStream.

  Returns a map with `:readable` (`%Web.ReadableStream{}`) and `:writable`
  (`%Web.WritableStream{}`) keys, both backed by the same engine PID.

  ## Options

  - `:high_water_mark` — the writable-side high water mark (default: 1)
  - `:readable_strategy` — a queuing strategy (e.g. `Web.CountQueuingStrategy.new(n)`)
    for the readable side, allowing users to tune the high-water mark of the
    transformed output queue. Defaults to `Web.CountQueuingStrategy.new(1)`.
  - `:writable_strategy` — legacy alias for `:readable_strategy` (deprecated)

  ## Transformer keys

  - `transform: fn chunk, ctrl -> :ok end` — called for each written chunk; must return `:ok` or a `Web.Promise.t()`
  - `flush: fn ctrl -> :ok end` — called before the stream closes; must return `:ok` or a `Web.Promise.t()`
  - `start: fn ctrl -> :ok end` — called at stream creation; must return `:ok` or a `Web.Promise.t()`
  - `cancel: fn reason -> :ok end` — called if the stream is cancelled
  """
  def new(transformer \\ %{}, opts \\ []) do
    hwm = Keyword.get(opts, :high_water_mark, 1)

    readable_strategy =
      Keyword.get(
        opts,
        :readable_strategy,
        Keyword.get(opts, :writable_strategy, Web.CountQueuingStrategy.new(hwm))
      )

    opts =
      opts
      |> Keyword.put(:transformer, transformer)
      |> Keyword.put_new(:strategy, readable_strategy)

    {:ok, pid} = start_link(opts)

    %{
      readable: %Web.ReadableStream{controller_pid: pid},
      writable: %Web.WritableStream{controller_pid: pid}
    }
  end
end
