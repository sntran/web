defmodule Web.BroadcastChannel.ChannelServer do
  @moduledoc false

  use GenServer

  alias Web.AsyncContext.Snapshot
  alias Web.BroadcastChannel
  alias Web.BroadcastChannel.Dispatcher
  alias Web.EventTarget
  alias Web.Internal.StructuredData
  alias Web.MessageEvent

  @table Web.BroadcastChannel.ChannelServer.Runtime

  @type state :: %{
          name: String.t(),
          owner: pid(),
          owner_ref: reference(),
          dispatcher: pid(),
          creation_index: non_neg_integer(),
          event_target: EventTarget.t(),
          onmessage: BroadcastChannel.callback() | nil,
          closed: boolean()
        }

  @type runtime_info :: %{
          dispatcher: pid(),
          closed: boolean()
        }

  @doc false
  @spec start(String.t(), pid()) :: GenServer.on_start()
  def start(name, owner) when is_binary(name) and is_pid(owner) do
    GenServer.start(__MODULE__, {name, owner})
  end

  @doc false
  @spec runtime_info(pid()) :: runtime_info() | nil
  def runtime_info(pid) when is_pid(pid) do
    case :ets.lookup(table(), pid) do
      [{^pid, info}] -> info
      [] -> nil
    end
  end

  @doc false
  @spec mark_closed(pid()) :: :ok
  def mark_closed(pid) when is_pid(pid) do
    case runtime_info(pid) do
      %{dispatcher: dispatcher} ->
        put_runtime_info(pid, %{dispatcher: dispatcher, closed: true})

      nil ->
        :ok
    end
  end

  @impl true
  def init({name, owner}) do
    %{dispatcher: dispatcher, creation_index: creation_index} = Dispatcher.register(name, self())
    :ok = put_runtime_info(self(), %{dispatcher: dispatcher, closed: false})

    {:ok,
     %{
       name: name,
       owner: owner,
       owner_ref: Process.monitor(owner),
       dispatcher: dispatcher,
       creation_index: creation_index,
       event_target: EventTarget.new(owner: self()),
       onmessage: nil,
       closed: false
     }}
  end

  @impl true
  def handle_call(:get_onmessage, _from, state) do
    {:reply, state.onmessage, state}
  end

  def handle_call({:set_onmessage, callback}, _from, state) do
    {:reply, :ok, %{state | onmessage: callback}}
  end

  def handle_call({:add_listener, type, callback, options}, _from, state) do
    event_target = EventTarget.add_event_listener(state.event_target, type, callback, options)
    {:reply, :ok, %{state | event_target: event_target}}
  end

  def handle_call({:remove_listener, type, callback}, _from, state) do
    event_target = EventTarget.remove_event_listener(state.event_target, type, callback)
    {:reply, :ok, %{state | event_target: event_target}}
  end

  def handle_call({:dispatch_event, event}, _from, state) do
    {event_target, dispatched?} = EventTarget.dispatch_event(state.event_target, event)
    {:reply, dispatched?, %{state | event_target: event_target}}
  end

  def handle_call(:close, _from, state) do
    {:reply, :ok, close_state(state)}
  end

  @impl true
  def handle_cast({:set_onmessage, callback}, state) do
    {:noreply, %{state | onmessage: callback}}
  end

  def handle_cast({:add_listener, type, callback, options}, state) do
    event_target = EventTarget.add_event_listener(state.event_target, type, callback, options)
    {:noreply, %{state | event_target: event_target}}
  end

  def handle_cast({:remove_listener, type, callback}, state) do
    event_target = EventTarget.remove_event_listener(state.event_target, type, callback)
    {:noreply, %{state | event_target: event_target}}
  end

  def handle_cast(:close, state) do
    {:noreply, close_state(state)}
  end

  @impl true
  def handle_info({:broadcast_channel_deliver, dispatcher, ref, message}, state) do
    next_state =
      if state.closed do
        state
      else
        deliver_message(state, message)
      end

    send(dispatcher, {:broadcast_channel_delivery_complete, ref, self()})
    {:noreply, next_state}
  rescue
    exception ->
      send(dispatcher, {:broadcast_channel_delivery_complete, ref, self()})
      reraise(exception, __STACKTRACE__)
  end

  def handle_info({:DOWN, owner_ref, :process, owner, _reason}, state)
      when owner_ref == state.owner_ref and owner == state.owner do
    {:stop, :normal, close_state(state)}
  end

  def handle_info(message, state) do
    case EventTarget.handle_info(state.event_target, message) do
      {:ok, event_target} ->
        {:noreply, %{state | event_target: event_target}}

      :unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    delete_runtime_info(self())
    :ok
  end

  defp deliver_message(state, %{origin: origin, serialized: serialized, snapshot: snapshot}) do
    Snapshot.run(snapshot, fn ->
      event =
        MessageEvent.new("message",
          data: StructuredData.deserialize(serialized),
          origin: origin,
          source: nil,
          target: public_channel(state)
        )

      state
      |> invoke_onmessage(event)
      |> dispatch_event_target(event)
    end)
  end

  defp invoke_onmessage(%{onmessage: nil} = state, _event), do: state

  defp invoke_onmessage(%{onmessage: callback} = state, event) when is_function(callback, 1) do
    callback.(event)
    state
  end

  defp invoke_onmessage(%{onmessage: callback} = state, _event) when is_function(callback, 0) do
    callback.()
    state
  end

  defp dispatch_event_target(state, event) do
    {event_target, _dispatched?} = EventTarget.dispatch_event(state.event_target, event)
    %{state | event_target: event_target}
  end

  defp public_channel(state) do
    %BroadcastChannel{pid: self(), name: state.name, onmessage: state.onmessage}
  end

  defp close_state(%{closed: true} = state), do: state

  defp close_state(state) do
    :ok = mark_closed(self())
    :ok = Dispatcher.unregister(state.dispatcher, self())
    %{state | closed: true}
  end

  defp put_runtime_info(pid, info) do
    true = :ets.insert(table(), {pid, info})
    :ok
  end

  defp delete_runtime_info(pid) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _table -> :ets.delete(@table, pid)
    end

    :ok
  end

  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            {:read_concurrency, true},
            {:write_concurrency, true}
          ])
        rescue
          # coveralls-ignore-next-line
          ArgumentError ->
            @table
        end

      _tid ->
        @table
    end
  end
end
