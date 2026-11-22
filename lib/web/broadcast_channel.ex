defmodule Web.BroadcastChannel do
  @moduledoc """
  A channel to all the other channels with the same name, as
  `BroadcastChannel` of the HTML Standard.

  A message that one channel sends arrives, as an event `message`, at each
  other open channel with the same name: in this VM, and on each connected
  node of the cluster. The channel that sends the message does not get it.
  The message is a structured clone: see `Web.structured_clone/2`.

      receiver = Web.BroadcastChannel.new("jobs")
      Web.BroadcastChannel.onmessage(receiver, fn event -> IO.inspect(event.data) end)

      sender = Web.BroadcastChannel.new("jobs")
      Web.BroadcastChannel.post_message(sender, %{id: 7, state: "done"})
      # The listener of `receiver` prints the map.

  ## Events

    * `message` - a `Web.MessageEvent` with the message in `data`, and the
      node of the sender in `origin`: `"node://name@host"`;
    * `messageerror` - a `Web.MessageEvent`, when the message cannot be made
      in this process.

  ## Sequence

  The messages of one channel arrive at each other channel in the sequence
  in which that channel sent them. Two channels can get the messages of two
  different senders in a different sequence.

  ## Listeners

  The listeners of one channel run in one process of that channel, one
  event at a time. A slow listener delays only its channel. A listener can
  call each function of this module, also on its channel. A value that a
  listener throws goes to the log, and the channel continues.

  ## Lifetime

  The VM cannot tell when a channel has no more references. A channel
  stays, and gets messages, until one of these occurs:

    * a process calls `close/1`;
    * its holder stops. The holder is the process that made the channel.

  Close a channel when the work is complete, or use `Web.using/2`.

  ## Settings

    * `config :web, broadcast_governor: governor` - a governor, for example
      a `Web.CountingGovernor`, that limits the rate of `post_message/2`.
      The process that sends a message waits for the governor.
  """

  alias Web.EventTarget
  alias Web.Internal.BroadcastChannel, as: Engine
  alias Web.Internal.MessageTarget

  @enforce_keys [:address, :token, :name]
  defstruct [:address, :token, :name]

  @typedoc "A callback for an event of the channel."
  @type callback :: (Web.MessageEvent.t() -> any()) | (-> any())

  @typedoc "A handle to one channel. The fields `address` and `token` are private."
  @type t :: %__MODULE__{address: pid(), token: reference(), name: String.t()}

  @doc """
  Makes a channel with the given name.

  The name becomes a string with `to_string/1`, as the constructor of
  ECMAScript changes its argument to a string. The process that calls this
  function is the holder of the channel.

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

  @doc """
  Returns the callback of the event `message`, or `nil`.
  """
  @spec onmessage(t()) :: callback() | nil
  def onmessage(%__MODULE__{} = channel), do: MessageTarget.get_handler(channel, "message")

  @doc """
  Sets the callback of the event `message`. `nil` removes the callback.
  Returns the channel.
  """
  @spec onmessage(t(), callback() | nil) :: t()
  def onmessage(%__MODULE__{} = channel, callback), do: set_handler(channel, "message", callback)

  @doc """
  Returns the callback of the event `messageerror`, or `nil`.
  """
  @spec onmessageerror(t()) :: callback() | nil
  def onmessageerror(%__MODULE__{} = channel) do
    MessageTarget.get_handler(channel, "messageerror")
  end

  @doc """
  Sets the callback of the event `messageerror`. Returns the channel.
  """
  @spec onmessageerror(t(), callback() | nil) :: t()
  def onmessageerror(%__MODULE__{} = channel, callback) do
    set_handler(channel, "messageerror", callback)
  end

  defp set_handler(channel, type, callback)
       when is_nil(callback) or is_function(callback, 0) or is_function(callback, 1) do
    :ok = MessageTarget.set_handler(channel, type, callback)
    channel
  end

  defp set_handler(_channel, _type, callback) do
    raise Web.TypeError,
          "The callback must be a function with 0 or 1 arguments, or nil, got: " <>
            inspect(callback)
  end

  @doc """
  Adds a listener for an event of the channel. Returns the channel.

  The options are those of `Web.EventTarget.add_event_listener/4`: `:once`
  and `:signal`.
  """
  @spec add_event_listener(t(), String.t() | atom(), callback(), keyword() | map()) :: t()
  def add_event_listener(%__MODULE__{} = channel, type, callback, options \\ %{})
      when is_function(callback, 0) or is_function(callback, 1) do
    EventTarget.add_event_listener(channel, type, callback, options)
  end

  @doc """
  Removes a listener. Returns the channel.
  """
  @spec remove_event_listener(t(), String.t() | atom(), callback()) :: t()
  def remove_event_listener(%__MODULE__{} = channel, type, callback)
      when is_function(callback, 0) or is_function(callback, 1) do
    EventTarget.remove_event_listener(channel, type, callback)
  end

  @doc """
  Sends a structured clone of `message` to each other channel with the same
  name.

  The function does not wait for the delivery.

  Raises `Web.DOMException` with the name `InvalidStateError` when the
  channel is closed, and with the name `DataCloneError` when the message
  cannot be cloned.

  ## Examples

      iex> receiver = Web.BroadcastChannel.new("doc-example")
      iex> test = self()
      iex> Web.BroadcastChannel.onmessage(receiver, fn event -> send(test, event.data) end)
      iex> sender = Web.BroadcastChannel.new("doc-example")
      iex> Web.BroadcastChannel.post_message(sender, [1, 2, 3])
      :ok
      iex> receive do
      ...>   message -> message
      ...> end
      [1, 2, 3]
      iex> Web.BroadcastChannel.close(sender)
      :ok
      iex> Web.BroadcastChannel.close(receiver)
      :ok
  """
  @spec post_message(t(), term()) :: :ok
  def post_message(%__MODULE__{} = channel, message) do
    Engine.post_message(channel, message)
  end

  @doc """
  Gives an event to the listeners of the channel. Returns the channel and
  `true`.

  The function does not wait for the listeners.
  """
  @spec dispatch_event(t(), map()) :: {t(), boolean()}
  def dispatch_event(%__MODULE__{} = channel, event) when is_map(event) do
    EventTarget.dispatch_event(channel, event)
  end

  @doc """
  Closes the channel.

  The channel delivers no event after this function returns. A second call
  has no effect.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = channel) do
    Engine.close(channel)
  end

  defimpl Web.EventTarget.Protocol do
    def add_event_listener(target, type, callback, options) do
      :ok = MessageTarget.add_event_listener(target, type, callback, options)
      target
    end

    def remove_event_listener(target, type, callback) do
      :ok = MessageTarget.remove_event_listener(target, type, callback)
      target
    end

    def dispatch_event(target, event) do
      {target, MessageTarget.dispatch_event(target, event)}
    end
  end

  defp normalize_name(nil), do: "null"
  defp normalize_name(name), do: to_string(name)
end
