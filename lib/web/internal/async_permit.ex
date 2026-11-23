defmodule Web.Internal.AsyncPermit do
  @moduledoc false

  # The concurrency argument of the proposal for concurrency control, for
  # `Web.AsyncIterator.limit/2` and the governor argument of the methods
  # that consume an iterator: a governor, or a non-negative integer.
  #
  # "Anywhere a Governor is accepted in any AsyncIterator.prototype method,
  # a non-negative integral Number may be passed instead. It will be
  # treated as if a CountingGovernor with that capacity was passed." Such a
  # governor has no other user. Thus a count in the state of the process
  # has the same behavior, and needs no governor process.
  #
  # The functions work on the state of a process of `Web.AsyncIterator`,
  # with the fields `permit` and `running`. The process starts each step
  # with a permit, and gives the permit back at the end of the step:
  #
  #   * `:count` for an integer;
  #   * `{:token, token}` for a governor. One acquisition runs at a time,
  #     in a process that sends `{:permit, ref, outcome}`. An acquisition
  #     that the process does not need any more is aborted when the
  #     governor can abort it, and its token goes back at once.

  alias Web.GovernorToken
  alias Web.Promise

  @type t :: %{
          type: {:count, non_neg_integer()} | {:governor, struct()},
          in_use: non_neg_integer(),
          acquiring: nil | %{ref: reference(), abort: (-> :ok) | nil}
        }

  @doc """
  The permit state of a concurrency argument. Raises `Web.RangeError` for
  a negative integer, and `Web.TypeError` for a value that is not a
  governor.
  """
  @spec new!(term()) :: t()
  def new!(capacity) when is_integer(capacity) and capacity >= 0,
    do: new_state({:count, capacity})

  def new!(capacity) when is_integer(capacity) do
    raise Web.RangeError, "The concurrency must be a non-negative integer, got: #{capacity}"
  end

  def new!(%module{} = governor) do
    if governor?(module) do
      new_state({:governor, governor})
    else
      raise_not_governor(governor)
    end
  end

  def new!(value), do: raise_not_governor(value)

  defp new_state(type), do: %{type: type, in_use: 0, acquiring: nil}

  defp governor?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :acquire, 1)
  end

  defp raise_not_governor(value) do
    raise Web.TypeError,
          "The concurrency must be a governor or a non-negative integer, got: #{inspect(value)}"
  end

  @doc """
  Takes a permit for a step: `{:ok, permit, state}`, or `{:wait, state}`.
  For a governor, the first call starts the acquisition.
  """
  @spec take(map()) :: {:ok, :count, map()} | {:wait, map()}
  def take(%{permit: %{type: {:count, capacity}, in_use: in_use} = permit} = state) do
    if in_use < capacity do
      {:ok, :count, %{state | permit: %{permit | in_use: in_use + 1}}}
    else
      {:wait, state}
    end
  end

  def take(%{permit: %{type: {:governor, governor}, acquiring: nil} = permit} = state) do
    ref = make_ref()
    coordinator = self()
    {promise, abort} = acquire(governor)
    pid = spawn_link(fn -> send(coordinator, {:permit, ref, Promise.wait(promise)}) end)
    running = Map.put(state.running, pid, %{role: :permit, ref: ref, permit: nil})
    {:wait, %{state | permit: %{permit | acquiring: %{ref: ref, abort: abort}}, running: running}}
  end

  def take(state), do: {:wait, state}

  # `acquireAbortable()` when the governor has it. An error of the
  # governor rejects the acquisition.
  defp acquire(%module{} = governor) do
    if function_exported?(module, :acquire_abortable, 1) do
      %{promise: promise, abort: abort} = module.acquire_abortable(governor)
      {promise, abort}
    else
      {Promise.try(fn -> module.acquire(governor) end), nil}
    end
  catch
    kind, reason -> {Promise.reject(Exception.normalize(kind, reason, __STACKTRACE__)), nil}
  end

  @doc """
  The outcome of the acquisition `ref`, which runs. A token that the
  process does not need goes back at once.
  """
  @spec granted(map(), reference(), Promise.outcome(), boolean()) ::
          {:ok, {:token, GovernorToken.t()}, map()} | {:error, term(), map()} | {:ignored, map()}
  def granted(%{permit: %{acquiring: %{ref: ref}} = permit} = state, ref, outcome, needed?) do
    state = %{state | permit: %{permit | acquiring: nil}}

    case {outcome, needed?} do
      {{:fulfilled, token}, true} -> {:ok, {:token, token}, state}
      {{:fulfilled, token}, false} -> {:ignored, release(state, {:token, token})}
      {{:rejected, reason}, true} -> {:error, reason, state}
      {{:rejected, _reason}, false} -> {:ignored, state}
    end
  end

  @doc "Tells if the acquisition `ref` runs."
  @spec acquiring?(map(), reference()) :: boolean()
  def acquiring?(state, ref), do: match?(%{permit: %{acquiring: %{ref: ^ref}}}, state)

  @doc """
  Gives back the permit of the process with the reference `ref`, at the
  end of its work: the process keeps no permit. A process that stopped
  has no entry, and keeps its permit until its exit.
  """
  @spec release_job(map(), reference()) :: map()
  def release_job(state, ref) do
    case Enum.find(state.running, fn {_pid, entry} -> entry.ref == ref end) do
      {pid, entry} -> state |> release(entry.permit) |> put_in([:running, pid, :permit], nil)
      nil -> state
    end
  end

  @doc "Gives a permit back."
  @spec release(map(), :count | {:token, GovernorToken.t()} | nil) :: map()
  def release(%{permit: %{in_use: in_use} = permit} = state, :count) do
    %{state | permit: %{permit | in_use: in_use - 1}}
  end

  def release(state, {:token, token}) do
    :ok = GovernorToken.release(token)
    state
  end

  def release(state, nil), do: state

  @doc """
  Aborts an acquisition that the process does not need, when the governor
  can abort it. The outcome of the acquisition still comes: see
  `granted/4`.
  """
  @spec prune(map(), boolean()) :: map()
  def prune(%{permit: %{acquiring: %{abort: abort} = acquiring} = permit} = state, false)
      when is_function(abort, 0) do
    abort.()
    %{state | permit: %{permit | acquiring: %{acquiring | abort: nil}}}
  end

  def prune(state, _needed?), do: state
end
