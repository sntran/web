defmodule Web.CountingGovernor do
  @moduledoc """
  A governor that limits concurrent work to a fixed number of active tokens.

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

  The process of a governor does not stop when the process that made it
  stops. Thus a governor can limit the work of all the processes of an
  application.
  """

  use GenServer

  alias Web.Governor.Token
  alias Web.Promise

  defstruct [:pid, :capacity]

  @type t :: %__MODULE__{
          pid: pid(),
          capacity: non_neg_integer()
        }

  @type waiter :: %{
          waiter_ref: reference(),
          pid: pid(),
          holder: pid(),
          monitor_ref: reference()
        }

  @type state :: %{
          capacity: non_neg_integer(),
          in_use: non_neg_integer(),
          queue: :queue.queue(waiter()),
          active_tokens: %{optional(reference()) => reference()},
          holder_monitors: %{optional(reference()) => reference()},
          waiting: %{optional(reference()) => waiter()},
          waiter_monitors: %{optional(reference()) => reference()}
        }

  @doc """
  Creates a new counting governor with a fixed concurrency capacity.
  """
  @spec new(non_neg_integer()) :: t()
  def new(capacity) when is_integer(capacity) and capacity >= 0 do
    {:ok, pid} = GenServer.start(__MODULE__, %{capacity: capacity})
    %__MODULE__{pid: pid, capacity: capacity}
  end

  def new(capacity) do
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
  def init(%{capacity: capacity}) do
    {:ok,
     %{
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
  def handle_cast({:acquire, waiter_pid, waiter_ref, holder, flag}, state) do
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

  def handle_cast({:abort_waiter, waiter_ref}, state) do
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

  def handle_cast({:release, token_ref}, state) do
    case Map.pop(state.active_tokens, token_ref) do
      # coveralls-ignore-next-line
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

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
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
          resolve.(%Token{governor: governor, ref: token_ref})

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
        state = %{state | queue: queue}

        case Map.pop(state.waiting, waiter_ref) do
          {nil, waiting} ->
            # coveralls-ignore-next-line
            pop_next_waiter(%{state | waiting: waiting})

          {waiter, waiting} ->
            state = %{state | waiting: waiting}
            {:waiter, waiter, state}
        end
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
