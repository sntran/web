defmodule Web.PromisePropertyTest do
  # Properties of `Web.Promise` for random inputs. Each input promise is
  # settled at creation, or it settles after a short random time.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.Promise

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp outcome do
    one_of([
      tuple({constant(:fulfilled), integer()}),
      tuple({constant(:rejected), integer()})
    ])
  end

  # A description of a promise: its outcome, and the time before it settles.
  # The time `:settled` gives a promise that is settled at creation.
  defp spec do
    tuple({outcome(), one_of([constant(:settled), integer(0..3)])})
  end

  defp build({{:fulfilled, value}, :settled}), do: Promise.resolve(value)
  defp build({{:rejected, reason}, :settled}), do: Promise.reject(reason)

  defp build({outcome, delay}) do
    Promise.new(fn resolve, reject ->
      Process.sleep(delay)

      case outcome do
        {:fulfilled, value} -> resolve.(value)
        {:rejected, reason} -> reject.(reason)
      end
    end)
  end

  defp outcomes(specs), do: Enum.map(specs, &elem(&1, 0))

  # ---------------------------------------------------------------------------
  # One promise
  # ---------------------------------------------------------------------------

  property "wait/1 gives the outcome of the promise" do
    check all({outcome, _delay} = spec <- spec()) do
      assert Promise.wait(build(spec)) == outcome
    end
  end

  property "each process gets the same outcome, each time" do
    check all(
            {outcome, _delay} = spec <- spec(),
            processes <- integer(1..4),
            repeats <- integer(1..3),
            max_runs: 50
          ) do
      promise = build(spec)

      tasks =
        for _ <- 1..processes do
          Task.async(fn -> for _ <- 1..repeats, do: Promise.wait(promise) end)
        end

      for results <- Task.await_many(tasks), result <- results do
        assert result == outcome
      end
    end
  end

  property "only the first settlement has an effect" do
    check all(settlements <- list_of(outcome(), min_length: 1, max_length: 6)) do
      {promise, resolve, reject} = Promise.with_resolvers()

      for {status, value} <- settlements do
        if status == :fulfilled, do: resolve.(value), else: reject.(value)
      end

      assert Promise.wait(promise) == hd(settlements)
    end
  end

  # ---------------------------------------------------------------------------
  # Chains
  # ---------------------------------------------------------------------------

  property "a chain of then/2 gives the composition of its functions" do
    check all(
            {outcome, _delay} = spec <- spec(),
            numbers <- list_of(integer(-5..5), max_length: 5)
          ) do
      chained =
        Enum.reduce(numbers, build(spec), fn n, promise -> Promise.then(promise, &(&1 + n)) end)

      expected =
        case outcome do
          {:fulfilled, value} -> {:fulfilled, value + Enum.sum(numbers)}
          {:rejected, reason} -> {:rejected, reason}
        end

      assert Promise.wait(chained) == expected
    end
  end

  property "catch/2 changes a rejection into a value, and keeps a value" do
    check all({outcome, _delay} = spec <- spec()) do
      recovered = Promise.catch(build(spec), fn reason -> {:recovered, reason} end)

      expected =
        case outcome do
          {:fulfilled, value} -> {:fulfilled, value}
          {:rejected, reason} -> {:fulfilled, {:recovered, reason}}
        end

      assert Promise.wait(recovered) == expected
    end
  end

  property "finally/2 runs its callback one time and keeps the outcome" do
    check all({outcome, _delay} = spec <- spec()) do
      test = self()
      ref = make_ref()
      promise = Promise.finally(build(spec), fn -> send(test, {:finally, ref}) end)

      assert Promise.wait(promise) == outcome
      assert_received {:finally, ^ref}
      refute_received {:finally, ^ref}
    end
  end

  property "then/2 with a callback that returns a promise gives the outcome of that promise" do
    check all(first <- spec(), {second_outcome, _delay} = second <- spec()) do
      chained = Promise.then(build(first), fn _value -> build(second) end)

      expected =
        case elem(first, 0) do
          {:fulfilled, _value} -> second_outcome
          {:rejected, reason} -> {:rejected, reason}
        end

      assert Promise.wait(chained) == expected
    end
  end

  # ---------------------------------------------------------------------------
  # Combinators
  # ---------------------------------------------------------------------------

  property "all_settled/1 gives each outcome in the sequence of the input" do
    check all(specs <- list_of(spec(), max_length: 6)) do
      expected =
        Enum.map(outcomes(specs), fn
          {:fulfilled, value} -> %{status: "fulfilled", value: value}
          {:rejected, reason} -> %{status: "rejected", reason: reason}
        end)

      assert await(Promise.all_settled(Enum.map(specs, &build/1))) == expected
    end
  end

  property "all/1 gives all the values, or the reason of a rejected input" do
    check all(specs <- list_of(spec(), max_length: 6)) do
      result = Promise.wait(Promise.all(Enum.map(specs, &build/1)))
      rejections = for {:rejected, reason} <- outcomes(specs), do: reason

      if rejections == [] do
        assert result == {:fulfilled, for({:fulfilled, value} <- outcomes(specs), do: value)}
      else
        assert {:rejected, reason} = result
        assert reason in rejections
      end
    end
  end

  property "all/1 with settled input rejects with the first rejection of the input" do
    check all(outcomes <- list_of(outcome(), max_length: 6)) do
      promises = Enum.map(outcomes, &build({&1, :settled}))
      first_rejection = Enum.find(outcomes, &match?({:rejected, _}, &1))

      if first_rejection do
        assert Promise.wait(Promise.all(promises)) == first_rejection
      else
        assert Promise.wait(Promise.all(promises)) ==
                 {:fulfilled, Enum.map(outcomes, &elem(&1, 1))}
      end
    end
  end

  property "any/1 gives a fulfilled value, or all the reasons in the sequence of the input" do
    check all(specs <- list_of(spec(), max_length: 6)) do
      result = Promise.wait(Promise.any(Enum.map(specs, &build/1)))
      values = for {:fulfilled, value} <- outcomes(specs), do: value

      if values == [] do
        reasons = for {:rejected, reason} <- outcomes(specs), do: reason
        assert result == {:rejected, %Promise.AggregateError{errors: reasons}}
      else
        assert {:fulfilled, value} = result
        assert value in values
      end
    end
  end

  property "race/1 gives the outcome of one of its inputs" do
    check all(specs <- list_of(spec(), min_length: 1, max_length: 6)) do
      assert Promise.wait(Promise.race(Enum.map(specs, &build/1))) in outcomes(specs)
    end
  end

  property "race/1 with a settled input gives the first settled input" do
    check all(
            before <- list_of(tuple({outcome(), integer(20..40)}), max_length: 3),
            settled <- outcome(),
            rest <- list_of(spec(), max_length: 3)
          ) do
      promises = Enum.map(before ++ [{settled, :settled}] ++ rest, &build/1)
      assert Promise.wait(Promise.race(promises)) == settled
    end
  end

  property "a value that is not a promise is the same as a fulfilled promise" do
    value = one_of([integer(), tuple({constant(:error), integer()})])

    check all(values <- list_of(value, max_length: 5)) do
      assert await(Promise.all(values)) == values

      assert await(Promise.all_settled(values)) ==
               Enum.map(values, &%{status: "fulfilled", value: &1})
    end
  end
end
