defmodule Web.WritableStream do
  @moduledoc """
  An Elixir implementation of the WHATWG WritableStream standard.

  This process-backed stream mirrors the ReadableStream architecture in this project:
  a `:gen_statem` owns the internal slots, sink callbacks run in supervised tasks,
  and a writer lock grants exclusive write access.
  """
  @behaviour :gen_statem

  defstruct [:controller_pid]

  alias Web.TypeError
  alias Web.WritableStreamDefaultController
  alias Web.WritableStreamDefaultWriter

  defmodule Data do
    defstruct [
      :underlying_sink,
      :writer_pid,
      :writer_ref,
      :pending_write_request,
      :pending_close_request,
      :task_ref,
      :active_task,
      :active_operation,
      :error_reason,
      high_water_mark: 1,
      backpressure: false,
      queued_write_requests: :queue.new(),
      ready_requests: :queue.new()
    ]
  end

  def start_link(opts \\ []) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  @doc """
  Creates a new WritableStream with the given underlying sink.
  """
  def new(underlying_sink \\ %{})

  def new(underlying_sink) when is_map(underlying_sink) do
    {:ok, pid} = start_link(underlying_sink: underlying_sink)
    %__MODULE__{controller_pid: pid}
  end

  def new(underlying_sink) do
    raise ArgumentError, "underlying_sink must be a map, got: #{inspect(underlying_sink)}"
  end

  @doc """
  Returns whether the stream has an active writer lock.
  """
  def locked?(%__MODULE__{controller_pid: pid}), do: locked?(pid)
  def locked?(pid) when is_pid(pid), do: :gen_statem.call(pid, :locked?)

  @doc """
  Returns the stream desired size or `nil` once it is closed or errored.
  """
  def desired_size(%__MODULE__{controller_pid: pid}), do: desired_size(pid)
  def desired_size(pid) when is_pid(pid), do: :gen_statem.call(pid, :desired_size)

  @doc """
  Returns whether the stream is currently applying backpressure.
  """
  def backpressure?(%__MODULE__{controller_pid: pid}), do: backpressure?(pid)
  def backpressure?(pid) when is_pid(pid), do: :gen_statem.call(pid, :backpressure?)

  @doc """
  Locks the stream and returns a default writer.
  """
  def get_writer(pid) when is_pid(pid) do
    case :gen_statem.call(pid, {:get_writer, self()}) do
      :ok -> :ok
      {:error, :already_locked} -> {:error, :already_locked}
    end
  end

  def get_writer(%__MODULE__{controller_pid: pid}) do
    case get_writer(pid) do
      :ok ->
        %WritableStreamDefaultWriter{controller_pid: pid, owner_pid: self()}

      {:error, :already_locked} ->
        raise TypeError, "WritableStream is already locked"
    end
  end

  def write(pid, chunk) when is_pid(pid) do
    :gen_statem.call(pid, {:write, self(), chunk}, :infinity)
  end

  def write(pid, owner_pid, chunk) when is_pid(pid) and is_pid(owner_pid) do
    :gen_statem.call(pid, {:write, owner_pid, chunk}, :infinity)
  end

  def ready(pid) when is_pid(pid) do
    :gen_statem.call(pid, {:ready, self()}, :infinity)
  end

  def ready(pid, owner_pid) when is_pid(pid) and is_pid(owner_pid) do
    :gen_statem.call(pid, {:ready, owner_pid}, :infinity)
  end

  def close(pid) when is_pid(pid) do
    :gen_statem.call(pid, {:close, self()}, :infinity)
  end

  def close(pid, owner_pid) when is_pid(pid) and is_pid(owner_pid) do
    :gen_statem.call(pid, {:close, owner_pid}, :infinity)
  end

  def abort(pid, reason) when is_pid(pid) do
    :gen_statem.call(pid, {:abort, self(), reason}, :infinity)
  end

  def abort(pid, owner_pid, reason) when is_pid(pid) and is_pid(owner_pid) do
    :gen_statem.call(pid, {:abort, owner_pid, reason}, :infinity)
  end

  def release_lock(pid) when is_pid(pid) do
    :gen_statem.call(pid, {:release_lock, self()})
  end

  def release_lock(pid, owner_pid) when is_pid(pid) and is_pid(owner_pid) do
    :gen_statem.call(pid, {:release_lock, owner_pid})
  end

  def error(pid, reason) when is_pid(pid) do
    :gen_statem.cast(pid, {:error, reason})
  end

  def get_slots(pid) when is_pid(pid) do
    :gen_statem.call(pid, :get_slots)
  end

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def terminate(_reason, _state, data) do
    if data.active_task, do: Task.shutdown(data.active_task, :brutal_kill)
    :ok
  end

  @impl true
  def init(opts) do
    underlying_sink = Keyword.get(opts, :underlying_sink, %{})

    data =
      %Data{
        underlying_sink: underlying_sink,
        high_water_mark:
          Keyword.get(opts, :high_water_mark, Map.get(underlying_sink, :high_water_mark, 1))
      }
      |> maybe_start_sink()
      |> refresh_backpressure()

    {:ok, :writable, data}
  end

  def writable(type, content, data) do
    case handle_common(type, content, :writable, data) do
      :not_handled ->
        case {type, content} do
          {{:call, from}, {:write, pid, chunk}} ->
            handle_write(from, pid, chunk, :writable, data)

          {{:call, from}, {:close, pid}} ->
            handle_close(from, pid, :writable, data)

          {{:call, from}, {:abort, pid, reason}} ->
            handle_abort(from, pid, reason, data)

          # coveralls-ignore-start
          _ ->
            :keep_state_and_data
            # coveralls-ignore-stop
        end

      result ->
        result
    end
  end

  def closing(type, content, data) do
    case handle_common(type, content, :closing, data) do
      :not_handled ->
        case {type, content} do
          {{:call, from}, {:write, pid, _chunk}} ->
            if pid == data.writer_pid do
              {:keep_state_and_data, [{:reply, from, {:error, :closing}}]}
            else
              {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
            end

          {{:call, from}, {:close, pid}} ->
            if pid == data.writer_pid do
              {:keep_state_and_data, [{:reply, from, {:error, :closing}}]}
            else
              {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
            end

          {{:call, from}, {:abort, pid, reason}} ->
            handle_abort(from, pid, reason, data)

          _ ->
            :keep_state_and_data
        end

      result ->
        result
    end
  end

  def closed(type, content, data) do
    case handle_common(type, content, :closed, data) do
      :not_handled ->
        case {type, content} do
          {{:call, from}, {:write, pid, _chunk}} ->
            if pid == data.writer_pid do
              {:keep_state_and_data, [{:reply, from, {:error, :closed}}]}
            else
              {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
            end

          {{:call, from}, {:close, pid}} ->
            if pid == data.writer_pid do
              {:keep_state_and_data, [{:reply, from, :ok}]}
            else
              {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
            end

          {{:call, from}, {:abort, pid, _reason}} ->
            if pid == data.writer_pid do
              {:keep_state_and_data, [{:reply, from, :ok}]}
            else
              {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
            end

          # coveralls-ignore-start
          _ ->
            :keep_state_and_data
            # coveralls-ignore-stop
        end

      result ->
        result
    end
  end

  def errored(type, content, data) do
    case handle_common(type, content, :errored, data) do
      :not_handled ->
        case {type, content} do
          {{:call, from}, {:write, pid, _chunk}} ->
            # coveralls-ignore-start
            if pid == data.writer_pid do
              {:keep_state_and_data, [{:reply, from, {:error, {:errored, data.error_reason}}}]}
            else
              {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
            end
            # coveralls-ignore-stop

          {{:call, from}, {:close, pid}} ->
            # coveralls-ignore-start
            if pid == data.writer_pid do
              {:keep_state_and_data, [{:reply, from, {:error, {:errored, data.error_reason}}}]}
            else
              {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
            end
            # coveralls-ignore-stop

          {{:call, from}, {:abort, pid, _reason}} ->
            # coveralls-ignore-start
            if pid == data.writer_pid do
              {:keep_state_and_data, [{:reply, from, {:error, {:errored, data.error_reason}}}]}
            else
              {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
            end
            # coveralls-ignore-stop

          _ ->
            :keep_state_and_data
        end

      result ->
        result
    end
  end

  defp handle_common({:call, from}, {:get_writer, pid}, _state, %{writer_pid: nil} = data) do
    ref = Process.monitor(pid)
    {:keep_state, %{data | writer_pid: pid, writer_ref: ref}, [{:reply, from, :ok}]}
  end

  defp handle_common({:call, from}, {:get_writer, _pid}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_locked}}]}
  end

  defp handle_common({:call, from}, {:release_lock, pid}, _state, data) do
    if pid == data.writer_pid do
      if data.writer_ref, do: Process.demonitor(data.writer_ref, [:flush])
      {:keep_state, %{data | writer_pid: nil, writer_ref: nil}, [{:reply, from, :ok}]}
    else
      {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
    end
  end

  defp handle_common({:call, from}, {:ready, pid}, state, data) do
    cond do
      pid != data.writer_pid ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}

      # coveralls-ignore-start
      state == :errored ->
        {:keep_state_and_data, [{:reply, from, {:error, {:errored, data.error_reason}}}]}
      # coveralls-ignore-stop

      state == :closed or not data.backpressure ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      true ->
        {:keep_state, %{data | ready_requests: :queue.in(from, data.ready_requests)}}
    end
  end

  defp handle_common({:call, from}, :locked?, _state, data) do
    {:keep_state_and_data, [{:reply, from, not is_nil(data.writer_pid)}]}
  end

  defp handle_common({:call, from}, :backpressure?, _state, data) do
    {:keep_state_and_data, [{:reply, from, data.backpressure}]}
  end

  defp handle_common({:call, from}, :desired_size, state, data) do
    desired_size =
      if state in [:closed, :errored] do
        nil
      else
        internal_desired_size(data)
      end

    {:keep_state_and_data, [{:reply, from, desired_size}]}
  end

  defp handle_common({:call, from}, :get_slots, state, data) do
    slots =
      data
      |> Map.from_struct()
      |> Map.put(:state, state)
      |> Map.put(
        :desired_size,
        if(state in [:closed, :errored], do: nil, else: internal_desired_size(data))
      )

    {:keep_state_and_data, [{:reply, from, slots}]}
  end

  defp handle_common(:cast, {:error, reason}, state, data) do
    if state in [:closed, :errored] do
      :keep_state_and_data
    else
      fail_stream(reason, data)
    end
  end

  defp handle_common(:info, {ref, result}, state, data) do
    if ref == data.task_ref do
      case data.active_operation do
        :abort ->
          handle_abort_task_result(result, data)

        _ ->
          handle_task_result(result, state, data)
      end
    else
      :keep_state_and_data
    end
  end

  defp handle_common(:info, {:DOWN, ref, :process, _pid, reason}, _state, data) do
    cond do
      ref == data.writer_ref ->
        {:keep_state, %{data | writer_pid: nil, writer_ref: nil}}

      ref == data.task_ref and data.active_operation == :abort ->
        {:keep_state, clear_active_operation(data)}

      ref == data.task_ref and reason == :normal ->
        :keep_state_and_data

      ref == data.task_ref ->
        fail_stream(reason, data)

      true ->
        :keep_state_and_data
    end
  end

  defp handle_common(_type, _content, _state, _data), do: :not_handled

  defp handle_write(from, pid, chunk, _state, data) do
    cond do
      pid != data.writer_pid ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}

      active_operation?(data) ->
        new_data =
          data
          |> enqueue_write_request({from, pid, chunk})
          |> refresh_backpressure()

        {:keep_state, new_data}

      true ->
        data
        |> start_write_request({from, pid, chunk})
        |> reply_keep_state(:writable)
    end
  end

  defp handle_close(from, pid, _state, data) do
    cond do
      pid != data.writer_pid ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}

      data.pending_close_request ->
        {:keep_state_and_data, [{:reply, from, {:error, :closing}}]}

      active_operation?(data) or not :queue.is_empty(data.queued_write_requests) ->
        {:next_state, :closing, %{data | pending_close_request: from}}

      true ->
        data
        |> Map.put(:pending_close_request, from)
        |> start_close_operation()
    end
  end

  defp handle_abort(from, pid, reason, data) do
    if pid != data.writer_pid do
      {:keep_state_and_data, [{:reply, from, {:error, :not_locked_by_writer}}]}
    else
      data
      |> start_abort_operation(reason)
      |> then(&fail_stream(reason, &1, [{:reply, from, :ok}]))
    end
  end

  defp maybe_start_sink(%Data{underlying_sink: %{start: start}} = data)
       when is_function(start, 1) do
    stream_pid = self()
    task = start_sink_task(fn -> start.(%WritableStreamDefaultController{pid: stream_pid}) end)
    %{data | active_task: task, task_ref: task.ref, active_operation: :start}
  end

  defp maybe_start_sink(data), do: data

  defp start_write_request(data, request) do
    {from, _pid, chunk} = request
    stream_pid = self()

    task =
      start_sink_task(fn ->
        invoke_sink_callback(data.underlying_sink, :write, [
          chunk,
          %WritableStreamDefaultController{pid: stream_pid}
        ])
      end)

    data
    |> Map.put(:pending_write_request, request)
    |> Map.put(:active_task, task)
    |> Map.put(:task_ref, task.ref)
    |> Map.put(:active_operation, {:write, from})
    |> refresh_backpressure()
  end

  defp start_close_operation(data) do
    stream_pid = self()

    task =
      start_sink_task(fn ->
        invoke_sink_callback(data.underlying_sink, :close, [
          %WritableStreamDefaultController{pid: stream_pid}
        ])
      end)

    {:next_state, :closing,
     %{
       data
       | active_task: task,
         task_ref: task.ref,
         active_operation: {:close, data.pending_close_request}
     }}
  end

  defp start_abort_operation(data, reason) do
    task =
      start_sink_task(fn ->
        invoke_abort(data, reason)
      end)

    %{
      data
      | active_task: task,
        task_ref: task.ref,
        active_operation: :abort
    }
  end

  defp handle_task_result({:error, reason}, _state, data) do
    fail_stream(reason, data)
  end

  defp handle_task_result(_result, state, %{active_operation: :start} = data) do
    data
    |> clear_active_operation()
    |> continue_after_completion(state, [])
  end

  defp handle_task_result(_result, state, %{active_operation: {:write, from}} = data) do
    data
    |> clear_active_operation()
    |> Map.put(:pending_write_request, nil)
    |> refresh_backpressure()
    |> continue_after_completion(state, [{:reply, from, :ok}])
  end

  defp handle_task_result(_result, _state, %{active_operation: {:close, from}} = data) do
    data
    |> clear_active_operation()
    |> Map.put(:pending_close_request, nil)
    |> close_stream([{:reply, from, :ok}])
  end

  defp handle_abort_task_result(_result, data) do
    {:keep_state, clear_active_operation(data)}
  end

  defp continue_after_completion(data, state, actions) do
    cond do
      not :queue.is_empty(data.queued_write_requests) ->
        {{:value, request}, remaining} = :queue.out(data.queued_write_requests)

        new_data =
          data
          |> Map.put(:queued_write_requests, remaining)
          |> start_write_request(request)

        {:keep_state, new_data, actions}

      state == :closing and data.pending_close_request ->
        case start_close_operation(data) do
          {:next_state, :closing, new_data} ->
            {:next_state, :closing, new_data, actions}
        end

      true ->
        {new_data, ready_actions} = maybe_resolve_ready_requests(data)
        {:keep_state, new_data, actions ++ ready_actions}
    end
  end

  defp close_stream(data, actions) do
    {new_data, ready_actions} =
      data
      |> Map.put(:backpressure, false)
      |> maybe_resolve_ready_requests(force?: true)

    {:next_state, :closed, new_data, actions ++ ready_actions}
  end

  defp fail_stream(reason, data, actions \\ []) do
    cond do
      data.active_operation == :abort ->
        :ok

      is_nil(data.active_task) ->
        :ok

      true ->
        Task.shutdown(data.active_task, :brutal_kill)
    end

    error_actions =
      pending_write_error_actions(data, reason) ++
        queued_write_error_actions(data, reason) ++
        close_error_actions(data, reason) ++
        ready_error_actions(data, reason)

    new_data =
      data
      |> preserve_abort_task()
      |> clear_writer_lock()

    new_data =
      new_data
      |> Map.put(:pending_write_request, nil)
      |> Map.put(:queued_write_requests, :queue.new())
      |> Map.put(:pending_close_request, nil)
      |> Map.put(:ready_requests, :queue.new())
      |> Map.put(:backpressure, false)
      |> Map.put(:error_reason, reason)

    {:next_state, :errored, new_data, actions ++ error_actions}
  end

  defp clear_writer_lock(%{writer_ref: writer_ref} = data) do
    if writer_ref, do: Process.demonitor(writer_ref, [:flush])
    %{data | writer_pid: nil, writer_ref: nil}
  end

  defp pending_write_error_actions(%{pending_write_request: {from, _pid, _chunk}}, reason) do
    [{:reply, from, {:error, {:errored, reason}}}]
  end

  defp pending_write_error_actions(_data, _reason), do: []

  defp queued_write_error_actions(data, reason) do
    data.queued_write_requests
    |> :queue.to_list()
    |> Enum.map(fn {from, _pid, _chunk} -> {:reply, from, {:error, {:errored, reason}}} end)
  end

  defp close_error_actions(%{pending_close_request: from}, reason) when not is_nil(from) do
    [{:reply, from, {:error, {:errored, reason}}}]
  end

  defp close_error_actions(_data, _reason), do: []

  defp ready_error_actions(data, reason) do
    data.ready_requests
    |> :queue.to_list()
    |> Enum.map(fn from -> {:reply, from, {:error, {:errored, reason}}} end)
  end

  defp maybe_resolve_ready_requests(data, opts \\ []) do
    force? = Keyword.get(opts, :force?, false)

    if force? or not data.backpressure do
      actions =
        data.ready_requests
        |> :queue.to_list()
        |> Enum.map(fn from -> {:reply, from, :ok} end)

      {%{data | ready_requests: :queue.new()}, actions}
    else
      {data, []}
    end
  end

  defp refresh_backpressure(data) do
    %{data | backpressure: internal_desired_size(data) <= 0}
  end

  defp internal_desired_size(data) do
    data.high_water_mark - pending_write_count(data)
  end

  defp pending_write_count(data) do
    :queue.len(data.queued_write_requests) + if(data.pending_write_request, do: 1, else: 0)
  end

  defp enqueue_write_request(data, request) do
    %{data | queued_write_requests: :queue.in(request, data.queued_write_requests)}
  end

  defp active_operation?(data) do
    not is_nil(data.active_task) or not is_nil(data.pending_write_request)
  end

  defp clear_active_operation(data) do
    %{data | active_task: nil, task_ref: nil, active_operation: nil}
  end

  defp preserve_abort_task(%{active_operation: :abort} = data), do: data
  defp preserve_abort_task(data), do: clear_active_operation(data)

  defp invoke_abort(%{underlying_sink: %{abort: abort}}, reason) when is_function(abort, 1) do
    try do
      abort.(reason)
      :ok
    rescue
      error -> {:error, error}
    catch
      kind, abort_reason -> {:error, {kind, abort_reason}}
    end
  end

  defp invoke_abort(_data, _reason), do: :ok

  defp invoke_sink_callback(underlying_sink, name, args) do
    case Map.get(underlying_sink, name) do
      fun when is_function(fun, length(args)) ->
        apply(fun, args)

      _ ->
        :ok
    end
  end

  defp start_sink_task(fun) do
    Task.Supervisor.async_nolink(Web.TaskSupervisor, fn ->
      try do
        fun.()
      rescue
        error -> {:error, error}
      catch
        kind, reason -> {:error, {kind, reason}}
      end
    end)
  end

  defp reply_keep_state(data, state) do
    {:keep_state, data, []}
    |> normalize_reply_keep_state(state)
  end

  defp normalize_reply_keep_state({:keep_state, data, actions}, _state),
    do: {:keep_state, data, actions}
end
