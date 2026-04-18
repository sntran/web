defmodule Web.BroadcastChannel do
  @moduledoc """
  WHATWG-style BroadcastChannel backed by a configurable distributed adapter.

  The API keeps the browser semantics while presenting an idiomatic Elixir
  surface with snake_case function names.
  """

  alias Web.AsyncContext.Snapshot
  alias Web.BroadcastChannel.Adapter.PG
  alias Web.BroadcastChannel.ChannelServer
  alias Web.BroadcastChannel.Dispatcher
  alias Web.DOMException
  alias Web.Internal.StructuredData

  defstruct [:pid, :name, onmessage: nil]

  @type callback :: (Web.MessageEvent.t() -> any()) | (-> any())

  @type t :: %__MODULE__{
          pid: pid(),
          name: String.t(),
          onmessage: callback() | nil
        }

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
    {:ok, pid} = ChannelServer.start(normalized_name, self())
    %__MODULE__{pid: pid, name: normalized_name, onmessage: nil}
  end

  @doc false
  @spec onmessage(t()) :: callback() | nil
  def onmessage(%__MODULE__{pid: pid}) do
    GenServer.call(pid, :get_onmessage, :infinity)
  end

  @doc false
  @spec onmessage(t(), callback() | nil) :: t()
  def onmessage(%__MODULE__{} = channel, callback)
      when is_nil(callback) or is_function(callback, 0) or is_function(callback, 1) do
    :ok = maybe_call_or_cast(channel.pid, {:set_onmessage, callback})
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
    :ok = maybe_call_or_cast(channel.pid, {:add_listener, type, callback, options})
    channel
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
    :ok = maybe_call_or_cast(channel.pid, {:remove_listener, type, callback})
    channel
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
  def post_message(%__MODULE__{pid: pid}, data) do
    dispatcher = lookup_open_dispatcher!(pid)
    cloned = Web.structured_clone(data)
    serialized = StructuredData.serialize(cloned)
    snapshot = Snapshot.take()

    Dispatcher.post(dispatcher, pid, %{
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
  def dispatch_event(%__MODULE__{pid: pid} = channel, event) when is_map(event) do
    dispatched? = GenServer.call(pid, {:dispatch_event, event}, :infinity)
    {channel, dispatched?}
  end

  @doc """
  Closes the channel so it no longer sends or receives messages.

  ## Examples

      iex> channel = Web.BroadcastChannel.new("closing")
      iex> Web.BroadcastChannel.close(channel)
      :ok
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid}) do
    if self() == pid do
      :ok = ChannelServer.mark_closed(pid)
      GenServer.cast(pid, :close)
    else
      :ok = GenServer.call(pid, :close, :infinity)
    end

    :ok
  end

  @doc false
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:web, :broadcast_adapter, PG)
  end

  @doc false
  @spec governor() :: struct() | nil
  def governor do
    Application.get_env(:web, :broadcast_governor)
  end

  @doc false
  @spec origin() :: String.t()
  def origin do
    "node://" <> Atom.to_string(node())
  end

  defp maybe_call_or_cast(pid, message) do
    if self() == pid do
      GenServer.cast(pid, message)
      :ok
    else
      GenServer.call(pid, message, :infinity)
    end
  end

  defp lookup_open_dispatcher!(pid) do
    case ChannelServer.runtime_info(pid) do
      %{dispatcher: dispatcher, closed: false} when is_pid(dispatcher) ->
        if Process.alive?(pid) do
          dispatcher
        else
          raise DOMException.exception(
                  name: "InvalidStateError",
                  message: "BroadcastChannel is closed"
                )
        end

      _other ->
        raise DOMException.exception(
                name: "InvalidStateError",
                message: "BroadcastChannel is closed"
              )
    end
  end

  defp normalize_name(nil), do: "null"
  defp normalize_name(name), do: to_string(name)
end
