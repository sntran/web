defmodule Web.MessagePort do
  @moduledoc """
  WHATWG-style MessagePort backed by a capability-addressed runtime.
  """

  alias Web.EventTarget
  alias Web.Internal.MessagePort, as: Engine

  defstruct [:address, :token, onmessage: nil]

  @typedoc "Callback invoked for `message` events delivered to the port."
  @type callback :: (Web.MessageEvent.t() -> any()) | (-> any())

  @typedoc "Opaque capability handle for one endpoint of a `Web.MessageChannel`."
  @type t :: %__MODULE__{
          address: reference(),
          token: reference(),
          onmessage: callback() | nil
        }

  @doc false
  @spec onmessage(t()) :: callback() | nil
  def onmessage(%__MODULE__{} = port) do
    Engine.get_onmessage(port)
  end

  @doc false
  @spec onmessage(t(), callback() | nil) :: t()
  def onmessage(%__MODULE__{} = port, callback)
      when is_nil(callback) or is_function(callback, 0) or is_function(callback, 1) do
    :ok = Engine.set_onmessage(port, callback)
    %{port | onmessage: callback}
  end

  @doc """
  Registers a listener for the port's events.
  """
  @spec add_event_listener(t(), String.t() | atom(), callback(), keyword() | map()) :: t()
  def add_event_listener(%__MODULE__{} = port, type, callback, options \\ %{})
      when is_function(callback, 0) or is_function(callback, 1) do
    EventTarget.add_event_listener(port, type, callback, options)
  end

  @doc """
  Removes a previously registered listener.
  """
  @spec remove_event_listener(t(), String.t() | atom(), callback()) :: t()
  def remove_event_listener(%__MODULE__{} = port, type, callback)
      when is_function(callback, 0) or is_function(callback, 1) do
    EventTarget.remove_event_listener(port, type, callback)
  end

  @doc """
  Dispatches an event to listeners registered on the port.
  """
  @spec dispatch_event(t(), map()) :: {t(), boolean()}
  def dispatch_event(%__MODULE__{} = port, event) when is_map(event) do
    EventTarget.dispatch_event(port, event)
  end

  @doc """
  Sends a structured-cloned message to the entangled port.
  """
  @spec post_message(t(), term(), list()) :: :ok
  def post_message(%__MODULE__{} = port, message, transfer \\ []) when is_list(transfer) do
    Engine.post_message(port, message, transfer)
  end

  @doc """
  Closes the port and notifies its entangled sibling.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = port) do
    Engine.close(port)
  end
end

defmodule Web.MessageChannel do
  @moduledoc """
  WHATWG-style MessageChannel constructor that returns an entangled port pair.
  """

  alias Web.Internal.MessagePort, as: Engine
  alias Web.MessagePort

  @spec new() :: {MessagePort.t(), MessagePort.t()}
  def new do
    Engine.start_pair(self())
  end
end

defimpl Web.EventTarget.Protocol, for: Web.MessagePort do
  alias Web.Internal.MessagePort, as: Engine

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
