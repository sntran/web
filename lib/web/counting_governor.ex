defmodule Web.CountingGovernor do
  @moduledoc """
  A governor that limits concurrent work to a fixed number of active tokens.
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
          monitor_ref: reference()
        }

  @type state :: %{
          capacity: non_neg_integer(),
          in_use: non_neg_integer(),
          queue: :queue.queue(waiter()),
          active_tokens: %{optional(reference()) => true},
          waiting: %{optional(reference()) => waiter()},
          canceled_waiters: MapSet.t(reference()),
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
    promise_for_waiter(governor, make_ref())
  end

  @doc false
  @spec acquire_abortable(t()) :: %{abort: (-> :ok), promise: Promise.t()}
  def acquire_abortable(%__MODULE__{} = governor) do
    waiter_ref = make_ref()

    %{
      abort: fn -> abort_waiter(governor, waiter_ref) end,
      promise: promise_for_waiter(governor, waiter_ref)
    }
  end

  @doc false
  @spec release_token(t(), reference()) :: :ok
  def release_token(%__MODULE__{pid: pid}, token_ref) when is_reference(token_ref) do
    if Process.alive?(pid) do
      GenServer.cast(pid, {:release, token_ref})
    end

    :ok
  end

  @doc false
  def init(%{capacity: capacity}) do
    {:ok,
     %{
       capacity: capacity,
       in_use: 0,
       queue: :queue.new(),
       active_tokens: %{},
       waiting: %{},
       canceled_waiters: MapSet.new(),
       waiter_monitors: %{}
     }}
  end

  @doc false
  def handle_call({:acquire, waiter_pid, waiter_ref}, _from, state) do
    # coveralls-ignore-start
    if MapSet.member?(state.canceled_waiters, waiter_ref) do
      send(waiter_pid, {:governor_rejected, waiter_ref, :aborted})

      {:reply, :ok,
       %{state | canceled_waiters: MapSet.delete(state.canceled_waiters, waiter_ref)}}
    else
      # coveralls-ignore-stop
      monitor_ref = Process.monitor(waiter_pid)
      waiter = %{waiter_ref: waiter_ref, pid: waiter_pid, monitor_ref: monitor_ref}
      state = put_in(state.waiting[waiter_ref], waiter)
      state = put_in(state.waiter_monitors[monitor_ref], waiter_ref)
      {:reply, :ok, maybe_grant_or_queue(waiter, state)}
    end
  end

  def handle_cast({:abort_waiter, waiter_ref}, state) do
    case Map.pop(state.waiting, waiter_ref) do
      # coveralls-ignore-start
      {nil, waiting} ->
        {:noreply,
         %{
           state
           | waiting: waiting,
             canceled_waiters: MapSet.put(state.canceled_waiters, waiter_ref)
         }}

      # coveralls-ignore-stop

      {waiter, waiting} ->
        Process.demonitor(waiter.monitor_ref, [:flush])
        send(waiter.pid, {:governor_rejected, waiter_ref, :aborted})

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

      {_value, active_tokens} ->
        state =
          state
          |> Map.put(:active_tokens, active_tokens)
          |> Map.put(:in_use, max(state.in_use - 1, 0))
          |> grant_next_waiters()

        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.waiter_monitors, monitor_ref) do
      {nil, waiter_monitors} ->
        # coveralls-ignore-next-line
        {:noreply, %{state | waiter_monitors: waiter_monitors}}

      {waiter_ref, waiter_monitors} ->
        state =
          state
          |> Map.put(:waiter_monitors, waiter_monitors)
          |> update_in([:waiting], &Map.delete(&1, waiter_ref))
          |> drop_waiter_from_queue(waiter_ref)

        {:noreply, state}
    end
  end

  defp promise_for_waiter(%__MODULE__{pid: pid} = governor, waiter_ref) do
    Promise.new(fn resolve, reject ->
      if Process.alive?(pid) do
        :ok = GenServer.call(pid, {:acquire, self(), waiter_ref}, :infinity)

        receive do
          {:governor_granted, ^waiter_ref, token_ref} ->
            resolve.(%Token{governor: governor, ref: token_ref})

          {:governor_rejected, ^waiter_ref, reason} ->
            reject.(reason)
        end
      else
        # coveralls-ignore-next-line
        reject.(:closed)
      end
    end)
  end

  defp abort_waiter(%__MODULE__{pid: pid}, waiter_ref) do
    if Process.alive?(pid) do
      GenServer.cast(pid, {:abort_waiter, waiter_ref})
    end

    :ok
  end

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
    send(waiter.pid, {:governor_granted, waiter.waiter_ref, token_ref})

    state
    |> update_in([:waiting], &Map.delete(&1, waiter.waiter_ref))
    |> update_in([:waiter_monitors], &Map.delete(&1, waiter.monitor_ref))
    |> put_in([:active_tokens, token_ref], true)
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
