defmodule Web.Promise.AggregateError do
  defexception [:errors]

  @impl true
  def message(%{errors: errors}) do
    "All promises were rejected: #{inspect(errors)}"
  end
end

defmodule Web.Promise do
  @moduledoc """
  A minimalist WHATWG-style promise backed by a supervised task.

  Promises are one-shot and follow standard Elixir `Task` semantics: once awaited,
  their result message is consumed.
  """

  defstruct [:task]

  @type t :: %__MODULE__{task: Task.t()}

  @spec new(((... -> no_return()), (... -> no_return()) -> any())) :: t()
  def new(executor) when is_function(executor, 2) do
    %__MODULE__{
      task:
        Task.Supervisor.async_nolink(Web.TaskSupervisor, fn ->
          run_executor(executor)
        end)
    }
  end

  @spec resolve(t() | Task.t() | any()) :: t()
  def resolve(%__MODULE__{} = promise), do: promise
  def resolve(%Task{} = task), do: %__MODULE__{task: task}

  def resolve(value) do
    %__MODULE__{task: Task.completed(value)}
  end

  @spec reject(any()) :: t()
  def reject(reason) do
    new(fn _resolve, reject -> reject.(reason) end)
  end

  @spec then(t() | Task.t() | any(), (any() -> any())) :: t()
  def then(promise, on_fulfilled) when is_function(on_fulfilled, 1) do
    %__MODULE__{task: original_task} = __MODULE__.resolve(promise)

    try do
      value = Task.await(original_task, :infinity)

      case on_fulfilled.(value) do
        %__MODULE__{} = chained -> chained
        new_value -> resolve(new_value)
      end
    catch
      :exit, reason -> reject(normalize_await_exit_reason(reason))
    end
  end

  @spec unquote(:catch)(t() | Task.t() | any(), (any() -> any())) :: t()
  def unquote(:catch)(promise, on_rejected) when is_function(on_rejected, 1) do
    %__MODULE__{task: original_task} = __MODULE__.resolve(promise)

    try do
      value = Task.await(original_task, :infinity)
      resolve(value)
    catch
      :exit, reason ->
        case on_rejected.(normalize_await_exit_reason(reason)) do
          %__MODULE__{} = chained -> chained
          new_value -> resolve(new_value)
        end
    end
  end

  defp normalize_await_exit_reason({{:shutdown, reason}, {Task, :await, _details}}), do: reason
  # coveralls-ignore-next-line
  defp normalize_await_exit_reason({:shutdown, reason}), do: reason
  # coveralls-ignore-next-line
  defp normalize_await_exit_reason(reason), do: reason

  @spec all(Enumerable.t()) :: t()
  def all(enumerable) do
    tasks =
      enumerable
      |> Enum.map(&__MODULE__.resolve/1)
      |> Enum.map(fn %__MODULE__{task: task} -> task end)

    results =
      tasks
      |> Task.yield_many(:infinity)
      |> Enum.reduce_while([], fn {_task, result}, acc ->
        case result do
          {:ok, value} -> {:cont, [value | acc]}
          {:exit, {:shutdown, reason}} -> {:halt, {:error, reason}}
          # coveralls-ignore-next-line
          {:exit, reason} -> {:halt, {:error, reason}}
        end
      end)

    case results do
      {:error, reason} -> reject(reason)
      list -> resolve(Enum.reverse(list))
    end
  end

  @spec allSettled(Enumerable.t()) :: t()
  def allSettled(enumerable) do
    tasks =
      enumerable
      |> Enum.map(&__MODULE__.resolve/1)
      |> Enum.map(fn %__MODULE__{task: task} -> task end)

    results =
      tasks
      |> Task.yield_many(:infinity)
      |> Enum.map(fn {_task, result} ->
        case result do
          {:ok, {:error, reason}} -> %{status: "rejected", reason: reason}
          {:ok, value} -> %{status: "fulfilled", value: value}
          {:exit, {:shutdown, reason}} -> %{status: "rejected", reason: reason}
          # coveralls-ignore-next-line
          {:exit, reason} -> %{status: "rejected", reason: reason}
        end
      end)

    resolve(results)
  end

  @spec any(Enumerable.t()) :: t()
  def any(enumerable) do
    new(fn resolve, reject ->
      tasks =
        enumerable
        |> Enum.map(&__MODULE__.resolve/1)
        |> Enum.map(fn %__MODULE__{task: task} -> task end)

      if Enum.empty?(tasks) do
        reject.(%Web.Promise.AggregateError{errors: []})
      else
        case do_any(tasks, []) do
          {:ok, value} -> resolve.(value)
          {:error, errors} -> reject.(%Web.Promise.AggregateError{errors: errors})
        end
      end
    end)
  end

  @spec race(Enumerable.t()) :: t()
  def race(enumerable) do
    new(fn resolve, reject ->
      tasks =
        enumerable
        |> Enum.map(&__MODULE__.resolve/1)
        |> Enum.map(fn %__MODULE__{task: task} -> task end)

      if Enum.empty?(tasks) do
        # JS Promise.race([]) hangs forever in a pending state
        # coveralls-ignore-next-line
        Process.sleep(:infinity)
      else
        case do_race(tasks) do
          {:ok, value} -> resolve.(value)
          {:error, reason} -> reject.(reason)
        end
      end
    end)
  end

  defp run_executor(executor) do
    # Using messages is the most "actor-model" way to capture results.
    parent = self()

    resolve = fn
      %__MODULE__{task: inner_task} ->
        # [JS Alignment]: Handle nested promises in resolve.
        # We wait for the inner promise to settle and adopt its state.
        try do
          value = Task.await(inner_task, :infinity)
          send(parent, {:promise_settled, {:ok, value}})
        catch
          # coveralls-ignore-next-line
          :exit, {:shutdown, reason} -> send(parent, {:promise_settled, {:error, reason}})
          :exit, reason -> send(parent, {:promise_settled, {:error, reason}})
        end

      value ->
        send(parent, {:promise_settled, {:ok, value}})
    end

    reject = fn reason -> send(parent, {:promise_settled, {:error, reason}}) end

    try do
      executor.(resolve, reject)
    catch
      _, reason -> send(parent, {:promise_settled, {:error, reason}})
    end

    # Wait for either resolve or reject to be called, and return or exit accordingly
    receive do
      {:promise_settled, {:ok, value}} ->
        value

      {:promise_settled, {:error, reason}} ->
        # Exit with :shutdown so Erlang does not report this as a crash in the logs
        exit({:shutdown, reason})
    after
      0 -> nil
    end
  end

  # --- Simplified Async Event Loops for Any / Race ---

  defp do_any([], errors), do: {:error, Enum.reverse(errors)}

  defp do_any(tasks, errors) do
    # Poll tasks quietly without throwing exceptions on rejection
    {settled, pending} =
      Task.yield_many(tasks, 50)
      |> Enum.split_with(fn {_task, result} -> result != nil end)

    pending_tasks = Enum.map(pending, fn {t, _} -> t end)

    # Check if ANY task succeeded
    case Enum.find(settled, fn
           {_t, {:ok, {:error, _reason}}} -> false
           {_t, {:ok, _value}} -> true
           # coveralls-ignore-next-line
           _ -> false
         end) do
      {_task, {:ok, value}} ->
        shutdown_tasks(pending_tasks)
        {:ok, value}

      nil ->
        # Collect errors and continue waiting for pending tasks
        new_errors =
          Enum.map(settled, fn
            # coveralls-ignore-next-line
            {_t, {:exit, {:shutdown, reason}}} -> reason
            # coveralls-ignore-next-line
            {_t, {:exit, reason}} -> reason
            {_t, {:ok, {:error, reason}}} -> reason
          end)

        do_any(pending_tasks, errors ++ new_errors)
    end
  end

  defp do_race(tasks) do
    {settled, pending} =
      Task.yield_many(tasks, 50)
      |> Enum.split_with(fn {_task, result} -> result != nil end)

    pending_tasks = Enum.map(pending, fn {t, _} -> t end)

    if Enum.empty?(settled) do
      # coveralls-ignore-next-line
      do_race(pending_tasks)
    else
      shutdown_tasks(pending_tasks)

      [{_task, result} | _] = settled

      case result do
        {:ok, {:error, reason}} -> {:error, reason}
        {:ok, value} -> {:ok, value}
        # coveralls-ignore-next-line
        {:exit, {:shutdown, reason}} -> {:error, reason}
        # coveralls-ignore-next-line
        {:exit, reason} -> {:error, reason}
      end
    end
  end

  defp shutdown_tasks(tasks) do
    Enum.each(tasks, fn task -> Task.shutdown(task, :brutal_kill) end)
  end
end

defimpl Inspect, for: Web.Promise do
  import Inspect.Algebra

  def inspect(%Web.Promise{task: task}, opts) do
    cond do
      is_pid(task.pid) and Process.alive?(task.pid) ->
        "#Web.Promise<pending>"

      true ->
        inspect_completed_from_mailbox(task, opts)
    end
  end

  defp inspect_completed_from_mailbox(task, opts) do
    case find_task_message(task) do
      {:ok, {:error, reason}} ->
        concat(["#Web.Promise<rejected: ", to_doc(reason, opts), ">"])

      {:ok, {:ok, value}} ->
        concat(["#Web.Promise<resolved: ", to_doc(value, opts), ">"])

      {:ok, value} ->
        concat(["#Web.Promise<resolved: ", to_doc(value, opts), ">"])

      {:down, reason} ->
        concat(["#Web.Promise<rejected: ", to_doc(reason, opts), ">"])

      :not_found ->
        "#Web.Promise<pending>"
    end
  end

  defp find_task_message(task) do
    case Process.info(self(), :messages) do
      {:messages, messages} ->
        Enum.find_value(messages, :not_found, fn
          {ref, result} when ref == task.ref ->
            {:ok, result}

          # Handle our customized :shutdown exits gracefully
          {:DOWN, ref, :process, _pid, {:shutdown, reason}} when ref == task.ref ->
            {:down, reason}

          {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
            {:down, reason}

          _other ->
            false
        end)

      # coveralls-ignore-next-line
      _ ->
        # coveralls-ignore-next-line
        :not_found
    end
  end
end
