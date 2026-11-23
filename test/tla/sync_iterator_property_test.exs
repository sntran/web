defmodule Web.TLA.SyncIteratorPropertyTest do
  # Checks the properties of `tla/SyncIterator.tla` on the real
  # `Web.Iterator`. The iterator 1 reads an endless enumerable, the iterator
  # 2 maps the iterator 1, and the iterator 3 maps the iterator 2. The mapper
  # of the iterator `i` calls `next/1` of the iterator `plan[i]`, or of no
  # iterator (0). A test cannot control each step of the processes: thus it
  # checks the result of each call.
  #
  #   * AllAnswered: each call returns. A call that would wait for itself
  #     raises `Web.TypeError`, as GeneratorValidate: a call fails exactly
  #     when its steps call an iterator that runs in their own chain.
  #   * With two users and a plan with no cycle (Acyclic), a call of an
  #     iterator that runs for the other user waits, and it does not fail
  #     (NoFalseError).
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Iterator

  # The time limit of a call that does not return: a call returns in
  # microseconds.
  @limit 5_000

  defp build(plan) do
    {:ok, holder} = Agent.start_link(fn -> %{} end)

    mapper = fn index ->
      fn value ->
        call_target(holder, Map.fetch!(plan, index))
        value
      end
    end

    one = Iterator.from(Stream.iterate(0, &(&1 + 1)))
    two = Iterator.map(one, mapper.(2))
    three = Iterator.map(two, mapper.(3))
    iterators = %{1 => one, 2 => two, 3 => three}
    Agent.update(holder, fn _empty -> iterators end)
    iterators
  end

  defp call_target(_holder, 0), do: :ok
  defp call_target(holder, target), do: Iterator.next(Agent.get(holder, &Map.fetch!(&1, target)))

  defp call(iterators, index) do
    Task.async(fn ->
      try do
        {:value, Iterator.next(Map.fetch!(iterators, index))}
      rescue
        error in Web.TypeError -> {:error, error}
      end
    end)
  end

  defp result(task) do
    case Task.yield(task, @limit) do
      {:ok, result} -> result
      nil -> flunk("the call did not return: the processes wait for each other")
    end
  end

  # TRUE when the steps of a call of the iterator `index` call an iterator
  # of their own chain: its source, and then the target of its mapper.
  defp fails?(_plan, 0, _chain), do: false

  defp fails?(plan, index, chain) do
    index in chain or
      Enum.any?([index - 1, Map.get(plan, index, 0)], &fails?(plan, &1, [index | chain]))
  end

  property "each call returns, and fails only when it would wait for itself" do
    check all(
            plan <- fixed_map(%{2 => integer(0..3), 3 => integer(0..3)}),
            index <- integer(1..3),
            max_runs: 100
          ) do
      iterators = build(plan)
      result = iterators |> call(index) |> result()

      if fails?(plan, index, []) do
        assert {:error, %Web.TypeError{message: "The iterator runs" <> _}} = result
      else
        assert {:value, %{done: false}} = result
      end
    end
  end

  property "with two users and no cycle, a call waits for the step of the other user" do
    check all(
            plan <- fixed_map(%{2 => integer(0..1), 3 => integer(0..2)}),
            first <- integer(1..3),
            second <- integer(1..3),
            max_runs: 100
          ) do
      iterators = build(plan)
      tasks = [call(iterators, first), call(iterators, second)]

      for task <- tasks do
        assert {:value, %{done: false}} = result(task)
      end
    end
  end
end
