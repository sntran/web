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
  - `terminate(reason, state)` — **Optional.** Called when the stream is aborted or cancelled.

  ## Stream Types

  The `start/2` callback declares one of three types:

  - `:producer` — readable source (e.g. `ReadableStream`)
  - `:consumer` — writable sink (e.g. `WritableStream`)
  - `:producer_consumer` — transform (e.g. `TransformStream`)
  """

  @behaviour :gen_statem

  # ---------------------------------------------------------------------------
  # Behavior definition
  # ---------------------------------------------------------------------------

  @doc "Initializes the stream and declares its type."
  @callback start(pid :: pid(), opts :: keyword()) ::
              {:producer | :consumer | :producer_consumer, state :: term()}
              | {:producer | :consumer | :producer_consumer, state :: term(), actions :: list()}

  @doc "Called by the engine to pull data from a producer source."
  @callback pull(ctrl :: term(), state :: term()) ::
              {:ok, new_state :: term()} | {:ok, new_state :: term(), :pause}

  @doc "Called by the engine to process an incoming write chunk."
  @callback write(chunk :: term(), ctrl :: term(), state :: term()) ::
              {:ok, new_state :: term()}

  @doc "Called by the engine just before the stream closes (flush/finalize)."
  @callback flush(ctrl :: term(), state :: term()) :: {:ok, new_state :: term()}

  @doc "Called by the engine to notify the module of a stream error."
  @callback error(reason :: term(), state :: term()) :: {:ok, new_state :: term()}

  @doc "Called by the engine when the stream is aborted or cancelled."
  @callback terminate(reason :: term(), state :: term()) :: :ok

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
    # Producer (readable) side
    queue: :queue.new(),
    hwm: 1,
    pulling: false,
    reader_pid: nil,
    reader_ref: nil,
    read_requests: :queue.new(),
    disturbed: false,
    branches: [],
    branch_desired_sizes: %{},
    # Consumer (writable) side
    writer_pid: nil,
    writer_ref: nil,
    pending_write_request: nil,
    pending_close_request: nil,
    queued_write_requests: :queue.new(),
    ready_requests: :queue.new(),
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
    :gen_statem.start_link(__MODULE__, {module, opts}, [])
  end

  # ---------------------------------------------------------------------------
  # :gen_statem callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init({module, opts}) do
    hwm = Keyword.get(opts, :high_water_mark, 1)
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    {type, impl_state, extra_actions} =
      case module.start(self(), opts) do
        {t, s} -> {t, s, []}
        {t, s, a} -> {t, s, a}
      end

    data = %__MODULE__{
      module: module,
      type: type,
      impl_state: impl_state,
      hwm: hwm,
      timeout_ms: timeout_ms
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

    {:ok, initial_state, data, all_actions}
  end

  @impl true
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
              start_task(fn ->
                try do
                  fun.()
                  {:ok, :init_done}
                rescue
                  e -> {:error, e}
                catch
                  kind, r -> {:error, {kind, r}}
                end
              end)

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
            start_task(fn ->
              try do
                fun.()
                {:ok, :start_done}
              rescue
                e -> {:error, e}
              catch
                kind, r -> {:error, {kind, r}}
              end
            end)

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
      case {type, content} do
        {{:call, from}, {:write, pid, _chunk}} ->
          if pid == data.writer_pid do
            {:keep_state_and_data, [{:reply, from, {:error, :closing}}]}
          else
            {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
          end

        {{:call, from}, {:close, pid}} ->
          if pid == data.writer_pid do
            {:keep_state_and_data, [{:reply, from, {:error, :closing}}]}
          else
            {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
          end

        {{:call, from}, {:abort, pid, reason}} ->
          handle_abort(from, pid, reason, data)

        _ ->
          :keep_state_and_data
      end
    end
  end

  # ---------------------------------------------------------------------------
  # State: closed
  # ---------------------------------------------------------------------------

  def closed(type, content, data) do
    with :not_handled <- handle_common(type, content, :closed, data) do
      case {type, content} do
        {:cast, {:enqueue, _chunk}} ->
          :keep_state_and_data

        {:internal, :flush_requests} ->
          flush_read_requests(data)

        {{:call, from}, {:write, pid, _chunk}} ->
          if pid == data.writer_pid do
            {:keep_state_and_data, [{:reply, from, {:error, :closed}}]}
          else
            {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
          end

        {{:call, from}, {:close, pid}} ->
          if pid == data.writer_pid do
            {:keep_state_and_data, [{:reply, from, :ok}]}
          else
            {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
          end

        {{:call, from}, {:abort, pid, _reason}} ->
          if pid == data.writer_pid do
            {:keep_state_and_data, [{:reply, from, :ok}]}
          else
            {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
          end

        # coveralls-ignore-start
        _ ->
          {:keep_state_and_data, [:postpone]}
          # coveralls-ignore-stop
      end
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
         %{reader_pid: nil, branches: []} = data
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
    if pid != data.reader_pid do
      {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_reader}}]}
    else
      data = %{data | disturbed: true}

      case state do
        :errored ->
          {:keep_state, data, [{:reply, from, {:error, {:errored, data.error_reason}}}]}

        _ ->
          if not :queue.is_empty(data.queue) do
            {{:value, chunk}, new_queue} = :queue.out(data.queue)
            new_data = %{data | queue: new_queue}
            actions = [{:reply, from, {:ok, chunk}}]

            {new_data, actions} =
              if data.type == :producer_consumer do
                new_data = refresh_backpressure(new_data)
                {new_data, ready_actions} = maybe_resolve_ready_requests(new_data)
                {new_data, actions ++ ready_actions}
              else
                {new_data, actions}
              end

            actions =
              if :queue.len(new_queue) < data.hwm,
                do: [{:next_event, :internal, :maybe_pull} | actions],
                else: actions

            {:keep_state, new_data, actions}
          else
            if state == :closed do
              {:keep_state, data, [{:reply, from, :done}]}
            else
              new_requests = :queue.in(from, data.read_requests)

              {:keep_state, %{data | read_requests: new_requests},
               [{:next_event, :internal, :maybe_pull}]}
            end
          end
      end
    end
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

      state == :closed or not data.backpressure ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      true ->
        {:keep_state, %{data | ready_requests: :queue.in(from, data.ready_requests)}}
    end
  end

  # Tee
  defp handle_common(
         {:call, from},
         :tee,
         state,
      %{reader_pid: nil, branches: [], disturbed: false} = data
       )
       when data.type == :producer do
    parent_pid = self()

    create_branch = fn ->
      child_source = %{
        pull: fn controller ->
          child_pid = controller.pid
          ds = Web.ReadableStreamDefaultController.desired_size(controller)
          :gen_statem.cast(parent_pid, {:branch_desired_size, child_pid, ds})
        end,
        cancel: fn _reason ->
          :gen_statem.cast(parent_pid, {:branch_cancelled, self()})
        end
      }

      Web.ReadableStream.new(child_source)
    end

    stream_a = create_branch.()
    stream_b = create_branch.()

    new_branches = [stream_a.controller_pid, stream_b.controller_pid]

    for chunk <- :queue.to_list(data.queue) do
      Enum.each(new_branches, &:gen_statem.cast(&1, {:enqueue, chunk}))
    end

    case state do
      :closed -> Enum.each(new_branches, &:gen_statem.cast(&1, :close))
      :errored -> Enum.each(new_branches, &:gen_statem.cast(&1, {:error, data.error_reason}))
      # coveralls-ignore-next-line
      _ -> :ok
    end

    new_data = %{
      data
      | branches: new_branches,
        disturbed: true,
        reader_pid: :teed,
        queue: :queue.new(),
        branch_desired_sizes: %{stream_a.controller_pid => 1, stream_b.controller_pid => 1}
    }

    {:keep_state, new_data, [{:reply, from, {:ok, {stream_a, stream_b}}}]}
  end

  defp handle_common({:call, from}, :tee, _state, data) when data.type == :producer do
    {:keep_state_and_data, [{:reply, from, {:error, :already_locked}}]}
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

  defp handle_common({:call, from}, :get_desired_size, _state, data) do
    {:keep_state_and_data, [{:reply, from, get_effective_desired_size(data)}]}
  end

  defp handle_common({:call, from}, :get_slots, state, data) do
    slots =
      data
      |> Map.from_struct()
      |> Map.put(:state, state)
      |> Map.put(
        :desired_size,
        if(state in [:closed, :errored], do: nil, else: internal_desired_size(data))
      )

    {:keep_state_and_data, [{:reply, from, slots}]}
  end

  defp handle_common({:call, from}, :force_unknown_error, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :unexpected}}]}
  end

  # Error injection (cast)
  defp handle_common(:cast, {:error, reason}, state, data) do
    if state in [:closed, :errored] do
      :keep_state_and_data
    else
      fail_stream(reason, data)
    end
  end

  # Cancel
  defp handle_common(:cast, {:cancel, reason}, _state, data) do
    if data.active_task, do: Task.shutdown(data.active_task, :brutal_kill)
    data = clear_active_operation(data)
    Enum.each(data.branches, &:gen_statem.cast(&1, {:cancel, reason}))
    signal_terminate(data, reason)

    new_data = %{
      data
      | disturbed: true,
        queue: :queue.new(),
        pulling: false,
        active_task: nil,
        task_ref: nil,
        task_timeout_ref: nil,
        branches: []
    }

    {:next_state, :closed, new_data, [{:next_event, :internal, :flush_requests}]}
  end

  # Branch desired size update (for tee)
  defp handle_common(:cast, {:branch_desired_size, pid, size}, _state, data) do
    new_sizes = Map.put(data.branch_desired_sizes, pid, size)

    {:keep_state, %{data | branch_desired_sizes: new_sizes},
     [{:next_event, :internal, :maybe_pull}]}
  end

  # Branch cancelled (for tee)
  defp handle_common(:cast, {:branch_cancelled, pid}, _state, data) do
    new_branches = List.delete(data.branches, pid)
    new_sizes = Map.delete(data.branch_desired_sizes, pid)

    if new_branches == [] and data.branches != [] do
      signal_terminate(data, :all_branches_cancelled)

      {:next_state, :closed,
       %{data | branches: [], branch_desired_sizes: %{}, pulling: false},
       [{:next_event, :internal, :flush_requests}]}
    else
      {:keep_state, %{data | branches: new_branches, branch_desired_sizes: new_sizes}}
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

  defp handle_common(_type, _content, _state, _data), do: :not_handled

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
    Enum.each(data.branches, &:gen_statem.cast(&1, {:enqueue, chunk}))
    new_data = %{data | queue: :queue.in(chunk, data.queue)}

    case :queue.out(new_data.read_requests) do
      {{:value, from}, new_requests} ->
        {{:value, c}, new_queue} = :queue.out(new_data.queue)
        new_data = %{new_data | read_requests: new_requests, queue: new_queue}
        :gen_statem.reply(from, {:ok, c})
        {:keep_state, new_data, [{:next_event, :internal, :maybe_pull}]}

      {:empty, _} ->
        {:keep_state, new_data}
    end
  end

  defp handle_producer_close(data) do
    Enum.each(data.branches, &:gen_statem.cast(&1, :close))

    {:next_state, :closed, %{data | pulling: false},
     [{:next_event, :internal, :flush_requests}]}
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
    effective_ds = get_effective_desired_size(data)

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
        start_task(fn ->
          try do
            module.pull(ctrl, impl_state)
          rescue
            e -> {:error, e}
          catch
            kind, reason -> {:error, {kind, reason}}
          end
        end)

      {:keep_state, set_active_task(data, task, :pull, pulling: true)}
    else
      :keep_state_and_data
    end
  end

  defp get_effective_desired_size(data) do
    if data.branches == [] do
      data.hwm - :queue.len(data.queue)
    else
      Enum.max(Map.values(data.branch_desired_sizes))
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

      data
      |> clear_active_operation()
      |> start_abort_task(reason)
      |> then(&fail_stream(reason, &1, [{:reply, from, :ok}]))
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
      start_task(fn ->
        try do
          module.write(chunk, ctrl, impl_state)
        rescue
          e -> {:error, e}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

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
      start_task(fn ->
        try do
          if function_exported?(module, :flush, 2) do
            module.flush(ctrl, impl_state)
          else
            {:ok, impl_state}
          end
        rescue
          e -> {:error, e}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    {:next_state, :closing,
     set_active_task(data, task, {:flush, data.pending_close_request})}
  end

  defp start_abort_task(data, reason) do
    module = data.module
    impl_state = data.impl_state

    task =
      start_task(fn ->
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
      end)

    set_active_task(data, task, :abort)
  end

  # ---------------------------------------------------------------------------
  # Task result handling
  # ---------------------------------------------------------------------------

  defp handle_task_result({:error, reason}, _state, data) do
    fail_stream(reason, data)
  end

  # Producer pull completed
  defp handle_task_result({:ok, new_impl_state, :pause}, _state, %{active_operation: :pull} = data) do
    new_data =
      data
      |> Map.put(:impl_state, new_impl_state)
      |> clear_active_operation()
      |> Map.put(:pulling, false)

    {:keep_state, new_data}
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

  defp extract_new_state_from_result({:ok, new_state, _}, _old_state) do
    new_state
  end
  # coveralls-ignore-stop
  defp extract_new_state_from_result(_, old_state) do
    old_state
  end

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
        {new_data, ready_actions} = maybe_resolve_ready_requests(data)
        {:keep_state, new_data, actions ++ ready_actions}
    end
  end

  defp close_consumer_stream(data, actions) do
    {new_data, ready_actions} =
      data
      |> Map.put(:backpressure, false)
      |> maybe_resolve_ready_requests(force?: true)

    {:next_state, :closed, new_data,
     actions ++ ready_actions ++ [{:next_event, :internal, :flush_requests}]}
  end

  # ---------------------------------------------------------------------------
  # Stream failure (error state)
  # ---------------------------------------------------------------------------

  defp fail_stream(reason, data, actions \\ []) do
    Enum.each(data.branches, &:gen_statem.cast(&1, {:error, reason}))

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
        ready_error_actions(data, reason)

    new_data =
      data
      |> preserve_abort_task()
      |> clear_writer_lock()
      |> Map.put(:pending_write_request, nil)
      |> Map.put(:queued_write_requests, :queue.new())
      |> Map.put(:pending_close_request, nil)
      |> Map.put(:ready_requests, :queue.new())
      |> Map.put(:backpressure, false)
      |> Map.put(:branches, [])
      |> Map.put(:branch_desired_sizes, %{})
      |> Map.put(:error_reason, reason)

    {:next_state, :errored, new_data,
     actions ++ error_actions ++ [{:next_event, :internal, :flush_requests}]}
  end

  defp clear_writer_lock(%{writer_ref: writer_ref} = data) do
    if writer_ref, do: Process.demonitor(writer_ref, [:flush])
    %{data | writer_pid: nil, writer_ref: nil}
  end

  defp pending_write_error_actions(%{pending_write_request: {from, _pid, _chunk}}, reason) do
    [{:reply, from, {:error, {:errored, reason}}}]
  end

  defp pending_write_error_actions(_data, _reason), do: []

  defp queued_write_error_actions(data, reason) do
    data.queued_write_requests
    |> :queue.to_list()
    |> Enum.map(fn {from, _pid, _chunk} -> {:reply, from, {:error, {:errored, reason}}} end)
  end

  defp close_error_actions(%{pending_close_request: from}, reason) when not is_nil(from) do
    [{:reply, from, {:error, {:errored, reason}}}]
  end

  defp close_error_actions(_data, _reason), do: []

  defp ready_error_actions(data, reason) do
    data.ready_requests
    |> :queue.to_list()
    |> Enum.map(fn from -> {:reply, from, {:error, {:errored, reason}}} end)
  end

  # ---------------------------------------------------------------------------
  # Helper utilities
  # ---------------------------------------------------------------------------

  defp signal_terminate(%{module: module, impl_state: impl_state}, reason) do
    if function_exported?(module, :terminate, 2) do
      module.terminate(reason, impl_state)
    end
  end

  defp refresh_backpressure(data) do
    %{data | backpressure: internal_desired_size(data) <= 0}
  end

  defp internal_desired_size(%{type: :consumer} = data) do
    data.hwm - pending_write_count(data)
  end

  defp internal_desired_size(%{type: :producer_consumer} = data) do
    writable_capacity = data.hwm - pending_write_count(data)
    readable_capacity = readable_capacity(data)
    min(writable_capacity, readable_capacity)
  end

  defp internal_desired_size(data) do
    data.hwm - :queue.len(data.queue)
  end

  defp readable_capacity(data) do
    if map_size(data.branch_desired_sizes) == 0 do
      data.hwm - :queue.len(data.queue)
    else
      Enum.max(Map.values(data.branch_desired_sizes))
    end
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

  defp maybe_resolve_ready_requests(data, opts \\ []) do
    force? = Keyword.get(opts, :force?, false)

    if force? or not data.backpressure do
      actions =
        data.ready_requests
        |> :queue.to_list()
        |> Enum.map(fn from -> {:reply, from, :ok} end)

      {%{data | ready_requests: :queue.new()}, actions}
    else
      {data, []}
    end
  end

  defp reply_keep_state(data) do
    {:keep_state, data, []}
  end

  defp timeout_operation(operation) do
    case operation do
      {:write, _from} -> :write
      {:flush, _from} -> :flush
      other -> other
    end
  end

  defp start_task(fun) do
    Task.Supervisor.async_nolink(Web.TaskSupervisor, fun)
  end

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
end
