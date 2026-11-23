defmodule Web.TLA.AsyncBufferedConformanceTest do
  # Compares the real helper `Web.AsyncIterator.buffered/3` with the
  # specification `tla/AsyncBuffered.tla`, with three calls, a limit of 2,
  # and each value of `prepopulate`.
  #
  # The test is the source of the helper (see `Web.Test.ScriptedIterator`):
  # it gets each read and each close, and it gives their outcomes. A read
  # gives its number as its value. The test makes a random walk of the
  # operations that the specification permits: the calls of `next/1` and
  # `return/1`, the answers of the source, and the end of a close. It does
  # each operation on the real helper and on the specification, and it
  # compares the results of the calls, the reads, the reads that run, the
  # closes, and the life of the process.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.AsyncIterator
  alias Web.Promise
  alias Web.Test.ScriptedIterator, as: Script
  alias Web.Test.SpecModel

  @calls ["c1", "c2", "c3"]
  @steps [
    {"StartAhead", []},
    {"StartForward", []},
    {"EndUnmatched", []},
    {"Deliver", []},
    {"StartClose", []},
    {"Stop", []}
  ]

  defp config(prepopulate) do
    [
      {~s(Calls = {"c1", "c2"}), ~s(Calls = {"c1", "c2", "c3"})},
      {"MaxReads = 4", "MaxReads = 5"},
      {"Prepopulate = FALSE", "Prepopulate = #{String.upcase(to_string(prepopulate))}"}
    ]
  end

  # Each command is two random numbers: the first chooses an operation among
  # the operations that the specification permits, with their weights, and
  # the second chooses its argument.
  defp commands, do: list_of(tuple({integer(0..9_999), integer(0..9_999)}), max_length: 24)

  defp choose(model, {pick, argument}) do
    state = SpecModel.to_map(model)
    uncalled = for call <- @calls, state["called"][call] == "none", do: call

    running =
      for read <- 1..state["reads"]//1,
          Enum.at(state["res"], read - 1) == "none",
          o <- ~w(value value end error),
          do: {:answer, read, o}

    closing =
      if state["closer"] != "none", do: [{:close_end, "ok"}, {:close_end, "fail"}], else: []

    [
      {10, Enum.map(uncalled, &{:call, &1, "CallNext"})},
      {2, Enum.map(uncalled, &{:call, &1, "CallReturn"})},
      {10, running},
      {4, closing}
    ]
    |> Enum.reject(fn {_weight, choices} -> choices == [] end)
    |> pick_option(pick, argument)
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
    check all(prepopulate <- boolean(), commands <- commands(), max_runs: 200) do
      system = start_system(prepopulate)

      try do
        model =
          "AsyncBuffered"
          |> SpecModel.start(config(prepopulate))
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
  # The real system: an owner that makes the helper, with the test as source
  # ---------------------------------------------------------------------------

  defp start_system(prepopulate) do
    flush()
    test = self()
    source = Script.new()

    owner =
      spawn(fn ->
        send(test, {:helper, AsyncIterator.buffered(source, 2, prepopulate)})
        Process.sleep(:infinity)
      end)

    assert_receive {:helper, helper}
    %{owner: owner, helper: helper, promises: %{}, reads: [], open: MapSet.new(), closes: []}
  end

  defp stop_system(system) do
    monitor = Process.monitor(system.helper.pid)
    Process.exit(system.owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
  end

  # The steps of an earlier run.
  defp flush do
    receive do
      {:"$web_async_iterator", _step, _target} -> flush()
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

  defp run({:answer, read, outcome}, model, system) do
    target = Enum.at(system.reads, read - 1)

    case outcome do
      "value" -> Script.give(target, read)
      "end" -> Script.finish(target)
      "error" -> Script.fail(target, {:source_error, read})
    end

    system = %{system | open: MapSet.delete(system.open, target)}
    {SpecModel.step!(model, "Answer", [read, outcome]), system}
  end

  defp run({:close_end, outcome}, model, system) do
    target = List.last(system.closes)

    case outcome do
      "ok" -> Script.finish(target)
      "fail" -> Script.fail(target, :close_error)
    end

    {SpecModel.step!(model, "CloseEnd", [outcome]), system}
  end

  defp run(:none, model, system), do: {model, system}

  # ---------------------------------------------------------------------------
  # The observation of the real system
  # ---------------------------------------------------------------------------

  defp observe(system) do
    Script.settle([system.helper.pid | Enum.map(system.promises, fn {_call, p} -> p.pid end)])
    take_messages(system)
  end

  defp take_messages(system) do
    receive do
      {:"$web_async_iterator", :next, target} ->
        take_messages(%{
          system
          | reads: system.reads ++ [target],
            open: MapSet.put(system.open, target)
        })

      {:"$web_async_iterator", {:return, _value}, target} ->
        take_messages(%{system | closes: system.closes ++ [target]})
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
    running = state["res"] |> Enum.take(state["reads"]) |> Enum.count(&(&1 == "none"))
    assert MapSet.size(system.open) == running
    assert length(system.closes) == state["closes"]
    assert Process.alive?(system.helper.pid) == state["alive"]
  end

  defp result(promise) do
    case Promise.peek(promise) do
      :pending -> {"none", 0}
      {:fulfilled, %{done: false, value: read}} -> {"value", read}
      {:fulfilled, %{done: true}} -> {"done", 0}
      {:rejected, _reason} -> {"error", 0}
    end
  end
end
