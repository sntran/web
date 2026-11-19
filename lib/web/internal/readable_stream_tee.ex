defmodule Web.Internal.ReadableStreamTee do
  @moduledoc false

  # The algorithm ReadableStreamDefaultTee of the Streams Standard.
  #
  # One process holds the reader lock of the source and keeps the state of
  # the algorithm. The two branches are usual readable streams. Their `pull`
  # and `cancel` callbacks send a message to this process and do not wait.
  #
  #   * A pull from one of the two branches starts one read from the source,
  #     if no read is in progress. The chunk of that read goes to the two
  #     branches. Thus a branch that no process reads keeps each chunk in its
  #     queue, and does not slow down the other branch.
  #   * When the source ends, the two branches close. When the source has an
  #     error, the two branches get that error immediately, and the chunks
  #     in their queues are discarded.
  #   * A cancel of one branch has no effect on the source. When the two
  #     branches are cancelled, the source is cancelled with the list of the
  #     two reasons. The promise of a cancel settles when the cancel of the
  #     source is complete, or when the source ends.
  #
  # A branch that stops is a cancelled branch.
  #
  # The process keeps the reader lock until the source stops, because the
  # Streams Standard never releases the lock of a stream that has a tee.
  # Then the process stops.

  use GenServer

  alias Web.ReadableStream

  @type index :: 1 | 2

  # Starts the process and takes the reader lock of the source.
  @spec start(pid()) :: {:ok, pid()} | {:error, :already_locked | :released}
  def start(source) when is_pid(source) do
    case GenServer.start(__MODULE__, {source, self()}) do
      {:ok, tee} -> {:ok, tee}
      {:error, {:shutdown, reason}} -> {:error, reason}
    end
  end

  # Gives the two branches to the process. The process does no read before
  # this call.
  @spec attach(pid(), pid(), pid()) :: :ok
  def attach(tee, branch1, branch2), do: GenServer.call(tee, {:attach, branch1, branch2})

  @spec pull(pid()) :: :ok
  def pull(tee), do: GenServer.cast(tee, :pull)

  # Records the cancel of a branch, and returns the promise of the Streams
  # Standard: it fulfils when the source is cancelled or complete, and it
  # rejects with the value that the cancel callback of the source throws.
  @spec cancel(pid(), index(), term()) :: Web.Promise.t()
  def cancel(tee, index, reason) do
    # The cast keeps the sequence of the cancels, and does not get lost if
    # the process that waits for the promise stops.
    GenServer.cast(tee, {:cancel, index, reason})

    Web.Promise.new(fn resolve, reject ->
      case wait_complete(tee) do
        :ok -> resolve.(:ok)
        {:error, thrown} -> reject.(thrown)
      end
    end)
  end

  defp wait_complete(tee) do
    GenServer.call(tee, :wait_complete, :infinity)
  catch
    # The tee stopped: its work is complete.
    :exit, _reason -> :ok
  end

  @impl true
  def init({source, caller}) do
    case ReadableStream.get_reader(source) do
      :ok ->
        state = %{
          source: source,
          # The process that makes the branches. If it stops before it gives
          # the branches, no process can use this tee.
          caller: Process.monitor(caller),
          branches: nil,
          # The request of the read that is in progress, or `nil`.
          request: nil,
          # The request for the end of the source. Its reply tells the tee
          # about an error of the source when no read is in progress.
          closed_request: :gen_statem.send_request(source, {:wait_closed, :reader, self()}),
          # A branch asked for a chunk before the branches were given.
          pull_wanted?: false,
          # The cancelled branches: index => reason.
          canceled: %{},
          # The error of the source, if it came before the branches.
          early_error: nil,
          # The callers that wait for the end of the work, and its result.
          complete_waiters: [],
          result: :ok,
          # The monitor of the source, after the work of the tee is complete.
          source_monitor: nil
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:shutdown, reason}}
    end
  end

  @impl true
  def handle_call({:attach, branch1, branch2}, _from, state) do
    Process.demonitor(state.caller, [:flush])

    branches = %{
      1 => {branch1, Process.monitor(branch1)},
      2 => {branch2, Process.monitor(branch2)}
    }

    state = %{state | caller: nil, branches: branches}

    cond do
      # The source had an error before the branches came.
      state.early_error -> {:reply, :ok, fail_branches(state.early_error, state)}
      state.pull_wanted? -> {:reply, :ok, start_read(state)}
      true -> {:reply, :ok, state}
    end
  end

  def handle_call(:wait_complete, _from, %{source_monitor: monitor} = state)
      when is_reference(monitor) do
    {:reply, state.result, state}
  end

  def handle_call(:wait_complete, from, state) do
    {:noreply, %{state | complete_waiters: [from | state.complete_waiters]}}
  end

  @impl true
  def handle_cast(_message, %{source_monitor: monitor} = state) when is_reference(monitor) do
    {:noreply, state}
  end

  def handle_cast(:pull, %{branches: nil} = state), do: {:noreply, %{state | pull_wanted?: true}}
  def handle_cast(:pull, %{request: nil} = state), do: {:noreply, start_read(state)}
  # The read that is in progress gives its chunk to the two branches.
  def handle_cast(:pull, state), do: {:noreply, state}

  def handle_cast({:cancel, index, reason}, state), do: cancel_branch(index, reason, state)

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{caller: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{source_monitor: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, %{source_monitor: monitor} = state) when is_reference(monitor) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason} = message, state) do
    case branch_index(state, pid, ref) do
      nil -> handle_response(message, state)
      index -> cancel_branch(index, {:branch_down, reason}, state)
    end
  end

  def handle_info(message, state), do: handle_response(message, state)

  defp branch_index(%{branches: branches}, pid, ref) do
    Enum.find_value(branches || %{}, fn {index, branch} ->
      if branch == {pid, ref}, do: index
    end)
  end

  defp start_read(state) do
    request = :gen_statem.send_request(state.source, {:read, self()})
    %{state | request: request, pull_wanted?: false}
  end

  defp handle_response(message, state) do
    case check_response(message, state.request) do
      {:reply, reply} -> handle_read(reply, %{state | request: nil})
      {:error, {_reason, _server}} -> handle_read({:error, :released}, %{state | request: nil})
      :no_reply -> handle_closed_response(message, state)
    end
  end

  # The source is errored, or it stopped. A source that is closed has no
  # effect here: the read that gets the end closes the branches.
  defp handle_closed_response(message, state) do
    case check_response(message, state.closed_request) do
      {:reply, {:error, {:errored, _reason} = error}} -> handle_read({:error, error}, state)
      {:reply, _closed_or_released} -> {:noreply, %{state | closed_request: nil}}
      {:error, {_reason, _server}} -> handle_read({:error, :released}, state)
      :no_reply -> {:noreply, state}
    end
  end

  defp check_response(_message, nil), do: :no_reply
  defp check_response(message, request), do: :gen_statem.check_response(message, request)

  defp handle_read({:ok, chunk}, state) do
    each_active_branch(state, &ReadableStream.enqueue(&1, chunk))
    {:noreply, state}
  end

  defp handle_read(:done, state) do
    each_active_branch(state, &ReadableStream.close/1)
    {:noreply, complete(state)}
  end

  defp handle_read({:error, reason}, %{branches: nil} = state) do
    {:noreply, %{state | early_error: reason, closed_request: nil}}
  end

  defp handle_read({:error, reason}, state), do: {:noreply, fail_branches(reason, state)}

  defp fail_branches(reason, state) do
    error = stored_error(reason)
    each_active_branch(state, &ReadableStream.error(&1, error))
    complete(state)
  end

  # The work is complete. The process waits for the stop of the source.
  defp complete(state) do
    for {_index, {_pid, monitor}} <- state.branches, do: Process.demonitor(monitor, [:flush])
    for waiter <- state.complete_waiters, do: GenServer.reply(waiter, state.result)

    %{
      state
      | request: nil,
        closed_request: nil,
        complete_waiters: [],
        source_monitor: Process.monitor(state.source)
    }
  end

  defp stored_error({:errored, reason}), do: reason

  defp stored_error(_released_or_not_locked) do
    Web.TypeError.exception("The stream is not available. It ended, or its owner stopped.")
  end

  defp each_active_branch(%{branches: branches, canceled: canceled}, fun) do
    for {index, {pid, _monitor}} <- branches, not is_map_key(canceled, index), do: fun.(pid)
    :ok
  end

  # The first reason of a branch is its reason.
  defp cancel_branch(index, reason, state) do
    canceled = Map.put_new(state.canceled, index, reason)
    state = %{state | canceled: canceled}

    if map_size(canceled) == 2 do
      # The call returns when the cancel callback of the source is complete.
      result = Web.Stream.terminate_and_wait(state.source, :cancel, [canceled[1], canceled[2]])
      {:noreply, complete(%{state | result: result})}
    else
      {:noreply, state}
    end
  end
end
