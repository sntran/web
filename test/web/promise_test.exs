defmodule Web.PromiseTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.AsyncContext.Variable
  alias Web.Promise
  alias Web.TypeError

  doctest Web.Promise

  # Returns a promise that is fulfilled with `value` after `ms` milliseconds.
  defp later(value, ms) do
    Promise.new(fn resolve, _reject ->
      Process.sleep(ms)
      resolve.(value)
    end)
  end

  # Returns a promise that is rejected with `reason` after `ms` milliseconds.
  defp later_rejection(reason, ms) do
    Promise.new(fn _resolve, reject ->
      Process.sleep(ms)
      reject.(reason)
    end)
  end

  defp assert_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
  end

  describe "AggregateError" do
    test "the message contains the list of errors" do
      error = %Web.AggregateError{errors: [:a, :b]}
      assert Exception.message(error) =~ "All promises were rejected"
      assert Exception.message(error) =~ ":a"
    end
  end

  describe "resolve/1 and reject/1" do
    test "resolve/1 gives a fulfilled promise without a process" do
      promise = Promise.resolve(:hello)
      assert promise.pid == nil
      assert await(promise) == :hello
    end

    test "resolve/1 returns an input promise without a change" do
      original = Promise.resolve(99)
      assert Promise.resolve(original) == original
    end

    test "reject/1 gives a rejected promise without a process" do
      promise = Promise.reject(:bad)
      assert promise.pid == nil
      assert catch_exit(await(promise)) == :bad
    end

    test "the value {:error, reason} is a usual value" do
      assert await(Promise.resolve({:error, :not_a_rejection})) == {:error, :not_a_rejection}
    end
  end

  describe "new/2" do
    test "the executor can resolve immediately" do
      assert await(Promise.new(fn resolve, _reject -> resolve.(1) end)) == 1
    end

    test "the executor can reject immediately" do
      promise = Promise.new(fn _resolve, reject -> reject.(:no) end)
      assert catch_exit(await(promise)) == :no
    end

    test "a different process can resolve the promise after the executor returns" do
      promise =
        Promise.new(fn resolve, _reject ->
          executor = self()

          # The other process resolves the promise after the executor stopped.
          spawn(fn ->
            monitor = Process.monitor(executor)

            receive do
              {:DOWN, ^monitor, :process, ^executor, _reason} -> resolve.(:late)
            end
          end)
        end)

      assert await(promise) == :late
    end

    test "the promise stays pending when the executor returns and does not settle it" do
      parent = self()
      promise = Promise.new(fn _resolve, _reject -> send(parent, {:executor, self()}) end)

      # The executor stopped before the peek.
      assert_receive {:executor, executor}
      assert_down(executor)
      assert Promise.peek(promise) == :pending
    end

    test "only the first settlement has an effect" do
      promise =
        Promise.new(fn resolve, reject ->
          resolve.(:first)
          reject.(:second)
          resolve.(:third)
        end)

      assert await(promise) == :first
    end

    test "an executor that raises rejects the promise with the exception" do
      promise = Promise.new(fn _resolve, _reject -> raise "executor failure" end)
      assert %RuntimeError{message: "executor failure"} = catch_exit(await(promise))
    end

    test "an executor that throws rejects the promise with the thrown value" do
      promise = Promise.new(fn _resolve, _reject -> throw(:thrown) end)
      assert catch_exit(await(promise)) == :thrown
    end

    test "an executor that exits rejects the promise with the exit reason" do
      promise = Promise.new(fn _resolve, _reject -> exit(:stopped) end)
      assert catch_exit(await(promise)) == :stopped
    end

    test "an executor that is killed rejects the promise" do
      parent = self()

      promise =
        Promise.new(fn _resolve, _reject ->
          send(parent, {:executor, self()})
          Process.sleep(:infinity)
        end)

      assert_receive {:executor, executor}
      Process.exit(executor, :kill)
      assert catch_exit(await(promise)) == :killed
    end

    test "an error after the settlement does not change the outcome" do
      promise =
        Promise.new(fn resolve, _reject ->
          resolve.(:kept)
          raise "too late"
        end)

      assert await(promise) == :kept
    end

    test "a resolve with a fulfilled promise takes its value" do
      promise = Promise.new(fn resolve, _reject -> resolve.(Promise.resolve(:inner)) end)
      assert await(promise) == :inner
    end

    test "a resolve with a rejected promise takes its reason" do
      promise = Promise.new(fn resolve, _reject -> resolve.(Promise.reject(:inner_fail)) end)
      assert catch_exit(await(promise)) == :inner_fail
    end

    test "a resolve with a pending promise takes its later outcome" do
      promise = Promise.new(fn resolve, _reject -> resolve.(later(:inner_later, 20)) end)
      assert await(promise) == :inner_later
    end

    test "a promise that resolves to itself rejects with TypeError" do
      {promise, resolve, _reject} = Promise.with_resolvers()
      resolve.(promise)

      assert %TypeError{message: "A promise cannot resolve to itself."} =
               catch_exit(await(promise))
    end

    test "the executor gets the AsyncContext values of the caller" do
      variable = Variable.new(name: "promise_new_context")

      promise =
        Variable.run(variable, :from_caller, fn ->
          Promise.new(fn resolve, _reject -> resolve.(Variable.get(variable)) end)
        end)

      assert await(promise) == :from_caller
    end
  end

  describe "with_resolvers/1" do
    test "the resolve function fulfills the promise" do
      {promise, resolve, _reject} = Promise.with_resolvers()
      assert resolve.(:hello) == :ok
      assert await(promise) == :hello
    end

    test "the reject function rejects the promise" do
      {promise, _resolve, reject} = Promise.with_resolvers()
      assert reject.(:boom) == :ok
      assert catch_exit(await(promise)) == :boom
    end

    test "a different process can settle the promise at a later time" do
      {promise, resolve, _reject} = Promise.with_resolvers()

      # The sleep is part of the scenario: the settle comes after the start
      # of the await.
      spawn(fn ->
        Process.sleep(10)
        resolve.(:later)
      end)

      assert await(promise) == :later
    end

    test "only the first settlement has an effect" do
      {promise, resolve, reject} = Promise.with_resolvers()
      resolve.(:first)
      reject.(:second)
      assert await(promise) == :first
    end
  end

  describe "await/1 and wait/1" do
    test "a process can await a promise more than one time" do
      promise = later(:again, 10)
      assert await(promise) == :again
      assert await(promise) == :again
      assert await(promise) == :again
    end

    test "a different process can await a promise" do
      promise = later(:shared, 10)
      tasks = for _ <- 1..3, do: Task.async(fn -> await(promise) end)
      assert Task.await_many(tasks) == [:shared, :shared, :shared]
      assert await(promise) == :shared
    end

    test "await/1 of Web returns a value that is not a promise" do
      assert await(:not_a_promise) == :not_a_promise
    end

    test "wait/1 returns the outcome as data" do
      assert Promise.wait(Promise.resolve(1)) == {:fulfilled, 1}
      assert Promise.wait(Promise.reject(:no)) == {:rejected, :no}
      assert Promise.wait(later(2, 5)) == {:fulfilled, 2}
      assert Promise.wait(later_rejection(:late_no, 5)) == {:rejected, :late_no}
    end
  end

  describe "then/2" do
    test "it changes the value of a fulfilled promise" do
      assert await(Promise.then(Promise.resolve(2), &(&1 * 3))) == 6
    end

    test "it accepts a value that is not a promise" do
      assert await(Promise.then(2, &(&1 + 1))) == 3
    end

    test "it returns before a pending promise settles" do
      # The promise settles only when the test resolves it.
      {promise, resolve, _reject} = Promise.with_resolvers()
      {microseconds, chained} = :timer.tc(fn -> Promise.then(promise, &(&1 + 1)) end)

      assert microseconds < 100_000
      assert Promise.peek(chained) == :pending
      resolve.(1)
      assert await(chained) == 2
    end

    test "a rejection goes through and the callback does not run" do
      parent = self()

      promise =
        later_rejection(:bad, 5)
        |> Promise.then(fn value ->
          send(parent, :callback_ran)
          value
        end)

      assert catch_exit(await(promise)) == :bad
      refute_received :callback_ran
    end

    test "a settled rejection is returned without a new process" do
      rejected = Promise.reject(:bad)
      assert Promise.then(rejected, & &1) == rejected
    end

    test "a callback that returns a promise gives the outcome of that promise" do
      promise = Promise.then(Promise.resolve("a"), fn value -> later(value <> "b", 5) end)
      assert await(promise) == "ab"
    end

    test "a callback that raises rejects the new promise" do
      promise = Promise.then(Promise.resolve(1), fn _value -> raise "callback failure" end)
      assert %RuntimeError{message: "callback failure"} = catch_exit(await(promise))
    end

    test "many callbacks can use the same promise" do
      promise = later(10, 10)
      first = Promise.then(promise, &(&1 + 1))
      second = Promise.then(promise, &(&1 + 2))
      assert await(first) == 11
      assert await(second) == 12
    end

    test "the callback runs in a different process with the context of the caller" do
      variable = Variable.new(name: "promise_then_context")
      caller = self()

      promise =
        Variable.run(variable, :from_caller, fn ->
          Promise.then(Promise.resolve(:ok), fn _value -> {self(), Variable.get(variable)} end)
        end)

      assert {pid, :from_caller} = await(promise)
      assert pid != caller
    end
  end

  describe "then/3" do
    # A settled or a pending promise with the outcome.
    defp promise_of({:fulfilled, value}, false), do: Promise.resolve(value)
    defp promise_of({:rejected, reason}, false), do: Promise.reject(reason)
    defp promise_of({:fulfilled, value}, true), do: later(value, 1)
    defp promise_of({:rejected, reason}, true), do: later_rejection(reason, 1)

    property "the callback of the state runs, and nil passes the outcome on" do
      check all(
              outcome <-
                one_of([
                  tuple({constant(:fulfilled), term()}),
                  tuple({constant(:rejected), term()})
                ]),
              pending? <- boolean(),
              on_fulfilled? <- boolean(),
              on_rejected? <- boolean(),
              max_runs: 40
            ) do
        on_fulfilled = if on_fulfilled?, do: &{:fulfilled_with, &1}
        on_rejected = if on_rejected?, do: &{:rejected_with, &1}
        promise = Promise.then(promise_of(outcome, pending?), on_fulfilled, on_rejected)

        expected =
          case {outcome, on_fulfilled?, on_rejected?} do
            {{:fulfilled, value}, true, _} -> {:fulfilled, {:fulfilled_with, value}}
            {{:rejected, reason}, _, true} -> {:fulfilled, {:rejected_with, reason}}
            {outcome, _, _} -> outcome
          end

        assert Promise.wait(promise) == expected
      end
    end

    test "on_rejected does not run for a fulfilled promise, and on_fulfilled not for a rejection" do
      parent = self()
      on_fulfilled = fn value -> send(parent, {:on_fulfilled, value}) end
      on_rejected = fn reason -> send(parent, {:on_rejected, reason}) end

      assert await(Promise.then(later(:value, 1), on_fulfilled, on_rejected)) ==
               {:on_fulfilled, :value}

      assert await(Promise.then(later_rejection(:bad, 1), on_fulfilled, on_rejected)) ==
               {:on_rejected, :bad}

      assert_received {:on_fulfilled, :value}
      assert_received {:on_rejected, :bad}
      refute_received _other
    end

    test "an on_rejected that raises rejects the new promise" do
      promise =
        Promise.then(Promise.reject(:err), nil, fn _reason -> raise "callback failure" end)

      assert %RuntimeError{message: "callback failure"} = catch_exit(await(promise))
    end

    test "a settled promise with no callback for its state is returned without a new process" do
      fulfilled = Promise.resolve(:value)
      assert Promise.then(fulfilled, nil, fn _reason -> :fallback end) == fulfilled
      assert Promise.then(fulfilled, nil, nil) == fulfilled
    end
  end

  describe "try/2" do
    test "it calls the function now, in the calling process, with the arguments" do
      parent = self()
      promise = Promise.try(fn a, b -> send(parent, {:called, self(), a + b}) end, [1, 2])

      assert_received {:called, ^parent, 3}
      assert promise == Promise.resolve({:called, parent, 3})
    end

    test "a raise, a throw, and an exit reject the promise with their value" do
      assert %RuntimeError{message: "bad"} = catch_exit(await(Promise.try(fn -> raise "bad" end)))
      assert catch_exit(await(Promise.try(fn -> throw(:thrown) end))) == :thrown
      assert catch_exit(await(Promise.try(fn -> exit(:exited) end))) == :exited
    end

    test "a promise of the function is the result" do
      pending = later(:later, 1)
      assert Promise.try(fn -> pending end) == pending
      assert await(Promise.try(fn -> pending end)) == :later
    end
  end

  describe "catch/2" do
    test "nil is undefined: the outcome goes through" do
      assert Promise.catch(Promise.reject(:bad), nil) == Promise.reject(:bad)
      assert catch_exit(await(Promise.catch(later_rejection(:bad, 1), nil))) == :bad
      assert await(Promise.catch(later(:value, 1), nil)) == :value
    end

    test "it recovers from a rejection" do
      promise = Promise.catch(Promise.reject(:boom), fn reason -> {:recovered, reason} end)
      assert await(promise) == {:recovered, :boom}
    end

    test "it recovers from a rejection of a pending promise" do
      promise = Promise.catch(later_rejection(:boom, 5), fn reason -> {:recovered, reason} end)
      assert await(promise) == {:recovered, :boom}
    end

    test "a fulfilled value goes through" do
      assert await(Promise.catch(later(:value, 5), fn _reason -> :fallback end)) == :value
    end

    test "a settled fulfilled promise is returned without a new process" do
      fulfilled = Promise.resolve(:value)
      assert Promise.catch(fulfilled, fn _reason -> :fallback end) == fulfilled
    end

    test "a callback that returns a promise gives the outcome of that promise" do
      promise = Promise.catch(Promise.reject(:err), fn _reason -> Promise.resolve(:recovered) end)
      assert await(promise) == :recovered
    end

    test "a callback that raises rejects the new promise" do
      promise = Promise.catch(Promise.reject(:err), fn _reason -> raise "callback failure" end)
      assert %RuntimeError{} = catch_exit(await(promise))
    end
  end

  describe "finally/2" do
    test "nil is undefined: the outcome goes through" do
      assert Promise.finally(Promise.resolve(:value), nil) == Promise.resolve(:value)
      assert await(Promise.finally(later(:value, 1), nil)) == :value
      assert catch_exit(await(Promise.finally(later_rejection(:bad, 1), nil))) == :bad
    end

    test "it runs the callback and keeps a fulfilled value" do
      parent = self()
      promise = Promise.finally(later(:value, 5), fn -> send(parent, :cleanup) end)
      assert await(promise) == :value
      assert_received :cleanup
    end

    test "it runs the callback and keeps a rejection" do
      parent = self()
      promise = Promise.finally(Promise.reject(:bad), fn -> send(parent, :cleanup) end)
      assert catch_exit(await(promise)) == :bad
      assert_received :cleanup
    end

    test "a callback that raises rejects the new promise" do
      promise = Promise.finally(Promise.resolve(:value), fn -> raise "cleanup failure" end)
      assert %RuntimeError{message: "cleanup failure"} = catch_exit(await(promise))
    end

    test "a callback that returns a rejected promise rejects the new promise" do
      promise = Promise.finally(Promise.resolve(:value), fn -> Promise.reject(:cleanup_bad) end)
      assert catch_exit(await(promise)) == :cleanup_bad
    end
  end

  describe "all/1" do
    test "it gives the values in the order of the input" do
      assert await(Promise.all([later(1, 30), 2, later(3, 5)])) == [1, 2, 3]
    end

    test "settled input gives a settled promise without a process" do
      promise = Promise.all([Promise.resolve(1), 2])
      assert promise.pid == nil
      assert await(promise) == [1, 2]
    end

    test "an empty input gives an empty list" do
      assert await(Promise.all([])) == []
    end

    test "it rejects with a settled rejection" do
      promise = Promise.all([Promise.resolve(1), Promise.reject(:fail), Promise.resolve(3)])
      assert catch_exit(await(promise)) == :fail
    end

    test "it rejects at the first rejection and does not wait for the other promises" do
      promise = Promise.all([later(:slow, 2_000), later_rejection(:fast_fail, 10)])
      {microseconds, reason} = :timer.tc(fn -> catch_exit(await(promise)) end)

      assert reason == :fast_fail
      assert microseconds < 1_000_000
    end

    test "the value {:error, reason} does not reject" do
      assert await(Promise.all([{:error, :value}, later(1, 5)])) == [{:error, :value}, 1]
    end
  end

  describe "all_settled/1" do
    test "it gives each outcome in the order of the input" do
      results = await(Promise.all_settled([later(:ok, 10), later_rejection(:err, 5), :plain]))

      assert results == [
               %{status: "fulfilled", value: :ok},
               %{status: "rejected", reason: :err},
               %{status: "fulfilled", value: :plain}
             ]
    end

    test "the value {:error, reason} is fulfilled" do
      assert await(Promise.all_settled([Promise.resolve({:error, :value})])) ==
               [%{status: "fulfilled", value: {:error, :value}}]
    end

    test "an empty input gives an empty list" do
      assert await(Promise.all_settled([])) == []
    end
  end

  describe "any/1" do
    test "it gives the first value that is fulfilled" do
      # The slow promise does not settle. Thus no time limit decides the
      # first value.
      {slow, _resolve, _reject} = Promise.with_resolvers()
      promise = Promise.any([later_rejection(:e1, 5), slow, later(:fast, 20)])
      assert await(promise) == :fast
    end

    test "it prefers a settled value" do
      assert await(Promise.any([later(:pending, 50), Promise.reject(:e), :settled])) == :settled
    end

    test "it rejects with AggregateError when all promises reject" do
      promise = Promise.any([later_rejection(:a, 10), Promise.reject(:b)])
      assert %Web.AggregateError{errors: [:a, :b]} = catch_exit(await(promise))
    end

    test "an empty input rejects with AggregateError" do
      assert %Web.AggregateError{errors: []} = catch_exit(await(Promise.any([])))
    end
  end

  describe "race/1" do
    # The slow promise of these tests does not settle. Thus no time limit
    # decides the first outcome.
    test "it gives the outcome of the first promise that settles" do
      {slow, _resolve, _reject} = Promise.with_resolvers()
      assert await(Promise.race([slow, later(:fast, 10)])) == :fast
    end

    test "it rejects when the first promise that settles is rejected" do
      {slow, _resolve, _reject} = Promise.with_resolvers()
      promise = Promise.race([slow, later_rejection(:fast_fail, 10)])
      assert catch_exit(await(promise)) == :fast_fail
    end

    test "it prefers a settled promise" do
      assert await(Promise.race([later(:pending, 50), :settled])) == :settled
    end

    test "the other promises continue" do
      parent = self()

      # The slow executor continues when the test lets it.
      slow =
        Promise.new(fn resolve, _reject ->
          send(parent, {:slow, self()})

          receive do
            :continue -> resolve.(:slow)
          end
        end)

      assert await(Promise.race([slow, later(:fast, 5)])) == :fast
      assert_receive {:slow, executor}
      send(executor, :continue)
      assert await(slow) == :slow
    end

    test "an empty input stays pending" do
      promise = Promise.race([])

      # The promise has no executor: no process can settle it. Thus the
      # check needs no wait.
      assert Process.info(promise.pid, :links) == {:links, []}
      assert Promise.peek(promise) == :pending
    end
  end

  describe "lifetime" do
    test "a pending promise and its executor stop when the owner stops" do
      parent = self()

      owner =
        spawn(fn ->
          promise =
            Promise.new(fn _resolve, _reject ->
              send(parent, {:executor, self()})
              Process.sleep(:infinity)
            end)

          send(parent, {:promise, promise})
          Process.sleep(:infinity)
        end)

      assert_receive {:promise, promise}
      assert_receive {:executor, executor}

      Process.exit(owner, :kill)

      assert_down(promise.pid)
      assert_down(executor)
      assert %TypeError{} = catch_exit(await(promise))
    end

    test "a settled promise stops when the owner stops" do
      parent = self()

      owner =
        spawn(fn ->
          send(parent, {:promise, Promise.new(fn resolve, _reject -> resolve.(1) end)})
          Process.sleep(:infinity)
        end)

      assert_receive {:promise, promise}
      assert await(promise) == 1

      Process.exit(owner, :kill)
      assert_down(promise.pid)
    end

    test "a detached executor continues to its end when the owner stops" do
      parent = self()

      owner =
        spawn(fn ->
          promise =
            Promise.__new__(
              fn resolve, _reject ->
                send(parent, {:executor, self()})

                receive do
                  :continue -> send(parent, :executor_completed)
                end

                resolve.(:done)
              end,
              detached: true
            )

          send(parent, {:promise, promise})
        end)

      assert_receive {:promise, promise}
      assert_receive {:executor, executor}
      assert_down(owner)
      assert Process.alive?(promise.pid)

      send(executor, :continue)

      assert_receive :executor_completed
      assert_down(promise.pid)
    end

    test "a promise made in an executor has the owner of the first promise" do
      outer =
        Promise.new(fn resolve, _reject ->
          resolve.(%{inner: later(:inner_value, 30)})
        end)

      # The executor of `outer` stopped. The inner promise continues, because
      # its owner is the test process.
      assert %{inner: inner} = await(outer)
      assert await(inner) == :inner_value
    end

    test "an outcome that was not delivered stays available" do
      promise = Promise.__new__(fn resolve, _reject -> resolve.(:kept) end, linger: 10)

      # The wait is longer than the linger time. This negative check has no
      # other end than a time limit.
      monitor = Process.monitor(promise.pid)
      refute_receive {:DOWN, ^monitor, :process, _pid, _reason}, 60
      assert await(promise) == :kept
    end

    test "a promise stops when the linger time after the first delivery is completed" do
      promise = Promise.__new__(fn resolve, _reject -> resolve.(:value) end, linger: 20)

      assert await(promise) == :value
      assert await(promise) == :value
      assert_down(promise.pid)

      assert %TypeError{message: message} = catch_exit(await(promise))
      assert message =~ "The promise is not available"
      assert inspect(promise) == "#Web.Promise<released>"
    end

    test "a chained promise on a released promise rejects with TypeError" do
      promise = Promise.__new__(fn resolve, _reject -> resolve.(:value) end, linger: 0)
      assert await(promise) == :value
      assert_down(promise.pid)

      assert %TypeError{} = catch_exit(await(Promise.then(promise, & &1)))
      assert %TypeError{} = catch_exit(await(Promise.all([promise])))
      assert %TypeError{} = catch_exit(await(Promise.new(fn resolve, _ -> resolve.(promise) end)))
    end

    test "the linger time :infinity keeps the outcome until the owner stops" do
      {promise, resolve, _reject} = Promise.__with_resolvers__(linger: :infinity)
      resolve.(:kept)

      assert await(promise) == :kept

      # The outcome stays after a delivery. This negative check has no other
      # end than a time limit.
      monitor = Process.monitor(promise.pid)
      refute_receive {:DOWN, ^monitor, :process, _pid, _reason}, 30
      assert await(promise) == :kept
    end

    test "a promise stops when it gets an exit signal" do
      {promise, _resolve, _reject} = Promise.with_resolvers()

      Process.exit(promise.pid, :shutdown)

      assert_down(promise.pid)
      assert %TypeError{} = catch_exit(await(promise))
    end

    test "a promise ignores messages that it does not know" do
      {promise, resolve, _reject} = Promise.with_resolvers()
      send(promise.pid, :unknown_message)
      send(promise.pid, {:settle, make_ref(), {:fulfilled, :wrong_token}})
      resolve.(:correct)
      assert await(promise) == :correct
    end

    test "a promise and its executor stop when the supervisor stops the promise" do
      parent = self()

      promise =
        Promise.new(fn _resolve, _reject ->
          send(parent, {:executor, self()})
          Process.sleep(:infinity)
        end)

      assert_receive {:executor, executor}
      monitors = Enum.map([promise.pid, executor], &Process.monitor/1)

      # The supervisor of the application stops its processes with this
      # signal.
      Process.exit(promise.pid, :shutdown)

      for monitor <- monitors do
        assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
      end
    end
  end

  describe "Inspect" do
    test "a pending promise" do
      {promise, _resolve, _reject} = Promise.with_resolvers()
      assert inspect(promise) == "#Web.Promise<pending>"
    end

    test "a promise that waits for a different promise is pending" do
      {inner, _resolve, _reject} = Promise.with_resolvers()
      {outer, resolve, _reject} = Promise.with_resolvers()
      resolve.(inner)
      assert inspect(outer) == "#Web.Promise<pending>"
    end

    test "a fulfilled promise" do
      assert inspect(Promise.resolve(42)) == "#Web.Promise<resolved: 42>"

      promise = later(15, 1)
      assert await(promise) == 15
      assert inspect(promise) == "#Web.Promise<resolved: 15>"
    end

    test "a rejected promise" do
      assert inspect(Promise.reject(:bad)) == "#Web.Promise<rejected: :bad>"
    end
  end
end
