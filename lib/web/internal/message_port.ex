defmodule Web.Internal.MessagePort do
  @moduledoc false

  use GenServer

  alias Web.AsyncContext.Snapshot
  alias Web.DOMException
  alias Web.Internal.Envelope
  alias Web.Internal.EventTarget.Server, as: EventTargetServer
  alias Web.Internal.StructuredData
  alias Web.MessageEvent
  alias Web.MessagePort
  alias Web.TypeError

  @call_timeout 100
  @local_state_key {__MODULE__, :local_state}

  @doc false
  @spec start_pair(pid()) :: {MessagePort.t(), MessagePort.t()}
  def start_pair(holder_pid \\ self()) when is_pid(holder_pid) do
    {left_pid, left_handle} = start_port(holder_pid)
    {right_pid, right_handle} = start_port(holder_pid)

    :ok =
      left_pid
      |> request_target(
        left_handle.token,
        {:attach_peer, right_pid, right_handle.token},
        :infinity
      )
      |> raise_on_error()

    :ok =
      right_pid
      |> request_target(
        right_handle.token,
        {:attach_peer, left_pid, left_handle.token},
        :infinity
      )
      |> raise_on_error()

    {left_handle, right_handle}
  end

  @doc false
  @spec get_onmessage(MessagePort.t()) :: MessagePort.callback() | nil
  def get_onmessage(%MessagePort{} = port) do
    port
    |> request(:get_onmessage)
    |> raise_on_error()
  end

  @doc false
  @spec set_onmessage(MessagePort.t(), MessagePort.callback() | nil) :: :ok
  def set_onmessage(%MessagePort{} = port, callback)
      when is_nil(callback) or is_function(callback, 0) or is_function(callback, 1) do
    port
    |> request({:set_onmessage, callback})
    |> raise_on_error()
  end

  @doc false
  @spec add_event_listener(
          MessagePort.t(),
          String.t() | atom(),
          MessagePort.callback(),
          keyword() | map()
        ) ::
          :ok
  def add_event_listener(%MessagePort{} = port, type, callback, options)
      when is_function(callback, 0) or is_function(callback, 1) do
    port
    |> request({:add_event_listener, type, callback, options})
    |> raise_on_error()
  end

  @doc false
  @spec remove_event_listener(MessagePort.t(), String.t() | atom(), MessagePort.callback()) :: :ok
  def remove_event_listener(%MessagePort{} = port, type, callback)
      when is_function(callback, 0) or is_function(callback, 1) do
    port
    |> request({:remove_event_listener, type, callback})
    |> raise_on_error()
  end

  @doc false
  @spec dispatch_event(MessagePort.t(), Web.EventTarget.event()) :: boolean()
  def dispatch_event(%MessagePort{} = port, %{type: type} = event)
      when is_binary(type) or is_atom(type) do
    port
    |> request({:dispatch_event, event})
    |> raise_on_error()
  end

  @doc false
  @spec post_message(MessagePort.t(), term(), list()) :: :ok
  def post_message(%MessagePort{} = port, message, transfer) when is_list(transfer) do
    port
    |> request({:post_message, message, transfer})
    |> raise_on_error()
  end

  @doc false
  @spec close(MessagePort.t()) :: :ok
  def close(%MessagePort{} = port) do
    port
    |> request(:close)
    |> raise_on_error()
  end

  @doc false
  @spec ensure_transferable(MessagePort.t()) :: :ok
  def ensure_transferable(%MessagePort{} = port) do
    case local_state(port) do
      {:ok, state} ->
        case ensure_peer_available(state) do
          {:ok, next_state} ->
            put_local_state(next_state)
            :ok

          {:error, exception} ->
            raise(exception)

          {:stop, exception, next_state} ->
            put_local_state(next_state)
            raise(exception)
        end

      :error ->
        port
        |> request(:ensure_transferable)
        |> raise_on_error()
    end
  end

  @doc false
  @spec detach_transferable(MessagePort.t(), pid()) :: %{address: reference(), token: reference()}
  def detach_transferable(%MessagePort{} = port, recipient_pid)
      when is_pid(recipient_pid) do
    case local_state(port) do
      {:ok, state} ->
        {next_handle, next_state} = rotate_handle(state, recipient_pid)
        put_local_state(next_state)
        handle_fields(next_handle)

      :error ->
        port
        |> request({:transfer, recipient_pid})
        |> raise_on_error()
        |> handle_fields()
    end
  end

  @doc false
  @spec deserialize(%{address: reference(), token: reference()}) :: MessagePort.t()
  def deserialize(%{address: address, token: token})
      when is_reference(address) and is_reference(token) do
    %MessagePort{address: address, token: token, onmessage: nil}
  end

  @doc false
  @spec debug_server_pid(MessagePort.t()) :: pid()
  def debug_server_pid(%MessagePort{} = port) do
    port
    |> request(:debug_server_pid)
    |> raise_on_error()
  end

  @impl true
  def init({holder_pid, boot_pid, boot_ref}) do
    Process.flag(:message_queue_data, :off_heap)

    address = Process.alias()
    token = make_ref()

    {:ok, event_target_pid} = start_event_target(address, token)

    state = %{
      address: address,
      token: token,
      holder_pid: holder_pid,
      holder_monitor: Process.monitor(holder_pid),
      peer_pid: nil,
      peer_token: nil,
      peer_monitor: nil,
      event_target_pid: event_target_pid,
      onmessage: nil,
      closed: false
    }

    send(boot_pid, {__MODULE__, boot_ref, self(), public_handle(state)})
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

  def handle_info({:DOWN, peer_monitor, :process, peer_pid, _reason}, state)
      when peer_monitor == state.peer_monitor and peer_pid == state.peer_pid do
    {:stop, :normal, close_state(state, notify_peer: false)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_event_target(state.event_target_pid)
    clear_monitor(state.holder_monitor)
    clear_monitor(state.peer_monitor)
    Process.unalias(state.address)
    :ok
  end

  defp start_port(holder_pid) do
    boot_ref = make_ref()
    {:ok, pid} = GenServer.start(__MODULE__, {holder_pid, self(), boot_ref})

    receive do
      {__MODULE__, ^boot_ref, ^pid, handle} -> {pid, handle}
    end
  end

  defp do_handle_call(:debug_server_pid, _snapshot, state), do: {:reply, self(), state}

  defp do_handle_call(:get_onmessage, _snapshot, state) do
    case ensure_open(state) do
      :ok -> {:reply, state.onmessage, state}
      {:error, exception} -> {:reply, {:error, exception}, state}
    end
  end

  defp do_handle_call({:set_onmessage, callback}, _snapshot, state) do
    case ensure_open(state) do
      :ok -> {:reply, :ok, %{state | onmessage: callback}}
      {:error, exception} -> {:reply, {:error, exception}, state}
    end
  end

  defp do_handle_call({:add_event_listener, type, callback, options}, _snapshot, state) do
    case ensure_open(state) do
      :ok ->
        :ok =
          EventTargetServer.add_event_listener(state.event_target_pid, type, callback, options)

        {:reply, :ok, state}

      {:error, exception} ->
        {:reply, {:error, exception}, state}
    end
  end

  defp do_handle_call({:remove_event_listener, type, callback}, _snapshot, state) do
    case ensure_open(state) do
      :ok ->
        :ok = EventTargetServer.remove_event_listener(state.event_target_pid, type, callback)
        {:reply, :ok, state}

      {:error, exception} ->
        {:reply, {:error, exception}, state}
    end
  end

  defp do_handle_call({:dispatch_event, event}, snapshot, state) do
    case ensure_open(state) do
      :ok ->
        dispatched? = EventTargetServer.dispatch_event(state.event_target_pid, event, snapshot)
        {:reply, dispatched?, state}

      {:error, exception} ->
        {:reply, {:error, exception}, state}
    end
  end

  defp do_handle_call(:ensure_transferable, _snapshot, state) do
    case ensure_peer_available(state) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, exception} -> {:reply, {:error, exception}, state}
      {:stop, exception, next_state} -> {:stop, :normal, {:error, exception}, next_state}
    end
  end

  defp do_handle_call({:post_message, message, transfer}, snapshot, state) do
    case ensure_peer_available(state) do
      {:ok, next_state} ->
        reply_post_message(next_state, message, transfer, snapshot)

      {:error, exception} ->
        {:reply, {:error, exception}, state}

      {:stop, exception, next_state} ->
        {:stop, :normal, {:error, exception}, next_state}
    end
  end

  defp do_handle_call({:transfer, recipient_pid}, _snapshot, state)
       when is_pid(recipient_pid) do
    if Process.alive?(recipient_pid) do
      case ensure_peer_available(state) do
        {:ok, next_state} ->
          {handle, rotated_state} = rotate_handle(next_state, recipient_pid)
          {:reply, handle, rotated_state}

        {:error, exception} ->
          {:reply, {:error, exception}, state}

        {:stop, exception, next_state} ->
          {:stop, :normal, {:error, exception}, next_state}
      end
    else
      {:reply, {:error, data_clone_error_exception()}, state}
    end
  end

  defp do_handle_call({:transfer, _recipient}, _snapshot, state) do
    {:reply, {:error, data_clone_error_exception()}, state}
  end

  defp do_handle_call({:attach_peer, peer_pid, peer_token}, _snapshot, state)
       when is_pid(peer_pid) and is_reference(peer_token) do
    {:reply, :ok, attach_peer(state, peer_pid, peer_token)}
  end

  defp do_handle_call(:close, _snapshot, state) do
    {:stop, :normal, :ok, close_state(state)}
  end

  defp do_handle_call(_body, _snapshot, state) do
    {:reply, {:error, data_clone_error_exception()}, state}
  end

  defp reply_post_message(state, message, transfer, snapshot) do
    case serialize_for_delivery(state, message, transfer) do
      {:ok, serialized, final_state} ->
        :ok =
          cast_target(
            final_state.peer_pid,
            final_state.peer_token,
            {:deliver, serialized},
            snapshot
          )

        {:reply, :ok, final_state}

      {:error, exception, final_state} ->
        {:reply, {:error, exception}, final_state}
    end
  end

  defp serialize_for_delivery(state, message, transfer) do
    case with_local_state(state, fn ->
           StructuredData.serialize(message,
             transfer: transfer,
             message_port_recipient: state.peer_pid
           )
         end) do
      {:ok, serialized, final_state} ->
        {:ok, serialized, final_state}

      {:error, %DOMException{} = exception, _stacktrace, final_state} ->
        {:error, exception, final_state}

      {:error, %TypeError{} = exception, _stacktrace, final_state} ->
        {:error, exception, final_state}

      {:error, exception, stacktrace, _final_state} ->
        reraise(exception, stacktrace)
    end
  end

  defp do_handle_cast({:deliver, serialized}, snapshot, state) do
    next_state =
      if state.closed do
        state
      else
        deliver_message(state, serialized, snapshot)
      end

    {:noreply, next_state}
  end

  defp do_handle_cast(:peer_closed, _snapshot, state) do
    {:stop, :normal, close_state(state, notify_peer: false)}
  end

  defp do_handle_cast({:peer_token_rotated, peer_token}, _snapshot, state)
       when is_reference(peer_token) do
    {:noreply, %{state | peer_token: peer_token}}
  end

  defp do_handle_cast(_body, _snapshot, state), do: {:noreply, state}

  defp deliver_message(state, serialized, snapshot) do
    Snapshot.run(snapshot, fn ->
      event =
        MessageEvent.new("message",
          data: StructuredData.deserialize(serialized),
          source: nil,
          target: public_handle(state)
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

  defp rotate_handle(state, holder_pid) do
    next_state =
      state
      |> Map.put(:holder_pid, holder_pid)
      |> Map.put(:holder_monitor, replace_monitor(state.holder_monitor, holder_pid))
      |> restart_handle()

    if is_pid(next_state.peer_pid) and is_reference(next_state.peer_token) do
      :ok =
        cast_target(
          next_state.peer_pid,
          next_state.peer_token,
          {:peer_token_rotated, next_state.token}
        )
    end

    {public_handle(next_state), next_state}
  end

  defp restart_handle(state) do
    old_address = state.address
    stop_event_target(state.event_target_pid)

    address = Process.alias()
    token = make_ref()
    {:ok, event_target_pid} = start_event_target(address, token)

    Process.unalias(old_address)

    %{
      state
      | address: address,
        token: token,
        event_target_pid: event_target_pid,
        onmessage: nil
    }
  end

  defp attach_peer(state, peer_pid, peer_token) do
    %{
      state
      | peer_pid: peer_pid,
        peer_token: peer_token,
        peer_monitor: replace_monitor(state.peer_monitor, peer_pid)
    }
  end

  defp close_state(%{closed: true} = state, _opts), do: state

  defp close_state(state, opts) do
    if Keyword.get(opts, :notify_peer, true) and is_pid(state.peer_pid) and
         is_reference(state.peer_token) do
      :ok = cast_target(state.peer_pid, state.peer_token, :peer_closed)
    end

    Process.unalias(state.address)
    %{state | closed: true, onmessage: nil}
  end

  defp close_state(state), do: close_state(state, notify_peer: true)

  defp ensure_open(%{closed: false}), do: :ok
  defp ensure_open(_state), do: {:error, data_clone_error_exception()}

  defp ensure_peer_available(state) do
    case ensure_open(state) do
      :ok ->
        cond do
          not is_pid(state.peer_pid) or not is_reference(state.peer_token) ->
            {:stop, data_clone_error_exception(), close_state(state, notify_peer: false)}

          not Process.alive?(state.peer_pid) ->
            {:stop, data_clone_error_exception(), close_state(state, notify_peer: false)}

          true ->
            {:ok, state}
        end

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp request(%MessagePort{} = port, body, timeout \\ @call_timeout) do
    request_target(port.address, port.token, body, timeout)
  end

  defp request_target(target, token, body, timeout)
       when (is_pid(target) or is_reference(target)) and is_reference(token) do
    reply_ref = make_ref()
    send(target, {:"$gen_call", {self(), reply_ref}, Envelope.new(token, body)})
    await_reply(reply_ref, timeout)
  end

  defp cast_target(target, token, body, snapshot \\ Snapshot.take())
       when (is_pid(target) or is_reference(target)) and is_reference(token) do
    send(target, {:"$gen_cast", Envelope.new(token, body, snapshot)})
    :ok
  end

  defp await_reply(reply_ref, :infinity) do
    receive do
      {^reply_ref, reply} -> reply
    end
  end

  defp await_reply(reply_ref, timeout) do
    receive do
      {^reply_ref, reply} -> reply
    after
      timeout -> {:error, data_clone_error_exception()}
    end
  end

  defp replace_monitor(nil, pid) when is_pid(pid), do: Process.monitor(pid)

  defp replace_monitor(monitor_ref, pid) when is_reference(monitor_ref) and is_pid(pid) do
    Process.demonitor(monitor_ref, [:flush])
    Process.monitor(pid)
  end

  defp clear_monitor(monitor_ref) do
    if is_reference(monitor_ref) do
      Process.demonitor(monitor_ref, [:flush])
    end

    :ok
  end

  defp with_local_state(state, fun) when is_function(fun, 0) do
    previous = Process.get(@local_state_key)
    put_local_state(state)

    try do
      {:ok, fun.(), current_local_state()}
    rescue
      exception ->
        {:error, exception, __STACKTRACE__, current_local_state()}
    after
      restore_local_state(previous)
    end
  end

  defp local_state(%MessagePort{} = port) do
    case Process.get(@local_state_key) do
      %{key: key, state: state} ->
        if key == handle_key(port) do
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
      # coveralls-ignore-next-line
      _other -> raise "missing local MessagePort state"
    end
  end

  defp put_local_state(state) do
    Process.put(@local_state_key, %{key: handle_key(public_handle(state)), state: state})
    state
  end

  defp restore_local_state(nil) do
    Process.delete(@local_state_key)
    :ok
  end

  defp restore_local_state(previous) do
    Process.put(@local_state_key, previous)
    :ok
  end

  defp start_event_target(address, token) do
    EventTargetServer.start_link(
      target: %MessagePort{address: address, token: token, onmessage: nil},
      callback_module: nil
    )
  end

  defp stop_event_target(pid) do
    if is_pid(pid) and Process.alive?(pid) do
      Process.unlink(pid)
      GenServer.stop(pid, :normal)
    end

    :ok
  end

  defp public_handle(state) do
    %MessagePort{address: state.address, token: state.token, onmessage: state.onmessage}
  end

  defp handle_key(%MessagePort{address: address, token: token}), do: {address, token}

  defp handle_fields(%MessagePort{address: address, token: token}) do
    %{address: address, token: token}
  end

  defp data_clone_error_exception do
    DOMException.exception(name: "DataCloneError", message: "MessagePort is closed or detached")
  end

  defp raise_on_error({:error, exception}), do: raise(exception)
  defp raise_on_error(value), do: value
end
