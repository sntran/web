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

  @doc "Called by the engine when the stream terminates."
  @callback terminate(event :: term(), state :: term()) :: :ok

  @optional_callbacks [pull: 2, write: 3, flush: 2, terminate: 2]

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

  # The key of the worker of a stream in the dictionary of the stream
  # process: see `start_task/2`.
  @worker_key {__MODULE__, :worker}

  # ---------------------------------------------------------------------------
  # Engine data
  # ---------------------------------------------------------------------------

  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
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
    stream_type: :default,
    auto_allocate_chunk_size: nil,
    pulling: false,
    reader_pid: nil,
    reader_ref: nil,
    reader_mode: nil,
    pending_byob_request: nil,
    # A pull was requested while a pull was in progress.
    pull_again: false,
    # The transformer called `terminate`: the stream closes after the write
    # that is in progress.
    terminated: false,
    # `{:errored, reason}` when the writable side of a closed transform
    # stream is in the errored state: the readable side was cancelled (the
    # reason of the cancel), or the transformer called `terminate`.
    writable_error: nil,
    read_requests: :queue.new(),
    disturbed: false,
    # Consumer (writable) side
    writer_pid: nil,
    writer_ref: nil,
    # A pipe holds the writer lock. Such a lock does not keep the stream.
    writer_is_pipe: false,
    pending_write_request: nil,
    pending_close_request: nil,
    # The caller of an abort, until the abort callback of the sink is complete.
    pending_abort_request: nil,
    # The abort signal of the controller of a writable stream: `nil`, an
    # `AbortController` after the first request for the signal, or
    # `{:aborted, reason}` after an abort with no controller.
    abort_controller: nil,
    # The callers that wait for the end of the stream: {from, pid}.
    closed_waiters: [],
    queued_write_requests: :queue.new(),
    # The number of requests in `queued_write_requests`. The stream needs it
    # for each write, and the length of a queue costs a read of the queue.
    queued_write_count: 0,
    ready_waiters: :queue.new(),
    # Transform-side readable backpressure (transform task parks here until readable has space)
    enqueue_waiters: :queue.new(),
    backpressure: false,
    # Shared
    timeout_ms: 30_000,
    error_reason: nil,
    cancel_on_reader_exit: false,
    # Lifetime
    signal_subscription: nil,
    unread_timeout: nil,
    owner_ref: nil,
    owner_down_reason: nil,
    linger: 5_000,
    lifetime_timer: nil
  ]

  # ---------------------------------------------------------------------------
  # Public start
  # ---------------------------------------------------------------------------

  @doc """
  Starts a stream engine process for the given implementing module.

  The stream has no link to the caller. It monitors its owner, and it stops
  by its lifetime rules. A link would stop the stream immediately when the
  owner stops with an error, also when a different process holds the lock.
  The name of the function stays for compatibility.
  """
  def start_link(module, opts) when is_atom(module) do
    snapshot = Snapshot.take()
    owner = Keyword.get_lazy(opts, :owner, &Web.Promise.owner/0)
    :gen_statem.start(__MODULE__, {module, opts, snapshot, owner}, [])
  end

  @doc false
  # Calls the stream process. Returns `gone` if the process stopped, also
  # when it stopped with a failure during the call.
  def call(pid, message, gone) when is_pid(pid) do
    :gen_statem.call(pid, message, :infinity)
  catch
    :exit, {reason, {:gen_statem, :call, _args}}
    when reason in [:noproc, :normal, :killed, :shutdown] or
           (is_tuple(reason) and elem(reason, 0) == :shutdown) ->
      gone
  end

  @doc false
  # Sends `message` to the stream as a call, and returns a promise for the
  # reply. `mapper` changes the reply into `{:ok, value}` or `{:error, reason}`.
  # `gone` is the reply for a stream that stopped.
  #
  # The process that calls this function sends the message. Thus the stream
  # gets the calls of one process in the sequence of the calls. The Streams
  # Standard specifies this for operations that are not awaited: a `write`
  # before a `close` is written before the close.
  def promise_call(pid, message, gone, mapper) when is_pid(pid) and is_function(mapper, 1) do
    caller = self()
    tag = make_ref()

    promise =
      Web.Promise.detached(fn resolve, reject ->
        monitor = Process.monitor(pid)
        send(caller, {tag, self()})

        reply =
          receive do
            {^tag, reply} -> reply
            {:DOWN, ^monitor, :process, _pid, _reason} -> gone
          end

        Process.demonitor(monitor, [:flush])

        case mapper.(reply) do
          {:ok, value} -> resolve.(value)
          {:error, reason} -> reject.(reason)
        end
      end)

    # The process of the promise is ready for the reply. The stream sends the
    # reply to that process.
    receive do
      {^tag, replier} -> deliver(pid, {:"$gen_call", {replier, tag}, message}, message)
    end

    promise
  end

  @doc false
  # Sends `message` to the stream as a call, and waits for the reply in the
  # process that calls this function. Returns `gone` when the stream
  # stopped, also when it stops during the request.
  #
  # The function makes no promise. The code of this library that reads many
  # chunks uses it: a promise for each chunk is one process for each chunk,
  # and that process keeps the chunk for the linger time of a promise.
  def request(pid, message, gone) when is_pid(pid) do
    monitor = Process.monitor(pid)
    send(pid, {:"$gen_call", {self(), monitor}, message})

    receive do
      {^monitor, reply} ->
        Process.demonitor(monitor, [:flush])
        reply

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        gone
    end
  end

  @doc false
  # Sends a terminal event to the stream process and waits for the result.
  # A stream that stopped needs no terminal event.
  def terminate_and_wait(pid, type, reason) when is_pid(pid) do
    control_call(pid, {:terminate, type, reason})
  catch
    :exit, {exit_reason, {__MODULE__, :control_call, _args}}
    when exit_reason in [:noproc, :normal] ->
      :ok
  end

  # ---------------------------------------------------------------------------
  # The function `start`
  #
  # As in the Streams Standard, the function `start` of a source, a sink, or
  # a transformer runs in the process that makes the stream, before the
  # constructor returns:
  #
  #   * A value that it throws is thrown by the constructor, and the stream
  #     process stops.
  #   * The stream waits for a promise that it returns. Until that promise
  #     fulfils, the stream does not pull, and the writes wait. A rejection
  #     puts the stream in the errored state.
  #
  # The stream process makes a promise, the gate, and has a task that awaits
  # it: see `start_actions/1`. The constructor calls `run_start/3`, which
  # runs `start` and settles the gate with its result. The stream process
  # owns the gate and the promises that `start` makes, as it owns the
  # promises of its other callbacks.
  # ---------------------------------------------------------------------------

  @start_resolver {__MODULE__, :start_resolver}

  @doc false
  # The actions for the callback `start/2` of a stream module. The option
  # `:has_start` tells that the constructor will call `run_start/3`.
  def start_actions(opts) do
    if Keyword.get(opts, :has_start, false) do
      {gate, resolve, _reject} = Web.Promise.with_resolvers()
      Process.put(@start_resolver, resolve)
      [{:next_event, :internal, {:start_task, fn -> Web.Promise.await(gate) end}}]
    else
      []
    end
  end

  @doc false
  def run_start(pid, start_fn, controller) do
    resolve = call(pid, :take_start_resolver, nil)
    # A promise from `start` becomes the result of the gate.
    resolve.(Web.Promise.with_owner(pid, fn -> start_fn.(controller) end))
    :ok
  catch
    kind, value ->
      stacktrace = __STACKTRACE__
      stop(pid)
      :erlang.raise(kind, value, stacktrace)
  end

  @doc false
  # Stops a stream process, with no call to a callback.
  def stop(pid) when is_pid(pid) do
    :gen_statem.stop(pid, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  # ---------------------------------------------------------------------------
  # Priority messages
  #
  # A cancel, an abort, and an error discard the data that the stream has.
  # Thus they do not wait for the messages before them: the stream gets them
  # as priority messages of Erlang/OTP, before the other messages of its
  # mailbox. A stream with a full mailbox stops immediately.
  #
  # Each other message is a usual message. Thus the stream handles a `close`
  # after the chunks that the same process enqueued before it.
  #
  # A priority message needs a priority alias of the stream process. The
  # stream keeps its alias in its process dictionary, where a sender reads
  # it with no message to the stream.
  # ---------------------------------------------------------------------------

  @priority_alias {__MODULE__, :priority_alias}

  defp deliver(pid, envelope, message) do
    if abortive?(message) do
      send_with_priority(pid, envelope)
    else
      send(pid, envelope)
    end

    :ok
  end

  defp abortive?({terminate, type, _reason})
       when terminate in [:terminate, :terminate_unlocked] and type in [:cancel, :abort],
       do: true

  defp abortive?({:abort, _owner, _reason}), do: true
  defp abortive?({:error, _reason}), do: true
  defp abortive?(_message), do: false

  defp send_with_priority(pid, envelope) do
    case :erlang.process_info(pid, {:dictionary, @priority_alias}) do
      {_item, alias} when is_reference(alias) -> :erlang.send(alias, envelope, [:priority])
      # The process stopped, or it is not a stream of this version.
      _other -> send(pid, envelope)
    end
  rescue
    # The process is on a different node.
    ArgumentError -> send(pid, envelope)
  end

  @doc false
  def control_cast(pid, message) when is_pid(pid) do
    deliver(pid, {:"$gen_cast", message}, message)
  end

  @doc false
  # A call that waits in the process that calls it. It exits when the
  # stream stops before the reply.
  def control_call(pid, message) when is_pid(pid) do
    monitor_ref = Process.monitor(pid)
    ref = make_ref()
    deliver(pid, {:"$gen_call", {self(), ref}, message}, message)

    receive do
      {^ref, reply} ->
        Process.demonitor(monitor_ref, [:flush])
        reply

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        exit({reason, {__MODULE__, :control_call, [pid, message]}})
    end
  end

  # ---------------------------------------------------------------------------
  # :gen_statem callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init({module, opts, snapshot, owner}) do
    Process.flag(:message_queue_data, :off_heap)
    Process.put(@priority_alias, :erlang.alias([:priority]))
    # The callbacks of this stream run in tasks. The promises and streams that
    # they make belong to this stream.
    Web.Promise.put_owner(self())
    hwm = Keyword.get(opts, :high_water_mark, 1)
    strategy = normalize_strategy(Keyword.get(opts, :strategy, %Web.CountQueuingStrategy{}))
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    started =
      case module.start(self(), opts) do
        {type, state} -> {type, state, []}
        {type, state, actions} -> {type, state, actions}
      end

    init_data(started, module, opts, snapshot, owner, hwm, strategy, timeout_ms)
  end

  defp init_data(
         {type, impl_state, extra_actions},
         module,
         opts,
         snapshot,
         owner,
         hwm,
         strategy,
         timeout_ms
       ) do
    {readable_hwm, writable_hwm} = init_capacities(type, hwm, strategy)

    data = %__MODULE__{
      module: module,
      type: type,
      impl_state: impl_state,
      cancel_on_reader_exit: Keyword.get(opts, :cancel_on_reader_exit, false),
      hwm: hwm,
      readable_hwm: readable_hwm,
      writable_hwm: writable_hwm,
      total_queued_size: 0,
      strategy: strategy,
      stream_type: Keyword.get(opts, :stream_type, :default),
      auto_allocate_chunk_size: Keyword.get(opts, :auto_allocate_chunk_size),
      timeout_ms: timeout_ms,
      async_context: snapshot,
      owner_ref: Process.monitor(owner),
      linger: Keyword.get_lazy(opts, :linger, &Web.Promise.default_linger/0),
      unread_timeout: Keyword.get(opts, :unread_timeout)
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

    all_actions = extra_actions ++ default_actions ++ unread_timeout_actions(data)

    data =
      if type in [:consumer, :producer_consumer] do
        refresh_backpressure(data)
      else
        data
      end

    # If the snapshot has an ambient AbortSignal, the stream goes to the
    # errored state when the signal aborts.
    data = %{data | signal_subscription: bind_ambient_signal(snapshot)}

    {:ok, initial_state, data, all_actions}
  end

  @impl true
  @doc "Terminates a stream engine process with a unified terminal event."
  def terminate(pid, type, reason \\ nil)

  def terminate(pid, type, reason) when is_pid(pid) do
    control_cast(pid, {:terminate, type, reason})
  end

  def terminate(_reason, _state, data) do
    if data.active_task, do: kill_task(data.active_task)

    case Process.get(@worker_key) do
      pid when is_pid(pid) -> stop_worker(pid)
      nil -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # State: readable  (producers only)
  # ---------------------------------------------------------------------------

  def readable(type, content, data) do
    type |> do_readable(content, data) |> with_lifetime(:readable, data)
  end

  defp do_readable(type, content, data) do
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
                  catch
                    _kind, r -> {:error, r}
                  end
                end,
                data.async_context
              )

            {:keep_state, set_active_task(data, task, :init, pulling: true)}

          {:internal, :maybe_pull} ->
            handle_maybe_pull(data)

          # The stream ignores a message that it does not know.
          _ ->
            :keep_state_and_data
        end

      result ->
        result
    end
  end

  # ---------------------------------------------------------------------------
  # State: writable  (consumers AND producer_consumers)
  # ---------------------------------------------------------------------------

  def writable(type, content, data) do
    type
    |> do_writable(content, data)
    |> start_held_write(:writable, data)
    |> with_lifetime(:writable, data)
  end

  defp do_writable(type, content, data) do
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
                catch
                  _kind, r -> {:error, r}
                end
              end,
              data.async_context
            )

          {:keep_state, set_active_task(data, task, :start)}

        _ ->
          :keep_state_and_data
      end
    end
  end

  # ---------------------------------------------------------------------------
  # State: closing  (consumers draining writes before flush)
  # ---------------------------------------------------------------------------

  def closing(type, content, data) do
    type
    |> do_closing(content, data)
    |> start_held_write(:closing, data)
    |> with_lifetime(:closing, data)
  end

  defp do_closing(type, content, data) do
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
    type |> do_closed(content, data) |> with_lifetime(:closed, data)
  end

  defp do_closed(type, content, data) do
    with :not_handled <- handle_common(type, content, :closed, data) do
      handle_closed_event(type, content, data)
    end
  end

  # ---------------------------------------------------------------------------
  # State: errored
  # ---------------------------------------------------------------------------

  def errored(type, content, data) do
    type |> do_errored(content, data) |> with_lifetime(:errored, data)
  end

  defp do_errored(type, content, data) do
    with :not_handled <- handle_common(type, content, :errored, data) do
      case {type, content} do
        {:internal, :flush_requests} ->
          flush_errored_requests(data)

        # A write to an errored stream rejects with the error of the stream.
        # An error releases the lock, thus the lock is not examined.
        {{:call, from}, {:write, _pid, _chunk}} ->
          {:keep_state_and_data, [{:reply, from, {:error, {:errored, data.error_reason}}}]}

        {{:call, from}, {:close, _pid}} ->
          {:keep_state_and_data, [{:reply, from, {:error, :errored}}]}

        # An abort of an errored stream has no effect, unless its abort
        # callback is not complete: then this caller waits for it also.
        {{:call, from}, {:abort, _pid, _reason}} ->
          {:keep_state_and_data, [{:reply, from, :ok}]}

        _ ->
          :keep_state_and_data
      end
    end
  end

  # ---------------------------------------------------------------------------
  # handle_common — operations valid in all states
  # ---------------------------------------------------------------------------

  # Reader lock acquisition
  defp handle_common({:call, from}, {:get_reader, pid}, state, data)
       when data.type in [:producer, :producer_consumer] do
    handle_common({:call, from}, {:get_reader, pid, :default}, state, data)
  end

  defp handle_common(
         {:call, from},
         {:get_reader, pid, mode},
         _state,
         %{reader_pid: nil} = data
       )
       when data.type in [:producer, :producer_consumer] do
    case mode do
      :byob when data.stream_type != :bytes ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_byte_stream}}]}

      reader_mode when reader_mode in [:default, :byob] ->
        ref = Process.monitor(pid)

        {:keep_state, %{data | reader_pid: pid, reader_ref: ref, reader_mode: reader_mode},
         [
           {:reply, from, {:ok, ref}}
         ]}
    end
  end

  defp handle_common({:call, from}, {:get_reader, _pid, _mode}, _state, data)
       when data.type in [:producer, :producer_consumer] do
    {:keep_state_and_data, [{:reply, from, {:error, :already_locked}}]}
  end

  # Read a chunk
  defp handle_common({:call, from}, {:read, pid}, state, data)
       when data.type in [:producer, :producer_consumer] do
    handle_read_request(from, pid, state, data)
  end

  defp handle_common({:call, from}, {:read_batch, pid, max}, state, data)
       when data.type in [:producer, :producer_consumer] do
    handle_read_batch(from, pid, max, state, data)
  end

  defp handle_common({:call, from}, {:byob_read, pid, %Web.Uint8Array{} = view}, state, data)
       when data.type in [:producer, :producer_consumer] do
    handle_byob_read_request(from, pid, view, state, data)
  end

  defp handle_common({:call, from}, {:byob_read, _pid, _view}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :invalid_byob_view}}]}
  end

  # The release of the lock of one side. The two sides of a transform stream
  # have separate locks, thus the caller names the side. A release by a
  # process that does not hold the lock has no effect, as in the Streams
  # Standard.
  defp handle_common({:call, from}, {:release_lock, :reader, pid}, _state, data) do
    if pid == data.reader_pid do
      if(data.reader_ref, do: Process.demonitor(data.reader_ref, [:flush]))

      # The read requests of the reader reject, as the Streams Standard
      # specifies.
      {data, pending_byob_actions} =
        settle_pending_byob_request(data, {:error, :not_locked_by_reader})

      read_actions =
        data.read_requests
        |> :queue.to_list()
        |> Enum.map(&{:reply, &1, {:error, :not_locked_by_reader}})

      {data, closed_actions} = release_closed_waiters(data, :reader, pid)

      new_data = %{
        data
        | reader_pid: nil,
          reader_ref: nil,
          reader_mode: nil,
          read_requests: :queue.new()
      }

      {:keep_state, new_data,
       [{:reply, from, :ok}] ++ read_actions ++ pending_byob_actions ++ closed_actions}
    else
      {:keep_state_and_data, [{:reply, from, :ok}]}
    end
  end

  defp handle_common({:call, from}, {:release_lock, :writer, pid}, _state, data) do
    if pid == data.writer_pid do
      if data.writer_ref, do: Process.demonitor(data.writer_ref, [:flush])
      {data, closed_actions} = release_closed_waiters(data, :writer, pid)

      {:keep_state, %{data | writer_pid: nil, writer_ref: nil},
       [{:reply, from, :ok} | closed_actions]}
    else
      {:keep_state_and_data, [{:reply, from, :ok}]}
    end
  end

  # The promise `closed` of a reader or a writer. The caller waits until the
  # stream is closed or errored.
  defp handle_common({:call, from}, {:wait_closed, side, pid}, state, data) do
    cond do
      state == :closed ->
        {:keep_state_and_data, [{:reply, from, closed_reply(data, side)}]}

      state == :errored ->
        {:keep_state_and_data, [{:reply, from, {:error, {:errored, data.error_reason}}}]}

      lock_holder(data, side) != pid ->
        {:keep_state_and_data, [{:reply, from, {:error, :lock_released}}]}

      true ->
        {:keep_state, %{data | closed_waiters: [{from, side, pid} | data.closed_waiters]}}
    end
  end

  # A terminal event from the stream object, not from a reader or a writer.
  # The Streams Standard refuses it when the stream is locked.
  defp handle_common({:call, from}, {:terminate_unlocked, type, reason}, state, data)
       when type in [:cancel, :close, :abort] do
    side = if type == :cancel, do: :reader, else: :writer

    cond do
      is_pid(lock_holder(data, side)) ->
        {:keep_state_and_data, [{:reply, from, {:error, :locked}}]}

      # A close of a writable stream is the close of a writer: the writes
      # that wait complete, and then the close callback of the sink runs.
      # The stream has no writer, thus the writer of this request is `nil`.
      type == :close and data.type in [:consumer, :producer_consumer] ->
        {:keep_state_and_data, [{:next_event, {:call, from}, {:close, nil}}]}

      true ->
        handle_common({:call, from}, {:terminate, type, reason}, state, data)
    end
  end

  # Writer lock acquisition
  defp handle_common(
         {:call, from},
         {:get_writer, pid, kind},
         _state,
         %{writer_pid: nil} = data
       )
       when data.type in [:consumer, :producer_consumer] do
    ref = Process.monitor(pid)

    {:keep_state, %{data | writer_pid: pid, writer_ref: ref, writer_is_pipe: kind == :pipe},
     [{:reply, from, :ok}]}
  end

  defp handle_common({:call, from}, {:get_writer, _pid, _kind}, _state, data)
       when data.type in [:consumer, :producer_consumer] do
    {:keep_state_and_data, [{:reply, from, {:error, :already_locked}}]}
  end

  # Ready (backpressure signal for writers)
  defp handle_common({:call, from}, {:ready, pid}, state, data)
       when data.type in [:consumer, :producer_consumer] do
    cond do
      state == :errored ->
        {:keep_state_and_data, [{:reply, from, {:error, {:errored, data.error_reason}}}]}

      # The writable side of a transform stream is in the errored state. An
      # error releases the lock, thus this check comes before the lock check.
      state == :closed and is_tuple(data.writable_error) ->
        {:keep_state_and_data, [{:reply, from, closed_reply(data, :writer)}]}

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

  # `enqueue` and `close` of a controller. The Streams Standard specifies
  # that they throw a `TypeError` when the readable side cannot accept the
  # request: it is closed, a close was requested, or it is errored. Thus
  # they are calls, and the caller gets the refusal.
  defp handle_common({:call, from}, {:enqueue, chunk}, state, data) do
    case controller_refusal(state, data) do
      nil ->
        {:keep_state, new_data, actions} = handle_producer_enqueue(chunk, state, data)
        {:keep_state, new_data, [{:reply, from, :ok} | actions]}

      refusal ->
        {:keep_state_and_data, [{:reply, from, {:error, refusal}}]}
    end
  end

  defp handle_common({:call, from}, :close, state, data) do
    case controller_refusal(state, data) do
      nil ->
        result =
          if data.type == :producer,
            do: handle_producer_close(data),
            else: handle_common(:cast, :terminate_transform, state, data)

        {next_state, new_data, actions} = transition(result, state, data)
        {:next_state, next_state, new_data, [{:reply, from, :ok} | actions]}

      refusal ->
        {:keep_state_and_data, [{:reply, from, {:error, refusal}}]}
    end
  end

  # The constructor takes the function that settles the gate of `start`.
  defp handle_common({:call, from}, :take_start_resolver, _state, _data) do
    {:keep_state_and_data, [{:reply, from, Process.delete(@start_resolver)}]}
  end

  # Query helpers
  defp handle_common({:call, from}, :disturbed?, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.disturbed}]}
  end

  # The signal of the controller of a writable stream, as the attribute
  # `signal` of the Streams Standard. The stream makes it for the first
  # request, thus a stream that does not use it has no process for it.
  defp handle_common({:call, from}, :abort_signal, _state, data) do
    case data.abort_controller do
      nil ->
        controller = Web.AbortController.new()
        {:keep_state, %{data | abort_controller: controller}, [{:reply, from, controller.signal}]}

      {:aborted, reason} ->
        {:keep_state_and_data, [{:reply, from, Web.AbortSignal.abort(reason)}]}

      controller ->
        {:keep_state_and_data, [{:reply, from, controller.signal}]}
    end
  end

  # The two sides of a transform stream have separate locks.
  defp handle_common({:call, from}, {:locked?, :reader}, _state, data) do
    {:keep_state_and_data, [{:reply, from, is_pid(data.reader_pid)}]}
  end

  defp handle_common({:call, from}, {:locked?, :writer}, _state, data) do
    {:keep_state_and_data, [{:reply, from, is_pid(data.writer_pid)}]}
  end

  defp handle_common({:call, from}, :backpressure?, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.backpressure}]}
  end

  # The desired size of the Streams Standard: `nil` for an errored stream,
  # and 0 for a closed stream.
  defp handle_common({:call, from}, :desired_size, state, data) do
    desired =
      case state do
        :errored -> nil
        :closed when is_tuple(data.writable_error) -> nil
        :closed -> 0
        _ -> internal_desired_size(data)
      end

    {:keep_state_and_data, [{:reply, from, desired}]}
  end

  defp handle_common({:call, from}, :get_desired_size, state, data) do
    desired =
      case state do
        :errored -> nil
        :closed -> 0
        _ -> readable_desired_size(data)
      end

    {:keep_state_and_data, [{:reply, from, desired}]}
  end

  defp handle_common({:call, from}, :get_byob_request, _state, data)
       when data.type in [:producer, :producer_consumer] do
    {:keep_state_and_data, [{:reply, from, byob_request_for(data.pending_byob_request)}]}
  end

  defp handle_common({:call, from}, {:byob_respond, _bytes_written}, _state, data)
       when data.type in [:producer, :producer_consumer] do
    {:keep_state_and_data, [{:reply, from, {:error, :byob_capability_required}}]}
  end

  defp handle_common({:call, from}, {:byob_respond_with_new_view, _view}, _state, data)
       when data.type in [:producer, :producer_consumer] do
    {:keep_state_and_data, [{:reply, from, {:error, :byob_capability_required}}]}
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

  # A cancel or an abort from a caller that waits for the result. The stream
  # goes to its terminal state immediately. The callback of the source or
  # sink runs in a task, and the caller gets its reply when the callback is
  # complete: `:ok`, or the value that the callback threw. A promise from
  # the callback is awaited. This is the rule of the Streams Standard.
  defp handle_common({:call, from}, {:terminate, type, reason}, state, data)
       when type in [:cancel, :abort] and state not in [:closed, :errored] do
    terminate_with_task(type, reason, from, data)
  end

  # The same, for a caller that does not wait for the callback: the halt of
  # an enumeration.
  defp handle_common({:call, from}, {:terminate_detached, :cancel, reason}, state, data) do
    if state in [:closed, :errored] do
      {:keep_state_and_data, [{:reply, from, :ok}]}
    else
      {:next_state, next_state, new_data, actions} =
        terminate_with_task(:cancel, reason, nil, data)

      {:next_state, next_state, new_data, [{:reply, from, :ok} | actions]}
    end
  end

  defp handle_common({:call, from}, {:terminate, type, reason}, state, data)
       when type in [:cancel, :close, :abort, :error] do
    {result, transition} = terminate_request_with_result(type, reason, state, data)

    case transition do
      :keep_state_and_data ->
        {:keep_state_and_data, [{:reply, from, result}]}

      {:next_state, next_state, new_data, actions} ->
        {:next_state, next_state, new_data, [{:reply, from, result} | actions]}
    end
  end

  defp handle_common(:cast, :terminate_transform, state, %{type: :producer_consumer} = data)
       when state in [:writable, :closing] do
    if active_consumer_operation?(data) do
      {:keep_state, %{data | terminated: true}}
    else
      terminate_transform(%{data | terminated: true}, [])
    end
  end

  defp handle_common(:cast, :terminate_transform, _state, _data), do: :keep_state_and_data

  defp handle_common(:cast, {:error, reason}, state, data) do
    if final?(state, data) do
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
      # A pipe to a destination that is errored gets the error of the
      # destination, as the Streams Standard specifies.
      state == :errored ->
        send(waiter_pid, {:stream_error, ref, {:errored, data.error_reason}})
        :keep_state_and_data

      state == :closed and match?({:errored, _reason}, data.writable_error) ->
        {:errored, reason} = data.writable_error
        send(waiter_pid, {:stream_error, ref, {:errored, reason}})
        :keep_state_and_data

      owner_pid != data.writer_pid ->
        send(waiter_pid, {:stream_error, ref, :not_locked_by_writer})
        :keep_state_and_data

      state == :closed ->
        send(waiter_pid, {:ready, ref})
        :keep_state_and_data

      writable_ready?(data) ->
        send(waiter_pid, {:ready, ref})
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
         %{type: type} = data
       ) do
    if type in [:producer, :producer_consumer] do
      cond do
        state in [:closed, :errored] ->
          send(waiter_pid, {:ready, ref})
          :keep_state_and_data

        # The queue is below its limit, or a read waits.
        readable_wants_chunk?(data) ->
          send(waiter_pid, {:ready, ref})
          :keep_state_and_data

        true ->
          waiter = {:signal, waiter_pid, ref}
          {:keep_state, %{data | enqueue_waiters: :queue.in(waiter, data.enqueue_waiters)}}
      end
    else
      :keep_state_and_data
    end
  end

  defp handle_common(
         :info,
         {:web_stream_byob_response, address, {:chunk, chunk}},
         _state,
         %{pending_byob_request: %{address: address}} = data
       )
       when is_binary(chunk) do
    fulfill_pending_byob_enqueue(chunk, data)
  end

  defp handle_common(
         :info,
         {:web_stream_byob_response, address, {:view, view}},
         _state,
         %{pending_byob_request: %{address: address}} = data
       ) do
    fulfill_pending_byob_view(view, data)
  end

  defp handle_common(
         :info,
         {:web_stream_byob_response, address, _payload},
         _state,
         %{pending_byob_request: %{address: address}} = data
       ) do
    fail_invalid_byob_response(data)
  end

  defp handle_common(:info, {:web_stream_byob_response, _address, _payload}, _state, _data) do
    :keep_state_and_data
  end

  # The result of a callback: `{ref, result}` from the worker.
  defp handle_common(:info, {ref, result}, state, data) when is_reference(ref) do
    # The worker stays: remove the monitor of this callback.
    Process.demonitor(ref, [:flush])

    cond do
      ref != data.task_ref ->
        :keep_state_and_data

      data.active_operation == :abort ->
        handle_abort_task_result(result, data)

      # A callback that continued after it closed the stream. Its result,
      # also a failure, has no effect on a closed or errored stream, as in
      # the Streams Standard.
      state in [:closed, :errored] ->
        {:keep_state, data |> clear_active_operation() |> Map.put(:pulling, false)}

      true ->
        handle_task_result(result, state, data)
    end
  end

  # Task timeout handling
  defp handle_common(:info, {:task_timeout, ref}, _state, data) do
    if ref == data.task_ref and data.active_task do
      operation = timeout_operation(data.active_operation)
      kill_task(data.active_task)
      error = task_timeout_error(operation, data)

      # The caller of an abort gets the timeout as its rejection reason.
      abort_actions = abort_reply_actions(data, {:error, error})
      data = clear_active_operation(%{data | pending_abort_request: nil})
      fail_stream(error, data, abort_actions)
    else
      :keep_state_and_data
    end
  end

  # The process of the ambient AbortSignal stopped with no abort. A signal
  # that aborts sends its reason before it stops: see the clause for
  # `{:abort, ref, reason}`.
  defp handle_common(
         :info,
         {:DOWN, monitor_ref, :process, _pid, _reason},
         state,
         %{signal_subscription: %{monitor_ref: monitor_ref}} = data
       ) do
    handle_ambient_abort(AbortSignal.default_reason(), state, data)
  end

  defp handle_common(
         :info,
         {:DOWN, ref, :process, _pid, reason},
         _state,
         %{owner_ref: ref} = data
       )
       when is_reference(ref) do
    {:keep_state, %{data | owner_ref: nil, owner_down_reason: {:owner_down, reason}}}
  end

  defp handle_common(:info, {:DOWN, ref, :process, _pid, reason}, state, data) do
    cond do
      ref == data.reader_ref ->
        maybe_cancel_on_reader_exit(reason, state, data)

      ref == data.writer_ref ->
        {:keep_state, %{data | writer_pid: nil, writer_ref: nil}}

      # The process of the abort callback stopped with no result.
      ref == data.task_ref and data.active_operation == :abort ->
        {:keep_state, clear_active_operation(data), abort_reply_actions(data, :ok)}
        |> clear_abort_request()

      ref == data.task_ref and reason == :normal ->
        :keep_state_and_data

      ref == data.task_ref ->
        fail_stream(reason, data)

      true ->
        :keep_state_and_data
    end
  end

  # The ambient AbortSignal aborted. The stream goes to the errored state,
  # thus a reader gets the abort reason and not a body that looks complete.
  defp handle_common(
         :info,
         {:abort, ref, reason},
         state,
         %{signal_subscription: %{ref: ref}} = data
       ) do
    handle_ambient_abort(reason, state, data)
  end

  defp handle_common(:info, {:ambient_signal_abort, reason}, state, data) do
    handle_ambient_abort(reason, state, data)
  end

  # The option `:unread_timeout`: the stream holds a resource, for example a
  # network connection, and no process started to read it in the given time.
  # A stream that has work goes to the errored state, thus its source
  # releases the resource. A closed stream discards its chunks. Then the
  # lifetime rules stop the stream.
  defp handle_common({:timeout, :unread}, :expired, state, data) do
    cond do
      data.disturbed or locked?(data) or state == :errored ->
        :keep_state_and_data

      state == :closed ->
        {:keep_state, %{data | queue: :queue.new(), total_queued_size: 0, disturbed: true}}

      true ->
        handle_termination(:abort, unread_error(data), data)
    end
  end

  # The lifetime timer: see `with_lifetime/3`.
  defp handle_common({:timeout, :lifetime}, :expired, state, data) do
    data = %{data | lifetime_timer: nil}

    if state in [:closed, :errored] do
      {:stop, :normal, data}
    else
      # No process can read the chunks in the queue. Discard them, thus the
      # stream stops immediately after the terminal event.
      data = %{data | queue: :queue.new(), total_queued_size: 0}
      handle_termination(owner_down_type(data), data.owner_down_reason, data)
    end
  end

  defp handle_common(_type, _content, _state, _data), do: :not_handled

  # Why the readable side cannot accept an `enqueue` or a `close`, or `nil`.
  defp controller_refusal(_state, %{type: :consumer}), do: :closed
  defp controller_refusal(:errored, _data), do: :errored
  defp controller_refusal(:closed, _data), do: :closed
  defp controller_refusal(_state, %{terminated: true}), do: :closed
  defp controller_refusal(_state, _data), do: nil

  defp task_timeout_error(operation, data) do
    Web.TypeError.exception(
      message: "The #{operation} callback did not return in #{data.timeout_ms} ms.",
      cause: {:task_timeout, operation}
    )
  end

  defp handle_ambient_abort(reason, state, data) do
    data = %{data | signal_subscription: nil}

    cond do
      final?(state, data) -> {:keep_state, data}
      # The source is complete: an abort only discards the chunks.
      state == :closed -> fail_stream(reason, data)
      true -> handle_termination(:abort, reason, data)
    end
  end

  # A stream that closed with chunks in its queue is still readable in the
  # Streams Standard: its state is "readable", with a close request, until a
  # read takes the last chunk. Until then an error puts it in the errored
  # state and discards the chunks. Thus the abort of a fetch errors a
  # complete body that no process read.
  defp final?(:errored, _data), do: true
  defp final?(:closed, data), do: :queue.is_empty(data.queue)
  defp final?(_state, _data), do: false

  defp handle_closed_event(:cast, {:enqueue, _chunk}, _data), do: :keep_state_and_data
  defp handle_closed_event(:internal, :flush_requests, data), do: flush_read_requests(data)

  # The readable side of a transform stream was cancelled, or the
  # transformer called `terminate`. The writable side is in the errored
  # state, as in the Streams Standard: see the field `writable_error`.
  defp handle_closed_event({:call, from}, {:write, _pid, _chunk}, %{
         writable_error: {:errored, reason}
       }) do
    {:keep_state_and_data, [{:reply, from, {:error, {:errored, reason}}}]}
  end

  defp handle_closed_event({:call, from}, {:close, _pid}, %{writable_error: {:errored, _reason}}) do
    {:keep_state_and_data, [{:reply, from, {:error, :errored}}]}
  end

  defp handle_closed_event({:call, from}, {:write, pid, _chunk}, data) do
    reply_to_writer(from, pid, data.writer_pid, {:error, :closed})
  end

  defp handle_closed_event({:call, from}, {:close, pid}, data) do
    reply_to_writer(from, pid, data.writer_pid, {:error, :closed})
  end

  defp handle_closed_event({:call, from}, {:abort, pid, _reason}, data) do
    reply_to_writer(from, pid, data.writer_pid, :ok)
  end

  defp handle_closed_event(_type, _content, _data), do: :keep_state_and_data

  defp reply_to_writer(from, pid, writer_pid, success_reply) when pid == writer_pid do
    {:keep_state_and_data, [{:reply, from, success_reply}]}
  end

  defp reply_to_writer(from, _pid, _writer_pid, _success_reply) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
  end

  # A read from an errored stream gives the error. The error releases the
  # lock, thus this clause must come before the lock checks.
  defp handle_read_request(from, _pid, :errored, data) do
    disturbed_data = %{data | disturbed: true}
    {:keep_state, disturbed_data, [{:reply, from, {:error, {:errored, data.error_reason}}}]}
  end

  defp handle_read_request(from, pid, _state, data) when pid != data.reader_pid do
    {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_reader}}]}
  end

  defp handle_read_request(from, pid, _state, %{reader_mode: :byob} = data)
       when pid == data.reader_pid do
    {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_reader}}]}
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
    data = %{data | read_requests: :queue.in(from, data.read_requests)}
    # A read that waits is a request for a chunk: a transform that waits for
    # capacity continues.
    {data, waiter_actions} = maybe_resolve_enqueue_waiters(data)

    {:keep_state, data, [{:next_event, :internal, :maybe_pull} | waiter_actions]}
  end

  # A batch read of an internal reader, such as the enumeration of a stream.
  # The reader gets the chunks that are in the queue at this time, up to
  # `max`, in one answer `{:chunks, list}`. That is the result of one
  # `read()` for each chunk, one after the other. With no chunk in the
  # queue, it is one read that waits, as a usual read.
  #
  # The batch changes neither the desired size of the stream nor the
  # pulls: the stream pulls only as the Streams Standard specifies. Thus a
  # batch has more than one chunk only when the source enqueues more than
  # one chunk for one pull, or when the high water mark is above 1.
  defp handle_read_batch(from, pid, max, state, data)
       when pid == data.reader_pid and data.reader_mode != :byob and state != :errored do
    data = %{data | disturbed: true}

    if :queue.is_empty(data.queue) do
      queue_or_complete_read(from, state, data)
    else
      pop_queued_chunks(from, max, data)
    end
  end

  defp handle_read_batch(from, pid, _max, state, data) do
    handle_read_request(from, pid, state, data)
  end

  defp pop_queued_chunks(from, max, data) do
    {chunks, queue, size} = take_chunks(data.queue, max, data, [], 0)

    new_data = %{data | queue: queue, total_queued_size: data.total_queued_size - size}
    actions = [{:reply, from, {:chunks, chunks}}]
    {new_data, actions} = maybe_refresh_read_actions(new_data, actions)
    {:keep_state, new_data, maybe_request_pull(new_data, actions)}
  end

  defp take_chunks(queue, 0, _data, chunks, size), do: {Enum.reverse(chunks), queue, size}

  defp take_chunks(queue, count, data, chunks, size) do
    case :queue.out(queue) do
      {{:value, chunk}, rest} ->
        take_chunks(
          rest,
          count - 1,
          data,
          [default_read_chunk(data, chunk) | chunks],
          size + queue_chunk_size(data, chunk)
        )

      {:empty, queue} ->
        {Enum.reverse(chunks), queue, size}
    end
  end

  defp pop_queued_chunk(from, data) do
    {{:value, chunk}, new_queue} = :queue.out(data.queue)

    new_data = %{
      data
      | queue: new_queue,
        total_queued_size: data.total_queued_size - queue_chunk_size(data, chunk)
    }

    actions = [{:reply, from, {:ok, default_read_chunk(data, chunk)}}]
    {new_data, actions} = maybe_refresh_read_actions(new_data, actions)
    {:keep_state, new_data, maybe_request_pull(new_data, actions)}
  end

  # A default read of a byte stream gives a `Web.Uint8Array`, as the Streams
  # Standard specifies. The queue of a byte stream holds binaries, thus a
  # BYOB read can take a part of a chunk.
  defp default_read_chunk(%{stream_type: :bytes}, chunk) when is_binary(chunk) do
    Web.Uint8Array.from(chunk)
  end

  defp default_read_chunk(_data, chunk), do: chunk

  defp handle_byob_read_request(from, _pid, _view, :errored, data) do
    disturbed_data = %{data | disturbed: true}
    {:keep_state, disturbed_data, [{:reply, from, {:error, {:errored, data.error_reason}}}]}
  end

  defp handle_byob_read_request(from, pid, _view, _state, data)
       when pid != data.reader_pid or data.reader_mode != :byob do
    {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_reader}}]}
  end

  defp handle_byob_read_request(from, _pid, _view, _state, %{stream_type: stream_type})
       when stream_type != :bytes do
    {:keep_state_and_data, [{:reply, from, {:error, :not_byte_stream}}]}
  end

  defp handle_byob_read_request(from, _pid, %Web.Uint8Array{} = view, state, data) do
    case take_byob_view(view) do
      {:ok, view} -> accept_byob_read(from, view, state, %{data | disturbed: true})
      {:error, error} -> {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  # A BYOB read moves the buffer of the reader into the stream, as the
  # Streams Standard specifies. The buffer of the reader becomes detached,
  # and the result of the read has a new buffer with the same bytes and the
  # bytes of the chunk. Thus no process can change the buffer during the read.
  defp take_byob_view(%Web.Uint8Array{byte_length: 0}) do
    {:error, Web.TypeError.exception("A BYOB read needs a view with a byte length above zero.")}
  end

  defp take_byob_view(%Web.Uint8Array{} = view) do
    {:ok, Web.Uint8Array.transfer(view)}
  rescue
    Web.TypeError ->
      {:error,
       Web.TypeError.exception("A BYOB read needs a view of a buffer that is not detached.")}
  end

  defp accept_byob_read(from, view, state, data) do
    cond do
      not :queue.is_empty(data.queue) ->
        pop_queued_bytes(from, view, data)

      state == :closed ->
        {:keep_state, data, [{:reply, from, {:done, Web.Uint8Array.empty(view)}}]}

      true ->
        pending_byob_request = new_pending_byob_request(from, view)

        {:keep_state, %{data | pending_byob_request: pending_byob_request},
         [{:next_event, :internal, :maybe_pull}]}
    end
  end

  defp pop_queued_bytes(from, %Web.Uint8Array{} = view, data) do
    {chunk, new_queue, new_total_queued_size} =
      take_bytes_from_queue(data.queue, data.total_queued_size, data.strategy, view.byte_length)

    chunk_view = Web.Uint8Array.fill(view, chunk)

    new_data = %{
      data
      | queue: new_queue,
        total_queued_size: new_total_queued_size
    }

    actions = [{:reply, from, {:ok, chunk_view}}]
    {new_data, actions} = maybe_refresh_read_actions(new_data, actions)
    {:keep_state, new_data, maybe_request_pull(new_data, actions)}
  end

  defp take_bytes_from_queue(queue, total_queued_size, strategy, byte_length) do
    {iodata, remaining_chunks, remaining_total_queued_size} =
      do_take_bytes_from_queue(
        :queue.to_list(queue),
        total_queued_size,
        strategy,
        byte_length,
        []
      )

    {IO.iodata_to_binary(Enum.reverse(iodata)), :queue.from_list(remaining_chunks),
     remaining_total_queued_size}
  end

  defp do_take_bytes_from_queue(chunks, total_queued_size, _strategy, byte_length, acc)
       when byte_length <= 0 do
    {acc, chunks, total_queued_size}
  end

  defp do_take_bytes_from_queue([], total_queued_size, _strategy, _byte_length, acc) do
    {acc, [], total_queued_size}
  end

  defp do_take_bytes_from_queue([chunk | rest], total_queued_size, strategy, byte_length, acc)
       when is_binary(chunk) do
    chunk_size = strategy_size(strategy, chunk)

    if byte_size(chunk) <= byte_length do
      do_take_bytes_from_queue(
        rest,
        total_queued_size - chunk_size,
        strategy,
        byte_length - byte_size(chunk),
        [chunk | acc]
      )
    else
      head = binary_part(chunk, 0, byte_length)
      tail = binary_part(chunk, byte_length, byte_size(chunk) - byte_length)

      {[head | acc], [tail | rest],
       total_queued_size - chunk_size + strategy_size(strategy, tail)}
    end
  end

  defp maybe_refresh_read_actions(%{type: :producer_consumer} = data, actions) do
    data = refresh_backpressure(data)
    {data, ready_actions} = maybe_resolve_ready_waiters(data)
    {data, enqueue_actions} = maybe_resolve_enqueue_waiters(data)
    {data, actions ++ ready_actions ++ enqueue_actions}
  end

  defp maybe_refresh_read_actions(data, actions) do
    {data, enqueue_actions} = maybe_resolve_enqueue_waiters(data)
    {data, actions ++ enqueue_actions}
  end

  defp maybe_request_pull(data, actions) do
    if readable_wants_chunk?(data) do
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

      # A close of the readable side of a transform stream is `terminate`.
      {:cast, :close} ->
        handle_common(:cast, :terminate_transform, state, data)

      _ ->
        :not_handled
    end
  end

  # ---------------------------------------------------------------------------
  # Producer enqueue logic (used from readable/3 and producer_consumer states)
  # ---------------------------------------------------------------------------

  # The queue of a byte stream holds binaries, thus a BYOB read can take a
  # part of a chunk. A branch of `tee` gets its chunks as views.
  defp handle_producer_enqueue(%Web.Uint8Array{} = chunk, state, %{stream_type: :bytes} = data) do
    handle_producer_enqueue(Web.Uint8Array.to_binary(chunk), state, data)
  end

  defp handle_producer_enqueue(chunk, _state, %{pending_byob_request: %{}} = data)
       when is_binary(chunk) do
    fulfill_pending_byob_enqueue(chunk, data)
  end

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
        :gen_statem.reply(from, {:ok, default_read_chunk(data, c)})

        {:keep_state, new_data, [{:next_event, :internal, :maybe_pull}]}

      {:empty, _} ->
        new_data = refresh_backpressure(new_data)
        {:keep_state, new_data, [{:next_event, :internal, :maybe_pull}]}
    end
  end

  defp fulfill_pending_byob_enqueue(chunk, %{pending_byob_request: %{}} = data) do
    {%{from: from, view: view}, new_data} = take_pending_byob_request(data)
    written_size = min(byte_size(chunk), view.byte_length)
    written = binary_part(chunk, 0, written_size)

    chunk_view = Web.Uint8Array.fill(view, written)

    new_data =
      if written_size < byte_size(chunk) do
        remainder = binary_part(chunk, written_size, byte_size(chunk) - written_size)

        %{
          new_data
          | queue: :queue.in(remainder, new_data.queue),
            total_queued_size: new_data.total_queued_size + queue_chunk_size(new_data, remainder)
        }
      else
        new_data
      end

    new_data = refresh_backpressure(new_data)
    actions = [{:reply, from, {:ok, chunk_view}}]
    {new_data, actions} = maybe_refresh_read_actions(new_data, actions)
    {:keep_state, new_data, maybe_request_pull(new_data, actions)}
  end

  defp handle_producer_close(data) do
    {new_data, pending_byob_actions} =
      data
      |> Map.put(:pulling, false)
      |> settle_pending_byob_request(:done)

    {:next_state, :closed, new_data,
     pending_byob_actions ++ [{:next_event, :internal, :flush_requests}]}
  end

  defp flush_read_requests(data) do
    if :queue.is_empty(data.queue) do
      data.read_requests
      |> :queue.to_list()
      |> Enum.each(&:gen_statem.reply(&1, :done))

      {new_data, pending_byob_actions} = settle_pending_byob_request(data, :done)

      {:keep_state, %{new_data | read_requests: :queue.new()}, pending_byob_actions}
    else
      :keep_state_and_data
    end
  end

  defp flush_errored_requests(data) do
    data.read_requests
    |> :queue.to_list()
    |> Enum.each(&:gen_statem.reply(&1, {:error, {:errored, data.error_reason}}))

    {new_data, pending_byob_actions} =
      settle_pending_byob_request(data, {:error, {:errored, data.error_reason}})

    {:keep_state, %{new_data | read_requests: :queue.new()}, pending_byob_actions}
  end

  # ---------------------------------------------------------------------------
  # Maybe pull (producer backpressure)
  # ---------------------------------------------------------------------------

  # The rule of the Streams Standard for a pull: the stream pulls when its
  # queue is below its limit, or when a read waits. A request during a pull
  # causes one more pull after it. Thus a source whose pull gives no chunk
  # immediately is not pulled again and again.
  defp handle_maybe_pull(data) do
    cond do
      data.pulling -> {:keep_state, %{data | pull_again: true}}
      readable_wants_chunk?(data) -> do_trigger_pull(data)
      true -> :keep_state_and_data
    end
  end

  defp readable_wants_chunk?(data) do
    readable_capacity(data) > 0 or not :queue.is_empty(data.read_requests) or
      not is_nil(data.pending_byob_request)
  end

  # The actions after a pull is complete.
  defp after_pull_actions(%{pull_again: true}), do: [{:next_event, :internal, :maybe_pull}]
  defp after_pull_actions(_data), do: []

  defp do_trigger_pull(%{module: module, impl_state: impl_state} = data) do
    if function_exported?(module, :pull, 2) do
      ctrl = readable_controller(data)

      task =
        start_task(
          fn ->
            try do
              module.pull(ctrl, impl_state) |> resolve_if_promise({:ok, impl_state})
            rescue
              e -> {:error, e}
            catch
              _kind, reason -> {:error, reason}
            end
          end,
          data.async_context
        )

      {:keep_state, set_active_task(data, task, :pull, pulling: true)}
    else
      :keep_state_and_data
    end
  end

  defp readable_controller(%{stream_type: :bytes}) do
    %Web.ReadableByteStreamController{pid: self()}
  end

  defp readable_controller(_data) do
    %Web.ReadableStreamDefaultController{pid: self()}
  end

  # ---------------------------------------------------------------------------
  # Consumer write/close/abort handlers
  # ---------------------------------------------------------------------------

  defp handle_write(from, pid, chunk, _state, data) do
    cond do
      pid != data.writer_pid ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}

      data.terminated ->
        {:keep_state_and_data, [{:reply, from, {:error, {:errored, terminated_error()}}}]}

      active_consumer_operation?(data) or not transform_ready?(data) ->
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

  # The backpressure of a transform stream, as the Streams Standard
  # specifies: the transform of a chunk starts only when the readable side
  # wants a chunk. Until then the write waits, and the writer gets
  # backpressure. Thus a reader that is slow does not fill the memory.
  defp transform_ready?(%{type: :producer_consumer} = data), do: readable_wants_chunk?(data)
  defp transform_ready?(_data), do: true

  # Starts a write that waited for the readable side. Each result of the
  # states `writable` and `closing` goes through this function.
  defp start_held_write(result, state, data) do
    case transition(result, state, data) do
      {next_state, new_data, actions} when next_state in [:writable, :closing] ->
        if held_write_can_start?(new_data) do
          {request, new_data} = dequeue_write_request(new_data)
          started = start_write_task(new_data, request)

          {:next_state, next_state, started, actions}
        else
          result
        end

      _other ->
        result
    end
  end

  defp held_write_can_start?(%{type: :producer_consumer} = data) do
    not active_consumer_operation?(data) and not :queue.is_empty(data.queued_write_requests) and
      readable_wants_chunk?(data)
  end

  defp held_write_can_start?(_data), do: false

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
        kill_task(data.active_task)
      end

      # The caller gets its reply when the abort callback is complete.
      data
      |> clear_active_operation()
      |> Map.put(:pending_abort_request, from)
      |> start_terminal_task(:abort, reason)
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
            _kind, reason -> {:error, reason}
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
            _kind, reason -> {:error, reason}
          end
        end,
        data.async_context
      )

    {:next_state, :closing, set_active_task(data, task, {:flush, data.pending_close_request})}
  end

  # An abort of a writable stream aborts the signal of its controller.
  defp abort_signal(%{abort_controller: %Web.AbortController{} = controller} = data, reason) do
    :ok = Web.AbortController.abort(controller, reason)
    data
  end

  # No process asked for the signal. The stream keeps the first reason.
  defp abort_signal(data, reason) do
    %{data | abort_controller: data.abort_controller || {:aborted, reason}}
  end

  # Runs the cancel or abort callback of the module in a task.
  defp start_terminal_task(data, type, reason) do
    data = if type == :abort, do: abort_signal(data, reason), else: data
    module = data.module
    impl_state = data.impl_state

    task =
      start_task(
        fn ->
          # The result of the callback has no use. A value that it throws,
          # or the reason of a promise that it returns, is the rejection
          # reason of the cancel or abort.
          try do
            result =
              if function_exported?(module, :terminate, 2) do
                module.terminate({type, reason}, impl_state)
              end

            # Only a promise that rejects is a failure. Each other value
            # that the callback returns has no effect.
            with %Web.Promise{} = promise <- result,
                 {:rejected, rejection} <- Web.Promise.wait(promise) do
              {:error, rejection}
            else
              _other -> :ok
            end
          rescue
            error -> {:error, error}
          catch
            _kind, thrown -> {:error, thrown}
          end
        end,
        data.async_context
      )

    set_active_task(data, task, :abort)
  end

  # ---------------------------------------------------------------------------
  # Task result handling
  # ---------------------------------------------------------------------------

  # The transformer called `terminate`, and then its write failed. The
  # write rejects with the failure. The readable side stays closed, and the
  # writable side has the error of the terminate.
  defp handle_task_result(
         {:error, reason},
         _state,
         %{terminated: true, active_operation: {:write, from}} = data
       ) do
    data
    |> clear_active_operation()
    |> Map.put(:pending_write_request, nil)
    |> terminate_transform([{:reply, from, {:error, {:errored, reason}}}])
  end

  defp handle_task_result({:error, reason}, _state, data) do
    fail_stream(reason, data)
  end

  # The pull of a producer is complete. The result `:pause` has the same
  # effect as no third element: the engine pulls again only when the stream
  # wants a chunk. With `:hibernate`, the stream process also hibernates.
  defp handle_task_result(result, _state, %{active_operation: :pull} = data)
       when tuple_size(result) in [2, 3] and elem(result, 0) == :ok do
    new_data =
      data
      |> Map.put(:impl_state, elem(result, 1))
      |> clear_active_operation()
      |> Map.merge(%{pulling: false, pull_again: false})

    hibernate = if match?({:ok, _state, :hibernate}, result), do: [:hibernate], else: []
    {:keep_state, new_data, after_pull_actions(data) ++ hibernate}
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
  defp handle_task_result(
         {:ok, new_impl_state},
         state,
         %{active_operation: {:write, from}} = data
       ) do
    data
    |> clear_active_operation()
    |> Map.put(:pending_write_request, nil)
    |> Map.put(:impl_state, new_impl_state)
    |> refresh_backpressure()
    |> continue_after_consumer_completion(state, [{:reply, from, :ok}])
  end

  # Flush task completed
  defp handle_task_result(
         {:ok, new_impl_state},
         _state,
         %{active_operation: {:flush, from}} = data
       ) do
    data
    |> clear_active_operation()
    |> Map.put(:pending_close_request, nil)
    |> Map.put(:impl_state, new_impl_state)
    |> close_consumer_stream([{:reply, from, :ok}])
  end

  defp handle_abort_task_result(result, data) do
    reply = if match?({:error, _thrown}, result), do: result, else: :ok

    {:keep_state, clear_active_operation(data), abort_reply_actions(data, reply)}
    |> clear_abort_request()
  end

  defp abort_reply_actions(%{pending_abort_request: nil}, _reply), do: []
  defp abort_reply_actions(%{pending_abort_request: from}, reply), do: [{:reply, from, reply}]

  defp clear_abort_request({:keep_state, data, actions}) do
    {:keep_state, %{data | pending_abort_request: nil}, actions}
  end

  defp continue_after_consumer_completion(data, state, actions) do
    cond do
      # The transformer called `terminate` during this write.
      data.terminated ->
        terminate_transform(data, actions)

      # The next write waits for the readable side of a transform stream.
      not :queue.is_empty(data.queued_write_requests) and not transform_ready?(data) ->
        {:keep_state, data, actions}

      not :queue.is_empty(data.queued_write_requests) ->
        {request, data} = dequeue_write_request(data)

        new_data =
          data
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

  # `terminate` of the controller of a transform stream, as in the Streams
  # Standard: the readable side closes after its chunks are read, and the
  # writable side goes to the errored state with a `TypeError`. The writes
  # that wait, a close that waits, and the promises `ready` and `closed` of
  # the writer reject with that error.
  defp terminate_transform(data, actions) do
    error = terminated_error()

    rejected =
      queued_write_error_actions(data, error) ++
        close_error_actions(data, error) ++
        ready_error_actions(data, error)

    data
    |> Map.merge(%{
      queued_write_requests: :queue.new(),
      queued_write_count: 0,
      pending_close_request: nil,
      ready_waiters: :queue.new(),
      writable_error: {:errored, error}
    })
    |> close_consumer_stream(actions ++ rejected)
  end

  defp terminated_error do
    Web.TypeError.exception("The transform stream was terminated.")
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
        kill_task(data.active_task)
    end

    {data, pending_byob_actions} = settle_pending_byob_request(data, {:error, {:errored, reason}})

    error_actions =
      pending_write_error_actions(data, reason) ++
        queued_write_error_actions(data, reason) ++
        close_error_actions(data, reason) ++
        ready_error_actions(data, reason) ++
        enqueue_error_actions(data, reason) ++
        pending_byob_actions

    new_data =
      data
      |> preserve_abort_task()
      |> clear_writer_lock()
      |> Map.put(:pending_write_request, nil)
      |> Map.put(:queued_write_requests, :queue.new())
      |> Map.put(:queued_write_count, 0)
      |> Map.put(:pending_close_request, nil)
      |> Map.put(:ready_waiters, :queue.new())
      |> Map.put(:enqueue_waiters, :queue.new())
      |> Map.put(:backpressure, false)
      |> Map.put(:error_reason, reason)
      |> Map.put(:queue, :queue.new())
      |> Map.put(:total_queued_size, 0)

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

  # ---------------------------------------------------------------------------
  # Lifetime
  #
  # The BEAM does not collect a process that no one refers to. Thus a stream
  # stops by these rules:
  #
  #   * A stream that has work, or chunks that are not read, does not stop
  #     while a process holds its reader lock or its writer lock.
  #   * When the owner stopped and the stream has work or chunks that are
  #     not read, the stream waits for the linger time. This lets a different
  #     process, which got the stream in a message, take a lock. Then the
  #     stream cancels (or aborts) and stops.
  #   * An owner that stopped with a failure or a shutdown gets no linger
  #     time: the stream cancels (or aborts) immediately, unless a process
  #     holds a lock. The stream has no link to its owner. Thus a failure of
  #     the owner does not stop a stream that a different process reads, and
  #     the source always gets its `cancel` call.
  #   * The writer lock of a pipe does not keep the destination stream. When
  #     the destination stops, the pipe ends and cancels its source. Thus the
  #     life of a pipe follows the process that uses its destination.
  #   * When the stream is ended and all its chunks are read, it waits for
  #     the linger time and stops. A lock has no effect, because the stream
  #     has no more data for the process that holds the lock.
  #
  # Each state function sends its result through `with_lifetime/3`, which
  # starts or cancels the timer.
  # ---------------------------------------------------------------------------

  @handoff_linger 5_000

  defp with_lifetime(result, state, data) do
    case transition(result, state, data) do
      {next_state, new_data, actions} ->
        {new_data, closed_actions} = closed_waiter_actions(next_state, new_data)
        timeout = lifetime_timeout(next_state, new_data)

        cond do
          timeout != new_data.lifetime_timer ->
            {:next_state, next_state, %{new_data | lifetime_timer: timeout},
             actions ++ closed_actions ++ [lifetime_action(timeout)]}

          closed_actions != [] ->
            {:next_state, next_state, new_data, actions ++ closed_actions}

          true ->
            result
        end

      :stop ->
        result
    end
  end

  # The processes that wait for the promise `closed` get the end of the
  # stream.
  defp closed_waiter_actions(state, %{closed_waiters: [_ | _] = waiters} = data)
       when state in [:closed, :errored] do
    actions =
      Enum.map(waiters, fn {from, side, _pid} ->
        if state == :closed do
          {:reply, from, closed_reply(data, side)}
        else
          {:reply, from, {:error, {:errored, data.error_reason}}}
        end
      end)

    {%{data | closed_waiters: []}, actions}
  end

  defp closed_waiter_actions(_state, data), do: {data, []}

  # The reply for the promise `closed` of one side of a closed stream. The
  # writable side of a transform stream can be in the errored state while
  # the readable side is closed.
  defp closed_reply(%{writable_error: {:errored, reason}}, :writer),
    do: {:error, {:errored, reason}}

  defp closed_reply(_data, _side), do: :ok

  # A release of the lock rejects the promise `closed` of that reader or writer.
  defp release_closed_waiters(data, side, pid) do
    {released, kept} =
      Enum.split_with(data.closed_waiters, fn {_from, waiter_side, waiter_pid} ->
        waiter_side == side and waiter_pid == pid
      end)

    actions = Enum.map(released, fn {from, _, _} -> {:reply, from, {:error, :lock_released}} end)
    {%{data | closed_waiters: kept}, actions}
  end

  defp lock_holder(data, :reader), do: data.reader_pid
  defp lock_holder(data, :writer), do: data.writer_pid

  defp transition(:keep_state_and_data, state, data), do: {state, data, []}
  defp transition({:keep_state_and_data, actions}, state, data), do: {state, data, actions}
  defp transition({:keep_state, new_data}, state, _data), do: {state, new_data, []}
  defp transition({:keep_state, new_data, actions}, state, _data), do: {state, new_data, actions}
  defp transition({:next_state, next, new_data}, _state, _data), do: {next, new_data, []}

  defp transition({:next_state, next, new_data, actions}, _state, _data),
    do: {next, new_data, actions}

  defp transition({:stop, _reason, _new_data}, _state, _data), do: :stop

  defp lifetime_action(nil), do: {{:timeout, :lifetime}, :cancel}
  defp lifetime_action(timeout), do: {{:timeout, :lifetime}, timeout, :expired}

  # Returns the time to wait before the stream stops, or `nil` if the stream
  # must stay.
  defp lifetime_timeout(state, data) when state in [:closed, :errored] do
    cond do
      not is_nil(data.active_task) -> nil
      # No process can read the chunks of an errored stream.
      state == :errored or drained?(data) -> complete_linger(data)
      true -> unread_linger(data)
    end
  end

  defp lifetime_timeout(_state, data), do: unread_linger(data)

  # The stream is ended and has no chunks. A lock does not keep it. A process
  # that got the stream in a message can still get a reader in the linger
  # time, and read the end of the stream.
  defp complete_linger(data) do
    cond do
      not owner_down?(data) -> data.linger
      owner_failed?(data) and not locked?(data) -> 0
      # The linger time `:infinity` is not applicable after the owner stopped.
      true -> handoff_linger(data.linger)
    end
  end

  # The stream has work, or chunks that are not read.
  defp unread_linger(data) do
    cond do
      locked?(data) -> nil
      owner_failed?(data) -> 0
      owner_down?(data) -> handoff_linger(data.linger)
      true -> nil
    end
  end

  # An owner that stopped with a failure or a shutdown gave the stream to no
  # process. Only a normal stop gets the handoff time.
  defp owner_failed?(%{owner_down_reason: {:owner_down, reason}}),
    do: reason not in [:normal, :noproc]

  defp owner_failed?(_data), do: false

  defp owner_down?(data), do: not is_nil(data.owner_down_reason)
  # The writer lock of a pipe is not a lock for these rules. A pipe writes
  # for the process that reads the destination, or for the owner. If the
  # pipe kept the destination, a pipe with an endless source would have no
  # end after all its users stopped.
  defp locked?(data) do
    is_pid(data.reader_pid) or (is_pid(data.writer_pid) and not data.writer_is_pipe)
  end

  defp handoff_linger(linger) when is_integer(linger), do: linger
  defp handoff_linger(_infinity), do: @handoff_linger

  defp drained?(data) do
    :queue.is_empty(data.queue) and :queue.is_empty(data.read_requests) and
      is_nil(data.pending_byob_request)
  end

  defp unread_timeout_actions(%{unread_timeout: timeout}) when is_integer(timeout) do
    [{{:timeout, :unread}, timeout, :expired}]
  end

  defp unread_timeout_actions(_data), do: []

  defp unread_error(data) do
    Web.TypeError.exception(
      "The stream was not read in #{data.unread_timeout} ms. " <>
        "Read or cancel each response body."
    )
  end

  defp owner_down_type(%{type: :producer}), do: :cancel
  defp owner_down_type(_consumer_or_transform), do: :abort

  defp handle_termination(type, reason, data) do
    {_result, transition} = termination_with_result(type, reason, data)
    transition
  end

  # Gives the result of the terminal callback together with the transition.
  # A callback that throws does not stop the stream process: the stream
  # goes to its terminal state, and the caller gets the thrown value.
  defp termination_with_result(type, reason, data) do
    data = data |> clear_owner() |> clear_task()

    case {type, signal_terminate(data, type, reason)} do
      # A close callback that throws puts the stream in the errored state.
      {:close, {:error, thrown} = result} ->
        {result, finalize_termination(data, :error, thrown)}

      {_type, result} ->
        {result, finalize_termination(data, type, reason)}
    end
  end

  defp finalize_termination(data, type, reason) when type in [:cancel, :close] do
    {data, pending_byob_actions} = settle_pending_byob_request(data, :done)

    actions =
      if type == :cancel and data.type == :producer_consumer do
        # A cancel of the readable side of a transform stream: the writes
        # that wait reject with the reason of the cancel.
        pending_write_error_actions(data, reason) ++
          queued_write_error_actions(data, reason) ++
          close_error_actions(data, reason) ++
          ready_error_actions(data, reason) ++
          pending_byob_actions
      else
        pending_write_closed_actions(data) ++
          queued_write_closed_actions(data) ++
          close_ok_actions(data) ++
          ready_ok_actions(data) ++
          pending_byob_actions
      end

    new_data = %{
      data
      | disturbed: type == :cancel or data.disturbed,
        writable_error:
          if(type == :cancel and data.type == :producer_consumer, do: {:errored, reason}),
        queue: if(type == :cancel, do: :queue.new(), else: data.queue),
        pulling: false,
        pending_write_request: nil,
        pending_close_request: nil,
        queued_write_requests: :queue.new(),
        queued_write_count: 0,
        ready_waiters: :queue.new(),
        backpressure: false,
        error_reason: nil
    }

    {:next_state, :closed, new_data, actions ++ [{:next_event, :internal, :flush_requests}]}
  end

  defp finalize_termination(data, _type, reason) do
    {data, pending_byob_actions} = settle_pending_byob_request(data, {:error, {:errored, reason}})

    error_actions =
      pending_write_error_actions(data, reason) ++
        queued_write_error_actions(data, reason) ++
        close_error_actions(data, reason) ++
        ready_error_actions(data, reason) ++
        pending_byob_actions

    new_data = %{
      data
      | pending_write_request: nil,
        queued_write_requests: :queue.new(),
        queued_write_count: 0,
        pending_close_request: nil,
        ready_waiters: :queue.new(),
        backpressure: false,
        error_reason: reason
    }

    {:next_state, :errored, new_data,
     error_actions ++ [{:next_event, :internal, :flush_requests}]}
  end

  defp signal_terminate(%{module: module, impl_state: impl_state}, type, reason) do
    if function_exported?(module, :terminate, 2) do
      module.terminate({type, reason}, impl_state)
    end

    :ok
  rescue
    error -> {:error, error}
  catch
    _kind, thrown -> {:error, thrown}
  end

  defp clear_owner(%{reader_ref: reader_ref, writer_ref: writer_ref} = data) do
    if reader_ref, do: Process.demonitor(reader_ref, [:flush])
    if writer_ref, do: Process.demonitor(writer_ref, [:flush])

    %{
      data
      | reader_pid: nil,
        reader_ref: nil,
        reader_mode: nil,
        writer_pid: nil,
        writer_ref: nil
    }
  end

  defp clear_task(data) do
    if data.active_task, do: kill_task(data.active_task)
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
    data.queued_write_count + if(data.pending_write_request, do: 1, else: 0)
  end

  defp enqueue_write_request(data, request) do
    %{
      data
      | queued_write_requests: :queue.in(request, data.queued_write_requests),
        queued_write_count: data.queued_write_count + 1
    }
  end

  defp dequeue_write_request(data) do
    {{:value, request}, remaining} = :queue.out(data.queued_write_requests)

    {request,
     %{data | queued_write_requests: remaining, queued_write_count: data.queued_write_count - 1}}
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
    if :queue.is_empty(data.enqueue_waiters) or not readable_wants_chunk?(data) do
      {data, []}
    else
      actions =
        data.enqueue_waiters
        |> :queue.to_list()
        |> Enum.flat_map(&List.wrap(waiter_ok_action(&1)))

      {%{data | enqueue_waiters: :queue.new()}, actions}
    end
  end

  defp maybe_cancel_on_reader_exit(reason, state, %{cancel_on_reader_exit: true} = data)
       when state not in [:closed, :errored] do
    handle_termination(:cancel, {:reader_down, reason}, data)
  end

  defp maybe_cancel_on_reader_exit(_reason, _state, data) do
    new_data =
      data
      |> drop_pending_byob_request()
      |> Map.put(:reader_pid, nil)
      |> Map.put(:reader_ref, nil)
      |> Map.put(:reader_mode, nil)

    {:keep_state, new_data}
  end

  defp handle_terminate_request(type, reason, state, data) do
    {_result, transition} = terminate_request_with_result(type, reason, state, data)
    transition
  end

  defp terminate_with_task(type, reason, from, data) do
    data
    |> clear_owner()
    |> clear_task()
    |> Map.put(:pending_abort_request, from)
    |> start_terminal_task(type, reason)
    |> finalize_termination(type, reason)
  end

  # A terminal event for a stream that is closed or errored has no effect,
  # and calls no callback, as in the Streams Standard.
  defp terminate_request_with_result(type, reason, state, data) do
    if state in [:closed, :errored] do
      {:ok, :keep_state_and_data}
    else
      termination_with_result(type, reason, data)
    end
  end

  defp waiter_ok_action({:signal, pid, ref}) do
    send(pid, {:ready, ref})
    []
  end

  defp waiter_ok_action(from), do: {:reply, from, :ok}

  defp waiter_closed_action(from), do: {:reply, from, {:error, :closed}}

  defp waiter_error_action({:signal, pid, ref}, reason) do
    send(pid, {:stream_error, ref, {:errored, reason}})
    []
  end

  defp waiter_error_action(from, reason), do: {:reply, from, {:error, {:errored, reason}}}

  defp byob_request_for(nil), do: nil

  defp byob_request_for(%{address: address, view: %Web.Uint8Array{} = view}) do
    %Web.ReadableStreamBYOBRequest{
      address: address,
      view_byte_offset: view.byte_offset,
      view_byte_length: view.byte_length
    }
  end

  defp new_pending_byob_request(from, %Web.Uint8Array{} = view) do
    %{
      from: from,
      view: view,
      address: Process.alias([:reply])
    }
  end

  defp take_pending_byob_request(%{pending_byob_request: nil} = data) do
    {nil, data}
  end

  defp take_pending_byob_request(%{pending_byob_request: %{address: address} = request} = data) do
    Process.unalias(address)
    {request, %{data | pending_byob_request: nil}}
  end

  defp drop_pending_byob_request(data) do
    {_request, new_data} = take_pending_byob_request(data)
    new_data
  end

  defp settle_pending_byob_request(data, reply) do
    case take_pending_byob_request(data) do
      {nil, new_data} ->
        {new_data, []}

      # The reader gets its buffer back, in a view of zero bytes.
      {%{from: from, view: view}, new_data} when reply == :done ->
        {new_data, [{:reply, from, {:done, Web.Uint8Array.empty(view)}}]}

      {%{from: from}, new_data} ->
        {new_data, [{:reply, from, reply}]}
    end
  end

  defp fulfill_pending_byob_view(view, %{pending_byob_request: %{}} = data) do
    case normalize_byob_response_view(view) do
      {:ok, %Web.Uint8Array{} = response_view} ->
        {%{from: from}, new_data} = take_pending_byob_request(data)
        actions = [{:reply, from, {:ok, response_view}}]
        {:keep_state, new_data, maybe_request_pull(new_data, actions)}

      :error ->
        fail_stream(:invalid_byob_response, data)
    end
  end

  defp fail_invalid_byob_response(%{pending_byob_request: %{}} = data) do
    fail_stream(:invalid_byob_response, data)
  end

  defp normalize_byob_response_view(%Web.Uint8Array{} = view), do: {:ok, view}

  defp normalize_byob_response_view(view) when is_binary(view) do
    {:ok, view |> Web.ArrayBuffer.new() |> Web.Uint8Array.new()}
  end

  defp normalize_byob_response_view(_view), do: :error

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

  defp queue_chunk_size(%{strategy: strategy}, chunk) do
    strategy_size(strategy, chunk)
  end

  defp strategy_size(%{__struct__: strategy}, chunk), do: strategy.size(chunk)

  defp normalize_strategy(%{__struct__: _} = strategy), do: strategy
  # A value that is not a strategy gives the default strategy.
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

  # ---------------------------------------------------------------------------
  # The worker
  #
  # The callbacks of a stream run in one worker process, one at a time. The
  # worker stays for the life of the stream. Thus a callback costs two
  # messages, and no new process.
  #
  # The stream monitors the worker for each callback, and the worker sends
  # `{ref, result}` with the reference of that monitor: the messages of a
  # task of Elixir. A worker that stops during a callback gives a `:DOWN`
  # message with that reference.
  #
  # The stream kills the worker to stop a callback that runs, for example at
  # a cancel. The next callback starts a new worker. The worker stops when
  # the stream stops.
  # ---------------------------------------------------------------------------

  defp start_task(fun, snapshot) do
    worker = worker()
    ref = Process.monitor(worker)
    send(worker, {:run, ref, fun, snapshot})
    %{ref: ref, pid: worker}
  end

  defp worker do
    case Process.get(@worker_key) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: start_worker()

      nil ->
        start_worker()
    end
  end

  defp start_worker do
    stream = self()
    pid = spawn(fn -> worker_init(stream) end)
    Process.put(@worker_key, pid)
    pid
  end

  defp worker_init(stream) do
    # The promises and streams that the callbacks make belong to the stream.
    Web.Promise.put_owner(stream)
    worker_loop(stream, Process.monitor(stream))
  end

  defp worker_loop(stream, monitor) do
    receive do
      {:run, ref, fun, snapshot} ->
        result =
          case snapshot do
            %Snapshot{} -> Snapshot.run(snapshot, fun)
            _ -> fun.()
          end

        send(stream, {ref, result})
        worker_loop(stream, monitor)

      {:DOWN, ^monitor, :process, ^stream, _reason} ->
        :ok
    end
  end

  # Stops the callback that runs, and waits until the worker stopped. Thus
  # no callback of the stream runs at the same time as the next one.
  defp kill_task(%{ref: ref, pid: pid}) do
    Process.demonitor(ref, [:flush])
    stop_worker(pid)
  end

  defp stop_worker(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end

    if Process.get(@worker_key) == pid, do: Process.delete(@worker_key)
    :ok
  end

  # Resolve a callback result that may be a %Web.Promise{}, awaiting it and
  # adopting its state. Falls back to `fallback` if the promise resolves to
  # something unexpected. Non-promise values pass through unchanged.
  defp resolve_if_promise(%Web.Promise{} = promise, fallback) do
    case Web.Promise.wait(promise) do
      {:fulfilled, {:ok, _} = result} -> result
      {:fulfilled, {:ok, _, _} = result} -> result
      {:fulfilled, {:error, _} = result} -> result
      {:fulfilled, _other} -> fallback
      {:rejected, reason} -> {:error, reason}
    end
  end

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

  # The stream process subscribes to the signal. Thus no other process is
  # necessary, and the signal drops the subscription when the stream stops.
  defp bind_ambient_signal(%{ambient_signal: %AbortSignal{aborted: true, reason: reason}}) do
    send(self(), {:ambient_signal_abort, reason})
    nil
  end

  defp bind_ambient_signal(%{ambient_signal: %AbortSignal{} = signal}) do
    case AbortSignal.subscribe(signal) do
      {:ok, subscription} ->
        subscription

      {:error, :aborted} ->
        reason = AbortSignal.reason(signal) || AbortSignal.default_reason()
        send(self(), {:ambient_signal_abort, reason})
        nil
    end
  end

  defp bind_ambient_signal(_snapshot), do: nil
end
