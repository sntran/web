defmodule Web.Internal.EventTarget.Server do
  @moduledoc false

  use GenServer

  alias Web.AbortSignal
  alias Web.AsyncContext.Snapshot

  @abort_message_prefix {Web.EventTarget, :abort_signal}

  @type listener :: %{
          id: non_neg_integer(),
          callback: Web.EventTarget.callback(),
          once: boolean(),
          watcher: pid() | nil
        }

  @type state :: %{
          target: struct(),
          callback_module: module(),
          listeners: %{optional(String.t()) => [listener()]},
          next_id: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec add_event_listener(
          pid(),
          String.t() | atom(),
          Web.EventTarget.callback(),
          keyword() | map()
        ) ::
          :ok
  def add_event_listener(pid, type, callback, options)
      when is_pid(pid) and (is_function(callback, 0) or is_function(callback, 1)) do
    GenServer.call(pid, {:add_event_listener, type, callback, options}, :infinity)
  end

  @spec remove_event_listener(pid(), String.t() | atom(), Web.EventTarget.callback()) :: :ok
  def remove_event_listener(pid, type, callback)
      when is_pid(pid) and (is_function(callback, 0) or is_function(callback, 1)) do
    GenServer.call(pid, {:remove_event_listener, type, callback}, :infinity)
  end

  @spec dispatch_event(pid(), Web.EventTarget.event(), Snapshot.t()) :: boolean()
  def dispatch_event(pid, event, %Snapshot{} = snapshot) when is_pid(pid) and is_map(event) do
    GenServer.call(pid, {:dispatch_event, event, snapshot}, :infinity)
  end

  @impl true
  def init(opts) do
    Process.flag(:message_queue_data, :off_heap)

    target = Keyword.fetch!(opts, :target)
    callback_module = Keyword.get(opts, :callback_module, target.__struct__)
    registry_key = Keyword.get(opts, :registry_key, Map.get(target, :ref))
    server_pid = Keyword.get(opts, :server_pid, self())

    if registry_key do
      {:ok, _owner} = Registry.register(Web.Registry, registry_key, %{server_pid: server_pid})
    end

    {:ok,
     %{
       target: target,
       callback_module: callback_module,
       listeners: %{},
       next_id: 0
     }}
  end

  @impl true
  def handle_call({:add_event_listener, type, callback, options}, _from, state) do
    {:reply, :ok, do_add_event_listener(state, type, callback, options)}
  end

  def handle_call({:remove_event_listener, type, callback}, _from, state) do
    {:reply, :ok, do_remove_event_listener(state, type, callback)}
  end

  def handle_call({:dispatch_event, event, snapshot}, _from, state) do
    next_state = do_dispatch_event(state, event, snapshot)
    {:reply, true, next_state}
  end

  @impl true
  def handle_cast({:add_event_listener, type, callback, options}, state) do
    {:noreply, do_add_event_listener(state, type, callback, options)}
  end

  def handle_cast({:remove_event_listener, type, callback}, state) do
    {:noreply, do_remove_event_listener(state, type, callback)}
  end

  def handle_cast({:dispatch_event, event, snapshot}, state) do
    {:noreply, do_dispatch_event(state, event, snapshot)}
  end

  @impl true
  def handle_info({@abort_message_prefix, listener_id}, state) do
    {:noreply, remove_listener_by_id(state, listener_id)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp do_add_event_listener(state, type, callback, options) do
    type = normalize_type(type)

    if listener_registered?(state, type, callback) do
      state
    else
      opts = normalize_options(options)
      signal = Map.get(opts, :signal)

      if signal && AbortSignal.aborted?(signal) do
        state
      else
        next_target = invoke_handle_add_listener(state, type, callback, opts)
        listener_id = state.next_id
        watcher = maybe_start_signal_watcher(self(), signal, listener_id)

        listener = %{
          id: listener_id,
          callback: callback,
          once: Map.get(opts, :once, false),
          watcher: watcher
        }

        listeners = Map.update(state.listeners, type, [listener], &(&1 ++ [listener]))
        %{state | target: next_target, listeners: listeners, next_id: listener_id + 1}
      end
    end
  end

  defp do_remove_event_listener(state, type, callback) do
    type = normalize_type(type)

    {removed, kept} =
      state.listeners
      |> Map.get(type, [])
      |> Enum.split_with(&same_callback?(&1.callback, callback))

    Enum.each(removed, &stop_watcher(&1.watcher))

    listeners =
      case kept do
        [] -> Map.delete(state.listeners, type)
        _listeners -> Map.put(state.listeners, type, kept)
      end

    %{state | listeners: listeners}
  end

  defp do_dispatch_event(state, event, %Snapshot{} = snapshot) do
    Snapshot.run(snapshot, fn ->
      state
      |> invoke_handle_dispatch(event)
      |> invoke_listeners(event)
    end)
  end

  defp invoke_listeners(state, %{type: type} = event) do
    type = normalize_type(type)
    listeners = Map.get(state.listeners, type, [])

    Enum.reduce(listeners, state, fn listener, acc ->
      invoke_callback(listener.callback, event)

      if listener.once do
        remove_listener_by_id(acc, type, listener.id)
      else
        acc
      end
    end)
  end

  defp invoke_handle_add_listener(
         %{callback_module: callback_module, target: target},
         type,
         callback,
         opts
       ) do
    invoke_callback_module(
      callback_module,
      :handle_add_listener,
      [target, type, callback, opts],
      target
    )
  end

  defp invoke_handle_dispatch(%{callback_module: callback_module, target: target} = state, event) do
    next_target =
      invoke_callback_module(callback_module, :handle_dispatch, [target, event], target)

    %{state | target: next_target}
  end

  defp invoke_callback_module(callback_module, function, args, fallback_target) do
    if function_exported?(callback_module, function, length(args)) do
      case apply(callback_module, function, args) do
        {:ok, next_target} when is_map(next_target) -> next_target
        :ok -> fallback_target
      end
    else
      fallback_target
    end
  end

  defp normalize_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalize_type(type), do: to_string(type)

  defp normalize_options(options) when is_list(options), do: Map.new(options)
  defp normalize_options(%{} = options), do: options

  defp listener_registered?(state, type, callback) do
    state.listeners
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

  defp remove_listener_by_id(state, listener_id) do
    Enum.reduce(Map.keys(state.listeners), state, fn type, acc ->
      remove_listener_by_id(acc, type, listener_id)
    end)
  end

  defp remove_listener_by_id(state, type, listener_id) do
    {removed, kept} =
      state.listeners
      |> Map.get(type, [])
      |> Enum.split_with(&(&1.id == listener_id))

    Enum.each(removed, &stop_watcher(&1.watcher))

    listeners =
      case kept do
        [] -> Map.delete(state.listeners, type)
        _listeners -> Map.put(state.listeners, type, kept)
      end

    %{state | listeners: listeners}
  end

  defp stop_watcher(nil), do: :ok

  defp stop_watcher(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    :ok
  end
end
