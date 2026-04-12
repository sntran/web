defmodule Web.EventTarget do
  @moduledoc """
  Foundational event listener storage and dispatch helpers.

  Store this struct in process state for evented modules, then route lifecycle
  events through `handle_info/2` to support abort-signal based listener cleanup.
  """

  alias Web.AbortSignal
  alias Web.CustomEvent

  @abort_message_prefix {__MODULE__, :abort_signal}

  defstruct owner: nil, listeners: %{}, next_id: 0

  @type callback :: (CustomEvent.t() -> any()) | (-> any())
  @type listener :: %{
          id: non_neg_integer(),
          callback: callback(),
          once: boolean(),
          watcher: pid() | nil
        }
  @type t :: %__MODULE__{
          owner: pid() | nil,
          listeners: %{optional(String.t()) => [listener()]},
          next_id: non_neg_integer()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{owner: Keyword.get(opts, :owner, self())}
  end

  @spec add_event_listener(t(), String.t() | atom(), callback(), keyword() | map()) :: t()
  # coveralls-ignore-start
  def add_event_listener(%__MODULE__{} = target, type, callback)
      when is_function(callback, 0) or is_function(callback, 1),
      do: add_event_listener(target, type, callback, %{})

  # coveralls-ignore-stop

  def add_event_listener(%__MODULE__{} = target, type, callback, options)
      when is_function(callback, 0) or is_function(callback, 1) do
    type = normalize_type(type)

    if listener_registered?(target, type, callback) do
      target
    else
      opts = normalize_options(options)
      signal = Map.get(opts, :signal)

      if signal && AbortSignal.aborted?(signal) do
        target
      else
        id = target.next_id
        watcher = maybe_start_signal_watcher(target.owner, signal, id)

        listener = %{
          id: id,
          callback: callback,
          once: Map.get(opts, :once, false),
          watcher: watcher
        }

        listeners = Map.update(target.listeners, type, [listener], &(&1 ++ [listener]))
        %{target | listeners: listeners, next_id: id + 1}
      end
    end
  end

  def unquote(:addEventListener)(target, type, callback, options \\ %{}) do
    add_event_listener(target, type, callback, options)
  end

  @spec remove_event_listener(t(), String.t() | atom(), callback()) :: t()
  def remove_event_listener(%__MODULE__{} = target, type, callback)
      when is_function(callback, 0) or is_function(callback, 1) do
    type = normalize_type(type)

    {removed, kept} =
      target.listeners
      |> Map.get(type, [])
      |> Enum.split_with(&same_callback?(&1.callback, callback))

    Enum.each(removed, &stop_watcher(&1.watcher))

    listeners =
      case kept do
        [] -> Map.delete(target.listeners, type)
        _ -> Map.put(target.listeners, type, kept)
      end

    %{target | listeners: listeners}
  end

  def unquote(:removeEventListener)(target, type, callback) do
    remove_event_listener(target, type, callback)
  end

  @spec dispatch_event(t(), CustomEvent.t()) :: {t(), boolean()}
  def dispatch_event(%__MODULE__{} = target, %CustomEvent{} = event) do
    type = normalize_type(event.type)
    listeners = Map.get(target.listeners, type, [])

    updated_target =
      Enum.reduce(listeners, target, fn listener, acc ->
        invoke_callback(listener.callback, event)

        if listener.once do
          remove_listener_by_id(acc, type, listener.id)
        else
          acc
        end
      end)

    {updated_target, true}
  end

  def unquote(:dispatchEvent)(target, event) do
    dispatch_event(target, event)
  end

  @spec handle_info(t(), term()) :: {:ok, t()} | :unknown
  def handle_info(%__MODULE__{} = target, {@abort_message_prefix, listener_id}) do
    {:ok, remove_listener_by_id(target, listener_id)}
  end

  def handle_info(%__MODULE__{}, _message), do: :unknown

  defp normalize_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalize_type(type), do: to_string(type)

  defp normalize_options(options) when is_list(options), do: Map.new(options)
  defp normalize_options(%{} = options), do: options

  defp listener_registered?(%__MODULE__{} = target, type, callback) do
    target.listeners
    |> Map.get(type, [])
    |> Enum.any?(&same_callback?(&1.callback, callback))
  end

  defp same_callback?(left, right) do
    module_matches? = :erlang.fun_info(left, :module) == :erlang.fun_info(right, :module)
    index_matches? = :erlang.fun_info(left, :new_index) == :erlang.fun_info(right, :new_index)
    uniq_matches? = :erlang.fun_info(left, :uniq) == :erlang.fun_info(right, :uniq)

    module_matches? and index_matches? and uniq_matches?
  end

  defp maybe_start_signal_watcher(_owner, nil, _listener_id), do: nil
  defp maybe_start_signal_watcher(nil, _signal, _listener_id), do: nil

  defp maybe_start_signal_watcher(owner, signal, listener_id) do
    spawn(fn -> watch_signal(owner, signal, listener_id) end)
  end

  defp watch_signal(owner, signal, listener_id) do
    owner_ref = Process.monitor(owner)

    case AbortSignal.subscribe(signal) do
      {:ok, subscription} ->
        try do
          await_signal_or_owner(subscription, owner, owner_ref, listener_id)
        after
          AbortSignal.unsubscribe(subscription)
          Process.demonitor(owner_ref, [:flush])
        end

      {:error, :aborted} ->
        send(owner, {@abort_message_prefix, listener_id})
        Process.demonitor(owner_ref, [:flush])
    end
  end

  defp await_signal_or_owner(
         %{type: :abort_signal, pid: pid, ref: ref, monitor_ref: signal_ref},
         owner,
         owner_ref,
         listener_id
       ) do
    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        :ok

      {:abort, ^ref, _reason} ->
        send(owner, {@abort_message_prefix, listener_id})

      {:DOWN, ^signal_ref, :process, ^pid, _reason} ->
        send(owner, {@abort_message_prefix, listener_id})

      _other ->
        await_signal_or_owner(
          %{type: :abort_signal, pid: pid, ref: ref, monitor_ref: signal_ref},
          owner,
          owner_ref,
          listener_id
        )
    end
  end

  defp await_signal_or_owner(
         %{type: :pid, pid: pid, monitor_ref: signal_ref},
         owner,
         owner_ref,
         listener_id
       ) do
    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        :ok

      {:abort, ^pid, _reason} ->
        send(owner, {@abort_message_prefix, listener_id})

      {:DOWN, ^signal_ref, :process, ^pid, _reason} ->
        send(owner, {@abort_message_prefix, listener_id})

      _other ->
        await_signal_or_owner(
          %{type: :pid, pid: pid, monitor_ref: signal_ref},
          owner,
          owner_ref,
          listener_id
        )
    end
  end

  defp await_signal_or_owner(%{type: :token, token: token}, owner, owner_ref, listener_id) do
    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        :ok

      {:abort, ^token} ->
        send(owner, {@abort_message_prefix, listener_id})

      {:abort, ^token, _reason} ->
        send(owner, {@abort_message_prefix, listener_id})

      _other ->
        await_signal_or_owner(%{type: :token, token: token}, owner, owner_ref, listener_id)
    end
  end

  defp invoke_callback(callback, event) when is_function(callback, 1), do: callback.(event)
  defp invoke_callback(callback, _event) when is_function(callback, 0), do: callback.()

  defp remove_listener_by_id(%__MODULE__{} = target, listener_id) do
    Enum.reduce(Map.keys(target.listeners), target, fn type, acc ->
      remove_listener_by_id(acc, type, listener_id)
    end)
  end

  defp remove_listener_by_id(%__MODULE__{} = target, type, listener_id) do
    {removed, kept} =
      target.listeners
      |> Map.get(type, [])
      |> Enum.split_with(&(&1.id == listener_id))

    Enum.each(removed, &stop_watcher(&1.watcher))

    listeners =
      case kept do
        [] -> Map.delete(target.listeners, type)
        _ -> Map.put(target.listeners, type, kept)
      end

    %{target | listeners: listeners}
  end

  defp stop_watcher(nil), do: :ok

  defp stop_watcher(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :normal)
    end

    :ok
  end
end
