defmodule Web.ReadableStream do
  @moduledoc """
  An Elixir implementation of the WHATWG ReadableStream standard.

  Provides a way to represent a stream of data that can be consumed or multicasted (teed).
  The implementation follows the Web API concepts, including:

  - **Backpressure**: The stream respects the consumption speed of its readers.
  - **Locking**: A stream can be locked to a single reader using `get_reader/1`.
  - **Teeing**: A stream can be split into two branches via `tee/1`.

  ## Technical Implementation Notes

  ### [[disturbed]] slot
  In the WHATWG spec, a stream is "disturbed" once data has been requested from it or it
  has been cancelled. In this implementation, the `[[disturbed]]` state prevents certain
  operations like `tee/1` if the stream has already been interacted with.

  ### Teeing and Backpressure
  The `tee/1` implementation uses a "multicast" strategy. The original stream's backpressure
  signal (the `desired_size`) is calculated as `max(branch_a.desired_size, branch_b.desired_size)`.
  This ensures that the source continues to pull data as long as at least one branch has capacity.

  ### Buffer Bloat Warning
  When using `tee/1`, be aware that a significantly slower consumer on one branch will NOT
  stop the other branch from receiving data. This can lead to "Buffer Bloat" (unbounded memory usage)
  on the slower branch's internal queue. If consumers have vastly different speeds, consider
  implementing custom branch-level backpressure or using a different distribution strategy.
  """
  @behaviour :gen_statem

  defstruct [:controller_pid]

  alias Web.ReadableStreamDefaultReader
  alias Web.TypeError

  defmodule Data do
    defstruct [
      :reader_pid,
      :reader_ref,
      :source,
      disturbed: false,
      queue: :queue.new(),
      hwm: 1,
      read_requests: :queue.new(),
      error_reason: nil,
      pulling: false,
      task_ref: nil,
      active_task: nil,
      branches: [],
      branch_desired_sizes: %{}
    ]
  end

  def start_link(opts \\ []) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  @doc """
  Creates a new ReadableStream with the given underlying source.

  ## Examples

      iex> source = %{
      ...>   start: fn controller ->
      ...>     Web.ReadableStreamDefaultController.enqueue(controller, "hello")
      ...>     Web.ReadableStreamDefaultController.close(controller)
      ...>   end
      ...> }
      iex> stream = Web.ReadableStream.new(source)
      iex> Enum.to_list(stream)
      ["hello"]
  """
  def new(underlying_source \\ %{}) do
    {:ok, pid} = start_link(source: underlying_source)
    %__MODULE__{controller_pid: pid}
  end

  @doc """
  Locks the stream and returns a reader.

  ## Examples

      iex> stream = Web.ReadableStream.new()
      iex> reader = Web.ReadableStream.get_reader(stream)
      iex> is_struct(reader, Web.ReadableStreamDefaultReader)
      true
  """
  def get_reader(pid) when is_pid(pid) do
    case :gen_statem.call(pid, {:get_reader, self()}) do
      {:ok, _ref} -> :ok
      {:error, :already_locked} -> {:error, :already_locked}
    end
  end

  def get_reader(%__MODULE__{controller_pid: pid}) do
    case get_reader(pid) do
      :ok ->
        %Web.ReadableStreamDefaultReader{controller_pid: pid}

      {:error, :already_locked} ->
        raise TypeError, "ReadableStream is already locked"
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

  def tee(pid) when is_pid(pid) do
    :gen_statem.call(pid, :tee)
  end

  @doc """
  Tees the current readable stream, returning two new readable stream branches.

  ## Examples

      iex> stream = Web.ReadableStream.new(%{
      ...>   start: fn c ->
      ...>     Web.ReadableStreamDefaultController.enqueue(c, "a")
      ...>     Web.ReadableStreamDefaultController.close(c)
      ...>   end
      ...> })
      iex> {s1, s2} = Web.ReadableStream.tee(stream)
      iex> Enum.to_list(s1)
      ["a"]
      iex> Enum.to_list(s2)
      ["a"]
  """
  def tee(%__MODULE__{controller_pid: pid}) do
    case tee(pid) do
      {:ok, {s1, s2}} ->
        {s1, s2}

      {:error, :already_locked} ->
        raise TypeError, "ReadableStream is already locked"
    end
  end

  def branch_cancelled(pid, child_pid) do
    :gen_statem.cast(pid, {:branch_cancelled, child_pid})
  end

  def report_desired_size(pid, child_pid, size) do
    :gen_statem.cast(pid, {:branch_desired_size, child_pid, size})
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
    source = Keyword.get(opts, :source)

    data = %Data{
      hwm: Keyword.get(opts, :high_water_mark, 1),
      source: source
    }

    actions =
      if is_map(source) and is_function(source[:start], 1) do
        ref = start_async_task(source.start, self())
        [{:next_event, :internal, {:task_started, ref}}]
      else
        [{:next_event, :internal, :maybe_pull}]
      end

    {:ok, :readable, data, actions}
  end

  def readable(type, content, data) do
    case handle_common(type, content, :readable, data) do
      :not_handled ->
        case {type, content} do
          {:cast, {:enqueue, chunk}} ->
            Enum.each(data.branches, &enqueue(&1, chunk))

            new_data = %{data | queue: :queue.in(chunk, data.queue), disturbed: true}

            case :queue.out(new_data.read_requests) do
              {{:value, from}, new_requests} ->
                {{:value, c}, new_queue} = :queue.out(new_data.queue)
                new_data = %{new_data | read_requests: new_requests, queue: new_queue}
                :gen_statem.reply(from, {:ok, c})
                {:keep_state, new_data, [{:next_event, :internal, :maybe_pull}]}

              {:empty, _} ->
                {:keep_state, new_data}
            end

          {:cast, :close} ->
            Enum.each(data.branches, &close/1)

            {:next_state, :closed, %{data | pulling: false},
             [{:next_event, :internal, :flush_requests}]}

          {:cast, {:error, reason}} ->
            if data.active_task, do: Task.shutdown(data.active_task, :brutal_kill)
            Enum.each(data.branches, &error(&1, reason))

            {:next_state, :errored,
             %{data | error_reason: reason, active_task: nil, task_ref: nil, pulling: false},
             [{:next_event, :internal, :flush_requests}]}

          {:internal, {:task_started, task}} ->
            {:keep_state, %{data | pulling: true, task_ref: task.ref, active_task: task}}

          {:internal, :maybe_pull} ->
            effective_ds = get_effective_desired_size(data)

            if not data.pulling and effective_ds > 0 do
              task = signal_source_pull(data)

              if task do
                {:keep_state, %{data | pulling: true, task_ref: task.ref, active_task: task}}
              else
                :keep_state_and_data
              end
            else
              :keep_state_and_data
            end

          _ ->
            {:keep_state_and_data, [:postpone]}
        end

      result ->
        result
    end
  end

  def closed(type, content, data) do
    case handle_common(type, content, :closed, data) do
      :not_handled ->
        case {type, content} do
          {:cast, {:enqueue, _chunk}} ->
            :keep_state_and_data

          {:internal, :flush_requests} ->
            if :queue.is_empty(data.queue) do
              data.read_requests
              |> :queue.to_list()
              |> Enum.each(&:gen_statem.reply(&1, :done))

              {:keep_state, %{data | read_requests: :queue.new()}}
            else
              :keep_state_and_data
            end

          _ ->
            {:keep_state_and_data, [:postpone]}
        end

      result ->
        result
    end
  end

  def errored(type, content, data) do
    case handle_common(type, content, :errored, data) do
      :not_handled ->
        case {type, content} do
          {:internal, :flush_requests} ->
            data.read_requests
            |> :queue.to_list()
            |> Enum.each(&:gen_statem.reply(&1, {:error, {:errored, data.error_reason}}))

            {:keep_state, %{data | read_requests: :queue.new()}}

          _ ->
            {:keep_state_and_data, [:postpone]}
        end

      result ->
        result
    end
  end

  defp handle_common(
         {:call, from},
         {:get_reader, pid},
         _state,
         %{reader_pid: nil, branches: []} = data
       ) do
    ref = Process.monitor(pid)
    {:keep_state, %{data | reader_pid: pid, reader_ref: ref}, [{:reply, from, {:ok, ref}}]}
  end

  defp handle_common({:call, from}, {:get_reader, _pid}, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_locked}}]}
  end

  defp handle_common(
         {:call, from},
         {:read, _pid},
         _state,
         %{error_reason: :force_unexpected_read} = data
       ) do
    {:keep_state, %{data | error_reason: nil}, [{:reply, from, {:error, :unexpected}}]}
  end

  defp handle_common(
         {:call, from},
         {:read, _pid},
         _state,
         %{error_reason: :force_error_no_reason} = data
       ) do
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
            actions = [{:reply, from, {:ok, chunk}}]

            actions =
              if :queue.len(new_queue) < data.hwm,
                do: [{:next_event, :internal, :maybe_pull} | actions],
                else: actions

            {:keep_state, new_data, actions}
          else
            if state == :closed do
              {:keep_state, data, [{:reply, from, :done}]}
            else
              new_requests = :queue.in(from, data.read_requests)

              {:keep_state, %{data | read_requests: new_requests},
               [{:next_event, :internal, :maybe_pull}]}
            end
          end
      end
    end
  end

  defp handle_common(
         {:call, from},
         {:release_lock, _pid},
         _state,
         %{error_reason: :force_unexpected_release} = data
       ) do
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
    size = get_effective_desired_size(data)
    {:keep_state_and_data, [{:reply, from, size}]}
  end

  defp handle_common({:call, from}, :tee, state, %{reader_pid: nil, branches: []} = data) do
    parent_pid = self()

    create_branch = fn ->
      child_source = %{
        pull: fn controller ->
          child_pid = controller.pid
          ds = Web.ReadableStreamDefaultController.desired_size(controller)
          report_desired_size(parent_pid, child_pid, ds)
        end,
        cancel: fn _reason ->
          branch_cancelled(parent_pid, self())
        end
      }

      new(child_source)
    end

    stream_a = create_branch.()
    stream_b = create_branch.()

    new_branches = [stream_a.controller_pid, stream_b.controller_pid]

    for chunk <- :queue.to_list(data.queue) do
      Enum.each(new_branches, &enqueue(&1, chunk))
    end

    case state do
      :closed -> Enum.each(new_branches, &close/1)
      :errored -> Enum.each(new_branches, &error(&1, data.error_reason))
      _ -> :ok
    end

    new_data = %{
      data
      | branches: new_branches,
        disturbed: true,
        reader_pid: :teed,
        queue: :queue.new(),
        branch_desired_sizes: %{stream_a.controller_pid => 1, stream_b.controller_pid => 1}
    }

    {:keep_state, new_data, [{:reply, from, {:ok, {stream_a, stream_b}}}]}
  end

  defp handle_common({:call, from}, :tee, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_locked}}]}
  end

  defp handle_common({:call, from}, :get_slots, state, data) do
    res = data |> Map.from_struct() |> Map.put(:state, state)
    {:keep_state_and_data, [{:reply, from, res}]}
  end

  defp handle_common(:info, {ref, result}, _state, data) do
    if ref == data.task_ref do
      case result do
        {:error, reason} ->
          {:next_state, :errored, %{data | error_reason: reason, task_ref: nil, pulling: false},
           [{:next_event, :internal, :flush_requests}]}

        _ ->
          {:keep_state, %{data | task_ref: nil, active_task: nil, pulling: false},
           [{:next_event, :internal, :maybe_pull}]}
      end
    else
      :keep_state_and_data
    end
  end

  defp handle_common(:info, {:DOWN, ref, :process, _pid, reason}, _state, data) do
    cond do
      ref == data.reader_ref ->
        {:keep_state, %{data | reader_pid: nil, reader_ref: nil}}

      ref == data.task_ref ->
        if reason == :normal do
          {:keep_state, %{data | task_ref: nil, active_task: nil, pulling: false},
           [{:next_event, :internal, :maybe_pull}]}
        else
          {:next_state, :errored,
           %{data | error_reason: reason, task_ref: nil, active_task: nil, pulling: false},
           [{:next_event, :internal, :flush_requests}]}
        end

      true ->
        :keep_state_and_data
    end
  end

  defp handle_common(:cast, {:branch_cancelled, pid}, _state, data) do
    new_branches = List.delete(data.branches, pid)
    new_sizes = Map.delete(data.branch_desired_sizes, pid)

    if new_branches == [] and data.branches != [] do
      signal_source_cancel(data, :all_branches_cancelled)

      {:next_state, :closed, %{data | branches: [], branch_desired_sizes: %{}, pulling: false},
       [{:next_event, :internal, :flush_requests}]}
    else
      {:keep_state, %{data | branches: new_branches, branch_desired_sizes: new_sizes}}
    end
  end

  defp handle_common(:cast, {:cancel, reason}, _state, data) do
    if data.active_task, do: Task.shutdown(data.active_task, :brutal_kill)
    Enum.each(data.branches, &cancel(&1, reason))
    signal_source_cancel(data, reason)

    new_data = %{
      data
      | disturbed: true,
        queue: :queue.new(),
        pulling: false,
        active_task: nil,
        task_ref: nil,
        branches: []
    }

    {:next_state, :closed, new_data, [{:next_event, :internal, :flush_requests}]}
  end

  defp handle_common(:cast, {:branch_desired_size, pid, size}, _state, data) do
    new_sizes = Map.put(data.branch_desired_sizes, pid, size)

    {:keep_state, %{data | branch_desired_sizes: new_sizes},
     [{:next_event, :internal, :maybe_pull}]}
  end

  defp handle_common({:call, from}, :force_unknown_error, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :unexpected}}]}
  end

  defp handle_common(_type, _content, _state, _data), do: :not_handled

  defp start_async_task(fun, pid) do
    Task.Supervisor.async_nolink(Web.TaskSupervisor, fn ->
      try do
        fun.(%Web.ReadableStreamDefaultController{pid: pid})
        :ok
      rescue
        e -> {:error, e}
      catch
        kind, reason -> {:error, {kind, reason}}
      end
    end)
  end

  defp signal_source_pull(%{source: %{pull: pull}, pulling: false}) when is_function(pull, 1) do
    start_async_task(pull, self())
  end

  defp signal_source_pull(%{source: nil}), do: nil

  defp signal_source_pull(%{source: pid, pulling: false}) when is_pid(pid) do
    send(pid, {:pull, self()})
    nil
  end

  defp signal_source_pull(%{source: {m, f, a}, pulling: false}) do
    start_async_task(fn controller -> apply(m, f, a ++ [controller]) end, self())
  end

  defp signal_source_pull(%{source: fun, pulling: false}) when is_function(fun, 1) do
    start_async_task(fun, self())
  end

  defp signal_source_pull(_), do: nil

  defp signal_source_cancel(%{source: %{cancel: cancel}}, reason) when is_function(cancel, 1) do
    cancel.(reason)
  end

  defp signal_source_cancel(%{source: source}, _reason) when is_map(source), do: :ok
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

  defp get_effective_desired_size(data) do
    if data.branches == [] do
      data.hwm - :queue.len(data.queue)
    else
      case Map.values(data.branch_desired_sizes) do
        [] -> 0
        vals -> Enum.max(vals)
      end
    end
  end
end

defimpl Enumerable, for: Web.ReadableStream do
  alias Web.ReadableStreamDefaultReader

  def reduce(stream, acc, fun) do
    reader = Web.ReadableStream.get_reader(stream)
    do_reduce(reader, acc, fun)
  end

  defp do_reduce(reader, {:halt, acc}, _fun) do
    try do
      ReadableStreamDefaultReader.release_lock(reader)
    rescue
      _ -> :ok
    end

    {:halted, acc}
  end

  defp do_reduce(reader, {:suspend, acc}, fun) do
    {:suspended, acc, &do_reduce(reader, &1, fun)}
  end

  defp do_reduce(reader, {:cont, acc}, fun) do
    case ReadableStreamDefaultReader.read(reader) do
      :done ->
        try do
          ReadableStreamDefaultReader.release_lock(reader)
        rescue
          _ -> :ok
        end

        {:done, acc}

      chunk ->
        try do
          do_reduce(reader, fun.(chunk, acc), fun)
        rescue
          e ->
            try do
              ReadableStreamDefaultReader.release_lock(reader)
            rescue
              _ -> :ok
            end

            reraise e, __STACKTRACE__
        end
    end
  end

  def count(_stream), do: {:error, __MODULE__}
  def member?(_stream, _element), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}
end
