defmodule Web.AsyncIteratorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.AsyncContext.Variable
  alias Web.AsyncIterator
  alias Web.Promise
  alias Web.RangeError
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController, as: Controller
  alias Web.Test.ScriptedIterator, as: Script
  alias Web.TypeError

  doctest Web.AsyncIterator

  # A governor that gives each acquisition to the test: the test settles
  # it, and gets each release. It cannot abort an acquisition.
  defmodule ManualGovernor do
    defstruct [:test]

    def acquire(%__MODULE__{test: test}) do
      {promise, resolve, reject} = Promise.with_resolvers()
      send(test, {:acquire, resolve, reject})
      promise
    end

    def release_token(%__MODULE__{test: test}, ref) do
      send(test, {:released, ref})
      :ok
    end
  end

  # A governor as ManualGovernor that can abort an acquisition: the test
  # gets each abort.
  defmodule AbortableManualGovernor do
    defstruct [:test]

    def acquire(%__MODULE__{} = governor), do: acquire_abortable(governor).promise

    def acquire_abortable(%__MODULE__{test: test}) do
      {promise, resolve, reject} = Promise.with_resolvers()
      send(test, {:acquire, resolve, reject})

      abort = fn ->
        send(test, {:aborted, reject})
        :ok
      end

      %{promise: promise, abort: abort}
    end

    def release_token(%__MODULE__{test: test}, ref) do
      send(test, {:released, ref})
      :ok
    end
  end

  # A governor that gives each token at once. Its release waits for the
  # test.
  defmodule SlowReleaseGovernor do
    defstruct [:test]

    def acquire(%__MODULE__{} = governor) do
      Promise.resolve(%Web.GovernorToken{governor: governor, ref: make_ref()})
    end

    def release_token(%__MODULE__{test: test}, _ref) do
      send(test, {:releasing, self()})

      receive do
        :go -> :ok
      end
    end
  end

  defp token(governor), do: %Web.GovernorToken{governor: governor, ref: make_ref()}

  # Examines the condition until it is true, for a state of a different
  # process that no message tells.
  defp eventually(fun, attempts \\ 500) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition is not true")
      true -> Process.sleep(2) && eventually(fun, attempts - 1)
    end
  end

  # A governor whose acquire raises.
  defmodule FailingGovernor do
    defstruct []
    def acquire(%__MODULE__{}), do: raise("no acquire")
  end

  # A governor whose acquireAbortable raises.
  defmodule FailingAbortableGovernor do
    defstruct []
    def acquire(%__MODULE__{}), do: raise("no acquire")
    def acquire_abortable(%__MODULE__{}), do: raise("no abortable acquire")
  end

  defp next(iterator), do: await(AsyncIterator.next(iterator))
  defp value(value), do: %{value: value, done: false}
  defp done, do: %{value: nil, done: true}

  # A stream with the after function of `Stream.resource/3`: the test gets
  # `:closed` when the enumerable halts.
  defp closable(values) do
    test = self()

    Stream.resource(
      fn -> values end,
      fn
        [] -> {:halt, []}
        [value | rest] -> {[value], rest}
      end,
      fn _rest -> send(test, :closed) end
    )
  end

  # A callback that tells the test about its call, and waits for the
  # result from the test: `{:go, result}` or `{:raise, reason}`.
  defp blocking(name) do
    test = self()

    fn value, counter ->
      send(test, {name, value, counter, self()})

      receive do
        {:go, result} -> result
        {:raise, reason} -> raise reason
      end
    end
  end

  defp assert_called(name) do
    assert_receive {^name, value, counter, pid}
    {value, counter, pid}
  end

  # The calls of a callback that runs in many jobs at the same time come in
  # each sequence: sorted by their counter.
  defp assert_calls(name, count) do
    1..count |> Enum.map(fn _call -> assert_called(name) end) |> Enum.sort_by(&elem(&1, 1))
  end

  defp peek(promise), do: Promise.peek(promise)

  # The one process that is linked to `pid`: the close, or the acquisition
  # of a permit, of a helper or a method.
  defp linked(pid) do
    Script.settle([pid])
    {:links, [linked]} = Process.info(pid, :links)
    linked
  end

  # The job of a method for the read `index`.
  defp job_of(pid, index) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    assert dictionary
    :erlang.suspend_process(pid)
    {:links, links} = Process.info(pid, :links)
    :erlang.resume_process(pid)
    Enum.at(Enum.sort(links), index)
  end

  describe "from/1" do
    property "gives the elements of an enumerable, and then the end" do
      check all(values <- list_of(term(), max_length: 8)) do
        iterator = AsyncIterator.from(values)
        assert Enum.map(values, fn _value -> next(iterator) end) == Enum.map(values, &value/1)
        assert next(iterator) == done()
        assert next(iterator) == done()
      end
    end

    test "takes no element before the first next" do
      test = self()
      iterator = AsyncIterator.from(Stream.map([1, 2], &send(test, {:step, &1})))
      Script.settle([iterator.pid])
      refute_received {:step, _value}

      assert next(iterator) == value({:step, 1})
      assert_received {:step, 1}
      refute_received {:step, 2}
    end

    test "gives the value of a promise element, as AsyncFromSyncIteratorContinuation" do
      iterator = AsyncIterator.from([Promise.resolve(:a), :b])
      assert next(iterator) == value(:a)
      assert next(iterator) == value(:b)
    end

    test "a promise element that rejects closes the enumerable" do
      iterator = AsyncIterator.from(Stream.concat(closable([Promise.reject(:bad)]), [:after]))
      assert catch_exit(next(iterator)) == :bad
      assert_receive :closed
      assert next(iterator) == done()
    end

    test "an error of the enumerable rejects, and then the iterator is done" do
      iterator =
        AsyncIterator.from(
          Stream.map([1, 2], fn
            2 -> raise "step failed"
            v -> v
          end)
        )

      assert next(iterator) == value(1)
      assert %RuntimeError{message: "step failed"} = catch_exit(next(iterator))
      assert next(iterator) == done()

      iterator = AsyncIterator.from(Stream.map([1], fn _value -> throw(:thrown) end))
      assert catch_exit(next(iterator)) == :thrown
    end

    test "gives the last element of an enumerable that halts itself" do
      assert 1..10 |> Stream.take(2) |> AsyncIterator.from() |> Enum.to_list() == [1, 2]
    end

    test "return/1 halts the enumerable, and then the iterator is done" do
      iterator = AsyncIterator.from(closable([1, 2]))
      assert next(iterator) == value(1)
      assert await(AsyncIterator.return(iterator)) == done()
      assert_received :closed
      assert next(iterator) == done()
      assert await(AsyncIterator.return(iterator)) == done()
    end

    test "return/1 before the first next does not start the enumerable" do
      iterator = AsyncIterator.from(closable([1]))
      assert await(AsyncIterator.return(iterator)) == done()
      refute_received :closed
    end

    test "return/1 rejects with the error of the code for the end" do
      stream = Stream.resource(fn -> 0 end, &{[&1], &1 + 1}, fn _acc -> raise "no end" end)
      iterator = AsyncIterator.from(stream)
      assert next(iterator) == value(0)
      assert %RuntimeError{message: "no end"} = catch_exit(await(AsyncIterator.return(iterator)))
    end

    test "gives the code points of a string" do
      assert "añ" |> AsyncIterator.from() |> Enum.to_list() == ["a", "ñ"]
    end

    test "gives the same async iterator, and a wrapper of a stream iterator" do
      iterator = AsyncIterator.from([1])
      assert AsyncIterator.from(iterator) == iterator

      stream_iterator = ReadableStream.values(ReadableStream.from([:x]))
      wrapper = AsyncIterator.from(stream_iterator)
      assert %AsyncIterator{source: ^stream_iterator} = wrapper
      assert next(wrapper) == value(:x)
      assert next(wrapper) == done()
    end

    test "takes the lock of a stream, as [Symbol.asyncIterator]()" do
      test = self()
      stream = ReadableStream.new(%{cancel: &send(test, {:cancel, &1})})
      iterator = AsyncIterator.from(stream)
      assert ReadableStream.locked?(stream)

      # The method return() of the wrapper has no argument.
      assert await(AsyncIterator.return(iterator, :reason)) == done()
      assert_received {:cancel, nil}
      refute ReadableStream.locked?(stream)
    end

    test "raises TypeError for a value that is not an iterable" do
      for value <- [nil, 42, :atom, {1, 2}, %URI{}] do
        assert_raise TypeError, ~r/not an async iterator or an iterable/, fn ->
          AsyncIterator.from(value)
        end
      end
    end

    test "the iterator stops with its owner, and halts the enumerable" do
      test = self()
      enumerable = closable([1, 2])

      owner =
        spawn(fn ->
          iterator = AsyncIterator.from(enumerable)
          send(test, {:iterator, iterator, next(iterator)})
          Process.sleep(:infinity)
        end)

      assert_receive {:iterator, iterator, %{value: 1}}
      monitor = Process.monitor(iterator.pid)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
      assert_received :closed
      assert next(iterator) == done()
    end
  end

  describe "next/1 and return/2" do
    test "take each async iterator of the library" do
      test = self()

      stream =
        ReadableStream.new(%{
          start: &Controller.enqueue(&1, :a),
          cancel: &send(test, {:cancel, &1})
        })

      iterator = ReadableStream.values(stream)

      assert next(iterator) == value(:a)
      assert await(AsyncIterator.return(iterator, :stop)) == %{value: :stop, done: true}
      assert_received {:cancel, :stop}
    end

    test "raise TypeError for a value that is not an async iterator" do
      assert_raise TypeError, ~r/not an async iterator/, fn -> AsyncIterator.next([1]) end
      assert_raise TypeError, ~r/not an async iterator/, fn -> AsyncIterator.return(:no) end
    end

    test "the promise of a step stops with its owner" do
      test = self()
      source = Script.new()

      owner =
        spawn(fn ->
          send(test, {:promise, AsyncIterator.next(AsyncIterator.map(source, & &1))})
          Process.sleep(:infinity)
        end)

      assert_receive {:promise, promise}
      _target = Script.assert_next()
      monitor = Process.monitor(promise.pid)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    end
  end

  describe "map/2" do
    test "gives the value and the counter to the mapper" do
      iterator = [:a, :b] |> AsyncIterator.from() |> AsyncIterator.map(&{&1, &2})
      assert Enum.to_list(iterator) == [{:a, 0}, {:b, 1}]

      assert [1] |> AsyncIterator.from() |> AsyncIterator.map(fn -> :x end) |> Enum.to_list() ==
               [:x]
    end

    test "is lazy: it reads its source only for a next" do
      source = Script.new()
      iterator = AsyncIterator.map(source, & &1)
      Script.settle([iterator.pid])
      Script.refute_step()

      promise = AsyncIterator.next(iterator)
      Script.give(Script.assert_next(), 1)
      assert await(promise) == value(1)
    end

    test "gives the value of a promise that the mapper returns" do
      iterator = [1] |> AsyncIterator.from() |> AsyncIterator.map(&Promise.resolve(&1 + 1))
      assert next(iterator) == value(2)
    end

    test "concurrent calls of next run the mapper at the same time, and get their results in sequence" do
      source = Script.new()
      iterator = AsyncIterator.map(source, blocking(:map))
      first = AsyncIterator.next(iterator)
      second = AsyncIterator.next(iterator)

      # The helper starts the two reads before the first value comes.
      first_read = Script.assert_next()
      second_read = Script.assert_next()
      Script.give(first_read, :a)
      Script.give(second_read, :b)
      assert [{:a, 0, first_mapper}, {:b, 1, second_mapper}] = assert_calls(:map, 2)

      # The second mapper ends first. Its result waits for the first.
      send(second_mapper, {:go, :second})
      Script.settle([iterator.pid])
      assert peek(first) == :pending
      assert peek(second) == :pending

      send(first_mapper, {:go, :first})
      assert await(first) == value(:first)
      assert await(second) == value(:second)
    end

    test "an end before an earlier result gives done at once to the calls from it on" do
      source = Script.new()
      iterator = AsyncIterator.map(source, blocking(:map))
      first = AsyncIterator.next(iterator)
      second = AsyncIterator.next(iterator)
      third = AsyncIterator.next(iterator)
      first_read = Script.assert_next()
      Script.finish(Script.assert_next())
      _third_read = Script.assert_next()

      assert await(second) == done()
      assert await(third) == done()
      assert peek(first) == :pending

      Script.give(first_read, :a)
      {:a, 0, mapper} = assert_called(:map)
      send(mapper, {:go, :mapped})
      assert await(first) == value(:mapped)

      # After the end, a call gives done, and reads nothing.
      assert next(iterator) == done()
      Script.settle([iterator.pid])
      Script.refute_step()
    end

    test "an error of the mapper rejects after the earlier results, and closes the source" do
      source = Script.new()
      iterator = AsyncIterator.map(source, blocking(:map))
      [first, second, third] = for _call <- 1..3, do: AsyncIterator.next(iterator)
      reads = for _read <- 1..3, do: Script.assert_next()
      Enum.zip(reads, [:a, :b, :c]) |> Enum.each(fn {read, v} -> Script.give(read, v) end)
      [{:a, 0, first_mapper}, {:b, 1, second_mapper}, {:c, 2, _third}] = assert_calls(:map, 3)

      send(second_mapper, {:raise, "mapper failed"})

      # The calls after the error are done at once. The error waits for the
      # first call, and the close waits for the error.
      assert await(third) == done()
      Script.settle([iterator.pid])
      Script.refute_step()
      assert peek(second) == :pending

      send(first_mapper, {:go, :first})
      assert await(first) == value(:first)

      # The close comes before the rejection.
      close = Script.assert_return()
      Script.settle([iterator.pid])
      assert peek(second) == :pending
      Script.finish(close)
      assert %RuntimeError{message: "mapper failed"} = catch_exit(await(second))
      assert next(iterator) == done()
    end

    test "an error of the mapper stays when the close fails" do
      source = Script.new()
      iterator = AsyncIterator.map(source, fn _value -> throw(:mapper) end)
      promise = AsyncIterator.next(iterator)
      Script.give(Script.assert_next(), 1)
      Script.fail(Script.assert_return(), :close)
      assert catch_exit(await(promise)) == :mapper
    end

    test "a mapper that returns a promise that rejects closes the source" do
      iterator =
        [1, 2]
        |> closable()
        |> AsyncIterator.from()
        |> AsyncIterator.map(fn _v -> Promise.reject(:no) end)

      assert catch_exit(next(iterator)) == :no
      assert_receive :closed
    end

    test "an error of the source rejects, and does not close the source" do
      source = Script.new()
      iterator = AsyncIterator.map(source, & &1)
      promise = AsyncIterator.next(iterator)
      Script.fail(Script.assert_next(), :source)
      assert catch_exit(await(promise)) == :source
      assert next(iterator) == done()
      Script.settle([iterator.pid])
      Script.refute_step()
    end

    test "raises TypeError for a callback that is not a function of arity 0 to 2" do
      iterator = AsyncIterator.from([1])

      assert_raise TypeError, ~r/callback of map/, fn -> AsyncIterator.map(iterator, :no) end
      assert_raise TypeError, fn -> AsyncIterator.map(iterator, fn _a, _b, _c -> :x end) end
      assert_raise TypeError, ~r/not an async iterator/, fn -> AsyncIterator.map([1], & &1) end
    end

    test "the mapper runs with the async context of the call of map" do
      variable = Variable.new(name: "request")

      iterator =
        Variable.run(variable, :outer, fn ->
          [1]
          |> AsyncIterator.from()
          |> AsyncIterator.map(fn _value -> Variable.get(variable) end)
        end)

      assert Variable.run(variable, :inner, fn -> next(iterator) end) == value(:outer)
    end

    test "a stream iterator is a source" do
      stream = ReadableStream.from(["a", "b"])

      assert stream
             |> ReadableStream.values()
             |> AsyncIterator.map(&String.upcase/1)
             |> Enum.to_list() ==
               ["A", "B"]

      refute ReadableStream.locked?(stream)
    end
  end

  describe "return/1 of a helper" do
    test "before the first next closes the source" do
      source = Script.new()
      iterator = AsyncIterator.map(source, & &1)
      promise = AsyncIterator.return(iterator, :ignored)
      Script.finish(Script.assert_return())
      assert await(promise) == done()
      assert next(iterator) == done()
    end

    test "comes after the calls of next before it" do
      source = Script.new()
      iterator = AsyncIterator.map(source, & &1)
      first = AsyncIterator.next(iterator)
      returned = AsyncIterator.return(iterator)
      later = AsyncIterator.next(iterator)
      read = Script.assert_next()

      # A call after the return is done at once. The close waits.
      assert await(later) == done()
      Script.settle([iterator.pid])
      Script.refute_step()

      Script.give(read, :a)
      assert await(first) == value(:a)
      Script.finish(Script.assert_return())
      assert await(returned) == done()
    end

    test "rejects with the error of the close" do
      source = Script.new()
      iterator = AsyncIterator.map(source, & &1)
      promise = AsyncIterator.return(iterator)
      Script.fail(Script.assert_return(), :close_failed)
      assert catch_exit(await(promise)) == :close_failed
    end

    test "of a helper that is done gives done, and closes nothing" do
      iterator = [] |> AsyncIterator.from() |> AsyncIterator.map(& &1)
      assert next(iterator) == done()
      assert await(AsyncIterator.return(iterator)) == done()

      source = Script.new()
      iterator = AsyncIterator.map(source, & &1)
      first = AsyncIterator.return(iterator)
      second = AsyncIterator.return(iterator)
      assert await(second) == done()
      Script.finish(Script.assert_return())
      assert await(first) == done()
    end

    test "after an end that comes during the calls before it gives done, and closes nothing" do
      source = Script.new()
      iterator = AsyncIterator.map(source, & &1)
      first = AsyncIterator.next(iterator)
      returned = AsyncIterator.return(iterator)
      Script.finish(Script.assert_next())
      assert await(first) == done()
      assert await(returned) == done()
      Script.settle([iterator.pid])
      Script.refute_step()
    end
  end

  describe "filter/2" do
    property "gives the values that the predicate selects, in their sequence" do
      check all(values <- list_of(integer(), max_length: 10)) do
        iterator = values |> AsyncIterator.from() |> AsyncIterator.filter(&(rem(&1, 3) == 0))
        assert Enum.to_list(iterator) == Enum.filter(values, &(rem(&1, 3) == 0))
      end
    end

    test "the counter counts each value of the source, and nil and false do not select" do
      iterator =
        [:a, :b, :c, :d]
        |> AsyncIterator.from()
        |> AsyncIterator.filter(fn _value, counter -> Enum.at([nil, 0, false, ""], counter) end)

      assert Enum.to_list(iterator) == [:b, :d]
    end

    test "a value that is not selected gives its call the next selected value" do
      source = Script.new()
      iterator = AsyncIterator.filter(source, blocking(:filter))
      first = AsyncIterator.next(iterator)
      second = AsyncIterator.next(iterator)
      Script.give(Script.assert_next(), :a)
      Script.give(Script.assert_next(), :b)
      [{:a, 0, a}, {:b, 1, b}] = assert_calls(:filter, 2)

      # :b is selected first, but :a can come before it.
      send(b, {:go, true})
      Script.settle([iterator.pid])
      assert peek(first) == :pending

      # :a is not selected: a new read starts, for the second call.
      send(a, {:go, false})
      assert await(first) == value(:b)
      Script.give(Script.assert_next(), :c)
      {:c, 2, c} = assert_called(:filter)
      send(c, {:go, :yes})
      assert await(second) == value(:c)
    end

    test "after the end, a call with no selected value gets done" do
      source = Script.new()
      iterator = AsyncIterator.filter(source, blocking(:filter))
      first = AsyncIterator.next(iterator)
      second = AsyncIterator.next(iterator)
      Script.give(Script.assert_next(), :a)
      Script.finish(Script.assert_next())
      assert await(second) == done()

      {:a, 0, a} = assert_called(:filter)
      send(a, {:go, false})
      assert await(first) == done()
    end

    test "an error of the predicate closes the source" do
      iterator =
        closable([1]) |> AsyncIterator.from() |> AsyncIterator.filter(fn _v -> raise "no" end)

      assert %RuntimeError{} = catch_exit(next(iterator))
      assert_receive :closed
    end

    test "raises TypeError for a predicate that is not a function" do
      assert_raise TypeError, ~r/callback of filter/, fn ->
        AsyncIterator.filter(AsyncIterator.from([]), "no")
      end
    end
  end

  describe "take/2" do
    property "gives the first values" do
      check all(values <- list_of(integer(), max_length: 6), limit <- integer(0..8)) do
        iterator = values |> AsyncIterator.from() |> AsyncIterator.take(limit)
        assert Enum.to_list(iterator) == Enum.take(values, limit)
      end
    end

    test "the call after the limit closes the source, and gives done" do
      source = Script.new()
      iterator = AsyncIterator.take(source, 1)
      first = AsyncIterator.next(iterator)
      second = AsyncIterator.next(iterator)
      third = AsyncIterator.next(iterator)
      read = Script.assert_next()
      assert await(third) == done()

      # The close waits for the call before it.
      Script.settle([iterator.pid])
      Script.refute_step()
      Script.give(read, :a)
      assert await(first) == value(:a)
      Script.finish(Script.assert_return())
      assert await(second) == done()
    end

    test "take(0) closes the source at the first call" do
      iterator = closable([1]) |> AsyncIterator.from() |> AsyncIterator.take(0)
      assert next(iterator) == done()
    end

    test "a close that fails rejects the call after the limit" do
      source = Script.new()
      iterator = AsyncIterator.take(source, 0)
      promise = AsyncIterator.next(iterator)
      Script.fail(Script.assert_return(), :close)
      assert catch_exit(await(promise)) == :close
    end

    test "a source that ends before the limit is not closed" do
      source = Script.new()
      iterator = AsyncIterator.take(source, 5)
      promise = AsyncIterator.next(iterator)
      Script.finish(Script.assert_next())
      assert await(promise) == done()
      assert next(iterator) == done()
      Script.settle([iterator.pid])
      Script.refute_step()
    end

    test "a limit is a non-negative number, or :infinity" do
      assert 1..5 |> AsyncIterator.from() |> AsyncIterator.take(2.9) |> Enum.to_list() == [1, 2]
      assert 1..5 |> AsyncIterator.from() |> AsyncIterator.take(-0.5) |> Enum.to_list() == []

      assert 1..3 |> AsyncIterator.from() |> AsyncIterator.take(:infinity) |> Enum.to_list() == [
               1,
               2,
               3
             ]

      for limit <- [-1, -1.0, "2", nil, :nan] do
        assert_raise RangeError, ~r/limit of take/, fn ->
          AsyncIterator.take(AsyncIterator.from([]), limit)
        end
      end
    end
  end

  describe "drop/2" do
    property "gives the values after the first values" do
      check all(values <- list_of(integer(), max_length: 6), limit <- integer(0..8)) do
        iterator = values |> AsyncIterator.from() |> AsyncIterator.drop(limit)
        assert Enum.to_list(iterator) == Enum.drop(values, limit)
      end
    end

    test "the first call drops the values; the other calls read after it" do
      source = Script.new()
      iterator = AsyncIterator.drop(source, 2)
      first = AsyncIterator.next(iterator)
      second = AsyncIterator.next(iterator)

      # One read at a time, until the first call has its value.
      for result <- [:dropped, :dropped, :a] do
        read = Script.assert_next()
        Script.settle([iterator.pid])
        Script.refute_step()
        Script.give(read, result)
      end

      Script.give(Script.assert_next(), :b)
      assert await(first) == value(:a)
      assert await(second) == value(:b)
    end

    test "an end or an error while it drops ends each call" do
      source = Script.new()
      iterator = AsyncIterator.drop(source, 3)
      first = AsyncIterator.next(iterator)
      second = AsyncIterator.next(iterator)
      Script.finish(Script.assert_next())
      assert await(first) == done()
      assert await(second) == done()

      source = Script.new()
      iterator = AsyncIterator.drop(source, :infinity)
      first = AsyncIterator.next(iterator)
      second = AsyncIterator.next(iterator)
      Script.give(Script.assert_next(), :dropped)
      Script.fail(Script.assert_next(), :source)
      assert catch_exit(await(first)) == :source
      assert await(second) == done()
    end

    test "a limit is as for take" do
      assert 1..4 |> AsyncIterator.from() |> AsyncIterator.drop(:infinity) |> Enum.to_list() == []

      assert_raise RangeError, ~r/limit of drop/, fn ->
        AsyncIterator.drop(AsyncIterator.from([]), -2)
      end
    end
  end

  describe "flat_map/2" do
    property "gives the values of each inner iterable" do
      check all(lists <- list_of(list_of(integer(), max_length: 3), max_length: 5)) do
        iterator = lists |> AsyncIterator.from() |> AsyncIterator.flat_map(& &1)
        assert Enum.to_list(iterator) == Enum.concat(lists)
      end
    end

    test "an inner iterable is an async iterator, a stream, or an enumerable, with the counter" do
      iterator =
        [:list, :stream, :iterator]
        |> AsyncIterator.from()
        |> AsyncIterator.flat_map(fn
          :list, counter -> [counter]
          :stream, counter -> ReadableStream.from([counter])
          :iterator, counter -> AsyncIterator.from([counter, :last])
        end)

      assert Enum.to_list(iterator) == [0, 1, 2, :last]
    end

    test "reads the inner iterator before the source, one call at a time" do
      source = Script.new()
      iterator = AsyncIterator.flat_map(source, fn value -> [value, value] end)
      first = AsyncIterator.next(iterator)
      second = AsyncIterator.next(iterator)
      third = AsyncIterator.next(iterator)

      Script.give(Script.assert_next(), :a)
      assert await(first) == value(:a)
      assert await(second) == value(:a)
      Script.give(Script.assert_next(), :b)
      assert await(third) == value(:b)
      Script.settle([iterator.pid])
      Script.refute_step()
    end

    test "a string, an error of the mapper, and an error of the inner iterator close the source" do
      for mapper <- [
            fn _value -> "string" end,
            fn _value -> raise "mapper" end,
            fn _value -> Stream.map([1], fn _v -> raise "inner" end) end
          ] do
        iterator = closable([1]) |> AsyncIterator.from() |> AsyncIterator.flat_map(mapper)
        assert catch_exit(next(iterator))
        assert_receive :closed
      end

      iterator = AsyncIterator.flat_map(AsyncIterator.from([1]), fn _v -> "abc" end)

      assert %TypeError{message: "The value is not an async iterator" <> _} =
               catch_exit(next(iterator))
    end

    test "an error of the source does not close it" do
      source = Script.new()
      iterator = AsyncIterator.flat_map(source, & &1)
      promise = AsyncIterator.next(iterator)
      Script.fail(Script.assert_next(), :source)
      assert catch_exit(await(promise)) == :source
    end

    test "return/1 closes the inner iterator and then the source" do
      test = self()

      inner =
        Stream.resource(fn -> 0 end, &{[&1], &1 + 1}, fn _acc -> send(test, :inner_closed) end)

      iterator =
        closable([1]) |> AsyncIterator.from() |> AsyncIterator.flat_map(fn _v -> inner end)

      assert next(iterator) == value(0)
      assert await(AsyncIterator.return(iterator)) == done()
      assert_received :inner_closed
      assert_received :closed
    end

    test "a close of the inner iterator that fails closes the source, and rejects" do
      inner = Stream.resource(fn -> 0 end, &{[&1], &1 + 1}, fn _acc -> raise "inner end" end)

      iterator =
        closable([1]) |> AsyncIterator.from() |> AsyncIterator.flat_map(fn _v -> inner end)

      assert next(iterator) == value(0)

      assert %RuntimeError{message: "inner end"} =
               catch_exit(await(AsyncIterator.return(iterator)))

      assert_received :closed
    end
  end

  describe "limit/2" do
    test "limits the reads of the source, for each number of calls" do
      source = Script.new()
      iterator = AsyncIterator.limit(source, 2)
      [first, second, third] = for _call <- 1..3, do: AsyncIterator.next(iterator)
      first_read = Script.assert_next()
      second_read = Script.assert_next()
      Script.settle([iterator.pid])
      Script.refute_step()

      # The end of a read gives its permit to the next call.
      Script.give(second_read, :b)
      Script.give(Script.assert_next(), :c)
      Script.settle([iterator.pid])
      assert peek(second) == :pending

      Script.give(first_read, :a)
      assert Enum.map([first, second, third], &await/1) == [value(:a), value(:b), value(:c)]
    end

    test "a governor gives the permits, and gets each token back" do
      governor = Web.CountingGovernor.new(1)
      source = Script.new()
      iterator = AsyncIterator.limit(source, governor)
      first = AsyncIterator.next(iterator)
      second = AsyncIterator.next(iterator)
      read = Script.assert_next()
      Script.settle([iterator.pid, governor.pid])
      Script.refute_step()

      Script.give(read, :a)
      Script.give(Script.assert_next(), :b)
      assert await(first) == value(:a)
      assert await(second) == value(:b)
      Script.settle([iterator.pid, governor.pid])
      assert :sys.get_state(governor.pid).in_use == 0
    end

    test "the token goes back before the result of the call, as wrapIterator" do
      source = Script.new()

      promise =
        source |> AsyncIterator.limit(%SlowReleaseGovernor{test: self()}) |> AsyncIterator.next()

      Script.give(Script.assert_next(), :a)
      assert_receive {:releasing, releaser}
      Script.settle([promise.pid])
      assert peek(promise) == :pending

      send(releaser, :go)
      assert await(promise) == value(:a)
    end

    test "a token that limit does not need any more goes back" do
      governor = %ManualGovernor{test: self()}
      source = Script.new()
      iterator = AsyncIterator.limit(source, governor)
      first = AsyncIterator.next(iterator)
      second = AsyncIterator.next(iterator)
      assert_receive {:acquire, resolve, _reject}
      first_token = token(governor)
      resolve.(first_token)
      read = Script.assert_next()
      assert_receive {:acquire, late, _reject}

      # The end of the source ends the second call. Its acquisition goes on.
      Script.finish(read)
      assert await(first) == done()
      assert await(second) == done()
      assert_receive {:released, ref} when ref == first_token.ref

      late_token = token(governor)
      late.(late_token)
      assert_receive {:released, ref} when ref == late_token.ref
    end

    test "a governor whose acquire raises rejects the call, and closes the source" do
      source = Script.new()
      promise = source |> AsyncIterator.limit(%FailingGovernor{}) |> AsyncIterator.next()
      Script.finish(Script.assert_return())
      assert %RuntimeError{message: "no acquire"} = catch_exit(await(promise))

      promise = AsyncIterator.to_array(Script.new(), %FailingGovernor{})
      Script.finish(Script.assert_return())
      assert %RuntimeError{message: "no acquire"} = catch_exit(await(promise))

      promise = AsyncIterator.to_array(Script.new(), %FailingAbortableGovernor{})
      Script.finish(Script.assert_return())
      assert %RuntimeError{message: "no abortable acquire"} = catch_exit(await(promise))
    end

    test "limit(0) reads nothing" do
      source = Script.new()
      promise = source |> AsyncIterator.limit(0) |> AsyncIterator.next()
      Script.settle([promise.pid])
      Script.refute_step()
      assert peek(promise) == :pending
    end

    test "raises for a value that is not a governor" do
      iterator = AsyncIterator.from([])
      assert_raise RangeError, fn -> AsyncIterator.limit(iterator, -1) end

      for value <- [nil, 1.5, %URI{}, :governor] do
        assert_raise TypeError, ~r/governor or a non-negative integer/, fn ->
          AsyncIterator.limit(iterator, value)
        end
      end
    end
  end

  describe "the methods that give a value" do
    property "give the results of the steps of the proposal, with each concurrency" do
      check all(
              values <- list_of(integer(-5..5), max_length: 8),
              concurrency <- one_of([constant(nil), integer(1..4)])
            ) do
        from = fn -> AsyncIterator.from(values) end
        positive? = &(&1 > 0)

        assert await(AsyncIterator.to_array(from.(), concurrency)) == values

        assert await(AsyncIterator.some(from.(), positive?, concurrency)) ==
                 Enum.any?(values, positive?)

        assert await(AsyncIterator.every(from.(), positive?, concurrency)) ==
                 Enum.all?(values, positive?)

        assert await(AsyncIterator.find(from.(), positive?, concurrency)) ==
                 Enum.find(values, positive?)

        reduced = await(AsyncIterator.reduce(from.(), &[{&3, &2} | &1], [], concurrency))

        assert reduced ==
                 values
                 |> Enum.with_index()
                 |> Enum.map(fn {v, i} -> {i, v} end)
                 |> Enum.reverse()

        test = self()
        ref = make_ref()

        assert await(AsyncIterator.for_each(from.(), &send(test, {ref, &2, &1}), concurrency)) ==
                 :ok

        calls = for _value <- values, do: assert_receive({^ref, _counter, _value})
        assert calls |> Enum.sort() |> Enum.map(&elem(&1, 2)) == values
      end
    end

    test "reduce/2 takes the first value as the accumulator, with the counter from 1" do
      iterator = AsyncIterator.from([:a, :b, :c])

      assert await(AsyncIterator.reduce(iterator, &[{&3, &2} | List.wrap(&1)])) == [
               {2, :c},
               {1, :b},
               :a
             ]
    end

    test "reduce/2 of an iterator with no value rejects with TypeError" do
      assert %TypeError{} = catch_exit(await(AsyncIterator.reduce(AsyncIterator.from([]), &+/2)))
    end

    test "an argument that is not valid rejects the promise" do
      iterator = AsyncIterator.from([1])

      assert %TypeError{message: "The value is not an async iterator" <> _} =
               catch_exit(await(AsyncIterator.to_array([1])))

      assert %TypeError{message: "The callback of forEach" <> _} =
               catch_exit(await(AsyncIterator.for_each(iterator, :no)))

      assert %TypeError{message: "The callback of reduce" <> _} =
               catch_exit(await(AsyncIterator.reduce(iterator, fn _a, _b, _c, _d -> :x end)))

      assert %RangeError{} = catch_exit(await(AsyncIterator.some(iterator, & &1, -1)))
      assert %TypeError{} = catch_exit(await(AsyncIterator.every(iterator, & &1, :many)))
      assert %TypeError{} = catch_exit(await(AsyncIterator.find(iterator, :no)))
    end

    test "some, every, and find close the iterator at their result, and settle after the close" do
      for {method, predicate, result} <- [
            {&AsyncIterator.some/2, &(&1 == :a), true},
            {&AsyncIterator.every/2, &(&1 != :a), false},
            {&AsyncIterator.find/2, &(&1 == :a), :a}
          ] do
        source = Script.new()
        promise = method.(source, predicate)
        Script.give(Script.assert_next(), :a)
        close = Script.assert_return()
        Script.settle([promise.pid])
        assert peek(promise) == :pending
        Script.finish(close)
        assert await(promise) == result
      end
    end

    test "a close that fails after the result rejects with its error" do
      source = Script.new()
      promise = AsyncIterator.find(source, & &1)
      Script.give(Script.assert_next(), :a)
      Script.fail(Script.assert_return(), :close)
      assert catch_exit(await(promise)) == :close
    end

    test "an error of a callback closes the iterator; an error of the iterator does not" do
      source = Script.new()
      promise = AsyncIterator.for_each(source, fn _value -> raise "callback" end)
      Script.give(Script.assert_next(), :a)
      Script.fail(Script.assert_return(), :close)
      assert %RuntimeError{message: "callback"} = catch_exit(await(promise))

      source = Script.new()
      promise = AsyncIterator.reduce(source, fn _acc, _value -> throw(:reducer) end, 0)
      Script.give(Script.assert_next(), :a)
      Script.finish(Script.assert_return())
      assert catch_exit(await(promise)) == :reducer

      source = Script.new()
      promise = AsyncIterator.to_array(source)
      Script.fail(Script.assert_next(), :source)
      assert catch_exit(await(promise)) == :source
      Script.settle([promise.pid])
      Script.refute_step()
    end

    test "with no concurrency, a method reads one value at a time" do
      source = Script.new()
      promise = AsyncIterator.for_each(source, blocking(:effect))
      Script.give(Script.assert_next(), :a)
      {:a, 0, effect} = assert_called(:effect)
      Script.settle([promise.pid])
      Script.refute_step()
      send(effect, {:go, :ok})
      Script.finish(Script.assert_next())
      assert await(promise) == :ok
    end

    test "a concurrency argument reads values, and runs callbacks, at the same time" do
      source = Script.new()
      promise = AsyncIterator.for_each(source, blocking(:effect), 2)
      first = Script.assert_next()
      second = Script.assert_next()
      Script.settle([promise.pid])
      Script.refute_step()

      Script.give(second, :b)
      Script.give(first, :a)
      [{:a, 0, a}, {:b, 1, b}] = assert_calls(:effect, 2)

      # The end of a callback gives its permit to the next read.
      send(b, {:go, :ok})
      Script.finish(Script.assert_next())
      Script.settle([promise.pid])
      assert peek(promise) == :pending
      send(a, {:go, :ok})
      assert await(promise) == :ok
    end

    test "a read that gives the end or an error stops the reads, also before the decision" do
      for answer <- [&Script.finish/1, &Script.fail(&1, :source)] do
        source = Script.new()
        promise = AsyncIterator.to_array(source, 2)
        first = Script.assert_next()
        answer.(Script.assert_next())
        Script.settle([promise.pid])
        Script.refute_step()

        Script.give(first, :a)
        result = Promise.wait(promise)
        assert result in [{:fulfilled, [:a]}, {:rejected, :source}]
      end
    end

    test "find with concurrency gives the first selected value in the sequence" do
      source = Script.new()
      promise = AsyncIterator.find(source, blocking(:predicate), 2)
      first = Script.assert_next()
      second = Script.assert_next()
      Script.give(first, :a)
      Script.give(second, :b)
      [{:a, 0, a}, {:b, 1, b}] = assert_calls(:predicate, 2)

      # :b is selected first, but the decision waits for :a. A decision
      # closes the source: no close comes.
      send(b, {:go, true})
      Script.settle([promise.pid])
      Script.refute_return()
      assert peek(promise) == :pending

      send(a, {:go, false})
      Script.finish(Script.assert_return())
      assert await(promise) == :b
    end

    test "reduce with concurrency calls the reducer in sequence, and limits the reads ahead" do
      source = Script.new()
      promise = AsyncIterator.reduce(source, blocking(:reducer), [], 2)
      first = Script.assert_next()
      second = Script.assert_next()
      Script.give(second, :b)
      Script.give(first, :a)

      {[], :a, reducer} = assert_called(:reducer)
      # The two jobs keep their permits: no third read before the reducer.
      Script.settle([promise.pid])
      Script.refute_step()
      refute_received {:reducer, _acc, _value, _pid}

      send(reducer, {:go, [:a]})
      {[:a], :b, reducer} = assert_called(:reducer)
      third = Script.assert_next()
      send(reducer, {:go, [:b, :a]})
      Script.finish(third)
      assert await(promise) == [:b, :a]
    end

    test "a counting governor is shared by two methods" do
      governor = Web.CountingGovernor.new(1)
      first = AsyncIterator.to_array(Script.new(), governor)
      second = AsyncIterator.to_array(Script.new(), governor)
      read = Script.assert_next()
      Script.settle([first.pid, second.pid, governor.pid])
      Script.refute_step()

      Script.finish(read)
      Script.finish(Script.assert_next())
      assert {await(first), await(second)} == {[], []}
    end

    test "an acquisition after the result is aborted, or its token goes back" do
      # A counting governor: the method gives each token back.
      governor = Web.CountingGovernor.new(2)
      held = await(Web.Governor.acquire(governor))
      promise = AsyncIterator.to_array(Script.new(), governor)
      read = Script.assert_next()
      Script.settle([promise.pid, governor.pid])
      assert map_size(:sys.get_state(governor.pid).waiting) == 1

      Script.finish(read)
      assert await(promise) == []
      eventually(fn -> match?(%{in_use: 1, waiting: %{}}, :sys.get_state(governor.pid)) end)
      Web.GovernorToken.release(held)

      # A governor that can abort: the method aborts the acquisition that it
      # does not need.
      governor = %AbortableManualGovernor{test: self()}
      promise = AsyncIterator.to_array(Script.new(), governor)
      assert_receive {:acquire, resolve, _reject}
      first = token(governor)
      resolve.(first)
      read = Script.assert_next()
      assert_receive {:acquire, _resolve, _reject}
      Script.finish(read)
      assert await(promise) == []
      assert_receive {:released, ref} when ref == first.ref
      assert_receive {:aborted, reject}
      reject.(Web.DOMException.abort_error())

      # A governor that cannot abort: the late token goes back.
      governor = %ManualGovernor{test: self()}
      promise = AsyncIterator.to_array(Script.new(), governor)
      assert_receive {:acquire, resolve, _reject}
      first = token(governor)
      resolve.(first)
      read = Script.assert_next()
      assert_receive {:acquire, late, _reject}
      Script.finish(read)
      assert await(promise) == []
      assert_receive {:released, ref} when ref == first.ref

      second = token(governor)
      late.(second)
      assert_receive {:released, ref} when ref == second.ref
    end

    test "a governor that rejects rejects the method, after the reads before it" do
      governor = %ManualGovernor{test: self()}
      source = Script.new()
      promise = AsyncIterator.to_array(source, governor)
      assert_receive {:acquire, resolve, _reject}
      resolve.(token(governor))
      read = Script.assert_next()
      assert_receive {:acquire, _resolve, reject}
      reject.(:no_token)
      Script.settle([promise.pid])
      assert peek(promise) == :pending

      Script.give(read, :a)
      Script.finish(Script.assert_return())
      assert catch_exit(await(promise)) == :no_token
    end
  end

  describe "Enumerable" do
    test "reads one value for each element" do
      assert 1..4 |> AsyncIterator.from() |> AsyncIterator.map(&(&1 * 2)) |> Enum.map(& &1) == [
               2,
               4,
               6,
               8
             ]

      assert [1, 2, 3] |> AsyncIterator.from() |> Enum.count() == 3
      assert [1, 2, 3] |> AsyncIterator.from() |> Enum.member?(2)
      assert [1, 2, 3] |> AsyncIterator.from() |> Enum.slice(1..1) == [2]
      assert [1, 2] |> AsyncIterator.from() |> Enum.zip([:a, :b]) == [{1, :a}, {2, :b}]
    end

    test "a halt closes the iterator" do
      assert closable([1, 2, 3]) |> AsyncIterator.from() |> Enum.take(1) == [1]
      assert_received :closed
    end

    test "a close that fails at a halt raises" do
      source = Script.new()
      task = Task.async(fn -> catch_error(source |> AsyncIterator.map(& &1) |> Enum.take(1)) end)
      Script.give(Script.assert_next(), :a)
      Script.fail(Script.assert_return(), :close)
      assert %TypeError{message: "The async iterator rejected.", cause: :close} = Task.await(task)
    end

    test "an error of the reducer closes the iterator, and goes to the caller" do
      iterator = closable([1, 2]) |> AsyncIterator.from()
      assert_raise ArithmeticError, fn -> Enum.each(iterator, fn value -> value / 0 end) end
      assert_received :closed
    end

    test "a rejection raises its exception, or a TypeError with the reason as its cause" do
      iterator =
        [1] |> AsyncIterator.from() |> AsyncIterator.map(fn _v -> raise ArgumentError end)

      assert_raise ArgumentError, fn -> Enum.to_list(iterator) end

      iterator = [1] |> AsyncIterator.from() |> AsyncIterator.map(fn _v -> throw(:thrown) end)
      assert %TypeError{cause: :thrown} = catch_error(Enum.to_list(iterator))
    end
  end

  describe "processes" do
    test "an iterator process takes each other message, and continues" do
      source = AsyncIterator.from([1, 2])
      helper = AsyncIterator.map(source, & &1)
      send(source.pid, :other)
      send(helper.pid, :other)
      Script.settle([source.pid, helper.pid])
      assert Enum.to_list(helper) == [1, 2]
    end

    test "the result of a job after the end has no effect" do
      source = Script.new()
      iterator = AsyncIterator.map(source, blocking(:map))
      first = AsyncIterator.next(iterator)
      second = AsyncIterator.next(iterator)
      Script.finish(Script.assert_next())
      Script.give(Script.assert_next(), :late)
      {:late, 1, job} = assert_called(:map)
      assert await(first) == done()
      assert await(second) == done()

      monitor = Process.monitor(iterator.pid)
      send(job, {:go, :ignored})
      assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
    end

    test "a helper stops after its end, and a step after that gives done" do
      iterator = [1] |> AsyncIterator.from() |> AsyncIterator.map(& &1)
      monitor = Process.monitor(iterator.pid)
      assert Enum.to_list(iterator) == [1]
      assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
      assert next(iterator) == done()
      assert await(AsyncIterator.return(iterator)) == done()
    end

    test "a helper stops with its owner, and stops its jobs" do
      test = self()
      source = Script.new()
      mapper = blocking(:map)

      owner =
        spawn(fn ->
          iterator = AsyncIterator.map(source, mapper)
          send(test, {:iterator, iterator, AsyncIterator.next(iterator)})
          Process.sleep(:infinity)
        end)

      assert_receive {:iterator, iterator, _promise}
      Script.give(Script.assert_next(), :a)
      {:a, 0, job} = assert_called(:map)
      monitors = Enum.map([iterator.pid, job], &Process.monitor/1)
      Process.exit(owner, :kill)

      for monitor <- monitors, do: assert_receive({:DOWN, ^monitor, :process, _pid, _reason})
    end

    test "a job that a different process kills fails with the reason, and closes the source" do
      source = Script.new()
      iterator = AsyncIterator.map(source, blocking(:map))
      promise = AsyncIterator.next(iterator)
      Script.give(Script.assert_next(), :a)
      {:a, 0, job} = assert_called(:map)
      Process.exit(job, :kill)
      Script.finish(Script.assert_return())
      assert catch_exit(await(promise)) == :killed
    end

    test "a close or an acquisition that a different process kills fails with the reason" do
      # The close.
      source = Script.new()
      iterator = AsyncIterator.map(source, & &1)
      promise = AsyncIterator.return(iterator)
      _close = Script.assert_return()
      Process.exit(linked(iterator.pid), :kill)
      assert catch_exit(await(promise)) == :killed

      # The acquisition of a permit.
      governor = %ManualGovernor{test: self()}
      iterator = AsyncIterator.limit(Script.new(), governor)
      promise = AsyncIterator.next(iterator)
      assert_receive {:acquire, _resolve, _reject}
      Process.exit(linked(iterator.pid), :kill)
      Script.finish(Script.assert_return())
      assert catch_exit(await(promise)) == :killed
    end

    test "a method stops with its owner, and stops its jobs" do
      test = self()
      source = Script.new()
      effect = blocking(:effect)

      owner =
        spawn(fn ->
          send(test, {:promise, AsyncIterator.for_each(source, effect)})
          Process.sleep(:infinity)
        end)

      assert_receive {:promise, promise}
      Script.give(Script.assert_next(), :a)
      {:a, 0, job} = assert_called(:effect)
      monitors = Enum.map([promise.pid, job], &Process.monitor/1)
      Process.exit(owner, :kill)

      for monitor <- monitors, do: assert_receive({:DOWN, ^monitor, :process, _pid, _reason})
    end

    test "a job of a method that a different process kills fails with the reason" do
      source = Script.new()
      promise = AsyncIterator.for_each(source, blocking(:effect))
      Script.give(Script.assert_next(), :a)
      {:a, 0, job} = assert_called(:effect)
      Process.exit(job, :kill)

      # The failure comes before the permit of the job goes back: no read
      # starts after it.
      close = Script.assert_return()
      Script.settle([promise.pid])
      Script.refute_step()
      Script.finish(close)
      assert catch_exit(await(promise)) == :killed

      # The job of reduce, during the reducer.
      source = Script.new()
      promise = AsyncIterator.reduce(source, blocking(:reducer), 0)
      Script.give(Script.assert_next(), :a)
      {0, :a, job} = assert_called(:reducer)
      Process.exit(job, :kill)
      Script.finish(Script.assert_return())
      assert catch_exit(await(promise)) == :killed

      # The job of reduce, before the reducer.
      source = Script.new()
      promise = AsyncIterator.reduce(source, blocking(:reducer), 0, 2)
      first = Script.assert_next()
      second = Script.assert_next()
      Script.give(second, :b)
      Script.settle([promise.pid])
      Process.exit(job_of(promise.pid, 1), :kill)
      Script.give(first, :a)
      {0, :a, reducer} = assert_called(:reducer)
      send(reducer, {:go, 1})
      Script.finish(Script.assert_return())
      assert catch_exit(await(promise)) == :killed
    end

    test "a close or an acquisition of a method that a different process kills fails" do
      source = Script.new()
      promise = AsyncIterator.some(source, & &1)
      Script.give(Script.assert_next(), :a)
      _close = Script.assert_return()
      Process.exit(linked(promise.pid), :kill)
      assert catch_exit(await(promise)) == :killed

      governor = %ManualGovernor{test: self()}
      promise = AsyncIterator.to_array(Script.new(), governor)
      assert_receive {:acquire, _resolve, _reject}
      Process.exit(linked(promise.pid), :kill)
      Script.finish(Script.assert_return())
      assert catch_exit(await(promise)) == :killed
    end
  end
end
