defmodule Web.BroadcastChannel do
  @moduledoc """
  WHATWG-style BroadcastChannel backed by a configurable distributed adapter.

  The API keeps the browser semantics while presenting an idiomatic Elixir
  surface with snake_case function names.
  """

  alias Web.AsyncContext.Snapshot
  alias Web.BroadcastChannel.ChannelServer
  alias Web.BroadcastChannel.Dispatcher
  alias Web.DOMException
  alias Web.EventTarget
  alias Web.Internal.StructuredData

  defstruct [:ref, :name, onmessage: nil]

  @type callback :: (Web.MessageEvent.t() -> any()) | (-> any())

  @type t :: %__MODULE__{
          ref: reference(),
          name: String.t(),
          onmessage: callback() | nil
        }

  defimpl Web.EventTarget.Protocol do
    def add_event_listener(target, type, callback, options) do
      Web.EventTarget.__add_event_listener__(target, type, callback, options)
    end

    def remove_event_listener(target, type, callback) do
      Web.EventTarget.__remove_event_listener__(target, type, callback)
    end

    def dispatch_event(target, event) do
      Web.EventTarget.__dispatch_event__(target, event)
    end
  end

  @doc """
  Creates a new broadcast channel for the given name.

  Values are coerced with `to_string/1`, matching the JavaScript constructor's
  stringification behavior.

  ## Examples

      iex> channel = Web.BroadcastChannel.new(:news)
      iex> channel.name
      "news"
      iex> Web.BroadcastChannel.close(channel)
      :ok
  """
  @spec new(term()) :: t()
  def new(name) do
    normalized_name = normalize_name(name)
    ref = make_ref()
    {:ok, _pid} = ChannelServer.start(normalized_name, self(), ref)
    %__MODULE__{ref: ref, name: normalized_name, onmessage: nil}
  end

  @doc false
  @spec onmessage(t()) :: callback() | nil
  def onmessage(%__MODULE__{} = channel) do
    case lookup_server_pid(channel) do
      nil -> nil
      pid -> GenServer.call(pid, :get_onmessage, :infinity)
    end
  end

  @doc false
  @spec onmessage(t(), callback() | nil) :: t()
  def onmessage(%__MODULE__{} = channel, callback)
      when is_nil(callback) or is_function(callback, 0) or is_function(callback, 1) do
    {event_target_pid, pid} = resolve_runtime_pids!(channel)

    if local_control_process?(event_target_pid, pid) do
      GenServer.cast(pid, {:set_onmessage, callback})
    else
      :ok = GenServer.call(pid, {:set_onmessage, callback}, :infinity)
    end

    %{channel | onmessage: callback}
  end

  @doc """
  Registers a listener for the channel's events.

  The three-argument form uses an empty options map. Supported options match
  `Web.EventTarget.add_event_listener/4`, including `:once` and `:signal`.

  ## Examples

      iex> channel = Web.BroadcastChannel.new("listener")
      iex> channel = Web.BroadcastChannel.add_event_listener(channel, "message", fn _event -> :ok end)
      iex> match?(%Web.BroadcastChannel{}, channel)
      true
      iex> Web.BroadcastChannel.close(channel)
      :ok

      iex> channel = Web.BroadcastChannel.new("listener-once")
      iex> channel =
      ...>   Web.BroadcastChannel.add_event_listener(channel, "message", fn _event -> :ok end, once: true)
      iex> match?(%Web.BroadcastChannel{}, channel)
      true
      iex> Web.BroadcastChannel.close(channel)
      :ok
  """
  @spec add_event_listener(t(), String.t() | atom(), callback(), keyword() | map()) :: t()
  def add_event_listener(%__MODULE__{} = channel, type, callback, options \\ %{})
      when is_function(callback, 0) or is_function(callback, 1) do
    EventTarget.add_event_listener(channel, type, callback, options)
  end

  @doc """
  Removes a previously registered listener.

  ## Examples

      iex> callback = fn _event -> :ok end
      iex> channel = Web.BroadcastChannel.new("remove-listener")
      iex> channel = Web.BroadcastChannel.add_event_listener(channel, "message", callback)
      iex> channel = Web.BroadcastChannel.remove_event_listener(channel, "message", callback)
      iex> match?(%Web.BroadcastChannel{}, channel)
      true
      iex> Web.BroadcastChannel.close(channel)
      :ok
  """
  @spec remove_event_listener(t(), String.t() | atom(), callback()) :: t()
  def remove_event_listener(%__MODULE__{} = channel, type, callback)
      when is_function(callback, 0) or is_function(callback, 1) do
    EventTarget.remove_event_listener(channel, type, callback)
  end

  @doc """
  Broadcasts a structured clone of `data` to every other same-name channel.

  Validation happens before the call returns. Closed channels raise
  `Web.DOMException` with `"InvalidStateError"`, and uncloneable values raise
  `Web.DOMException` with `"DataCloneError"`.

  ## Examples

      iex> parent = self()
      iex> sender = Web.BroadcastChannel.new("post-message")
      iex> recipient = Web.BroadcastChannel.new("post-message")
      iex> recipient =
      ...>   Web.BroadcastChannel.add_event_listener(recipient, "message", fn event ->
      ...>     send(parent, event.data)
      ...>   end)
      iex> :ok = Web.BroadcastChannel.post_message(sender, "hello")
      iex> receive do
      ...>   value -> value
      ...> after
      ...>   1_000 -> :timeout
      ...> end
      "hello"
      iex> Web.BroadcastChannel.close(sender)
      :ok
      iex> Web.BroadcastChannel.close(recipient)
      :ok
  """
  @spec post_message(t(), term()) :: :ok
  def post_message(%__MODULE__{} = channel, data) do
    {dispatcher, server_pid} = lookup_open_dispatcher!(channel)
    cloned = Web.structured_clone(data)
    serialized = StructuredData.serialize(cloned)
    snapshot = Snapshot.take()

    Dispatcher.post(dispatcher, server_pid, %{
      origin: origin(),
      serialized: serialized,
      snapshot: snapshot
    })
  end

  @doc """
  Dispatches an event to listeners registered on the channel process.

  The returned boolean mirrors DOM `dispatchEvent()` and indicates whether the
  event dispatch completed.

  ## Examples

      iex> parent = self()
      iex> channel = Web.BroadcastChannel.new("manual-dispatch")
      iex> channel =
      ...>   Web.BroadcastChannel.add_event_listener(channel, "custom", fn event ->
      ...>     send(parent, {:dispatched, event.type})
      ...>   end)
      iex> {:ok, event} = {:ok, %{type: "custom", target: channel}}
      iex> {same_channel, true} = Web.BroadcastChannel.dispatch_event(channel, event)
      iex> same_channel == channel
      true
      iex> receive do
      ...>   {:dispatched, "custom"} -> :ok
      ...> after
      ...>   1_000 -> :timeout
      ...> end
      :ok
      iex> Web.BroadcastChannel.close(channel)
      :ok
  """
  @spec dispatch_event(t(), map()) :: {t(), boolean()}
  def dispatch_event(%__MODULE__{} = channel, event) when is_map(event) do
    EventTarget.dispatch_event(channel, event)
  end

  @doc """
  Closes the channel so it no longer sends or receives messages.

  ## Examples

      iex> channel = Web.BroadcastChannel.new("closing")
      iex> Web.BroadcastChannel.close(channel)
      :ok
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = channel) do
    case lookup_runtime_pids(channel) do
      nil ->
        :ok

      {event_target_pid, pid} ->
        if local_control_process?(event_target_pid, pid) do
          :ok = ChannelServer.mark_closed(channel.ref)
          GenServer.cast(pid, :close)
        else
          :ok = GenServer.call(pid, :close, :infinity)
        end
    end

    :ok
  end

  defp resolve_runtime_pids!(%__MODULE__{} = channel) do
    case Registry.lookup(Web.Registry, channel.ref) do
      [{event_target_pid, %{server_pid: server_pid}}]
      when is_pid(event_target_pid) and is_pid(server_pid) ->
        {event_target_pid, server_pid}

      [{_event_target_pid, _value}] ->
        raise ArgumentError, "BroadcastChannel #{inspect(channel.ref)} is missing a server pid"

      [] ->
        raise ArgumentError, "Unknown BroadcastChannel ref: #{inspect(channel.ref)}"
    end
  end

  defp lookup_runtime_pids(%__MODULE__{} = channel) do
    case Registry.lookup(Web.Registry, channel.ref) do
      [{event_target_pid, %{server_pid: server_pid}}]
      when is_pid(event_target_pid) and is_pid(server_pid) ->
        {event_target_pid, server_pid}

      _other ->
        nil
    end
  end

  defp lookup_server_pid(%__MODULE__{} = channel) do
    case lookup_runtime_pids(channel) do
      {_event_target_pid, server_pid} -> server_pid
      nil -> nil
    end
  end

  defp local_control_process?(event_target_pid, server_pid) do
    self() == server_pid or self() == event_target_pid
  end

  defp lookup_open_dispatcher!(%__MODULE__{} = channel) do
    case {ChannelServer.runtime_info(channel.ref), lookup_server_pid(channel)} do
      {%{dispatcher: dispatcher, closed: false}, server_pid}
      when is_pid(dispatcher) and is_pid(server_pid) ->
        if Process.alive?(server_pid) do
          {dispatcher, server_pid}
        else
          raise_closed!()
        end

      _other ->
        raise_closed!()
    end
  end

  defp raise_closed! do
    raise DOMException.exception(
            name: "InvalidStateError",
            message: "BroadcastChannel is closed"
          )
  end

  defp origin do
    "node://" <> Atom.to_string(node())
  end

  defp normalize_name(nil), do: "null"
  defp normalize_name(name), do: to_string(name)
end
