# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule Web.AbortSignal do
  @moduledoc """
  An implementation of the WHATWG AbortSignal standard.

  Represents an abortable signal that can be shared across fetch operations.
  Signals are usually created through `Web.AbortController.new/0`.

  ## Examples

      iex> controller = Web.AbortController.new()
      iex> signal = controller.signal
      iex> {signal.aborted, signal.reason, is_pid(signal.pid), is_reference(signal.ref)}
      {false, nil, true, true}
      iex> timeout_signal = Web.AbortSignal.timeout(1)
      iex> Process.sleep(10)
      iex> Web.AbortSignal.subscribe(timeout_signal)
      {:error, :aborted}
      iex> aborted_signal = Web.AbortSignal.abort(:manual_cancel)
      iex> {aborted_signal.aborted, aborted_signal.reason}
      {true, :manual_cancel}
      iex> any_signal = Web.AbortSignal.any([signal, aborted_signal])
      iex> Web.AbortSignal.subscribe(any_signal)
      {:error, :aborted}
      iex> Web.AbortController.abort(controller)
      :ok
  """

  use GenServer
  @reason_key __MODULE__

  alias Web.DOMException

  defstruct aborted: false, reason: nil, pid: nil, ref: nil

  @type t :: %__MODULE__{
          aborted: boolean(),
          reason: any(),
          pid: pid() | nil,
          ref: reference() | nil
        }

  @type subscription ::
          nil
          | %{type: :abort_signal, pid: pid(), ref: reference(), monitor_ref: reference()}
          | %{type: :pid, pid: pid(), monitor_ref: reference()}
          | %{type: :token, token: term()}

  @doc """
  Returns a new signal that is already aborted.

  ## Examples

      iex> signal = Web.AbortSignal.abort(:timeout)
      iex> {signal.aborted, signal.reason, signal.pid == nil}
      {true, :timeout, true}
  """
  def abort(reason \\ :aborted) do
    %__MODULE__{aborted: true, reason: reason, ref: make_ref()}
  end

  @doc """
  Returns a signal that aborts automatically after `ms` milliseconds.

  ## Examples

      iex> signal = Web.AbortSignal.timeout(1)
      iex> is_pid(signal.pid) and is_reference(signal.ref)
      true
      iex> Process.sleep(10)
      iex> Web.AbortSignal.subscribe(signal)
      {:error, :aborted}
  """
  def timeout(ms) do
    controller = Web.AbortController.new()
    Process.send_after(controller.signal.pid, {:abort_signal_timeout, :timeout}, ms)
    controller.signal
  end

  @doc """
  Returns a signal that aborts when any provided signal aborts.

  ## Examples

      iex> controller = Web.AbortController.new()
      iex> signal = Web.AbortSignal.any([controller.signal, Web.AbortSignal.abort(:boom)])
      iex> {signal.aborted, signal.reason}
      {true, :boom}
      iex> Web.AbortController.abort(controller)
      :ok
  """
  def any(signals) do
    case Enum.find_value(signals, &any_abort_result/1) do
      {:aborted, reason} ->
        abort(reason)

      nil ->
        controller = Web.AbortController.new()

        spawn_link(fn ->
          wait_for_any_abort(signals, controller)
        end)

        controller.signal
    end
  end

  def start_link do
    ref = make_ref()
    GenServer.start(__MODULE__, %{ref: ref, subscribers: %{}})
  end

  @doc false
  def child_spec(_init) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}}
  end

  @doc false
  def init(state), do: {:ok, state}

  @doc false
  def subscribe(nil), do: {:ok, nil}

  def subscribe(%__MODULE__{aborted: true}), do: {:error, :aborted}

  def subscribe(%__MODULE__{pid: pid, ref: ref}) when is_pid(pid) and is_reference(ref) do
    if Process.alive?(pid) do
      :ok = GenServer.call(pid, {:subscribe, self()})
      {:ok, %{type: :abort_signal, pid: pid, ref: ref, monitor_ref: Process.monitor(pid)}}
    else
      {:error, :aborted}
    end
  catch
    # coveralls-ignore-start
    :exit, _ ->
      {:error, :aborted}
      # coveralls-ignore-stop
  end

  def subscribe(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      {:ok, %{type: :pid, pid: pid, monitor_ref: Process.monitor(pid)}}
    else
      {:error, :aborted}
    end
  end

  def subscribe(token) do
    {:ok, %{type: :token, token: token}}
  end

  @doc false
  def unsubscribe(nil), do: :ok

  def unsubscribe(%{monitor_ref: monitor_ref}) do
    Process.demonitor(monitor_ref, [:flush])
    :ok
  end

  def unsubscribe(%{type: :token}), do: :ok

  @doc false
  def check!(nil), do: :ok

  def check!(signal) do
    case subscribe(signal) do
      {:ok, subscription} ->
        try do
          case receive_abort(subscription, 0, true) do
            :ok ->
              :ok

            {:error, :aborted, reason} ->
              throw({:abort, normalize_reason(signal, reason)})
          end
        after
          unsubscribe(subscription)
        end

      {:error, :aborted} ->
        throw({:abort, normalize_reason(signal, :aborted)})
    end
  end

  @doc """
  Returns whether a signal has already aborted.
  """
  def aborted?(nil), do: false
  def aborted?(%__MODULE__{aborted: true}), do: true

  def aborted?(%__MODULE__{pid: pid} = signal) when is_pid(pid) do
    case subscribe(signal) do
      {:error, :aborted} ->
        true

      {:ok, subscription} ->
        try do
          match?({:error, :aborted, _reason}, receive_abort(subscription, 0, true))
        after
          unsubscribe(subscription)
        end
    end
  end

  def aborted?(_), do: false

  @doc """
  Returns the abort reason when available, otherwise `nil`.
  """
  def reason(nil), do: nil
  def reason(%__MODULE__{aborted: true, reason: reason}), do: reason

  def reason(%__MODULE__{pid: pid} = signal) when is_pid(pid) do
    case subscribe(signal) do
      {:error, :aborted} ->
        receive_signal_reason(signal)

      {:ok, subscription} ->
        try do
          case receive_abort(subscription, 0, true) do
            {:error, :aborted, reason} -> reason
            :ok -> nil
          end
        after
          unsubscribe(subscription)
        end
    end
  end

  def reason(_), do: nil

  @doc """
  Raises a `Web.DOMException` when the signal has already aborted.
  """
  @spec throw_if_aborted(t() | nil) :: :ok
  def throw_if_aborted(nil), do: :ok

  def throw_if_aborted(%__MODULE__{aborted: true, reason: reason}) do
    raise DOMException, name: "AbortError", message: inspect(reason)
  end

  def throw_if_aborted(%__MODULE__{} = signal) do
    case any_abort_result(signal) do
      {:aborted, reason} ->
        raise DOMException, name: "AbortError", message: inspect(reason)

      nil ->
        :ok
    end
  end

  defp normalize_reason(signal, :aborted), do: reason(signal) || :aborted
  defp normalize_reason(_signal, reason), do: reason

  defp receive_signal_reason(%__MODULE__{pid: pid, ref: ref, reason: fallback}) do
    subscription = %{type: :abort_signal, pid: pid, ref: ref, monitor_ref: Process.monitor(pid)}

    try do
      case receive_abort(subscription, 0, true) do
        {:error, :aborted, reason} ->
          reason

        :ok ->
          remembered_reason(ref) || fallback || if(Process.alive?(pid), do: nil, else: :aborted)
      end
    after
      Process.demonitor(subscription.monitor_ref, [:flush])
    end
  end

  defp remember_reason(ref, reason) when is_reference(ref) do
    :persistent_term.put({@reason_key, ref}, reason)
    :ok
  end

  defp remembered_reason(ref) when is_reference(ref) do
    :persistent_term.get({@reason_key, ref}, nil)
  end

  @doc false
  def receive_abort(nil, _timeout), do: :ok

  def receive_abort(%{type: :abort_signal, pid: pid, ref: ref, monitor_ref: monitor_ref}, timeout) do
    case receive_abort(
           %{type: :abort_signal, pid: pid, ref: ref, monitor_ref: monitor_ref},
           timeout,
           true
         ) do
      :ok -> :ok
      {:error, :aborted, _reason} -> {:error, :aborted}
    end
  end

  def receive_abort(%{type: :pid, pid: pid, monitor_ref: monitor_ref}, timeout) do
    case receive_abort(%{type: :pid, pid: pid, monitor_ref: monitor_ref}, timeout, true) do
      :ok -> :ok
      {:error, :aborted, _reason} -> {:error, :aborted}
    end
  end

  def receive_abort(%{type: :token, token: token}, timeout) do
    case receive_abort(%{type: :token, token: token}, timeout, true) do
      :ok -> :ok
      {:error, :aborted, _reason} -> {:error, :aborted}
    end
  end

  def receive_abort(nil, _timeout, _with_reason?), do: :ok

  def receive_abort(
        %{type: :abort_signal, pid: pid, ref: ref, monitor_ref: monitor_ref},
        timeout,
        true
      ) do
    receive do
      {:abort, ^ref, reason} ->
        {:error, :aborted, reason}

      {:DOWN, ^monitor_ref, :process, ^pid, {:shutdown, {:aborted, reason}}} ->
        {:error, :aborted, reason}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, :aborted, reason}
    after
      timeout ->
        :ok
    end
  end

  def receive_abort(%{type: :pid, pid: pid, monitor_ref: monitor_ref}, timeout, true) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, :aborted, reason}

      {:abort, ^pid, reason} ->
        {:error, :aborted, reason}
    after
      timeout ->
        if Process.alive?(pid), do: :ok, else: {:error, :aborted, :aborted}
    end
  end

  def receive_abort(%{type: :token, token: token}, timeout, true) do
    receive do
      {:abort, ^token} ->
        {:error, :aborted, :aborted}

      {:abort, ^token, reason} ->
        {:error, :aborted, reason}
    after
      timeout ->
        :ok
    end
  end

  @doc false
  def handle_call({:subscribe, subscriber}, _from, %{subscribers: subscribers} = state) do
    monitor_ref = Process.monitor(subscriber)
    subscribers = Map.put(subscribers, subscriber, monitor_ref)
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @doc false
  def handle_call({:abort, reason}, _from, %{ref: ref, subscribers: subscribers} = state) do
    remember_reason(ref, reason)

    Enum.each(Map.keys(subscribers), fn subscriber ->
      send(subscriber, {:abort, ref, reason})
    end)

    {:stop, {:shutdown, {:aborted, reason}}, :ok, state}
  end

  @doc false
  def handle_cast({:abort, reason}, %{ref: ref, subscribers: subscribers} = state) do
    remember_reason(ref, reason)

    Enum.each(Map.keys(subscribers), fn subscriber ->
      send(subscriber, {:abort, ref, reason})
    end)

    {:stop, {:shutdown, {:aborted, reason}}, state}
  end

  @doc false
  def handle_info({:abort_signal_timeout, reason}, state) do
    handle_cast({:abort, reason}, state)
  end

  @doc false
  def handle_info(
        {:DOWN, monitor_ref, :process, subscriber, _reason},
        %{subscribers: subscribers} = state
      ) do
    subscribers =
      case Map.get(subscribers, subscriber) do
        ^monitor_ref -> Map.delete(subscribers, subscriber)
        _ -> subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  defp any_abort_result(%__MODULE__{aborted: true, reason: reason}), do: {:aborted, reason}

  defp any_abort_result(%__MODULE__{} = signal) do
    case subscribe(signal) do
      {:ok, subscription} ->
        try do
          case receive_abort(subscription, 0, true) do
            {:error, :aborted, reason} -> {:aborted, reason}
            :ok -> nil
          end
        after
          unsubscribe(subscription)
        end

      {:error, :aborted} ->
        reason = reason(signal)
        if(is_nil(reason), do: nil, else: {:aborted, reason})
    end
  end

  defp any_abort_result(_signal), do: nil

  defp wait_for_any_abort(signals, controller) do
    address = Process.alias([:reply])
    coordinator = self()

    Enum.each(signals, &start_any_abort_waiter(&1, coordinator, address))

    try do
      receive do
        {:abort_signal_any, ^address, reason} ->
          Process.unalias(address)
          Web.AbortController.abort(controller, reason)
      end
    after
      Process.unalias(address)
    end
  end

  defp start_any_abort_waiter(nil, _coordinator, _address), do: :ok

  defp start_any_abort_waiter(signal, coordinator, address) do
    spawn(fn ->
      coordinator_monitor = Process.monitor(coordinator)

      try do
        case subscribe(signal) do
          {:ok, subscription} ->
            try do
              case wait_for_subscription_or_coordinator(
                     subscription,
                     coordinator,
                     coordinator_monitor
                   ) do
                {:aborted, reason} -> send(address, {:abort_signal_any, address, reason})
                :ok -> :ok
              end
            after
              unsubscribe(subscription)
            end

          {:error, :aborted} ->
            maybe_forward_any_abort(signal, address)
        end
      after
        Process.demonitor(coordinator_monitor, [:flush])
      end
    end)
  end

  defp maybe_forward_any_abort(signal, address) do
    case any_abort_result(signal) do
      {:aborted, reason} -> send(address, {:abort_signal_any, address, reason})
      nil -> :ok
    end
  end

  defp wait_for_subscription_or_coordinator(
         %{type: :abort_signal, pid: pid, ref: ref, monitor_ref: monitor_ref},
         coordinator,
         coordinator_monitor
       ) do
    receive do
      {:abort, ^ref, reason} ->
        {:aborted, reason}

      {:DOWN, ^monitor_ref, :process, ^pid, {:shutdown, {:aborted, reason}}} ->
        {:aborted, reason}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:aborted, reason}

      {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason} ->
        :ok
    end
  end

  defp wait_for_subscription_or_coordinator(
         %{type: :pid, pid: pid, monitor_ref: monitor_ref},
         coordinator,
         coordinator_monitor
       ) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:aborted, reason}

      {:abort, ^pid, reason} ->
        {:aborted, reason}

      {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason} ->
        :ok
    end
  end

  defp wait_for_subscription_or_coordinator(
         %{type: :token, token: token},
         coordinator,
         coordinator_monitor
       ) do
    receive do
      {:abort, ^token} ->
        {:aborted, :aborted}

      {:abort, ^token, reason} ->
        {:aborted, reason}

      {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason} ->
        :ok
    end
  end
end
