defmodule Web.BroadcastChannel.Dispatcher do
  @moduledoc false

  use GenServer

  alias Web.BroadcastChannel.Adapter.PG
  alias Web.BroadcastChannel.DispatcherSupervisor
  alias Web.Governor
  alias Web.Internal.Envelope

  @type subscriber :: %{
          creation_index: non_neg_integer(),
          monitor_ref: reference(),
          token: reference()
        }

  @type state :: %{
          name: String.t(),
          adapter: module(),
          next_creation_index: non_neg_integer(),
          subscribers: %{optional(pid()) => subscriber()},
          subscriber_monitors: %{optional(reference()) => pid()},
          queue: :queue.queue(map()),
          dispatch_scheduled: boolean(),
          current: map() | nil
        }

  @dispatch_delay_ms 1

  @spec ensure_started(String.t()) :: pid()
  def ensure_started(name) when is_binary(name) do
    :global.trans({__MODULE__, name}, fn ->
      case lookup(name) do
        {:ok, pid} ->
          pid

        :error ->
          {:ok, pid} = DynamicSupervisor.start_child(DispatcherSupervisor, {__MODULE__, name})
          pid
      end
    end)
  end

  @spec register(String.t(), pid(), reference()) :: %{
          dispatcher: pid(),
          creation_index: non_neg_integer()
        }
  def register(name, pid, token)
      when is_binary(name) and is_pid(pid) and is_reference(token) do
    dispatcher = ensure_started(name)
    GenServer.call(dispatcher, {:register, pid, token}, :infinity)
  end

  @spec unregister(pid(), pid()) :: :ok
  def unregister(dispatcher, pid) when is_pid(dispatcher) and is_pid(pid) do
    if Process.alive?(dispatcher) do
      GenServer.call(dispatcher, {:unregister, pid}, :infinity)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  @spec post(pid(), pid(), map()) :: :ok
  def post(dispatcher, sender_pid, message)
      when is_pid(dispatcher) and is_pid(sender_pid) and is_map(message) do
    GenServer.call(dispatcher, {:local_post, sender_pid, message}, :infinity)
  end

  def child_spec(name) do
    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [name]},
      restart: :transient
    }
  end

  def start_link(name) when is_binary(name) do
    GenServer.start_link(__MODULE__, name, name: {:global, global_name(name)})
  end

  @impl true
  def init(name) do
    adapter = adapter()
    :ok = adapter.join(name, self())

    {:ok,
     %{
       name: name,
       adapter: adapter,
       next_creation_index: 0,
       subscribers: %{},
       subscriber_monitors: %{},
       queue: :queue.new(),
       dispatch_scheduled: false,
       current: nil
     }}
  end

  @impl true
  def terminate(_reason, state) do
    state.adapter.leave(state.name, self())
  end

  @impl true
  def handle_call({:register, pid, token}, _from, state) do
    case Map.get(state.subscribers, pid) do
      %{creation_index: creation_index} = subscriber ->
        next_state = put_in(state, [:subscribers, pid], %{subscriber | token: token})
        {:reply, %{dispatcher: self(), creation_index: creation_index}, next_state}

      nil ->
        monitor_ref = Process.monitor(pid)
        creation_index = state.next_creation_index

        next_state =
          state
          |> put_in([:subscribers, pid], %{
            creation_index: creation_index,
            monitor_ref: monitor_ref,
            token: token
          })
          |> put_in([:subscriber_monitors, monitor_ref], pid)
          |> Map.put(:next_creation_index, creation_index + 1)

        {:reply, %{dispatcher: self(), creation_index: creation_index}, next_state}
    end
  end

  def handle_call({:unregister, pid}, _from, state) do
    next_state =
      state
      |> remove_subscriber(pid)
      |> schedule_dispatch()

    maybe_stop_idle(next_state, :ok)
  end

  def handle_call({:local_post, sender_pid, message}, _from, state) do
    :ok = broadcast_remote(state, message)

    next_state =
      state
      |> enqueue_event(recipient_snapshot(state, sender_pid), message)
      |> schedule_dispatch()

    {:reply, :ok, next_state}
  end

  @impl true
  def handle_info({:broadcast_channel_remote, message}, state) when is_map(message) do
    next_state =
      state
      |> enqueue_event(recipient_snapshot(state, nil), message)
      |> schedule_dispatch()

    maybe_stop_idle(next_state, :noreply)
  end

  def handle_info(:broadcast_channel_drain, state) do
    next_state =
      state
      |> Map.put(:dispatch_scheduled, false)
      |> maybe_dispatch_next()

    maybe_stop_idle(next_state, :noreply)
  end

  def handle_info({:broadcast_channel_delivery_complete, ref, pid}, %{current: current} = state)
      when is_map(current) do
    if current.ref == ref and current.current_pid == pid do
      next_state = advance_current(state)
      maybe_stop_idle(next_state, :noreply)
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, pid, _reason}, state) do
    next_state =
      case Map.pop(state.subscriber_monitors, monitor_ref) do
        {nil, subscriber_monitors} ->
          %{state | subscriber_monitors: subscriber_monitors}

        {^pid, subscriber_monitors} ->
          state
          |> Map.put(:subscriber_monitors, subscriber_monitors)
          |> update_in([:subscribers], &Map.delete(&1, pid))
      end

    next_state =
      if state.current && state.current.current_pid == pid do
        %{next_state | current: nil}
        |> advance_current_after_current_drop(state.current)
      else
        next_state
      end

    next_state
    |> maybe_dispatch_next()
    |> maybe_stop_idle(:noreply)
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp lookup(name) do
    case :global.whereis_name(global_name(name)) do
      pid when is_pid(pid) -> {:ok, pid}
      :undefined -> :error
    end
  end

  defp adapter do
    Application.get_env(:web, :broadcast_adapter, PG)
  end

  defp global_name(name), do: {__MODULE__, name}

  defp governor do
    Application.get_env(:web, :broadcast_governor)
  end

  defp remove_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, subscribers} ->
        %{state | subscribers: subscribers}

      {%{monitor_ref: monitor_ref}, subscribers} ->
        Process.demonitor(monitor_ref, [:flush])

        state
        |> Map.put(:subscribers, subscribers)
        |> update_in([:subscriber_monitors], &Map.delete(&1, monitor_ref))
    end
  end

  defp broadcast_remote(state, message) do
    run_with_governor(fn ->
      state.adapter.broadcast(
        state.name,
        self(),
        {:broadcast_channel_remote, message}
      )
    end)
  end

  defp run_with_governor(fun) when is_function(fun, 0) do
    case governor() do
      nil ->
        fun.()

      %_{} = governor ->
        governor
        |> Governor.with(fn ->
          fun.()
          :ok
        end)
        |> Map.fetch!(:task)
        |> Task.await(:infinity)
    end
  end

  defp recipient_snapshot(state, exclude_pid) do
    state.subscribers
    |> Enum.reject(fn {pid, _subscriber} -> pid == exclude_pid end)
    |> Enum.sort_by(fn {_pid, subscriber} -> subscriber.creation_index end)
    |> Enum.map(fn {pid, subscriber} -> %{pid: pid, token: subscriber.token} end)
  end

  defp enqueue_event(state, [], _message), do: state

  defp enqueue_event(state, recipients, message) do
    event = %{recipients: recipients, message: message}
    update_in(state.queue, &:queue.in(event, &1))
  end

  defp maybe_dispatch_next(%{current: nil} = state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, event}, queue} ->
        state = %{state | queue: queue}

        case next_recipient(event.recipients, state.subscribers) do
          {:recipient, recipient, remaining} ->
            dispatch_ref = make_ref()

            :ok = dispatch_to_recipient(recipient, dispatch_ref, event.message)

            %{
              state
              | current: %{
                  ref: dispatch_ref,
                  current_pid: recipient.pid,
                  remaining: remaining,
                  message: event.message
                }
            }

          :none ->
            maybe_dispatch_next(state)
        end
    end
  end

  defp maybe_dispatch_next(state), do: state

  defp schedule_dispatch(%{current: nil, dispatch_scheduled: false, queue: queue} = state) do
    if :queue.is_empty(queue) do
      state
    else
      Process.send_after(self(), :broadcast_channel_drain, @dispatch_delay_ms)
      %{state | dispatch_scheduled: true}
    end
  end

  defp schedule_dispatch(state), do: state

  defp advance_current(%{current: current} = state) do
    advance_current_after_current_drop(%{state | current: nil}, current)
    |> maybe_dispatch_next()
  end

  defp advance_current_after_current_drop(state, current) do
    case next_recipient(current.remaining, state.subscribers) do
      {:recipient, recipient, remaining} ->
        dispatch_ref = make_ref()

        :ok = dispatch_to_recipient(recipient, dispatch_ref, current.message)

        %{
          state
          | current: %{
              ref: dispatch_ref,
              current_pid: recipient.pid,
              remaining: remaining,
              message: current.message
            }
        }

      :none ->
        state
    end
  end

  defp next_recipient([], _subscribers), do: :none

  defp next_recipient([recipient | remaining], subscribers) do
    if Map.has_key?(subscribers, recipient.pid) do
      {:recipient, recipient, remaining}
    else
      next_recipient(remaining, subscribers)
    end
  end

  defp maybe_stop_idle(%{subscribers: subscribers, current: nil, queue: queue} = state, tag)
       when map_size(subscribers) == 0 do
    case :queue.is_empty(queue) do
      true ->
        case tag do
          :ok -> {:stop, :normal, :ok, state}
          :noreply -> {:stop, :normal, state}
        end

      false ->
        case tag do
          :ok -> {:reply, :ok, state}
          :noreply -> {:noreply, state}
        end
    end
  end

  defp maybe_stop_idle(state, :ok), do: {:reply, :ok, state}
  defp maybe_stop_idle(state, :noreply), do: {:noreply, state}

  defp dispatch_to_recipient(recipient, dispatch_ref, message) do
    run_with_governor(fn ->
      send(
        recipient.pid,
        {:"$gen_cast",
         Envelope.new(
           recipient.token,
           {:deliver, self(), dispatch_ref,
            %{origin: message.origin, serialized: message.serialized}},
           message.snapshot
         )}
      )

      :ok
    end)
  end
end
