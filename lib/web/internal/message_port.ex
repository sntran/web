defmodule Web.Internal.MessagePort do
  @moduledoc false

  # The server of one message port. See `Web.Internal.MessageTarget` for the
  # two processes of a port, and `tla/MessagePort.tla` for the design.
  #
  # ## The port message queue
  #
  # A message for the port goes into the queue of the server. The server
  # gives the messages to the listener process one at a time, and only after
  # the port started. Thus a message that comes before a listener is not
  # lost, and a transfer moves the messages that were not delivered together
  # with the port.
  #
  # ## The two ports of a channel
  #
  # Each server has the pid of the server of the other port, and the two
  # servers share one reference: the link. A server sends to its peer and
  # does not wait. All the messages from one port to the other come from one
  # process, thus they arrive in their sequence, and the notice of a close
  # arrives after them.
  #
  # A server never calls a different server. Only a process that has a
  # handle calls a server. Thus two servers cannot wait for each other.
  #
  # ## The holder
  #
  # The VM cannot tell when a port has no more references. A port thus
  # stays until a process closes it, or until its holder stops. The holder
  # is the process that made the channel. After a transfer, the holder is
  # the holder of the port that got the message.

  use GenServer, restart: :temporary

  alias Web.AsyncContext.Snapshot
  alias Web.DOMException
  alias Web.Internal.MessageTarget
  alias Web.Internal.StructuredData
  alias Web.MessageEvent
  alias Web.MessagePort

  # ---------------------------------------------------------------------------
  # Functions for the process that has a handle
  # ---------------------------------------------------------------------------

  @doc "Makes the two ports of a channel. `holder` keeps them alive."
  @spec start_pair(pid()) :: {MessagePort.t(), MessagePort.t()}
  def start_pair(holder \\ self()) when is_pid(holder) do
    link = make_ref()
    left = start_port(holder, link)
    right = start_port(holder, link)

    _reply = MessageTarget.call(left, {:entangle, right.address})
    _reply = MessageTarget.call(right, {:entangle, left.address})

    {left, right}
  end

  defp start_port(holder, link) do
    token = make_ref()
    pid = MessageTarget.start_server(__MODULE__, {holder, token, link})
    %MessagePort{address: pid, token: token}
  end

  @spec start(MessagePort.t()) :: :ok
  def start(%MessagePort{} = port) do
    _reply = MessageTarget.call(port, :start)
    :ok
  end

  @spec close(MessagePort.t()) :: :ok
  def close(%MessagePort{} = port) do
    _reply = MessageTarget.call(port, :close)
    :ok
  end

  @doc """
  Sends a message to the other port, as the steps of `postMessage()` in the
  HTML Standard.
  """
  @spec post_message(MessagePort.t(), term(), list()) :: :ok
  def post_message(%MessagePort{} = port, message, transfer) when is_list(transfer) do
    if Enum.any?(transfer, &same_port?(&1, port)) do
      raise data_clone_error("A MessagePort cannot transfer itself.")
    end

    peer =
      case MessageTarget.call(port, :peer) do
        {:ok, pid} when is_pid(pid) -> pid
        _other -> nil
      end

    # A transfer of the port that gets the message makes the message
    # impossible to deliver. The Standard calls such a message doomed.
    doomed? = peer != nil and Enum.any?(transfer, &match?(%MessagePort{address: ^peer}, &1))

    # The server of the peer keeps a transferred port until the peer
    # delivers the message.
    record = StructuredData.serialize(message, transfer: transfer, port_holder: peer || self())
    payload = %{record: record, snapshot: Snapshot.new()}

    if peer == nil or doomed? or MessageTarget.call(port, {:post, payload}) != :sent do
      discard(record)
    end

    :ok
  end

  # A message that nobody gets: its ports are lost, thus close them.
  defp discard(%StructuredData.Record{ports: ports}) do
    Enum.each(ports, fn fields -> fields |> deserialize() |> close() end)
  end

  defp same_port?(%MessagePort{address: address, token: token}, %MessagePort{
         address: address,
         token: token
       }),
       do: true

  defp same_port?(_left, _right), do: false

  @doc "Raises `DataCloneError` when the port cannot be transferred."
  @spec ensure_transferable(MessagePort.t()) :: :ok
  def ensure_transferable(%MessagePort{} = port) do
    case MessageTarget.call(port, :transferable?) do
      :ok -> :ok
      {:error, _reason} -> raise detached_error()
    end
  end

  @doc """
  Detaches the handle and gives the port to a new holder. Returns the
  fields of the new handle.
  """
  @spec detach_transferable(MessagePort.t(), pid()) :: %{address: pid(), token: reference()}
  def detach_transferable(%MessagePort{address: address} = port, holder) when is_pid(holder) do
    case MessageTarget.call(port, {:transfer, holder}) do
      {:ok, token} -> %{address: address, token: token}
      {:error, _reason} -> raise detached_error()
    end
  end

  @doc "Makes a handle from its fields."
  @spec deserialize(%{address: pid(), token: reference()}) :: MessagePort.t()
  def deserialize(%{address: address, token: token})
      when is_pid(address) and is_reference(token) do
    %MessagePort{address: address, token: token}
  end

  # ---------------------------------------------------------------------------
  # Functions that make the events, in the listener process
  # ---------------------------------------------------------------------------

  @doc false
  def message_event(record, target) do
    {data, ports} = StructuredData.deserialize_with_ports(record)
    MessageEvent.__new__("message", data: data, ports: ports, target: target)
  rescue
    # The Standard fires `messageerror` when the message cannot be made.
    _exception -> MessageEvent.__new__("messageerror", target: target)
  end

  @doc false
  def close_event(target), do: Web.Event.__new__("close", target: target)

  # ---------------------------------------------------------------------------
  # The server
  # ---------------------------------------------------------------------------

  def start_link(argument), do: GenServer.start_link(__MODULE__, argument)

  @impl true
  def init({holder, token, link}) do
    Process.flag(:message_queue_data, :off_heap)

    state = %{
      token: token,
      link: link,
      holder: holder,
      holder_monitor: Process.monitor(holder),
      peer: nil,
      peer_monitor: nil,
      entangled?: false,
      started?: false,
      queue: :queue.new(),
      # The item that the listener process has now, with its number.
      in_flight: nil,
      next_number: 0,
      target: nil
    }

    {:ok, start_target(state)}
  end

  @impl true
  def handle_call({token, request}, _from, %{token: token} = state) do
    request(request, state)
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :detached}, state}

  @impl true
  def handle_cast(_request, state), do: {:noreply, state}

  # A message from the other port.
  @impl true
  def handle_info({:port_message, link, payload}, %{link: link} = state) do
    {:noreply, state |> enqueue({:message, payload}) |> pump()}
  end

  # The other port closed.
  def handle_info({:port_closed, link}, %{link: link, peer: peer} = state) when is_pid(peer) do
    {:noreply, peer_closed(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{holder_monitor: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{peer_monitor: ref} = state) do
    {:noreply, peer_closed(state)}
  end

  # The listener process completed the event of the item.
  def handle_info({:event_done, number}, %{in_flight: {number, _item}} = state) do
    {:noreply, pump(%{state | in_flight: nil})}
  end

  # The listener process stopped before it started the item: a transfer
  # moved the port. The item goes back to the head of the queue.
  def handle_info({:event_returned, number}, %{in_flight: {number, item}} = state) do
    queue =
      if item == :close and :queue.member(:close, state.queue) do
        # The transfer put the event `close` in the queue for the new holder.
        state.queue
      else
        :queue.in_r(item, state.queue)
      end

    {:noreply, pump(%{state | in_flight: nil, queue: queue})}
  end

  # The port that got this port in a message gives it to its holder.
  def handle_info({:set_holder, token, holder}, %{token: token} = state) when is_pid(holder) do
    {:noreply, set_holder(state, holder)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    MessageTarget.close(state.target)

    if is_pid(state.peer) do
      send(state.peer, {:port_closed, state.link})
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Requests
  # ---------------------------------------------------------------------------

  defp request({:entangle, peer}, %{entangled?: false} = state) when is_pid(peer) do
    state = %{state | peer: peer, peer_monitor: Process.monitor(peer), entangled?: true}
    {:reply, :ok, state}
  end

  defp request(:peer, state), do: {:reply, {:ok, state.peer}, state}

  defp request({:post, payload}, %{peer: peer} = state) when is_pid(peer) do
    send(peer, {:port_message, state.link, payload})
    {:reply, :sent, state}
  end

  defp request({:post, _payload}, state), do: {:reply, :dropped, state}

  defp request(:start, state) do
    {:reply, :ok, pump(%{state | started?: true})}
  end

  defp request(:transferable?, state), do: {:reply, :ok, state}

  # A transfer gives the port a new handle and a new holder. The listeners
  # do not move with the port, and the port does not deliver until its new
  # holder starts it. The messages in the queue stay.
  defp request({:transfer, holder}, state) when is_pid(holder) do
    MessageTarget.close(state.target)
    token = make_ref()

    state =
      %{state | token: token, started?: false}
      |> set_holder(holder)
      |> start_target()
      |> close_for_new_holder()

    {:reply, {:ok, token}, state}
  end

  defp request(:close, state), do: {:stop, :normal, :ok, state}

  defp request(request, state) do
    case MessageTarget.request(state.target, request) do
      {:reply, reply, target} ->
        state = %{state | target: target}
        {:reply, reply, maybe_start(request, state)}

      :unknown ->
        {:reply, {:error, :unknown_request}, state}
    end
  end

  # The first callback of `onmessage` starts the port, as the HTML Standard
  # specifies.
  defp maybe_start({:set_handler, "message", callback}, state) when callback != nil do
    pump(%{state | started?: true})
  end

  defp maybe_start(_request, state), do: state

  # ---------------------------------------------------------------------------
  # State changes
  # ---------------------------------------------------------------------------

  defp start_target(state) do
    %{state | target: MessageTarget.start(handle(state))}
  end

  defp handle(state), do: %MessagePort{address: self(), token: state.token}

  defp set_holder(state, holder) do
    Process.demonitor(state.holder_monitor, [:flush])
    %{state | holder: holder, holder_monitor: Process.monitor(holder)}
  end

  # The port has no peer now, and it gets the event `close`.
  #
  # A port that started gets the event after the messages that the peer
  # sent. A port that did not start gets the event immediately: the event
  # does not wait in the port message queue, as in the HTML Standard. Thus a
  # port that only sends learns that its peer closed.
  defp peer_closed(state) do
    if state.peer_monitor, do: Process.demonitor(state.peer_monitor, [:flush])
    state = %{state | peer: nil, peer_monitor: nil}

    if state.started? do
      state |> enqueue(:close) |> pump()
    else
      MessageTarget.run(state.target, close_build(state), Snapshot.new())
      state
    end
  end

  # The listeners do not move with a port. The new holder of a port whose
  # peer closed gets the event `close` after it starts the port.
  defp close_for_new_holder(%{peer: nil, entangled?: true} = state) do
    if :queue.member(:close, state.queue), do: state, else: enqueue(state, :close)
  end

  defp close_for_new_holder(state), do: state

  defp close_build(state), do: {__MODULE__, :close_event, [handle(state)]}

  defp enqueue(state, item), do: %{state | queue: :queue.in(item, state.queue)}

  # Gives the next item to the listener process, when the port started and
  # the listener process has no item.
  defp pump(%{started?: true, in_flight: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, item}, queue} ->
        number = state.next_number
        deliver(item, number, state)
        %{state | queue: queue, in_flight: {number, item}, next_number: number + 1}

      {:empty, _queue} ->
        state
    end
  end

  defp pump(state), do: state

  defp deliver({:message, %{record: record, snapshot: snapshot}}, number, state) do
    # The holder of this port becomes the holder of each port in the
    # message.
    Enum.each(record.ports, fn %{address: pid, token: token} ->
      send(pid, {:set_holder, token, state.holder})
    end)

    build = {__MODULE__, :message_event, [record, handle(state)]}
    MessageTarget.run(state.target, build, snapshot, {self(), number})
  end

  defp deliver(:close, number, state) do
    MessageTarget.run(state.target, close_build(state), Snapshot.new(), {self(), number})
  end

  defp detached_error do
    data_clone_error("A MessagePort that is closed or detached cannot be transferred.")
  end

  defp data_clone_error(message) do
    DOMException.exception(name: "DataCloneError", message: message)
  end
end
