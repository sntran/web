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

  ## The signal of a request

  `Web.Request.new/2` and `Web.Request.clone/1` give each request a new
  signal that depends on the signal of the option `:signal`, or on the
  signal of the input request, as the steps "create a dependent abort
  signal" of the DOM Standard specify. That signal is lazy: it has no
  process until an operation needs one. Thus `Web.Request.new/2` and
  `Web.fetch/2` start no process for it.

    * `aborted?/1`, `reason/1`, `throw_if_aborted/1`, and `onabort/1` read
      the signal that it depends on, the source. `Web.fetch/2` and the
      other operations that wait for an abort use the process of the
      source.
    * A listener, an event handler, and the option `:signal` of a listener
      need a process. The first of these operations starts it. Each copy
      of the struct is the same signal: all the copies use one process, and
      a listener of one copy runs when the source aborts.
    * The process stops as the other signals do: when its owner (the
      process that started it) stopped and it has no use, or after its
      abort.

  The specification is `tla/LazySignal.tla`.

      iex> controller = Web.AbortController.new()
      iex> request = Web.Request.new("https://example.com", signal: controller.signal)
      iex> {request.signal == controller.signal, request.signal.pid}
      {false, nil}
      iex> Web.AbortController.abort(controller, :stop)
      iex> {Web.AbortSignal.aborted?(request.signal), Web.AbortSignal.reason(request.signal)}
      {true, :stop}

  ## Examples

      iex> controller = Web.AbortController.new()
      iex> signal = controller.signal
      iex> {signal.aborted, signal.reason, is_pid(signal.pid), is_reference(signal.ref)}
      {false, nil, true, true}
      iex> timeout_signal = Web.AbortSignal.timeout(60_000)
      iex> Web.AbortSignal.aborted?(timeout_signal)
      false
      iex> aborted_signal = Web.AbortSignal.abort(:manual_cancel)
      iex> {aborted_signal.aborted, aborted_signal.reason}
      {true, :manual_cancel}
      iex> any_signal = Web.AbortSignal.any([signal, aborted_signal])
      iex> Web.AbortSignal.aborted?(any_signal)
      true
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

  # The processes of the lazy signals register themselves in the registry of
  # the stream processes, with the key `{Web.AbortSignal, ref}`.
  @registry Web.StreamRegistry

  # The field `lazy` is `nil` for a signal with a process, or for an aborted
  # signal with no process. For the lazy signal of a request, it is
  # `{sequence, source}`: the source is the signal that this signal depends
  # on (`nil` when no abort can reach the signal), and the sequence tells
  # the time when the signal was made. The source keeps its dependent
  # signals in that sequence.
  defstruct aborted: false, reason: nil, pid: nil, ref: nil, lazy: nil

  @type t :: %__MODULE__{
          aborted: boolean(),
          reason: any(),
          pid: pid() | nil,
          ref: reference() | nil,
          lazy: nil | {integer(), t() | nil}
        }

  @typedoc false
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
  Returns a signal that aborts automatically after `ms` milliseconds. Its
  reason is then a `Web.DOMException` with the name `"TimeoutError"`.

  ## Examples

      iex> signal = Web.AbortSignal.timeout(60_000)
      iex> {Web.AbortSignal.aborted?(signal), Web.AbortSignal.reason(signal)}
      {false, nil}
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
  Returns a signal that aborts when a signal of the list aborts, as the
  static method `AbortSignal.any(signals)` of the DOM Standard.

  The argument is a list of `Web.AbortSignal` values, as the type
  `sequence<AbortSignal>`. Each other value, also `nil`, raises
  `Web.TypeError`. A signal of the list that already aborted gives a new
  signal that is aborted with the same reason.

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

      iex> Web.AbortSignal.any([:token])
      ** (Web.TypeError) The value is not an AbortSignal: :token
  """
  @spec any([t()]) :: t()
  def any(signals) do
    signals = signals |> sequence!() |> Enum.map(&__convert__/1)

    case Enum.find_value(signals, &any_abort_result/1) do
      {:aborted, reason} -> abort(reason)
      nil -> new_dependent(signals)
    end
  end

  # The conversion of Web IDL to a sequence: the value must be a list or
  # another enumerable.
  defp sequence!(signals) when is_list(signals), do: signals

  defp sequence!(signals) do
    if Enumerable.impl_for(signals) do
      Enum.to_list(signals)
    else
      raise Web.TypeError, "The signals must be a list, not #{inspect(signals)}."
    end
  end

  @doc false
  # The conversion of Web IDL to the type `AbortSignal`: the value must be
  # a `Web.AbortSignal`. Each other value raises `Web.TypeError`. The
  # functions with an option `:signal` call it, for example
  # `Web.Request.new/2`.
  @spec __convert__(term()) :: t()
  def __convert__(%__MODULE__{} = signal), do: signal

  def __convert__(value) do
    raise Web.TypeError, "The value is not an AbortSignal: #{inspect(value)}"
  end

  defp new_dependent(signals) do
    controller = Web.AbortController.new()
    result = controller.signal

    sources =
      signals
      |> Enum.flat_map(&sources_of/1)
      |> Enum.uniq_by(& &1.pid)

    :ok = GenServer.call(result.pid, {:set_sources, sources}, :infinity)

    Enum.each(sources, fn source ->
      case add_dependent(source, {:add_dependent, result}) do
        :ok -> :ok
        {:aborted, reason} -> __signal_abort__(result, reason)
      end
    end)

    result
  end

  # A signal that depends on other signals gives its sources: the new
  # signal depends on them, not on it. A lazy signal gives the sources of
  # its source. A signal with no process that did not abort has no source.
  defp sources_of(%__MODULE__{lazy: {_sequence, nil}}), do: []
  defp sources_of(%__MODULE__{lazy: {_sequence, source}}), do: sources_of(source)

  defp sources_of(%__MODULE__{pid: pid} = signal) when is_pid(pid) do
    case GenServer.call(pid, :sources, :infinity) do
      {:ok, nil} -> [signal]
      {:ok, sources} -> sources
    end
  catch
    :exit, _reason -> [signal]
  end

  defp sources_of(%__MODULE__{}), do: []

  # Returns `:ok`, or `{:aborted, reason}` for a source that aborted.
  defp add_dependent(source, request) do
    GenServer.call(source.pid, request, :infinity)
  catch
    # The process of the source stopped: it aborted, or it had no use. A
    # signal whose process stopped is aborted.
    :exit, _reason -> {:aborted, reason(source)}
  end

  @doc false
  # The steps "create a dependent abort signal" for one signal, with no
  # process: the signal of a `Web.Request`. The new signal is lazy: see
  # "The signal of a request". `nil` gives a signal that no abort can
  # reach. An aborted signal gives a new aborted signal with the same
  # reason, as step 2 of the steps specifies. The source of a lazy signal is
  # never a lazy signal: a lazy signal depends on the source of the lazy
  # signal that it gets.
  @spec __dependent__(t() | nil) :: t()
  def __dependent__(%__MODULE__{aborted: true, reason: reason}), do: abort(reason)
  def __dependent__(%__MODULE__{lazy: {_sequence, source}}), do: __dependent__(source)

  def __dependent__(%__MODULE__{pid: pid} = source) when is_pid(pid) do
    %__MODULE__{ref: make_ref(), lazy: {:erlang.unique_integer([:monotonic]), source}}
  end

  def __dependent__(_no_source), do: %__MODULE__{ref: make_ref(), lazy: {0, nil}}

  @doc false
  # The signal whose abort aborts this signal: the source of a lazy signal,
  # or the signal itself. `nil` when no abort can reach the signal.
  @spec __source__(t() | nil) :: t() | nil
  def __source__(%__MODULE__{lazy: {_sequence, source}}), do: source
  def __source__(signal), do: signal

  @doc false
  # Starts the process of a signal of `Web.AbortController.new/0`. The
  # process has no link: it monitors the process that made it.
  def start_link do
    GenServer.start(__MODULE__, %{ref: make_ref(), subscribers: %{}, owner: Web.Promise.owner()})
  end

  @doc false
  def child_spec(_init) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}}
  end

  @doc false
  # The start of the process of a lazy signal: see `keep_process/2`. The
  # process registers itself with the key of the signal before this
  # function runs. It adds itself to the dependent signals of its sources,
  # and only then answers a request. A process that finds a source aborted
  # stops at once: it has no listener yet, and its event has no effect.
  def init({:lazy, %__MODULE__{lazy: {sequence, source}} = signal, owner}) do
    {:ok, state} = init(%{ref: signal.ref, subscribers: %{}, owner: owner})
    handle = %{signal | pid: self()}

    case follow(source, {:add_dependent, handle, sequence}) do
      {:ok, sources} -> {:ok, %{state | sources: sources}}
      {:aborted, reason} -> {:stop, {:shutdown, {:aborted, reason}}}
    end
  end

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
        # The signals that depend on this signal, in the sequence in which
        # they were made, with a monitor and the sequence of each one, and
        # the signals that this signal depends on.
        dependents: [],
        dependent_monitors: %{},
        dependent_sequences: %{},
        sources: nil,
        # The processes that keep the process of a lazy signal for an
        # operation, with a monitor and a count: see `keep_process/2`.
        keepers: %{},
        # `{:aborted, reason}` after the abort. The process stops when the
        # process that aborts it ran the listeners.
        aborted: nil,
        aborter_ref: nil
      })

    {:ok, state}
  end

  # The process of a lazy signal depends on the sources of its source. A
  # source that is a signal of `any/1` also keeps the process of the lazy
  # signal in its list: thus that source stays while the lazy signal has a
  # process, and a read of the lazy signal finds it. The steps of an abort
  # of the source do not use that list.
  defp follow(nil, _request), do: {:ok, []}

  defp follow(source, request) do
    sources = sources_of(source)
    kept = if Enum.any?(sources, &(&1.pid == source.pid)), do: [], else: [source]

    Enum.reduce_while(sources ++ kept, {:ok, sources}, fn signal, ok ->
      case add_dependent(signal, request) do
        :ok -> {:cont, ok}
        {:aborted, reason} -> {:halt, {:aborted, reason}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # The process of a lazy signal
  #
  # The struct of a lazy signal is a value: each copy, in each process, is
  # the same signal. The process registers itself in the registry with the
  # key `{Web.AbortSignal, ref}`, as the stream process of a
  # `Web.Internal.LazyStream` does. A copy:
  #
  #   1. looks in the registry. With no live process, it starts one. The new
  #      process registers the key before its start continues: thus one
  #      start wins, and each other start gets the process of the winner;
  #   2. keeps the process for the operation. The process answers the keep
  #      only after its start, and the lifetime rules do not stop a process
  #      that a copy keeps. A process that stopped before the keep did not
  #      get the operation: the copy looks again, while the signal is not
  #      aborted;
  #   3. does the operation, and then releases the process.
  #
  # The registry removes the key when the process stops, also when it is
  # killed. A copy on a different node does these steps on the node of the
  # reference of the signal. See `tla/LazySignal.tla`.
  # ---------------------------------------------------------------------------

  @doc false
  # Runs `fun` with the pid of the process of a lazy signal, and starts the
  # process if necessary. The process stays while `fun` runs. Returns
  # `default` when the signal aborted before the process got the operation.
  @spec __with_process__(t(), term(), (pid() -> term())) :: term()
  def __with_process__(%__MODULE__{lazy: {_sequence, _source}} = signal, default, fun) do
    case keep_process(signal, Web.Promise.owner()) do
      {:ok, pid} ->
        try do
          fun.(pid)
        after
          GenServer.cast(pid, {:release, self()})
        end

      :aborted ->
        default
    end
  end

  # The steps 1 and 2 for the process `self()`, with `owner` as the owner of
  # a new process.
  defp keep_process(%__MODULE__{ref: ref} = signal, owner) do
    if node(ref) == node() do
      __keep__(signal, owner, self())
    else
      :erpc.call(node(ref), __MODULE__, :__keep__, [signal, owner, self()])
    end
  catch
    # The node of the signal is not available: no process can keep the
    # state of the signal.
    :error, {:erpc, _reason} -> :aborted
  end

  @doc false
  # The steps 1 and 2 on the node of the signal, for the process `keeper`. A
  # start that stops found a source aborted: the operation has no effect.
  @spec __keep__(t(), pid(), pid()) :: {:ok, pid()} | :aborted
  def __keep__(signal, owner, keeper) do
    case start_process(signal, owner) do
      {:ok, pid} -> keep_or_again(signal, owner, keeper, pid)
      :again -> __keep__(signal, owner, keeper)
      :aborted -> :aborted
    end
  end

  # A process that stopped before the keep did not get the operation.
  defp keep_or_again(signal, owner, keeper, pid) do
    case keep(pid, keeper) do
      :ok -> {:ok, pid}
      :gone -> if aborted?(signal), do: :aborted, else: __keep__(signal, owner, keeper)
    end
  end

  defp keep(pid, keeper) do
    GenServer.call(pid, {:keep, keeper}, :infinity)
  catch
    :exit, _reason -> :gone
  end

  # The look in the registry, and the start of a process when the registry
  # has no live process: `GenServer.start/3` looks first. A different
  # process can take the key between the look and the start: the start then
  # gives that process. Returns `:aborted` for a start that stopped because
  # it found a source aborted.
  defp start_process(%__MODULE__{ref: ref} = signal, owner) do
    name = {:via, Registry, {@registry, {__MODULE__, ref}}}

    case GenServer.start(__MODULE__, {:lazy, signal, owner}, name: name) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} when is_pid(pid) ->
        {:ok, pid}

      {:error, {:shutdown, {:aborted, _reason}}} ->
        :aborted

      # The process with the key stopped after the look of the start. The
      # look and the stop come at the same time: a test cannot make it at a
      # known time.
      # coveralls-ignore-start
      {:error, {:already_started, _undefined}} ->
        :again
        # coveralls-ignore-stop
    end
  end

  @doc false
  # The live process of a lazy signal, or `nil`, with no start. For each
  # other signal, its pid.
  @spec __listener_pid__(t()) :: pid() | nil
  def __listener_pid__(%__MODULE__{lazy: {_sequence, _source}, ref: ref} = signal) do
    if node(ref) == node(),
      do: live_process(signal),
      else: :erpc.call(node(ref), __MODULE__, :__listener_pid__, [signal])
  catch
    :error, {:erpc, _reason} -> nil
  end

  def __listener_pid__(%__MODULE__{pid: pid}), do: pid

  defp live_process(%__MODULE__{ref: ref}) do
    case Registry.lookup(@registry, {__MODULE__, ref}) do
      [{pid, _value}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  # The struct of a signal in an event: the process of a lazy signal has a
  # struct with its pid, and the event has the struct of the copies.
  defp event_target(%__MODULE__{lazy: {_sequence, _source}} = signal), do: %{signal | pid: nil}
  defp event_target(signal), do: signal

  @doc """
  Returns the event handler of the event `abort`, as the attribute
  `onabort`, or `nil`.
  """
  @spec onabort(t()) :: Web.EventTarget.callback() | nil
  def onabort(%__MODULE__{} = signal) do
    case __listener_pid__(signal) do
      nil -> nil
      pid -> Store.request(pid, {:get_handler, "abort"}, nil)
    end
  end

  @doc """
  Sets the event handler of the event `abort`, as the setter of the
  attribute `onabort`. The value `nil` removes it. A signal that aborted
  fires no event again.
  """
  @spec onabort(t(), Web.EventTarget.callback() | nil) :: t()
  def onabort(%__MODULE__{lazy: {_sequence, _source}} = signal, callback)
      when is_function(callback, 0) or is_function(callback, 1) do
    _ok = __with_process__(signal, :ok, &set_handler(&1, callback))
    signal
  end

  def onabort(%__MODULE__{} = signal, callback)
      when is_nil(callback) or is_function(callback, 0) or is_function(callback, 1) do
    case __listener_pid__(signal) do
      nil -> :ok
      pid -> set_handler(pid, callback)
    end

    signal
  end

  defp set_handler(pid, callback), do: Store.request(pid, {:set_handler, "abort", callback}, :ok)

  @doc false
  # The steps "add an algorithm": the abort of the signal calls `apply/3`
  # with the module, the function, and the arguments. Returns `:aborted`
  # for a signal that aborted: the algorithm does not run. A lazy signal
  # starts its process: the algorithm runs after the listeners of the
  # source, as the Standard specifies.
  @spec __add_algorithm__(t(), {module(), atom(), list()}) :: :ok | :aborted
  def __add_algorithm__(%__MODULE__{lazy: {_sequence, _source}} = signal, algorithm) do
    __with_process__(signal, :aborted, &add_algorithm(&1, algorithm))
  end

  def __add_algorithm__(%__MODULE__{pid: pid}, {_module, _function, _args} = algorithm)
      when is_pid(pid),
      do: add_algorithm(pid, algorithm)

  def __add_algorithm__(%__MODULE__{}, _algorithm), do: :aborted

  defp add_algorithm(pid, algorithm) do
    GenServer.call(pid, {:add_algorithm, algorithm}, :infinity)
  catch
    :exit, _reason -> :aborted
  end

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
    event = Web.Event.__create__("abort")
    _result = Dispatch.dispatch(event_target(signal), event, signal.pid, trusted: true)
    :ok
  end

  @doc false
  def subscribe(nil), do: {:ok, nil}

  def subscribe(%__MODULE__{aborted: true}), do: {:error, :aborted}

  # A lazy signal gets its abort from its source. A signal that no abort can
  # reach gives a subscription that never gets an abort.
  def subscribe(%__MODULE__{lazy: {_sequence, nil}, ref: ref}),
    do: {:ok, %{type: :token, token: ref}}

  def subscribe(%__MODULE__{lazy: {_sequence, source}}), do: subscribe(source)

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
  def check!(%__MODULE__{lazy: {_sequence, source}}), do: check!(source)

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
  def aborted?(%__MODULE__{lazy: {_sequence, source}}), do: aborted?(source)

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
  def reason(%__MODULE__{lazy: {_sequence, source}}), do: reason(source)

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

  @doc false
  # Waits `timeout` milliseconds for the abort of a subscription of
  # `subscribe/1`. Returns `:ok`, or `{:error, :aborted, reason}`.
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

  # `any/1` adds each new signal one time: the list of its sources has no
  # duplicate. Its signal is made at this time.
  def handle_call({:add_dependent, dependent}, from, state),
    do:
      handle_call({:add_dependent, dependent, :erlang.unique_integer([:monotonic])}, from, state)

  def handle_call(
        {:add_dependent, _dependent, _sequence},
        _from,
        %{aborted: {:aborted, reason}} = state
      ) do
    {:reply, {:aborted, reason}, state}
  end

  # The process of a lazy signal adds itself in its start, with the
  # sequence of the time when the lazy signal was made. The list keeps the
  # sequence in which the signals were made, as the Standard specifies.
  def handle_call({:add_dependent, %__MODULE__{pid: pid} = dependent, sequence}, _from, state) do
    sequences = Map.put(state.dependent_sequences, pid, sequence)
    {earlier, later} = Enum.split_while(state.dependents, &(sequences[&1.pid] < sequence))

    reply(:ok, %{
      state
      | dependents: earlier ++ [dependent | later],
        dependent_monitors: Map.put(state.dependent_monitors, pid, Process.monitor(pid)),
        dependent_sequences: sequences
    })
  end

  # A copy of a lazy signal keeps its process for an operation. A process can
  # keep it more than one time: the count shows how many keeps it has.
  def handle_call({:keep, keeper}, _from, state) do
    entry =
      case state.keepers do
        %{^keeper => {monitor_ref, count}} -> {monitor_ref, count + 1}
        _ -> {Process.monitor(keeper), 1}
      end

    reply(:ok, %{state | keepers: Map.put(state.keepers, keeper, entry)})
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

  # The operation of a copy of a lazy signal is complete.
  def handle_cast({:release, keeper}, state) do
    keepers =
      case state.keepers do
        %{^keeper => {monitor_ref, 1}} ->
          Process.demonitor(monitor_ref, [:flush])
          Map.delete(state.keepers, keeper)

        %{^keeper => {monitor_ref, count}} ->
          Map.put(state.keepers, keeper, {monitor_ref, count - 1})
      end

    noreply(%{state | keepers: keepers})
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

      match?(%{^pid => {^ref, _count}}, Map.get(state, :keepers, %{})) ->
        noreply(%{state | keepers: Map.delete(state.keepers, pid)})

      Map.get(Map.get(state, :monitors, %{}), pid) == ref ->
        listeners = Listeners.remove_owner(state.listeners, pid)
        algorithms = Enum.reject(state.algorithms, &(elem(&1, 0) == pid))
        noreply(monitor_owners(%{state | listeners: listeners, algorithms: algorithms}))

      Map.get(Map.get(state, :dependent_monitors, %{}), pid) == ref ->
        noreply(%{
          state
          | dependents: Enum.reject(state.dependents, &(&1.pid == pid)),
            dependent_monitors: Map.delete(state.dependent_monitors, pid),
            dependent_sequences: Map.delete(state.dependent_sequences, pid)
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
      Map.get(state, :monitors, %{}) == %{} and Map.get(state, :dependents, []) == [] and
      Map.get(state, :keepers, %{}) == %{}
  end

  defp unused_linger do
    case Web.Promise.default_linger() do
      linger when is_integer(linger) -> linger
      _infinity -> @handoff_linger
    end
  end

  defp any_abort_result(%__MODULE__{aborted: true, reason: reason}), do: {:aborted, reason}
  defp any_abort_result(%__MODULE__{lazy: {_sequence, nil}}), do: nil
  defp any_abort_result(%__MODULE__{lazy: {_sequence, source}}), do: any_abort_result(source)

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
end

defimpl Web.EventTarget.Protocol, for: Web.AbortSignal do
  # A listener of a lazy signal starts its process: see "The signal of a
  # request" in `Web.AbortSignal`. A remove and a dispatch use the process
  # only when it exists: with no process, the signal has no listener.
  def add_event_listener(
        %Web.AbortSignal{lazy: {_sequence, _source}} = signal,
        type,
        callback,
        options
      ) do
    :ok =
      Web.AbortSignal.__with_process__(signal, :ok, fn pid ->
        Web.EventTarget.__add__(pid, type, callback, options)
      end)

    signal
  end

  def add_event_listener(signal, type, callback, options) do
    :ok = Web.EventTarget.__add__(signal.pid, type, callback, options)
    signal
  end

  def remove_event_listener(signal, type, callback) do
    :ok =
      Web.EventTarget.__remove__(Web.AbortSignal.__listener_pid__(signal), type, callback, false)

    signal
  end

  def dispatch_event(signal, event) do
    {signal,
     Web.EventTarget.__dispatch__(signal, Web.AbortSignal.__listener_pid__(signal), event)}
  end
end
