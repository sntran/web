defmodule Web.IteratorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.AsyncContext.Variable
  alias Web.AsyncIterator
  alias Web.Iterator
  alias Web.Promise
  alias Web.RangeError
  alias Web.Test.ScriptedIterator, as: Script
  alias Web.TypeError

  doctest Web.Iterator

  defp value(value), do: %{value: value, done: false}
  defp done, do: %{value: nil, done: true}

  # A stream with the after function of `Stream.resource/3`: the test gets
  # `{:closed, name}` when the enumerable halts.
  defp closable(values, name \\ :source) do
    test = self()

    Stream.resource(
      fn -> values end,
      fn
        [] -> {:halt, []}
        [value | rest] -> {[value], rest}
      end,
      fn _rest -> send(test, {:closed, name}) end
    )
  end

  # An enumerable whose after function raises.
  defp failing_close(values) do
    Stream.resource(fn -> values end, &step/1, fn _rest -> raise "close failed" end)
  end

  defp step([]), do: {:halt, []}
  defp step([value | rest]), do: {[value], rest}

  # A callback that raises, throws, or exits with `reason`.
  defp failing(:raise), do: fn _value -> raise ArgumentError, "callback failed" end
  defp failing(:throw), do: fn _value -> throw(:callback_thrown) end
  defp failing(:exit), do: fn _value -> exit(:callback_exited) end

  defp failure(:raise), do: {:error, %ArgumentError{message: "callback failed"}}
  defp failure(:throw), do: {:throw, :callback_thrown}
  defp failure(:exit), do: {:exit, :callback_exited}

  defp caught(fun) do
    fun.()
    :no_error
  catch
    :error, %ArgumentError{} = error -> {:error, error}
    kind, reason -> {kind, reason}
  end

  # Examines the condition until it is true, for a state of a different
  # process that no message tells.
  defp eventually(fun, attempts \\ 500) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition is not true")
      true -> Process.sleep(2) && eventually(fun, attempts - 1)
    end
  end

  defp assert_down(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
  end

  describe "from/1" do
    property "gives the elements of an enumerable, and then the end" do
      check all(values <- list_of(term(), max_length: 8)) do
        iterator = Iterator.from(values)

        assert Enum.map(values, fn _value -> Iterator.next(iterator) end) ==
                 Enum.map(values, &value/1)

        assert Iterator.next(iterator) == done()
        assert Iterator.next(iterator) == done()
      end
    end

    test "takes no element before the first next" do
      test = self()
      iterator = Iterator.from(Stream.map([1, 2], &send(test, {:step, &1})))
      Script.settle([iterator.pid])
      refute_received {:step, _value}

      assert Iterator.next(iterator) == value({:step, 1})
      assert_received {:step, 1}
      refute_received {:step, 2}
    end

    test "the code of the enumerable runs in the process of the iterator" do
      iterator = Iterator.from(Stream.map([1], fn _value -> self() end))
      assert Iterator.next(iterator) == value(iterator.pid)
    end

    test "a promise is a value, as in a sync iterator" do
      promise = Promise.resolve(:a)
      assert Iterator.next(Iterator.from([promise])) == value(promise)
    end

    test "an error of the enumerable raises with its kind, and then the iterator is done" do
      for kind <- [:raise, :throw, :exit] do
        iterator = Iterator.from(Stream.map([1, 2], failing(kind)))
        assert caught(fn -> Iterator.next(iterator) end) == failure(kind)
        assert Iterator.next(iterator) == done()
      end
    end

    test "gives the last element of an enumerable that halts itself" do
      iterator = Iterator.from(Stream.take([1, 2, 3], 2))

      assert Enum.map(1..3, fn _call -> Iterator.next(iterator) end) == [
               value(1),
               value(2),
               done()
             ]
    end

    test "return/1 halts the enumerable, and then the iterator is done" do
      iterator = Iterator.from(closable([1, 2]))
      assert Iterator.next(iterator) == value(1)
      assert Iterator.return(iterator) == done()
      assert_received {:closed, :source}
      assert Iterator.next(iterator) == done()
      assert Iterator.return(iterator) == done()
    end

    test "return/1 before the first next does not start the enumerable" do
      iterator = Iterator.from(closable([1]))
      assert Iterator.return(iterator) == done()
      refute_received {:closed, :source}
    end

    test "return/1 raises the error of the code for the end" do
      iterator = Iterator.from(failing_close([1, 2]))
      assert Iterator.next(iterator) == value(1)
      assert_raise RuntimeError, "close failed", fn -> Iterator.return(iterator) end
      assert Iterator.next(iterator) == done()
    end

    test "gives the code points of a string, and the same iterator" do
      assert "añ" |> Iterator.from() |> Iterator.to_array() == ["a", "ñ"]
      iterator = Iterator.from([1])
      assert Iterator.from(iterator) == iterator
    end

    test "raises TypeError for a value that is not an iterable" do
      for value <- [nil, 1, :atom, {1, 2}] do
        assert_raise TypeError, ~r/not an iterator or an iterable/, fn -> Iterator.from(value) end
      end
    end

    test "the iterator stops with its owner, and halts the enumerable" do
      test = self()

      enumerable = closable([1, 2])

      owner =
        spawn(fn ->
          iterator = Iterator.from(enumerable)
          Iterator.next(iterator)
          send(test, {:iterator, iterator})
          Process.sleep(:infinity)
        end)

      assert_receive {:iterator, iterator}
      Process.exit(owner, :kill)
      assert_down(iterator.pid)
      assert_received {:closed, :source}
      assert Iterator.next(iterator) == done()
      assert Iterator.return(iterator) == done()
    end
  end

  describe "the stop of the owner" do
    test "the iterator stops normally also when the code for the end fails" do
      test = self()
      enumerable = failing_close([1, 2])

      owner =
        spawn(fn ->
          iterator = Iterator.from(enumerable)
          Iterator.next(iterator)
          send(test, {:iterator, iterator})
          Process.sleep(:infinity)
        end)

      assert_receive {:iterator, iterator}
      monitor = Process.monitor(iterator.pid)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
    end
  end

  describe "next/1 and return/1" do
    test "raise TypeError for a value that is not an iterator" do
      for value <- [nil, [1], AsyncIterator.from([1])] do
        assert_raise TypeError, ~r/not an iterator/, fn -> Iterator.next(value) end
        assert_raise TypeError, ~r/not an iterator/, fn -> Iterator.return(value) end
      end
    end

    test "a call from a different process waits until the step ends" do
      test = self()

      mapper = fn value ->
        send(test, {:mapping, value, self()})
        receive do: (:go -> value * 10)
      end

      iterator = [1, 2] |> Iterator.from() |> Iterator.map(mapper)
      first = Task.async(fn -> Iterator.next(iterator) end)
      assert_receive {:mapping, 1, helper}
      second = Task.async(fn -> Iterator.next(iterator) end)

      # The second call waits in the mailbox of the helper, during the step
      # of the first call.
      eventually(fn -> Process.info(helper, :message_queue_len) == {:message_queue_len, 1} end)
      refute_received {:mapping, 2, _helper}

      send(helper, :go)
      assert_receive {:mapping, 2, ^helper}
      send(helper, :go)
      assert Task.await(first) == value(10)
      assert Task.await(second) == value(20)
    end

    test "a step that calls its own helper raises TypeError, and closes the source" do
      {:ok, holder} = Agent.start_link(fn -> nil end)
      mapper = fn _value -> Iterator.next(Agent.get(holder, & &1)) end
      iterator = [1] |> closable() |> Iterator.from() |> Iterator.map(mapper)
      Agent.update(holder, fn _ -> iterator end)

      assert_raise TypeError, ~r/The iterator runs/, fn -> Iterator.next(iterator) end
      assert_received {:closed, :source}
      assert Iterator.next(iterator) == done()
    end

    test "a call of an iterator that waits for the caller raises TypeError" do
      {:ok, holder} = Agent.start_link(fn -> nil end)

      inner =
        [1, 2]
        |> Iterator.from()
        |> Iterator.map(fn _v -> Iterator.next(Agent.get(holder, & &1)) end)

      outer = Iterator.map(inner, & &1)
      Agent.update(holder, fn _ -> outer end)
      assert_raise TypeError, ~r/The iterator runs/, fn -> Iterator.next(outer) end
    end
  end

  describe "map/2" do
    property "gives the results of the mapper, with the counter" do
      check all(values <- list_of(integer(), max_length: 8)) do
        iterator = values |> Iterator.from() |> Iterator.map(&{&2, &1 * 2})

        assert Enum.to_list(iterator) ==
                 values |> Enum.with_index() |> Enum.map(fn {v, i} -> {i, v * 2} end)
      end
    end

    test "is lazy: it reads its source only for a next" do
      test = self()
      source = Iterator.from(Stream.map([1, 2], &send(test, {:read, &1})))
      iterator = Iterator.map(source, & &1)
      Script.settle([source.pid, iterator.pid])
      refute_received {:read, _value}
      assert Iterator.next(iterator) == value({:read, 1})
      refute_received {:read, 2}
    end

    test "an error of the mapper closes the source, and raises with its kind" do
      for kind <- [:raise, :throw, :exit] do
        iterator = [1, 2] |> closable() |> Iterator.from() |> Iterator.map(failing(kind))
        assert caught(fn -> Iterator.next(iterator) end) == failure(kind)
        assert_received {:closed, :source}
        assert Iterator.next(iterator) == done()
      end
    end

    test "an error of the mapper stays when the close fails" do
      iterator = [1] |> failing_close() |> Iterator.from() |> Iterator.map(failing(:throw))
      assert caught(fn -> Iterator.next(iterator) end) == failure(:throw)
    end

    test "an error of the source raises, and does not close the source" do
      source = Iterator.from(Stream.map([1], failing(:raise)))
      iterator = Iterator.map(source, & &1)
      assert caught(fn -> Iterator.next(iterator) end) == failure(:raise)
      assert Iterator.next(iterator) == done()
    end

    test "a callback that is not a function closes the iterator, and raises TypeError" do
      for callback <- [nil, :atom, fn _a, _b, _c -> :ok end] do
        source = [1] |> closable() |> Iterator.from()
        Iterator.next(source)
        assert_raise TypeError, ~r/callback of map/, fn -> Iterator.map(source, callback) end
        assert_received {:closed, :source}
      end

      assert_raise TypeError, ~r/not an iterator/, fn -> Iterator.map([1], & &1) end
    end

    test "the mapper runs in the helper, with the async context of the call of map" do
      variable = Variable.new(name: "request")

      iterator =
        Variable.run(variable, "req-1", fn ->
          [1]
          |> Iterator.from()
          |> Iterator.map(fn _value -> {Variable.get(variable), self()} end)
        end)

      assert Iterator.next(iterator) == value({"req-1", iterator.pid})
    end
  end

  describe "the return/1 of a helper" do
    test "before the first next, and at a value, closes the source" do
      source = [1, 2] |> closable() |> Iterator.from()
      assert Iterator.next(source) == value(1)
      iterator = Iterator.map(source, & &1)
      assert Iterator.return(iterator) == done()
      assert_received {:closed, :source}
      assert Iterator.next(source) == done()

      iterator = [1, 2] |> closable() |> Iterator.from() |> Iterator.map(& &1)
      assert Iterator.next(iterator) == value(1)
      assert Iterator.return(iterator) == done()
      assert_received {:closed, :source}
      assert Iterator.next(iterator) == done()
    end

    test "raises the error of the close, and then the helper is done" do
      iterator = [1, 2] |> failing_close() |> Iterator.from() |> Iterator.filter(& &1)
      assert Iterator.next(iterator) == value(1)
      assert_raise RuntimeError, "close failed", fn -> Iterator.return(iterator) end
      assert Iterator.next(iterator) == done()
    end

    test "of a helper that is done gives done, and closes nothing" do
      iterator = [] |> closable() |> Iterator.from() |> Iterator.map(& &1)
      assert Iterator.next(iterator) == done()
      assert_received {:closed, :source}
      assert Iterator.return(iterator) == done()
      refute_received {:closed, :source}
    end
  end

  describe "filter/2" do
    property "gives the values that the predicate selects" do
      check all(values <- list_of(integer(), max_length: 10)) do
        iterator = values |> Iterator.from() |> Iterator.filter(&(rem(&1, 2) == 0))
        assert Enum.to_list(iterator) == Enum.filter(values, &(rem(&1, 2) == 0))
      end
    end

    test "the counter counts each value of the source, and nil and false do not select" do
      iterator =
        [nil, false, :a, :b]
        |> Iterator.from()
        |> Iterator.filter(fn value, counter -> value && counter == 3 end)

      assert Enum.to_list(iterator) == [:b]
    end

    test "an error of the predicate closes the source" do
      iterator = [1] |> closable() |> Iterator.from() |> Iterator.filter(failing(:exit))
      assert caught(fn -> Iterator.next(iterator) end) == failure(:exit)
      assert_received {:closed, :source}
    end
  end

  describe "take/2" do
    property "gives the first values" do
      check all(values <- list_of(integer(), max_length: 8), limit <- integer(0..10)) do
        iterator = values |> Iterator.from() |> Iterator.take(limit)
        assert Enum.to_list(iterator) == Enum.take(values, limit)
      end
    end

    test "the call after the limit closes the source, and gives done" do
      iterator = [1, 2, 3] |> closable() |> Iterator.from() |> Iterator.take(1)
      assert Iterator.next(iterator) == value(1)
      refute_received {:closed, :source}
      assert Iterator.next(iterator) == done()
      assert_received {:closed, :source}
      assert Iterator.next(iterator) == done()
    end

    test "a close that fails raises at the call after the limit" do
      source = [1, 2] |> failing_close() |> Iterator.from()
      Iterator.next(source)
      iterator = Iterator.take(source, 0)
      assert_raise RuntimeError, "close failed", fn -> Iterator.next(iterator) end
    end

    test "a limit is a non-negative number or :infinity; else the iterator closes" do
      assert [1, 2] |> Iterator.from() |> Iterator.take(1.9) |> Enum.to_list() == [1]
      assert [1, 2] |> Iterator.from() |> Iterator.take(:infinity) |> Enum.to_list() == [1, 2]

      for limit <- [-1, -1.5, nil, "1", :nan] do
        source = [1] |> closable() |> Iterator.from()
        Iterator.next(source)
        assert_raise RangeError, ~r/limit of take/, fn -> Iterator.take(source, limit) end
        assert_received {:closed, :source}
      end
    end
  end

  describe "drop/2" do
    property "gives the values after the first values" do
      check all(values <- list_of(integer(), max_length: 8), limit <- integer(0..10)) do
        iterator = values |> Iterator.from() |> Iterator.drop(limit)
        assert Enum.to_list(iterator) == Enum.drop(values, limit)
      end
    end

    test "drops at the first next, and an end or an error while it drops ends it" do
      assert [1, 2] |> Iterator.from() |> Iterator.drop(:infinity) |> Iterator.next() == done()

      iterator = [1, 2] |> Iterator.from() |> Iterator.map(failing(:throw)) |> Iterator.drop(1)
      assert caught(fn -> Iterator.next(iterator) end) == failure(:throw)
      assert Iterator.next(iterator) == done()
    end

    test "a limit that is not valid closes the iterator, and raises RangeError" do
      source = [1] |> closable() |> Iterator.from()
      Iterator.next(source)
      assert_raise RangeError, ~r/limit of drop/, fn -> Iterator.drop(source, -2) end
      assert_received {:closed, :source}
    end
  end

  describe "flat_map/2" do
    property "gives the values of each inner iterable" do
      check all(lists <- list_of(list_of(integer(), max_length: 3), max_length: 5)) do
        iterator = lists |> Iterator.from() |> Iterator.flat_map(& &1)
        assert Enum.to_list(iterator) == Enum.concat(lists)
      end
    end

    test "an inner iterable is a Web.Iterator or an enumerable, with the counter" do
      iterator =
        [:list, :iterator, :empty, :last]
        |> Iterator.from()
        |> Iterator.flat_map(fn
          :list, counter -> [counter]
          :iterator, counter -> Iterator.from([counter, :inner])
          :empty, _counter -> []
          :last, counter -> MapSet.new([counter])
        end)

      assert Enum.to_list(iterator) == [0, 1, :inner, 3]
    end

    test "a string, an error of the mapper, and an error of the inner iterator close the source" do
      for mapper <- [
            fn _value -> "string" end,
            fn _value -> :atom end,
            fn _value -> raise "mapper" end,
            fn _value -> Stream.map([1], fn _v -> raise "inner" end) end,
            fn _value -> Iterator.from(Stream.map([1], fn _v -> raise "inner" end)) end
          ] do
        iterator = [1] |> closable() |> Iterator.from() |> Iterator.flat_map(mapper)
        assert catch_error(Iterator.next(iterator))
        assert_received {:closed, :source}
        assert Iterator.next(iterator) == done()
      end
    end

    test "return/1 closes the inner iterator and then the source" do
      for inner <- [closable([1, 2], :inner), Iterator.from(closable([1, 2], :inner))] do
        iterator = [1] |> closable() |> Iterator.from() |> Iterator.flat_map(fn _v -> inner end)
        assert Iterator.next(iterator) == value(1)
        assert Iterator.return(iterator) == done()
        assert_received {:closed, :inner}
        assert_received {:closed, :source}
      end
    end

    test "a close of the inner iterator that fails closes the source, and raises" do
      iterator =
        [1]
        |> closable()
        |> Iterator.from()
        |> Iterator.flat_map(fn _v -> failing_close([1, 2]) end)

      assert Iterator.next(iterator) == value(1)
      assert_raise RuntimeError, "close failed", fn -> Iterator.return(iterator) end
      assert_received {:closed, :source}
    end

    test "the helper halts its inner enumerable when its owner stops" do
      test = self()

      inner = closable([1, 2], :inner)

      owner =
        spawn(fn ->
          iterator = [1] |> Iterator.from() |> Iterator.flat_map(fn _v -> inner end)
          Iterator.next(iterator)
          send(test, {:iterator, iterator})
          Process.sleep(:infinity)
        end)

      assert_receive {:iterator, iterator}
      Process.exit(owner, :kill)
      assert_down(iterator.pid)
      assert_received {:closed, :inner}
    end
  end

  describe "the methods that give a value" do
    property "give the results of the steps of ECMAScript" do
      check all(values <- list_of(integer(-5..5), max_length: 8)) do
        from = fn -> Iterator.from(values) end
        positive? = &(&1 > 0)

        assert Iterator.to_array(from.()) == values
        assert Iterator.some(from.(), positive?) == Enum.any?(values, positive?)
        assert Iterator.every(from.(), positive?) == Enum.all?(values, positive?)
        assert Iterator.find(from.(), positive?) == Enum.find(values, positive?)

        assert Iterator.reduce(from.(), &[{&3, &2} | &1], []) ==
                 values
                 |> Enum.with_index()
                 |> Enum.map(fn {v, i} -> {i, v} end)
                 |> Enum.reverse()

        test = self()
        assert Iterator.for_each(from.(), &send(test, {&2, &1})) == :ok
        for {value, index} <- Enum.with_index(values), do: assert_received({^index, ^value})
      end
    end

    test "reduce/2 takes the first value as the accumulator, with the counter from 1" do
      assert [:a, :b, :c] |> Iterator.from() |> Iterator.reduce(&[{&3, &2} | List.wrap(&1)]) ==
               [{2, :c}, {1, :b}, :a]

      assert_raise TypeError, ~r/empty iterator/, fn ->
        [] |> Iterator.from() |> Iterator.reduce(&+/2)
      end
    end

    test "some, every, and find close the iterator at their result" do
      for method <- [
            &Iterator.some(&1, fn value -> value == 1 end),
            &Iterator.every(&1, fn value -> value != 1 end),
            &Iterator.find(&1, fn value -> value == 1 end)
          ] do
        [1, 2] |> closable() |> Iterator.from() |> method.()
        assert_received {:closed, :source}
      end

      assert [1, 2] |> Iterator.from() |> Iterator.every(&(&1 < 2)) == false
      assert [false] |> Iterator.from() |> Iterator.find(&(&1 == false)) == false
    end

    test "a close that fails at the result raises" do
      assert_raise RuntimeError, "close failed", fn ->
        [1, 2] |> failing_close() |> Iterator.from() |> Iterator.some(& &1)
      end
    end

    test "an error of a callback closes the iterator, and raises with its kind" do
      for kind <- [:raise, :throw, :exit],
          method <- [
            &Iterator.for_each(&1, failing(kind)),
            &Iterator.some(&1, failing(kind)),
            &Iterator.reduce(&1, fn _acc, value -> failing(kind).(value) end, 0)
          ] do
        iterator = [1, 2] |> closable() |> Iterator.from()
        assert caught(fn -> method.(iterator) end) == failure(kind)
        assert_received {:closed, :source}
      end
    end

    test "the callbacks run in the caller" do
      test = self()
      assert [1] |> Iterator.from() |> Iterator.find(fn _value -> self() == test end) == 1
    end

    test "an argument that is not valid raises, and closes the iterator" do
      assert_raise TypeError, ~r/not an iterator/, fn -> Iterator.to_array([1]) end

      for method <- [
            &Iterator.for_each(&1, nil),
            &Iterator.some(&1, nil),
            &Iterator.every(&1, nil),
            &Iterator.find(&1, nil),
            &Iterator.reduce(&1, nil),
            &Iterator.reduce(&1, nil, 0),
            &Iterator.filter(&1, nil),
            &Iterator.flat_map(&1, nil)
          ] do
        source = [1] |> closable() |> Iterator.from()
        Iterator.next(source)
        assert_raise TypeError, fn -> method.(source) end
        assert_received {:closed, :source}
      end
    end
  end

  describe "to_async/1" do
    test "gives the values of the iterator, and awaits a promise value" do
      async = [1, Promise.resolve(2)] |> Iterator.from() |> Iterator.to_async()
      assert %AsyncIterator{} = async
      assert await(AsyncIterator.to_array(async)) == [1, 2]
      assert_raise TypeError, fn -> Iterator.to_async([1]) end
    end

    test "a promise that rejects closes the iterator, and rejects" do
      async = [Promise.reject(:bad), 2] |> closable() |> Iterator.from() |> Iterator.to_async()
      assert catch_exit(await(AsyncIterator.next(async))) == :bad
      assert_received {:closed, :source}
      assert await(AsyncIterator.next(async)) == done()
    end

    test "an error of next rejects" do
      async = [1] |> Iterator.from() |> Iterator.map(failing(:raise)) |> Iterator.to_async()
      assert %ArgumentError{} = catch_exit(await(AsyncIterator.next(async)))
    end

    test "return calls return of the iterator, also before the first next" do
      for calls <- [0, 1] do
        iterator = [1, 2] |> closable() |> Iterator.from() |> Iterator.map(& &1)
        async = Iterator.to_async(iterator)
        for _call <- 1..calls//1, do: assert(await(AsyncIterator.next(async)) == value(1))
        assert await(AsyncIterator.return(async)) == done()
        if calls == 1, do: assert_received({:closed, :source})
        assert Iterator.next(iterator) == done()
      end

      iterator = [1, 2] |> failing_close() |> Iterator.from()
      Iterator.next(iterator)
      async = Iterator.to_async(iterator)
      assert %RuntimeError{} = catch_exit(await(AsyncIterator.return(async)))
    end

    test "AsyncIterator.from and wrap_iterator take a Web.Iterator, as toAsync" do
      iterator = [1] |> closable() |> Iterator.from() |> Iterator.map(& &1)
      async = AsyncIterator.from(iterator)
      assert await(AsyncIterator.return(async)) == done()
      assert Iterator.next(iterator) == done()

      governed = Web.Governor.wrap_iterator(Web.CountingGovernor.new(1), Iterator.from([:a]))
      assert Enum.to_list(governed) == [:a]
    end

    test "the async iterator stops with its owner, and does not close the iterator" do
      test = self()
      iterator = [1, 2] |> closable() |> Iterator.from()

      owner =
        spawn(fn ->
          send(test, {:async, Iterator.to_async(iterator)})
          Process.sleep(:infinity)
        end)

      assert_receive {:async, async}
      Process.exit(owner, :kill)
      assert_down(async.pid)
      assert Iterator.next(iterator) == value(1)
    end
  end

  describe "Enumerable" do
    test "a halt closes the iterator" do
      iterator = [1, 2, 3] |> closable() |> Iterator.from()
      assert Enum.take(iterator, 1) == [1]
      assert_received {:closed, :source}
      assert Iterator.next(iterator) == done()
    end

    test "a close that fails at a halt raises" do
      iterator = [1, 2] |> failing_close() |> Iterator.from()
      assert_raise RuntimeError, "close failed", fn -> Enum.take(iterator, 1) end
    end

    test "an error of the reducer closes the iterator, and goes to the caller" do
      iterator = [1, 2] |> closable() |> Iterator.from()
      assert_raise ArgumentError, fn -> Enum.each(iterator, failing(:raise)) end
      assert_received {:closed, :source}
    end

    test "the functions of Enum consume the iterator" do
      iterator = Iterator.from([1, 2, 3])
      assert Enum.count(iterator) == 3
      assert Enum.to_list(iterator) == []
      assert Enum.member?(Iterator.from([1, 2]), 2)
      assert Enum.slice(Iterator.from([1, 2, 3]), 1..2) == [2, 3]

      assert Stream.zip(Iterator.from([1, 2]), Iterator.from([:a, :b])) |> Enum.to_list() == [
               {1, :a},
               {2, :b}
             ]
    end
  end

  describe "processes" do
    test "an iterator process takes each other message, and continues" do
      source = Iterator.from([1, 2])
      helper = Iterator.map(source, & &1)
      send(source.pid, :other)
      send(helper.pid, :other)
      Script.settle([source.pid, helper.pid])
      assert Enum.to_list(helper) == [1, 2]
    end

    test "a helper stops after its end, and with its owner" do
      iterator = [1] |> Iterator.from() |> Iterator.map(& &1)
      assert Enum.to_list(iterator) == [1]
      assert_down(iterator.pid)

      test = self()

      owner =
        spawn(fn ->
          send(test, {:iterator, [1] |> Iterator.from() |> Iterator.map(& &1)})
          Process.sleep(:infinity)
        end)

      assert_receive {:iterator, iterator}
      Process.exit(owner, :kill)
      assert_down(iterator.pid)
      assert Iterator.next(iterator) == done()
    end
  end
end
