defmodule Web.Internal.EventTarget.Dispatch do
  @moduledoc false

  # The steps "dispatch" of the DOM Standard, for a target with no parent:
  # a `Web.EventTarget` and a `Web.AbortSignal`.
  #
  # The dispatch runs in the process that calls it, as `dispatchEvent()`
  # runs the listeners before it returns. The process of the target keeps
  # the listeners and never runs the code of a user: a listener can thus
  # add a listener, remove a listener, and dispatch an event to the same
  # target.
  #
  # Before the call of each listener, the dispatch asks the process of the
  # target if the listener is still there: a listener that a different
  # listener removed is not called, as the flag "removed" of the Standard
  # specifies.

  require Logger

  alias Web.DOMException
  alias Web.Event

  @at_target 2

  @doc """
  Dispatches `event` to `target`, as `dispatchEvent(event)`. `store` is the
  pid of the process with the listeners, or `nil` for a target with no
  listener. Returns `false` when a listener canceled the event.

  With `trusted: true`, the event keeps its `is_trusted`, as the steps
  "fire an event" do. Else `is_trusted` becomes `false`.

  Raises an `InvalidStateError` for an event that is in a dispatch now.
  """
  @spec dispatch(term(), map(), pid() | nil, keyword()) :: boolean()
  def dispatch(target, event, store, opts \\ []) do
    flags = flags(event)

    if Event.__flag__(flags, :dispatch) do
      raise DOMException, name: "InvalidStateError", message: "The event is already dispatched."
    end

    Event.__put_flag__(flags, :dispatch, 1)

    event =
      if Keyword.get(opts, :trusted, false), do: event, else: put(event, :is_trusted, false)

    try do
      # The path has only the target. The "capturing" pass calls the
      # listeners with capture, and the "bubbling" pass the others.
      Event.__put_phase__(flags, @at_target)
      invoke(target, event, flags, :capturing, store)
      Event.__put_phase__(flags, @at_target)
      invoke(target, event, flags, :bubbling, store)
    after
      Event.__put_phase__(flags, 0)

      for flag <- [:dispatch, :stop_propagation, :stop_immediate],
          do: Event.__put_flag__(flags, flag, 0)
    end

    not Event.default_prevented?(flags)
  end

  # The flags of the event. A map with no flags, such as `%{type: "x"}`,
  # has flags for the time of the dispatch: no listener can change them.
  defp flags(%{flags: flags} = event) when flags != nil, do: event
  defp flags(_event), do: %{flags: Event.__flags__()}

  # The steps "invoke".
  defp invoke(target, event, flags, phase, store) do
    event = put(event, :target, target)

    unless Event.__flag__(flags, :stop_propagation) do
      event = put(event, :current_target, target)
      listeners = request(store, {:clone, to_string(event.type)}, [])
      inner_invoke(listeners, event, flags, phase, store)
    end

    :ok
  end

  # The steps "inner invoke".
  defp inner_invoke(listeners, event, flags, phase, store) do
    Enum.reduce_while(listeners, :ok, fn listener, :ok ->
      cond do
        phase == :capturing and not listener.capture -> {:cont, :ok}
        phase == :bubbling and listener.capture -> {:cont, :ok}
        true -> call_listener(listener, event, flags, store)
      end
    end)
  end

  defp call_listener(listener, event, flags, store) do
    case request(store, {:begin, listener.id}, :removed) do
      {:ok, callback} when callback != nil ->
        if listener.passive, do: Event.__put_flag__(flags, :passive, 1)

        try do
          call(callback, event)
        after
          Event.__put_flag__(flags, :passive, 0)
        end

        if Event.__flag__(flags, :stop_immediate), do: {:halt, :ok}, else: {:cont, :ok}

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
