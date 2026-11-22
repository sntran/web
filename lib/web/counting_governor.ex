defmodule Web.CountingGovernor do
  @moduledoc """
  A governor with a fixed number of tokens, as `CountingGovernor` of the
  TC39 proposal "concurrency control": a counting semaphore. Use it with
  the functions of `Web.Governor` and `Web.AbortableGovernor`.

  ## The holder of a token

  A token belongs to the owner of the process that called
  `Web.Governor.acquire/1`. A process is its own owner. The process of a
  promise, and the process of a stream callback, have the owner of the
  promise or of the stream.

  When the owner stops, the governor takes the token back. Thus a process
  that stops with a failure, or that forgets the release, does not decrease
  the capacity. This is also applicable to `Web.Governor.with/2`: when its
  owner stops, its work stops, and the governor takes the token back.

  If you give a token to a different process, keep the owner alive until the
  release.

  ## The life of a governor

  A governor is a process. There are two procedures to make one:

    * `new/1` makes a governor that belongs to the process that calls it,
      as a stream or an abort signal. It is the constructor
      `new CountingGovernor(capacity)`. The governor stops after its owner
      stopped, when no token is in use and no acquisition waits. It stays
      for the linger time before it stops, thus a different process that got
      the governor in a message can use it. This is the equivalent of an
      object that the garbage collector removes when nothing refers to it.

    * `start_link/1` makes a governor for a supervision tree. Such a
      governor has no owner, and limits the work of all the processes of an
      application. `get/1` gives the governor of the process:

          children = [
            {Web.CountingGovernor, capacity: 4, name: MyApp.FetchLimit}
          ]

          governor = Web.CountingGovernor.get(MyApp.FetchLimit)
          Web.Governor.with(governor, fn -> Web.fetch(url) end)
  """

  use GenServer

  alias Web.GovernorToken
  alias Web.Promise

  defstruct [:pid, :capacity]

  @type t :: %__MODULE__{
          pid: GenServer.server(),
          capacity: non_neg_integer()
        }

  @typedoc false
  @type waiter :: %{
          waiter_ref: reference(),
          pid: pid(),
          holder: pid(),
          monitor_ref: reference()
        }

  @typedoc false
  @type state :: %{
          owner: reference() | {:down, term()} | nil,
          linger: non_neg_integer() | :infinity | nil,
          capacity: non_neg_integer(),
          in_use: non_neg_integer(),
          queue: :queue.queue(waiter()),
          active_tokens: %{optional(reference()) => reference()},
          holder_monitors: %{optional(reference()) => reference()},
          waiting: %{optional(reference()) => waiter()},
          waiter_monitors: %{optional(reference()) => reference()}
        }

  @doc """
  Makes a governor with a fixed capacity. The governor belongs to the process
  that calls this function. See the section "The life of a governor".
  """
  @spec new(non_neg_integer()) :: t()
  def new(capacity) do
    validate_capacity!(capacity)

    {:ok, pid} =
      GenServer.start(__MODULE__, %{
        capacity: capacity,
        owner: Promise.owner(),
        linger: Promise.default_linger()
      })

    %__MODULE__{pid: pid, capacity: capacity}
  end

  @doc """
  Starts a governor that has no owner, for a supervision tree.

  ## Options

    * `:capacity` - the number of tokens. This option is necessary.
    * `:name` - a name for the process, as for `GenServer.start_link/3`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    capacity = Keyword.fetch!(opts, :capacity)
    validate_capacity!(capacity)
    init = %{capacity: capacity, owner: nil, linger: nil}

    GenServer.start_link(__MODULE__, init, Keyword.take(opts, [:name]))
  end

  @doc """
  Returns the governor of a process that `start_link/1` started. `server`
  is the pid or the name of the process.

  The proposal has no such function: a supervisor starts a process, and the
  functions of `Web.Governor` need the struct of the governor.
  """
  @spec get(GenServer.server()) :: t()
  def get(server) do
    %__MODULE__{pid: server, capacity: GenServer.call(server, :capacity)}
  end

  defp validate_capacity!(capacity) when is_integer(capacity) and capacity >= 0, do: :ok

  defp validate_capacity!(capacity) do
    raise ArgumentError,
          "CountingGovernor capacity must be a non-negative integer, got: #{inspect(capacity)}"
  end

  @doc false
  @spec acquire(t()) :: Promise.t()
  def acquire(%__MODULE__{} = governor) do
    promise_for_waiter(governor, make_ref(), new_abort_flag())
  end

  @doc false
  @spec acquire_abortable(t()) :: %{abort: (-> :ok), promise: Promise.t()}
  def acquire_abortable(%__MODULE__{} = governor) do
    waiter_ref = make_ref()
    flag = new_abort_flag()

    %{
      abort: fn -> abort_waiter(governor, waiter_ref, flag) end,
      promise: promise_for_waiter(governor, waiter_ref, flag)
    }
  end

  @doc false
  @spec release_token(t(), reference()) :: :ok
  def release_token(%__MODULE__{pid: pid}, token_ref) when is_reference(token_ref) do
    GenServer.cast(pid, {:release, token_ref})
  end

  @doc false
  def init(%{capacity: capacity, owner: owner, linger: linger}) do
    {:ok,
     %{
       # The monitor of the owner, `nil` for a governor with no owner, or
       # `{:down, reason}` after the owner stopped.
       owner: if(is_pid(owner), do: Process.monitor(owner)),
       linger: linger,
       capacity: capacity,
       in_use: 0,
       queue: :queue.new(),
       # token_ref => the monitor of the process that holds the token
       active_tokens: %{},
       # the monitor of a holder => token_ref
       holder_monitors: %{},
       waiting: %{},
       waiter_monitors: %{}
     }}
  end

  @doc false
  def handle_call(:capacity, _from, state) do
    case with_lifetime({:noreply, state}) do
      {:noreply, state} -> {:reply, state.capacity, state}
      {:noreply, state, time} -> {:reply, state.capacity, state, time}
    end
  end

  @doc false
  def handle_cast(message, state), do: message |> do_cast(state) |> with_lifetime()

  @doc false
  # No message came in the linger time, thus the governor had no use.
  def handle_info(:timeout, state) do
    if is_nil(stop_after(state)), do: {:noreply, state}, else: {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{owner: ref} = state) do
    with_lifetime({:noreply, %{state | owner: {:down, reason}}})
  end

  def handle_info(message, state), do: message |> do_info(state) |> with_lifetime()

  # ---------------------------------------------------------------------------
  # The life of the governor
  #
  # A governor with an owner stops after the owner stopped, when no token is
  # in use and no acquisition waits. An owner that stopped normally gets the
  # linger time, because it can give the governor to a different process. A
  # message in that time starts the time again.
  # ---------------------------------------------------------------------------

  @handoff_linger 5_000

  defp with_lifetime({:noreply, state}) do
    case stop_after(state) do
      nil -> {:noreply, state}
      time -> {:noreply, state, time}
    end
  end

  defp stop_after(%{owner: {:down, reason}, in_use: 0, waiting: waiting, linger: linger})
       when map_size(waiting) == 0 do
    cond do
      reason not in [:normal, :noproc] -> 0
      is_integer(linger) -> linger
      true -> @handoff_linger
    end
  end

  defp stop_after(_state), do: nil

  defp do_cast({:acquire, waiter_pid, waiter_ref, holder, flag}, state) do
    # The abort function sets the flag before it sends its message. Thus an
    # abort that came before this call is not lost.
    if aborted?(flag) do
      send(waiter_pid, {:governor_rejected, waiter_ref, abort_reason()})
      {:noreply, state}
    else
      monitor_ref = Process.monitor(waiter_pid)

      waiter = %{
        waiter_ref: waiter_ref,
        pid: waiter_pid,
        holder: holder,
        monitor_ref: monitor_ref
      }

      state = put_in(state.waiting[waiter_ref], waiter)
      state = put_in(state.waiter_monitors[monitor_ref], waiter_ref)

      {:noreply, maybe_grant_or_queue(waiter, state)}
    end
  end

  defp do_cast({:abort_waiter, waiter_ref}, state) do
    case Map.pop(state.waiting, waiter_ref) do
      # The waiter has its token, or it is not registered. For a waiter that
      # is not registered, the flag rejects the acquisition.
      {nil, _waiting} ->
        {:noreply, state}

      {waiter, waiting} ->
        Process.demonitor(waiter.monitor_ref, [:flush])
        send(waiter.pid, {:governor_rejected, waiter_ref, abort_reason()})

        {:noreply,
         state
         |> Map.put(:waiting, waiting)
         |> update_in([:waiter_monitors], &Map.delete(&1, waiter.monitor_ref))
         |> drop_waiter_from_queue(waiter_ref)}
    end
  end

  defp do_cast({:release, token_ref}, state) do
    case Map.pop(state.active_tokens, token_ref) do
      # The token went back already: its holder released it two times, or
      # its holder stopped.
      {nil, _active_tokens} ->
        {:noreply, state}

      {holder_monitor, active_tokens} ->
        Process.demonitor(holder_monitor, [:flush])

        state =
          state
          |> Map.put(:active_tokens, active_tokens)
          |> update_in([:holder_monitors], &Map.delete(&1, holder_monitor))
          |> Map.put(:in_use, max(state.in_use - 1, 0))
          |> grant_next_waiters()

        {:noreply, state}
    end
  end

  defp do_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.waiter_monitors, monitor_ref) do
      {nil, _waiter_monitors} ->
        holder_down(monitor_ref, state)

      {waiter_ref, waiter_monitors} ->
        state =
          state
          |> Map.put(:waiter_monitors, waiter_monitors)
          |> update_in([:waiting], &Map.delete(&1, waiter_ref))
          |> drop_waiter_from_queue(waiter_ref)

        {:noreply, state}
    end
  end

  defp do_info(_message, state), do: {:noreply, state}

  # The process that holds the token stopped. The governor takes the token
  # back, and gives it to the next waiter.
  defp holder_down(monitor_ref, state) do
    case Map.pop(state.holder_monitors, monitor_ref) do
      {nil, _holder_monitors} ->
        {:noreply, state}

      {token_ref, holder_monitors} ->
        state =
          state
          |> Map.put(:holder_monitors, holder_monitors)
          |> update_in([:active_tokens], &Map.delete(&1, token_ref))
          |> Map.put(:in_use, max(state.in_use - 1, 0))
          |> grant_next_waiters()

        {:noreply, state}
    end
  end

  # The owner of the process that calls this function is the holder of the
  # token. A process is its own owner, unless it is the process of a promise
  # or of a stream callback: such a process stops after its work, and its
  # owner continues.
  defp promise_for_waiter(%__MODULE__{pid: pid} = governor, waiter_ref, flag) do
    holder = Promise.owner()

    Promise.new(fn resolve, reject ->
      monitor = Process.monitor(pid)

      # The message goes to the governor only if the governor is alive. The
      # monitor tells this process if the governor stopped.
      GenServer.cast(pid, {:acquire, self(), waiter_ref, holder, flag})

      receive do
        {:governor_granted, ^waiter_ref, token_ref} ->
          resolve.(%GovernorToken{governor: governor, ref: token_ref})

        {:governor_rejected, ^waiter_ref, reason} ->
          reject.(reason)

        {:DOWN, ^monitor, :process, _pid, _reason} ->
          reject.(Web.TypeError.exception("The governor is not available. Its process stopped."))
      end
    end)
  end

  defp abort_waiter(%__MODULE__{pid: pid}, waiter_ref, flag) do
    :atomics.put(flag, 1, 1)
    GenServer.cast(pid, {:abort_waiter, waiter_ref})
  end

  defp new_abort_flag, do: :atomics.new(1, signed: false)
  defp aborted?(flag), do: :atomics.get(flag, 1) == 1
  defp abort_reason, do: Web.DOMException.abort_error()

  defp maybe_grant_or_queue(waiter, state) do
    if state.in_use < state.capacity do
      grant_waiter(waiter, state)
    else
      update_in(state.queue, &:queue.in(waiter.waiter_ref, &1))
    end
  end

  defp grant_next_waiters(state) do
    if state.in_use >= state.capacity do
      state
    else
      case pop_next_waiter(state) do
        {:empty, next_state} ->
          next_state

        {:waiter, waiter, next_state} ->
          waiter |> grant_waiter(next_state) |> grant_next_waiters()
      end
    end
  end

  defp pop_next_waiter(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        {:empty, state}

      {{:value, waiter_ref}, queue} ->
        # Each waiter of the queue is in `waiting`: an abort and the stop of
        # a waiter remove it from the two places.
        {waiter, waiting} = Map.pop!(state.waiting, waiter_ref)
        {:waiter, waiter, %{state | queue: queue, waiting: waiting}}
    end
  end

  defp grant_waiter(waiter, state) do
    Process.demonitor(waiter.monitor_ref, [:flush])
    token_ref = make_ref()

    # If the holder stopped already, its DOWN message comes immediately.
    holder_monitor = Process.monitor(waiter.holder)
    send(waiter.pid, {:governor_granted, waiter.waiter_ref, token_ref})

    state
    |> update_in([:waiting], &Map.delete(&1, waiter.waiter_ref))
    |> update_in([:waiter_monitors], &Map.delete(&1, waiter.monitor_ref))
    |> put_in([:active_tokens, token_ref], holder_monitor)
    |> put_in([:holder_monitors, holder_monitor], token_ref)
    |> Map.put(:in_use, state.in_use + 1)
  end

  defp drop_waiter_from_queue(state, waiter_ref) do
    queue =
      state.queue
      |> :queue.to_list()
      |> Enum.reject(&(&1 == waiter_ref))
      |> :queue.from_list()

    %{state | queue: queue}
  end
end
