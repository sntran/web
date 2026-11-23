defmodule Web.Internal.AsyncIteratorHelper do
  @moduledoc false

  # The process of an async iterator helper of `Web.AsyncIterator`: `map`,
  # `filter`, `take`, `drop`, `flatMap`, and `buffered` of the proposal
  # "async iterator helpers", and `limit` of the proposal for concurrency
  # control. See `tla/AsyncIteratorHelper.tla`, `tla/AsyncFlatMap.tla`, and
  # `tla/AsyncBuffered.tla`.
  #
  # The helper is lazy: it reads its source only for a `next()`. Only
  # `buffered(limit, true)` starts its reads at once.
  #
  # Concurrent calls of `next()`: the proposal lets each call of `next()`
  # start its own step, before the steps of the calls before it settle.
  # Thus the mapper of `map` can run for two values at the same time. The
  # results stay race-free: each call gets the result that it gets when
  # the calls are sequential, up to the first `done: true` or error.
  #
  #   * Each call of `next()` is an entry of `waiting`, in the sequence of
  #     the calls. Each step that reads an iterator is a job, in `jobs`, in
  #     the sequence of its read. The first job gives its result to the
  #     first entry, and so on. The process starts the read of each job,
  #     thus each iterator gets the reads in their sequence.
  #   * A job gives its result only when each job before it gave its
  #     result. A job that ends the iteration (the end of the source, or an
  #     error) ends the entries after it at once with `done: true`: after
  #     the end, each result is `done: true`.
  #   * A value that `filter` does not select gives no result: its job goes
  #     out of `jobs`, and a new job reads the next value of the source.
  #   * `flatMap` reads its source only when its inner iterator is at its
  #     end, and one time only for each inner iterator: the next inner
  #     iterator comes from the result of the mapper. The calls of `next()`
  #     read the inner iterator at the same time, one read for each call.
  #     See "flatMap" below.
  #   * `drop` reads the values that it drops in the first job. The other
  #     jobs start after that job.
  #   * `limit` starts a job only with a permit of its governor: see
  #     `Web.Internal.AsyncPermit`.
  #   * `buffered` reads ahead of the calls: see "buffered" below.
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
  #
  # ## flatMap
  #
  # The proposal has no text for the concurrent steps of `flatMap`. The
  # process does the steps that its champion gives in issue #22 of the
  # proposal and in the meeting of July 2026: "drain the first callback
  # before pulling from the underlying iterator again", and "we are never
  # doing any concurrency for the underlying iterator. Concurrency only
  # happens on results of the flat map function."
  #
  #   * One job reads the source, calls the mapper, and gets the inner
  #     iterator (GetIteratorFlattenable). The calls that come during that
  #     job wait. Then each call that has no job gets a read of the inner
  #     iterator, at once.
  #   * Each inner iterator is a generation, `gen`. A read of an inner
  #     iterator that gives `done: true` tells that the iterator has no
  #     value at that position: the job of that read, and each later job of
  #     the same generation, go out of `jobs`. Their calls get later values.
  #     When the generation is the current one, a new job reads the source.
  #     The end can come before the values of the reads before it settle:
  #     the source read then starts at once, as the champion permits.
  #   * A read of an inner iterator that fails before a read of the same
  #     iterator that can still give `done: true` waits (`:deferred`): that
  #     earlier end can remove it. When the reads before it give values, the
  #     error stays, and the iteration ends after it. No read of that inner
  #     iterator, and no read of the source, starts during the wait.
  #   * `return()` closes the current inner iterator and then the source.
  #
  # Thus each call gets the result of a sequential run, also when an inner
  # iterator gives `done: true` for a read and a value for a later read.
  #
  # ## buffered
  #
  # `buffered(limit, prepopulate)` has no text in the proposals. The process
  # does what the champions said in the meetings of September 2023 and June
  # 2024 (see `Web.AsyncIterator.buffered/3`):
  #
  #   * The process starts its reads at the first `next()`, or at once with
  #     `prepopulate`. Then it keeps its buffer full: it starts a read for
  #     each permit of `limit` (an integer is a count). A read that goes
  #     ahead of the calls is a job with no entry.
  #   * A job keeps its permit until its result goes to a call: a promise
  #     that the iterator gave and that is not settled counts towards the
  #     buffer. Thus `map(fn) |> buffered(5)` in a loop calls `fn` five
  #     times at the same time, not six.
  #   * A call with no job gets a read at once, with no permit: "buffered(N)
  #     allows pulling more than N times".
  #   * After the end of the source, the calls still get the results of the
  #     reads before the end. `return()` drops the results that no call
  #     took.

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
          | {:buffered, {AsyncPermit.t(), boolean()}}

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

    {permit, started} =
      case {name, argument} do
        {:limit, permit} -> {permit, true}
        {:buffered, {permit, prepopulate}} -> {permit, prepopulate}
        _other -> {nil, true}
      end

    continue(%{
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
      # The permits of `limit` and `buffered`.
      permit: permit,
      # FALSE until the first `next()` of `buffered` without `prepopulate`.
      started: started,
      # The inner iterator of `flatMap`: `%{gen: gen, iterator: iterator,
      # failed: failed}`, or nil when the helper must read the source.
      inner: nil,
      # FALSE after `return()`, the limit of `take`, and the end.
      accepting: true,
      # TRUE when a job ended the iteration: the source is at its end, or a
      # step failed.
      completed: false,
      waiting: [],
      # Each job: `%{ref: ref, status: status, gen: gen, permit: permit}`.
      # `gen` is the generation of the inner iterator that a job of
      # `flatMap` reads, or `:outer` for its read of the source. `permit` is
      # the permit that a job of `buffered` keeps until its result goes to a
      # call.
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
      |> finalize_deferred()
      |> end_unmatched()
      |> drain()
      |> start_jobs()
      |> pending_close()

    state = AsyncPermit.prune(state, permit_needed?(state))

    if done?(state), do: :ok, else: loop(state)
  end

  # A helper is done after `return()`, after the end of `take`, and after
  # the end of the source when no job keeps a result for a later call.
  defp done?(state) do
    (not state.accepting or (state.completed and state.jobs == [])) and state.waiting == [] and
      is_nil(state.pending_close) and is_nil(state.closing) and map_size(state.running) == 0
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

  defp next_call(state, target), do: %{state | waiting: state.waiting ++ [target], started: true}

  # AsyncGeneratorReturn: the return comes after the calls before it. After
  # the end of the source, `buffered` drops the results that no call took.
  defp return_call(%{accepting: false} = state, target) do
    AsyncStep.reply(target, {:fulfilled, AsyncStep.done()})
    state
  end

  defp return_call(%{completed: true} = state, target) do
    AsyncStep.reply(target, {:fulfilled, AsyncStep.done()})
    %{truncate_jobs(state, length(state.waiting)) | accepting: false}
  end

  # The reads that `buffered` did ahead of the calls give no result: no call
  # can take them.
  defp return_call(state, target) do
    %{truncate_jobs(state, length(state.waiting)) | accepting: false, pending_close: target}
  end

  # ---------------------------------------------------------------------------
  # The results of the jobs
  # ---------------------------------------------------------------------------

  # The permit of a job of `limit` goes back before its result goes to the
  # call, as `wrapIterator` releases its token before its promise settles.
  defp job_result(state, ref, result) do
    state = AsyncPermit.release_job(state, ref)

    case Enum.find_index(state.jobs, &(&1.ref == ref and &1.status == :running)) do
      # A job after the end of the iteration, or a job that a different job
      # of `flatMap` removed.
      nil -> state
      index -> state |> clear_dropping(ref) |> record(index, result)
    end
  end

  defp clear_dropping(%{dropping: ref} = state, ref), do: %{state | dropping: nil}
  defp clear_dropping(state, _ref), do: state

  defp record(state, index, {:value, value}), do: put_status(state, index, {:value, value})

  # `filter` does not select the value: the next job reads the next value.
  defp record(state, index, :skip), do: %{state | jobs: List.delete_at(state.jobs, index)}

  # `flatMap` has the result of its mapper. This process gets the inner
  # iterator (GetIteratorFlattenable): thus it holds the lock of an inner
  # stream while it reads the stream. The job gives no result: the calls
  # with no job read the inner iterator. A value that is not an iterable is
  # an error of the mapper.
  defp record(state, index, {:mapped, mapped, gen}) do
    case flattenable(mapped) do
      {:ok, iterator} ->
        %{
          state
          | jobs: List.delete_at(state.jobs, index),
            inner: %{gen: gen, iterator: iterator, failed: false}
        }

      {:error, error} ->
        end_with_error(state, index, error, true)
    end
  end

  # `flatMap`: the inner iterator has no value at this position. The job,
  # and each later job of its generation, go out of `jobs`.
  defp record(state, index, :inner_done) do
    %{gen: gen} = Enum.at(state.jobs, index)
    {before, rest} = Enum.split(state.jobs, index)
    later = Enum.reject(rest, &(&1.gen == gen))
    state = %{state | jobs: before ++ later}
    if match?(%{gen: ^gen}, state.inner), do: %{state | inner: nil}, else: state
  end

  # The source is at its end. The entries from this job on are done.
  defp record(state, index, :done) do
    state
    |> complete(index)
    |> truncate_jobs(index)
  end

  # A step failed. The entries after this job are done, and this job gives
  # the error when it is the first job. A read of an inner iterator of
  # `flatMap` waits for the reads of that iterator before it.
  defp record(state, index, {:error, reason, close}) do
    if pending_before?(state, index) do
      state |> put_status(index, {:deferred, reason}) |> fail_inner(index)
    else
      end_with_error(state, index, reason, close)
    end
  end

  defp end_with_error(state, index, reason, close) do
    state
    |> put_status(index, {:error, reason, close})
    |> complete(index + 1)
    |> truncate_jobs(index + 1)
  end

  # TRUE for a read of an inner iterator of `flatMap` when a read of the
  # same iterator before it runs: that read can still give `done: true`. (A
  # deferred error has such a read before it: else it is not deferred.)
  defp pending_before?(state, index) do
    case Enum.at(state.jobs, index) do
      %{gen: gen} when is_integer(gen) ->
        state.jobs
        |> Enum.take(index)
        |> Enum.any?(&(&1.gen == gen and &1.status == :running))

      _other ->
        false
    end
  end

  # No read of an inner iterator with a deferred error starts.
  defp fail_inner(state, index) do
    %{gen: gen} = Enum.at(state.jobs, index)

    case state.inner do
      %{gen: ^gen} = inner -> %{state | inner: %{inner | failed: true}}
      _other -> state
    end
  end

  # A deferred error stays when the reads before it of its inner iterator
  # gave values.
  defp finalize_deferred(state) do
    with index when is_integer(index) <-
           Enum.find_index(state.jobs, &match?(%{status: {:deferred, _reason}}, &1)),
         false <- pending_before?(state, index) do
      {:deferred, reason} = Enum.at(state.jobs, index).status
      end_with_error(state, index, reason, true)
    else
      _pending -> state
    end
  end

  defp put_status(state, index, status) do
    %{state | jobs: List.update_at(state.jobs, index, &%{&1 | status: status})}
  end

  # The iteration ends at the entry `index`: each entry from it on, and a
  # close that waits, get `done: true`. `buffered` still gives the results
  # of its jobs before the end to later calls.
  defp complete(state, index) do
    {waiting, ended} = Enum.split(state.waiting, index)
    Enum.each(ended, &AsyncStep.reply(&1, {:fulfilled, AsyncStep.done()}))

    if state.pending_close,
      do: AsyncStep.reply(state.pending_close, {:fulfilled, AsyncStep.done()})

    %{
      state
      | waiting: waiting,
        pending_close: nil,
        accepting: state.accepting and state.kind == :buffered,
        completed: true,
        inner: nil
    }
  end

  # Keeps the first `count` jobs. The others give no result. A job of
  # `buffered` keeps its permit until its read settles.
  defp truncate_jobs(state, count) do
    {kept, dropped} = Enum.split(state.jobs, count)
    Enum.reduce(dropped, %{state | jobs: kept}, &drop_permit(&2, &1))
  end

  defp drop_permit(state, %{permit: nil}), do: state

  defp drop_permit(state, %{status: :running, ref: ref, permit: permit}) do
    {pid, _entry} = Enum.find(state.running, fn {_pid, entry} -> entry.ref == ref end)
    put_in(state.running[pid].permit, permit)
  end

  defp drop_permit(state, %{permit: permit}), do: AsyncPermit.release(state, permit)

  # After the end, an entry with no job gets `done: true`. Such an entry
  # comes from a value that `filter` did not select, or a read of `flatMap`
  # that an end removed.
  defp end_unmatched(%{completed: true} = state) do
    {waiting, ended} = Enum.split(state.waiting, length(state.jobs))
    Enum.each(ended, &AsyncStep.reply(&1, {:fulfilled, AsyncStep.done()}))
    %{state | waiting: waiting}
  end

  defp end_unmatched(state), do: state

  # Gives the results of the first jobs that have their results. A job of
  # `buffered` gives its permit back with its result.
  defp drain(
         %{
           closing: nil,
           jobs: [%{status: {:value, value}} = job | jobs],
           waiting: [target | waiting]
         } =
           state
       ) do
    AsyncStep.reply(target, {:fulfilled, %{value: value, done: false}})
    drain(release_held(%{state | jobs: jobs, waiting: waiting}, job))
  end

  defp drain(
         %{
           closing: nil,
           jobs: [%{status: {:error, reason, close}} = job | jobs],
           waiting: [target | waiting]
         } = state
       ) do
    state = release_held(%{state | jobs: jobs, waiting: waiting}, job)

    if close do
      start_close(state, {:throw, reason}, {:reject, target, reason})
    else
      AsyncStep.reply(target, {:rejected, reason})
      drain(state)
    end
  end

  defp drain(state), do: state

  defp release_held(state, %{permit: nil}), do: state
  defp release_held(state, %{permit: permit}), do: AsyncPermit.release(state, permit)

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
  defp close_sequence(%{inner: %{iterator: inner}, source: source}), do: [inner, source]

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

  # `buffered` fills its buffer first: thus a call takes a read that holds a
  # permit when one is free. A call with no read gets one with no permit.
  defp start_jobs(%{kind: :buffered} = state), do: state |> fill() |> forward()

  defp start_jobs(state) do
    if unstarted(state) > 0, do: start_next(state), else: state
  end

  # `drop` drops its values in the first job, before each other job.
  defp start_next(%{kind: :drop, dropping: ref} = state) when not is_nil(ref), do: state

  defp start_next(%{kind: :drop, remaining: remaining} = state) when remaining != 0 do
    %{ref: ref} = job = new_job(state, {:drop, remaining})
    start_jobs(%{add_job(state, job, nil, nil) | remaining: 0, dropping: ref})
  end

  # `flatMap`: one read of the source at a time, and only when no inner
  # iterator is open. Each call with no job reads the open inner iterator.
  defp start_next(%{kind: :flat_map} = state) do
    cond do
      Enum.any?(state.jobs, &(&1.gen == :outer)) -> state
      is_nil(state.inner) -> start_outer(state)
      state.inner.failed -> state
      true -> state |> start_inner_read() |> start_jobs()
    end
  end

  defp start_next(%{kind: :limit} = state) do
    case AsyncPermit.take(state) do
      {:ok, permit, state} -> state |> start_read(permit) |> start_jobs()
      {:wait, state} -> state
    end
  end

  defp start_next(state), do: state |> start_read(nil) |> start_jobs()

  defp fill(%{started: true, accepting: true} = state) do
    case AsyncPermit.take(state) do
      {:ok, permit, state} -> state |> start_read(permit) |> fill()
      {:wait, state} -> state
    end
  end

  defp fill(state), do: state

  defp forward(state) do
    if unstarted(state) > 0, do: state |> start_read(nil) |> forward(), else: state
  end

  # A job that reads the source: this process starts the read, thus the
  # reads of the jobs are in their sequence.
  defp start_read(state, permit) do
    job = new_job(state, :read)
    send(job.pid, {:handle, AsyncIteration.request(state.source, :next, job.pid)})
    %{add_job(state, job, permit, nil) | counter: state.counter + 1}
  end

  # The job of `flatMap` that reads the source and calls the mapper.
  defp start_outer(state) do
    job = new_job(state, {:outer, state.counter})
    send(job.pid, {:handle, AsyncIteration.request(state.source, :next, job.pid)})
    %{add_job(state, job, nil, :outer) | counter: state.counter + 1}
  end

  defp start_inner_read(%{inner: %{gen: gen, iterator: iterator}} = state) do
    job = new_job(state, :read_inner)
    send(job.pid, {:handle, AsyncIteration.request(iterator, :next, job.pid)})
    add_job(state, job, nil, gen)
  end

  # A job of `buffered` keeps its permit in `jobs`, until its result goes to
  # a call. A job of `limit` keeps it in `running`, until its result.
  defp add_job(state, job, permit, gen) do
    {held, released_at_result} =
      if state.kind == :buffered, do: {permit, nil}, else: {nil, permit}

    entry = %{role: :job, ref: job.ref, permit: released_at_result}

    %{
      state
      | jobs: state.jobs ++ [%{ref: job.ref, status: :running, gen: gen, permit: held}],
        running: Map.put(state.running, job.pid, entry)
    }
  end

  defp new_job(state, work) do
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

    %{ref: ref, pid: pid}
  end

  # ---------------------------------------------------------------------------
  # The work of a job
  # ---------------------------------------------------------------------------

  defp run(:read, context), do: context |> handle() |> read_result(context)

  defp run(:read_inner, context) do
    case handle(context) do
      {:fulfilled, %{done: true}} -> :inner_done
      {:fulfilled, %{value: value}} -> {:value, value}
      {:rejected, reason} -> {:error, reason, true}
    end
  end

  # The steps of `flatMap` for one value of the source: the mapper, with
  # AwaitNonPrimitive. An error of the mapper closes the source.
  defp run({:outer, gen}, context) do
    with {:fulfilled, %{done: false, value: value}} <- handle(context),
         {:ok, mapped} <- AsyncStep.call(context.fun, [value, gen]) do
      {:mapped, mapped, gen}
    else
      {:fulfilled, %{done: true}} -> :done
      {:rejected, reason} -> {:error, reason, false}
      {:error, reason} -> {:error, reason, true}
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

  # The read that this process started for the job.
  defp handle(_context) do
    receive do
      {:handle, handle} -> AsyncStep.await(handle)
    end
  end

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

  # GetIteratorFlattenable(mapped, async): a string is not an iterable.
  defp flattenable(mapped) do
    {:ok, Web.AsyncIterator.__from__(mapped, :reject_strings)}
  rescue
    error in Web.TypeError -> {:error, error}
  end

  # ---------------------------------------------------------------------------
  # Permits and the end of a job
  # ---------------------------------------------------------------------------

  # `limit` needs a permit for a call with no job. `buffered` needs a permit
  # for each read ahead, after its start.
  defp permit_needed?(%{kind: :buffered} = state) do
    state.started and state.accepting and not state.completed
  end

  defp permit_needed?(state), do: not state.completed and unstarted(state) > 0

  defp permit(state, ref, outcome) do
    case AsyncPermit.granted(state, ref, outcome, permit_needed?(state)) do
      {:ok, permit, state} ->
        state |> start_read(permit) |> start_jobs()

      # The governor rejected the acquisition. The entry gets the error as
      # the error of a step, and the helper closes its source.
      {:error, reason, state} ->
        index = length(state.jobs)
        job = %{ref: make_ref(), status: :running, gen: nil, permit: nil}
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
