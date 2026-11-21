# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule Web.AbortSignal.Reasons do
  @moduledoc false

  # Keeps the reason of each aborted signal for the linger time. The process
  # of a signal stops when the signal aborts, thus a later call to
  # `Web.AbortSignal.reason/1` reads the reason here.

  use GenServer

  @table __MODULE__
  @sweep_interval 1_000

  def start_link(_init), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec put(reference(), term()) :: :ok
  def put(ref, reason) do
    true = :ets.insert(@table, {ref, reason, expiry(Web.Promise.default_linger())})
    :ok
  rescue
    # The application is not started.
    ArgumentError -> :ok
  end

  @spec get(reference()) :: term() | nil
  def get(ref) do
    case :ets.lookup(@table, ref) do
      [{^ref, reason, _expiry}] -> reason
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp expiry(linger) when is_integer(linger), do: now() + linger
  defp expiry(_infinity), do: :infinity

  defp now, do: System.monotonic_time(:millisecond)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_interval)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    expired = [{{:_, :_, :"$1"}, [{:is_integer, :"$1"}, {:<, :"$1", now()}], [true]}]
    :ets.select_delete(@table, expired)
    Process.send_after(self(), :sweep, @sweep_interval)
    {:noreply, state}
  end
end

defmodule Web.AbortSignal do
  @moduledoc """
  An implementation of the WHATWG AbortSignal standard.

  Represents an abortable signal that can be shared across fetch operations.
  Signals are usually created through `Web.AbortController.new/0`.

  A signal that is not aborted is a small process. It stops when the process
  that made it stops and no process is subscribed to it, has a listener on
  it, or depends on it. The reason of an aborted signal stays available for
  the linger time (`config :web, linger: ms`).

  ## Events

  A signal is an event target, as `AbortSignal : EventTarget` of the DOM
  Standard: the functions of `Web.EventTarget` accept it. When the signal
  aborts, it fires the event `abort`. `onabort/2` sets the event handler of
  that event.

  The process that aborts the signal runs the listeners, before
  `Web.AbortController.abort/2` returns, as the steps "signal abort"
  specify. The signals of `any/1` that depend on the signal are aborted
  before the first listener runs, and their listeners run after the
  listeners of the signal. A new process runs the listeners of a signal of
  `timeout/1`. The signals of `timeout/1` that one process made, with the
  same or a shorter time, abort in the sequence in which the process made
  them.

  The specifications are `tla/AbortSignal.tla` (the lifetime of a signal),
  `tla/AbortSteps.tla` (the steps of an abort), and `tla/AbortTimeouts.tla`
  (the sequence of the timeouts).

  ## Examples

      iex> controller = Web.AbortController.new()
      iex> signal = controller.signal
      iex> {signal.aborted, signal.reason, is_pid(signal.pid), is_reference(signal.ref)}
      {false, nil, true, true}
      iex> timeout_signal = Web.AbortSignal.timeout(1)
      iex> Process.sleep(10)
      iex> Web.AbortSignal.subscribe(timeout_signal)
      {:error, :aborted}
      iex> aborted_signal = Web.AbortSignal.abort(:manual_cancel)
      iex> {aborted_signal.aborted, aborted_signal.reason}
      {true, :manual_cancel}
      iex> any_signal = Web.AbortSignal.any([signal, aborted_signal])
      iex> Web.AbortSignal.subscribe(any_signal)
      {:error, :aborted}
      iex> Web.AbortController.abort(controller)
      :ok
  """

  use GenServer

  alias Web.AbortSignal.Reasons
  alias Web.DOMException
  alias Web.Internal.EventTarget.Dispatch
  alias Web.Internal.EventTarget.Listeners
  alias Web.Internal.EventTarget.Store

  @handoff_linger 5_000
  @timeouts_key {__MODULE__, :timeouts}

  defstruct aborted: false, reason: nil, pid: nil, ref: nil

  @type t :: %__MODULE__{
          aborted: boolean(),
          reason: any(),
          pid: pid() | nil,
          ref: reference() | nil
        }

  @type subscription ::
          nil
          | %{type: :abort_signal, pid: pid(), ref: reference(), monitor_ref: reference()}
          | %{type: :pid, pid: pid(), monitor_ref: reference()}
          | %{type: :token, token: term()}

  @doc """
  Returns a new signal that is already aborted.

  ## Examples

      iex> signal = Web.AbortSignal.abort(:timeout)
      iex> {signal.aborted, signal.reason, signal.pid == nil}
      {true, :timeout, true}

  With no reason, the reason is an `AbortError`:

      iex> Web.AbortSignal.abort().reason.name
      "AbortError"
  """
  def abort(reason \\ DOMException.abort_error()) do
    %__MODULE__{aborted: true, reason: reason, ref: make_ref()}
  end

  @doc """
  Returns a signal that aborts automatically after `ms` milliseconds.

  ## Examples

      iex> signal = Web.AbortSignal.timeout(1)
      iex> is_pid(signal.pid) and is_reference(signal.ref)
      true
      iex> Process.sleep(10)
      iex> Web.AbortSignal.subscribe(signal)
      {:error, :aborted}
  """
  def timeout(ms) do
    controller = Web.AbortController.new()
    timeout_reason = DOMException.timeout_error()
    earlier = earlier_timeouts(controller.signal.pid, ms)

    # The signal keeps the earlier timeouts before its timer starts. See
    # `tla/AbortTimeouts.tla`.
    :ok = GenServer.call(controller.signal.pid, {:timeout_after, earlier})
    Process.send_after(controller.signal.pid, {:abort_signal_timeout, timeout_reason}, ms)
    controller.signal
  end

  # The steps "run steps after a timeout" wait for the timeouts of the same
  # global that started before, with the same or a shorter time. The
  # global of a process is the process: its dictionary has the timeouts
  # that it made, while they run.
  defp earlier_timeouts(pid, ms) do
    pending =
      for {other, time} <- Process.get(@timeouts_key, []),
          Process.alive?(other),
          do: {other, time}

    Process.put(@timeouts_key, [{pid, ms} | pending])
    for {other, time} <- pending, time <= ms, do: other
  end

  @doc """
  Returns a signal that aborts when any provided signal aborts.

  The new signal depends on each signal of the list, as the steps "create
  a dependent abort signal" specify: the abort of a signal of the list
  aborts the new signal before the listeners of the abort run.

  ## Examples

      iex> controller = Web.AbortController.new()
      iex> signal = Web.AbortSignal.any([controller.signal, Web.AbortSignal.abort(:boom)])
      iex> {signal.aborted, signal.reason}
      {true, :boom}
      iex> Web.AbortController.abort(controller)
      :ok
  """
  def any(signals) do
    case Enum.find_value(signals, &any_abort_result/1) do
      {:aborted, reason} -> abort(reason)
      nil -> new_dependent(signals)
    end
  end

  defp new_dependent(signals) do
    controller = Web.AbortController.new()
    result = controller.signal
    {signal_sources, other_sources} = Enum.split_with(signals, &process_signal?/1)

    sources = signal_sources |> Enum.flat_map(&sources_of/1) |> Enum.uniq_by(& &1.pid)
    :ok = GenServer.call(result.pid, {:set_sources, sources}, :infinity)
    Enum.each(sources, &add_dependent(&1, result))

    # A pid or a token is not a signal of the DOM Standard: a process waits
    # for its abort.
    case Enum.reject(other_sources, &is_nil/1) do
      [] -> :ok
      others -> spawn_link(fn -> wait_for_any_abort(others, controller) end)
    end

    result
  end

  defp process_signal?(%__MODULE__{pid: pid}) when is_pid(pid), do: true
  defp process_signal?(_signal), do: false

  # A signal that depends on other signals gives its sources: the new
  # signal depends on them, not on it.
  defp sources_of(signal) do
    case GenServer.call(signal.pid, :sources, :infinity) do
      {:ok, nil} -> [signal]
      {:ok, sources} -> sources
    end
  catch
    :exit, _reason -> [signal]
  end

  defp add_dependent(source, result) do
    case GenServer.call(source.pid, {:add_dependent, result}, :infinity) do
      :ok -> :ok
      {:aborted, reason} -> __signal_abort__(result, reason)
    end
  catch
    # The process of the source stopped: it aborted, or it had no use. A
    # signal whose process stopped is aborted.
    :exit, _reason -> __signal_abort__(result, reason(source))
  end

  def start_link do
    GenServer.start(__MODULE__, %{ref: make_ref(), subscribers: %{}, owner: Web.Promise.owner()})
  end

  @doc false
  def child_spec(_init) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}}
  end

  @doc false
  def init(%{owner: owner} = state) do
    state =
      state
      |> Map.delete(:owner)
      |> Map.merge(%{
        owner_ref: Process.monitor(owner),
        owner_down?: false,
        # The listeners of the event `abort`, and the abort algorithms of
        # the listeners of other targets. Each one belongs to a process:
        # `monitors` has a monitor for each of these processes.
        listeners: Listeners.new(),
        algorithms: [],
        monitors: %{},
        # The signals of `any/1` that depend on this signal, with a
        # monitor, and the signals that this signal depends on.
        dependents: [],
        dependent_monitors: %{},
        sources: nil,
        # `{:aborted, reason}` after the abort. The process stops when the
        # process that aborts it ran the listeners.
        aborted: nil,
        aborter_ref: nil
      })

    {:ok, state}
  end

  @doc """
  Returns the event handler of the event `abort`, as the attribute
  `onabort`, or `nil`.
  """
  @spec onabort(t()) :: Web.EventTarget.callback() | nil
  def onabort(%__MODULE__{pid: pid}) when is_pid(pid),
    do: Store.request(pid, {:get_handler, "abort"}, nil)

  def onabort(%__MODULE__{}), do: nil

  @doc """
  Sets the event handler of the event `abort`, as the setter of the
  attribute `onabort`. The value `nil` removes it. A signal that aborted
  fires no event again.
  """
  @spec onabort(t(), Web.EventTarget.callback() | nil) :: t()
  def onabort(%__MODULE__{pid: pid} = signal, callback)
      when is_pid(pid) and
             (is_nil(callback) or is_function(callback, 0) or is_function(callback, 1)) do
    _ok = Store.request(pid, {:set_handler, "abort", callback}, :ok)
    signal
  end

  def onabort(%__MODULE__{} = signal, callback)
      when is_nil(callback) or is_function(callback, 0) or is_function(callback, 1),
      do: signal

  @doc false
  # The steps "add an algorithm": the abort of the signal calls `apply/3`
  # with the module, the function, and the arguments. Returns `:aborted`
  # for a signal that aborted: the algorithm does not run.
  @spec __add_algorithm__(t(), {module(), atom(), list()}) :: :ok | :aborted
  def __add_algorithm__(%__MODULE__{pid: pid}, {_module, _function, _args} = algorithm)
      when is_pid(pid) do
    GenServer.call(pid, {:add_algorithm, algorithm}, :infinity)
  catch
    :exit, _reason -> :aborted
  end

  def __add_algorithm__(%__MODULE__{}, _algorithm), do: :aborted

  @doc false
  # The steps "signal abort", in the calling process: the signal and the
  # signals that depend on it are aborted, then the abort algorithms and the
  # listeners of each one run, before this function returns.
  @spec __signal_abort__(t(), term()) :: :ok
  def __signal_abort__(%__MODULE__{pid: pid} = signal, reason) when is_pid(pid) do
    case mark_aborted(pid, {:abort, reason}) do
      {:ok, algorithms, dependents} -> run_abort_steps(signal, algorithms, dependents)
      :already -> :ok
    end
  end

  def __signal_abort__(%__MODULE__{}, _reason), do: :ok

  @doc false
  # The steps "signal abort" for a process that must answer other processes
  # while the listeners run, such as the process of a stream: the signals
  # are aborted before this function returns, and a new process runs the
  # abort algorithms and the listeners.
  @spec __signal_abort_later__(t(), term()) :: :ok
  def __signal_abort_later__(%__MODULE__{pid: pid} = signal, reason) when is_pid(pid) do
    # The new process is the process that aborts the signal: the signal
    # stops when it stops.
    runner =
      spawn(fn ->
        receive do
          {:abort_steps, algorithms, dependents} ->
            run_abort_steps(signal, algorithms, dependents)

          :already ->
            :ok
        end
      end)

    case mark_aborted(pid, {:abort, reason, runner}) do
      {:ok, algorithms, dependents} -> send(runner, {:abort_steps, algorithms, dependents})
      :already -> send(runner, :already)
    end

    :ok
  end

  def __signal_abort_later__(%__MODULE__{}, _reason), do: :ok

  defp mark_aborted(pid, request) do
    GenServer.call(pid, request, :infinity)
  catch
    # The process of the signal stopped: it aborted, or it had no use.
    :exit, _reason -> :already
  end

  # The steps "run the abort steps" for the signal, then for each signal
  # that depends on it. Each process stops after its steps.
  defp run_abort_steps(signal, algorithms, dependents) do
    run_abort_steps(signal, algorithms)

    Enum.each(dependents, fn {dependent, dependent_algorithms} ->
      run_abort_steps(dependent, dependent_algorithms)
    end)
  after
    GenServer.cast(signal.pid, :abort_done)

    Enum.each(dependents, fn {dependent, _algorithms} ->
      GenServer.cast(dependent.pid, :abort_done)
    end)
  end

  defp run_abort_steps(signal, algorithms) do
    Enum.each(algorithms, fn {module, function, args} -> apply(module, function, args) end)
    _result = Dispatch.dispatch(signal, Web.Event.__create__("abort"), signal.pid, trusted: true)
    :ok
  end

  @doc false
  def subscribe(nil), do: {:ok, nil}

  def subscribe(%__MODULE__{aborted: true}), do: {:error, :aborted}

  def subscribe(%__MODULE__{pid: pid, ref: ref}) when is_pid(pid) and is_reference(ref) do
    case GenServer.call(pid, {:subscribe, self()}) do
      :ok -> {:ok, %{type: :abort_signal, pid: pid, ref: ref, monitor_ref: Process.monitor(pid)}}
      {:error, :aborted} -> {:error, :aborted}
    end
  catch
    # The process of the signal stopped: the signal aborted, or it had no
    # more use.
    :exit, _reason -> {:error, :aborted}
  end

  def subscribe(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      {:ok, %{type: :pid, pid: pid, monitor_ref: Process.monitor(pid)}}
    else
      {:error, :aborted}
    end
  end

  def subscribe(token) do
    {:ok, %{type: :token, token: token}}
  end

  @doc false
  def unsubscribe(nil), do: :ok

  def unsubscribe(%{type: :abort_signal, pid: pid, monitor_ref: monitor_ref}) do
    Process.demonitor(monitor_ref, [:flush])
    GenServer.cast(pid, {:unsubscribe, self()})
  end

  def unsubscribe(%{monitor_ref: monitor_ref}) do
    Process.demonitor(monitor_ref, [:flush])
    :ok
  end

  def unsubscribe(%{type: :token}), do: :ok

  @doc false
  def check!(nil), do: :ok

  def check!(signal) do
    case subscribe(signal) do
      {:ok, subscription} ->
        try do
          case receive_abort(subscription, 0, true) do
            :ok ->
              :ok

            {:error, :aborted, reason} ->
              throw({:abort, normalize_reason(signal, reason)})
          end
        after
          unsubscribe(subscription)
        end

      {:error, :aborted} ->
        throw({:abort, normalize_reason(signal, :aborted)})
    end
  end

  @doc """
  Returns whether a signal has already aborted.
  """
  def aborted?(nil), do: false
  def aborted?(%__MODULE__{aborted: true}), do: true

  def aborted?(%__MODULE__{pid: pid} = signal) when is_pid(pid) do
    case subscribe(signal) do
      {:error, :aborted} ->
        true

      {:ok, subscription} ->
        try do
          match?({:error, :aborted, _reason}, receive_abort(subscription, 0, true))
        after
          unsubscribe(subscription)
        end
    end
  end

  def aborted?(_), do: false

  @doc """
  Returns the abort reason when available, otherwise `nil`.
  """
  def reason(nil), do: nil
  def reason(%__MODULE__{aborted: true, reason: reason}), do: reason

  def reason(%__MODULE__{pid: pid} = signal) when is_pid(pid) do
    case subscribe(signal) do
      {:error, :aborted} ->
        receive_signal_reason(signal)

      {:ok, subscription} ->
        try do
          case receive_abort(subscription, 0, true) do
            {:error, :aborted, reason} -> reason
            :ok -> nil
          end
        after
          unsubscribe(subscription)
        end
    end
  end

  def reason(_), do: nil

  @doc """
  Raises the reason of the signal when the signal has already aborted, as
  `throwIfAborted()`: "throw this's abort reason". The reason is the error
  itself, also when it is not an exception: `catch :error, reason` gives
  it.
  """
  @spec throw_if_aborted(t() | nil) :: :ok
  def throw_if_aborted(nil), do: :ok

  def throw_if_aborted(%__MODULE__{aborted: true, reason: reason}) do
    :erlang.error(reason)
  end

  def throw_if_aborted(%__MODULE__{} = signal) do
    case any_abort_result(signal) do
      {:aborted, reason} -> :erlang.error(reason)
      nil -> :ok
    end
  end

  @doc false
  # The reason of a signal that gave no reason: the process of the signal
  # stopped, or a token signal sent no reason.
  @spec default_reason() :: DOMException.t()
  def default_reason, do: DOMException.abort_error()

  defp normalize_reason(signal, :aborted), do: reason(signal) || default_reason()
  defp normalize_reason(_signal, reason), do: reason

  # The process of the signal stopped. The reason is in the store for the
  # linger time. After that time, or for a signal that stopped with no
  # abort, the reason is the default reason.
  defp receive_signal_reason(%__MODULE__{ref: ref, reason: fallback}) do
    remembered_reason(ref) || fallback || default_reason()
  end

  defp remember_reason(ref, reason) when is_reference(ref), do: Reasons.put(ref, reason)

  defp remembered_reason(ref) when is_reference(ref), do: Reasons.get(ref)

  def receive_abort(nil, _timeout, _with_reason?), do: :ok

  def receive_abort(
        %{type: :abort_signal, pid: pid, ref: ref, monitor_ref: monitor_ref},
        timeout,
        true
      ) do
    receive do
      {:abort, ^ref, reason} ->
        {:error, :aborted, reason}

      {:DOWN, ^monitor_ref, :process, ^pid, {:shutdown, {:aborted, reason}}} ->
        {:error, :aborted, reason}

      # The process of the signal stopped with no abort.
      {:DOWN, ^monitor_ref, :process, ^pid, _exit_reason} ->
        {:error, :aborted, default_reason()}
    after
      timeout ->
        :ok
    end
  end

  def receive_abort(%{type: :pid, pid: pid, monitor_ref: monitor_ref}, timeout, true) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, :aborted, reason}

      {:abort, ^pid, reason} ->
        {:error, :aborted, reason}
    after
      timeout ->
        if Process.alive?(pid), do: :ok, else: {:error, :aborted, default_reason()}
    end
  end

  def receive_abort(%{type: :token, token: token}, timeout, true) do
    receive do
      {:abort, ^token} ->
        {:error, :aborted, default_reason()}

      {:abort, ^token, reason} ->
        {:error, :aborted, reason}
    after
      timeout ->
        :ok
    end
  end

  @doc false
  def handle_call({:subscribe, _subscriber}, _from, %{aborted: {:aborted, _reason}} = state) do
    {:reply, {:error, :aborted}, state}
  end

  def handle_call({:subscribe, subscriber}, _from, %{subscribers: subscribers} = state) do
    # A process can subscribe more than one time. The count shows how many
    # subscriptions it has.
    entry =
      case subscribers do
        %{^subscriber => {monitor_ref, count}} -> {monitor_ref, count + 1}
        _ -> {Process.monitor(subscriber), 1}
      end

    {:reply, :ok, %{state | subscribers: Map.put(subscribers, subscriber, entry)}}
  end

  # The steps "signal abort", steps 1 to 4: the process that aborts the
  # signal gets the abort algorithms of the signal, and the signals that
  # depend on it, with their algorithms. It runs them, and then the
  # process stops.
  def handle_call({:abort, reason}, {aborter, _tag}, state),
    do: handle_call({:abort, reason, aborter}, nil, state)

  def handle_call({:abort, _reason, _aborter}, _from, %{aborted: {:aborted, _}} = state) do
    {:reply, :already, state}
  end

  def handle_call({:abort, reason, aborter}, _from, state) do
    {algorithms, state} = mark(state, reason, aborter)

    dependents =
      Enum.flat_map(state.dependents, fn dependent ->
        case mark_dependent(dependent, reason, aborter) do
          {:ok, dependent_algorithms} -> [{dependent, dependent_algorithms}]
          :already -> []
        end
      end)

    {:reply, {:ok, algorithms, dependents}, state}
  end

  def handle_call({:abort_dependent, _reason, _aborter}, _from, %{aborted: {:aborted, _}} = state) do
    {:reply, :already, state}
  end

  def handle_call({:abort_dependent, reason, aborter}, _from, state) do
    {algorithms, state} = mark(state, reason, aborter)
    {:reply, {:ok, algorithms}, state}
  end

  # The listeners: see `Web.Internal.EventTarget.Listeners`.
  def handle_call({:listeners, request}, {client, _tag}, state) do
    {reply, listeners} = Listeners.handle(state.listeners, request, client)
    reply(reply, monitor_owners(%{state | listeners: listeners}))
  end

  def handle_call({:add_algorithm, _algorithm}, _from, %{aborted: {:aborted, _}} = state) do
    {:reply, :aborted, state}
  end

  def handle_call({:add_algorithm, algorithm}, {client, _tag}, state) do
    state = %{state | algorithms: state.algorithms ++ [{client, algorithm}]}
    reply(:ok, monitor_owners(state))
  end

  def handle_call({:add_dependent, _dependent}, _from, %{aborted: {:aborted, reason}} = state) do
    {:reply, {:aborted, reason}, state}
  end

  # `any/1` adds each new signal one time: the list of its sources has no
  # duplicate.
  def handle_call({:add_dependent, %__MODULE__{pid: pid} = dependent}, _from, state) do
    reply(:ok, %{
      state
      | dependents: state.dependents ++ [dependent],
        dependent_monitors: Map.put(state.dependent_monitors, pid, Process.monitor(pid))
    })
  end

  def handle_call(:sources, _from, %{aborted: {:aborted, _}} = state),
    do: {:reply, {:ok, nil}, state}

  def handle_call(:sources, _from, state), do: reply({:ok, state.sources}, state)

  def handle_call({:timeout_after, earlier}, _from, state),
    do: reply(:ok, Map.put(state, :timeout_after, earlier))

  def handle_call({:set_sources, sources}, _from, state),
    do: reply(:ok, %{state | sources: sources})

  # The steps "signal abort", step 2: the reason. The subscribers get the
  # abort now. The process that aborts the signal stops it after the
  # listeners.
  defp mark(state, reason, aborter) do
    remember_reason(state.ref, reason)

    Enum.each(Map.keys(state.subscribers), fn subscriber ->
      send(subscriber, {:abort, state.ref, reason})
    end)

    algorithms = Enum.map(state.algorithms, fn {_client, algorithm} -> algorithm end)

    state = %{
      state
      | aborted: {:aborted, reason},
        algorithms: [],
        aborter_ref: Process.monitor(aborter)
    }

    {algorithms, monitor_owners(state)}
  end

  defp mark_dependent(dependent, reason, aborter) do
    GenServer.call(dependent.pid, {:abort_dependent, reason, aborter}, :infinity)
  catch
    :exit, _reason -> :already
  end

  @doc false
  def handle_cast({:unsubscribe, subscriber}, %{subscribers: subscribers} = state) do
    subscribers =
      case subscribers do
        %{^subscriber => {monitor_ref, 1}} ->
          Process.demonitor(monitor_ref, [:flush])
          Map.delete(subscribers, subscriber)

        %{^subscriber => {monitor_ref, count}} ->
          Map.put(subscribers, subscriber, {monitor_ref, count - 1})

        _ ->
          subscribers
      end

    noreply(%{state | subscribers: subscribers})
  end

  # The process that aborted the signal ran its listeners.
  def handle_cast(:abort_done, %{aborted: {:aborted, reason}} = state) do
    {:stop, {:shutdown, {:aborted, reason}}, state}
  end

  # The time of `timeout/1` is complete. The process of the signal answers
  # the listeners: a new process aborts the signal, after the earlier
  # timeouts of the same process.
  @doc false
  def handle_info({:abort_signal_timeout, reason}, state) do
    signal = %__MODULE__{pid: self(), ref: state.ref}
    earlier = Map.get(state, :timeout_after, [])

    _pid =
      spawn(fn ->
        Enum.each(earlier, &await_stop/1)
        __signal_abort__(signal, reason)
      end)

    {:noreply, state}
  end

  # The linger time is complete, and no message came in that time.
  @doc false
  def handle_info(:timeout, state) do
    if unused?(state), do: {:stop, :normal, state}, else: {:noreply, state}
  end

  @doc false
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    cond do
      ref == Map.get(state, :owner_ref) ->
        noreply(%{state | owner_down?: true})

      ref == Map.get(state, :aborter_ref) ->
        {:aborted, reason} = state.aborted
        {:stop, {:shutdown, {:aborted, reason}}, state}

      match?(%{^pid => {^ref, _count}}, state.subscribers) ->
        noreply(%{state | subscribers: Map.delete(state.subscribers, pid)})

      Map.get(Map.get(state, :monitors, %{}), pid) == ref ->
        listeners = Listeners.remove_owner(state.listeners, pid)
        algorithms = Enum.reject(state.algorithms, &(elem(&1, 0) == pid))
        noreply(monitor_owners(%{state | listeners: listeners, algorithms: algorithms}))

      Map.get(Map.get(state, :dependent_monitors, %{}), pid) == ref ->
        noreply(%{
          state
          | dependents: Enum.reject(state.dependents, &(&1.pid == pid)),
            dependent_monitors: Map.delete(state.dependent_monitors, pid)
        })

      true ->
        noreply(state)
    end
  end

  defp await_stop(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  # The processes that own a listener or an abort algorithm.
  defp monitor_owners(state) do
    owners =
      MapSet.union(Listeners.owners(state.listeners), MapSet.new(state.algorithms, &elem(&1, 0)))

    monitors =
      Enum.reduce(owners, state.monitors, fn pid, acc ->
        Map.put_new_lazy(acc, pid, fn -> Process.monitor(pid) end)
      end)

    {gone, kept} = Map.split_with(monitors, fn {pid, _ref} -> not MapSet.member?(owners, pid) end)
    Enum.each(gone, fn {_pid, ref} -> Process.demonitor(ref, [:flush]) end)
    %{state | monitors: kept}
  end

  # A signal with no owner, no subscriber, no listener, and no signal that
  # depends on it has no use. It waits for the linger time, because a
  # different process can have the signal from a message, and then it
  # stops.
  defp reply(reply, state) do
    if unused?(state), do: {:reply, reply, state, unused_linger()}, else: {:reply, reply, state}
  end

  defp noreply(state) do
    if unused?(state), do: {:noreply, state, unused_linger()}, else: {:noreply, state}
  end

  defp unused?(state) do
    Map.get(state, :owner_down?, false) and map_size(state.subscribers) == 0 and
      Map.get(state, :monitors, %{}) == %{} and Map.get(state, :dependents, []) == []
  end

  defp unused_linger do
    case Web.Promise.default_linger() do
      linger when is_integer(linger) -> linger
      _infinity -> @handoff_linger
    end
  end

  defp any_abort_result(%__MODULE__{aborted: true, reason: reason}), do: {:aborted, reason}

  defp any_abort_result(%__MODULE__{} = signal) do
    case subscribe(signal) do
      {:ok, subscription} ->
        try do
          case receive_abort(subscription, 0, true) do
            {:error, :aborted, reason} -> {:aborted, reason}
            :ok -> nil
          end
        after
          unsubscribe(subscription)
        end

      {:error, :aborted} ->
        reason = reason(signal)
        if(is_nil(reason), do: nil, else: {:aborted, reason})
    end
  end

  defp any_abort_result(_signal), do: nil

  defp wait_for_any_abort(signals, controller) do
    address = Process.alias([:reply])
    coordinator = self()

    Enum.each(signals, &start_any_abort_waiter(&1, coordinator, address))

    # The waiters stop when this process stops. Thus this process must stop
    # when the new signal stops with no abort.
    signal_monitor = Process.monitor(controller.signal.pid)

    try do
      receive do
        {:abort_signal_any, ^address, reason} ->
          Process.unalias(address)
          Web.AbortController.abort(controller, reason)

        {:DOWN, ^signal_monitor, :process, _pid, _reason} ->
          :ok
      end
    after
      Process.unalias(address)
    end
  end

  defp start_any_abort_waiter(signal, coordinator, address) do
    spawn(fn ->
      coordinator_monitor = Process.monitor(coordinator)

      try do
        case subscribe(signal) do
          {:ok, subscription} ->
            try do
              case wait_for_subscription_or_coordinator(
                     subscription,
                     coordinator,
                     coordinator_monitor
                   ) do
                {:aborted, reason} -> send(address, {:abort_signal_any, address, reason})
                :ok -> :ok
              end
            after
              unsubscribe(subscription)
            end

          {:error, :aborted} ->
            :ok
        end
      after
        Process.demonitor(coordinator_monitor, [:flush])
      end
    end)
  end

  defp wait_for_subscription_or_coordinator(
         %{type: :pid, pid: pid, monitor_ref: monitor_ref},
         coordinator,
         coordinator_monitor
       ) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:aborted, reason}

      {:abort, ^pid, reason} ->
        {:aborted, reason}

      {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason} ->
        :ok
    end
  end

  defp wait_for_subscription_or_coordinator(
         %{type: :token, token: token},
         coordinator,
         coordinator_monitor
       ) do
    receive do
      {:abort, ^token} ->
        {:aborted, default_reason()}

      {:abort, ^token, reason} ->
        {:aborted, reason}

      {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason} ->
        :ok
    end
  end
end

defimpl Web.EventTarget.Protocol, for: Web.AbortSignal do
  def add_event_listener(signal, type, callback, options) do
    :ok = Web.EventTarget.__add__(signal.pid, type, callback, options)
    signal
  end

  def remove_event_listener(signal, type, callback) do
    :ok = Web.EventTarget.__remove__(signal.pid, type, callback, false)
    signal
  end

  def dispatch_event(signal, event) do
    {signal, Web.EventTarget.__dispatch__(signal, signal.pid, event)}
  end
end
