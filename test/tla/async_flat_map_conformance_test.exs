defmodule Web.TLA.AsyncFlatMapConformanceTest do
  # Compares the real helper `Web.AsyncIterator.flat_map/2` with the
  # specification `tla/AsyncFlatMap.tla`, with three calls.
  #
  # The test serves the source and the two inner iterators (see
  # `Web.Test.ScriptedIterator.new/1`): it gets each read and each close,
  # and it gives their outcomes. The source gives the number of the inner
  # iterator, and the mapper gives that inner iterator, or raises for the
  # value `:throw`. An inner iterator gives `{generation, index}` for the
  # read `index`. The test makes a random walk of the operations that the
  # specification permits: the calls of `next/1` and `return/1`, the
  # answers of the source and of the inner iterators, and the end of a
  # close. It does each operation on the real helper and on the
  # specification, and it compares the results of the calls, the reads of
  # each iterator, the reads that run, the closes, and the life of the
  # process.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.AsyncIterator
  alias Web.Promise
  alias Web.Test.ScriptedIterator, as: Script
  alias Web.Test.SpecModel

  @calls ["c1", "c2", "c3"]
  @config [
    {~s(Calls = {"c1", "c2"}), ~s(Calls = {"c1", "c2", "c3"})},
    {"MaxJobs = 7", "MaxJobs = 9"}
  ]
  @steps [
    {"StartOuter", []},
    {"StartPull", []},
    {"Finalize", []},
    {"EndUnmatched", []},
    {"Deliver", []},
    {"StartClose", []},
    {"Stop", []}
  ]

  # Each command is two random numbers: the first chooses an operation among
  # the operations that the specification permits, with their weights, and
  # the second chooses its argument.
  defp commands, do: list_of(tuple({integer(0..9_999), integer(0..9_999)}), max_length: 30)

  defp choose(model, {pick, argument}) do
    state = SpecModel.to_map(model)
    uncalled = for call <- @calls, state["called"][call] == "none", do: call
    running = running_jobs(state)
    inner = for {job, "inner"} <- running, o <- ~w(value value done error), do: {:inner, job, o}

    outer =
      for {job, "outer"} <- running,
          o <- ~w(inner inner end error),
          o != "inner" or Enum.at(state["gen"], job - 1) <= 2,
          do: {:outer, job, o}

    closing =
      if state["closer"] != "none", do: [{:close_end, "ok"}, {:close_end, "fail"}], else: []

    [
      {10, Enum.map(uncalled, &{:call, &1, "CallNext"})},
      {2, Enum.map(uncalled, &{:call, &1, "CallReturn"})},
      {10, inner},
      {6, outer},
      {4, closing}
    ]
    |> Enum.reject(fn {_weight, choices} -> choices == [] end)
    |> pick_option(pick, argument)
  end

  # The jobs that started and have no answer, with their kind.
  defp running_jobs(state) do
    for job <- 1..state["njobs"]//1, Enum.at(state["ans"], job - 1) == "none" do
      {job, Enum.at(state["kind"], job - 1)}
    end
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

  property "the helper does each step as the specification permits" do
    check all(commands <- commands(), max_runs: 200) do
      system = start_system()

      try do
        model = "AsyncFlatMap" |> SpecModel.start(@config) |> SpecModel.settle(@steps)

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
  # The real system: an owner that makes the helper, with the test as the
  # source and as the inner iterators
  # ---------------------------------------------------------------------------

  defp start_system do
    test = self()
    source = Script.new(:source)
    inners = %{1 => Script.new(1), 2 => Script.new(2)}

    mapper = fn
      :throw, _counter ->
        raise "mapper failed"

      generation, counter ->
        # The counter of the value of the read `generation` of the source.
        if counter != generation - 1, do: send(test, {:bad_counter, generation, counter})
        Map.fetch!(inners, generation)
    end

    owner =
      spawn(fn ->
        send(test, {:helper, AsyncIterator.flat_map(source, mapper)})
        Process.sleep(:infinity)
      end)

    assert_receive {:helper, helper}

    %{
      owner: owner,
      helper: helper,
      iterators: [source | Map.values(inners)],
      promises: %{},
      # The targets of the reads of each iterator, in their sequence.
      reads: %{:source => [], 1 => [], 2 => []},
      # The reads with no answer.
      open: MapSet.new(),
      # The closes of each iterator that have no answer, and their number.
      closing: [],
      closes: %{:source => 0, 1 => 0, 2 => 0}
    }
  end

  defp stop_system(system) do
    monitor = Process.monitor(system.helper.pid)
    Process.exit(system.owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    Enum.each(system.iterators, &Script.stop/1)
    flush()
  end

  defp flush do
    receive do
      {:scripted, _tag, _step, _target} -> flush()
    after
      0 -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # One operation, on the real helper and on the specification
  # ---------------------------------------------------------------------------

  defp run({:call, call, action}, model, system) do
    promise =
      case action do
        "CallNext" -> AsyncIterator.next(system.helper)
        "CallReturn" -> AsyncIterator.return(system.helper)
      end

    {SpecModel.step!(model, action, [call]), put_in(system.promises[call], promise)}
  end

  defp run({:inner, job, outcome}, model, system) do
    state = SpecModel.to_map(model)
    generation = Enum.at(state["gen"], job - 1)
    index = Enum.at(state["idx"], job - 1)
    target = Enum.at(system.reads[generation], index - 1)

    case outcome do
      "value" -> Script.give(target, {generation, index})
      "done" -> Script.finish(target)
      "error" -> Script.fail(target, {:inner_error, generation, index})
    end

    {SpecModel.step!(model, "AnswerInner", [job, outcome]), answered(system, target)}
  end

  defp run({:outer, job, outcome}, model, system) do
    read = Enum.at(SpecModel.to_map(model)["gen"], job - 1)
    target = Enum.at(system.reads.source, read - 1)

    case outcome do
      "inner" -> Script.give(target, read)
      "end" -> Script.finish(target)
      "error" -> Script.give(target, :throw)
    end

    {SpecModel.step!(model, "AnswerOuter", [job, outcome]), answered(system, target)}
  end

  # The close of the inner iterator comes first, and then the close of the
  # source. A close that fails fails the first close.
  defp run({:close_end, outcome}, model, system) do
    [{_tag, first} | _rest] = system.closing

    case outcome do
      "ok" -> Script.finish(first)
      "fail" -> Script.fail(first, :close_error)
    end

    system = %{system | closing: tl(system.closing)}

    system =
      if SpecModel.get(model, "closeInner") > 0 do
        target = Script.assert_close(:source)
        Script.finish(target)
        %{system | closes: Map.update!(system.closes, :source, &(&1 + 1))}
      else
        system
      end

    {SpecModel.step!(model, "CloseEnd", [outcome]), system}
  end

  defp run(:none, model, system), do: {model, system}

  defp answered(system, target), do: %{system | open: MapSet.delete(system.open, target)}

  # ---------------------------------------------------------------------------
  # The observation of the real system
  # ---------------------------------------------------------------------------

  # Waits until the helper, its jobs, the iterators, and the promises of the
  # calls are at rest. Then takes the reads and the closes.
  defp observe(system) do
    promises = Enum.map(system.promises, fn {_call, promise} -> promise.pid end)
    Script.settle([system.helper.pid | Enum.map(system.iterators, & &1.pid)] ++ promises)
    refute_received {:bad_counter, _generation, _counter}
    take_messages(system)
  end

  defp take_messages(system) do
    receive do
      {:scripted, tag, :next, target} ->
        system
        |> update_in([:reads, tag], &(&1 ++ [target]))
        |> Map.update!(:open, &MapSet.put(&1, target))
        |> take_messages()

      {:scripted, tag, {:return, _value}, target} ->
        system
        |> Map.update!(:closing, &(&1 ++ [{tag, target}]))
        |> update_in([:closes, tag], &(&1 + 1))
        |> take_messages()
    after
      0 -> system
    end
  end

  defp assert_same_state(model, system) do
    state = SpecModel.to_map(model)

    for call <- @calls, state["called"][call] != "none" do
      expected = {state["answer"][call], expected_value(state, call)}
      assert result(system.promises[call]) == expected, "#{call} in #{inspect(state)}"
    end

    assert length(system.reads.source) == state["outers"]
    assert Enum.map([1, 2], &length(system.reads[&1])) == state["pulls"]
    assert MapSet.size(system.open) == length(running_jobs(state))
    assert Process.alive?(system.helper.pid) == state["alive"]
    assert_closes(state, system)
  end

  # A close that runs has one close with no answer: of the inner iterator
  # that it closes first, or else of the source. The close of the source
  # after the inner iterator comes when the inner iterator answers.
  defp assert_closes(state, system) do
    inner_first? = state["closer"] != "none" and state["closeInner"] > 0

    case state["closer"] do
      "none" -> assert system.closing == []
      _closer -> assert [{_tag, _target}] = system.closing
    end

    for {tag, _target} <- system.closing do
      assert tag == if(inner_first?, do: state["closeInner"], else: :source)
    end

    assert system.closes.source == state["closes"] - if(inner_first?, do: 1, else: 0)
    assert system.closes[1] + system.closes[2] == state["innerCloses"]
  end

  defp expected_value(state, call) do
    case state["answer"][call] do
      "value" -> List.to_tuple(state["got"][call])
      _other -> nil
    end
  end

  defp result(promise) do
    case Promise.peek(promise) do
      :pending -> {"none", nil}
      {:fulfilled, %{done: false, value: value}} -> {"value", value}
      {:fulfilled, %{done: true}} -> {"done", nil}
      {:rejected, _reason} -> {"error", nil}
    end
  end
end
