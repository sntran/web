defmodule Web.Internal.AsyncIteratorConsumer do
  @moduledoc false

  # The methods of `Web.AsyncIterator` that consume an iterator and give a
  # promise: `reduce`, `toArray`, `forEach`, `some`, `every`, and `find`,
  # with the concurrency argument of the proposal for concurrency control.
  # See `tla/AsyncIteratorConsumer.tla`.
  #
  # The method is a process, and that process is also its promise: see
  # `Web.Internal.PromiseCell`. It reads the iterator in jobs. Each job
  # holds a permit (see `Web.Internal.AsyncPermit`): it reads one value,
  # calls the callback with the value and its counter, and gives the
  # permit back at its end. With no concurrency argument, the permit is a
  # count of 1: one job at a time, as the steps of the proposal.
  #
  # The process decides on the results in the sequence of the reads. Thus
  # the result is the result of the steps of the proposal: for example,
  # `find` gives the first value in the sequence that its predicate
  # selects, also when a later value is ready first. `reduce` calls its
  # reducer in the sequence of the values. A job of `reduce` keeps its
  # permit until the reducer has its value: the reads ahead of the reducer
  # are limited.
  #
  # A read that gives the end or an error stops the reads: the reads after
  # it give the same. At the decision, the process reads no more values. A
  # result before the end of the iterator closes the iterator
  # (AsyncIteratorClose), and the promise settles after the close. An error
  # of a callback also closes it. An error of the iterator does not. The
  # jobs that run continue to their end: the process gives their permits
  # back, and then it stops.

  alias Web.AsyncContext.Snapshot
  alias Web.Internal.AsyncIteration
  alias Web.Internal.AsyncPermit
  alias Web.Internal.AsyncStep
  alias Web.Internal.PromiseCell
  alias Web.Promise

  @typedoc false
  @type kind ::
          :to_array
          | {:for_each | :some | :every | :find, function()}
          | {:reduce, function(), {:ok, term()} | :none}

  @doc "Starts the method `kind` on the iterator `source`. Returns its promise."
  @spec start(AsyncIteration.t(), kind(), AsyncPermit.t()) :: Promise.t()
  def start(source, kind, permit) do
    owner = Promise.owner()
    snapshot = Snapshot.new()
    pid = spawn(fn -> init(source, kind, permit, owner, snapshot) end)
    PromiseCell.promise(pid)
  end

  defp init(source, kind, permit, owner, snapshot) do
    _promise = PromiseCell.start(owner)
    Process.flag(:trap_exit, true)
    Promise.put_owner(owner)
    Snapshot.restore(snapshot)

    {name, fun, acc} =
      case kind do
        :to_array -> {:to_array, nil, []}
        {:reduce, fun, initial} -> {:reduce, fun, initial}
        {name, fun} -> {name, fun, nil}
      end

    continue(%{
      kind: name,
      fun: fun,
      source: source,
      owner: owner,
      snapshot: snapshot,
      permit: permit,
      running: %{},
      # The index of the next read, and of the next read to decide on.
      index: 0,
      decide: 0,
      # index => the outcome of a job, before the decision on it.
      outcomes: %{},
      # index => the job, for the jobs of `reduce` that wait for the
      # reducer.
      jobs: %{},
      # The values of `toArray` in reverse, or the accumulator of `reduce`:
      # `{:ok, accumulator}`, or `:none` before the first value.
      acc: acc,
      # The index that the reducer runs for.
      reducing: nil,
      # TRUE after the decision: the process reads no more values.
      stopping: false,
      # TRUE when a read gave the end or an error: each later read gives the
      # same, thus the process reads no more.
      exhausted: false,
      closing: nil,
      settled: false
    })
  end

  defp loop(state) do
    receive do
      {:job, ref, outcome} ->
        state |> job_outcome(ref, outcome) |> continue()

      # Only the job of the index `reducing` runs the reducer.
      {:reduced, ref, result} ->
        state |> AsyncPermit.release_job(ref) |> reduced_result(result) |> continue()

      {:closed, ref, completion} when ref == state.closing.ref ->
        state |> closed(completion) |> continue()

      {:permit, ref, outcome} ->
        state |> permit(ref, outcome) |> continue()

      {:EXIT, pid, reason} when is_map_key(state.running, pid) ->
        state |> process_exit(pid, reason) |> continue()

      message ->
        case PromiseCell.handle(message) do
          {:owner_down, _reason} -> stop_jobs(state)
          _handled_unknown_or_expired -> loop(state)
        end
    end
  end

  defp continue(state) do
    state = state |> decide() |> fill()
    state = AsyncPermit.prune(state, not state.stopping)

    # After the result, the process waits for its jobs and their permits.
    if state.settled and map_size(state.running) == 0 do
      PromiseCell.linger()
    else
      loop(state)
    end
  end

  defp stop_jobs(state) do
    for {pid, _entry} <- state.running, do: Process.exit(pid, :kill)
    :ok
  end

  # ---------------------------------------------------------------------------
  # The reads
  # ---------------------------------------------------------------------------

  # Starts a job for each permit, until the decision.
  defp fill(%{stopping: true} = state), do: state
  defp fill(%{exhausted: true} = state), do: state

  defp fill(state) do
    case AsyncPermit.take(state) do
      {:ok, permit, state} -> state |> start_read(permit) |> fill()
      {:wait, state} -> state
    end
  end

  # This process starts the read of each job, thus the reads are in their
  # sequence.
  defp start_read(state, permit) do
    ref = make_ref()
    coordinator = self()
    index = state.index
    context = Map.take(state, [:kind, :fun, :owner, :snapshot])

    pid =
      spawn_link(fn ->
        Promise.put_owner(context.owner)
        Snapshot.restore(context.snapshot)
        read_job(coordinator, ref, index, context)
      end)

    send(pid, {:handle, AsyncIteration.request(state.source, :next, pid)})
    entry = %{role: :job, ref: ref, index: index, permit: permit}

    %{
      state
      | index: index + 1,
        running: Map.put(state.running, pid, entry),
        jobs: Map.put(state.jobs, index, pid)
    }
  end

  defp read_job(coordinator, ref, index, context) do
    outcome =
      receive do
        {:handle, handle} -> handle |> AsyncStep.await() |> read_outcome(index, context)
      end

    send(coordinator, {:job, ref, outcome})

    # A job of `reduce` keeps its value, and its permit, for the reducer.
    with {:reduce, {:value, value, nil}} <- {context.kind, outcome} do
      receive do
        {:reduce, acc} ->
          send(coordinator, {:reduced, ref, AsyncStep.call(context.fun, [acc, value, index])})

        :skip ->
          :ok
      end
    end
  end

  defp read_outcome({:rejected, reason}, _index, _context), do: {:next_error, reason}
  defp read_outcome({:fulfilled, %{done: true}}, _index, _context), do: :done

  defp read_outcome({:fulfilled, %{value: value}}, _index, %{kind: kind})
       when kind in [:to_array, :reduce],
       do: {:value, value, nil}

  defp read_outcome({:fulfilled, %{value: value}}, index, %{fun: fun}) do
    case AsyncStep.call(fun, [value, index]) do
      {:ok, result} -> {:value, value, result}
      {:error, reason} -> {:callback_error, reason}
    end
  end

  # A job sends its outcome before it stops: thus it is in `running`. The
  # job gives its permit back at once, but a read starts only after the
  # decisions that the outcome permits. A job of `reduce` with a value
  # keeps its permit for the reducer.
  defp job_outcome(state, ref, outcome) do
    {_pid, %{index: index}} = Enum.find(state.running, fn {_pid, entry} -> entry.ref == ref end)
    keeps? = state.kind == :reduce and match?({:value, _value, nil}, outcome)
    state = if keeps?, do: state, else: AsyncPermit.release_job(state, ref)
    record(state, index, outcome)
  end

  defp record(state, index, outcome) do
    exhausted = state.exhausted or outcome == :done or match?({:next_error, _reason}, outcome)
    state = %{state | outcomes: Map.put(state.outcomes, index, outcome), exhausted: exhausted}
    if state.stopping, do: skip_waiting(state), else: state
  end

  # A job that stopped with no result, for example because a different
  # process killed it, fails with the reason of its stop: before its
  # decision as the error of a callback, and during the reducer as the
  # error of the reducer. A job of `reduce` that keeps its value for the
  # reducer fails also after its result.
  defp job_failed(%{reducing: index} = state, index, reason) do
    reduced_result(state, {:error, reason})
  end

  defp job_failed(state, index, reason) do
    keeps_value? = state.kind == :reduce or not Map.has_key?(state.outcomes, index)
    failed? = index >= state.decide and keeps_value?
    if failed?, do: record(state, index, {:callback_error, reason}), else: state
  end

  # ---------------------------------------------------------------------------
  # The decisions, in the sequence of the reads
  # ---------------------------------------------------------------------------

  defp decide(%{stopping: true} = state), do: state
  defp decide(%{reducing: index} = state) when not is_nil(index), do: state

  defp decide(state) do
    case Map.pop(state.outcomes, state.decide) do
      {nil, _outcomes} -> state
      {outcome, outcomes} -> %{state | outcomes: outcomes} |> step(outcome)
    end
  end

  defp next_decision(state), do: decide(%{state | decide: state.decide + 1})

  # The end of the iterator: the result of the method.
  defp step(state, :done) do
    case {state.kind, state.acc} do
      {:to_array, values} -> settle(state, {:fulfilled, Enum.reverse(values)})
      {:for_each, _acc} -> settle(state, {:fulfilled, :ok})
      {:some, _acc} -> settle(state, {:fulfilled, false})
      {:every, _acc} -> settle(state, {:fulfilled, true})
      {:find, _acc} -> settle(state, {:fulfilled, nil})
      {:reduce, {:ok, acc}} -> settle(state, {:fulfilled, acc})
      {:reduce, :none} -> settle(state, {:rejected, empty_reduce()})
    end
  end

  # An error of the iterator does not close it.
  defp step(state, {:next_error, reason}), do: settle(state, {:rejected, reason})

  # IfAbruptCloseAsyncIterator: an error of a callback closes the iterator.
  defp step(state, {:callback_error, reason}), do: close(state, {:throw, reason})

  defp step(%{kind: :to_array} = state, {:value, value, _result}) do
    next_decision(%{state | acc: [value | state.acc]})
  end

  defp step(%{kind: :for_each} = state, {:value, _value, _result}), do: next_decision(state)

  defp step(%{kind: :some} = state, {:value, _value, result}) do
    if AsyncStep.truthy?(result), do: close(state, {:normal, true}), else: next_decision(state)
  end

  defp step(%{kind: :every} = state, {:value, _value, result}) do
    if AsyncStep.truthy?(result), do: next_decision(state), else: close(state, {:normal, false})
  end

  defp step(%{kind: :find} = state, {:value, value, result}) do
    if AsyncStep.truthy?(result), do: close(state, {:normal, value}), else: next_decision(state)
  end

  # `reduce` with no initial value: the first value is the accumulator.
  defp step(%{kind: :reduce, acc: :none} = state, {:value, value, nil}) do
    {pid, jobs} = Map.pop!(state.jobs, state.decide)
    send(pid, :skip)
    next_decision(%{state | acc: {:ok, value}, jobs: jobs})
  end

  defp step(%{kind: :reduce, acc: {:ok, acc}} = state, {:value, _value, nil}) do
    send(Map.fetch!(state.jobs, state.decide), {:reduce, acc})
    %{state | reducing: state.decide}
  end

  defp reduced_result(state, {:ok, acc}) do
    jobs = Map.delete(state.jobs, state.reducing)
    next_decision(%{state | acc: {:ok, acc}, reducing: nil, jobs: jobs})
  end

  defp reduced_result(state, {:error, reason}) do
    close(
      %{state | reducing: nil, jobs: Map.delete(state.jobs, state.reducing)},
      {:throw, reason}
    )
  end

  defp empty_reduce do
    %Web.TypeError{message: "Reduce of an empty async iterator with no initial value."}
  end

  # ---------------------------------------------------------------------------
  # The end
  # ---------------------------------------------------------------------------

  defp settle(state, outcome) do
    PromiseCell.settle(outcome)
    skip_waiting(%{state | stopping: true, settled: true})
  end

  # The jobs of `reduce` that wait for the reducer end with no reducer.
  defp skip_waiting(%{kind: :reduce} = state) do
    {skipped, kept} =
      Map.split_with(state.jobs, fn {index, _pid} -> Map.has_key?(state.outcomes, index) end)

    Enum.each(skipped, fn {_index, pid} -> send(pid, :skip) end)
    %{state | jobs: kept}
  end

  defp skip_waiting(state), do: state

  # AsyncIteratorClose, and then the result.
  defp close(state, completion) do
    ref = make_ref()
    coordinator = self()
    source = state.source

    pid =
      spawn_link(fn -> send(coordinator, {:closed, ref, AsyncStep.close(source, completion)}) end)

    entry = %{role: :close, ref: ref, index: nil, permit: nil}

    skip_waiting(%{
      state
      | stopping: true,
        closing: %{ref: ref},
        running: Map.put(state.running, pid, entry)
    })
  end

  defp closed(state, {:normal, value}), do: settle(%{state | closing: nil}, {:fulfilled, value})
  defp closed(state, {:throw, reason}), do: settle(%{state | closing: nil}, {:rejected, reason})

  # ---------------------------------------------------------------------------
  # Permits and the end of a process
  # ---------------------------------------------------------------------------

  defp permit(state, ref, outcome) do
    case AsyncPermit.granted(state, ref, outcome, not state.stopping) do
      {:ok, permit, state} ->
        start_read(state, permit)

      # The governor rejected the acquisition: an error of the method, after
      # the reads before it. The method closes the iterator.
      {:error, reason, state} ->
        index = state.index
        record(%{state | index: index + 1}, index, {:callback_error, reason})

      {:ignored, state} ->
        state
    end
  end

  # The end of a process gives its permit back. A process that stops with
  # no result, for example because a different process killed it, gives
  # the reason of its stop as its result, before its permit goes back: thus
  # no read starts before that result.
  defp process_exit(state, pid, reason) do
    {entry, running} = Map.pop!(state.running, pid)
    state = %{state | running: running}
    state = if reason == :normal, do: state, else: failed(state, entry, reason)
    AsyncPermit.release(state, entry.permit)
  end

  defp failed(state, %{role: :job, index: index}, reason), do: job_failed(state, index, reason)

  defp failed(state, %{role: :close, ref: ref}, reason) do
    if match?(%{ref: ^ref}, state.closing), do: closed(state, {:throw, reason}), else: state
  end

  # An acquisition that stops after its outcome has no effect.
  defp failed(state, %{role: :permit, ref: ref}, reason) do
    rejected = {:rejected, reason}
    if AsyncPermit.acquiring?(state, ref), do: permit(state, ref, rejected), else: state
  end
end
