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

  `dispatch_event/2` runs the listeners in the calling process, one after
  the other, before it returns, as the DOM Standard specifies. A listener
  can add and remove listeners, and dispatch other events. The result is
  `false` when a listener called `Web.Event.prevent_default/1`.

  The listener steps are those of the DOM Standard for each target:

    * the listeners with the option `:capture` run first, then the others,
      each group in the sequence of the adds;
    * a listener that a different listener removed, or whose signal
      aborted, does not run;
    * a listener with the option `:once` is removed before it runs;
    * `Web.Event.prevent_default/1` in a listener with the option
      `:passive` has no effect;
    * a listener that comes during a dispatch runs in the next dispatch.

  A message port and a broadcast channel fire their events, such as
  `message`, in a process of their own.

  ## The lifetime

  A listener of a target of `new/0` or of a signal belongs to the process
  that added it: when that process stops, its listeners go away. A target
  of `new/0` is a small process. It stops when the process that made it
  stopped and it has no listener, after the linger time
  (`config :web, linger: ms`).

  A listener of a message port or of a broadcast channel stays until a
  process removes it, or until the port or the channel closes.
  """

  alias Web.Internal.EventTarget.Dispatch
  alias Web.Internal.EventTarget.Store

  defstruct [:pid]

  @type t :: %__MODULE__{pid: pid()}

  @type event :: Web.Event.event()
  @type callback :: (event() -> any()) | (-> any())

  @doc """
  Makes an event target with no listener, as `new EventTarget()`.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{pid: Store.start(Web.Promise.owner())}

  @doc """
  Adds a listener for the events of a type, as
  `addEventListener(type, callback, options)`.

  The options are `:capture`, `:passive`, `:once`, and `:signal`, as the
  members of `AddEventListenerOptions`. The default of each one is `false`,
  and of `:signal` it is `nil`. A boolean in place of the options is the
  option `:capture`. A listener with the same type, callback, and capture
  is not added again. A callback that is `nil` adds no listener.

  Raises a `Web.TypeError` when `:signal` is not a `Web.AbortSignal`.
  """
  @spec add_event_listener(
          target,
          String.t() | atom(),
          callback() | nil,
          keyword() | map() | boolean()
        ) :: target
        when target: var
  def add_event_listener(target, type, callback, options \\ %{})

  def add_event_listener(target, _type, nil, options) do
    _options = flatten_more(options)
    target
  end

  def add_event_listener(target, type, callback, options)
      when is_function(callback, 0) or is_function(callback, 1) do
    Web.EventTarget.Protocol.add_event_listener(target, type, callback, flatten_more(options))
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

  def remove_event_listener(target, type, callback, options)
      when is_function(callback, 0) or is_function(callback, 1) do
    Web.EventTarget.Protocol.remove_event_listener(target, type, callback, flatten(options))
  end

  @doc """
  Dispatches an event to the target, as `dispatchEvent(event)`. Returns the
  target, and `false` when a listener canceled the event.

  The event is a `Web.Event`, or an event of a module with its fields, such
  as `Web.CustomEvent`. Raises a `Web.DOMException` with the name
  `InvalidStateError` for an event that is in a dispatch now, or that is
  not initialized: see `Web.Event`.
  """
  @spec dispatch_event(target, event()) :: {target, boolean()} when target: var
  def dispatch_event(target, %{type: type} = event) when is_binary(type) or is_atom(type) do
    Web.EventTarget.Protocol.dispatch_event(target, event)
  end

  # The steps "flatten": a boolean is the option `capture`.
  defp flatten(capture) when is_boolean(capture), do: capture
  defp flatten(options), do: options |> Map.new() |> Map.get(:capture, false) == true

  # The steps "flatten more", and the conversion of the dictionary
  # `AddEventListenerOptions` of Web IDL: the member `signal` is a signal.
  defp flatten_more(capture) when is_boolean(capture), do: %{capture: capture}

  defp flatten_more(options) when is_list(options) or is_map(options) do
    options = Map.new(options)
    signal = Map.get(options, :signal)

    unless is_nil(signal) or is_struct(signal, Web.AbortSignal) do
      raise Web.TypeError, "The option signal is not a Web.AbortSignal: #{inspect(signal)}"
    end

    options
  end

  @doc false
  # The steps "add an event listener" for a target whose process keeps the
  # listeners, with the options of "flatten more". `nil` is a target with
  # no process: a port or a channel that is closed. A listener with a
  # signal that aborted is not added. The abort of the signal removes the
  # listener.
  @spec __add__(pid() | nil, String.t() | atom(), callback(), map()) :: :ok
  def __add__(nil, _type, _callback, _options), do: :ok

  def __add__(pid, type, callback, %{} = options) do
    signal = Map.get(options, :signal)

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
end

defprotocol Web.EventTarget.Protocol do
  @moduledoc false

  # The functions of `Web.EventTarget` for each kind of event target of the
  # library. Only the library implements this protocol. The options of an
  # add are a map of "flatten more", and the capture of a remove is a
  # boolean.

  @spec add_event_listener(term(), String.t() | atom(), Web.EventTarget.callback(), map()) ::
          term()
  def add_event_listener(target, type, callback, options)

  @spec remove_event_listener(term(), String.t() | atom(), Web.EventTarget.callback(), boolean()) ::
          term()
  def remove_event_listener(target, type, callback, capture)

  @spec dispatch_event(term(), Web.EventTarget.event()) :: {term(), boolean()}
  def dispatch_event(target, event)
end

defimpl Web.EventTarget.Protocol, for: Web.EventTarget do
  def add_event_listener(target, type, callback, options) do
    :ok = Web.EventTarget.__add__(target.pid, type, callback, options)
    target
  end

  def remove_event_listener(target, type, callback, capture) do
    :ok = Web.EventTarget.__remove__(target.pid, type, callback, capture)
    target
  end

  def dispatch_event(target, event) do
    {target, Web.EventTarget.__dispatch__(target, target.pid, event)}
  end
end
