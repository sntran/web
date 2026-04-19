defmodule Web.EventTarget do
  @moduledoc """
  Public event-target interface for process-backed Web objects.

  Evented structs expose an opaque `ref` and use `Web.Registry` as the single
  lookup point for their internal listener server.
  """

  alias Web.AsyncContext.Snapshot
  alias Web.Internal.EventTarget.Server

  @type event :: %{required(:type) => String.t() | atom()}
  @type callback :: (event() -> any()) | (-> any())

  @callback handle_add_listener(struct(), String.t() | atom(), callback(), map()) ::
              :ok | {:ok, struct()}
  @callback handle_dispatch(struct(), event()) :: :ok | {:ok, struct()}
  @optional_callbacks handle_add_listener: 4, handle_dispatch: 2

  defmacro __using__(_opts) do
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
  end

  @spec add_event_listener(target, String.t() | atom(), callback(), keyword() | map()) :: target
        when target: var
  def add_event_listener(target, type, callback, options \\ %{})
      when is_function(callback, 0) or is_function(callback, 1) do
    Web.EventTarget.Protocol.add_event_listener(target, type, callback, options)
  end

  def unquote(:addEventListener)(target, type, callback, options \\ %{}) do
    add_event_listener(target, type, callback, options)
  end

  @spec remove_event_listener(target, String.t() | atom(), callback()) :: target when target: var
  def remove_event_listener(target, type, callback)
      when is_function(callback, 0) or is_function(callback, 1) do
    Web.EventTarget.Protocol.remove_event_listener(target, type, callback)
  end

  def unquote(:removeEventListener)(target, type, callback) do
    remove_event_listener(target, type, callback)
  end

  @spec dispatch_event(target, event()) :: {target, boolean()} when target: var
  def dispatch_event(target, %{type: type} = event) when is_binary(type) or is_atom(type) do
    Web.EventTarget.Protocol.dispatch_event(target, event)
  end

  def unquote(:dispatchEvent)(target, event) do
    dispatch_event(target, event)
  end

  @spec event_target_pid!(%{ref: reference()}) :: pid()
  defp event_target_pid!(%{ref: ref}) when is_reference(ref) do
    {event_target_pid, _value} = lookup_registration!(ref)
    event_target_pid
  end

  @doc false
  def __add_event_listener__(%{ref: ref} = target, type, callback, options)
      when is_reference(ref) and (is_function(callback, 0) or is_function(callback, 1)) do
    event_target_pid = event_target_pid!(target)

    if self() == event_target_pid do
      GenServer.cast(event_target_pid, {:add_event_listener, type, callback, options})
    else
      :ok = Server.add_event_listener(event_target_pid, type, callback, options)
    end

    target
  end

  @doc false
  def __remove_event_listener__(%{ref: ref} = target, type, callback)
      when is_reference(ref) and (is_function(callback, 0) or is_function(callback, 1)) do
    event_target_pid = event_target_pid!(target)

    if self() == event_target_pid do
      GenServer.cast(event_target_pid, {:remove_event_listener, type, callback})
    else
      :ok = Server.remove_event_listener(event_target_pid, type, callback)
    end

    target
  end

  @doc false
  def __dispatch_event__(%{ref: ref} = target, %{type: type} = event)
      when is_reference(ref) and (is_binary(type) or is_atom(type)) do
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

  defp lookup_registration!(ref) do
    case Registry.lookup(Web.Registry, ref) do
      [{pid, value}] when is_pid(pid) -> {pid, value}
      [] -> raise ArgumentError, "Unknown EventTarget ref: #{inspect(ref)}"
    end
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
