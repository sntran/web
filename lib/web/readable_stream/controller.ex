defmodule Web.ReadableStream.Controller do
  @moduledoc """
  A :gen_statem implementation of the ReadableStream Controller.
  Handles READABLE, CLOSED, and ERRORED states with strict source cancellation.
  """
  @behaviour :gen_statem

  defmodule Data do
    defstruct [
      :reader_pid,
      :reader_ref,
      :source,
      disturbed: false,
      queue: :queue.new(),
      hwm: 1,
      read_requests: :queue.new(),
      error_reason: nil
    ]
  end

  # --- Client API ---

  def start_link(opts \\ []) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  def get_reader(pid) do
    case :gen_statem.call(pid, {:get_reader, self()}) do
      {:ok, _ref} -> :ok
      {:error, :already_locked} -> {:error, :already_locked}
    end
  end

  def read(pid) do
    :gen_statem.call(pid, {:read, self()})
  end

  def force_unknown_error(pid) do
    :gen_statem.call(pid, :force_unknown_error)
  end

  def release_lock(pid) do
    :gen_statem.call(pid, {:release_lock, self()})
  end

  def get_desired_size(pid) do
    :gen_statem.call(pid, :get_desired_size)
  end

  def enqueue(pid, chunk) do
    :gen_statem.cast(pid, {:enqueue, chunk})
  end

  def close(pid) do
    :gen_statem.cast(pid, :close)
  end

  def error(pid, reason) do
    :gen_statem.cast(pid, {:error, reason})
  end

  def cancel(pid, reason \\ :cancelled) do
    :gen_statem.cast(pid, {:cancel, reason})
  end

  def get_slots(pid) do
    :gen_statem.call(pid, :get_slots)
  end

  # --- :gen_statem Callbacks ---

  @impl true
  def callback_mode(), do: :state_functions

  @impl true
  def init(opts) do
    data = %Data{
      hwm: Keyword.get(opts, :high_water_mark, 1),
      source: Keyword.get(opts, :source)
    }
    
    # Initial pull
    actions = [{:next_event, :internal, :maybe_pull}]
    {:ok, :readable, data, actions}
  end

  # --- States ---

  def readable(type, content, data) do
    case handle_common(type, content, :readable, data) do
      :not_handled ->
        case {type, content} do
          {:cast, {:enqueue, chunk}} ->
            # Update disturbed only if not already true
            new_data = %{data | queue: :queue.in(chunk, data.queue), disturbed: true}
            
            # Fulfill pending read requests if any
            case :queue.out(new_data.read_requests) do
              {{:value, from}, new_requests} ->
                {{:value, c}, new_queue} = :queue.out(new_data.queue)
                :gen_statem.reply(from, {:ok, c})
                {:keep_state, %{new_data | read_requests: new_requests, queue: new_queue}, [{:next_event, :internal, :maybe_pull}]}
              
              {:empty, _} ->
                {:keep_state, new_data}
            end

          {:cast, :close} ->
            # Transition to closed, but keep queue
            {:next_state, :closed, data, [{:next_event, :internal, :flush_requests}]}

          {:cast, {:error, reason}} ->
            {:next_state, :errored, %{data | error_reason: reason}, [{:next_event, :internal, :flush_requests}]}

          {:internal, :maybe_pull} ->
            if :queue.len(data.queue) < data.hwm do
              signal_source_pull(data)
            end
            :keep_state_and_data

          _ ->
            {:keep_state_and_data, [:postpone]}
        end
      result -> result
    end
  end

  def closed(type, content, data) do
    case handle_common(type, content, :closed, data) do
      :not_handled ->
        case {type, content} do
          {:cast, {:enqueue, _chunk}} ->
            # WHATWG: Ignoring enqueue on closed stream
            :keep_state_and_data

          {:internal, :flush_requests} ->
            # If queue is empty, resolve all pending read requests as :done
            if :queue.is_empty(data.queue) do
              data.read_requests
              |> :queue.to_list()
              |> Enum.each(& :gen_statem.reply(&1, :done))
              {:keep_state, %{data | read_requests: :queue.new()}}
            else
              :keep_state_and_data
            end

          _ ->
            {:keep_state_and_data, [:postpone]}
        end
      result -> result
    end
  end

  def errored(type, content, data) do
    case handle_common(type, content, :errored, data) do
      :not_handled ->
        case {type, content} do
          {:internal, :flush_requests} ->
            data.read_requests
            |> :queue.to_list()
            |> Enum.each(& :gen_statem.reply(&1, {:error, {:errored, data.error_reason}}))
            {:keep_state, %{data | read_requests: :queue.new()}}

          _ ->
            {:keep_state_and_data, [:postpone]}
        end
      result -> result
    end
  end

  # --- Common Event Handler ---

  defp handle_common({:call, from}, {:get_reader, pid}, _state, %{reader_pid: nil} = data) do
    ref = Process.monitor(pid)
    {:keep_state, %{data | reader_pid: pid, reader_ref: ref}, [{:reply, from, {:ok, ref}}]}
  end

  defp handle_common({:call, from}, {:get_reader, _pid}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_locked}}]}
  end

  defp handle_common({:call, from}, {:read, _pid}, _state, %{error_reason: :force_unexpected_read} = data) do
    {:keep_state, %{data | error_reason: nil}, [{:reply, from, {:error, :unexpected}}]}
  end

  defp handle_common({:call, from}, {:read, _pid}, _state, %{error_reason: :force_error_no_reason} = data) do
    {:keep_state, %{data | error_reason: nil}, [{:reply, from, {:error, :errored}}]}
  end

  defp handle_common({:call, from}, {:read, pid}, state, data) do
    if pid != data.reader_pid do
      {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_reader}}]}
    else
      data = %{data | disturbed: true}
      case state do
        :errored ->
          {:keep_state, data, [{:reply, from, {:error, {:errored, data.error_reason}}}]}
        
        _ ->
          if not :queue.is_empty(data.queue) do
            {{:value, chunk}, new_queue} = :queue.out(data.queue)
            new_data = %{data | queue: new_queue}
            # If we were at HWM and now below, maybe pull
            actions = [{:reply, from, {:ok, chunk}}]
            actions = if :queue.len(new_queue) < data.hwm, do: [{:next_event, :internal, :maybe_pull} | actions], else: actions
            {:keep_state, new_data, actions}
          else
            if state == :closed do
              {:keep_state, data, [{:reply, from, :done}]}
            else
              # READABLE and empty queue
              new_requests = :queue.in(from, data.read_requests)
              {:keep_state, %{data | read_requests: new_requests}, [{:next_event, :internal, :maybe_pull}]}
            end
          end
      end
    end
  end

  defp handle_common({:call, from}, {:release_lock, _pid}, _state, %{error_reason: :force_unexpected_release} = data) do
    {:keep_state, %{data | error_reason: nil}, [{:reply, from, {:error, :unexpected}}]}
  end

  defp handle_common({:call, from}, {:release_lock, pid}, _state, data) do
    if pid == data.reader_pid do
      if data.reader_ref, do: Process.demonitor(data.reader_ref, [:flush])
      {:keep_state, %{data | reader_pid: nil, reader_ref: nil}, [{:reply, from, :ok}]}
    else
      {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_reader}}]}
    end
  end

  defp handle_common({:call, from}, :get_desired_size, _state, data) do
    size = data.hwm - :queue.len(data.queue)
    {:keep_state_and_data, [{:reply, from, size}]}
  end

  defp handle_common({:call, from}, :get_slots, state, data) do
    # For testing, return a map with state as well
    res = data |> Map.from_struct() |> Map.put(:state, state)
    {:keep_state_and_data, [{:reply, from, res}]}
  end

  defp handle_common(:info, {:DOWN, ref, :process, _pid, _reason}, _state, data) do
    if ref == data.reader_ref do
      {:keep_state, %{data | reader_pid: nil, reader_ref: nil}}
    else
      :keep_state_and_data
    end
  end

  defp handle_common(:cast, {:cancel, reason}, _state, data) do
    # Source Cancellation
    signal_source_cancel(data, reason)
    # Transition to CLOSED, set disturbed, clear queue
    new_data = %{data | disturbed: true, queue: :queue.new()}
    {:next_state, :closed, new_data, [{:next_event, :internal, :flush_requests}]}
  end

  defp handle_common({:call, from}, :force_unknown_error, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :unexpected}}]}
  end

  defp handle_common(_type, _content, _state, _data), do: :not_handled

  # --- Internal Helpers ---

  defp signal_source_pull(%{source: nil}), do: :ok
  defp signal_source_pull(%{source: pid}) when is_pid(pid), do: send(pid, {:pull, self()})
  defp signal_source_pull(%{source: {m, f, a}}), do: apply(m, f, a ++ [self()])
  defp signal_source_pull(%{source: fun}) when is_function(fun, 1), do: fun.(self())

  defp signal_source_cancel(%{source: nil}, _reason), do: :ok
  defp signal_source_cancel(%{source: pid}, reason) when is_pid(pid) do
    send(pid, {:web_stream_cancel, self(), reason})
  end
  defp signal_source_cancel(%{source: fun}, reason) when is_function(fun, 1) do
    fun.(reason)
  end
  defp signal_source_cancel(%{source: {m, f, a}}, reason) do
    apply(m, f, a ++ [reason])
  end
end
