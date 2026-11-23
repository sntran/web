defmodule Web.Internal.BroadcastChannel do
  @moduledoc false

  # The server of one broadcast channel. See `Web.Internal.MessageTarget`
  # for the two processes of a channel, and `tla/BroadcastChannel.tla` for
  # the design.
  #
  # The servers of all the channels with one name are the members of one
  # group of the adapter. A server sends a message to each other member, and
  # does not wait. Thus:
  #
  #   * the messages of one channel arrive at each other channel in their
  #     sequence, because they come from one process;
  #   * a channel with a slow listener delays only its own events;
  #   * the channels have no shared process that can stop or fill up.
  #
  # The server stops when the channel closes. A request to a server that
  # stopped has no effect.

  use GenServer, restart: :temporary

  alias Web.AsyncContext.Snapshot
  alias Web.BroadcastChannel
  alias Web.BroadcastChannel.Adapter.PG
  alias Web.DOMException
  alias Web.Governor
  alias Web.Internal.MessageTarget
  alias Web.Internal.StructuredData
  alias Web.MessageEvent

  # ---------------------------------------------------------------------------
  # Functions for the process that has a handle
  # ---------------------------------------------------------------------------

  @doc "Makes a channel. `holder` keeps it alive."
  @spec new(String.t(), pid()) :: BroadcastChannel.t()
  def new(name, holder \\ self()) when is_binary(name) and is_pid(holder) do
    token = make_ref()
    pid = MessageTarget.start_server(__MODULE__, {name, holder, token, adapter()})
    %BroadcastChannel{address: pid, token: token, name: name}
  end

  @doc """
  Sends a message to each other channel with the same name, as the steps of
  `postMessage()` in the HTML Standard.
  """
  @spec post_message(BroadcastChannel.t(), term()) :: :ok
  def post_message(%BroadcastChannel{} = channel, message) do
    record = serialize(channel, message)

    payload = %{record: record, origin: origin(), snapshot: Snapshot.new()}

    case with_governor(fn -> MessageTarget.call(channel, {:post, payload}) end) do
      :ok -> :ok
      {:error, _reason} -> raise closed_error()
    end
  end

  # The Standard examines the closed state before the message. The usual
  # message can be cloned, thus the function asks the server only after a
  # failure.
  defp serialize(channel, message) do
    StructuredData.serialize(message)
  rescue
    exception in DOMException ->
      error = if open?(channel), do: exception, else: closed_error()
      reraise error, __STACKTRACE__
  end

  @spec close(BroadcastChannel.t()) :: :ok
  def close(%BroadcastChannel{} = channel) do
    _reply = MessageTarget.call(channel, :close)
    :ok
  end

  defp open?(channel), do: MessageTarget.call(channel, :open?) == true

  # The setting `:broadcast_governor` limits the rate of the messages. The
  # process that sends the message waits for the governor.
  defp with_governor(fun) do
    case Application.get_env(:web, :broadcast_governor) do
      nil ->
        fun.()

      governor ->
        governor
        |> Governor.with(fun)
        |> Web.Promise.await()
    end
  end

  defp adapter, do: Application.get_env(:web, :broadcast_adapter, PG)

  @doc "The origin of the messages of this node."
  @spec origin() :: String.t()
  def origin, do: "node://" <> Atom.to_string(node())

  # ---------------------------------------------------------------------------
  # The function that makes the event, in the listener process
  # ---------------------------------------------------------------------------

  # The channel fires each event, as "fire an event" of the DOM Standard:
  # the event is trusted.
  @doc false
  def message_event(%{record: record, origin: origin}, target) do
    MessageEvent.__create__("message",
      data: StructuredData.deserialize(record),
      origin: origin,
      target: target
    )
  rescue
    # The Standard fires `messageerror` when the message cannot be made.
    _exception -> MessageEvent.__create__("messageerror", origin: origin, target: target)
  end

  # ---------------------------------------------------------------------------
  # The server
  # ---------------------------------------------------------------------------

  def start_link(argument), do: GenServer.start_link(__MODULE__, argument)

  @impl true
  def init({name, holder, token, adapter}) do
    Process.flag(:message_queue_data, :off_heap)

    handle = %BroadcastChannel{address: self(), token: token, name: name}

    state = %{
      token: token,
      name: name,
      adapter: adapter,
      handle: handle,
      holder_monitor: Process.monitor(holder),
      target: MessageTarget.start(handle)
    }

    :ok = adapter.join(name, self())
    {:ok, state}
  end

  @impl true
  def handle_call({token, request}, _from, %{token: token} = state) do
    request(request, state)
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :detached}, state}

  @impl true
  def handle_cast(_request, state), do: {:noreply, state}

  # A message from a different channel with the same name.
  @impl true
  def handle_info(
        {:broadcast_channel_message, %{record: _, origin: _, snapshot: snapshot} = payload},
        state
      ) do
    build = {__MODULE__, :message_event, [payload, state.handle]}
    MessageTarget.run(state.target, build, snapshot)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{holder_monitor: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    MessageTarget.close(state.target)
    state.adapter.leave(state.name, self())
    :ok
  end

  defp request({:post, payload}, state) do
    :ok = state.adapter.broadcast(state.name, self(), {:broadcast_channel_message, payload})
    {:reply, :ok, state}
  end

  defp request(:open?, state), do: {:reply, true, state}
  defp request(:close, state), do: {:stop, :normal, :ok, state}

  defp request(request, state) do
    case MessageTarget.request(state.target, request) do
      {:reply, reply, target} -> {:reply, reply, %{state | target: target}}
      :unknown -> {:reply, {:error, :unknown_request}, state}
    end
  end

  defp closed_error do
    DOMException.exception(name: "InvalidStateError", message: "The BroadcastChannel is closed.")
  end
end
