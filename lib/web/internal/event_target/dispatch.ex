defmodule Web.Internal.EventTarget.Dispatch do
  @moduledoc false

  # The steps "dispatch" of the DOM Standard, for a target with no parent:
  # each event target of the library.
  #
  # The dispatch runs in the process that calls it, as `dispatchEvent()`
  # runs the listeners before it returns. A different process, the store,
  # keeps the listeners and never runs the code of a user: a listener can
  # thus add a listener, remove a listener, and dispatch other events to
  # the same target. The store is the process of a target of
  # `Web.EventTarget.new/0`, the process of a signal, or the store of a
  # message port or a broadcast channel (see `Web.Internal.MessageTarget`).
  #
  # Before the call of each listener, the dispatch asks the store if the
  # listener is still there: a listener that a different listener removed
  # is not called, as the flag "removed" of the Standard specifies. The
  # store removes a listener with `once` at that time, before the call.
  #
  # The specification is `tla/EventTarget.tla`.

  require Logger

  alias Web.DOMException
  alias Web.Event

  @doc """
  Dispatches `event` to `target`, as `dispatchEvent(event)`. `store` is the
  pid of the process with the listeners, or `nil` for a target with no
  listener. Returns `false` when a listener canceled the event.

  With `trusted: true`, the event keeps its `is_trusted`, as the steps
  "fire an event" do. Else `is_trusted` becomes `false`.

  Raises an `InvalidStateError` for an event that is in a dispatch now, or
  whose initialized flag is not set.
  """
  @spec dispatch(term(), map(), pid() | nil, keyword()) :: boolean()
  def dispatch(target, event, store, opts \\ []) do
    # The steps of `dispatchEvent()`, step 1.
    cond do
      Event.__flag__(event, :dispatch) ->
        raise DOMException, name: "InvalidStateError", message: "The event is already dispatched."

      not Event.__flag__(event, :initialized) ->
        raise DOMException, name: "InvalidStateError", message: "The event is not initialized."

      true ->
        :ok
    end

    Event.__put_flag__(event, :dispatch, 1)

    event =
      if Keyword.get(opts, :trusted, false), do: event, else: put(event, :is_trusted, false)

    try do
      # The path has only the target. The "capturing" pass calls the
      # listeners with capture, and the "bubbling" pass the others.
      Event.__put_phase__(event, Event.at_target())
      invoke(target, event, :capturing, store)
      Event.__put_phase__(event, Event.at_target())
      invoke(target, event, :bubbling, store)
    after
      Event.__put_phase__(event, Event.none())

      for flag <- [:dispatch, :stop_propagation, :stop_immediate],
          do: Event.__put_flag__(event, flag, 0)
    end

    not Event.default_prevented?(event)
  end

  # The steps "invoke".
  defp invoke(target, event, phase, store) do
    event = put(event, :target, target)

    unless Event.__flag__(event, :stop_propagation) do
      event = put(event, :current_target, target)
      listeners = request(store, {:clone, to_string(event.type)}, [])
      inner_invoke(listeners, event, phase, store)
    end

    :ok
  end

  # The steps "inner invoke".
  defp inner_invoke(listeners, event, phase, store) do
    Enum.reduce_while(listeners, :ok, fn listener, :ok ->
      cond do
        phase == :capturing and not listener.capture -> {:cont, :ok}
        phase == :bubbling and listener.capture -> {:cont, :ok}
        true -> call_listener(listener, event, store)
      end
    end)
  end

  defp call_listener(listener, event, store) do
    case request(store, {:begin, listener.id}, :removed) do
      {:ok, callback} when callback != nil ->
        if listener.passive, do: Event.__put_flag__(event, :passive, 1)

        try do
          call(callback, event)
        after
          Event.__put_flag__(event, :passive, 0)
        end

        if Event.__flag__(event, :stop_immediate), do: {:halt, :ok}, else: {:cont, :ok}

      _removed ->
        {:cont, :ok}
    end
  end

  # An exception of a listener is reported, and the dispatch continues, as
  # the steps "inner invoke" specify.
  defp call(callback, event) do
    if is_function(callback, 1), do: callback.(event), else: callback.()
  catch
    kind, reason ->
      Logger.error(
        "A listener of the event #{inspect(event.type)} failed.\n" <>
          Exception.format(kind, reason, __STACKTRACE__)
      )
  end

  # A request to the process of the target. A target whose process stopped
  # has no listener.
  defp request(nil, _request, default), do: default

  defp request(store, request, default) do
    GenServer.call(store, {:listeners, request}, :infinity)
  catch
    :exit, _reason -> default
  end

  defp put(event, key, value) do
    if Map.has_key?(event, key), do: Map.put(event, key, value), else: event
  end
end
