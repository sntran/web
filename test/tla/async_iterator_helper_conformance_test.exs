defmodule Web.TLA.AsyncIteratorHelperConformanceTest do
  # Compares the real helper `Web.AsyncIterator.map/2` with the
  # specification `tla/AsyncIteratorHelper.tla`, with a job for each call
  # (`Capacity = 3`).
  #
  # The test process is the source of the helper (see
  # `Web.Test.ScriptedIterator`): it gets each read and each close, and it
  # gives their outcomes. The mapper of each job waits for the test. The
  # test makes a random walk of the operations that the specification
  # permits: the calls of `next/1` and `return/1`, the answers of the
  # source, the ends of the mappers, a kill of a mapper, the end of a close,
  # and the stop of the owner. It does each
  # operation on the real helper and on the specification, and it compares
  # the results of the calls, the reads, the closes, the mappers that run,
  # and the life of the process.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.AsyncIterator
  alias Web.Promise
  alias Web.Test.ScriptedIterator, as: Script
  alias Web.Test.SpecModel

  @calls ["c1", "c2", "c3"]
  @steps [{"StartJob", []}, {"Deliver", []}, {"StartClose", []}, {"Stop", []}]

  # Each command is two random numbers. The first chooses an operation among
  # the operations that the specification permits at that time, with their
  # weights, and the second chooses its argument. Thus each command does a
  # step.
  defp commands, do: list_of(tuple({integer(0..9_999), integer(0..9_999)}), max_length: 24)

  defp choose(model, {pick, argument}) do
    state = SpecModel.to_map(model)
    jobs = fn phase -> for {^phase, job} <- Enum.with_index(state["phase"], 1), do: job end
    uncalled = for call <- @calls, state["called"][call] == "none", do: call

    closing =
      if state["closer"] != "none", do: [{:close_end, "ok"}, {:close_end, "fail"}], else: []

    options =
      Enum.reject(
        [
          {10, Enum.map(uncalled, &{:call, &1, "CallNext"})},
          {2, Enum.map(uncalled, &{:call, &1, "CallReturn"})},
          {8, for(job <- jobs.("read"), o <- ~w(value value end error), do: {:answer, job, o})},
          {8, for(job <- jobs.("map"), o <- ~w(ok ok throw), do: {:map_end, job, o})},
          {1, Enum.map(jobs.("map"), &{:kill, &1})},
          {4, closing},
          {1, if(state["alive"], do: [:owner_stop], else: [])}
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

  property "the helper does each step as the specification permits" do
    check all(commands <- commands(), max_runs: 200) do
      system = start_system()

      try do
        model =
          "AsyncIteratorHelper"
          |> SpecModel.start({"Capacity = 2", "Capacity = 3"})
          |> SpecModel.settle(@steps)

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
  # The real system: an owner that makes the helper, with the test as source
  # ---------------------------------------------------------------------------

  defp start_system do
    flush()
    test = self()
    source = Script.new()

    mapper = fn value, counter ->
      send(test, {:mapper, value, counter, self()})

      receive do
        {:go, result} -> result
        {:raise, reason} -> raise reason
      end
    end

    owner =
      spawn(fn ->
        send(test, {:helper, AsyncIterator.map(source, mapper)})
        Process.sleep(:infinity)
      end)

    assert_receive {:helper, helper}

    %{
      owner: owner,
      helper: helper,
      promises: %{},
      reads: [],
      closes: [],
      mappers: %{},
      ended: MapSet.new()
    }
  end

  defp stop_system(system) do
    monitor = Process.monitor(system.helper.pid)
    Process.exit(system.owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
  end

  # The steps and the mapper calls of an earlier run.
  defp flush do
    receive do
      {:"$web_async_iterator", _step, _target} -> flush()
      {:mapper, _value, _counter, _pid} -> flush()
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

  defp run({:answer, job, outcome}, model, system) do
    target = Enum.at(system.reads, job - 1)

    case outcome do
      "value" -> Script.give(target, job)
      "end" -> Script.finish(target)
      "error" -> Script.fail(target, :source_error)
    end

    {SpecModel.step!(model, "Answer", [job, outcome]), system}
  end

  defp run({:map_end, job, outcome}, model, system) do
    case outcome do
      "ok" -> send(system.mappers[job], {:go, job})
      "throw" -> send(system.mappers[job], {:raise, "mapper failed"})
    end

    {SpecModel.step!(model, "MapEnd", [job, outcome]), end_mapper(system, job)}
  end

  defp run({:kill, job}, model, system) do
    Process.exit(system.mappers[job], :kill)
    {SpecModel.step!(model, "Kill", [job]), end_mapper(system, job)}
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
    monitor = Process.monitor(system.helper.pid)
    Process.exit(system.owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}

    # The helper stops its jobs, and their mappers.
    ended = MapSet.new(Map.keys(system.mappers))
    {SpecModel.step!(model, "OwnerStop"), %{system | ended: ended}}
  end

  defp run(:none, model, system), do: {model, system}

  defp end_mapper(system, job), do: %{system | ended: MapSet.put(system.ended, job)}

  # ---------------------------------------------------------------------------
  # The observation of the real system
  # ---------------------------------------------------------------------------

  # Waits until the helper, its jobs, and the promises of the calls are at
  # rest. Then takes the reads, the closes, and the calls of the mapper.
  defp observe(system) do
    Script.settle([system.helper.pid | Enum.map(system.promises, fn {_call, p} -> p.pid end)])
    take_messages(system)
  end

  defp take_messages(system) do
    receive do
      {:"$web_async_iterator", :next, target} ->
        take_messages(%{system | reads: system.reads ++ [target]})

      {:"$web_async_iterator", {:return, _value}, target} ->
        take_messages(%{system | closes: system.closes ++ [target]})

      {:mapper, job, counter, pid} ->
        # The counter of the value of the read `job`.
        assert counter == job - 1
        take_messages(put_in(system.mappers[job], pid))
    after
      0 -> system
    end
  end

  defp assert_same_state(model, system) do
    state = SpecModel.to_map(model)

    for call <- @calls, state["called"][call] != "none" do
      expected = {state["answer"][call], state["got"][call]}
      assert result(system.promises[call]) == expected, "#{call} in #{inspect(state)}"
    end

    assert length(system.reads) == state["reads"]
    assert length(system.closes) == state["closes"]
    assert Process.alive?(system.helper.pid) == state["alive"]

    mapping = for {"map", job} <- Enum.with_index(state["phase"], 1), do: job
    running = system.mappers |> Map.keys() |> Enum.reject(&MapSet.member?(system.ended, &1))

    # A job whose callback ended, or that the owner stopped, has no process.
    for job <- system.ended, do: refute(Process.alive?(system.mappers[job]))
    assert Enum.sort(running) == mapping
  end

  defp result(promise) do
    case Promise.peek(promise) do
      :pending -> {"none", 0}
      {:fulfilled, %{done: false, value: job}} -> {"value", job}
      {:fulfilled, %{done: true}} -> {"done", 0}
      {:rejected, _reason} -> {"error", 0}
    end
  end
end
