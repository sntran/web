defmodule Web.Internal.AsyncIteratorHelper do
  @moduledoc false

  # The process of an async iterator helper of `Web.AsyncIterator`: `map`,
  # `filter`, `take`, `drop`, `flatMap`, and `limit` of the proposal for
  # concurrency control. See `tla/AsyncIteratorHelper.tla`.
  #
  # The helper is lazy: it reads its source only for a `next()`.
  #
  # Concurrent calls of `next()`: the proposal lets each call of `next()`
  # start its own step, before the steps of the calls before it settle.
  # Thus the mapper of `map` can run for two values at the same time. The
  # results stay race-free: each call gets the result that it gets when
  # the calls are sequential, up to the first `done: true` or error.
  #
  #   * Each call of `next()` is an entry of `waiting`, in the sequence of
  #     the calls. Each step that reads the source is a job, in `jobs`, in
  #     the sequence of its read of the source. The first job gives its
  #     result to the first entry, and so on. The process starts the read
  #     of each job, thus the source gets the reads in their sequence.
  #   * A job gives its result only when each job before it gave its
  #     result. A job that ends the iteration (the end of the source, or an
  #     error) ends the entries after it at once with `done: true`: after
  #     the end, each result is `done: true`.
  #   * A value that `filter` does not select gives no result: its job goes
  #     out of `jobs`, and a new job reads the next value of the source.
  #   * `flatMap` has one job at a time: it reads all the values of the
  #     inner iterator before it reads the source again.
  #   * `drop` reads the values that it drops in the first job. The other
  #     jobs start after that job.
  #   * `limit` starts a job only with a permit of its governor: see
  #     `Web.Internal.AsyncPermit`.
  #
  # `return()` comes after the calls of `next()` before it, as
  # AsyncGeneratorReturn of the proposal enqueues it: the process closes
  # the source when those calls have their results. The limit of `take`
  # closes the source in the same way.
  #
  # An error of a callback closes the source (IfAbruptCloseAsyncIterator)
  # when the job of the error is the first job. Thus a close does not
  # change the result of a read that a call before it waits for. The
  # process closes its source one time only. An error of the source does
  # not close it.
  #
  # The process stops when it is done and no job runs. Then each step
  # gives `done: true`: see `Web.Internal.AsyncStep`. It also stops when
  # its owner stops, and then it stops its jobs.

  alias Web.AsyncContext.Snapshot
  alias Web.Internal.AsyncIteration
  alias Web.Internal.AsyncPermit
  alias Web.Internal.AsyncStep
  alias Web.Promise

  @typedoc false
  @type kind ::
          {:map, function()}
          | {:filter, function()}
          | {:take, non_neg_integer() | :infinity}
          | {:drop, non_neg_integer() | :infinity}
          | {:flat_map, function()}
          | {:limit, AsyncPermit.t()}

  @doc "Starts the helper `kind` of the iterator `source`."
  @spec start(AsyncIteration.t(), kind()) :: Web.AsyncIterator.t()
  def start(source, kind) do
    owner = Promise.owner()
    snapshot = Snapshot.new()
    pid = spawn(fn -> init(source, kind, owner, snapshot) end)
    %Web.AsyncIterator{pid: pid}
  end

  defp init(source, {name, argument}, owner, snapshot) do
    Process.flag(:trap_exit, true)
    Promise.put_owner(owner)
    Snapshot.restore(snapshot)

    loop(%{
      kind: name,
      source: source,
      owner: owner,
      owner_monitor: Process.monitor(owner),
      snapshot: snapshot,
      # The callback of `map`, `filter`, and `flatMap`.
      fun: if(name in [:map, :filter, :flat_map], do: argument),
      # The counter of the next value of the source, for the callback.
      counter: 0,
      # The values that `take` gives, and the values that `drop` drops.
      remaining: if(name in [:take, :drop], do: argument),
      permit: if(name == :limit, do: argument),
      # The inner iterator of `flatMap`.
      inner: nil,
      # FALSE after `return()`, the limit of `take`, and the end.
      accepting: true,
      # TRUE when a job ended the iteration: the source is at its end, or a
      # step failed.
      completed: false,
      waiting: [],
      jobs: [],
      # The `return()`, or the call of `take` after its limit, that waits
      # for the calls before it.
      pending_close: nil,
      # The close that runs, and the step that waits for it.
      closing: nil,
      # The job of `drop` that drops the values.
      dropping: nil,
      # Each process of this helper that runs: a job, the close, or the
      # acquisition of a permit, with its reference and its permit.
      running: %{}
    })
  end

  defp loop(state) do
    receive do
      {:"$web_async_iterator", :next, target} ->
        state |> next_call(target) |> continue()

      {:"$web_async_iterator", {:return, _value}, target} ->
        state |> return_call(target) |> continue()

      {:job, ref, result} ->
        state |> job_result(ref, result) |> continue()

      {:closed, ref, completion} when ref == state.closing.ref ->
        state |> closed(completion) |> continue()

      {:permit, ref, outcome} ->
        state |> permit(ref, outcome) |> continue()

      {:EXIT, pid, reason} when is_map_key(state.running, pid) ->
        state |> process_exit(pid, reason) |> continue()

      {:DOWN, monitor, :process, _owner, _reason} when monitor == state.owner_monitor ->
        stop_jobs(state)

      _other ->
        loop(state)
    end
  end

  # The steps after each event: give the results that are ready, start the
  # jobs, do a close that waits, and stop at the end.
  defp continue(state) do
    state =
      state
      |> end_unmatched()
      |> drain()
      |> start_jobs()
      |> pending_close()

    state = AsyncPermit.prune(state, permit_needed?(state))

    if done?(state), do: :ok, else: loop(state)
  end

  defp done?(state) do
    not state.accepting and state.waiting == [] and is_nil(state.pending_close) and
      is_nil(state.closing) and map_size(state.running) == 0
  end

  defp stop_jobs(state) do
    for {pid, _entry} <- state.running, do: Process.exit(pid, :kill)
    :ok
  end

  # ---------------------------------------------------------------------------
  # The calls of the iterator
  # ---------------------------------------------------------------------------

  # AsyncGeneratorNext: a helper that is done gives `done: true` at once.
  defp next_call(%{accepting: false} = state, target) do
    AsyncStep.reply(target, {:fulfilled, AsyncStep.done()})
    state
  end

  # `take`: "If remaining is 0, return ? AsyncIteratorClose(iterated,
  # NormalCompletion(undefined))". The close waits for the calls before it.
  defp next_call(%{kind: :take, remaining: 0} = state, target) do
    %{state | accepting: false, pending_close: target}
  end

  defp next_call(%{kind: :take, remaining: remaining} = state, target)
       when is_integer(remaining) do
    %{state | waiting: state.waiting ++ [target], remaining: remaining - 1}
  end

  defp next_call(state, target), do: %{state | waiting: state.waiting ++ [target]}

  # AsyncGeneratorReturn: the return comes after the calls before it.
  defp return_call(%{accepting: false} = state, target) do
    AsyncStep.reply(target, {:fulfilled, AsyncStep.done()})
    state
  end

  defp return_call(state, target), do: %{state | accepting: false, pending_close: target}

  # ---------------------------------------------------------------------------
  # The results of the jobs
  # ---------------------------------------------------------------------------

  # The permit of the job goes back before its result goes to the call, as
  # `wrapIterator` releases its token before its promise settles.
  defp job_result(state, ref, result) do
    state = AsyncPermit.release_job(state, ref)

    case Enum.find_index(state.jobs, &(&1.ref == ref and &1.status == :running)) do
      # A job after the end of the iteration.
      nil -> state
      index -> state |> clear_dropping(ref) |> record(index, result)
    end
  end

  defp clear_dropping(%{dropping: ref} = state, ref), do: %{state | dropping: nil}
  defp clear_dropping(state, _ref), do: state

  defp record(state, index, {:value, value}), do: put_status(state, index, {:value, value})

  defp record(state, index, {:value, value, inner, counter}) do
    %{put_status(state, index, {:value, value}) | inner: inner, counter: counter}
  end

  # `filter` does not select the value: the next job reads the next value.
  defp record(state, index, :skip), do: %{state | jobs: List.delete_at(state.jobs, index)}

  # The source is at its end. The entries from this job on are done.
  defp record(state, index, :done) do
    state
    |> complete(index)
    |> Map.update!(:jobs, &Enum.take(&1, index))
  end

  # A step failed. The entries after this job are done, and this job gives
  # the error when it is the first job.
  defp record(state, index, {:error, reason, close}) do
    state
    |> put_status(index, {:error, reason, close})
    |> complete(index + 1)
    |> Map.update!(:jobs, &Enum.take(&1, index + 1))
  end

  defp put_status(state, index, status) do
    %{state | jobs: List.update_at(state.jobs, index, &%{&1 | status: status})}
  end

  # The iteration ends at the entry `index`: each entry from it on, and a
  # close that waits, get `done: true`.
  defp complete(state, index) do
    {waiting, ended} = Enum.split(state.waiting, index)
    Enum.each(ended, &AsyncStep.reply(&1, {:fulfilled, AsyncStep.done()}))

    if state.pending_close,
      do: AsyncStep.reply(state.pending_close, {:fulfilled, AsyncStep.done()})

    %{
      state
      | waiting: waiting,
        pending_close: nil,
        accepting: false,
        completed: true,
        inner: nil
    }
  end

  # After the end, an entry with no job gets `done: true`. Such an entry
  # comes from a value that `filter` did not select.
  defp end_unmatched(%{completed: true} = state) do
    {waiting, ended} = Enum.split(state.waiting, length(state.jobs))
    Enum.each(ended, &AsyncStep.reply(&1, {:fulfilled, AsyncStep.done()}))
    %{state | waiting: waiting}
  end

  defp end_unmatched(state), do: state

  # Gives the results of the first jobs that have their results.
  defp drain(
         %{closing: nil, jobs: [%{status: {:value, value}} | jobs], waiting: [target | waiting]} =
           state
       ) do
    AsyncStep.reply(target, {:fulfilled, %{value: value, done: false}})
    drain(%{state | jobs: jobs, waiting: waiting})
  end

  defp drain(
         %{
           closing: nil,
           jobs: [%{status: {:error, reason, close}} | jobs],
           waiting: [target | waiting]
         } = state
       ) do
    state = %{state | jobs: jobs, waiting: waiting}

    if close do
      start_close(state, {:throw, reason}, {:reject, target, reason})
    else
      AsyncStep.reply(target, {:rejected, reason})
      drain(state)
    end
  end

  defp drain(state), do: state

  # ---------------------------------------------------------------------------
  # The close of the source
  # ---------------------------------------------------------------------------

  # A `return()` or the limit of `take`, when the calls before it have their
  # results. The end of the iteration gives `done: true` to a close that
  # waits (see `complete/2`). Thus the source of a close that waits is
  # open, and the process closes its source one time only.
  defp pending_close(%{pending_close: target, waiting: [], closing: nil} = state)
       when not is_nil(target) do
    start_close(%{state | pending_close: nil}, {:normal, nil}, {:return, target})
  end

  defp pending_close(state), do: state

  defp start_close(state, completion, after_close) do
    ref = make_ref()
    coordinator = self()
    iterators = close_sequence(state)

    pid =
      spawn_link(fn ->
        send(coordinator, {:closed, ref, close_all(iterators, completion)})
      end)

    %{
      state
      | closing: %{ref: ref, after: after_close},
        running: Map.put(state.running, pid, %{role: :close, ref: ref, permit: nil})
    }
  end

  # `flatMap` closes its inner iterator and then its source, as the steps
  # for a return completion of its Yield.
  defp close_sequence(%{inner: nil, source: source}), do: [source]
  defp close_sequence(%{inner: inner, source: source}), do: [inner, source]

  # A close of the inner iterator that fails closes the source with that
  # error (IfAbruptCloseIterator).
  defp close_all([iterator], completion), do: AsyncStep.close(iterator, completion)

  defp close_all([inner, source], completion) do
    AsyncStep.close(source, AsyncStep.close(inner, completion))
  end

  defp closed(%{closing: %{after: after_close}} = state, completion) do
    case {after_close, completion} do
      {{:reject, target, reason}, _completion} ->
        AsyncStep.reply(target, {:rejected, reason})

      {{:return, target}, {:normal, _value}} ->
        AsyncStep.reply(target, {:fulfilled, AsyncStep.done()})

      {{:return, target}, {:throw, reason}} ->
        AsyncStep.reply(target, {:rejected, reason})
    end

    %{state | closing: nil}
  end

  # ---------------------------------------------------------------------------
  # The start of the jobs
  # ---------------------------------------------------------------------------

  defp unstarted(state), do: length(state.waiting) - length(state.jobs)

  defp start_jobs(%{completed: true} = state), do: state

  defp start_jobs(state) do
    if unstarted(state) > 0, do: start_next(state), else: state
  end

  # `drop` drops its values in the first job, before each other job.
  defp start_next(%{kind: :drop, dropping: ref} = state) when not is_nil(ref), do: state

  defp start_next(%{kind: :drop, remaining: remaining} = state) when remaining != 0 do
    %{ref: ref} = job = new_job(state, {:drop, remaining}, nil)
    start_jobs(%{add_job(state, job) | remaining: 0, dropping: ref})
  end

  defp start_next(%{kind: :flat_map, jobs: [_running]} = state), do: state

  defp start_next(%{kind: :flat_map} = state) do
    add_job(state, new_job(state, {:flat_map, state.inner, state.counter}, nil))
  end

  defp start_next(%{kind: :limit} = state) do
    case AsyncPermit.take(state) do
      {:ok, permit, state} -> state |> start_read(permit) |> start_jobs()
      {:wait, state} -> state
    end
  end

  defp start_next(state), do: state |> start_read(nil) |> start_jobs()

  # A job that reads the source: this process starts the read, thus the
  # reads of the jobs are in their sequence.
  defp start_read(state, permit) do
    job = new_job(state, :read, permit)
    send(job.pid, {:handle, AsyncIteration.request(state.source, :next, job.pid)})
    %{add_job(state, job) | counter: state.counter + 1}
  end

  defp add_job(state, job) do
    entry = %{role: :job, ref: job.ref, permit: job.permit}

    %{
      state
      | jobs: state.jobs ++ [%{ref: job.ref, status: :running}],
        running: Map.put(state.running, job.pid, entry)
    }
  end

  defp new_job(state, work, permit) do
    ref = make_ref()
    coordinator = self()

    context = %{
      kind: state.kind,
      fun: state.fun,
      counter: state.counter,
      source: state.source,
      owner: state.owner,
      snapshot: state.snapshot
    }

    pid =
      spawn_link(fn ->
        Promise.put_owner(context.owner)
        Snapshot.restore(context.snapshot)
        send(coordinator, {:job, ref, run(work, context)})
      end)

    %{ref: ref, pid: pid, permit: permit}
  end

  # ---------------------------------------------------------------------------
  # The work of a job
  # ---------------------------------------------------------------------------

  defp run(:read, context) do
    receive do
      {:handle, handle} -> handle |> AsyncStep.await() |> read_result(context)
    end
  end

  # The steps of `drop`: "Repeat, while remaining > 0", and then the read of
  # the first value.
  defp run({:drop, remaining}, context) do
    case drop(context.source, remaining) do
      :ok -> context.source |> read(:next) |> read_result(context)
      result -> result
    end
  end

  defp run({:flat_map, inner, counter}, context), do: flat_map(inner, counter, context)

  defp read(iterator, step) do
    iterator |> AsyncIteration.request(step, self()) |> AsyncStep.await()
  end

  defp drop(_source, 0), do: :ok

  defp drop(source, remaining) do
    case read(source, :next) do
      {:rejected, reason} -> {:error, reason, false}
      {:fulfilled, %{done: true}} -> :done
      {:fulfilled, _result} -> drop(source, decrement(remaining))
    end
  end

  defp decrement(:infinity), do: :infinity
  defp decrement(remaining), do: remaining - 1

  # An error of the source does not close it. An error of a callback does.
  defp read_result({:rejected, reason}, _context), do: {:error, reason, false}
  defp read_result({:fulfilled, %{done: true}}, _context), do: :done
  defp read_result({:fulfilled, %{value: value}}, context), do: apply_callback(value, context)

  defp apply_callback(value, %{kind: :map, fun: fun, counter: counter}) do
    case AsyncStep.call(fun, [value, counter]) do
      {:ok, mapped} -> {:value, mapped}
      {:error, reason} -> {:error, reason, true}
    end
  end

  defp apply_callback(value, %{kind: :filter, fun: fun, counter: counter}) do
    case AsyncStep.call(fun, [value, counter]) do
      {:ok, selected} -> if AsyncStep.truthy?(selected), do: {:value, value}, else: :skip
      {:error, reason} -> {:error, reason, true}
    end
  end

  defp apply_callback(value, _context), do: {:value, value}

  # The steps of `flatMap` for one value: the next value of the inner
  # iterator, or else the inner iterator of the next value of the source.
  # An error of the inner iterator closes the source.
  defp flat_map(nil, counter, context) do
    with {:fulfilled, %{done: false, value: value}} <- read(context.source, :next),
         {:ok, mapped} <- AsyncStep.call(context.fun, [value, counter]),
         {:ok, inner} <- flattenable(mapped) do
      flat_map(inner, counter + 1, context)
    else
      {:fulfilled, %{done: true}} -> :done
      {:rejected, reason} -> {:error, reason, false}
      {:error, reason} -> {:error, reason, true}
    end
  end

  defp flat_map(inner, counter, context) do
    case read(inner, :next) do
      {:fulfilled, %{done: true}} -> flat_map(nil, counter, context)
      {:fulfilled, %{value: value}} -> {:value, value, inner, counter}
      {:rejected, reason} -> {:error, reason, true}
    end
  end

  # GetIteratorFlattenable(mapped, async): a string is not an iterable.
  defp flattenable(mapped) do
    {:ok, Web.AsyncIterator.__from__(mapped, :reject_strings)}
  rescue
    error in Web.TypeError -> {:error, error}
  end

  # ---------------------------------------------------------------------------
  # Permits and the end of a job
  # ---------------------------------------------------------------------------

  defp permit_needed?(state), do: not state.completed and unstarted(state) > 0

  defp permit(state, ref, outcome) do
    case AsyncPermit.granted(state, ref, outcome, permit_needed?(state)) do
      {:ok, permit, state} ->
        state |> start_read(permit) |> start_jobs()

      # The governor rejected the acquisition. The entry gets the error as
      # the error of a step, and the helper closes its source.
      {:error, reason, state} ->
        index = length(state.jobs)
        job = %{ref: make_ref(), status: :running}
        record(%{state | jobs: state.jobs ++ [job]}, index, {:error, reason, true})

      {:ignored, state} ->
        state
    end
  end

  # The end of a process of this helper gives its permit back. A process
  # that stops with no result, for example because a different process
  # killed it, gives the reason of its stop as its result, before its
  # permit goes back: thus no step starts before that result. A result that
  # came before the stop stays.
  defp process_exit(state, pid, reason) do
    {entry, running} = Map.pop!(state.running, pid)
    state = %{state | running: running}
    state = if reason == :normal, do: state, else: failed(state, entry, reason)
    AsyncPermit.release(state, entry.permit)
  end

  defp failed(state, %{role: :job, ref: ref}, reason) do
    job_result(state, ref, {:error, reason, true})
  end

  defp failed(state, %{role: :close, ref: ref}, reason) do
    if match?(%{ref: ^ref}, state.closing), do: closed(state, {:throw, reason}), else: state
  end

  # An acquisition that stops after its outcome has no effect.
  defp failed(state, %{role: :permit, ref: ref}, reason) do
    rejected = {:rejected, reason}
    if AsyncPermit.acquiring?(state, ref), do: permit(state, ref, rejected), else: state
  end
end
