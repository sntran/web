defmodule Web.BroadcastChannel do
  @moduledoc """
  WHATWG-style BroadcastChannel backed by a capability-addressed runtime.

  The API keeps the browser semantics while presenting an idiomatic Elixir
  surface with snake_case function names.
  """

  alias Web.EventTarget
  alias Web.Internal.BroadcastChannel, as: Engine

  defstruct [:address, :token, :name, onmessage: nil]

  @typedoc "Callback invoked for `message` events delivered to the channel."
  @type callback :: (Web.MessageEvent.t() -> any()) | (-> any())

  @typedoc "Opaque capability handle for a named `Web.BroadcastChannel` subscription."
  @type t :: %__MODULE__{
          address: reference(),
          token: reference(),
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
    name
    |> normalize_name()
    |> Engine.new(self())
  end

  @doc false
  @spec onmessage(t()) :: callback() | nil
  def onmessage(%__MODULE__{} = channel) do
    Engine.get_onmessage(channel)
  end

  @doc false
  @spec onmessage(t(), callback() | nil) :: t()
  def onmessage(%__MODULE__{} = channel, callback)
      when is_nil(callback) or is_function(callback, 0) or is_function(callback, 1) do
    :ok = Engine.set_onmessage(channel, callback)
    %{channel | onmessage: callback}
  end

  @doc """
  Registers a listener for the channel's events.

  The three-argument form uses an empty options map. Supported options match
  `Web.EventTarget.add_event_listener/4`, including `:once` and `:signal`.
  """
  @spec add_event_listener(t(), String.t() | atom(), callback(), keyword() | map()) :: t()
  def add_event_listener(%__MODULE__{} = channel, type, callback, options \\ %{})
      when is_function(callback, 0) or is_function(callback, 1) do
    EventTarget.add_event_listener(channel, type, callback, options)
  end

  @doc """
  Removes a previously registered listener.
  """
  @spec remove_event_listener(t(), String.t() | atom(), callback()) :: t()
  def remove_event_listener(%__MODULE__{} = channel, type, callback)
      when is_function(callback, 0) or is_function(callback, 1) do
    EventTarget.remove_event_listener(channel, type, callback)
  end

  @doc """
  Broadcasts a structured clone of `data` to every other same-name channel.
  """
  @spec post_message(t(), term()) :: :ok
  def post_message(%__MODULE__{} = channel, data) do
    Engine.post_message(channel, data)
  end

  @doc """
  Dispatches an event to listeners registered on the channel process.
  """
  @spec dispatch_event(t(), map()) :: {t(), boolean()}
  def dispatch_event(%__MODULE__{} = channel, event) when is_map(event) do
    EventTarget.dispatch_event(channel, event)
  end

  @doc """
  Closes the channel so it no longer sends or receives messages.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = channel) do
    Engine.close(channel)
  end

  defimpl Web.EventTarget.Protocol do
    def add_event_listener(target, type, callback, options) do
      :ok = Engine.add_event_listener(target, type, callback, options)
      target
    end

    def remove_event_listener(target, type, callback) do
      :ok = Engine.remove_event_listener(target, type, callback)
      target
    end

    def dispatch_event(target, event) do
      dispatched? = Engine.dispatch_event(target, event)
      {target, dispatched?}
    end
  end

  defp normalize_name(nil), do: "null"
  defp normalize_name(name), do: to_string(name)
end
