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
  - `:producer_consumer` — transform in one process (e.g. `CompressionStream`)

  A `Web.TransformStream` has two processes: a `:producer` and a
  `:consumer`. See "The two sides of a transform stream".
  """

  @behaviour :gen_statem

  alias Web.AbortSignal
  alias Web.AsyncContext.Snapshot
  alias Web.Internal.ByteStreamController
  alias Web.Internal.LazyStream
  alias Web.Internal.QueuingStrategy

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

  # The forms of the messages that keep the sequence of one sender: see
  # "Priority messages".
  @fence :"$web_fence"
  @fenced :"$web_fenced"
  @sent :"$web_sent"
  @sequence_forms [@fence, @fenced, @sent]

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
    :active_operation,
    :async_context,
    # The callers that wait for the end of the function start: see
    # `run_start/4`.
    start_waiters: [],
    # Producer (readable) side
    queue: :queue.new(),
    hwm: 1,
    readable_hwm: 1,
    writable_hwm: 1,
    total_queued_size: 0,
    strategy: %Web.CountQueuingStrategy{},
    # The size algorithms of the two sides: see `Web.Internal.QueuingStrategy`.
    # The queue of a default stream holds `{chunk, size}`.
    readable_size: :count,
    writable_size: :count,
    # The sizes of the writes that are not complete, in their sequence, and
    # their total.
    write_sizes: :queue.new(),
    write_total: 0,
    # The reader lock and the promise `closed` of each reader that asked for
    # it: see `reader_closed/4`.
    closed_promises: %{},
    stream_type: :default,
    # The state of the controller of a byte stream: see
    # `Web.Internal.ByteStreamController`. `nil` for each other stream.
    bytes: nil,
    pulling: false,
    reader_pid: nil,
    reader_ref: nil,
    reader_mode: nil,
    # A pull was requested while a pull was in progress.
    pull_again: false,
    # The transformer called `terminate`: the stream closes after the write
    # that is in progress.
    terminated: false,
    # `{:errored, reason}` when the writable side of a closed transform
    # stream is in the errored state: the readable side was cancelled (the
    # reason of the cancel), or the transformer called `terminate`.
    writable_error: nil,
    # The slots of `Web.TransformStream` that the two sides share, for the
    # process of one side: see "The two sides of a transform stream". `nil`
    # for each other stream.
    transform: nil,
    read_requests: :queue.new(),
    disturbed: false,
    # The stream was cancelled: see `complete_linger/1`.
    canceled: false,
    # Consumer (writable) side
    writer_pid: nil,
    writer_ref: nil,
    # The promises `ready` and `closed` of the writer that holds the lock, and
    # of the writers that released their lock: see "The promises of a
    # writer".
    writer_ready: nil,
    writer_closed: nil,
    released_writer_promises: %{},
    # The lock of a writer that the stream released at an error or a
    # terminal event, not the writer: that writer still has the stream.
    cleared_writer_ref: nil,
    # A pipe holds the writer lock. Such a lock does not keep the stream.
    writer_is_pipe: false,
    pending_write_request: nil,
    pending_close_request: nil,
    # The caller of an abort, until the abort callback of the sink is complete.
    pending_abort_request: nil,
    # The pipe that waits until the abort callback of the sink returned:
    # see "The abort action of a pipe".
    abort_notice: nil,
    # A public abort that runs the listeners of the signal of the
    # controller: see "The abort of a writable stream by a public function".
    abort_window: nil,
    # The [[pendingAbortRequest]] of a writable stream that is erroring:
    # `{callers, reason, was_already_erroring}`. See `writable_abort/4`.
    abort_request: nil,
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
    error_reason: nil,
    cancel_on_reader_exit: false,
    # Lifetime
    signal_subscription: nil,
    # `{monitor, error_fun}` for the option `:watch_source`: the process that
    # gives the chunks. A stop of that process before the end of the stream
    # puts the stream in the errored state.
    source_watch: nil,
    # The pull of a source that is a process: see `__start__/3`.
    direct_pull: nil,
    unread_timeout: nil,
    owner_ref: nil,
    owner_down_reason: nil,
    linger: 5_000,
    lifetime_timer: nil,
    # The key of a stream with no process, when this process is its stream
    # process: see `Web.Internal.LazyStream`.
    lazy_key: nil,
    # The copies of a stream with no process that got this process and take
    # its lock next: monitor => pid. See "Lifetime".
    keepers: %{}
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
  def start_link(module, opts) when is_atom(module), do: __start__(module, opts, [])

  @doc false
  # Starts a stream with options of this library that are not part of any
  # public function:
  #
  #   * `:direct_pull` — the engine pulls from a source that is a process,
  #     with no callback in the worker:
  #       - `{:message, pid, message}`: the engine sends `message` to `pid`,
  #         and the pull is complete at once. The source enqueues later;
  #       - `{:pid_source, pid}`: the same, with the message
  #         `{:pull, stream}` of a source that is a process;
  #       - `{:process, pid}`: the engine sends
  #         `{:web_stream_pull, ref, stream}` to `pid` and monitors it. The
  #         pull is complete when `pid` sends `{ref, :pulled}` with
  #         `__send_info__/2`. A cancel does not stop `pid`: the cancel
  #         callback must stop it.
  #   * `:watch_source` — `{pid, error_fun}`: a stop of `pid` before the end
  #     of the stream puts the stream in the errored state.
  #   * `:registry_key` — the stream registers itself with this key: see
  #     `Web.Internal.LazyStream`. With `:lazy_kind` (`:bytes`, the default,
  #     or `:closed`), the stream starts only when the state of that stream
  #     with no process permits it: else `__start__/3` returns `:ignore`.
  #   * `:disturbed` — the stream starts disturbed.
  def __start__(module, opts, internal) when is_atom(module) and is_list(internal) do
    snapshot = Snapshot.new()
    owner = Keyword.get_lazy(opts, :owner, &Web.Promise.owner/0)
    :gen_statem.start(__MODULE__, {module, opts, internal, snapshot, owner}, [])
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
    # The tag tells the sender of the call: see "Priority messages".
    tag = {@sent, caller, make_ref()}

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
  # The two sides of a transform stream have the same start: give the list
  # of their processes. The first process owns the promises of `start`.
  #
  # With the option `await: true`, the function returns after each process
  # has the end of a start that gave a value or a settled promise. In
  # JavaScript, the reactions to that start come before the reaction to
  # each later operation. Thus the later operations find the processes
  # started. See `tla/TransformStream.tla`.
  #
  # Only `Web.TransformStream.new/2` uses the option. A readable stream and
  # a writable stream get the end of start later, in a message from their
  # worker, as JavaScript sets [[started]] in a reaction after the
  # constructor. That gives a different time of a result, and never a
  # result that the Streams Standard cannot give:
  #
  #   * [[started]] has an effect only in ReadableStreamDefaultControllerShouldCallPull
  #     (and the same step of a byte stream), in
  #     WritableStreamDefaultControllerAdvanceQueueIfNeeded, and in
  #     WritableStreamStartErroring. Each of them only moves a step (a pull,
  #     a write, a close, or WritableStreamFinishErroring) to the reaction
  #     to start. The stream process also does these steps after its start
  #     task.
  #   * An operation of a caller that comes before the end of start finds
  #     the state that a synchronous operation after the constructor finds
  #     in JavaScript. An operation that comes after it finds the state that
  #     an operation after an await finds. For example, an abort after an
  #     error of the controller rejects with the stored error ("erroring"),
  #     or fulfils ("errored"): each is the result of JavaScript for one
  #     place of the reaction to start between the operations.
  #   * No algorithm of these two streams reacts to a promise and then reads
  #     the state that [[started]] changes. The pipe treats "erroring" and
  #     "errored" alike. A transform stream is different: the reaction of
  #     TransformStreamDefaultSourceCancelAlgorithm reads the state of the
  #     writable side, which is a different process.
  def run_start(pids, start_fn, controller, opts \\ [])

  def run_start(pids, start_fn, controller, opts) when is_list(pids) do
    resolvers = Enum.map(pids, &call(&1, :take_start_resolver, nil))
    # A promise from `start` becomes the result of the gate.
    result = Web.Promise.with_owner(hd(pids), fn -> start_fn.(controller) end)
    Enum.each(resolvers, & &1.(result))

    if Keyword.get(opts, :await, false) and settled?(result) do
      Enum.each(pids, &call(&1, :await_start, :ok))
    end

    :ok
  catch
    kind, value ->
      stacktrace = __STACKTRACE__
      Enum.each(pids, &stop/1)
      :erlang.raise(kind, value, stacktrace)
  end

  def run_start(pid, start_fn, controller, opts),
    do: run_start([pid], start_fn, controller, opts)

  defp settled?(%Web.Promise{} = promise), do: Web.Promise.peek(promise) != :pending
  defp settled?(_value), do: true

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
  # Thus they do not wait for the messages of other processes: the stream
  # gets them as priority messages of Erlang/OTP, before the other messages
  # of its mailbox. A stream with a full mailbox stops immediately.
  #
  # Each other message is a usual message. Thus the stream handles a `close`
  # after the chunks that the same process enqueued before it.
  #
  # A priority message goes before the usual messages that wait, also before
  # the earlier messages of the same process. In the Streams Standard, the
  # operations of one caller have their sequence: for example, `write()`
  # starts the write of the sink before `abort()`. Thus the sender keeps its
  # sequence with a fence:
  #
  #   1. The sender sends the usual message `{:"$web_fence", fence}`.
  #   2. The sender sends the priority message, with its pid and the fence.
  #   3. The stream gets the priority message first. It takes the usual
  #      messages of that sender up to the fence, with a selective receive,
  #      and handles them first. Then it handles the priority message, and
  #      then the messages of the other processes.
  #
  # Erlang/OTP keeps the sequence of the signals of one sender: the fence
  # comes before the priority message. Thus the fence is in the mailbox when
  # the stream gets the priority message, also when the sender stopped after
  # it.
  #
  # Each message that can wait in the mailbox before a priority message of
  # the same sender tells its sender:
  #
  #   * A call names its sender in its `from`: the tag
  #     `{:"$web_sent", sender, ref}` of `promise_call/4`, which gets the
  #     reply in a different process, or else the pid. The pipe, the tees,
  #     and the parser of `Web.FormData` send calls with no wait, with their
  #     own pid.
  #   * A cast has the form `{:"$web_sent", sender, message}`: see
  #     `control_cast/2` and `__usual_cast__/2`.
  #   * An info message of a process that is not a stream has the form
  #     `{:"$web_sent", sender, message}`: see `__send_info__/2`. For example,
  #     a source that is a process tells the end of a pull, and it can then
  #     put the stream in the errored state.
  #
  # The other messages have no sender, and the stream handles them after the
  # priority message. No such message can wait in the mailbox before a
  # priority message of its sender:
  #
  #   * The result of a callback comes from the worker when the callback
  #     returned. A priority message of the callback comes before it, and the
  #     next callback starts after the stream handled it.
  #   * A `:DOWN` message comes after each message of the process that
  #     stopped, and that process sends nothing after it.
  #   * The timers and the abort of an ambient signal: the stream and the
  #     process of a signal send no priority message to a stream.
  #   * The messages between the two sides of a transform stream: see "The
  #     two sides of a transform stream".
  #
  # A priority message needs a priority alias of the stream process. The
  # stream keeps its alias in its process dictionary, where a sender reads
  # it with no message to the stream.
  # ---------------------------------------------------------------------------

  @priority_alias {__MODULE__, :priority_alias}

  # The requests between the two sides of a transform stream: see
  # `handle_transform/4`.
  @transform_requests [
    :transform_peer,
    :transform_peer_locked,
    :transform_backpressure,
    :transform_error,
    :transform_error_unblock,
    :transform_error_if_needed,
    :transform_finish,
    :transform_finished,
    :transform_write,
    :transform_end
  ]

  # The requests of `Web.ReadableByteStreamController` and
  # `Web.ReadableStreamBYOBRequest`: see `handle_byte_request/4`.
  @byte_requests [
    :enqueue_bytes,
    :close_bytes,
    :byob_request,
    :byob_request_view,
    :byob_respond,
    :byob_respond_with_new_view
  ]

  # The size function of the user for the writable side. The process that
  # writes reads it from the dictionary of the stream, with no message: it
  # calls the function before it sends the write, as the Streams Standard
  # specifies. The stream removes it when the writable side is closed or
  # errored, as ClearAlgorithms does.
  @writable_size_key {__MODULE__, :writable_size}

  @doc false
  # The size function of the user for the writable side of the stream, or
  # `nil`.
  def __writable_size__(pid) when is_pid(pid) do
    case :erlang.process_info(pid, {:dictionary, @writable_size_key}) do
      {_item, size} when is_function(size, 1) -> size
      _other -> nil
    end
  rescue
    # The process is on a different node.
    ArgumentError -> nil
  end

  defp deliver(pid, envelope, message) do
    if abortive?(message) do
      send_with_priority(pid, envelope)
    else
      send(pid, with_sender(pid, envelope))
    end

    :ok
  end

  # A usual cast to a stream of this node tells its sender: see "Priority
  # messages". A call tells its sender in its tag.
  defp with_sender(pid, {:"$gen_cast", message}) when node(pid) == node(),
    do: {:"$gen_cast", {@sent, self(), message}}

  defp with_sender(_pid, envelope), do: envelope

  defp abortive?({terminate, type, _reason})
       when terminate in [:terminate, :terminate_unlocked] and type in [:cancel, :abort],
       do: true

  defp abortive?({:abort, _owner, _reason}), do: true
  defp abortive?({:abort_first_steps, _owner, _reason}), do: true
  defp abortive?({:abort_rest, _window, message}), do: abortive?(message)
  defp abortive?({:as_writer, _lock, message}), do: abortive?(message)
  defp abortive?({:error, _reason}), do: true
  defp abortive?(_message), do: false

  defp send_with_priority(pid, envelope) do
    case :erlang.process_info(pid, {:dictionary, @priority_alias}) do
      {_item, alias} when is_reference(alias) ->
        fence = make_ref()
        send(pid, {@fence, fence})
        :erlang.send(alias, fenced(envelope, fence), [:priority])

      # The process stopped, or it is not a stream of this version.
      _other ->
        send(pid, envelope)
    end
  rescue
    # The process is on a different node.
    ArgumentError -> send(pid, envelope)
  end

  defp fenced({:"$gen_call", from, message}, fence),
    do: {:"$gen_call", from, {@fenced, self(), fence, message}}

  defp fenced({:"$gen_cast", message}, fence),
    do: {:"$gen_cast", {@fenced, self(), fence, message}}

  @doc false
  # Sends a usual cast that tells its sender: see "Priority messages". It is
  # never a priority message, also for a message that `control_cast/2` sends
  # with priority.
  def __usual_cast__(pid, message) when is_pid(pid) do
    send(pid, with_sender(pid, {:"$gen_cast", message}))
    :ok
  end

  @doc false
  # Sends an info message that tells its sender, from a process that is not
  # a stream: see "Priority messages".
  def __send_info__(pid, message) when is_pid(pid) do
    send(pid, {@sent, self(), message})
    :ok
  end

  # The messages that keep the sequence of one sender, for each state
  # function `fun`: see "Priority messages".
  defp in_sequence(type, {@sent, _sender, message}, data, fun), do: fun.(type, message, data)

  # The stream handled the fence before the priority message came: it
  # handled the usual messages of the sender before the fence.
  defp in_sequence(:info, {@fence, fence}, _data, _fun) do
    Process.put({@fence, fence}, true)
    :keep_state_and_data
  end

  # A priority message: the stream handles the usual messages of its sender
  # up to the fence first. The fence is in the mailbox, or the stream
  # handled it.
  defp in_sequence(type, {@fenced, sender, fence, message}, _data, _fun) do
    earlier = if Process.delete({@fence, fence}), do: [], else: sender_events(sender, fence, [])
    {:keep_state_and_data, earlier ++ [{:next_event, type, message}]}
  end

  defp sender_events(sender, fence, events) do
    receive do
      {@fence, ^fence} ->
        Enum.reverse(events)

      {:"$gen_call", {_replier, {@sent, ^sender, _ref}} = from, message} ->
        sender_events(sender, fence, [{:next_event, {:call, from}, message} | events])

      # A call with no such tag names its sender with the pid of `from`.
      {:"$gen_call", {^sender, tag} = from, message}
      when not is_tuple(tag) or elem(tag, 0) != @sent ->
        sender_events(sender, fence, [{:next_event, {:call, from}, message} | events])

      {:"$gen_cast", {@sent, ^sender, message}} ->
        sender_events(sender, fence, [{:next_event, :cast, message} | events])

      {@sent, ^sender, message} ->
        sender_events(sender, fence, [{:next_event, :info, message} | events])
    end
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
  # The abort of a writable stream by a public function
  #
  # WritableStreamAbort signals abort on the signal of the controller in its
  # step 2. The listeners of the signal run at once, before the steps that
  # change the stream. A listener can write, close, or abort the stream
  # again, and the Streams Standard gives the result. The stream process
  # must answer other processes, thus it does not run the listeners. A
  # public abort does steps 1 and 2 in the calling process, as
  # `Web.AbortController.abort/2` does:
  #
  #   1. The caller asks the stream for its state, with a priority message.
  #      A closed or errored stream needs no abort.
  #   2. The caller signals abort. The listeners run in its process.
  #   3. The caller sends the abort. The stream does the steps after step 2.
  #      The abort is a priority message, and the requests that the
  #      listeners sent are usual messages of the same process: the stream
  #      handles them first. See "Priority messages".
  #
  # From step 1 to step 3, the stream keeps the results of its callbacks,
  # and handles them after the abort. In JavaScript, a write that stops
  # when the signal aborts completes in a later microtask, thus after the
  # abort. For example, a sink that stops a write when the signal aborts
  # gets its abort callback when the write is complete. A caller that stops
  # before step 3 does not keep the stream: the stream does the steps after
  # step 2 with no caller.
  #
  # A stream with no signal needs only step 3, because no process can have
  # a listener. The stream keeps its signal in its process dictionary, and
  # the caller reads it there with no message. Thus an abort of a stream
  # with no signal does not wait for the stream.
  #
  # An abort that this library starts, for example the abort of a pipe,
  # does all the steps in the stream process. A new process runs the
  # listeners: see `abort_signal/2`.
  # ---------------------------------------------------------------------------

  @abort_signal_key {__MODULE__, :abort_signal}

  @doc false
  # WritableStreamAbort for `Web.WritableStream.abort/2` and the abort of a
  # writer. `first_steps` is the request `{:abort_first_steps, owner,
  # reason}`, and `abort` is the request of the abort, each in the form of
  # the caller. `gone` and `mapper` are the arguments of `promise_call/4`.
  def __abort__(pid, {first_steps, abort}, reason, gone, mapper) when is_pid(pid) do
    case abort_signal_of(pid) do
      nil ->
        promise_call(pid, abort, gone, mapper)

      signal ->
        case first_abort_steps(pid, first_steps, gone) do
          {:continue, window} ->
            :ok = AbortSignal.__signal_abort__(signal, reason)
            promise_call(pid, {:abort_rest, window, abort}, gone, mapper)

          reply ->
            settled_promise(mapper.(reply))
        end
    end
  end

  defp abort_signal_of(pid) do
    case :erlang.process_info(pid, {:dictionary, @abort_signal_key}) do
      {_item, %AbortSignal{} = signal} -> signal
      _other -> nil
    end
  rescue
    # The process is on a different node.
    ArgumentError -> nil
  end

  defp first_abort_steps(pid, request, gone) do
    control_call(pid, request)
  catch
    # The stream stopped after the caller read its signal.
    :exit, {_reason, {__MODULE__, :control_call, _args}} -> gone
  end

  defp settled_promise({:ok, value}), do: Web.Promise.resolve(value)
  defp settled_promise({:error, reason}), do: Web.Promise.reject(reason)

  # ---------------------------------------------------------------------------
  # :gen_statem callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init({module, opts, snapshot, owner}), do: init({module, opts, [], snapshot, owner})

  def init({module, opts, internal, snapshot, owner}) do
    Process.flag(:message_queue_data, :off_heap)
    Process.put(@priority_alias, :erlang.alias([:priority]))
    # The callbacks of this stream run in tasks. The promises and streams that
    # they make belong to this stream.
    Web.Promise.put_owner(self())
    hwm = Keyword.get(opts, :high_water_mark, 1)
    strategy = normalize_strategy(Keyword.get(opts, :strategy, %Web.CountQueuingStrategy{}))

    started =
      case module.start(self(), opts) do
        {type, state} -> {type, state, []}
        {type, state, actions} -> {type, state, actions}
      end

    init_data(started, module, {opts, internal}, snapshot, owner, hwm, strategy)
  end

  defp init_data(
         {type, impl_state, extra_actions},
         module,
         {opts, internal},
         snapshot,
         owner,
         hwm,
         strategy
       ) do
    {readable_hwm, writable_hwm} = init_capacities(type, hwm, strategy)
    {readable_size, writable_size} = init_sizes(type, opts, strategy)

    # A writer calls the size function of the user in its own process: see
    # `__writable_size__/1`.
    if is_function(writable_size), do: Process.put(@writable_size_key, writable_size)

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
      readable_size: readable_size,
      writable_size: writable_size,
      stream_type: Keyword.get(opts, :stream_type, :default),
      bytes: byte_controller(opts),
      async_context: snapshot,
      owner_ref: Process.monitor(owner),
      linger: Keyword.get_lazy(opts, :linger, &Web.Promise.default_linger/0),
      unread_timeout: Keyword.get(opts, :unread_timeout),
      # A stream that replaces a stream with no process that a read used
      # already: see `Web.Internal.LazyStream`.
      disturbed: Keyword.get(internal, :disturbed, false),
      source_watch: watch_source(Keyword.get(internal, :watch_source)),
      direct_pull: Keyword.get(internal, :direct_pull),
      transform: transform_side(Keyword.get(opts, :transform)),
      lazy_key: Keyword.get(internal, :registry_key)
    }

    # A different stream process has the key, or the start is old: this
    # process stops normally, and its starter uses the state that it finds.
    if register(data.lazy_key, Keyword.get(internal, :lazy_kind, :bytes)) == :ok,
      do: init_states(type, extra_actions, data, snapshot),
      else: :ignore
  end

  defp init_states(type, extra_actions, data, snapshot) do
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

  defp byte_controller(opts) do
    if Keyword.get(opts, :stream_type) == :bytes do
      ByteStreamController.new(Keyword.get(opts, :auto_allocate_chunk_size))
    end
  end

  defp watch_source({pid, error_fun}) when is_pid(pid) and is_function(error_fun, 1) do
    {Process.monitor(pid), error_fun}
  end

  defp watch_source(nil), do: nil

  # The copies of a stream with no process find this process with the key:
  # see `Web.Internal.LazyStream`. The registry removes the key when the
  # process stops.
  defp register(nil, _kind), do: :ok
  defp register(key, kind), do: LazyStream.__register__(key, kind)

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

  # A request of a writer of `Web.WritableStreamDefaultWriter`, with the
  # reference of its lock. The state function handles the request of the
  # writer that holds the lock. A writer that released its lock has no
  # effect on the stream, also when the same process has a new writer.
  defp as_writer({:call, from} = type, {:as_writer, lock, message}, data, fun) do
    cond do
      lock == data.writer_ref ->
        fun.(type, message, data)

      # The stream released this lock, not the writer: see
      # `cleared_writer_ref`.
      is_reference(lock) and lock == data.cleared_writer_ref and
          message in [:writer_ready, :writer_closed] ->
        fun.(type, message, data)

      is_reference(lock) and lock == data.cleared_writer_ref ->
        fun.(type, writer_message(message, data.writer_pid), data)

      true ->
        {:keep_state_and_data, [{:reply, from, released_writer_reply(message, lock, data)}]}
    end
  end

  defp as_writer(type, content, data, fun), do: fun.(type, content, data)

  # ---------------------------------------------------------------------------
  # State: readable  (producers only)
  # ---------------------------------------------------------------------------

  def readable(type, content, data) when elem(content, 0) in @sequence_forms,
    do: in_sequence(type, content, data, &readable/3)

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
            handle_source_close(data)

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

  def writable(type, content, data) when elem(content, 0) in @sequence_forms,
    do: in_sequence(type, content, data, &writable/3)

  def writable(type, content, data) do
    type
    |> as_writer(content, data, &do_writable/3)
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
          handle_abort(from, pid, reason, :writable, data)

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

  def closing(type, content, data) when elem(content, 0) in @sequence_forms,
    do: in_sequence(type, content, data, &closing/3)

  def closing(type, content, data) do
    type
    |> as_writer(content, data, &do_closing/3)
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
    handle_abort(from, pid, reason, :closing, data)
  end

  defp handle_closing_event(_type, _content, _data), do: :keep_state_and_data

  # ---------------------------------------------------------------------------
  # State: erroring  (consumers only)
  #
  # The state "erroring" of a WritableStream in the Streams Standard: an
  # abort or `error` of the controller started the error, and a write, a
  # close, or the function `start` of the sink is not complete. The stream
  # waits for that operation. Then it goes to the state `errored`: see
  # `finish_erroring/2`. The field `error_reason` holds the stored error.
  # ---------------------------------------------------------------------------

  @doc false
  # A state function of `:gen_statem`.
  def erroring(type, content, data) when elem(content, 0) in @sequence_forms,
    do: in_sequence(type, content, data, &erroring/3)

  def erroring(type, content, data) do
    type |> as_writer(content, data, &do_erroring/3) |> with_lifetime(:erroring, data)
  end

  defp do_erroring(type, content, data) do
    with :not_handled <- handle_common(type, content, :erroring, data) do
      handle_erroring_event(type, content, data)
    end
  end

  # WritableStreamDefaultWriterWrite: a close that is queued or in flight
  # gives a `TypeError`, and else the write rejects with the stored error.
  defp handle_erroring_event({:call, from}, {:write, pid, _chunk}, data)
       when pid == data.writer_pid do
    reply =
      if data.pending_close_request,
        do: {:error, :closing},
        else: {:error, {:errored, data.error_reason}}

    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  # WritableStreamClose: the close request waits. The stream rejects it with
  # the stored error when the error is complete.
  defp handle_erroring_event({:call, from}, {:close, pid}, data)
       when pid == data.writer_pid do
    if data.pending_close_request do
      {:keep_state_and_data, [{:reply, from, {:error, :closing}}]}
    else
      {:keep_state, %{data | pending_close_request: from}}
    end
  end

  defp handle_erroring_event({:call, from}, {:abort, pid, reason}, data) do
    handle_abort(from, pid, reason, :erroring, data)
  end

  defp handle_erroring_event({:call, from}, {:write, _pid, _chunk}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
  end

  defp handle_erroring_event({:call, from}, {:close, _pid}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
  end

  defp handle_erroring_event(_type, _content, _data), do: :keep_state_and_data

  # ---------------------------------------------------------------------------
  # State: closed
  # ---------------------------------------------------------------------------

  def closed(type, content, data) when elem(content, 0) in @sequence_forms,
    do: in_sequence(type, content, data, &closed/3)

  def closed(type, content, data) do
    type |> as_writer(content, data, &do_closed/3) |> with_lifetime(:closed, data)
  end

  defp do_closed(type, content, data) do
    with :not_handled <- handle_common(type, content, :closed, data) do
      handle_closed_event(type, content, data)
    end
  end

  # ---------------------------------------------------------------------------
  # State: errored
  # ---------------------------------------------------------------------------

  def errored(type, content, data) when elem(content, 0) in @sequence_forms,
    do: in_sequence(type, content, data, &errored/3)

  def errored(type, content, data) do
    type |> as_writer(content, data, &do_errored/3) |> with_lifetime(:errored, data)
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

  # A request of a reader of `Web.ReadableStreamDefaultReader`. The reader
  # has the reference of its lock. A reader that released its lock keeps
  # no effect on the stream, also when the same process has a new reader.
  defp handle_common({:call, from}, {:as_reader, lock, message}, state, data) do
    if lock == data.reader_ref and not is_nil(lock) do
      handle_common({:call, from}, message, state, data)
    else
      {:keep_state_and_data, [{:reply, from, released_reader_reply(message)}]}
    end
  end

  # The attributes `ready` and `closed` of the writer that holds the lock.
  defp handle_common({:call, from}, request, state, data)
       when request in [:writer_ready, :writer_closed] do
    {promise, data} = writer_promise(request, state, data)
    {:keep_state, data, [{:reply, from, promise}]}
  end

  # The attribute `closed` of a reader: the same promise for each request.
  defp handle_common({:call, from}, {:reader_closed, lock}, state, data) do
    {promise, data} = reader_closed(lock, state, data)
    {:keep_state, data, [{:reply, from, promise}]}
  end

  # The requests between the two sides of a transform stream: see "The two
  # sides of a transform stream".
  defp handle_common(type, request, state, %{transform: %{}} = data)
       when is_tuple(request) and elem(request, 0) in @transform_requests do
    handle_transform(type, request, state, data)
  end

  # `terminate`, `close`, and `error` of the controller of the readable side.
  defp handle_common(:cast, :transform_terminate, state, %{transform: %{}} = data),
    do: handle_transform(:cast, :transform_terminate, state, data)

  defp handle_common(
         {:call, _from} = type,
         :close,
         state,
         %{transform: %{side: :readable}} = data
       ),
       do: handle_transform(type, :close, state, data)

  defp handle_common(:cast, {:error, reason}, state, %{transform: %{side: :readable}} = data),
    do: handle_transform(:cast, {:error, reason}, state, data)

  # A side of a transform stream that asked the other side for the end of
  # the two sides grants no lock until the answer: see "The lock rule of the
  # two sides". The request waits in the side, and the side handles it
  # after the answer.
  defp handle_common(
         {:call, _from} = type,
         {request, _pid, _mode} = content,
         _state,
         %{transform: %{ending: true} = transform} = data
       )
       when request in [:get_reader, :get_writer] do
    {:keep_state, put_transform(data, deferred: [{type, content} | transform.deferred])}
  end

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
        data = drop_keeper(data, pid)

        {:keep_state, %{data | reader_pid: pid, reader_ref: ref, reader_mode: reader_mode},
         [
           {:reply, from, {:ok, ref}}
         ]}
    end
  end

  defp handle_common({:call, from}, {:get_reader, _pid, _mode} = request, _state, data)
       when data.type in [:producer, :producer_consumer] do
    after_stopped_holder(
      data.reader_pid,
      data.reader_ref,
      from,
      request,
      {:error, :already_locked}
    )
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

  defp handle_common({:call, from}, {:byob_read, pid, view, min}, state, data)
       when data.type in [:producer, :producer_consumer] do
    handle_byob_read_request(from, pid, view, min, state, data)
  end

  # The release of the lock of one side. The two sides of a transform stream
  # have separate locks, thus the caller names the side. A release by a
  # process that does not hold the lock has no effect, as in the Streams
  # Standard.
  defp handle_common({:call, from}, {:release_lock, :reader, pid}, _state, data) do
    if pid == data.reader_pid do
      if(data.reader_ref, do: Process.demonitor(data.reader_ref, [:flush]))
      data = release_closed_promise(data)

      # The read requests of the reader reject, as the Streams Standard
      # specifies.
      {data, pending_byob_actions} = release_byte_reader(data)

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
      data = release_writer_promises(data)
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

  # Step 1 of WritableStreamAbort, and the check of the lock, for a public
  # abort: see "The abort of a writable stream by a public function". The
  # owner is `nil` for an abort of the stream object. A writer that released
  # its lock gets its answer from `as_writer/4`. The first caller opens the
  # window in which the stream keeps the results of its callbacks.
  defp handle_common({:call, from}, {:abort_first_steps, pid, reason}, state, data) do
    cond do
      pid != data.writer_pid ->
        {:keep_state_and_data, [{:reply, from, {:error, :locked}}]}

      state in [:closed, :errored] ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      data.abort_window != nil ->
        {:keep_state_and_data, [{:reply, from, {:continue, nil}}]}

      true ->
        {caller, _tag} = from
        window = %{id: make_ref(), monitor: Process.monitor(caller), reason: reason, held: []}
        {:keep_state, %{data | abort_window: window}, [{:reply, from, {:continue, window.id}}]}
    end
  end

  # Step 3: the abort, and then the results that the stream kept.
  defp handle_common({:call, from}, {:abort_rest, window, request}, _state, _data) do
    {:keep_state_and_data,
     [{:next_event, {:call, from}, request}, {:next_event, :internal, {:close_window, window}}]}
  end

  defp handle_common(:internal, {:close_window, id}, _state, %{abort_window: %{id: id}} = data) do
    %{monitor: monitor, held: held} = data.abort_window
    Process.demonitor(monitor, [:flush])
    actions = for message <- Enum.reverse(held), do: {:next_event, :info, message}
    {:keep_state, %{data | abort_window: nil}, actions}
  end

  defp handle_common(:internal, {:close_window, _id}, _state, _data), do: :keep_state_and_data

  # The caller stopped before it sent the abort.
  defp handle_common(
         :info,
         {:DOWN, ref, :process, _pid, _reason},
         _state,
         %{abort_window: %{monitor: ref} = window}
       ) do
    {:keep_state_and_data,
     [
       {:next_event, :internal, {:abort_with_no_caller, window.reason}},
       {:next_event, :internal, {:close_window, window.id}}
     ]}
  end

  defp handle_common(:internal, {:abort_with_no_caller, reason}, state, %{type: :consumer} = data)
       when state in [:writable, :closing, :erroring] do
    writable_abort(nil, reason, state, data)
  end

  defp handle_common(:internal, {:abort_with_no_caller, _reason}, _state, _data),
    do: :keep_state_and_data

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

      # The abort of a writable stream is the abort of a writer.
      type == :abort and data.type == :consumer ->
        {:keep_state_and_data, [{:next_event, {:call, from}, {:abort, nil, reason}}]}

      true ->
        handle_common({:call, from}, {:terminate, type, reason}, state, data)
    end
  end

  # A write with the result of the size function of the user: the writer
  # called it. A stream that is not writable handles the write as each
  # other write.
  defp handle_common({:call, from}, {:write, pid, chunk, size_result}, state, data)
       when data.type in [:consumer, :producer_consumer] do
    if state == :writable do
      handle_write(from, pid, chunk, size_result, state, data)
    else
      {:keep_state_and_data, [{:next_event, {:call, from}, {:write, pid, chunk}}]}
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

    data = %{
      data
      | writer_pid: pid,
        writer_ref: ref,
        writer_is_pipe: kind == :pipe,
        writer_ready: nil,
        writer_closed: nil,
        cleared_writer_ref: nil
    }

    {:keep_state, data, [{:reply, from, {:ok, ref}}]}
  end

  defp handle_common({:call, from}, {:get_writer, _pid, _kind} = request, _state, data)
       when data.type in [:consumer, :producer_consumer] do
    after_stopped_holder(
      data.writer_pid,
      data.writer_ref,
      from,
      request,
      {:error, :already_locked}
    )
  end

  # Ready (backpressure signal for writers)
  defp handle_common({:call, from}, {:ready, pid}, state, data)
       when data.type in [:consumer, :producer_consumer] do
    cond do
      state in [:errored, :erroring] ->
        {:keep_state_and_data, [{:reply, from, {:error, {:errored, data.error_reason}}}]}

      # The writable side of a transform stream is in the errored state. An
      # error releases the lock, thus this check comes before the lock check.
      state == :closed and is_tuple(data.writable_error) ->
        {:keep_state_and_data, [{:reply, from, closed_reply(data, :writer)}]}

      pid != data.writer_pid ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}

      # A close fulfils the promise `ready`, as WritableStreamClose specifies.
      state in [:closed, :closing] ->
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

      QueuingStrategy.positive?(readable_capacity(data)) ->
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
      nil -> controller_enqueue(from, chunk, state, data)
      refusal -> {:keep_state_and_data, [{:reply, from, {:error, refusal}}]}
    end
  end

  # The second step of an enqueue with the size function of the user: the
  # process that enqueues called the function. See `controller_enqueue/4`.
  defp handle_common({:call, from}, {:enqueue_sized, chunk, result}, state, data) do
    enqueue_sized(from, chunk, result, state, data)
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

  # The caller waits for the end of the start task: see `run_start/4` and
  # `clear_active_operation/1`.
  defp handle_common({:call, from}, :await_start, _state, data) do
    if data.active_operation in [:start, :init],
      do: {:keep_state, %{data | start_waiters: [from | data.start_waiters]}},
      else: {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  # Query helpers
  defp handle_common({:call, from}, :disturbed?, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.disturbed}]}
  end

  # A copy of a stream with no process got this process, and takes its lock
  # next. The process stays for the copy until the copy takes its lock or
  # stops: see `unread_linger/1`.
  defp handle_common({:call, from}, {:keep, pid}, _state, data) do
    keepers = Map.put(data.keepers, Process.monitor(pid), pid)
    {:keep_state, %{data | keepers: keepers}, [{:reply, from, :ok}]}
  end

  # ReadableStreamPipeTo sets [[disturbed]] of the source before its first
  # read: see `Web.ReadableStream.pipe_to/3`.
  defp handle_common({:call, from}, :disturb, _state, data) do
    {:keep_state, %{data | disturbed: true}, [{:reply, from, :ok}]}
  end

  # The signal of the controller of a writable stream, as the attribute
  # `signal` of the Streams Standard. The stream makes it for the first
  # request, thus a stream that does not use it has no process for it. A
  # public abort reads the signal in the process dictionary: see "The abort
  # of a writable stream by a public function".
  defp handle_common({:call, from}, :abort_signal, _state, data) do
    case data.abort_controller do
      nil ->
        controller = Web.AbortController.new()
        Process.put(@abort_signal_key, controller.signal)
        {:keep_state, %{data | abort_controller: controller}, [{:reply, from, controller.signal}]}

      {:aborted, reason} ->
        {:keep_state_and_data, [{:reply, from, Web.AbortSignal.abort(reason)}]}

      controller ->
        {:keep_state_and_data, [{:reply, from, controller.signal}]}
    end
  end

  # The two sides of a transform stream have separate locks.
  # A lock of a process that stopped is not a lock: see
  # `after_stopped_holder/5`.
  defp handle_common({:call, from}, {:locked?, :reader} = request, _state, data) do
    after_stopped_holder(data.reader_pid, data.reader_ref, from, request, is_pid(data.reader_pid))
  end

  defp handle_common({:call, from}, {:locked?, :writer} = request, _state, data) do
    after_stopped_holder(data.writer_pid, data.writer_ref, from, request, is_pid(data.writer_pid))
  end

  defp handle_common({:call, from}, :backpressure?, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.backpressure}]}
  end

  # Tells if the readable side wants a chunk now: the rule of a pull. A tee
  # asks this before a read for the pull of a branch.
  defp handle_common({:call, from}, :wants_chunk?, state, data) do
    {:keep_state_and_data, [{:reply, from, state == :readable and readable_wants_chunk?(data)}]}
  end

  # The desired size of the Streams Standard: `nil` for an errored stream,
  # and 0 for a closed stream.
  defp handle_common({:call, from}, :desired_size, state, data) do
    desired =
      case state do
        :errored -> nil
        :erroring -> nil
        :closed when is_tuple(data.writable_error) -> nil
        :closed -> 0
        _ -> internal_desired_size(data)
      end

    {:keep_state_and_data, [{:reply, from, desired}]}
  end

  # The attribute `desiredSize` of a writer. A writer that released its
  # lock throws a `TypeError`: see `as_writer/4`.
  defp handle_common({:call, from}, {:desired_size, :writer, _pid}, state, data) do
    handle_common({:call, from}, :desired_size, state, data)
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

  # The operations of the controller of a byte stream and of its BYOB
  # request: see `Web.Internal.ByteStreamController`.
  defp handle_common({:call, from}, request, state, %{bytes: %ByteStreamController{}} = data)
       when is_tuple(request) and elem(request, 0) in @byte_requests do
    handle_byte_request(from, request, state, data)
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

  # WritableStreamAbort, with no check of the lock.
  defp handle_common(
         {:call, from},
         {:terminate, :abort, reason},
         state,
         %{type: :consumer} = data
       )
       when state in [:writable, :closing, :erroring] do
    writable_abort(from, reason, state, data)
  end

  # The abort action of a pipe: see "The abort action of a pipe".
  defp handle_common({:call, from}, {:pipe_abort, pid, reason}, state, data)
       when state in [:writable, :closing] do
    noticed = %{data | abort_notice: from}
    result = handle_abort(from, pid, reason, state, noticed)
    {next_state, data, actions} = transition(result, state, noticed)
    {:next_state, next_state, send_abort_notice(data), actions}
  end

  # "If dest.[[state]] is "writable", return ! WritableStreamAbort(dest,
  # error). Otherwise, return a promise resolved with undefined."
  defp handle_common({:call, from}, {:pipe_abort, _pid, _reason}, _state, _data),
    do: {:keep_state_and_data, [{:reply, from, :ok}]}

  # The abort callback of the sink returned: the pipe can cancel its source.
  # The worker sends this message before the result of the callback, thus
  # the abort has no reply yet.
  defp handle_common(:info, {:abort_callback_returned, from}, _state, data) do
    send_abort_notice(%{data | abort_notice: from})
    :keep_state_and_data
  end

  # A cancel or an abort from a caller that waits for the result. The stream
  # goes to its terminal state immediately. The callback of the source or
  # sink runs in a task, and the caller gets its reply when the callback is
  # complete: `:ok`, or the value that the callback threw. A promise from
  # the callback is awaited. This is the rule of the Streams Standard.
  # A stream that closed with chunks in its queue is still readable, as in
  # the Streams Standard: a cancel discards the chunks, and calls the cancel
  # callback of the source.
  defp handle_common({:call, from}, {:terminate, type, reason}, state, data)
       when type in [:cancel, :abort] and state != :errored and
              (state != :closed or data.queue != {[], []}) do
    terminate_with_task(type, reason, from, data)
  end

  # The same, for a caller that does not wait for the callback: the halt of
  # an enumeration.
  defp handle_common({:call, from}, {:terminate_detached, :cancel, reason}, state, data) do
    if final?(state, data) do
      {:keep_state_and_data, [{:reply, from, :ok}]}
    else
      {:next_state, next_state, new_data, actions} =
        terminate_with_task(:cancel, reason, nil, data)

      {:next_state, next_state, new_data, [{:reply, from, :ok} | actions]}
    end
  end

  # ReadableStreamCancel: the cancel sets [[disturbed]], and the cancel of
  # an errored stream rejects with the error of the stream. The errored
  # state of a transform stream can come from its writable side, before the
  # readable side is errored: such a cancel has no effect.
  defp handle_common({:call, from}, {:terminate, :cancel, _reason}, :errored, data)
       when data.type == :producer do
    {:keep_state, %{data | disturbed: true}, [{:reply, from, {:error, data.error_reason}}]}
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

  # `error` of the controller of a writable stream, as
  # WritableStreamDefaultControllerError specifies: it has an effect only in
  # the state "writable". A write or a close that is in flight completes.
  defp handle_common(:cast, {:error, reason}, state, %{type: :consumer} = data) do
    if state in [:writable, :closing] do
      start_erroring(reason, data, [])
    else
      :keep_state_and_data
    end
  end

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
      state in [:errored, :erroring] ->
        send(waiter_pid, {:stream_error, ref, {:errored, data.error_reason}})
        :keep_state_and_data

      state == :closed and match?({:errored, _reason}, data.writable_error) ->
        {:errored, reason} = data.writable_error
        send(waiter_pid, {:stream_error, ref, {:errored, reason}})
        :keep_state_and_data

      owner_pid != data.writer_pid ->
        send(waiter_pid, {:stream_error, ref, :not_locked_by_writer})
        :keep_state_and_data

      state in [:closed, :closing] ->
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

  # The result of a callback while a public abort runs the listeners of the
  # signal: the stream handles it after the abort.
  defp handle_common(
         :info,
         {ref, _result} = message,
         _state,
         %{abort_window: %{} = window} = data
       )
       when is_reference(ref) and ref == data.task_ref do
    {:keep_state, %{data | abort_window: %{window | held: [message | window.held]}}}
  end

  # The reply of the readable side to the default transform. The tag of the
  # call names its sender: see `run_write_task/2`.
  defp handle_common(:info, {{@sent, _sender, ref}, result}, state, data)
       when is_reference(ref),
       do: handle_common(:info, {ref, result}, state, data)

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

  # The process of the other side of a transform stream stopped: its lock
  # does not keep this side. The default transform that it did not answer
  # fails: see `run_write_task/2`. A side that asked for the end of the two
  # sides gets no answer: it ends, as the other side has no lock. See "The
  # lock rule of the two sides".
  defp handle_common(
         :info,
         {:DOWN, ref, :process, _pid, _reason},
         state,
         %{transform: %{peer_ref: ref}} = data
       )
       when is_reference(ref) do
    data = put_transform(data, peer_ref: nil, peer_locked: false)

    result =
      case data.active_task do
        %{enqueue: true, ref: task} ->
          handle_common(:info, {task, {:error, enqueue_refusal_error(:closed)}}, state, data)

        _other ->
          {:keep_state, data}
      end

    if data.transform.ending, do: end_after_answer(result, state, data), else: result
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

  # The source process stopped. Before the end of the stream, the chunks
  # are not complete: the stream goes to the errored state. A byte stream
  # with a close request has all its chunks: it closes when a read takes
  # the last bytes of its queue.
  defp handle_common(
         :info,
         {:DOWN, ref, :process, _pid, reason},
         state,
         %{source_watch: {ref, error_fun}} = data
       ) do
    data = %{data | source_watch: nil}

    if state == :readable and not match?(%{bytes: %{close_requested: true}}, data) do
      fail_stream(error_fun.(reason), data)
    else
      {:keep_state, data}
    end
  end

  defp handle_common(:info, {:DOWN, ref, :process, _pid, reason}, state, data) do
    cond do
      is_map_key(data.keepers, ref) ->
        {:keep_state, %{data | keepers: Map.delete(data.keepers, ref)}}

      ref == data.reader_ref ->
        maybe_cancel_on_reader_exit(reason, state, data)

      ref == data.writer_ref ->
        {:keep_state,
         %{data | writer_pid: nil, writer_ref: nil, writer_ready: nil, writer_closed: nil}}

      ref == data.task_ref ->
        task_down(reason, state, data)

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
      owner_rule(data)
    end
  end

  defp handle_common(_type, _content, _state, _data), do: :not_handled

  # The process of a callback stopped with no result.
  defp task_down(_reason, _state, %{active_operation: :abort} = data) do
    {:keep_state, clear_active_operation(data), abort_reply_actions(data, :ok)}
    |> clear_abort_request()
  end

  # The source process of a direct pull stopped with no failure before its
  # answer, for example an enumerator that got `:stop`: the source has no
  # more chunks.
  defp task_down(reason, state, %{active_task: %{external: true}} = data)
       when reason in [:normal, :noproc] do
    data = data |> clear_active_operation() |> Map.put(:pulling, false)
    if state == :readable, do: handle_producer_close(data), else: {:keep_state, data}
  end

  defp task_down(:normal, _state, _data), do: :keep_state_and_data
  defp task_down(reason, _state, data), do: fail_stream(reason, data)

  # `enqueue` of a controller. The size function of the user must run in the
  # process that enqueues, as in the Streams Standard: the function can
  # call the stream, and this process must be free to answer. Thus the
  # reply `{:size, size}` gives the function to the caller, which calls it
  # and sends `{:enqueue_sized, chunk, result}`. A read that waits takes the
  # chunk with no call of the size function.
  defp controller_enqueue(from, chunk, _state, %{stream_type: :default} = data) do
    if is_function(data.readable_size) and :queue.is_empty(data.read_requests) do
      {:keep_state_and_data, [{:reply, from, {:size, data.readable_size}}]}
    else
      case enqueue_default(chunk, data) do
        {:ok, data} ->
          enqueued(data, [{:reply, from, :ok}])

        # The size of the chunk is not valid.
        {:error, reason} ->
          data = transform_error_writable(data, reason)
          fail_stream_for_caller(reason, from, data, [size_error_reply(from, reason, reason)])
      end
    end
  end

  # The steps of ReadableStreamDefaultControllerEnqueue after the size
  # function. The function can change the stream. A chunk with a valid size
  # goes to the end of the queue, also when a read waits. A chunk for a
  # stream that is closed or errored has no effect. A size that is not valid
  # puts a readable stream in the errored state. The caller gets the error
  # of the size and the error of the stream: see `size_error_reply/3`.
  defp enqueue_sized(from, chunk, result, state, data) do
    case QueuingStrategy.validate(result) do
      {:ok, size} ->
        if readable_side_open?(state, data) do
          data
          |> put_chunk(chunk, size)
          |> refresh_backpressure()
          |> enqueued([{:reply, from, :ok}])
        else
          {:keep_state_and_data, [{:reply, from, :ok}]}
        end

      # TransformStreamDefaultControllerEnqueue: the writable side of a
      # transform stream gets the error of the size, also when the readable
      # side is not readable.
      {:error, reason} ->
        data = transform_error_writable(data, reason)

        cond do
          readable_side_open?(state, data) ->
            fail_stream_for_caller(reason, from, data, [size_error_reply(from, reason, reason)])

          state == :errored ->
            {:keep_state, data, [size_error_reply(from, reason, data.error_reason)]}

          true ->
            {:keep_state, data, [size_error_reply(from, reason, reason)]}
        end
    end
  end

  # The reply for a size that is not valid. The controller of a readable
  # stream throws the error of the size. The controller of a transform
  # stream throws the error of the readable side: the size function can put
  # the stream in the errored state before it fails.
  defp size_error_reply(from, reason, stored) do
    {:reply, from, {:error, {:size, reason, stored}}}
  end

  # The readable side is in the state "readable" of the Streams Standard. A
  # stream that closed with chunks in its queue is still readable. The
  # `terminate` of a transformer closes the readable side at once when its
  # queue is empty, also while a write is in progress.
  defp readable_side_open?(:readable, _data), do: true

  defp readable_side_open?(state, data) when state in [:writable, :closing],
    do: not (data.terminated and :queue.is_empty(data.queue))

  defp readable_side_open?(:closed, data), do: not :queue.is_empty(data.queue)
  defp readable_side_open?(_errored, _data), do: false

  # Why the readable side cannot accept an `enqueue` or a `close`, or `nil`.
  defp controller_refusal(_state, %{type: :consumer}), do: :closed
  defp controller_refusal(:errored, _data), do: :errored
  defp controller_refusal(:closed, _data), do: :closed
  defp controller_refusal(_state, %{terminated: true}), do: :closed
  defp controller_refusal(_state, _data), do: nil

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

  # [[PullSteps]] of the controller of a byte stream.
  defp handle_read_request(from, _pid, :readable, %{bytes: %ByteStreamController{}} = data) do
    data
    |> Map.put(:disturbed, true)
    |> ByteStreamController.pull_steps(from)
    |> byte_result()
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

    case data do
      %{transform: %{side: :readable}} -> {:keep_state, transform_pull(data), waiter_actions}
      _other -> {:keep_state, data, [{:next_event, :internal, :maybe_pull} | waiter_actions]}
    end
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
       when pid == data.reader_pid and data.reader_mode != :byob and state != :errored and
              is_nil(data.bytes) do
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
    {chunks, queue, total} = take_chunks(data.queue, max, data, [], data.total_queued_size)
    new_data = %{data | queue: queue, total_queued_size: total}
    actions = [{:reply, from, {:chunks, chunks}}]
    {new_data, actions} = maybe_refresh_read_actions(new_data, actions)
    {:keep_state, new_data, maybe_request_pull(new_data, actions)}
  end

  # Each chunk is one DequeueValue: the total decreases one chunk at a time.
  defp take_chunks(queue, 0, _data, chunks, total), do: {Enum.reverse(chunks), queue, total}

  defp take_chunks(queue, count, data, chunks, total) do
    case :queue.out(queue) do
      {{:value, chunk}, rest} ->
        take_chunks(
          rest,
          count - 1,
          data,
          [default_read_chunk(data, chunk) | chunks],
          QueuingStrategy.subtract(total, queue_chunk_size(data, chunk))
        )

      {:empty, queue} ->
        {Enum.reverse(chunks), queue, total}
    end
  end

  defp pop_queued_chunk(from, data) do
    {{:value, chunk}, new_queue} = :queue.out(data.queue)

    new_data = %{
      data
      | queue: new_queue,
        total_queued_size:
          QueuingStrategy.subtract(data.total_queued_size, queue_chunk_size(data, chunk))
    }

    actions = [{:reply, from, {:ok, default_read_chunk(data, chunk)}}]
    {new_data, actions} = maybe_refresh_read_actions(new_data, actions)
    {:keep_state, new_data, maybe_request_pull(new_data, actions)}
  end

  defp default_read_chunk(_data, {chunk, _size}), do: chunk

  # ReadableStreamBYOBReaderRead. An error releases the lock, thus the
  # errored state comes before the lock checks.
  defp handle_byob_read_request(from, _pid, _view, _min, :errored, data) do
    disturbed_data = %{data | disturbed: true}
    {:keep_state, disturbed_data, [{:reply, from, {:error, {:errored, data.error_reason}}}]}
  end

  defp handle_byob_read_request(from, pid, view, min, state, data)
       when pid == data.reader_pid and data.reader_mode == :byob do
    data
    |> Map.put(:disturbed, true)
    |> ByteStreamController.pull_into(state, from, view, min)
    |> byte_result()
  end

  defp handle_byob_read_request(from, _pid, _view, _min, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_reader}}]}
  end

  # The requests of the controller of a byte stream and of its BYOB request.
  defp handle_byte_request(from, request, state, data) do
    case request do
      {:enqueue_bytes, chunk} ->
        ByteStreamController.enqueue(data, state, chunk, from)

      {:close_bytes} ->
        ByteStreamController.close(data, state, from)

      {:byob_request} ->
        ByteStreamController.byob_request(data, from)

      {:byob_request_view, id} ->
        byob_request_view(data, from, id)

      {:byob_respond, id, bytes_written, view} ->
        ByteStreamController.respond(data, state, from, id, bytes_written, view)

      {:byob_respond_with_new_view, id, view} ->
        ByteStreamController.respond_with_new_view(data, state, from, id, view)
    end
    |> byte_result()
  end

  defp byob_request_view(data, from, id) do
    {data, [{:reply, from, ByteStreamController.current_request?(data, id)}], :none}
  end

  # Applies the result of an operation of the controller of a byte stream.
  # A read that takes bytes from the queue lets a source that waits for
  # capacity continue.
  defp byte_result({data, actions, transition}) do
    {data, actions} = maybe_refresh_read_actions(data, actions)

    case transition do
      :none -> {:keep_state, data, actions}
      :close -> handle_producer_close(data, actions)
      {:error, reason} -> fail_stream(reason, data, actions)
    end
  end

  # The read requests of the reader of a byte stream that releases its lock.
  defp release_byte_reader(%{bytes: %ByteStreamController{}} = data),
    do: ByteStreamController.release(data)

  defp release_byte_reader(data), do: {data, []}

  # The read-into requests of a byte stream that is cancelled or errored.
  defp settle_byte_requests(%{bytes: %ByteStreamController{}} = data, :done),
    do: ByteStreamController.cancel(data)

  defp settle_byte_requests(%{bytes: %ByteStreamController{}} = data, {:error, reason}),
    do: ByteStreamController.error(data, reason)

  defp settle_byte_requests(data, _reply), do: {data, []}

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

  # A chunk of a byte stream from the code of this library: a binary or a
  # `Web.Uint8Array`. A chunk that the stream refuses is discarded.
  defp handle_producer_enqueue(chunk, state, %{bytes: %ByteStreamController{}} = data) do
    chunk = if is_binary(chunk), do: Web.Uint8Array.from(chunk), else: chunk

    data
    |> ByteStreamController.enqueue(state, chunk, nil)
    |> byte_result()
  end

  # ReadableStreamDefaultControllerEnqueue. A read that waits gets the chunk
  # with no call of the size algorithm. Each other chunk goes to the end of
  # the queue with its size. A size that is not valid puts the stream in
  # the errored state.
  defp handle_producer_enqueue(chunk, _state, %{stream_type: :default} = data) do
    case enqueue_default(chunk, data) do
      {:ok, data} -> enqueued(data, [])
      {:error, reason} -> fail_stream(reason, transform_error_writable(data, reason))
    end
  end

  defp enqueue_default(chunk, data) do
    case :queue.out(data.read_requests) do
      {{:value, from}, requests} ->
        :gen_statem.reply(from, {:ok, chunk})
        {:ok, refresh_backpressure(%{data | read_requests: requests})}

      {:empty, _requests} ->
        case QueuingStrategy.chunk_size(data.readable_size, chunk) do
          {:ok, size} -> {:ok, data |> put_chunk(chunk, size) |> refresh_backpressure()}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # The close of a source that is a process. A byte stream closes when a
  # read takes the last bytes of its queue.
  defp handle_source_close(%{bytes: %ByteStreamController{}} = data) do
    data |> ByteStreamController.close(:readable, nil) |> byte_result()
  end

  defp handle_source_close(data), do: handle_producer_close(data)

  defp handle_producer_close(data, actions \\ []) do
    {:next_state, :closed, %{data | pulling: false},
     actions ++ [{:next_event, :internal, :flush_requests}]}
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

  # ReadableStreamDefaultControllerCallPullIfNeeded of the Streams Standard:
  # the stream pulls when its queue is below its limit, or when a read
  # waits (ShouldCallPull). It does not pull before the function `start` is
  # complete. A request that comes during a pull, when the stream wants a
  # chunk, causes one more pull after it. Thus a source whose pull gives no
  # chunk immediately is not pulled again and again.
  defp handle_maybe_pull(data) do
    cond do
      # ShouldCallPull is false before the end of `start`, and when the
      # stream wants no chunk: no pull follows, also after a pull.
      data.active_operation == :init -> :keep_state_and_data
      not readable_wants_chunk?(data) -> :keep_state_and_data
      data.pulling -> {:keep_state, %{data | pull_again: true}}
      true -> do_trigger_pull(data)
    end
  end

  defp readable_wants_chunk?(%{bytes: %ByteStreamController{}} = data),
    do: ByteStreamController.should_pull?(data)

  defp readable_wants_chunk?(data) do
    QueuingStrategy.positive?(readable_capacity(data)) or not :queue.is_empty(data.read_requests)
  end

  # The actions after a pull is complete.
  defp after_pull_actions(%{pull_again: true}), do: [{:next_event, :internal, :maybe_pull}]
  defp after_pull_actions(_data), do: []

  # TransformStreamDefaultSourcePullAlgorithm: the pull of the readable side
  # of a transform stream ends the backpressure. The Standard gives the next
  # change of the backpressure as the result of the pull. Here the pull is
  # complete at once: a pull while the backpressure is off has no effect.
  defp do_trigger_pull(%{transform: %{side: :readable}} = data) do
    {:keep_state, transform_backpressure(data, false)}
  end

  defp do_trigger_pull(%{module: module, impl_state: impl_state} = data) do
    case data.direct_pull do
      {:message, pid, message} ->
        send(pid, message)
        :keep_state_and_data

      {:pid_source, pid} ->
        send(pid, {:pull, self()})
        :keep_state_and_data

      # The source process answers this process directly: the pull costs
      # two messages, and no worker runs. The source enqueues before its
      # answer, thus the stream gets the chunk while it pulls, as in the
      # Streams Standard.
      {:process, pid} ->
        ref = Process.monitor(pid)
        send(pid, {:web_stream_pull, ref, self()})
        task = %{ref: ref, pid: pid, external: true}
        {:keep_state, set_active_task(data, task, :pull, pulling: true)}

      nil ->
        trigger_pull_task(module, impl_state, data)
    end
  end

  defp trigger_pull_task(module, impl_state, data) do
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

  # A write with no size from the writer: the stream calls the size
  # algorithm. See `__writable_size__/1`.
  defp handle_write(from, pid, chunk, state, data) do
    handle_write(from, pid, chunk, QueuingStrategy.call(data.writable_size, chunk), state, data)
  end

  defp handle_write(from, pid, chunk, size_result, _state, data) do
    cond do
      pid != data.writer_pid ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}

      data.terminated ->
        {:keep_state_and_data, [{:reply, from, {:error, {:errored, terminated_error()}}}]}

      true ->
        accept_write(from, pid, chunk, QueuingStrategy.validate(size_result), size_result, data)
    end
  end

  # WritableStreamDefaultControllerGetChunkSize: a size function that throws
  # starts the error of the stream (WritableStreamDefaultControllerErrorIfNeeded).
  # The write rejects with that error at once.
  defp accept_write(
         from,
         _pid,
         _chunk,
         {:error, reason},
         {:thrown, _, _, _},
         %{type: :consumer} = data
       ),
       do: start_erroring(reason, data, [{:reply, from, {:error, {:errored, reason}}}])

  # WritableStreamDefaultControllerWrite: a size that is not valid
  # (EnqueueValueWithSize) starts the error after the write request is in
  # the queue. The write rejects when the error is complete. A write in
  # flight completes first.
  defp accept_write(from, pid, chunk, {:error, reason}, _result, %{type: :consumer} = data),
    do: data |> enqueue_write_request({from, pid, chunk}) |> then(&start_erroring(reason, &1, []))

  # The writable side of a stream of the type `:producer_consumer`.
  defp accept_write(from, _pid, _chunk, {:error, reason}, _result, data) do
    fail_stream(reason, data, [{:reply, from, {:error, {:errored, reason}}}])
  end

  defp accept_write(from, pid, chunk, {:ok, size}, _result, data) do
    data = add_write_size(data, size)

    if active_consumer_operation?(data) or not transform_ready?(data) do
      new_data =
        data
        |> enqueue_write_request({from, pid, chunk})
        |> refresh_backpressure()

      {:keep_state, new_data}
    else
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

  # WritableStreamClose: the close fulfils the promise `ready`, and waits for
  # the writes before it.
  defp handle_close(from, pid, _state, data) do
    cond do
      pid != data.writer_pid ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}

      data.pending_close_request ->
        {:keep_state_and_data, [{:reply, from, {:error, :closing}}]}

      active_consumer_operation?(data) or not :queue.is_empty(data.queued_write_requests) ->
        {:next_state, :closing, %{release_ready_waiters(data) | pending_close_request: from}}

      true ->
        data
        |> release_ready_waiters()
        |> Map.put(:pending_close_request, from)
        |> start_flush_task()
    end
  end

  # The processes that wait for the promise `ready` get their answer now.
  defp release_ready_waiters(data) do
    {data, actions} = maybe_resolve_ready_waiters(data, force?: true)
    Enum.each(actions, fn {:reply, from, reply} -> :gen_statem.reply(from, reply) end)
    data
  end

  defp handle_abort(from, pid, _reason, _state, data) when pid != data.writer_pid do
    {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
  end

  defp handle_abort(from, _pid, reason, state, %{type: :consumer} = data) do
    writable_abort(from, reason, state, data)
  end

  # The writable side of a transform stream.
  defp handle_abort(from, _pid, reason, _state, data) do
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

  # ---------------------------------------------------------------------------
  # The error of a writable stream
  #
  # The abort and the error of a WritableStream, as the Streams Standard
  # specifies. They do not stop a write or a close that is in flight: the
  # stream is "erroring" until the operation is complete, and then
  # "errored". The writes that wait reject with the stored error. Then the
  # abort callback of the sink runs, for an abort.
  # ---------------------------------------------------------------------------

  # WritableStreamAbort. All the callers of an abort get the same result.
  # An abort with no caller has the caller `nil`.
  defp writable_abort(from, reason, state, data) do
    data = abort_signal(data, reason)

    cond do
      data.abort_request ->
        {callers, abort_reason, was_already_erroring} = data.abort_request

        {:keep_state,
         %{data | abort_request: {List.wrap(from) ++ callers, abort_reason, was_already_erroring}}}

      state == :erroring ->
        {:keep_state, %{data | abort_request: {List.wrap(from), nil, true}}}

      true ->
        start_erroring(reason, %{data | abort_request: {List.wrap(from), reason, false}}, [])
    end
  end

  # WritableStreamStartErroring.
  defp start_erroring(reason, data, actions) do
    data = %{data | error_reason: reason}
    ready_actions = ready_error_actions(data, reason)
    data = %{data | ready_waiters: :queue.new(), backpressure: false}

    if operation_in_flight?(data) or data.active_operation == :start do
      {:next_state, :erroring, data, actions ++ ready_actions}
    else
      finish_erroring(data, actions ++ ready_actions)
    end
  end

  # WritableStreamHasOperationMarkedInFlight.
  defp operation_in_flight?(data) do
    not is_nil(data.pending_write_request) or match?({:flush, _from}, data.active_operation)
  end

  # WritableStreamDefaultControllerAdvanceQueueIfNeeded and
  # WritableStreamDealWithRejection: a failure in the state "writable" starts
  # the error. In the state "erroring", the error is complete.
  defp consumer_failure(reason, state, data) do
    {data, actions} =
      case data.active_operation do
        {:write, from} ->
          {%{data | pending_write_request: nil}, [{:reply, from, {:error, {:errored, reason}}}]}

        # WritableStreamFinishInFlightCloseWithError: the abort request
        # rejects with the failure of the close.
        {:flush, from} ->
          {data, abort_actions} = settle_abort_request(data, {:error, reason})

          {%{data | pending_close_request: nil},
           [{:reply, from, {:error, {:errored, reason}}} | abort_actions]}

        :start ->
          {data, []}
      end

    data = clear_active_operation(data)

    if state == :erroring,
      do: finish_erroring(data, actions),
      else: start_erroring(reason, data, actions)
  end

  # WritableStreamFinishErroring. The promise `closed` of the writer rejects
  # in the state `errored` with no abort callback in flight: see
  # `closed_waiter_actions/2`.
  defp finish_erroring(data, actions) do
    reason = data.error_reason
    write_actions = queued_write_error_actions(data, reason)
    abort_request = data.abort_request

    data = %{
      data
      | queued_write_requests: :queue.new(),
        queued_write_count: 0,
        backpressure: false,
        abort_request: nil
    }

    case abort_request do
      # The abort of the sink runs. The callers get its result.
      {callers, abort_reason, false} ->
        data =
          data
          |> Map.put(:pending_abort_request, callers)
          |> start_terminal_task(:abort, abort_reason)

        {:next_state, :errored, data, actions ++ write_actions}

      other ->
        abort_actions =
          case other do
            {callers, _reason, true} -> Enum.map(callers, &{:reply, &1, {:error, reason}})
            nil -> []
          end

        {data, close_actions} = reject_close_request(data)
        {:next_state, :errored, data, actions ++ write_actions ++ abort_actions ++ close_actions}
    end
  end

  # WritableStreamRejectCloseAndClosedPromiseIfNeeded, for the close request.
  defp reject_close_request(%{pending_close_request: nil} = data), do: {data, []}

  defp reject_close_request(%{pending_close_request: from} = data) do
    {%{data | pending_close_request: nil},
     [{:reply, from, {:error, {:errored, data.error_reason}}}]}
  end

  # The callers of an abort request get `reply`.
  defp settle_abort_request(%{abort_request: {callers, _reason, _erroring}} = data, reply) do
    {%{data | abort_request: nil}, Enum.map(callers, &{:reply, &1, reply})}
  end

  defp settle_abort_request(data, _reply), do: {data, []}

  # ---------------------------------------------------------------------------
  # The abort action of a pipe
  #
  # The abort algorithm of the signal of ReadableStreamPipeTo has two actions
  # in a sequence: WritableStreamAbort of the destination, and then
  # ReadableStreamCancel of the source. In JavaScript, WritableStreamAbort
  # calls the abort callback of the sink before it returns, when the stream
  # started and has no write or close in flight. Thus the sink gets its
  # abort before the source gets its cancel.
  #
  # The callbacks of the two streams run in two workers. Thus the pipe sends
  # the cancel only when the destination tells it that WritableStreamAbort
  # did the steps that JavaScript does before it returns. The destination
  # sends `{:abort_steps_done, tag}`, with the tag of the request:
  #
  #   * at once, when the abort callback does not run now. For example, the
  #     stream did not start, or a write or a close is in flight;
  #   * when the abort callback returned a value, also a promise that is
  #     pending. The worker tells the stream, and the stream tells the pipe.
  #     Thus the notice comes before the reply of the abort: one process
  #     sends the two messages.
  #
  # The reply of the abort without a notice tells the pipe the same, and no
  # notice comes after it. For example, the callback threw before it
  # returned, or the destination is not writable.
  # ---------------------------------------------------------------------------

  defp send_abort_notice(%{abort_notice: nil} = data), do: data

  defp send_abort_notice(%{abort_notice: {pid, tag}} = data) do
    send(pid, {:abort_steps_done, tag})
    %{data | abort_notice: nil}
  end

  # ---------------------------------------------------------------------------
  # The two sides of a transform stream
  #
  # A `Web.TransformStream` has two stream processes, as in the Streams
  # Standard: a readable side (`:producer`) and a writable side
  # (`:consumer`), each with its own state. The field `transform` of each
  # process has the slots of the transform stream that the side needs:
  #
  #   * [[backpressure]] of the Standard is one `:atomics` cell that the two
  #     sides share. Its value is `@backpressure_off`, `@backpressure_on`, or
  #     `@backpressure_held`: the backpressure is on, and the writable side
  #     holds a write.
  #   * The readable side changes the backpressure: an enqueue turns it on,
  #     and a pull turns it off. A pull that finds a held write sends
  #     `{:transform_backpressure, false}` to the writable side.
  #   * The writable side reads the cell before the transform of each write.
  #     When the backpressure is on, it holds the write, until the message
  #     comes: see `start_write_task/2`. Thus a change of the backpressure
  #     costs no message, and a held write costs one message.
  #   * A transformer with no function `transform` has the default
  #     transform: an enqueue on the readable side, with no code of the
  #     user. The writable side sends it to the readable side, with no
  #     worker: see `run_write_task/2`.
  #   * The readable side has [[finishPromise]] of the Standard. It makes
  #     sure that only one of flush, an abort, and a cancel calls the
  #     transformer. The callback of each one runs in the worker of its side,
  #     and asks the readable side first: see `Web.TransformStream`.
  #
  # Each change of the cell is one atomic operation. The hold of a write
  # changes "on" to "held" in one step, and a pull changes each value to
  # "off" in one step. Thus the two steps cannot both miss the other: if the
  # pull comes first, the writable side finds "off" and does not hold the
  # write. If the hold comes first, the pull finds "held" and sends the
  # message. See `tla/TransformStream.tla`.
  #
  # A stream process never waits for the other stream process. The reply of
  # the default transform comes to the writable side as a usual message.
  # Only the workers wait for the replies of the two processes.
  #
  # Each message between the two processes names its sender: see "Priority
  # messages". Thus a priority message of one side does not pass the usual
  # messages that the side sent before it.
  #
  # The lock rule of the two sides
  #
  # For the lifetime rules, the two sides are one stream: a lock of one side
  # keeps the two sides. Each side keeps a copy of the lock of the other
  # side: see `notify_peer_lock/2`. The copy can be late, because a lock of
  # the other side can be in a message. Thus an active side that the owner
  # rule ends asks the other side first, and the other side decides in its
  # own process (the handshake):
  #
  #   1. At the end of its linger time, the side sends
  #      `{:transform_end, :ask, reason}`. Until the answer, it grants no
  #      lock: a request for a lock waits in the side.
  #   2. The other side answers `:denied` when it has a lock. Else it ends
  #      by the owner rule, and answers `:agreed`. A complete side agrees.
  #   3. The side ends when the other side agrees, or when the other side
  #      stopped. After a denial it stays: the lock message came before the
  #      denial, thus its copy keeps it until that lock changes.
  #
  # Thus a side ends by the owner rule only when no lock of the two sides
  # exists. Each request and each answer is a usual message, and each side
  # handles each message: no side waits for the other side. See
  # `tla/TransformLifetime.tla`.
  # ---------------------------------------------------------------------------

  @backpressure_off 0
  @backpressure_on 1
  @backpressure_held 2

  @doc false
  # InitializeTransformStream: the cell of [[backpressure]] for the two sides
  # of a new transform stream. The backpressure is on.
  def __transform_cell__ do
    cell = :atomics.new(1, signed: false)
    :atomics.put(cell, 1, @backpressure_on)
    cell
  end

  # `ending` is `true` while the side waits for the answer of the
  # handshake, and `deferred` has the requests for a lock that wait.
  defp transform_side({:readable, writable, cell}) do
    %{
      side: :readable,
      peer: writable,
      peer_ref: Process.monitor(writable),
      peer_locked: false,
      ending: false,
      deferred: [],
      cell: cell,
      finish: nil,
      cleared: false
    }
  end

  # `enqueue` is `true` for the default transform.
  defp transform_side({:writable, cell, enqueue}) do
    %{
      side: :writable,
      peer: nil,
      peer_ref: nil,
      peer_locked: false,
      ending: false,
      deferred: [],
      cell: cell,
      enqueue: enqueue
    }
  end

  defp transform_side(nil), do: nil

  defp put_transform(%{transform: transform} = data, changes) do
    %{data | transform: Map.merge(transform, Map.new(changes))}
  end

  # The owner rule for a stream that is not complete, at the end of its
  # linger time. An active side of a transform stream asks the other side
  # first: see "The lock rule of the two sides".
  defp owner_rule(%{transform: %{peer_ref: ref} = transform} = data) when is_reference(ref) do
    control_cast(transform.peer, {:transform_end, :ask, data.owner_down_reason})
    {:keep_state, put_transform(data, ending: true)}
  end

  defp owner_rule(data), do: owner_rule_end(data)

  # The stream process of a stream with no process that no read disturbed:
  # its bytes stay in the struct, or with the process that holds them. The
  # process stops with no cancel, and the next reader gets the bytes. See
  # `Web.Internal.LazyStream`.
  defp owner_rule_end(%{lazy_key: key, disturbed: false} = data) when key != nil,
    do: {:stop, :normal, data}

  # No process can read the chunks in the queue. Discard them, thus the
  # stream stops immediately after the terminal event.
  defp owner_rule_end(data) do
    data = %{data | queue: :queue.new(), total_queued_size: 0}
    handle_termination(owner_down_type(data), data.owner_down_reason, data)
  end

  # The end of a side by the owner rule, after the handshake. A complete
  # side has no work. A closed side with chunks discards them, as a cancel.
  defp owner_rule_finish(state, data),
    do: if(final?(state, data), do: {:keep_state, data}, else: owner_rule_end(data))

  # The handshake is complete: the requests for a lock that waited come
  # now, in their sequence.
  defp end_after_answer(result, state, data) do
    {next_state, new_data, actions} = transition(result, state, data)
    deferred = Enum.reverse(new_data.transform.deferred)
    events = for {type, content} <- deferred, do: {:next_event, type, content}

    {:next_state, next_state, put_transform(new_data, ending: false, deferred: []),
     actions ++ events}
  end

  # TransformStreamSetBackpressure, on the readable side. The backpressure
  # turns on only when it is off. A held write gets the end of the
  # backpressure as a message.
  defp transform_backpressure(%{transform: %{cell: cell}} = data, true) do
    _ = :atomics.compare_exchange(cell, 1, @backpressure_off, @backpressure_on)
    data
  end

  defp transform_backpressure(%{transform: %{cell: cell} = transform} = data, false) do
    if :atomics.exchange(cell, 1, @backpressure_off) == @backpressure_held do
      control_cast(transform.peer, {:transform_backpressure, false})
    end

    data
  end

  # The first steps of TransformStreamDefaultSinkWriteAlgorithm: `true` when
  # the write must wait for the end of the backpressure. The writable side
  # marks its hold in the same atomic step.
  defp transform_hold?(cell) do
    case :atomics.compare_exchange(cell, 1, @backpressure_on, @backpressure_held) do
      :ok -> true
      value -> value == @backpressure_held
    end
  end

  # The last steps of ReadableStreamDefaultControllerEnqueue
  # (ReadableStreamDefaultControllerCallPullIfNeeded) and of
  # TransformStreamDefaultControllerEnqueue. The pull of the readable side of
  # a transform stream has no callback, thus it runs here, with no event:
  # see `do_trigger_pull/1`. After the pull, the readable side has
  # backpressure when it does not want more chunks.
  defp enqueued(%{transform: %{side: :readable}} = data, actions) do
    pull? = transform_should_pull?(data)
    {:keep_state, transform_backpressure(data, not pull?), actions}
  end

  defp enqueued(data, actions),
    do: {:keep_state, data, actions ++ [{:next_event, :internal, :maybe_pull}]}

  # ReadableStreamDefaultControllerCallPullIfNeeded for the readable side of
  # a transform stream, after a read that waits.
  defp transform_pull(data) do
    if transform_should_pull?(data), do: transform_backpressure(data, false), else: data
  end

  # ReadableStreamDefaultControllerShouldCallPull. The readable side is
  # readable here.
  defp transform_should_pull?(data),
    do: data.active_operation != :init and readable_wants_chunk?(data)

  # TransformStreamErrorWritableAndUnblockWrite, from the readable side. The
  # writable side does TransformStreamUnblockWrite.
  defp transform_error_writable(%{transform: %{side: :readable} = transform} = data, reason) do
    control_cast(transform.peer, {:transform_error_unblock, reason})
    put_transform(data, cleared: true)
  end

  defp transform_error_writable(data, _reason), do: data

  # The writable side learns the readable side. The worker gets it for its
  # calls to the readable side.
  defp handle_transform({:call, from}, {:transform_peer, readable}, _state, data) do
    data =
      %{data | impl_state: Map.put(data.impl_state, :peer, readable)}
      |> put_transform(peer: readable, peer_ref: Process.monitor(readable))

    {:keep_state, data, [{:reply, from, :ok}]}
  end

  defp handle_transform(:cast, {:transform_peer_locked, locked}, _state, data) do
    {:keep_state, put_transform(data, peer_locked: locked)}
  end

  # The end of the backpressure lets the held write continue.
  defp handle_transform(:cast, {:transform_backpressure, false}, state, data),
    do: release_held_write(state, data)

  # TransformStreamErrorWritableAndUnblockWrite, on the writable side:
  # WritableStreamDefaultControllerErrorIfNeeded and TransformStreamUnblockWrite.
  defp handle_transform(:cast, {:transform_error_unblock, reason}, state, data) do
    error_and_unblock(reason, state, data, [])
  end

  # The steps of TransformStreamDefaultSourceCancelAlgorithm on the writable
  # side, with no step between them.
  defp handle_transform({:call, from}, {:transform_error_if_needed, reason}, state, data) do
    if state == :errored,
      do: {:keep_state_and_data, [{:reply, from, {:errored, data.error_reason}}]},
      else: error_and_unblock(reason, state, data, [{:reply, from, :ok}])
  end

  # TransformStreamDefaultControllerError, on the readable side. The
  # controller sent the error to the writable side also.
  defp handle_transform(:cast, {:transform_error, reason}, state, data) do
    data = put_transform(data, cleared: true)
    if final?(state, data), do: {:keep_state, data}, else: fail_stream(reason, data)
  end

  # `Web.ReadableStream.error/2` on the readable side of a transform stream:
  # TransformStreamError.
  defp handle_transform(:cast, {:error, reason}, state, data) do
    handle_transform(
      :cast,
      {:transform_error, reason},
      state,
      transform_error_writable(data, reason)
    )
  end

  # TransformStreamDefaultControllerTerminate. The controller sent the error
  # to the writable side.
  defp handle_transform(:cast, :transform_terminate, state, data) do
    data = put_transform(data, cleared: true)

    if controller_refusal(state, data) == nil,
      do: handle_producer_close(data),
      else: {:keep_state, data}
  end

  # `close` of the controller of the readable side is a terminate. It
  # throws a `TypeError` when the readable side cannot close.
  defp handle_transform({:call, from}, :close, state, data) do
    case controller_refusal(state, data) do
      nil ->
        data
        |> transform_error_writable(terminated_error())
        |> handle_producer_close([{:reply, from, :ok}])

      refusal ->
        {:keep_state_and_data, [{:reply, from, {:error, refusal}}]}
    end
  end

  # The handshake of the lock rule: the other side asks for the end of the
  # two sides. This side decides in its own process: see "The lock rule of
  # the two sides". A lock of a complete side keeps nothing. The side that
  # asks gives the reason of the stop of the owner: this side can get its
  # own monitor message later.
  defp handle_transform(:cast, {:transform_end, :ask, reason}, state, data) do
    if own_lock?(data) and not final?(state, data) do
      control_cast(data.transform.peer, {:transform_end, :denied})
      {:keep_state, data}
    else
      control_cast(data.transform.peer, {:transform_end, :agreed})
      owner_rule_finish(state, %{data | owner_down_reason: data.owner_down_reason || reason})
    end
  end

  # The answer of the handshake.
  defp handle_transform(:cast, {:transform_end, :agreed}, state, data),
    do: end_after_answer(owner_rule_finish(state, data), state, data)

  defp handle_transform(:cast, {:transform_end, :denied}, state, data),
    do: end_after_answer({:keep_state, data}, state, data)

  # TransformStreamDefaultControllerPerformTransform with the default
  # transform, from the writable side: see `run_write_task/2`. The reply is
  # the result of the write. A failure is TransformStreamError: the readable
  # side gets the error, and the write rejects with it.
  defp handle_transform({:call, from}, {:transform_write, chunk}, state, data) do
    case controller_refusal(state, data) do
      nil ->
        case enqueue_default(chunk, data) do
          {:ok, data} ->
            enqueued(data, [{:reply, from, :ok}])

          # TransformStreamDefaultControllerEnqueue: the size is not valid.
          # The write rejects with the stored error of the readable side.
          {:error, reason} ->
            data = transform_error_writable(data, reason)
            fail_stream(reason, data, [{:reply, from, {:error, reason}}])
        end

      refusal ->
        error = enqueue_refusal_error(refusal)
        result = handle_transform(:cast, {:transform_error, error}, state, data)
        {next_state, data, actions} = transition(result, state, data)
        {:next_state, next_state, data, [{:reply, from, {:error, error}} | actions]}
    end
  end

  # [[finishPromise]]: the first request runs its callback. Each later
  # request gets the result of that callback.
  defp handle_transform({:call, from}, {:transform_finish, _kind}, _state, data) do
    case data.transform.finish do
      nil ->
        run = not data.transform.cleared
        data = put_transform(data, finish: {:pending, []}, cleared: true)
        {:keep_state, data, [{:reply, from, {:run, run}}]}

      {:pending, waiters} ->
        {:keep_state, put_transform(data, finish: {:pending, [from | waiters]})}

      {:settled, result} ->
        {:keep_state_and_data, [{:reply, from, {:done, result}}]}
    end
  end

  # The callback is complete: the steps after it, on the readable side.
  defp handle_transform({:call, from}, {:transform_finished, kind, outcome}, state, data) do
    {:pending, waiters} = data.transform.finish
    {result, transition} = finish_steps(kind, outcome, state, data)
    {next_state, data, actions} = transition(transition, state, data)
    replies = for waiter <- [from | waiters], do: {:reply, waiter, {:done, result}}
    data = put_transform(data, finish: {:settled, result})
    {:next_state, next_state, data, actions ++ replies}
  end

  # TransformStreamDefaultSinkCloseAlgorithm.
  defp finish_steps(:flush, :ok, :errored, data),
    do: {{:error, data.error_reason}, :keep_state_and_data}

  defp finish_steps(:flush, :ok, state, data) do
    if controller_refusal(state, data) == nil,
      do: {:ok, handle_producer_close(data)},
      else: {:ok, :keep_state_and_data}
  end

  # TransformStreamDefaultSinkAbortAlgorithm.
  defp finish_steps({:abort, _reason}, :ok, :errored, data),
    do: {{:error, data.error_reason}, :keep_state_and_data}

  defp finish_steps({:abort, reason}, :ok, state, data),
    do: {:ok, readable_error(reason, state, data)}

  # TransformStreamDefaultSourceCancelAlgorithm: the worker did the steps
  # on the writable side.
  defp finish_steps(:cancel, outcome, _state, _data), do: {outcome, :keep_state_and_data}

  # A flush or a cancel of the transformer that failed.
  defp finish_steps(_kind, {:error, reason}, state, data),
    do: {{:error, reason}, readable_error(reason, state, data)}

  # ReadableStreamDefaultControllerError: it has an effect only on a
  # readable side that is readable.
  defp readable_error(reason, state, data) do
    if final?(state, data), do: :keep_state_and_data, else: fail_stream(reason, data)
  end

  defp error_and_unblock(reason, state, data, actions) do
    result =
      if state in [:writable, :closing],
        do: start_erroring(reason, data, actions),
        else: {:keep_state, data, actions}

    # TransformStreamUnblockWrite: the held write continues. The writable
    # side is not writable after the error, thus it reads the cell of the
    # backpressure no more.
    {next_state, data, actions} = transition(result, state, data)
    {final_state, data, more} = transition(release_held_write(next_state, data), next_state, data)
    {:next_state, final_state, data, actions ++ more}
  end

  # The write in flight continues after the backpressure. The stream that
  # is erroring rejects it with the stored error, as
  # TransformStreamDefaultSinkWriteAlgorithm specifies.
  defp release_held_write(
         state,
         %{pending_write_request: {from, _pid, _chunk} = request, active_task: nil} = data
       )
       when data.active_operation == {:write, from} do
    if state == :erroring,
      do: consumer_failure(data.error_reason, state, data),
      else: {:keep_state, run_write_task(data, request)}
  end

  defp release_held_write(_state, data), do: {:keep_state, data}

  # ---------------------------------------------------------------------------
  # Consumer task starters
  # ---------------------------------------------------------------------------

  # TransformStreamDefaultSinkWriteAlgorithm: the write of the writable side
  # of a transform stream is in flight. With backpressure, it waits for the
  # end of the backpressure. It has no task until then: see
  # `release_held_write/2`.
  defp start_write_task(%{transform: %{side: :writable, cell: cell}} = data, request) do
    if transform_hold?(cell) do
      {from, _pid, _chunk} = request

      %{data | pending_write_request: request, active_operation: {:write, from}}
      |> refresh_backpressure()
    else
      run_write_task(data, request)
    end
  end

  defp start_write_task(data, request), do: run_write_task(data, request)

  # The default transform of a transform stream runs no code of the user.
  # Thus the writable side sends the enqueue to the readable side as a call,
  # with no worker, and gets the reply as the result of a callback. The
  # readable side answers at once. When the readable side stopped, the
  # enqueue fails, as an enqueue of a worker.
  defp run_write_task(%{transform: %{enqueue: true} = transform} = data, request) do
    {from, _pid, chunk} = request
    ref = make_ref()

    if transform.peer_ref,
      do:
        send(
          transform.peer,
          {:"$gen_call", {self(), {@sent, self(), ref}}, {:transform_write, chunk}}
        ),
      else: send(self(), {ref, {:error, enqueue_refusal_error(:closed)}})

    task = %{ref: ref, pid: transform.peer, external: true, enqueue: true}

    refresh_backpressure(%{
      data
      | pending_write_request: request,
        active_task: task,
        task_ref: ref,
        active_operation: {:write, from}
    })
  end

  defp run_write_task(data, request) do
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
  # The stream process must answer other processes while the listeners of
  # the signal run: the signal is aborted before the call returns, and a new
  # process runs the listeners. A public abort signals abort before it sends
  # the abort, thus this step has no effect then. A later public abort does
  # not ask for the state of the stream.
  defp abort_signal(%{abort_controller: %Web.AbortController{} = controller} = data, reason) do
    :ok = Web.AbortSignal.__signal_abort_later__(controller.signal, reason)
    Process.delete(@abort_signal_key)
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
    stream = self()
    notice = if type == :abort, do: data.abort_notice

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

            # The stream tells the pipe that waits: see "The abort action
            # of a pipe".
            if notice, do: send(stream, {:abort_callback_returned, notice})

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

    set_active_task(%{data | abort_notice: nil}, task, :abort)
  end

  # ---------------------------------------------------------------------------
  # Task result handling
  # ---------------------------------------------------------------------------

  # The transformer called `terminate`, and then its write failed. The
  # write rejects with the failure. A readable side with chunks in its queue
  # is still readable, and goes to the errored state (TransformStreamError).
  # Each other readable side stays closed, and the writable side has the
  # error of the terminate.
  defp handle_task_result(
         {:error, reason},
         _state,
         %{terminated: true, active_operation: {:write, from}} = data
       ) do
    data =
      data
      |> clear_active_operation()
      |> Map.put(:pending_write_request, nil)

    if :queue.is_empty(data.queue) do
      terminate_transform(data, [{:reply, from, {:error, {:errored, reason}}}])
    else
      fail_stream(reason, data, [{:reply, from, {:error, {:errored, reason}}}])
    end
  end

  defp handle_task_result({:error, reason}, state, %{type: :consumer} = data) do
    consumer_failure(reason, state, data)
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

  # The source process of a direct pull answered: see `__start__/3`.
  defp handle_task_result(:pulled, state, %{active_operation: :pull} = data) do
    handle_task_result({:ok, data.impl_state}, state, data)
  end

  # The readable side of a transform stream did the default transform: see
  # `run_write_task/2`.
  defp handle_task_result(:ok, state, %{active_operation: {:write, _from}} = data) do
    handle_task_result({:ok, data.impl_state}, state, data)
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
    |> remove_write_size()
    |> Map.put(:pending_write_request, nil)
    |> Map.put(:impl_state, new_impl_state)
    |> refresh_backpressure()
    |> continue_after_consumer_completion(state, [{:reply, from, :ok}])
  end

  # Flush task completed: WritableStreamFinishInFlightClose. A stream that
  # is erroring closes, and its abort request fulfils.
  defp handle_task_result(
         {:ok, new_impl_state},
         _state,
         %{active_operation: {:flush, from}} = data
       ) do
    {data, abort_actions} = settle_abort_request(data, :ok)

    data
    |> clear_active_operation()
    |> Map.merge(%{pending_close_request: nil, impl_state: new_impl_state, error_reason: nil})
    |> close_consumer_stream([{:reply, from, :ok} | abort_actions])
  end

  defp handle_abort_task_result(result, data) do
    reply = if match?({:error, _thrown}, result), do: result, else: :ok

    {:keep_state, data |> clear_active_operation() |> transformer_cancel_error(result),
     abort_reply_actions(data, reply)}
    |> clear_abort_request()
  end

  # The function `cancel` of a transformer failed. The other side of the
  # stream gets that error, as TransformStreamDefaultSourceCancelAlgorithm
  # and TransformStreamDefaultSinkAbortAlgorithm specify: the writable side
  # after a cancel of the readable side, and the readable side after an
  # abort of the writable side.
  defp transformer_cancel_error(%{type: :producer_consumer} = data, {:error, thrown}) do
    case data.writable_error do
      {:errored, _reason} -> %{data | writable_error: {:errored, thrown}}
      nil -> %{data | error_reason: thrown}
    end
  end

  defp transformer_cancel_error(data, _result), do: data

  # The callers of an abort. The abort of a writable stream can have more
  # than one caller: see `writable_abort/4`.
  defp abort_reply_actions(%{pending_abort_request: nil}, _reply), do: []

  defp abort_reply_actions(%{pending_abort_request: callers}, reply) when is_list(callers),
    do: Enum.map(callers, &{:reply, &1, reply})

  defp abort_reply_actions(%{pending_abort_request: from}, reply), do: [{:reply, from, reply}]

  # The abort callback of a writable stream is complete: the close request
  # rejects with the stored error, as WritableStreamFinishErroring specifies.
  # Then the promise `closed` rejects: see `closed_waiter_actions/2`.
  defp clear_abort_request({:keep_state, %{type: :consumer} = data, actions}) do
    {data, close_actions} = reject_close_request(data)
    {:keep_state, %{data | pending_abort_request: nil}, actions ++ close_actions}
  end

  defp clear_abort_request({:keep_state, data, actions}) do
    {:keep_state, %{data | pending_abort_request: nil}, actions}
  end

  # WritableStreamDefaultControllerAdvanceQueueIfNeeded: the operation in
  # flight is complete, thus the error of the stream is complete.
  defp continue_after_consumer_completion(data, :erroring, actions),
    do: finish_erroring(data, actions)

  defp continue_after_consumer_completion(data, state, actions) do
    cond do
      # The transformer called `terminate` during this write.
      data.terminated ->
        terminate_transform(data, actions)

      # The next write waits for the readable side of a transform stream.
      not :queue.is_empty(data.queued_write_requests) and not transform_ready?(data) ->
        {:keep_state, data, actions}

      not :queue.is_empty(data.queued_write_requests) ->
        start_next_write(data, state, actions)

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

  # The next write starts. The promise `ready` fulfils when the queue is
  # below its limit, also when it is not empty.
  defp start_next_write(data, state, actions) do
    {request, data} = dequeue_write_request(data)
    new_data = start_write_task(data, request)

    {new_data, ready_actions} =
      if state == :writable, do: maybe_resolve_ready_waiters(new_data), else: {new_data, []}

    {:keep_state, new_data, actions ++ ready_actions}
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

  # The error of an enqueue that the readable side cannot accept, as
  # `Web.ReadableStream.controller_enqueue/3` raises it.
  defp enqueue_refusal_error(refusal) do
    Web.TypeError.exception("Cannot enqueue a chunk: the stream is #{refusal}.")
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

    {data, pending_byob_actions} = settle_byte_requests(data, {:error, reason})

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

  # An error that the callback that runs causes, for example with a size
  # that is not valid. The callback continues, as in the Streams Standard,
  # and gets the reply. Its result has no effect.
  defp fail_stream_for_caller(reason, {caller, _tag}, data, actions) do
    case data.active_task do
      %{pid: ^caller} when data.active_operation != :abort ->
        fail_stream(reason, clear_active_operation(data), actions)

      _other ->
        fail_stream(reason, data, actions)
    end
  end

  defp clear_writer_lock(%{writer_ref: writer_ref} = data) do
    if writer_ref, do: Process.demonitor(writer_ref, [:flush])

    %{
      data
      | writer_pid: nil,
        writer_ref: nil,
        cleared_writer_ref: writer_ref || data.cleared_writer_ref
    }
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
        notify_peer_lock(data, new_data)
        notify_disturbed(data, new_data)
        clear_writable_size(next_state, new_data)
        {new_data, synced?} = sync_writer_promises(next_state, new_data)
        {new_data, settled?} = settle_closed_promise(next_state, new_data)
        settled? = settled? or synced?
        {new_data, closed_actions} = closed_waiter_actions(next_state, new_data)
        timeout = lifetime_timeout(next_state, new_data)

        cond do
          timeout != new_data.lifetime_timer ->
            {:next_state, next_state, %{new_data | lifetime_timer: timeout},
             actions ++ closed_actions ++ [lifetime_action(timeout)]}

          closed_actions != [] or settled? ->
            {:next_state, next_state, new_data, actions ++ closed_actions}

          true ->
            result
        end

      :stop ->
        result
    end
  end

  # ---------------------------------------------------------------------------
  # The promise `closed` of a reader
  #
  # The attribute `closed` of a reader gives the same promise each time, as
  # in the Streams Standard. The stream makes the promise at the first
  # request, thus a reader that does not ask for it costs no process. The
  # process that holds the lock owns the promise.
  #
  #   * The promise fulfils when the stream is closed and its queue is
  #     empty, and rejects with the error of the stream.
  #   * A release of the lock of a stream that is readable rejects the
  #     promise with a `TypeError`. A release of the lock of a stream that
  #     is closed or errored replaces the promise with a promise that is
  #     rejected with a `TypeError`.
  #
  # `closed_promises` has the promise of the reader that holds the lock,
  # and the promises of the readers that released their lock of a readable
  # stream: `{:pending, promise, resolve, reject}` or `{:settled, promise}`.
  # ---------------------------------------------------------------------------

  defp reader_closed(lock, state, data) do
    case Map.fetch(data.closed_promises, lock) do
      {:ok, entry} ->
        {elem(entry, 1), data}

      :error when lock == data.reader_ref and not is_nil(lock) ->
        new_reader_closed(lock, state, data)

      :error ->
        {Web.Promise.reject(released_reader_error()), data}
    end
  end

  defp new_reader_closed(lock, state, data) do
    cond do
      state == :errored ->
        {Web.Promise.reject(data.error_reason), data}

      readable_side_open?(state, data) ->
        {promise, resolve, reject} =
          Web.Promise.with_owner(data.reader_pid, fn -> Web.Promise.with_resolvers() end)

        entry = {:pending, promise, resolve, reject}
        {promise, %{data | closed_promises: Map.put(data.closed_promises, lock, entry)}}

      true ->
        {Web.Promise.resolve(:ok), data}
    end
  end

  # ReadableStreamClose and ReadableStreamError settle the promise of the
  # reader that holds the lock.
  # Returns the data, and `true` when the promise settled.
  defp settle_closed_promise(state, %{reader_ref: lock, closed_promises: promises} = data)
       when is_map_key(promises, lock) do
    with {:pending, promise, resolve, reject} <- Map.fetch!(promises, lock),
         false <- readable_side_open?(state, data) do
      if state == :errored, do: reject.(data.error_reason), else: resolve.(:ok)
      {%{data | closed_promises: Map.put(promises, lock, {:settled, promise})}, true}
    else
      _pending_or_settled -> {data, false}
    end
  end

  defp settle_closed_promise(_state, data), do: {data, false}

  # ReadableStreamReaderGenericRelease. A promise that is pending belongs to
  # a readable stream: it rejects, and keeps its identity. A promise that
  # settled belongs to a stream that is closed or errored: a request after
  # the release gets a new promise.
  defp release_closed_promise(%{reader_ref: lock, closed_promises: promises} = data) do
    case Map.fetch(promises, lock) do
      {:ok, {:pending, promise, _resolve, reject}} ->
        reject.(released_reader_error())
        %{data | closed_promises: Map.put(promises, lock, {:settled, promise})}

      {:ok, {:settled, _promise}} ->
        %{data | closed_promises: Map.delete(promises, lock)}

      :error ->
        data
    end
  end

  # The reply to a request of a reader that released its lock.
  defp released_reader_reply({:release_lock, :reader, _pid}), do: :ok
  defp released_reader_reply(_message), do: {:error, :not_locked_by_reader}

  defp released_reader_error, do: Web.TypeError.exception("This reader is no longer locked.")

  # ---------------------------------------------------------------------------
  # The promises of a writer
  #
  # The attributes `ready` and `closed` of a writer give the same promise
  # until the Streams Standard replaces it ([[readyPromise]] and
  # [[closedPromise]]). The stream makes each promise at the first request,
  # thus a writer that does not ask for it costs no process. The process
  # that holds the lock owns the promise. An entry is
  # `{:pending, promise, resolve, reject}` or `{:settled, promise, outcome}`.
  #
  # After each event, the stream compares each entry with the state of the
  # stream (`sync_writer_promises/2`):
  #
  #   * A pending entry settles: WritableStreamUpdateBackpressure resolves
  #     `ready`, WritableStreamStartErroring rejects it, and the end of the
  #     stream settles `closed`.
  #   * A settled `ready` that no longer tells the state goes away: the next
  #     request makes a new promise, as WritableStreamUpdateBackpressure and
  #     WritableStreamDefaultWriterEnsureReadyPromiseRejected specify.
  #
  # WritableStreamDefaultWriterRelease rejects the pending promises with a
  # `TypeError`. The writer that released its lock keeps them: see
  # `released_writer_promises`.
  # ---------------------------------------------------------------------------

  defp writer_promise(request, state, data) do
    {field, status} =
      if request == :writer_ready,
        do: {:writer_ready, writer_ready_status(state, data)},
        else: {:writer_closed, writer_closed_status(state, data)}

    case Map.fetch!(data, field) do
      nil ->
        entry = new_writer_entry(status, data)
        {entry_promise(entry), Map.put(data, field, entry)}

      entry ->
        {entry_promise(entry), data}
    end
  end

  # The value of [[readyPromise]] for the state of the stream.
  defp writer_ready_status(state, data) do
    cond do
      state in [:errored, :erroring] -> {:rejected, data.error_reason}
      state == :closed -> closed_status(data)
      state == :closing or not data.backpressure -> {:fulfilled, :ok}
      true -> :pending
    end
  end

  # The value of [[closedPromise]]. It rejects after the abort callback of
  # the sink, as WritableStreamFinishErroring specifies.
  defp writer_closed_status(:closed, data), do: closed_status(data)

  defp writer_closed_status(:errored, data) do
    if data.type == :consumer and data.active_operation == :abort,
      do: :pending,
      else: {:rejected, data.error_reason}
  end

  defp writer_closed_status(_state, _data), do: :pending

  defp closed_status(data) do
    case closed_reply(data, :writer) do
      :ok -> {:fulfilled, :ok}
      {:error, {:errored, reason}} -> {:rejected, reason}
    end
  end

  defp new_writer_entry(status, data) do
    {promise, resolve, reject} =
      Web.Promise.with_owner(data.writer_pid || self(), fn -> Web.Promise.with_resolvers() end)

    settle_writer_entry({:pending, promise, resolve, reject}, status)
  end

  defp settle_writer_entry({:pending, promise, resolve, reject} = entry, status) do
    case status do
      :pending -> entry
      {:fulfilled, value} -> settled_entry(promise, resolve, status, value)
      {:rejected, reason} -> settled_entry(promise, reject, status, reason)
    end
  end

  defp settled_entry(promise, settle, outcome, value) do
    settle.(value)
    {:settled, promise, outcome}
  end

  # A promise that settled stops after its linger time: then the request
  # gets a promise with the same outcome.
  defp entry_promise({:pending, promise, _resolve, _reject}), do: promise

  defp entry_promise({:settled, promise, outcome}) do
    if Process.alive?(promise.pid), do: promise, else: %Web.Promise{state: outcome}
  end

  defp sync_writer_promises(_state, %{writer_ready: nil, writer_closed: nil} = data),
    do: {data, false}

  defp sync_writer_promises(state, data) do
    ready = sync_ready(data.writer_ready, writer_ready_status(state, data))
    closed = sync_closed(data.writer_closed, writer_closed_status(state, data))
    changed? = ready != data.writer_ready or closed != data.writer_closed
    {%{data | writer_ready: ready, writer_closed: closed}, changed?}
  end

  defp sync_ready({:pending, _promise, _resolve, _reject} = entry, status),
    do: settle_writer_entry(entry, status)

  # The backpressure is on again, or the stream is erroring: the next
  # request gets a new promise.
  defp sync_ready({:settled, _promise, {:fulfilled, _value}}, status)
       when status == :pending or elem(status, 0) == :rejected,
       do: nil

  defp sync_ready(entry, _status), do: entry

  defp sync_closed({:pending, _promise, _resolve, _reject} = entry, status),
    do: settle_writer_entry(entry, status)

  defp sync_closed(entry, _status), do: entry

  # WritableStreamDefaultWriterRelease: [[readyPromise]] and then
  # [[closedPromise]] reject with a `TypeError`.
  defp release_writer_promises(data) do
    error = released_writer_error()
    ready = reject_pending(data.writer_ready, error)
    closed = reject_pending(data.writer_closed, error)
    lock = data.writer_ref || data.cleared_writer_ref

    released =
      if is_nil(ready) and is_nil(closed),
        do: data.released_writer_promises,
        else: Map.put(data.released_writer_promises, lock, %{ready: ready, closed: closed})

    %{
      data
      | writer_ready: nil,
        writer_closed: nil,
        cleared_writer_ref: nil,
        released_writer_promises: released
    }
  end

  # A promise that settled before the release is replaced: the writer gets a
  # new rejected promise, thus the entry goes away.
  defp reject_pending({:pending, _promise, _resolve, _reject} = entry, error),
    do: settle_writer_entry(entry, {:rejected, error})

  defp reject_pending(_entry, _error), do: nil

  # The reply to a request of a writer that released its lock. The Streams
  # Standard rejects each operation with a `TypeError`. `releaseLock()` has
  # no effect.
  defp released_writer_reply({:release_lock, :writer, _pid}, _lock, _data), do: :ok

  defp released_writer_reply(request, lock, data)
       when request in [:writer_ready, :writer_closed] do
    field = if request == :writer_ready, do: :ready, else: :closed

    case get_in(data.released_writer_promises, [lock, field]) do
      nil -> Web.Promise.reject(released_writer_error())
      entry -> entry_promise(entry)
    end
  end

  defp released_writer_reply(_message, _lock, _data), do: {:error, :not_locked_by_writer}

  defp released_writer_error, do: Web.TypeError.exception("This writer is no longer locked.")

  # A request of the writer whose lock the stream released: the stream
  # handles it as a request of the lock holder.
  # The requests `release_lock` and `desired_size` name the side first.
  defp writer_message({request, :writer, _pid}, holder), do: {request, :writer, holder}
  defp writer_message(message, holder), do: put_elem(message, 1, holder)

  # The writable side does not call the size function of the user after it
  # is closed or errored.
  defp clear_writable_size(state, %{writable_size: size}) when is_function(size) do
    if state in [:closed, :errored], do: Process.delete(@writable_size_key)
    :ok
  end

  defp clear_writable_size(_state, _data), do: :ok

  # The processes that wait for the promise `closed` get the end of the
  # stream. For a writable stream, the promise rejects after the abort
  # callback of the sink, as WritableStreamFinishErroring specifies.
  defp closed_waiter_actions(:errored, %{type: :consumer, active_operation: :abort} = data),
    do: {data, []}

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
  #
  # A cancel keeps the reader lock, as in the Streams Standard. That lock does
  # not keep the stream: the process that cancelled does not wait for the
  # end of the stream.
  defp complete_linger(data) do
    cond do
      not owner_down?(data) -> data.linger
      owner_failed?(data) and (data.canceled or not locked?(data)) -> 0
      # The linger time `:infinity` is not applicable after the owner stopped.
      true -> handoff_linger(data.linger)
    end
  end

  # The stream has work, or chunks that are not read. A side of a transform
  # stream that waits for the answer of the handshake has no timer.
  defp unread_linger(%{transform: %{ending: true}}), do: nil

  # A copy of a stream with no process that got the process and did not
  # take its lock yet keeps the process, as a lock.
  defp unread_linger(data) do
    cond do
      locked?(data) or data.keepers != %{} -> nil
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
  #
  # The two sides of a transform stream are one stream for these rules: a
  # lock of one side keeps the two sides. Each side tells the other side when
  # its own lock changes: see `notify_peer_lock/2`. Each side monitors the
  # other side: a stop of the other side clears its lock. An active side
  # ends by the owner rule only after the handshake of "The lock rule of the
  # two sides". See `tla/TransformLifetime.tla`.
  defp locked?(data), do: own_lock?(data) or peer_locked?(data)

  defp own_lock?(data) do
    is_pid(data.reader_pid) or (is_pid(data.writer_pid) and not data.writer_is_pipe)
  end

  defp peer_locked?(%{transform: %{peer_locked: locked}}), do: locked
  defp peer_locked?(_data), do: false

  # The first disturb of the stream process of a stream with no process
  # takes the bytes for all the copies: a disturbed stream gives no bytes to
  # a different reader. See `Web.Internal.LazyStream`.
  defp notify_disturbed(%{disturbed: false}, %{disturbed: true, lazy_key: key}) when key != nil,
    do: LazyStream.__disturbed__(key)

  defp notify_disturbed(_old, _new), do: :ok

  # The keeper `pid` took its lock.
  defp drop_keeper(%{keepers: keepers} = data, _pid) when keepers == %{}, do: data

  defp drop_keeper(data, pid) do
    {dropped, kept} = Map.split_with(data.keepers, fn {_monitor, keeper} -> keeper == pid end)
    Enum.each(dropped, fn {monitor, _keeper} -> Process.demonitor(monitor, [:flush]) end)
    %{data | keepers: kept}
  end

  defp notify_peer_lock(%{transform: %{peer: peer}} = old, new) when is_pid(peer) do
    if lock_fields(old) != lock_fields(new) do
      locked = own_lock?(new)
      if own_lock?(old) != locked, do: control_cast(peer, {:transform_peer_locked, locked})
    end

    :ok
  end

  defp notify_peer_lock(_old, _new), do: :ok

  defp lock_fields(data), do: {data.reader_pid, data.writer_pid, data.writer_is_pipe}

  defp handoff_linger(linger) when is_integer(linger), do: linger
  defp handoff_linger(_infinity), do: @handoff_linger

  defp drained?(data) do
    :queue.is_empty(data.queue) and :queue.is_empty(data.read_requests) and
      not ByteStreamController.waiting?(data.bytes)
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
  # A side of a transform stream calls its callback in its worker: the
  # callback calls the other side, and the stream process must answer.
  defp termination_with_result(type, reason, %{transform: %{}} = data)
       when type in [:cancel, :abort] do
    {data, abort_actions} = settle_abort_request(data, :ok)
    {:ok, type |> terminate_with_task(reason, nil, data) |> add_actions(abort_actions)}
  end

  defp termination_with_result(type, reason, data) do
    data = data |> clear_owner() |> clear_task()
    {data, abort_actions} = settle_abort_request(data, :ok)

    case {type, signal_terminate(data, type, reason)} do
      # A close callback that throws puts the stream in the errored state.
      {:close, {:error, thrown} = result} ->
        {result, data |> finalize_termination(:error, thrown) |> add_actions(abort_actions)}

      {_type, result} ->
        {result, data |> finalize_termination(type, reason) |> add_actions(abort_actions)}
    end
  end

  defp add_actions({:next_state, state, data, actions}, more),
    do: {:next_state, state, data, more ++ actions}

  defp finalize_termination(data, type, reason) when type in [:cancel, :close] do
    {data, pending_byob_actions} = settle_byte_requests(data, :done)

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
        canceled: type == :cancel or data.canceled,
        writable_error:
          if(type == :cancel and data.type == :producer_consumer, do: {:errored, reason}),
        queue: if(type == :cancel, do: :queue.new(), else: data.queue),
        total_queued_size: if(type == :cancel, do: 0, else: data.total_queued_size),
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
    {data, pending_byob_actions} = settle_byte_requests(data, {:error, reason})

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

  # A terminal event releases the writer lock. It does not release the
  # reader lock, as the Streams Standard specifies: the reader reads the
  # end of the stream, and gets its promise `closed`.
  defp clear_owner(data), do: clear_writer_lock(data)

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
    QueuingStrategy.desired(data.readable_hwm, data.total_queued_size)
  end

  # The writes that are not complete have the sizes in `write_sizes`. A
  # stream with no such write has an empty queue: an error or a close
  # discards the writes, and the next write clears the old sizes.
  defp writable_capacity(data) do
    if pending_write_count(data) == 0 do
      QueuingStrategy.desired(data.writable_hwm, 0)
    else
      QueuingStrategy.desired(data.writable_hwm, data.write_total)
    end
  end

  defp writable_ready?(data) do
    QueuingStrategy.positive?(writable_capacity(data))
  end

  defp pending_write_count(data) do
    data.queued_write_count + if(data.pending_write_request, do: 1, else: 0)
  end

  # Adds the size of a write that the stream accepts.
  defp add_write_size(data, size) do
    data =
      if pending_write_count(data) == 0,
        do: %{data | write_sizes: :queue.new(), write_total: 0},
        else: data

    %{
      data
      | write_sizes: :queue.in(size, data.write_sizes),
        write_total: QueuingStrategy.add(data.write_total, size)
    }
  end

  # Removes the size of the write that is complete: the first one.
  defp remove_write_size(data) do
    {{:value, size}, sizes} = :queue.out(data.write_sizes)
    %{data | write_sizes: sizes, write_total: QueuingStrategy.subtract(data.write_total, size)}
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
    data = reply_start_waiters(data)
    %{data | active_task: nil, task_ref: nil, active_operation: nil}
  end

  # The start task is complete, or it stopped: each caller of
  # `:await_start` gets its reply.
  defp reply_start_waiters(%{start_waiters: [_ | _], active_operation: op} = data)
       when op in [:start, :init] do
    Enum.each(data.start_waiters, &:gen_statem.reply(&1, :ok))
    %{data | start_waiters: []}
  end

  defp reply_start_waiters(data), do: data

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

  # The process that holds the reader lock stopped: the lock is free.
  # A reader of a stream with no process that stopped before its first read
  # took no bytes: the stream releases the lock, and does not cancel.
  defp maybe_cancel_on_reader_exit(reason, state, %{cancel_on_reader_exit: true} = data)
       when state not in [:closed, :errored] and (is_nil(data.lazy_key) or data.disturbed) do
    handle_termination(:cancel, {:reader_down, reason}, release_stopped_reader(data))
  end

  defp maybe_cancel_on_reader_exit(_reason, _state, data) do
    {data, actions} = release_byte_reader(data)
    {:keep_state, release_stopped_reader(data), actions}
  end

  defp release_stopped_reader(data) do
    data
    |> Map.put(:reader_pid, nil)
    |> Map.put(:reader_ref, nil)
    |> Map.put(:reader_mode, nil)
  end

  # The lock of a process that stopped. A process that saw the stop (for
  # example with its own monitor) can send a call that comes before the
  # `:DOWN` message of the lock: Erlang keeps the order of the signals of
  # one sender only. The `:DOWN` message comes, because the stream monitors
  # the holder. Thus the stream takes that message, does the usual steps of
  # the stop with its true reason, and then does the call again. A holder
  # that is alive, or on a different node, gives `reply`.
  defp after_stopped_holder(holder, ref, from, request, reply)
       when is_pid(holder) and node(holder) == node() do
    if Process.alive?(holder) do
      {:keep_state_and_data, [{:reply, from, reply}]}
    else
      receive do
        {:DOWN, ^ref, :process, ^holder, _reason} = down ->
          {:keep_state_and_data,
           [{:next_event, :info, down}, {:next_event, {:call, from}, request}]}
      end
    end
  end

  defp after_stopped_holder(_holder, _ref, from, _request, reply),
    do: {:keep_state_and_data, [{:reply, from, reply}]}

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
    if final?(state, data) do
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

  # The size of an entry of the queue. The queue of a default stream holds
  # `{chunk, size}`, as the Streams Standard specifies: the size function of
  # the user runs one time for each chunk. A byte stream has its own queue:
  # see `Web.Internal.ByteStreamController`.
  defp queue_chunk_size(_data, {_chunk, size}), do: size

  # Puts a chunk of a valid size at the end of the queue.
  defp put_chunk(data, chunk, size) do
    %{
      data
      | queue: :queue.in({chunk, size}, data.queue),
        total_queued_size: QueuingStrategy.add(data.total_queued_size, size)
    }
  end

  defp normalize_strategy(%{__struct__: _} = strategy), do: strategy
  # A value that is not a strategy gives the default strategy.
  defp normalize_strategy(_), do: %Web.CountQueuingStrategy{}

  defp init_capacities(:producer_consumer, writable_hwm, strategy) do
    {strategy_high_water_mark(strategy, writable_hwm), writable_hwm}
  end

  defp init_capacities(_type, hwm, _strategy), do: {hwm, hwm}

  defp strategy_high_water_mark(%{high_water_mark: hwm}, _fallback)
       when is_number(hwm) or hwm == :infinity,
       do: hwm

  defp strategy_high_water_mark(_strategy, fallback), do: fallback

  # The option `:size` is the size function of the user. A transform stream
  # has the options `:readable_size` and `:writable_size`.
  defp init_sizes(:producer_consumer, opts, strategy) do
    {Keyword.get(opts, :readable_size) || strategy_size_algorithm(strategy),
     Keyword.get(opts, :writable_size) || :count}
  end

  defp init_sizes(_type, opts, strategy) do
    size = Keyword.get(opts, :size) || strategy_size_algorithm(strategy)
    {size, size}
  end

  defp strategy_size_algorithm(%Web.ByteLengthQueuingStrategy{}), do: :byte_length
  defp strategy_size_algorithm(_count), do: :count

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
  # The process of a direct pull is the source, not the worker: its cancel
  # callback stops it.
  defp kill_task(%{ref: ref, external: true}) do
    Process.demonitor(ref, [:flush])
    :ok
  end

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

  # A callback has no time limit, as in the Streams Standard: a promise
  # that it returns can stay pending.
  defp set_active_task(data, task, operation, updates \\ []) do
    data =
      data
      |> Map.put(:active_task, task)
      |> Map.put(:task_ref, task.ref)
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
