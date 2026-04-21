defmodule Web.Stream do
  @moduledoc """
  Universal `:gen_statem` stream engine.

  Manages all process logic, locking, and data queuing for `Web.ReadableStream`,
  `Web.WritableStream`, and `Web.TransformStream`.

  ## Behavior Callbacks

  Implementing modules must define `start/2` and may optionally define any of the
  data-processing callbacks. All data-processing callbacks (`pull/2`, `write/3`,
  `flush/2`) run in supervised `Task`s.

  - `start(pid, opts)` — **Required.** Returns the stream type and initial state.
  - `pull(ctrl, state)` — **Optional.** Called when the producer needs more data.
  - `write(chunk, ctrl, state)` — **Optional.** Called to process an incoming write.
  - `flush(ctrl, state)` — **Optional.** Called just before the stream closes.
  - `error(reason, state)` — **Optional.** Called when the stream encounters an error.
  - `terminate(event, state)` — **Optional.** Called when the stream terminates.

  ## Stream Types

  The `start/2` callback declares one of three types:

  - `:producer` — readable source (e.g. `ReadableStream`)
  - `:consumer` — writable sink (e.g. `WritableStream`)
  - `:producer_consumer` — transform (e.g. `TransformStream`)
  """

  @behaviour :gen_statem

  alias Web.AbortSignal
  alias Web.AsyncContext.Snapshot

  # ---------------------------------------------------------------------------
  # Behavior definition
  # ---------------------------------------------------------------------------

  @doc "Initializes the stream and declares its type."
  @callback start(pid :: pid(), opts :: keyword()) ::
              {:producer | :consumer | :producer_consumer, state :: term()}
              | {:producer | :consumer | :producer_consumer, state :: term(), actions :: list()}

  @doc "Called by the engine to pull data from a producer source."
  @callback pull(ctrl :: term(), state :: term()) ::
              {:ok, new_state :: term()}
              | {:ok, new_state :: term(), :pause}
              | {:ok, new_state :: term(), :hibernate}

  @doc "Called by the engine to process an incoming write chunk."
  @callback write(chunk :: term(), ctrl :: term(), state :: term()) ::
              {:ok, new_state :: term()}

  @doc "Called by the engine just before the stream closes (flush/finalize)."
  @callback flush(ctrl :: term(), state :: term()) :: {:ok, new_state :: term()}

  @doc "Called by the engine to notify the module of a stream error."
  @callback error(reason :: term(), state :: term()) :: {:ok, new_state :: term()}

  @doc "Called by the engine when the stream terminates."
  @callback terminate(event :: term(), state :: term()) :: :ok

  @optional_callbacks [pull: 2, write: 3, flush: 2, error: 2, terminate: 2]

  @doc """
  Sets up an implementing stream module with the `Web.Stream` behaviour and
  a default `start_link/1` delegating to the shared engine.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Web.Stream

      def start_link(opts \\ []) do
        Web.Stream.start_link(__MODULE__, opts)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Engine data
  # ---------------------------------------------------------------------------

  defstruct [
    :module,
    :type,
    :impl_state,
    :active_task,
    :task_ref,
    :task_timeout_ref,
    :active_operation,
    :async_context,
    # Producer (readable) side
    queue: :queue.new(),
    hwm: 1,
    readable_hwm: 1,
    writable_hwm: 1,
    total_queued_size: 0,
    strategy: %Web.CountQueuingStrategy{},
    pulling: false,
    reader_pid: nil,
    reader_ref: nil,
    read_requests: :queue.new(),
    disturbed: false,
    # Consumer (writable) side
    writer_pid: nil,
    writer_ref: nil,
    pending_write_request: nil,
    pending_close_request: nil,
    queued_write_requests: :queue.new(),
    ready_waiters: :queue.new(),
    # Transform-side readable backpressure (transform task parks here until readable has space)
    enqueue_waiters: :queue.new(),
    backpressure: false,
    # Shared
    timeout_ms: 30_000,
    error_reason: nil
  ]

  # ---------------------------------------------------------------------------
  # Public start
  # ---------------------------------------------------------------------------

  @doc "Starts a stream engine process for the given implementing module."
  def start_link(module, opts) when is_atom(module) do
    snapshot = Snapshot.take()
    :gen_statem.start_link(__MODULE__, {module, opts, snapshot}, [])
  end

  @doc false
  def control_cast(pid, message) when is_pid(pid) do
    priority_send(pid, {:"$gen_cast", message})
    :ok
  end

  @doc false
  def control_call(pid, message, timeout \\ :infinity) when is_pid(pid) do
    monitor_ref = Process.monitor(pid)
    ref = make_ref()
    priority_send(pid, {:"$gen_call", {self(), ref}, message})

    receive do
      {^ref, reply} ->
        Process.demonitor(monitor_ref, [:flush])
        reply

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        exit({reason, {__MODULE__, :control_call, [pid, message, timeout]}})
    after
      timeout ->
        Process.demonitor(monitor_ref, [:flush])
        exit({:timeout, {__MODULE__, :control_call, [pid, message, timeout]}})
    end
  end

  # ---------------------------------------------------------------------------
  # :gen_statem callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init({module, opts, snapshot}) do
    Process.flag(:message_queue_data, :off_heap)
    hwm = Keyword.get(opts, :high_water_mark, 1)
    strategy = normalize_strategy(Keyword.get(opts, :strategy, %Web.CountQueuingStrategy{}))
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    {type, impl_state, extra_actions} =
      case module.start(self(), opts) do
        {t, s} -> {t, s, []}
        {t, s, a} -> {t, s, a}
      end

    {readable_hwm, writable_hwm} = init_capacities(type, hwm, strategy)

    data = %__MODULE__{
      module: module,
      type: type,
      impl_state: impl_state,
      hwm: hwm,
      readable_hwm: readable_hwm,
      writable_hwm: writable_hwm,
      total_queued_size: 0,
      strategy: strategy,
      timeout_ms: timeout_ms,
      async_context: snapshot
    }

    {initial_state, default_actions} =
      case type do
        :producer ->
          # auto-pull unless the module provided explicit init actions
          default = if extra_actions == [], do: [{:next_event, :internal, :maybe_pull}], else: []
          {:readable, default}

        :consumer ->
          {:writable, []}

        :producer_consumer ->
          {:writable, []}
      end

    all_actions = extra_actions ++ default_actions

    data =
      if type in [:consumer, :producer_consumer] do
        refresh_backpressure(data)
      else
        data
      end

    # Bind ambient AbortSignal — if one was captured in the snapshot, subscribe
    # so the stream auto-cancels when the signal fires.
    maybe_bind_ambient_signal(snapshot)

    {:ok, initial_state, data, all_actions}
  end

  @impl true
  @doc "Terminates a stream engine process with a unified terminal event."
  def terminate(pid, type, reason \\ nil)

  def terminate(pid, type, reason) when is_pid(pid) do
    control_cast(pid, {:terminate, type, reason})
  end

  def terminate(_reason, _state, data) do
    if data.active_task, do: Task.shutdown(data.active_task, :brutal_kill)
    :ok
  end

  # ---------------------------------------------------------------------------
  # State: readable  (producers only)
  # ---------------------------------------------------------------------------

  def readable(type, content, data) do
    case handle_common(type, content, :readable, data) do
      :not_handled ->
        case {type, content} do
          {:cast, {:enqueue, chunk}} ->
            handle_producer_enqueue(chunk, :readable, data)

          {:cast, :close} ->
            handle_producer_close(data)

          {:internal, {:start_task, fun}} ->
            task =
              start_task(
                fn ->
                  try do
                    fun.()
                    {:ok, :init_done}
                  rescue
                    e -> {:error, e}
                  catch
                    kind, r -> {:error, {kind, r}}
                  end
                end,
                data.async_context
              )

            {:keep_state, set_active_task(data, task, :init, pulling: true)}

          {:internal, :maybe_pull} ->
            handle_maybe_pull(data)

          # coveralls-ignore-start
          _ ->
            {:keep_state_and_data, [:postpone]}
            # coveralls-ignore-stop
        end

      result ->
        result
    end
  end

  # ---------------------------------------------------------------------------
  # State: writable  (consumers AND producer_consumers)
  # ---------------------------------------------------------------------------

  def writable(type, content, data) do
    # For producer_consumer, readable-side ops work in any state
    with :not_handled <- maybe_handle_producer_side(type, content, :writable, data),
         :not_handled <- handle_common(type, content, :writable, data) do
      case {type, content} do
        {{:call, from}, {:write, pid, chunk}} ->
          handle_write(from, pid, chunk, :writable, data)

        {{:call, from}, {:close, pid}} ->
          handle_close(from, pid, :writable, data)

        {{:call, from}, {:abort, pid, reason}} ->
          handle_abort(from, pid, reason, data)

        {:internal, {:start_task, fun}} ->
          task =
            start_task(
              fn ->
                try do
                  fun.()
                  {:ok, :start_done}
                rescue
                  e -> {:error, e}
                catch
                  kind, r -> {:error, {kind, r}}
                end
              end,
              data.async_context
            )

          {:keep_state, set_active_task(data, task, :start)}

        # coveralls-ignore-start
        _ ->
          :keep_state_and_data
          # coveralls-ignore-stop
      end
    end
  end

  # ---------------------------------------------------------------------------
  # State: closing  (consumers draining writes before flush)
  # ---------------------------------------------------------------------------

  def closing(type, content, data) do
    with :not_handled <- maybe_handle_producer_side(type, content, :closing, data),
         :not_handled <- handle_common(type, content, :closing, data) do
      handle_closing_event(type, content, data)
    end
  end

  defp handle_closing_event({:call, from}, {:write, pid, _chunk}, data) do
    reply_to_writer(from, pid, data.writer_pid, {:error, :closing})
  end

  defp handle_closing_event({:call, from}, {:close, pid}, data) do
    reply_to_writer(from, pid, data.writer_pid, {:error, :closing})
  end

  defp handle_closing_event({:call, from}, {:abort, pid, reason}, data) do
    handle_abort(from, pid, reason, data)
  end

  defp handle_closing_event(_type, _content, _data), do: :keep_state_and_data

  # ---------------------------------------------------------------------------
  # State: closed
  # ---------------------------------------------------------------------------

  def closed(type, content, data) do
    with :not_handled <- handle_common(type, content, :closed, data) do
      handle_closed_event(type, content, data)
    end
  end

  # ---------------------------------------------------------------------------
  # State: errored
  # ---------------------------------------------------------------------------

  def errored(type, content, data) do
    with :not_handled <- handle_common(type, content, :errored, data) do
      case {type, content} do
        {:internal, :flush_requests} ->
          flush_errored_requests(data)

        {{:call, from}, {:write, pid, _chunk}} ->
          _ = pid
          {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}

        {{:call, from}, {:close, pid}} ->
          _ = pid
          {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}

        {{:call, from}, {:abort, pid, _reason}} ->
          _ = pid
          {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}

        _ ->
          :keep_state_and_data
      end
    end
  end

  # ---------------------------------------------------------------------------
  # handle_common — operations valid in all states
  # ---------------------------------------------------------------------------

  # Reader lock acquisition
  defp handle_common(
         {:call, from},
         {:get_reader, pid},
         _state,
         %{reader_pid: nil} = data
       )
       when data.type in [:producer, :producer_consumer] do
    ref = Process.monitor(pid)
    {:keep_state, %{data | reader_pid: pid, reader_ref: ref}, [{:reply, from, {:ok, ref}}]}
  end

  defp handle_common({:call, from}, {:get_reader, _pid}, _state, data)
       when data.type in [:producer, :producer_consumer] do
    {:keep_state_and_data, [{:reply, from, {:error, :already_locked}}]}
  end

  # Force-error helpers for testing
  defp handle_common(
         {:call, from},
         {:read, _pid},
         _state,
         %{error_reason: :force_unexpected_read} = data
       ) do
    {:keep_state, %{data | error_reason: nil}, [{:reply, from, {:error, :unexpected}}]}
  end

  defp handle_common(
         {:call, from},
         {:read, _pid},
         _state,
         %{error_reason: :force_error_no_reason} = data
       ) do
    {:keep_state, %{data | error_reason: nil}, [{:reply, from, {:error, :errored}}]}
  end

  # Read a chunk
  defp handle_common({:call, from}, {:read, pid}, state, data)
       when data.type in [:producer, :producer_consumer] do
    handle_read_request(from, pid, state, data)
  end

  # Release force-error for release_lock
  defp handle_common(
         {:call, from},
         {:release_lock, _pid},
         _state,
         %{error_reason: :force_unexpected_release} = data
       ) do
    {:keep_state, %{data | error_reason: nil}, [{:reply, from, {:error, :unexpected}}]}
  end

  # Reader lock release
  defp handle_common({:call, from}, {:release_lock, pid}, _state, data)
       when data.type in [:producer, :producer_consumer] and is_pid(data.reader_pid) do
    if pid == data.reader_pid do
      if data.reader_ref, do: Process.demonitor(data.reader_ref, [:flush])
      {:keep_state, %{data | reader_pid: nil, reader_ref: nil}, [{:reply, from, :ok}]}
    else
      {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_reader}}]}
    end
  end

  # Writer lock acquisition
  defp handle_common(
         {:call, from},
         {:get_writer, pid},
         _state,
         %{writer_pid: nil} = data
       )
       when data.type in [:consumer, :producer_consumer] do
    ref = Process.monitor(pid)
    {:keep_state, %{data | writer_pid: pid, writer_ref: ref}, [{:reply, from, :ok}]}
  end

  defp handle_common({:call, from}, {:get_writer, _pid}, _state, data)
       when data.type in [:consumer, :producer_consumer] do
    {:keep_state_and_data, [{:reply, from, {:error, :already_locked}}]}
  end

  # Writer lock release
  defp handle_common({:call, from}, {:release_lock, pid}, _state, data)
       when data.type in [:consumer, :producer_consumer] and is_pid(data.writer_pid) do
    if pid == data.writer_pid do
      if data.writer_ref, do: Process.demonitor(data.writer_ref, [:flush])
      {:keep_state, %{data | writer_pid: nil, writer_ref: nil}, [{:reply, from, :ok}]}
    else
      {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
    end
  end

  # Generic release_lock (no lock held or wrong type)
  defp handle_common({:call, from}, {:release_lock, _pid}, _state, data) do
    error =
      if data.type in [:producer, :producer_consumer],
        do: :not_locked_by_reader,
        else: :not_locked_by_writer

    {:keep_state_and_data, [{:reply, from, {:error, error}}]}
  end

  # Ready (backpressure signal for writers)
  defp handle_common({:call, from}, {:ready, pid}, state, data)
       when data.type in [:consumer, :producer_consumer] do
    cond do
      pid != data.writer_pid ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}

      state == :closed ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      writable_ready?(data) ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      true ->
        new_waiters = :queue.in(from, data.ready_waiters)
        {:keep_state, %{data | ready_waiters: new_waiters}}
    end
  end

  # Enqueue-ready: transform task parks here until the readable queue has capacity
  defp handle_common({:call, from}, :enqueue_ready, state, %{type: :producer_consumer} = data) do
    cond do
      state in [:closed, :errored] ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      readable_capacity(data) > 0 ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      true ->
        {:keep_state, %{data | enqueue_waiters: :queue.in(from, data.enqueue_waiters)}}
    end
  end

  # Query helpers
  defp handle_common({:call, from}, :disturbed?, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.disturbed}]}
  end

  defp handle_common({:call, from}, :locked?, _state, data) do
    locked =
      cond do
        data.type in [:producer, :producer_consumer] -> not is_nil(data.reader_pid)
        data.type == :consumer -> not is_nil(data.writer_pid)
      end

    {:keep_state_and_data, [{:reply, from, locked}]}
  end

  defp handle_common({:call, from}, :backpressure?, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.backpressure}]}
  end

  defp handle_common({:call, from}, :desired_size, state, data) do
    desired =
      if state in [:closed, :errored] do
        nil
      else
        internal_desired_size(data)
      end

    {:keep_state_and_data, [{:reply, from, desired}]}
  end

  defp handle_common({:call, from}, :get_desired_size, state, data) do
    desired =
      if state in [:closed, :errored] do
        nil
      else
        readable_desired_size(data)
      end

    {:keep_state_and_data, [{:reply, from, desired}]}
  end

  defp handle_common({:call, from}, :get_slots, state, data) do
    readable_desired_size =
      if(state in [:closed, :errored], do: nil, else: readable_desired_size(data))

    writable_desired_size =
      if(state in [:closed, :errored], do: nil, else: internal_desired_size(data))

    slots =
      data
      |> Map.from_struct()
      |> Map.put(:state, state)
      |> Map.put(:desired_size, slot_desired_size(data, state))
      |> Map.put(:readable_desired_size, readable_desired_size)
      |> Map.put(:writable_desired_size, writable_desired_size)

    {:keep_state_and_data, [{:reply, from, slots}]}
  end

  defp handle_common({:call, from}, :force_unknown_error, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :unexpected}}]}
  end

  # Error injection (cast)
  defp handle_common({:call, from}, {:terminate, type, reason}, state, data)
       when type in [:cancel, :close, :abort, :error] do
    case handle_terminate_request(type, reason, state, data) do
      :keep_state_and_data ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      {:next_state, next_state, new_data, actions} ->
        {:next_state, next_state, new_data, [{:reply, from, :ok} | actions]}
    end
  end

  defp handle_common(:cast, {:error, reason}, state, data) do
    if state in [:closed, :errored] do
      :keep_state_and_data
    else
      fail_stream(reason, data)
    end
  end

  defp handle_common(:cast, {:terminate, type, reason}, state, data)
       when type in [:cancel, :close, :abort, :error] do
    handle_terminate_request(type, reason, state, data)
  end

  # Cancel
  defp handle_common(:cast, {:cancel, reason}, _state, data) do
    handle_termination(:cancel, reason, data)
  end

  defp handle_common(
         :cast,
         {:register_ready_waiter, waiter_pid, owner_pid, ref},
         state,
         data
       )
       when data.type in [:consumer, :producer_consumer] do
    cond do
      owner_pid != data.writer_pid ->
        priority_send(waiter_pid, {:stream_error, ref, :not_locked_by_writer})
        :keep_state_and_data

      state == :closed ->
        priority_send(waiter_pid, {:ready, ref})
        :keep_state_and_data

      writable_ready?(data) ->
        priority_send(waiter_pid, {:ready, ref})
        :keep_state_and_data

      true ->
        waiter = {:signal, waiter_pid, ref}
        {:keep_state, %{data | ready_waiters: :queue.in(waiter, data.ready_waiters)}}
    end
  end

  defp handle_common(
         :cast,
         {:register_enqueue_waiter, waiter_pid, ref},
         state,
         %{
           type: :producer_consumer
         } = data
       ) do
    cond do
      state in [:closed, :errored] ->
        priority_send(waiter_pid, {:ready, ref})
        :keep_state_and_data

      readable_capacity(data) > 0 ->
        priority_send(waiter_pid, {:ready, ref})
        :keep_state_and_data

      true ->
        waiter = {:signal, waiter_pid, ref}
        {:keep_state, %{data | enqueue_waiters: :queue.in(waiter, data.enqueue_waiters)}}
    end
  end

  # Task result (info message: {ref, result})
  defp handle_common(:info, {ref, result}, state, data) when is_reference(ref) do
    if ref == data.task_ref do
      case data.active_operation do
        :abort ->
          handle_abort_task_result(result, data)

        _ ->
          handle_task_result(result, state, data)
      end
    else
      :keep_state_and_data
    end
  end

  # Task timeout handling
  defp handle_common(:info, {:task_timeout, ref}, _state, data) do
    if ref == data.task_ref and data.active_task do
      operation = timeout_operation(data.active_operation)
      Task.shutdown(data.active_task, :brutal_kill)
      fail_stream({:error, {:task_timeout, operation}}, clear_active_operation(data))
    else
      :keep_state_and_data
    end
  end

  # Task DOWN monitoring
  defp handle_common(:info, {:DOWN, ref, :process, _pid, reason}, _state, data) do
    cond do
      ref == data.reader_ref ->
        {:keep_state, %{data | reader_pid: nil, reader_ref: nil}}

      ref == data.writer_ref ->
        {:keep_state, %{data | writer_pid: nil, writer_ref: nil}}

      ref == data.task_ref and data.active_operation == :abort ->
        {:keep_state, clear_active_operation(data)}

      ref == data.task_ref and reason == :normal ->
        :keep_state_and_data

      ref == data.task_ref ->
        fail_stream(reason, data)

      true ->
        :keep_state_and_data
    end
  end

  # Ambient AbortSignal fired
  defp handle_common(:info, {:ambient_signal_abort, reason}, state, data) do
    if state in [:closed, :errored] do
      :keep_state_and_data
    else
      handle_termination(:cancel, reason, data)
    end
  end

  defp handle_common(_type, _content, _state, _data), do: :not_handled

  defp handle_closed_event(:cast, {:enqueue, _chunk}, _data), do: :keep_state_and_data
  defp handle_closed_event(:internal, :flush_requests, data), do: flush_read_requests(data)

  defp handle_closed_event({:call, from}, {:write, pid, _chunk}, data) do
    reply_to_writer(from, pid, data.writer_pid, {:error, :closed})
  end

  defp handle_closed_event({:call, from}, {:close, pid}, data) do
    reply_to_writer(from, pid, data.writer_pid, :ok)
  end

  defp handle_closed_event({:call, from}, {:abort, pid, _reason}, data) do
    reply_to_writer(from, pid, data.writer_pid, :ok)
  end

  # coveralls-ignore-start
  defp handle_closed_event(_type, _content, _data), do: {:keep_state_and_data, [:postpone]}
  # coveralls-ignore-stop

  defp reply_to_writer(from, pid, writer_pid, success_reply) when pid == writer_pid do
    {:keep_state_and_data, [{:reply, from, success_reply}]}
  end

  defp reply_to_writer(from, _pid, _writer_pid, _success_reply) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
  end

  defp handle_read_request(from, pid, _state, data) when pid != data.reader_pid do
    {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_reader}}]}
  end

  defp handle_read_request(from, _pid, :errored, data) do
    disturbed_data = %{data | disturbed: true}
    {:keep_state, disturbed_data, [{:reply, from, {:error, {:errored, data.error_reason}}}]}
  end

  defp handle_read_request(from, _pid, state, data) do
    data = %{data | disturbed: true}

    if :queue.is_empty(data.queue) do
      queue_or_complete_read(from, state, data)
    else
      pop_queued_chunk(from, data)
    end
  end

  defp queue_or_complete_read(from, :closed, data) do
    {:keep_state, data, [{:reply, from, :done}]}
  end

  defp queue_or_complete_read(from, _state, data) do
    new_requests = :queue.in(from, data.read_requests)

    {:keep_state, %{data | read_requests: new_requests}, [{:next_event, :internal, :maybe_pull}]}
  end

  defp pop_queued_chunk(from, data) do
    {{:value, chunk}, new_queue} = :queue.out(data.queue)

    new_data = %{
      data
      | queue: new_queue,
        total_queued_size: data.total_queued_size - queue_chunk_size(data, chunk)
    }

    actions = [{:reply, from, {:ok, chunk}}]
    {new_data, actions} = maybe_refresh_read_actions(new_data, actions)
    {:keep_state, new_data, maybe_request_pull(new_data, actions)}
  end

  defp maybe_refresh_read_actions(%{type: :producer_consumer} = data, actions) do
    data = refresh_backpressure(data)
    {data, ready_actions} = maybe_resolve_ready_waiters(data)
    {data, enqueue_actions} = maybe_resolve_enqueue_waiters(data)
    {data, actions ++ ready_actions ++ enqueue_actions}
  end

  defp maybe_refresh_read_actions(data, actions), do: {data, actions}

  defp maybe_request_pull(data, actions) do
    if readable_desired_size(data) > 0 do
      [{:next_event, :internal, :maybe_pull} | actions]
    else
      actions
    end
  end

  # ---------------------------------------------------------------------------
  # Producer-side helpers (for producer_consumer, used in non-readable states)
  # ---------------------------------------------------------------------------

  defp maybe_handle_producer_side(_type, _content, _state, %{type: :consumer}), do: :not_handled

  defp maybe_handle_producer_side(type, content, state, data) do
    case {type, content} do
      {:cast, {:enqueue, chunk}} ->
        handle_producer_enqueue(chunk, state, data)

      _ ->
        :not_handled
    end
  end

  # ---------------------------------------------------------------------------
  # Producer enqueue logic (used from readable/3 and producer_consumer states)
  # ---------------------------------------------------------------------------

  defp handle_producer_enqueue(chunk, _state, data) do
    chunk_size = queue_chunk_size(data, chunk)

    new_data = %{
      data
      | queue: :queue.in(chunk, data.queue),
        total_queued_size: data.total_queued_size + chunk_size
    }

    case :queue.out(new_data.read_requests) do
      {{:value, from}, new_requests} ->
        {{:value, c}, new_queue} = :queue.out(new_data.queue)
        # The chunk is consumed immediately — undo the size increment so
        # total_queued_size stays accurate (chunk never resided in the queue).
        new_data = %{
          new_data
          | read_requests: new_requests,
            queue: new_queue,
            total_queued_size: new_data.total_queued_size - chunk_size
        }

        new_data = refresh_backpressure(new_data)
        :gen_statem.reply(from, {:ok, c})

        {:keep_state, new_data, [{:next_event, :internal, :maybe_pull}]}

      {:empty, _} ->
        new_data = refresh_backpressure(new_data)
        {:keep_state, new_data}
    end
  end

  defp handle_producer_close(data) do
    {:next_state, :closed, %{data | pulling: false}, [{:next_event, :internal, :flush_requests}]}
  end

  defp flush_read_requests(data) do
    if :queue.is_empty(data.queue) do
      data.read_requests
      |> :queue.to_list()
      |> Enum.each(&:gen_statem.reply(&1, :done))

      {:keep_state, %{data | read_requests: :queue.new()}}
    else
      :keep_state_and_data
    end
  end

  defp flush_errored_requests(data) do
    data.read_requests
    |> :queue.to_list()
    |> Enum.each(&:gen_statem.reply(&1, {:error, {:errored, data.error_reason}}))

    {:keep_state, %{data | read_requests: :queue.new()}}
  end

  # ---------------------------------------------------------------------------
  # Maybe pull (producer backpressure)
  # ---------------------------------------------------------------------------

  defp handle_maybe_pull(data) do
    effective_ds = readable_desired_size(data)

    if not data.pulling and effective_ds > 0 do
      do_trigger_pull(data)
    else
      :keep_state_and_data
    end
  end

  defp do_trigger_pull(%{module: module, impl_state: impl_state} = data) do
    if function_exported?(module, :pull, 2) do
      ctrl = %Web.ReadableStreamDefaultController{pid: self()}

      task =
        start_task(
          fn ->
            try do
              module.pull(ctrl, impl_state) |> resolve_if_promise({:ok, impl_state})
            rescue
              e -> {:error, e}
            catch
              kind, reason -> {:error, {kind, reason}}
            end
          end,
          data.async_context
        )

      {:keep_state, set_active_task(data, task, :pull, pulling: true)}
    else
      :keep_state_and_data
    end
  end

  # ---------------------------------------------------------------------------
  # Consumer write/close/abort handlers
  # ---------------------------------------------------------------------------

  defp handle_write(from, pid, chunk, _state, data) do
    cond do
      pid != data.writer_pid ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}

      active_consumer_operation?(data) ->
        new_data =
          data
          |> enqueue_write_request({from, pid, chunk})
          |> refresh_backpressure()

        {:keep_state, new_data}

      true ->
        data
        |> start_write_task({from, pid, chunk})
        |> reply_keep_state()
    end
  end

  defp handle_close(from, pid, _state, data) do
    cond do
      pid != data.writer_pid ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}

      data.pending_close_request ->
        {:keep_state_and_data, [{:reply, from, {:error, :closing}}]}

      active_consumer_operation?(data) or not :queue.is_empty(data.queued_write_requests) ->
        {:next_state, :closing, %{data | pending_close_request: from}}

      true ->
        data
        |> Map.put(:pending_close_request, from)
        |> start_flush_task()
    end
  end

  defp handle_abort(from, pid, reason, data) do
    if pid != data.writer_pid do
      {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
    else
      if data.active_task && data.active_operation != :abort do
        Task.shutdown(data.active_task, :brutal_kill)
      end

      :gen_statem.reply(from, :ok)

      data
      |> clear_active_operation()
      |> start_abort_task(reason)
      |> then(&fail_stream(reason, &1))
    end
  end

  # ---------------------------------------------------------------------------
  # Consumer task starters
  # ---------------------------------------------------------------------------

  defp start_write_task(data, request) do
    {from, _pid, chunk} = request
    module = data.module
    impl_state = data.impl_state
    ctrl = %Web.ReadableStreamDefaultController{pid: self()}

    task =
      start_task(
        fn ->
          try do
            module.write(chunk, ctrl, impl_state) |> resolve_if_promise({:ok, impl_state})
          rescue
            e -> {:error, e}
          catch
            kind, reason -> {:error, {kind, reason}}
          end
        end,
        data.async_context
      )

    data
    |> Map.put(:pending_write_request, request)
    |> set_active_task(task, {:write, from})
    |> refresh_backpressure()
  end

  defp start_flush_task(data) do
    module = data.module
    impl_state = data.impl_state
    ctrl = %Web.ReadableStreamDefaultController{pid: self()}

    task =
      start_task(
        fn ->
          try do
            if function_exported?(module, :flush, 2) do
              module.flush(ctrl, impl_state) |> resolve_if_promise({:ok, impl_state})
            else
              {:ok, impl_state}
            end
          rescue
            e -> {:error, e}
          catch
            kind, reason -> {:error, {kind, reason}}
          end
        end,
        data.async_context
      )

    {:next_state, :closing, set_active_task(data, task, {:flush, data.pending_close_request})}
  end

  defp start_abort_task(data, reason) do
    module = data.module
    impl_state = data.impl_state

    task =
      start_task(
        fn ->
          try do
            if function_exported?(module, :terminate, 2) do
              module.terminate(reason, impl_state)
            else
              :ok
            end
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end
        end,
        data.async_context
      )

    set_active_task(data, task, :abort)
  end

  # ---------------------------------------------------------------------------
  # Task result handling
  # ---------------------------------------------------------------------------

  defp handle_task_result({:error, reason}, _state, data) do
    fail_stream(reason, data)
  end

  # Producer pull completed
  defp handle_task_result(
         {:ok, new_impl_state, :pause},
         _state,
         %{active_operation: :pull} = data
       ) do
    new_data =
      data
      |> Map.put(:impl_state, new_impl_state)
      |> clear_active_operation()
      |> Map.put(:pulling, false)

    {:keep_state, new_data}
  end

  defp handle_task_result(
         {:ok, new_impl_state, :hibernate},
         _state,
         %{active_operation: :pull} = data
       ) do
    new_data =
      data
      |> Map.put(:impl_state, new_impl_state)
      |> clear_active_operation()
      |> Map.put(:pulling, false)

    {:keep_state, new_data, [:hibernate]}
  end

  defp handle_task_result({:ok, new_impl_state}, _state, %{active_operation: :pull} = data) do
    new_data =
      data
      |> Map.put(:impl_state, new_impl_state)
      |> clear_active_operation()
      |> Map.put(:pulling, false)

    {:keep_state, new_data, [{:next_event, :internal, :maybe_pull}]}
  end

  # Producer init (start_task) completed
  defp handle_task_result({:ok, :init_done}, _state, %{active_operation: :init} = data) do
    new_data = data |> Map.put(:pulling, false) |> clear_active_operation()
    {:keep_state, new_data, [{:next_event, :internal, :maybe_pull}]}
  end

  # Consumer start task completed
  defp handle_task_result({:ok, :start_done}, state, %{active_operation: :start} = data) do
    data
    |> clear_active_operation()
    |> continue_after_consumer_completion(state, [])
  end

  # Write task completed
  defp handle_task_result(result, state, %{active_operation: {:write, from}} = data) do
    data
    |> clear_active_operation()
    |> Map.put(:pending_write_request, nil)
    |> Map.put(:impl_state, extract_new_state_from_result(result, data.impl_state))
    |> refresh_backpressure()
    |> continue_after_consumer_completion(state, [{:reply, from, :ok}])
  end

  # Flush task completed
  defp handle_task_result(result, _state, %{active_operation: {:flush, from}} = data) do
    data
    |> clear_active_operation()
    |> Map.put(:pending_close_request, nil)
    |> Map.put(:impl_state, extract_new_state_from_result(result, data.impl_state))
    |> close_consumer_stream([{:reply, from, :ok}])
  end

  defp handle_abort_task_result(_result, data) do
    {:keep_state, clear_active_operation(data)}
  end

  # coveralls-ignore-start
  defp extract_new_state_from_result({:ok, new_state}, _old_state) do
    new_state
  end

  # coveralls-ignore-stop

  defp continue_after_consumer_completion(data, state, actions) do
    cond do
      not :queue.is_empty(data.queued_write_requests) ->
        {{:value, request}, remaining} = :queue.out(data.queued_write_requests)

        new_data =
          data
          |> Map.put(:queued_write_requests, remaining)
          |> start_write_task(request)

        {:keep_state, new_data, actions}

      state == :closing and data.pending_close_request ->
        case start_flush_task(data) do
          {:next_state, :closing, new_data} ->
            {:next_state, :closing, new_data, actions}
        end

      true ->
        {new_data, ready_actions} = maybe_resolve_ready_waiters(data)
        {:keep_state, new_data, actions ++ ready_actions}
    end
  end

  defp close_consumer_stream(data, actions) do
    {new_data, ready_actions} =
      data
      |> Map.put(:backpressure, false)
      |> maybe_resolve_ready_waiters(force?: true)

    {:next_state, :closed, new_data,
     actions ++ ready_actions ++ [{:next_event, :internal, :flush_requests}]}
  end

  # ---------------------------------------------------------------------------
  # Stream failure (error state)
  # ---------------------------------------------------------------------------

  defp fail_stream(reason, data, actions \\ []) do
    cond do
      data.active_operation == :abort ->
        :ok

      is_nil(data.active_task) ->
        :ok

      true ->
        Task.shutdown(data.active_task, :brutal_kill)
    end

    error_actions =
      pending_write_error_actions(data, reason) ++
        queued_write_error_actions(data, reason) ++
        close_error_actions(data, reason) ++
        ready_error_actions(data, reason) ++
        enqueue_error_actions(data, reason)

    new_data =
      data
      |> preserve_abort_task()
      |> clear_writer_lock()
      |> Map.put(:pending_write_request, nil)
      |> Map.put(:queued_write_requests, :queue.new())
      |> Map.put(:pending_close_request, nil)
      |> Map.put(:ready_waiters, :queue.new())
      |> Map.put(:enqueue_waiters, :queue.new())
      |> Map.put(:backpressure, false)
      |> Map.put(:error_reason, reason)

    {:next_state, :errored, new_data,
     actions ++ error_actions ++ [{:next_event, :internal, :flush_requests}]}
  end

  defp clear_writer_lock(%{writer_ref: writer_ref} = data) do
    if writer_ref, do: Process.demonitor(writer_ref, [:flush])
    %{data | writer_pid: nil, writer_ref: nil}
  end

  defp pending_write_error_actions(%{pending_write_request: {from, _pid, _chunk}}, reason) do
    [waiter_error_action(from, reason)]
  end

  defp pending_write_error_actions(_data, _reason), do: []

  defp queued_write_error_actions(data, reason) do
    data.queued_write_requests
    |> :queue.to_list()
    |> Enum.map(fn {from, _pid, _chunk} -> waiter_error_action(from, reason) end)
  end

  defp close_error_actions(%{pending_close_request: from}, reason) when not is_nil(from) do
    [waiter_error_action(from, reason)]
  end

  defp close_error_actions(_data, _reason), do: []

  defp ready_error_actions(data, reason) do
    data.ready_waiters
    |> :queue.to_list()
    |> Enum.flat_map(&List.wrap(waiter_error_action(&1, reason)))
  end

  defp enqueue_error_actions(data, reason) do
    data.enqueue_waiters
    |> :queue.to_list()
    |> Enum.flat_map(&List.wrap(waiter_error_action(&1, reason)))
  end

  # ---------------------------------------------------------------------------
  # Helper utilities
  # ---------------------------------------------------------------------------

  defp handle_termination(type, reason, data) do
    data
    |> clear_owner()
    |> clear_task()
    |> signal_terminate(type, reason)
    |> finalize_termination(type, reason)
  end

  defp finalize_termination(data, type, _reason) when type in [:cancel, :close] do
    actions =
      pending_write_closed_actions(data) ++
        queued_write_closed_actions(data) ++
        close_ok_actions(data) ++
        ready_ok_actions(data)

    new_data = %{
      data
      | disturbed: type == :cancel or data.disturbed,
        queue: if(type == :cancel, do: :queue.new(), else: data.queue),
        pulling: false,
        pending_write_request: nil,
        pending_close_request: nil,
        queued_write_requests: :queue.new(),
        ready_waiters: :queue.new(),
        backpressure: false,
        error_reason: nil
    }

    {:next_state, :closed, new_data, actions ++ [{:next_event, :internal, :flush_requests}]}
  end

  defp finalize_termination(data, _type, reason) do
    error_actions =
      pending_write_error_actions(data, reason) ++
        queued_write_error_actions(data, reason) ++
        close_error_actions(data, reason) ++
        ready_error_actions(data, reason)

    new_data = %{
      data
      | pending_write_request: nil,
        queued_write_requests: :queue.new(),
        pending_close_request: nil,
        ready_waiters: :queue.new(),
        backpressure: false,
        error_reason: reason
    }

    {:next_state, :errored, new_data,
     error_actions ++ [{:next_event, :internal, :flush_requests}]}
  end

  defp signal_terminate(%{module: module, impl_state: impl_state} = data, type, reason) do
    if function_exported?(module, :terminate, 2) do
      module.terminate({type, reason}, impl_state)
    end

    data
  end

  defp clear_owner(%{reader_ref: reader_ref, writer_ref: writer_ref} = data) do
    if reader_ref, do: Process.demonitor(reader_ref, [:flush])
    if writer_ref, do: Process.demonitor(writer_ref, [:flush])
    %{data | reader_pid: nil, reader_ref: nil, writer_pid: nil, writer_ref: nil}
  end

  defp clear_task(data) do
    if data.active_task, do: Task.shutdown(data.active_task, :brutal_kill)
    data |> clear_active_operation() |> Map.put(:pulling, false)
  end

  defp pending_write_closed_actions(%{pending_write_request: {from, _pid, _chunk}}) do
    [waiter_closed_action(from)]
  end

  defp pending_write_closed_actions(_data), do: []

  defp queued_write_closed_actions(data) do
    data.queued_write_requests
    |> :queue.to_list()
    |> Enum.map(fn {from, _pid, _chunk} -> waiter_closed_action(from) end)
  end

  defp close_ok_actions(%{pending_close_request: from}) when not is_nil(from) do
    [waiter_ok_action(from)]
  end

  defp close_ok_actions(_data), do: []

  defp ready_ok_actions(data) do
    data.ready_waiters
    |> :queue.to_list()
    |> Enum.flat_map(&List.wrap(waiter_ok_action(&1)))
  end

  defp refresh_backpressure(data) do
    %{data | backpressure: not writable_ready?(data)}
  end

  defp internal_desired_size(%{type: :consumer} = data) do
    writable_capacity(data)
  end

  defp internal_desired_size(%{type: :producer_consumer} = data) do
    writable_capacity(data)
  end

  defp internal_desired_size(data) do
    readable_desired_size(data)
  end

  defp readable_desired_size(data) do
    readable_capacity(data)
  end

  defp readable_capacity(data) do
    data.readable_hwm - data.total_queued_size
  end

  defp writable_capacity(data) do
    data.writable_hwm - pending_write_count(data)
  end

  defp writable_ready?(data) do
    writable_capacity(data) > 0
  end

  defp pending_write_count(data) do
    :queue.len(data.queued_write_requests) + if(data.pending_write_request, do: 1, else: 0)
  end

  defp enqueue_write_request(data, request) do
    %{data | queued_write_requests: :queue.in(request, data.queued_write_requests)}
  end

  defp active_consumer_operation?(data) do
    not is_nil(data.active_task) or not is_nil(data.pending_write_request)
  end

  defp clear_active_operation(data) do
    if data.task_timeout_ref do
      Process.cancel_timer(data.task_timeout_ref)
    end

    %{data | active_task: nil, task_ref: nil, task_timeout_ref: nil, active_operation: nil}
  end

  defp preserve_abort_task(%{active_operation: :abort} = data), do: data
  defp preserve_abort_task(data), do: clear_active_operation(data)

  defp maybe_resolve_ready_waiters(data, opts \\ []) do
    force? = Keyword.get(opts, :force?, false)

    if force? or not data.backpressure do
      actions =
        data.ready_waiters
        |> :queue.to_list()
        |> Enum.flat_map(&List.wrap(waiter_ok_action(&1)))

      {%{data | ready_waiters: :queue.new()}, actions}
    else
      {data, []}
    end
  end

  # Resolve transform tasks that are parked waiting for readable capacity.
  defp maybe_resolve_enqueue_waiters(data) do
    if :queue.is_empty(data.enqueue_waiters) or readable_capacity(data) <= 0 do
      {data, []}
    else
      actions =
        data.enqueue_waiters
        |> :queue.to_list()
        |> Enum.flat_map(&List.wrap(waiter_ok_action(&1)))

      {%{data | enqueue_waiters: :queue.new()}, actions}
    end
  end

  defp handle_terminate_request(type, reason, state, data) do
    cond do
      type == :cancel and state == :closed ->
        _ = signal_terminate(data, type, reason)
        :keep_state_and_data

      state in [:closed, :errored] ->
        :keep_state_and_data

      true ->
        handle_termination(type, reason, data)
    end
  end

  defp waiter_ok_action({:signal, pid, ref}) do
    priority_send(pid, {:ready, ref})
    []
  end

  defp waiter_ok_action(from), do: {:reply, from, :ok}

  defp waiter_closed_action(from), do: {:reply, from, {:error, :closed}}

  defp waiter_error_action({:signal, pid, ref}, reason) do
    priority_send(pid, {:stream_error, ref, {:errored, reason}})
    []
  end

  defp waiter_error_action(from, reason), do: {:reply, from, {:error, {:errored, reason}}}

  defp slot_desired_size(_data, state) when state in [:closed, :errored], do: nil

  defp slot_desired_size(%{type: :consumer} = data, _state) do
    internal_desired_size(data)
  end

  defp slot_desired_size(data, _state) do
    readable_desired_size(data)
  end

  defp reply_keep_state(data) do
    {:keep_state, data, []}
  end

  defp priority_send(pid, message) do
    :erlang.send(pid, message, [:priority])
  end

  defp queue_chunk_size(%{strategy: strategy}, chunk) do
    strategy_size(strategy, chunk)
  end

  defp strategy_size(%{__struct__: strategy}, chunk), do: strategy.size(chunk)

  defp normalize_strategy(%{__struct__: _} = strategy), do: strategy
  # coveralls-ignore-next-line
  defp normalize_strategy(_), do: %Web.CountQueuingStrategy{}

  defp init_capacities(:producer_consumer, writable_hwm, strategy) do
    {strategy_high_water_mark(strategy, writable_hwm), writable_hwm}
  end

  defp init_capacities(_type, hwm, _strategy), do: {hwm, hwm}

  defp strategy_high_water_mark(%{high_water_mark: hwm}, _fallback) when is_number(hwm), do: hwm
  defp strategy_high_water_mark(_strategy, fallback), do: fallback

  defp timeout_operation(operation) do
    case operation do
      {:write, _from} -> :write
      {:flush, _from} -> :flush
      other -> other
    end
  end

  defp start_task(fun, snapshot) do
    Task.Supervisor.async_nolink(Web.TaskSupervisor, fn ->
      case snapshot do
        %Snapshot{} -> Snapshot.run(snapshot, fun)
        _ -> fun.()
      end
    end)
  end

  # Resolve a callback result that may be a %Web.Promise{}, awaiting it and
  # adopting its state. Falls back to `fallback` if the promise resolves to
  # something unexpected. Non-promise values pass through unchanged.
  # coveralls-ignore-start
  defp resolve_if_promise(%Web.Promise{task: task}, fallback) do
    result = Task.await(task, :infinity)

    case result do
      {:ok, _} -> result
      {:ok, _, _} -> result
      {:error, _} -> result
      _ -> fallback
    end
  catch
    :exit, {:shutdown, reason} -> {:error, reason}
    :exit, {{:shutdown, reason}, _} -> {:error, reason}
    :exit, reason -> {:error, reason}
  end

  # coveralls-ignore-stop

  defp resolve_if_promise(result, _fallback), do: result

  defp set_active_task(data, task, operation, updates \\ []) do
    timeout_ref = Process.send_after(self(), {:task_timeout, task.ref}, data.timeout_ms)

    data =
      data
      |> Map.put(:active_task, task)
      |> Map.put(:task_ref, task.ref)
      |> Map.put(:task_timeout_ref, timeout_ref)
      |> Map.put(:active_operation, operation)

    Enum.reduce(updates, data, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end

  # ---------------------------------------------------------------------------
  # Ambient AbortSignal binding
  # ---------------------------------------------------------------------------

  defp maybe_bind_ambient_signal(%{ambient_signal: signal}), do: bind_ambient_signal(signal)
  defp maybe_bind_ambient_signal(_), do: :ok

  defp bind_ambient_signal(nil), do: :ok

  defp bind_ambient_signal(%AbortSignal{aborted: true, reason: reason}) do
    send(self(), {:ambient_signal_abort, reason})
    :ok
  end

  defp bind_ambient_signal(%AbortSignal{} = signal) do
    stream_pid = self()

    spawn_link(fn -> forward_ambient_signal_abort(signal, stream_pid) end)

    :ok
  end

  defp bind_ambient_signal(_), do: :ok

  defp forward_ambient_signal_abort(signal, stream_pid) do
    case AbortSignal.subscribe(signal) do
      {:ok, subscription} ->
        await_ambient_signal_abort(subscription, stream_pid)

      {:error, :aborted} ->
        send(stream_pid, {:ambient_signal_abort, signal.reason || :aborted})
    end
  end

  defp await_ambient_signal_abort(subscription, stream_pid) do
    with {:error, :aborted, reason} <- AbortSignal.receive_abort(subscription, :infinity, true) do
      send(stream_pid, {:ambient_signal_abort, reason})
    end

    :ok
  end
end
