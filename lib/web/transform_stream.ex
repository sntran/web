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
      ...>   transform: fn chunk, controller, state ->
      ...>     Web.ReadableStreamDefaultController.enqueue(controller, String.upcase(chunk))
      ...>     {:ok, state}
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
    writable_strategy = Keyword.get(opts, :writable_strategy, Keyword.get(opts, :strategy, Web.CountQueuingStrategy.new(1)))
    readable_strategy = Keyword.get(opts, :readable_strategy, Web.CountQueuingStrategy.new(1))
    state = %{transformer: transformer, pid: pid}
    {:producer_consumer, Map.merge(state, %{writable_strategy: writable_strategy, readable_strategy: readable_strategy})}
  end

  @impl Web.Stream
  def write(chunk, _ctrl, %{transformer: transformer, pid: pid} = state) do
    ctrl = %Web.ReadableStreamDefaultController{pid: pid}

    result =
      case Map.get(transformer, :transform) do
        transform when is_function(transform, 3) ->
          transform.(chunk, ctrl, state)

        transform when is_function(transform, 2) ->
          transform.(chunk, ctrl)
          {:ok, state}

        _ ->
          # Default passthrough: enqueue chunk as-is
          Web.ReadableStreamDefaultController.enqueue(ctrl, chunk)
          {:ok, state}
      end

    case result do
      %Web.Promise{task: task} -> Task.await(task, :infinity)
      other -> other
    end
  end

  @impl Web.Stream
  def flush(_ctrl, %{transformer: transformer, pid: pid} = state) do
    ctrl = %Web.ReadableStreamDefaultController{pid: pid}

    result =
      case Map.get(transformer, :flush) do
        flush_fn when is_function(flush_fn, 2) ->
          flush_fn.(ctrl, state)

        flush_fn when is_function(flush_fn, 1) ->
          flush_fn.(ctrl)
          {:ok, state}

        _ ->
          {:ok, state}
      end

    case result do
      %Web.Promise{task: task} -> Task.await(task, :infinity)
      other -> other
    end
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

  ## Transformer keys

  - `transform: fn chunk, ctrl, state -> {:ok, new_state} end` — called for each written chunk
  - `flush: fn ctrl, state -> {:ok, new_state} end` — called before the stream closes
  - `cancel: fn reason -> :ok end` — called if the stream is cancelled
  """
  def new(transformer \\ %{}, opts \\ []) do
    hwm = Keyword.get(opts, :high_water_mark, 1)
    opts =
      opts
      |> Keyword.put(:transformer, transformer)
      |> Keyword.put_new(
        :strategy,
        Keyword.get(opts, :writable_strategy, Web.CountQueuingStrategy.new(hwm))
      )

    {:ok, pid} = start_link(opts)

    %{
      readable: %Web.ReadableStream{controller_pid: pid},
      writable: %Web.WritableStream{controller_pid: pid}
    }
  end
end
