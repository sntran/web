defmodule Web.Internal.BroadcastChannel do
  @moduledoc false

  use GenServer

  alias Web.AsyncContext.Snapshot
  alias Web.BroadcastChannel
  alias Web.BroadcastChannel.Dispatcher
  alias Web.DOMException
  alias Web.Internal.Envelope
  alias Web.Internal.EventTarget.Server, as: EventTargetServer
  alias Web.Internal.StructuredData
  alias Web.MessageEvent
  alias Web.TypeError

  @call_timeout 100
  @local_state_key {__MODULE__, :local_state}

  @doc false
  @spec new(String.t(), pid()) :: BroadcastChannel.t()
  def new(name, holder_pid \\ self()) when is_binary(name) and is_pid(holder_pid) do
    boot_ref = make_ref()
    {:ok, pid} = GenServer.start(__MODULE__, {name, holder_pid, self(), boot_ref})

    receive do
      {__MODULE__, ^boot_ref, ^pid, channel} -> channel
    end
  end

  @doc false
  @spec get_onmessage(BroadcastChannel.t()) :: BroadcastChannel.callback() | nil
  def get_onmessage(%BroadcastChannel{} = channel) do
    case local_state(channel) do
      {:ok, state} -> open_local_state!(state).onmessage
      :error -> channel |> request(:get_onmessage) |> raise_on_error()
    end
  end

  @doc false
  @spec set_onmessage(BroadcastChannel.t(), BroadcastChannel.callback() | nil) :: :ok
  def set_onmessage(%BroadcastChannel{} = channel, callback)
      when is_nil(callback) or is_function(callback, 0) or is_function(callback, 1) do
    case local_state(channel) do
      {:ok, state} ->
        state = open_local_state!(state)
        put_local_state(%{state | onmessage: callback})
        :ok

      :error ->
        channel
        |> request({:set_onmessage, callback})
        |> raise_on_error()
    end
  end

  @doc false
  @spec add_event_listener(
          BroadcastChannel.t(),
          String.t() | atom(),
          BroadcastChannel.callback(),
          keyword() | map()
        ) :: :ok
  def add_event_listener(%BroadcastChannel{} = channel, type, callback, options)
      when is_function(callback, 0) or is_function(callback, 1) do
    case local_state(channel) do
      {:ok, state} ->
        state = open_local_state!(state)
        EventTargetServer.add_event_listener(state.event_target_pid, type, callback, options)

      :error ->
        channel |> request({:add_event_listener, type, callback, options}) |> raise_on_error()
    end
  end

  @doc false
  @spec remove_event_listener(
          BroadcastChannel.t(),
          String.t() | atom(),
          BroadcastChannel.callback()
        ) :: :ok
  def remove_event_listener(%BroadcastChannel{} = channel, type, callback)
      when is_function(callback, 0) or is_function(callback, 1) do
    case local_state(channel) do
      {:ok, state} ->
        state = open_local_state!(state)
        EventTargetServer.remove_event_listener(state.event_target_pid, type, callback)

      :error ->
        channel |> request({:remove_event_listener, type, callback}) |> raise_on_error()
    end
  end

  @doc false
  @spec dispatch_event(BroadcastChannel.t(), Web.EventTarget.event()) :: boolean()
  def dispatch_event(%BroadcastChannel{} = channel, %{type: type} = event)
      when is_binary(type) or is_atom(type) do
    case local_state(channel) do
      {:ok, state} ->
        state = open_local_state!(state)
        EventTargetServer.dispatch_event(state.event_target_pid, event, Snapshot.take())

      :error ->
        channel |> request({:dispatch_event, event}) |> raise_on_error()
    end
  end

  @doc false
  @spec post_message(BroadcastChannel.t(), term()) :: :ok
  def post_message(%BroadcastChannel{} = channel, data) do
    case local_state(channel) do
      {:ok, state} -> local_post(state, data)
      :error -> channel |> request({:post_message, data, origin()}) |> raise_on_error()
    end
  end

  @doc false
  @spec close(BroadcastChannel.t()) :: :ok
  def close(%BroadcastChannel{} = channel) do
    case local_state(channel) do
      {:ok, state} ->
        put_local_state(close_state(state))
        :ok

      :error ->
        channel
        |> request(:close)
        |> raise_on_error()
    end
  end

  @doc false
  @spec debug_server_pid(BroadcastChannel.t()) :: pid()
  def debug_server_pid(%BroadcastChannel{} = channel) do
    channel
    |> request(:debug_server_pid)
    |> raise_on_error()
  end

  @impl true
  def init({name, holder_pid, boot_pid, boot_ref}) do
    Process.flag(:message_queue_data, :off_heap)

    address = Process.alias()
    token = make_ref()

    %{dispatcher: dispatcher, creation_index: creation_index} =
      Dispatcher.register(name, self(), token)

    {:ok, event_target_pid} =
      EventTargetServer.start_link(
        target: %BroadcastChannel{address: address, token: token, name: name, onmessage: nil},
        server_pid: self(),
        callback_module: nil
      )

    state = %{
      address: address,
      token: token,
      name: name,
      holder_pid: holder_pid,
      holder_monitor: Process.monitor(holder_pid),
      dispatcher: dispatcher,
      creation_index: creation_index,
      event_target_pid: event_target_pid,
      onmessage: nil,
      closed: false
    }

    send(boot_pid, {__MODULE__, boot_ref, self(), public_channel(state)})
    {:ok, state}
  end

  @impl true
  def handle_call(
        %Envelope{
          headers: %{"Authorization" => token, "X-Async-Context" => snapshot},
          body: body
        },
        _from,
        %{token: token} = state
      ) do
    do_handle_call(body, snapshot, state)
  end

  def handle_call({:envelope, %Envelope{} = envelope}, from, state) do
    handle_call(envelope, from, state)
  end

  def handle_call(%Envelope{}, _from, state) do
    {:reply, {:error, data_clone_error_exception()}, state}
  end

  def handle_call({:envelope, _envelope}, _from, state) do
    {:reply, {:error, data_clone_error_exception()}, state}
  end

  @impl true
  def handle_cast(
        %Envelope{
          headers: %{"Authorization" => token, "X-Async-Context" => snapshot},
          body: body
        },
        %{token: token} = state
      ) do
    do_handle_cast(body, snapshot, state)
  end

  def handle_cast({:envelope, %Envelope{} = envelope}, state) do
    handle_cast(envelope, state)
  end

  def handle_cast(%Envelope{}, state), do: {:noreply, state}
  def handle_cast({:envelope, _envelope}, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, holder_monitor, :process, holder_pid, _reason}, state)
      when holder_monitor == state.holder_monitor and holder_pid == state.holder_pid do
    {:stop, :normal, close_state(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_event_target(state.event_target_pid)
    Process.demonitor(state.holder_monitor, [:flush])

    if not state.closed do
      :ok = Dispatcher.unregister(state.dispatcher, self())
    end

    Process.unalias(state.address)
    :ok
  end

  defp do_handle_call(:debug_server_pid, _snapshot, state), do: {:reply, self(), state}

  defp do_handle_call(:get_onmessage, _snapshot, state) do
    case check_open(state) do
      {:ok, next_state} -> {:reply, next_state.onmessage, next_state}
      {:error, exception} -> {:reply, {:error, exception}, state}
    end
  end

  defp do_handle_call({:set_onmessage, callback}, _snapshot, state) do
    case check_open(state) do
      {:ok, next_state} -> {:reply, :ok, %{next_state | onmessage: callback}}
      {:error, exception} -> {:reply, {:error, exception}, state}
    end
  end

  defp do_handle_call({:add_event_listener, type, callback, options}, _snapshot, state) do
    case check_open(state) do
      {:ok, next_state} ->
        :ok =
          EventTargetServer.add_event_listener(
            next_state.event_target_pid,
            type,
            callback,
            options
          )

        {:reply, :ok, next_state}

      {:error, exception} ->
        {:reply, {:error, exception}, state}
    end
  end

  defp do_handle_call({:remove_event_listener, type, callback}, _snapshot, state) do
    case check_open(state) do
      {:ok, next_state} ->
        :ok = EventTargetServer.remove_event_listener(next_state.event_target_pid, type, callback)
        {:reply, :ok, next_state}

      {:error, exception} ->
        {:reply, {:error, exception}, state}
    end
  end

  defp do_handle_call({:dispatch_event, event}, snapshot, state) do
    case check_open(state) do
      {:ok, next_state} ->
        dispatched? =
          EventTargetServer.dispatch_event(next_state.event_target_pid, event, snapshot)

        {:reply, dispatched?, next_state}

      {:error, exception} ->
        {:reply, {:error, exception}, state}
    end
  end

  defp do_handle_call({:post_message, data, origin}, snapshot, state) do
    case check_open(state) do
      {:ok, next_state} ->
        cloned = Web.structured_clone(data)
        serialized = StructuredData.serialize(cloned)

        :ok =
          Dispatcher.post(next_state.dispatcher, self(), %{
            origin: origin,
            serialized: serialized,
            snapshot: snapshot
          })

        {:reply, :ok, next_state}

      {:error, exception} ->
        {:reply, {:error, exception}, state}
    end
  rescue
    exception in [DOMException, TypeError] ->
      {:reply, {:error, exception}, state}
  end

  defp do_handle_call(:close, _snapshot, state) do
    {:reply, :ok, close_state(state)}
  end

  defp do_handle_call(_body, _snapshot, state) do
    {:reply, {:error, data_clone_error_exception()}, state}
  end

  defp do_handle_cast(
         {:deliver, dispatcher, dispatch_ref, %{origin: origin, serialized: serialized}},
         snapshot,
         state
       ) do
    next_state =
      if state.closed,
        do: state,
        else: deliver_message(state, origin, serialized, snapshot)

    send(dispatcher, {:broadcast_channel_delivery_complete, dispatch_ref, self()})
    {:noreply, next_state}
  rescue
    exception ->
      send(dispatcher, {:broadcast_channel_delivery_complete, dispatch_ref, self()})
      reraise(exception, __STACKTRACE__)
  end

  defp do_handle_cast(_body, _snapshot, state), do: {:noreply, state}

  defp deliver_message(state, origin, serialized, snapshot) do
    Snapshot.run(snapshot, fn ->
      with_local_state(state, fn ->
        event =
          MessageEvent.new("message",
            data: StructuredData.deserialize(serialized),
            origin: origin,
            source: nil,
            target: public_channel(state)
          )

        invoke_onmessage(state, event)
        dispatch_event_target(state, event)
      end)
    end)
  end

  defp invoke_onmessage(%{onmessage: nil}, _event), do: :ok

  defp invoke_onmessage(%{onmessage: callback}, event) when is_function(callback, 1) do
    callback.(event)
  end

  defp invoke_onmessage(%{onmessage: callback}, _event) when is_function(callback, 0) do
    callback.()
  end

  defp dispatch_event_target(state, event) do
    _dispatched? =
      EventTargetServer.dispatch_event(state.event_target_pid, event, Snapshot.take())

    :ok
  end

  defp local_post(state, _data) when state.closed, do: raise(data_clone_error_exception())

  defp local_post(state, data) do
    cloned = Web.structured_clone(data)
    serialized = StructuredData.serialize(cloned)

    :ok =
      Dispatcher.post(state.dispatcher, self(), %{
        origin: origin(),
        serialized: serialized,
        snapshot: Snapshot.take()
      })
  end

  defp with_local_state(state, fun) when is_function(fun, 0) do
    previous = Process.get(@local_state_key)
    put_local_state(state)

    try do
      fun.()
      current_local_state()
    after
      restore_local_state(previous)
    end
  end

  defp local_state(%BroadcastChannel{} = channel) do
    case Process.get(@local_state_key) do
      %{key: key, state: state} ->
        if key == handle_key(channel) do
          {:ok, state}
        else
          :error
        end

      _other ->
        :error
    end
  end

  defp current_local_state do
    case Process.get(@local_state_key) do
      %{state: state} -> state
      _other -> raise "missing local BroadcastChannel state"
    end
  end

  defp put_local_state(state) do
    Process.put(@local_state_key, %{key: handle_key(public_channel(state)), state: state})
    state
  end

  defp restore_local_state(previous) do
    Process.put(@local_state_key, previous)
    :ok
  end

  defp close_state(%{closed: true} = state), do: state

  defp close_state(state) do
    Process.unalias(state.address)
    :ok = Dispatcher.unregister(state.dispatcher, self())
    %{state | closed: true, onmessage: nil}
  end

  defp open_local_state!(state) do
    case check_open(state) do
      {:ok, next_state} -> next_state
      {:error, exception} -> raise(exception)
    end
  end

  defp check_open(%{closed: false} = state), do: {:ok, state}
  defp check_open(_state), do: {:error, data_clone_error_exception()}

  defp request(%BroadcastChannel{} = channel, body, timeout \\ @call_timeout) do
    request_target(channel.address, channel.token, body, timeout)
  end

  defp request_target(target, token, body, timeout)
       when (is_pid(target) or is_reference(target)) and is_reference(token) do
    reply_ref = make_ref()
    send(target, {:"$gen_call", {self(), reply_ref}, Envelope.new(token, body)})
    await_reply(reply_ref, timeout)
  end

  defp await_reply(reply_ref, timeout) do
    receive do
      {^reply_ref, reply} -> reply
    after
      timeout -> {:error, data_clone_error_exception()}
    end
  end

  defp stop_event_target(pid) do
    if is_pid(pid) and Process.alive?(pid) do
      Process.unlink(pid)
      GenServer.stop(pid, :normal)
    end

    :ok
  end

  defp public_channel(state) do
    %BroadcastChannel{
      address: state.address,
      token: state.token,
      name: state.name,
      onmessage: state.onmessage
    }
  end

  defp handle_key(%BroadcastChannel{address: address, token: token}), do: {address, token}

  defp data_clone_error_exception do
    DOMException.exception(name: "DataCloneError", message: "BroadcastChannel handle is invalid")
  end

  defp origin do
    "node://" <> Atom.to_string(node())
  end

  defp raise_on_error({:error, exception}), do: raise(exception)
  defp raise_on_error(value), do: value
end
