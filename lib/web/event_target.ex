defmodule Web.EventTarget do
  @moduledoc """
  An object that gets events, as `EventTarget` of the DOM Standard.

  `new/0` makes an event target, as `new EventTarget()`. A
  `Web.AbortSignal`, a `Web.MessagePort`, and a `Web.BroadcastChannel` are
  event targets too. The functions of this module accept each of them.

      iex> target = Web.EventTarget.new()
      iex> me = self()
      iex> target = Web.EventTarget.add_event_listener(target, "ping", fn event -> send(me, event.type) end)
      iex> {^target, true} = Web.EventTarget.dispatch_event(target, Web.Event.new("ping"))
      iex> receive do: (type -> type)
      "ping"

  ## The dispatch

  `dispatch_event/2` on a target of `new/0` or on a signal runs the
  listeners in the calling process, one after the other, before it returns,
  as the DOM Standard specifies. A listener can add and remove listeners,
  and dispatch other events. The result is `false` when a listener called
  `Web.Event.prevent_default/1`.

  A message port and a broadcast channel run their listeners in a process
  of their own.

  ## The lifetime

  A listener belongs to the process that added it: when that process stops,
  its listeners go away. A target of `new/0` is a small process. It stops
  when the process that made it stopped and it has no listener, after the
  linger time (`config :web, linger: ms`).

  Evented structs may expose a direct `event_target_pid` so listener routing can
  stay capability-local without any central registry lookup.
  """

  alias Web.AsyncContext.Snapshot
  alias Web.Internal.EventTarget.Dispatch
  alias Web.Internal.EventTarget.Server
  alias Web.Internal.EventTarget.Store

  defstruct [:pid]

  @type t :: %__MODULE__{pid: pid()}

  @type event :: %{required(:type) => String.t() | atom()}
  @type callback :: (event() -> any()) | (-> any())

  @callback handle_add_listener(struct(), String.t() | atom(), callback(), map()) ::
              :ok | {:ok, struct()}
  @callback handle_dispatch(struct(), event()) :: :ok | {:ok, struct()}
  @optional_callbacks handle_add_listener: 4, handle_dispatch: 2

  defmacro __using__(_opts) do
    # The macro runs when a module compiles, before the coverage tool starts.
    # coveralls-ignore-start
    quote do
      @behaviour Web.EventTarget

      @impl Web.EventTarget
      def handle_add_listener(target, _type, _callback, _options), do: {:ok, target}

      @impl Web.EventTarget
      def handle_dispatch(target, _event), do: {:ok, target}

      defoverridable handle_add_listener: 4, handle_dispatch: 2

      defimpl Web.EventTarget.Protocol, for: __MODULE__ do
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
    end

    # coveralls-ignore-stop
  end

  @doc """
  Makes an event target with no listener, as `new EventTarget()`.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{pid: Store.start(Web.Promise.owner())}

  @doc """
  Adds a listener for the events of a type, as
  `addEventListener(type, callback, options)`.

  The options are `:capture`, `:passive`, `:once`, and `:signal`, as the
  members of `AddEventListenerOptions`. A boolean in place of the options
  is the option `:capture`. A listener with the same type, callback, and
  capture is not added again. A callback that is `nil` adds no listener.
  """
  @spec add_event_listener(
          target,
          String.t() | atom(),
          callback() | nil,
          keyword() | map() | boolean()
        ) :: target
        when target: var
  def add_event_listener(target, type, callback, options \\ %{})

  def add_event_listener(target, _type, nil, _options), do: target

  def add_event_listener(target, type, callback, options)
      when is_function(callback, 0) or is_function(callback, 1) do
    Web.EventTarget.Protocol.add_event_listener(target, type, callback, flatten(options))
  end

  def unquote(:addEventListener)(target, type, callback, options \\ %{}) do
    add_event_listener(target, type, callback, options)
  end

  @doc """
  Removes the listener with the type, the callback, and the capture of the
  options, as `removeEventListener(type, callback, options)`.
  """
  @spec remove_event_listener(
          target,
          String.t() | atom(),
          callback() | nil,
          keyword() | map() | boolean()
        ) :: target
        when target: var
  def remove_event_listener(target, type, callback, options \\ %{})

  def remove_event_listener(target, _type, nil, _options), do: target

  def remove_event_listener(%struct{pid: pid} = target, type, callback, options)
      when struct in [__MODULE__, Web.AbortSignal] and
             (is_function(callback, 0) or is_function(callback, 1)) do
    capture = Map.get(flatten(options), :capture, false) == true
    :ok = __remove__(pid, type, callback, capture)
    target
  end

  def remove_event_listener(target, type, callback, _options)
      when is_function(callback, 0) or is_function(callback, 1) do
    Web.EventTarget.Protocol.remove_event_listener(target, type, callback)
  end

  def unquote(:removeEventListener)(target, type, callback, options \\ %{}) do
    remove_event_listener(target, type, callback, options)
  end

  @doc """
  Dispatches an event to the target, as `dispatchEvent(event)`. Returns the
  target, and `false` when a listener canceled the event.

  Raises a `Web.DOMException` with the name `InvalidStateError` for an
  event that is in a dispatch now.
  """
  @spec dispatch_event(target, event()) :: {target, boolean()} when target: var
  def dispatch_event(target, %{type: type} = event) when is_binary(type) or is_atom(type) do
    Web.EventTarget.Protocol.dispatch_event(target, event)
  end

  def unquote(:dispatchEvent)(target, event) do
    dispatch_event(target, event)
  end

  # The steps "flatten more options": a boolean is the option `capture`.
  defp flatten(capture) when is_boolean(capture), do: %{capture: capture}
  defp flatten(options) when is_list(options), do: Map.new(options)
  defp flatten(%{} = options), do: options

  @doc false
  # The steps "add an event listener" for a target whose process keeps the
  # listeners: a target of `new/0` and a signal. A listener with a signal
  # that aborted is not added. The abort of the signal removes the
  # listener.
  @spec __add__(pid() | nil, String.t() | atom(), callback(), keyword() | map() | boolean()) ::
          :ok
  def __add__(nil, _type, _callback, _options), do: :ok

  def __add__(pid, type, callback, options) do
    options = flatten(options)
    signal = Map.get(options, :signal)

    unless is_nil(signal) or is_struct(signal, Web.AbortSignal) do
      raise Web.TypeError, "The option signal is not a Web.AbortSignal: #{inspect(signal)}"
    end

    if signal != nil and Web.AbortSignal.aborted?(signal) do
      :ok
    else
      case Store.request(pid, {:add, to_string(type), callback, options}, :exists) do
        {:added, id} when signal != nil -> remove_at_abort(signal, pid, id)
        _other -> :ok
      end
    end
  end

  defp remove_at_abort(signal, pid, id) do
    case Web.AbortSignal.__add_algorithm__(signal, {Store, :remove_listener, [pid, id]}) do
      :ok -> :ok
      :aborted -> Store.remove_listener(pid, id)
    end
  end

  @doc false
  # The steps "remove an event listener", for a target whose process keeps
  # the listeners.
  @spec __remove__(pid() | nil, String.t() | atom(), callback(), boolean()) :: :ok
  def __remove__(nil, _type, _callback, _capture), do: :ok

  def __remove__(pid, type, callback, capture) do
    _ok = Store.request(pid, {:remove, to_string(type), callback, capture}, :ok)
    :ok
  end

  @doc false
  @spec __dispatch__(term(), pid() | nil, event()) :: boolean()
  def __dispatch__(target, pid, event), do: Dispatch.dispatch(target, event, pid)

  @spec event_target_pid!(map()) :: pid()
  defp event_target_pid!(%{event_target_pid: event_target_pid}) when is_pid(event_target_pid) do
    if Process.alive?(event_target_pid) do
      event_target_pid
    else
      raise ArgumentError, "Unknown EventTarget pid: #{inspect(event_target_pid)}"
    end
  end

  defp event_target_pid!(target) do
    raise ArgumentError, "Unknown EventTarget handle: #{inspect(target)}"
  end

  @doc false
  def __add_event_listener__(%{} = target, type, callback, options)
      when is_function(callback, 0) or is_function(callback, 1) do
    event_target_pid = event_target_pid!(target)

    if self() == event_target_pid do
      GenServer.cast(event_target_pid, {:add_event_listener, type, callback, options})
    else
      :ok = Server.add_event_listener(event_target_pid, type, callback, options)
    end

    target
  end

  @doc false
  def __remove_event_listener__(%{} = target, type, callback)
      when is_function(callback, 0) or is_function(callback, 1) do
    event_target_pid = event_target_pid!(target)

    if self() == event_target_pid do
      GenServer.cast(event_target_pid, {:remove_event_listener, type, callback})
    else
      :ok = Server.remove_event_listener(event_target_pid, type, callback)
    end

    target
  end

  @doc false
  def __dispatch_event__(%{} = target, %{type: type} = event)
      when is_binary(type) or is_atom(type) do
    event_target_pid = event_target_pid!(target)
    snapshot = Snapshot.take()

    dispatched? =
      if self() == event_target_pid do
        GenServer.cast(event_target_pid, {:dispatch_event, event, snapshot})
        true
      else
        Server.dispatch_event(event_target_pid, event, snapshot)
      end

    {target, dispatched?}
  end
end

defprotocol Web.EventTarget.Protocol do
  @spec add_event_listener(
          term(),
          String.t() | atom(),
          Web.EventTarget.callback(),
          keyword() | map()
        ) ::
          term()
  def add_event_listener(target, type, callback, options)

  @spec remove_event_listener(term(), String.t() | atom(), Web.EventTarget.callback()) :: term()
  def remove_event_listener(target, type, callback)

  @spec dispatch_event(term(), Web.EventTarget.event()) :: {term(), boolean()}
  def dispatch_event(target, event)
end

defimpl Web.EventTarget.Protocol, for: Web.EventTarget do
  def add_event_listener(target, type, callback, options) do
    :ok = Web.EventTarget.__add__(target.pid, type, callback, options)
    target
  end

  def remove_event_listener(target, type, callback) do
    :ok = Web.EventTarget.__remove__(target.pid, type, callback, false)
    target
  end

  def dispatch_event(target, event) do
    {target, Web.EventTarget.__dispatch__(target, target.pid, event)}
  end
end
