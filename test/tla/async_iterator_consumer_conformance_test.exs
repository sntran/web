defmodule Web.TLA.AsyncIteratorConsumerConformanceTest do
  # Compares the real method `Web.AsyncIterator.find/3` with the
  # specification `tla/AsyncIteratorConsumer.tla`, with one or two permits.
  #
  # The test process is the source (see `Web.Test.ScriptedIterator`): it
  # gets each read and the close, and it gives their outcomes. The value of
  # the read `j` is `j`. The predicate of each job waits for the test. The
  # test makes a random walk of the operations that the specification
  # permits: the answers of the source, the ends of the predicates, a kill
  # of a predicate, the end of the close, and the stop of the owner. It does
  # each operation on the real method and on
  # the specification, and it compares the reads, the closes, the result,
  # the predicates that run, the processes of the method, and its work.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.AsyncIterator
  alias Web.Promise
  alias Web.Test.ScriptedIterator, as: Script
  alias Web.Test.SpecModel

  @reads 3
  @steps [{"Decide", []}] ++
           for(job <- 1..@reads, do: {"Release", [job]}) ++ [{"StartRead", []}, {"Stop", []}]

  # Each command is two random numbers. The first chooses an operation among
  # the operations that the specification permits at that time, with their
  # weights, and the second chooses its argument. Thus each command does a
  # step.
  defp commands, do: list_of(tuple({integer(0..9_999), integer(0..9_999)}), max_length: 14)

  defp choose(model, {pick, argument}) do
    state = SpecModel.to_map(model)
    jobs = fn phase -> for {^phase, job} <- Enum.with_index(state["phase"], 1), do: job end

    # The last read of the model gives the end.
    answers = fn job -> if job == @reads, do: ["end"], else: ~w(value value end error) end

    closing =
      if state["closing"] != "none", do: [{:close_end, "ok"}, {:close_end, "fail"}], else: []

    options =
      Enum.reject(
        [
          {8, for(job <- jobs.("read"), o <- answers.(job), do: {:answer, job, o})},
          {8, for(job <- jobs.("check"), o <- ~w(yes no no throw), do: {:check, job, o})},
          {1, Enum.map(jobs.("check"), &{:kill, &1})},
          {4, closing},
          {1, if(state["ownerAlive"], do: [:owner_stop], else: [])}
        ],
        fn {_weight, choices} -> choices == [] end
      )

    pick_option(options, pick, argument)
  end

  defp pick_option([], _pick, _argument), do: :none

  defp pick_option(options, pick, argument) do
    total = options |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    {_weight, choices} = weighted(options, rem(pick, total))
    Enum.at(choices, rem(argument, length(choices)))
  end

  defp weighted([{weight, _choices} = option | rest], point) do
    if point < weight, do: option, else: weighted(rest, point - weight)
  end

  property "the method does each step as the specification permits" do
    check all(
            capacity <- member_of([1, 2]),
            commands <- commands(),
            max_runs: 150
          ) do
      system = start_system(capacity)

      try do
        model =
          "AsyncIteratorConsumer"
          |> SpecModel.start({"Capacity = 2", "Capacity = #{capacity}"})
          |> SpecModel.settle(@steps)

        system = observe(system)
        assert_same_state(model, system)

        Enum.reduce(commands, {model, system}, fn numbers, {model, system} ->
          {model, system} = run(choose(model, numbers), model, system)
          system = observe(system)
          model = SpecModel.settle(model, @steps)
          assert_same_state(model, system)
          {model, system}
        end)
      after
        stop_system(system)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The real system: an owner that calls the method, with the test as source
  # ---------------------------------------------------------------------------

  defp start_system(capacity) do
    flush()
    test = self()
    source = Script.new()

    predicate = fn value, counter ->
      send(test, {:predicate, value, counter, self()})

      receive do
        {:go, result} -> result
        {:raise, reason} -> raise reason
      end
    end

    owner =
      spawn(fn ->
        send(test, {:promise, AsyncIterator.find(source, predicate, capacity)})
        Process.sleep(:infinity)
      end)

    assert_receive {:promise, promise}

    %{
      owner: owner,
      promise: promise,
      reads: [],
      later_reads: 0,
      closes: [],
      predicates: %{},
      ended: MapSet.new()
    }
  end

  defp stop_system(system) do
    monitor = Process.monitor(system.promise.pid)
    Process.exit(system.owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
  end

  defp flush do
    receive do
      {:"$web_async_iterator", _step, _target} -> flush()
      {:predicate, _value, _counter, _pid} -> flush()
    after
      0 -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # One operation, on the real method and on the specification
  # ---------------------------------------------------------------------------

  defp run({:answer, job, outcome}, model, system) do
    target = Enum.at(system.reads, job - 1)

    case outcome do
      "value" -> Script.give(target, job)
      "end" -> Script.finish(target)
      "error" -> Script.fail(target, :source_error)
    end

    {SpecModel.step!(model, "Answer", [job, outcome]), system}
  end

  defp run({:check, job, outcome}, model, system) do
    case outcome do
      "yes" -> send(system.predicates[job], {:go, true})
      "no" -> send(system.predicates[job], {:go, false})
      "throw" -> send(system.predicates[job], {:raise, "predicate failed"})
    end

    {SpecModel.step!(model, "Check", [job, outcome]), end_predicate(system, job)}
  end

  defp run({:kill, job}, model, system) do
    Process.exit(system.predicates[job], :kill)
    {SpecModel.step!(model, "Kill", [job]), end_predicate(system, job)}
  end

  defp run({:close_end, outcome}, model, system) do
    target = List.last(system.closes)

    case outcome do
      "ok" -> Script.finish(target)
      "fail" -> Script.fail(target, :close_error)
    end

    {SpecModel.step!(model, "CloseEnd", [outcome]), system}
  end

  defp run(:owner_stop, model, system) do
    monitor = Process.monitor(system.promise.pid)
    Process.exit(system.owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}

    # The method stops its jobs, and their predicates.
    ended = MapSet.new(Map.keys(system.predicates))
    {SpecModel.step!(model, "OwnerStop"), %{system | ended: ended}}
  end

  defp run(:none, model, system), do: {model, system}

  defp end_predicate(system, job), do: %{system | ended: MapSet.put(system.ended, job)}

  # ---------------------------------------------------------------------------
  # The observation of the real system
  # ---------------------------------------------------------------------------

  # The source of the model has 3 reads: the last gives the end. The real
  # method can start a later read before the third read has its answer.
  # Such a read gets the end at once: the source gives the end after its
  # end, and the result of a read after the end has no effect.
  defp observe(system) do
    Script.settle([system.promise.pid])
    system = take_messages(system)
    {model_reads, later} = Enum.split(system.reads, @reads)

    if later == [] do
      system
    else
      Enum.each(later, &Script.finish/1)
      observe(%{system | reads: model_reads, later_reads: system.later_reads + length(later)})
    end
  end

  defp take_messages(system) do
    receive do
      {:"$web_async_iterator", :next, target} ->
        take_messages(%{system | reads: system.reads ++ [target]})

      {:"$web_async_iterator", {:return, _value}, target} ->
        take_messages(%{system | closes: system.closes ++ [target]})

      {:predicate, job, counter, pid} ->
        # The counter of the value of the read `job`.
        assert counter == job - 1
        take_messages(put_in(system.predicates[job], pid))
    after
      0 -> system
    end
  end

  defp assert_same_state(model, system) do
    state = SpecModel.to_map(model)

    assert length(system.reads) == state["reads"]
    assert length(system.closes) == state["closes"]
    # A promise stops when its owner stops.
    found = if state["result"] == "value", do: state["found"], else: 0
    expected = if state["ownerAlive"], do: {state["result"], found}, else: :released
    assert result(system.promise) == expected, inspect(state)

    checking = for {"check", job} <- Enum.with_index(state["phase"], 1), do: job
    running = system.predicates |> Map.keys() |> Enum.reject(&MapSet.member?(system.ended, &1))

    # A job whose callback ended, or that the owner stopped, has no process.
    for job <- system.ended, do: refute(Process.alive?(system.predicates[job]))
    assert Enum.sort(running) == checking

    # The processes of the method: a job for each permit in use, and the
    # close.
    closing = if state["closing"] == "none", do: 0, else: 1
    assert linked(system.promise.pid) == MapSet.size(state["held"]) + closing
    assert working?(system.promise.pid) == state["working"]
  end

  defp result(promise) do
    case Promise.peek(promise) do
      :pending -> {"none", 0}
      {:fulfilled, nil} -> {"nil", 0}
      {:fulfilled, job} -> {"value", job}
      {:rejected, _reason} -> {"error", 0}
      :released -> :released
    end
  end

  defp linked(pid) do
    case Process.info(pid, :links) do
      {:links, links} -> length(links)
      nil -> 0
    end
  end

  # After its work, the process only keeps the result: it hibernates.
  defp working?(pid) do
    case Process.info(pid, :current_function) do
      {:current_function, {:erlang, :hibernate, 3}} -> false
      {:current_function, _function} -> true
      nil -> false
    end
  end
end
