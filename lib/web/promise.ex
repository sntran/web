defmodule Web.Promise.AggregateError do
  defexception [:errors]

  @impl true
  def message(%{errors: errors}) do
    "All promises were rejected: #{inspect(errors)}"
  end
end

defmodule Web.Promise do
  @moduledoc """
  A promise in the style of the ECMAScript `Promise`.

  A promise has one of three states: pending, fulfilled, or rejected. A
  promise settles one time only. Subsequent calls to `resolve` or `reject` have
  no effect.

  ## Behavior

    * Any process can await a promise, and can await it more than one time.
    * The executor can call `resolve` or `reject` at a later time, from any
      process.
    * `then/2`, `catch/2`, and `finally/2` return a new promise immediately.
      The callback runs in a different process, with the
      `Web.AsyncContext` values of the caller.
    * A rejection is a state. The value `{:error, reason}` is a usual value.

  ## Lifetime

  The BEAM does not collect a process when no one refers to it. Thus each
  pending promise has an owner, which is the process that made the promise.

    * A promise that is settled at creation (`resolve/1`, `reject/1`) is plain
      data. It has no process and no lifetime limit.
    * A pending promise is a small process. It stops when its owner stops.
      The work of its executor stops at the same time.
    * After a pending promise settles, it keeps its outcome until its first
      delivery to an `await/1` or to a chained promise. Then it keeps the
      outcome for the linger time, and stops.
    * An `await/1` on a promise that stopped rejects with `Web.TypeError`.

  The default linger time is 5000 ms. Set `config :web, linger: ms`
  to change it. The value `:infinity` keeps each outcome until the owner
  stops. The option `:linger` of `new/2` and `with_resolvers/1` sets the
  time for one promise.

  Keep the awaited value, not the promise, when you need the value later.
  """

  alias Web.AsyncContext.Snapshot
  alias Web.Promise.AggregateError
  alias Web.TypeError

  defstruct [:pid, :state]

  @typedoc "The outcome of a settled promise."
  @type outcome :: {:fulfilled, term()} | {:rejected, term()}

  @type t :: %__MODULE__{pid: pid() | nil, state: outcome() | nil}

  @type resolver :: (term() -> :ok)
  @type executor :: (resolver(), resolver() -> term())

  @owner_key {__MODULE__, :owner}
  @default_linger 5_000

  # ---------------------------------------------------------------------------
  # Constructors
  # ---------------------------------------------------------------------------

  @doc """
  Makes a promise and runs `executor` in a new process.

  The executor gets the functions `resolve` and `reject`. If the executor
  raises, throws, or exits before it settles the promise, the promise rejects.

  ## Options

    * `:linger` - the time in milliseconds to keep the outcome after its first
      delivery, or `:infinity`.
    * `:detached` - if `true`, the executor continues to its end when the
      owner stops. The default is `false`.

  ## Examples

      iex> promise = Web.Promise.new(fn resolve, _reject -> resolve.(:done) end)
      iex> Web.Promise.await(promise)
      :done
      iex> Web.Promise.await(promise)
      :done
  """
  @spec new(executor(), keyword()) :: t()
  def new(executor, opts \\ []) when is_function(executor, 2) and is_list(opts) do
    {promise, _token} = start_cell(executor, opts)
    promise
  end

  @doc """
  Returns a promise together with the functions that settle it.

  ## Examples

      iex> {promise, resolve, _reject} = Web.Promise.with_resolvers()
      iex> resolve.(:hello)
      iex> Web.await(promise)
      :hello
  """
  @spec with_resolvers(keyword()) :: {t(), resolver(), resolver()}
  def with_resolvers(opts \\ []) when is_list(opts) do
    {%__MODULE__{pid: pid} = promise, token} = start_cell(nil, opts)
    {promise, settle_fun(pid, token, :fulfilled), settle_fun(pid, token, :rejected)}
  end

  @doc """
  Returns a promise that is fulfilled with `value`.

  If `value` is a promise, the function returns it without a change.
  """
  @spec resolve(term()) :: t()
  def resolve(%__MODULE__{} = promise), do: promise
  def resolve(value), do: %__MODULE__{state: {:fulfilled, value}}

  @doc """
  Returns a promise that is rejected with `reason`.
  """
  @spec reject(term()) :: t()
  def reject(reason), do: %__MODULE__{state: {:rejected, reason}}

  # ---------------------------------------------------------------------------
  # Await
  # ---------------------------------------------------------------------------

  @doc """
  Waits for the promise and returns its value.

  If the promise rejects, the calling process exits with the reason.

  ## Examples

      iex> Web.Promise.await(Web.Promise.resolve(1))
      1

      iex> catch_exit(Web.Promise.await(Web.Promise.reject(:boom)))
      :boom
  """
  @spec await(t()) :: term()
  def await(%__MODULE__{} = promise) do
    case wait(promise) do
      {:fulfilled, value} -> value
      {:rejected, reason} -> exit(reason)
    end
  end

  @doc """
  Waits for the promise and returns its outcome as data.

  ## Examples

      iex> Web.Promise.wait(Web.Promise.resolve(1))
      {:fulfilled, 1}

      iex> Web.Promise.wait(Web.Promise.reject(:boom))
      {:rejected, :boom}
  """
  @spec wait(t()) :: outcome()
  def wait(%__MODULE__{state: {status, _} = outcome}) when status in [:fulfilled, :rejected] do
    outcome
  end

  def wait(%__MODULE__{pid: pid}) when is_pid(pid) do
    ref = subscribe(pid)

    receive do
      {:web_promise, ^ref, outcome} -> outcome
      {:DOWN, ^ref, :process, _pid, _reason} -> {:rejected, released_error()}
    end
  end

  # ---------------------------------------------------------------------------
  # Chaining
  # ---------------------------------------------------------------------------

  @doc """
  Returns a promise for the result of `on_fulfilled`.

  If the first promise rejects, the new promise rejects with the same reason.
  If the callback returns a promise, the new promise takes its outcome.
  """
  @spec then(t() | term(), (term() -> term())) :: t()
  def then(promise, on_fulfilled) when is_function(on_fulfilled, 1) do
    case resolve(promise) do
      %__MODULE__{state: {:rejected, _}} = rejected ->
        rejected

      upstream ->
        new(fn resolve, reject ->
          upstream |> wait() |> on_fulfilled(on_fulfilled, resolve, reject)
        end)
    end
  end

  defp on_fulfilled({:fulfilled, value}, callback, resolve, _reject) do
    resolve.(callback.(value))
  end

  defp on_fulfilled({:rejected, reason}, _callback, _resolve, reject), do: reject.(reason)

  @doc """
  Returns a promise that recovers from a rejection with `on_rejected`.

  If the first promise is fulfilled, the new promise has the same value.
  """
  @spec unquote(:catch)(t() | term(), (term() -> term())) :: t()
  def unquote(:catch)(promise, on_rejected) when is_function(on_rejected, 1) do
    case resolve(promise) do
      %__MODULE__{state: {:fulfilled, _}} = fulfilled ->
        fulfilled

      upstream ->
        new(fn resolve, _reject ->
          upstream |> wait() |> on_rejected(on_rejected, resolve)
        end)
    end
  end

  defp on_rejected({:fulfilled, value}, _callback, resolve), do: resolve.(value)
  defp on_rejected({:rejected, reason}, callback, resolve), do: resolve.(callback.(reason))

  @doc """
  Runs `on_finally` when the promise settles, and keeps the outcome.

  If the callback raises, or returns a promise that rejects, the new promise
  rejects with that reason.
  """
  @spec finally(t() | term(), (-> term())) :: t()
  def finally(promise, on_finally) when is_function(on_finally, 0) do
    upstream = resolve(promise)

    new(fn resolve, reject ->
      outcome = wait(upstream)

      case wait(resolve(on_finally.())) do
        {:rejected, reason} -> reject.(reason)
        {:fulfilled, _} -> settle_with(outcome, resolve, reject)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Combinators
  # ---------------------------------------------------------------------------

  @doc """
  Returns a promise for the list of all values.

  The promise rejects when the first input promise rejects.
  """
  @spec all(Enumerable.t()) :: t()
  def all(enumerable) do
    promises = Enum.map(enumerable, &resolve/1)

    combine(promises, &decide_all/1)
  end

  defp decide_all(outcomes) do
    cond do
      rejected = Enum.find(outcomes, &match?({:rejected, _}, &1)) ->
        rejected

      Enum.member?(outcomes, :pending) ->
        :pending

      true ->
        {:fulfilled, Enum.map(outcomes, fn {:fulfilled, value} -> value end)}
    end
  end

  @doc """
  Returns a promise for the list of all outcomes. It does not reject.
  """
  @spec all_settled(Enumerable.t()) :: t()
  def all_settled(enumerable) do
    promises = Enum.map(enumerable, &resolve/1)

    combine(promises, &decide_all_settled/1)
  end

  defp decide_all_settled(outcomes) do
    if Enum.member?(outcomes, :pending) do
      :pending
    else
      {:fulfilled, Enum.map(outcomes, &outcome_record/1)}
    end
  end

  defp outcome_record({:fulfilled, value}), do: %{status: "fulfilled", value: value}
  defp outcome_record({:rejected, reason}), do: %{status: "rejected", reason: reason}

  @doc """
  Returns a promise for the first value that is fulfilled.

  If all input promises reject, the promise rejects with
  `Web.Promise.AggregateError`.
  """
  @spec any(Enumerable.t()) :: t()
  def any(enumerable) do
    promises = Enum.map(enumerable, &resolve/1)

    combine(promises, &decide_any/1)
  end

  defp decide_any(outcomes) do
    cond do
      fulfilled = Enum.find(outcomes, &match?({:fulfilled, _}, &1)) ->
        fulfilled

      Enum.member?(outcomes, :pending) ->
        :pending

      true ->
        errors = Enum.map(outcomes, fn {:rejected, reason} -> reason end)
        {:rejected, %AggregateError{errors: errors}}
    end
  end

  @doc """
  Returns a promise that takes the outcome of the first input promise that
  settles.

  The other input promises continue. An empty input gives a promise that
  stays pending.
  """
  @spec race(Enumerable.t()) :: t()
  def race(enumerable) do
    promises = Enum.map(enumerable, &resolve/1)

    combine(promises, &decide_race/1)
  end

  defp decide_race(outcomes), do: Enum.find(outcomes, :pending, &(&1 != :pending))

  # ---------------------------------------------------------------------------
  # Internal API for the other modules of the library
  # ---------------------------------------------------------------------------

  @doc false
  # Makes a promise for a command to a stream or a socket. The command
  # continues to its end when the owner stops.
  @spec detached(executor()) :: t()
  def detached(executor) when is_function(executor, 2), do: new(executor, detached: true)

  @doc false
  # Returns the process that owns the promises and the streams that the
  # calling process makes.
  @spec owner() :: pid()
  def owner, do: Process.get(@owner_key) || self()

  @doc false
  # Makes `owner` the owner of the promises and the streams that the calling
  # process makes. A process that runs callbacks for a different process
  # uses this function.
  @spec put_owner(pid()) :: :ok
  def put_owner(owner) when is_pid(owner) do
    Process.put(@owner_key, owner)
    :ok
  end

  @doc false
  # Runs `fun` with `owner` as the owner of the promises and the streams
  # that it makes, and then restores the owner of the calling process.
  @spec with_owner(pid(), (-> result)) :: result when result: term()
  def with_owner(owner, fun) when is_pid(owner) and is_function(fun, 0) do
    previous = Process.put(@owner_key, owner)

    try do
      fun.()
    after
      if previous, do: Process.put(@owner_key, previous), else: Process.delete(@owner_key)
    end
  end

  @doc false
  # The default time that a settled promise or an ended stream stays
  # available.
  @spec default_linger() :: non_neg_integer() | :infinity
  def default_linger, do: Application.get_env(:web, :linger, @default_linger)

  @doc false
  # Returns the outcome if the promise is settled, or `:pending`.
  @spec peek(t()) :: outcome() | :pending | :released
  def peek(%__MODULE__{state: {status, _} = outcome}) when status in [:fulfilled, :rejected] do
    outcome
  end

  def peek(%__MODULE__{pid: pid}) when is_pid(pid) do
    ref = Process.monitor(pid, alias: :reply_demonitor)
    send(pid, {:peek, ref})

    receive do
      {:web_promise, ^ref, state} -> state
      {:DOWN, ^ref, :process, _pid, _reason} -> :released
    end
  end

  # ---------------------------------------------------------------------------
  # Combinator engine
  # ---------------------------------------------------------------------------

  # `decide` gets the list of outcomes, with `:pending` for each promise that
  # is not settled. It returns the outcome of the combined promise, or
  # `:pending` to continue.
  defp combine(promises, decide) do
    outcomes = Enum.map(promises, &settled_or_pending/1)

    case decide.(outcomes) do
      {:fulfilled, value} ->
        resolve(value)

      {:rejected, reason} ->
        reject(reason)

      :pending when promises == [] ->
        # An empty input to `race/1`: the promise does not settle.
        {promise, _resolve, _reject} = with_resolvers()
        promise

      :pending ->
        new(fn resolve, reject ->
          promises
          |> Enum.zip(outcomes)
          |> subscribe_to_pending()
          |> combine_loop(decide)
          |> settle_with(resolve, reject)
        end)
    end
  end

  defp settled_or_pending(%__MODULE__{state: {status, _} = outcome})
       when status in [:fulfilled, :rejected],
       do: outcome

  defp settled_or_pending(%__MODULE__{}), do: :pending

  # Returns `{waiting, results}`. `waiting` maps each subscription to the
  # position of its promise. `results` maps each position to an outcome, or to
  # `:pending`.
  defp subscribe_to_pending(promises_and_outcomes) do
    promises_and_outcomes
    |> Enum.with_index()
    |> Enum.reduce({%{}, %{}}, fn
      {{%__MODULE__{pid: pid}, :pending}, index}, {waiting, results} ->
        {Map.put(waiting, subscribe(pid), index), Map.put(results, index, :pending)}

      {{_promise, outcome}, index}, {waiting, results} ->
        {waiting, Map.put(results, index, outcome)}
    end)
  end

  # Each step adds one outcome. To keep a large input fast, a step calls
  # `decide` with the new outcome only. That is sufficient to find an early
  # end: a rejection for `all/1`, a value for `any/1`, each outcome for
  # `race/1`. The full list goes to `decide` one time, at the end.
  defp combine_loop({waiting, results}, decide) when map_size(waiting) == 0 do
    0..(map_size(results) - 1)//1
    |> Enum.map(&Map.fetch!(results, &1))
    |> decide.()
  end

  defp combine_loop({waiting, results}, decide) do
    {ref, outcome} = receive_outcome()
    {index, waiting} = Map.pop!(waiting, ref)

    case decide.([outcome, :pending]) do
      :pending -> combine_loop({waiting, Map.put(results, index, outcome)}, decide)
      early_end -> early_end
    end
  end

  defp receive_outcome do
    receive do
      {:web_promise, ref, outcome} when is_reference(ref) -> {ref, outcome}
      {:DOWN, ref, :process, _pid, _reason} -> {ref, {:rejected, released_error()}}
    end
  end

  # ---------------------------------------------------------------------------
  # Cell process
  # ---------------------------------------------------------------------------

  defp start_cell(executor, opts) do
    token = make_ref()
    owner = owner()
    detached? = Keyword.get(opts, :detached, false)
    linger = Keyword.get_lazy(opts, :linger, &default_linger/0)
    snapshot = Snapshot.take()

    {:ok, pid} =
      Task.Supervisor.start_child(Web.TaskSupervisor, fn ->
        cell_init(%{
          token: token,
          owner: owner,
          detached?: detached?,
          linger: linger,
          executor: executor,
          snapshot: snapshot
        })
      end)

    {%__MODULE__{pid: pid}, token}
  end

  defp cell_init(%{owner: owner, executor: executor} = init) do
    Process.flag(:trap_exit, true)

    cell = %{
      token: init.token,
      linger: init.linger,
      detached?: init.detached?,
      owner_ref: Process.monitor(owner),
      owner_down?: false,
      executor: nil,
      status: :pending,
      adopt_ref: nil,
      waiters: [],
      expiry_started?: false
    }

    cell =
      if executor do
        %{cell | executor: start_executor(executor, init, self())}
      else
        cell
      end

    cell_loop(cell)
  end

  defp start_executor(executor, %{token: token, snapshot: snapshot} = init, cell_pid) do
    spawn_link(fn ->
      # A detached executor can continue after the owner stops. Thus it owns
      # the promises that it makes.
      if not init.detached?, do: put_owner(init.owner)
      resolve = settle_fun(cell_pid, token, :fulfilled)
      reject = settle_fun(cell_pid, token, :rejected)

      Snapshot.run(snapshot, fn ->
        try do
          executor.(resolve, reject)
        catch
          _kind, reason -> reject.(reason)
        end
      end)
    end)
  end

  defp settle_fun(pid, token, status) do
    fn value ->
      send(pid, {:settle, token, {status, value}})
      :ok
    end
  end

  defp cell_loop(cell) do
    receive do
      {:settle, token, outcome} when token == cell.token ->
        cell |> handle_settle(outcome) |> cell_loop()

      {:subscribe, ref} ->
        cell |> handle_subscribe(ref) |> cell_loop()

      {:peek, ref} ->
        send(ref, {:web_promise, ref, public_status(cell.status)})
        cell_loop(cell)

      {:web_promise, ref, outcome} when ref == cell.adopt_ref ->
        cell |> settle(outcome) |> cell_loop()

      {:DOWN, ref, :process, _pid, _reason} when ref == cell.adopt_ref ->
        cell |> settle({:rejected, released_error()}) |> cell_loop()

      {:DOWN, ref, :process, _pid, _reason} when ref == cell.owner_ref ->
        if cell.detached? and is_pid(cell.executor) do
          cell_loop(%{cell | owner_down?: true})
        else
          stop_cell(cell)
        end

      {:EXIT, pid, reason} when pid == cell.executor ->
        cell |> handle_executor_exit(reason) |> cell_loop()

      {:EXIT, _pid, _reason} ->
        stop_cell(cell)

      {:expire, token} when token == cell.token ->
        stop_cell(cell)

      _other ->
        cell_loop(cell)
    end
  end

  # A resolve with a promise: take the outcome of that promise.
  defp handle_settle(%{status: :pending} = cell, {:fulfilled, %__MODULE__{} = inner}) do
    cond do
      inner.pid == self() ->
        settle(cell, {:rejected, %TypeError{message: "A promise cannot resolve to itself."}})

      is_pid(inner.pid) ->
        %{cell | status: :adopting, adopt_ref: subscribe(inner.pid)}

      true ->
        settle(cell, inner.state)
    end
  end

  defp handle_settle(%{status: :pending} = cell, outcome), do: settle(cell, outcome)
  defp handle_settle(cell, _outcome), do: cell

  defp settle(cell, outcome) do
    Enum.each(cell.waiters, &deliver(&1, outcome))
    delivered? = cell.waiters != []

    %{cell | status: outcome, adopt_ref: nil, waiters: []}
    |> maybe_start_expiry(delivered?)
  end

  defp handle_subscribe(%{status: {_, _} = outcome} = cell, ref) do
    deliver(ref, outcome)
    maybe_start_expiry(cell, true)
  end

  defp handle_subscribe(cell, ref), do: %{cell | waiters: [ref | cell.waiters]}

  defp handle_executor_exit(%{owner_down?: true} = cell, _reason) do
    stop_cell(%{cell | executor: nil})
  end

  defp handle_executor_exit(%{status: :pending} = cell, reason) when reason != :normal do
    settle(%{cell | executor: nil}, {:rejected, reason})
  end

  defp handle_executor_exit(cell, _reason), do: %{cell | executor: nil}

  defp deliver(ref, outcome), do: send(ref, {:web_promise, ref, outcome})

  defp maybe_start_expiry(%{expiry_started?: false, linger: linger} = cell, true)
       when is_integer(linger) do
    Process.send_after(self(), {:expire, cell.token}, linger)
    %{cell | expiry_started?: true}
  end

  defp maybe_start_expiry(cell, _delivered?), do: cell

  defp stop_cell(%{executor: executor}) do
    if is_pid(executor), do: Process.exit(executor, :kill)
    exit(:normal)
  end

  defp public_status({_, _} = outcome), do: outcome
  defp public_status(_pending_or_adopting), do: :pending

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp subscribe(pid) do
    ref = Process.monitor(pid, alias: :reply_demonitor)
    send(pid, {:subscribe, ref})
    ref
  end

  defp settle_with({:fulfilled, value}, resolve, _reject), do: resolve.(value)
  defp settle_with({:rejected, reason}, _resolve, reject), do: reject.(reason)

  defp released_error do
    %TypeError{
      message:
        "The promise is not available. Its owner stopped, or it released its outcome. " <>
          "Keep the awaited value, or set the :linger option."
    }
  end
end

defimpl Inspect, for: Web.Promise do
  import Inspect.Algebra

  def inspect(%Web.Promise{} = promise, opts) do
    case Web.Promise.peek(promise) do
      {:fulfilled, value} -> concat(["#Web.Promise<resolved: ", to_doc(value, opts), ">"])
      {:rejected, reason} -> concat(["#Web.Promise<rejected: ", to_doc(reason, opts), ">"])
      :pending -> "#Web.Promise<pending>"
      :released -> "#Web.Promise<released>"
    end
  end
end
