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
    case Enum.find(signals, &already_aborted?/1) do
      %__MODULE__{reason: reason} ->
        abort(reason)

      _ ->
        controller = Web.AbortController.new()

        spawn_link(fn ->
          subscriptions =
            signals
            |> Enum.map(&subscribe/1)
            |> Enum.flat_map(fn
              {:ok, subscription} -> [subscription]
              {:error, :aborted} -> []
            end)

          wait_for_any_abort(subscriptions, controller)
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

            {:error, :aborted, _reason} ->
              throw({:abort, :aborted})
          end
        after
          unsubscribe(subscription)
        end

      {:error, :aborted} ->
        throw({:abort, :aborted})
    end
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
  def handle_cast({:abort, reason}, %{ref: ref, subscribers: subscribers} = state) do
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

  defp already_aborted?(%__MODULE__{aborted: true}), do: true
  defp already_aborted?(_signal), do: false

  defp wait_for_any_abort(subscriptions, controller) do
    case Enum.find_value(subscriptions, fn subscription ->
           case receive_abort(subscription, 0, true) do
             {:error, :aborted, reason} -> reason
             :ok -> nil
           end
         end) do
      nil ->
        receive do
        after
          10 -> wait_for_any_abort(subscriptions, controller)
        end

      reason ->
        Web.AbortController.abort(controller, reason)
    end
  after
    Enum.each(subscriptions, &unsubscribe/1)
  end
end
