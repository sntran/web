defmodule Web.BroadcastChannel.ChannelServer do
  @moduledoc false

  use GenServer

  alias Web.AsyncContext.Snapshot
  alias Web.BroadcastChannel
  alias Web.BroadcastChannel.Dispatcher
  alias Web.Internal.EventTarget.Server, as: EventTargetServer
  alias Web.Internal.StructuredData
  alias Web.MessageEvent

  @table Web.BroadcastChannel.ChannelServer.Runtime

  @type state :: %{
          ref: reference(),
          name: String.t(),
          owner: pid(),
          owner_ref: reference(),
          dispatcher: pid(),
          creation_index: non_neg_integer(),
          event_target_pid: pid(),
          onmessage: BroadcastChannel.callback() | nil,
          closed: boolean()
        }

  @type runtime_info :: %{
          dispatcher: pid(),
          closed: boolean()
        }

  @doc false
  @spec start(String.t(), pid(), reference()) :: GenServer.on_start()
  def start(name, owner, ref) when is_binary(name) and is_pid(owner) and is_reference(ref) do
    GenServer.start(__MODULE__, {name, owner, ref})
  end

  @doc false
  @spec runtime_info(reference()) :: runtime_info() | nil
  def runtime_info(ref) when is_reference(ref) do
    case :ets.lookup(table(), ref) do
      [{^ref, info}] -> info
      [] -> nil
    end
  end

  @doc false
  @spec mark_closed(reference()) :: :ok
  def mark_closed(ref) when is_reference(ref) do
    case runtime_info(ref) do
      %{dispatcher: dispatcher} ->
        put_runtime_info(ref, %{dispatcher: dispatcher, closed: true})

      nil ->
        :ok
    end
  end

  @impl true
  def init({name, owner, ref}) do
    Process.flag(:message_queue_data, :off_heap)

    %{dispatcher: dispatcher, creation_index: creation_index} = Dispatcher.register(name, self())

    {:ok, event_target_pid} =
      EventTargetServer.start_link(
        target: %BroadcastChannel{ref: ref, name: name, onmessage: nil},
        registry_key: ref,
        server_pid: self(),
        callback_module: nil
      )

    :ok = put_runtime_info(ref, %{dispatcher: dispatcher, closed: false})

    {:ok,
     %{
       ref: ref,
       name: name,
       owner: owner,
       owner_ref: Process.monitor(owner),
       dispatcher: dispatcher,
       creation_index: creation_index,
       event_target_pid: event_target_pid,
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
    :ok = EventTargetServer.add_event_listener(state.event_target_pid, type, callback, options)
    {:reply, :ok, state}
  end

  def handle_call({:remove_listener, type, callback}, _from, state) do
    :ok = EventTargetServer.remove_event_listener(state.event_target_pid, type, callback)
    {:reply, :ok, state}
  end

  def handle_call({:dispatch_event, event}, _from, state) do
    dispatched? = EventTargetServer.dispatch_event(state.event_target_pid, event, Snapshot.take())
    {:reply, dispatched?, state}
  end

  def handle_call(:close, _from, state) do
    {:reply, :ok, close_state(state)}
  end

  @impl true
  def handle_cast({:set_onmessage, callback}, state) do
    {:noreply, %{state | onmessage: callback}}
  end

  def handle_cast({:add_listener, type, callback, options}, state) do
    :ok = EventTargetServer.add_event_listener(state.event_target_pid, type, callback, options)
    {:noreply, state}
  end

  def handle_cast({:remove_listener, type, callback}, state) do
    :ok = EventTargetServer.remove_event_listener(state.event_target_pid, type, callback)
    {:noreply, state}
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

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    delete_runtime_info(state.ref)
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
    _dispatched? =
      EventTargetServer.dispatch_event(state.event_target_pid, event, Snapshot.take())

    state
  end

  defp public_channel(state) do
    %BroadcastChannel{ref: state.ref, name: state.name, onmessage: state.onmessage}
  end

  defp close_state(%{closed: true} = state), do: state

  defp close_state(state) do
    :ok = mark_closed(state.ref)
    :ok = Dispatcher.unregister(state.dispatcher, self())
    %{state | closed: true}
  end

  defp put_runtime_info(ref, info) do
    true = :ets.insert(table(), {ref, info})
    :ok
  end

  defp delete_runtime_info(ref) do
    :ets.delete(@table, ref)
    :ok
  end

  defp table, do: @table
end
