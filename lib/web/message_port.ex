defmodule Web.MessagePort do
  @moduledoc """
  One of the two ports of a `Web.MessageChannel`, as `MessagePort` of the
  HTML Standard.

  A message that one port sends arrives at the other port as an event
  `message`. The message is a structured clone: see
  `Web.structured_clone/2`.

      %{port1: port1, port2: port2} = Web.MessageChannel.new()

      Web.MessagePort.onmessage(port2, fn event ->
        # Answer on the port that got the message.
        Web.MessagePort.post_message(event.target, String.upcase(event.data))
      end)

      Web.MessagePort.onmessage(port1, fn event -> IO.puts(event.data) end)
      Web.MessagePort.post_message(port1, "hello")
      # Prints "HELLO".

  ## The port message queue

  A port keeps the messages that it gets until it starts. A port starts
  when `start/1` is called, or when `onmessage/2` sets a callback. Thus no
  message is lost before a listener is there.

  As in a browser, `add_event_listener/4` does not start the port. Call
  `start/1` after it.

  ## Events

    * `message` - a `Web.MessageEvent` with the message in `data` and the
      transferred ports in `ports`;
    * `messageerror` - a `Web.MessageEvent`, when the message cannot be made
      in this process;
    * `close` - a `Web.Event`, after the other port closed. A port that
      started gets it after the messages that the other port sent. A port
      that did not start gets it immediately.

  ## Listeners

  The listeners of one port run in one process of that port, one event at a
  time. A listener can call each function of this module, also on its port.
  A value that a listener throws goes to the log, and the port continues.

  ## A handle

  The struct is a handle to the port. A process can send the handle to a
  different process in a usual message: the two processes then use the same
  port. A transfer is different: `post_message/3` with the port in the
  transfer list moves the port to the process that gets the message. The
  handle of the sender is then detached, and the port has no listeners
  until the new holder adds them.

  ## Lifetime

  The VM cannot tell when a port has no more references. A port stays until
  one of these occurs:

    * a process calls `close/1`;
    * its holder stops. The holder is the process that made the channel.
      After a transfer, it is the holder of the port that got the message.

  Close a port when the work is complete, or use `Web.using/2`. A function
  on a port that is closed or detached has no effect and gives no error, as
  in a browser. Only a transfer of such a port raises `DataCloneError`.
  """

  alias Web.EventTarget
  alias Web.Internal.MessagePort, as: Engine
  alias Web.Internal.MessageTarget

  @enforce_keys [:address, :token]
  defstruct [:address, :token]

  @typedoc "A callback for an event of the port."
  @type callback :: (Web.MessageEvent.t() | Web.Event.t() -> any()) | (-> any())

  @typedoc "A handle to one port. The fields are private."
  @type t :: %__MODULE__{address: pid(), token: reference()}

  @doc """
  Starts the delivery of the messages in the port message queue.

  A second call has no effect.
  """
  @spec start(t()) :: :ok
  def start(%__MODULE__{} = port), do: Engine.start(port)

  @doc """
  Returns the callback of the event `message`, or `nil`.
  """
  @spec onmessage(t()) :: callback() | nil
  def onmessage(%__MODULE__{} = port), do: MessageTarget.get_handler(port, "message")

  @doc """
  Sets the callback of the event `message`, and starts the port. `nil`
  removes the callback. Returns the port.
  """
  @spec onmessage(t(), callback() | nil) :: t()
  def onmessage(%__MODULE__{} = port, callback), do: set_handler(port, "message", callback)

  @doc """
  Returns the callback of the event `messageerror`, or `nil`.
  """
  @spec onmessageerror(t()) :: callback() | nil
  def onmessageerror(%__MODULE__{} = port), do: MessageTarget.get_handler(port, "messageerror")

  @doc """
  Sets the callback of the event `messageerror`. Returns the port.
  """
  @spec onmessageerror(t(), callback() | nil) :: t()
  def onmessageerror(%__MODULE__{} = port, callback) do
    set_handler(port, "messageerror", callback)
  end

  @doc """
  Returns the callback of the event `close`, or `nil`.
  """
  @spec onclose(t()) :: callback() | nil
  def onclose(%__MODULE__{} = port), do: MessageTarget.get_handler(port, "close")

  @doc """
  Sets the callback of the event `close`. Returns the port.
  """
  @spec onclose(t(), callback() | nil) :: t()
  def onclose(%__MODULE__{} = port, callback), do: set_handler(port, "close", callback)

  defp set_handler(port, type, callback)
       when is_nil(callback) or is_function(callback, 0) or is_function(callback, 1) do
    :ok = MessageTarget.set_handler(port, type, callback)
    port
  end

  defp set_handler(_port, _type, callback) do
    raise Web.TypeError,
          "The callback must be a function with 0 or 1 arguments, or nil, got: " <>
            inspect(callback)
  end

  @doc """
  Adds a listener for an event of the port. Returns the port.

  The options are those of `Web.EventTarget.add_event_listener/4`: `:once`
  and `:signal`. This function does not start the port: see `start/1`.
  """
  @spec add_event_listener(t(), String.t() | atom(), callback(), keyword() | map()) :: t()
  def add_event_listener(%__MODULE__{} = port, type, callback, options \\ %{})
      when is_function(callback, 0) or is_function(callback, 1) do
    EventTarget.add_event_listener(port, type, callback, options)
  end

  @doc """
  Removes a listener. Returns the port.
  """
  @spec remove_event_listener(t(), String.t() | atom(), callback()) :: t()
  def remove_event_listener(%__MODULE__{} = port, type, callback)
      when is_function(callback, 0) or is_function(callback, 1) do
    EventTarget.remove_event_listener(port, type, callback)
  end

  @doc """
  Gives an event to the listeners of the port. Returns the port and `true`.

  The function does not wait for the listeners.
  """
  @spec dispatch_event(t(), map()) :: {t(), boolean()}
  def dispatch_event(%__MODULE__{} = port, event) when is_map(event) do
    EventTarget.dispatch_event(port, event)
  end

  @doc """
  Sends a structured clone of `message` to the other port.

  `transfer` is a list of `Web.ArrayBuffer` and `Web.MessagePort` values
  that move to the process that gets the message. It can also be the
  keyword list `[transfer: list]`. The sender cannot use a transferred
  value after the call.

  The function does not wait for the delivery. A message to a port that is
  closed is dropped.

  Raises `Web.DOMException` with the name `DataCloneError` when the message
  cannot be cloned, or when `transfer` has this port. The function then
  sends nothing and moves nothing.

  ## Examples

      iex> %{port1: port1, port2: port2} = Web.MessageChannel.new()
      iex> test = self()
      iex> Web.MessagePort.onmessage(port2, fn event -> send(test, event.data) end)
      iex> Web.MessagePort.post_message(port1, %{status: "ready"})
      :ok
      iex> receive do
      ...>   message -> message
      ...> end
      %{status: "ready"}
      iex> Web.MessagePort.close(port1)
      :ok
  """
  @spec post_message(t(), term(), list()) :: :ok
  def post_message(%__MODULE__{} = port, message, transfer \\ []) when is_list(transfer) do
    Engine.post_message(port, message, transfer_list(transfer))
  end

  defp transfer_list([{:transfer, transfer}]) when is_list(transfer), do: transfer
  defp transfer_list(transfer), do: transfer

  @doc """
  Closes the port. The other port gets the event `close`.

  The port delivers no event after this function returns. A second call
  has no effect.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = port), do: Engine.close(port)
end

defmodule Web.MessageChannel do
  @moduledoc """
  A channel with two connected ports, as `MessageChannel` of the HTML
  Standard.

  The fields `port1` and `port2` are the attributes of the Standard. See
  `Web.MessagePort`.
  """

  alias Web.Internal.MessagePort, as: Engine
  alias Web.MessagePort

  @enforce_keys [:port1, :port2]
  defstruct [:port1, :port2]

  @type t :: %__MODULE__{port1: MessagePort.t(), port2: MessagePort.t()}

  @doc """
  Makes a channel with two connected ports, as the constructor
  `new MessageChannel()`.

  The process that calls this function is the holder of the two ports: the
  ports close when it stops.

  ## Examples

      iex> %Web.MessageChannel{port1: port1, port2: port2} = Web.MessageChannel.new()
      iex> is_struct(port1, Web.MessagePort) and is_struct(port2, Web.MessagePort)
      true
      iex> Web.MessagePort.close(port1)
      :ok
  """
  @spec new() :: t()
  def new do
    {port1, port2} = Engine.start_pair(self())
    %__MODULE__{port1: port1, port2: port2}
  end
end

defimpl Web.EventTarget.Protocol, for: Web.MessagePort do
  alias Web.Internal.MessageTarget

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
