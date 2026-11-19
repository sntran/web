defmodule Web.PromiseLeakTest do
  # These tests count the processes of the VM. Thus they cannot run at the
  # same time as other tests.
  use ExUnit.Case, async: false

  import Web, only: [await: 1]

  alias Web.Promise

  @count 2_000
  @tolerance 20
  # A short linger time, thus the tests do not wait for the default time.
  @linger 100

  setup do
    previous = Application.get_env(:web, :promise_linger)
    Application.put_env(:web, :promise_linger, @linger)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:web, :promise_linger)
      else
        Application.put_env(:web, :promise_linger, previous)
      end
    end)
  end

  defp process_count, do: :erlang.system_info(:process_count)

  # Waits until the process count is near `baseline`, and returns the last
  # difference.
  defp settle(baseline, attempts \\ 100) do
    difference = process_count() - baseline

    if difference <= @tolerance or attempts == 0 do
      difference
    else
      Process.sleep(20)
      settle(baseline, attempts - 1)
    end
  end

  test "settled promises start no process" do
    baseline = process_count()

    for index <- 1..@count do
      assert await(Promise.resolve(index)) == index
      assert catch_exit(await(Promise.reject(index))) == index
    end

    assert process_count() - baseline <= @tolerance
  end

  test "a process that stays alive does not keep the promises that it awaited" do
    baseline = process_count()

    for index <- 1..@count do
      assert await(Promise.new(fn resolve, _reject -> resolve.(index) end)) == index
    end

    assert settle(baseline) <= @tolerance
  end

  test "a process that stays alive does not keep awaited chains and combinators" do
    baseline = process_count()

    for index <- 1..div(@count, 10) do
      first = Promise.new(fn resolve, _reject -> resolve.(index) end)
      second = Promise.then(first, &(&1 + 1))
      third = Promise.catch(second, fn _reason -> :not_used end)

      assert await(Promise.all([first, second, third])) == [index, index + 1, index + 1]
      assert await(Promise.race([first, second])) in [index, index + 1]
    end

    assert settle(baseline) <= @tolerance
  end

  test "pending promises stop when their owner stops" do
    baseline = process_count()
    parent = self()

    owner =
      spawn(fn ->
        for _ <- 1..@count do
          Promise.new(fn _resolve, _reject -> Process.sleep(:infinity) end)
        end

        send(parent, :promises_started)
        Process.sleep(:infinity)
      end)

    assert_receive :promises_started, 5_000
    assert process_count() - baseline >= @count

    Process.exit(owner, :kill)
    assert settle(baseline) <= @tolerance
  end
end
