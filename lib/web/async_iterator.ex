defmodule Web.AsyncIterator do
  @moduledoc """
  The async iterator helpers of the TC39 proposal "async iterator
  helpers", with the concurrency arguments of the TC39 proposal
  "concurrency control".

  `from/1` gives an async iterator, as `AsyncIterator.from()`. The other
  functions are the methods of `AsyncIterator.prototype`. Each of them
  takes an async iterator of this library as its first argument: a
  `Web.AsyncIterator`, or a `Web.ReadableStreamAsyncIterator` (from
  `Web.ReadableStream.values/2`). `Web.Governor.wrap_iterator/2` also
  gives a `Web.AsyncIterator`.

      iex> iterator =
      ...>   [1, 2, 3, 4]
      ...>   |> Web.AsyncIterator.from()
      ...>   |> Web.AsyncIterator.map(fn value -> value * 10 end)
      ...>   |> Web.AsyncIterator.filter(fn value -> value > 10 end)
      iex> Web.await(Web.AsyncIterator.to_array(iterator))
      [20, 30, 40]

  ## The methods

    * `map/2`, `filter/2`, `take/2`, `drop/2`, `flat_map/2`, and `limit/2`
      give a new async iterator. The new iterator is lazy: it reads the
      first value of its source only at the first `next/1`.
    * `reduce/2`, `to_array/1`, `for_each/2`, `some/2`, `every/2`, and
      `find/2` read the iterator and give a `Web.Promise` of the result.
    * `next/1` and `return/1` are the methods of each async iterator. The
      promise fulfils with an iterator result, `%{value: value, done:
      false}`, or `%{value: nil, done: true}` at the end.

  A callback gets the value and its counter: the index of the value in the
  source, from 0. A callback of `reduce/2` gets the accumulator, the value,
  and the counter. A function of ECMAScript ignores the arguments that it
  does not declare: thus a callback can have fewer arguments, for example
  `&String.upcase/1`. A callback that returns a `Web.Promise` gives the
  value of the promise. A predicate selects a value when its result is not
  `false` and not `nil`.

  ## Errors and the close of the source

  A raise, a throw, or an exit of a callback rejects the promise with that
  reason. Then the helper closes its source with `return/1`
  (AsyncIteratorClose), and the iteration is done. An error of the source
  also rejects, but the helper does not close the source. After the end or
  an error, `next/1` gives `done: true`. A method that gives a value closes
  the iterator when it has its result before the end, for example `some/2`
  at the first selected value.

  ## Concurrent calls of `next/1`

  Each call of `next/1` on a helper starts its own step. Thus the mapper of
  `map/2` can run for many values at the same time. The calls get their
  results in their sequence, with the values that they get one after the
  other. `flat_map/2` reads all the values of an inner iterator before it
  reads its source again. A call of `return/1` comes after the calls of
  `next/1` before it.

  The methods that consume an iterator take a concurrency argument: a
  governor, for example a `Web.CountingGovernor`, or a non-negative
  integer, as a `Web.CountingGovernor` of that capacity. The method then
  reads many values at the same time, and runs its callback for them at
  the same time. The result is the same as with no concurrency argument:

      iex> iterator =
      ...>   1..5
      ...>   |> Web.AsyncIterator.from()
      ...>   |> Web.AsyncIterator.map(fn value -> Web.Promise.resolve(value * value) end)
      iex> Web.await(Web.AsyncIterator.to_array(iterator, 3))
      [1, 4, 9, 16, 25]

  `limit/2` gives an iterator that reads its source only with a token of
  the governor.

  ## Elixir glue

  A `Web.AsyncIterator` is an `Enumerable`. The enumeration reads one value
  at a time. A halt of the enumeration, for example `Enum.take/2`, closes
  the iterator. A rejection raises its reason when the reason is an
  exception, and else a `Web.TypeError`.

      iex> ["a", "b", "c"] |> Web.AsyncIterator.from() |> Enum.take(2)
      ["a", "b"]

  ## Processes

  A helper, and the iterator of an enumerable, is a process. It belongs to
  the process that made it, as a `Web.ReadableStream`, and stops when that
  process stops. It also stops after its end. Then `next/1` gives `done:
  true`. The callbacks run in other processes, with the `Web.AsyncContext`
  of the call that made the helper. The callbacks of a method that gives a
  value have the `Web.AsyncContext` of the call of the method.
  """

  alias Web.Internal.AsyncFromSyncIterator
  alias Web.Internal.AsyncIteration
  alias Web.Internal.AsyncIteratorConsumer
  alias Web.Internal.AsyncIteratorHelper
  alias Web.Internal.AsyncPermit
  alias Web.Internal.AsyncStep
  alias Web.Promise
  alias Web.ReadableStream
  alias Web.ReadableStreamAsyncIterator

  defstruct [:pid, :source]

  @typedoc """
  An async iterator: a helper, or a wrapper of a different iterator. The
  fields are private.
  """
  @type t :: %__MODULE__{pid: pid() | nil, source: ReadableStreamAsyncIterator.t() | nil}

  @typedoc "An async iterator of this library."
  @type async_iterator :: t() | ReadableStreamAsyncIterator.t()

  @typedoc "A governor, or a non-negative integer for a counting governor."
  @type concurrency :: struct() | non_neg_integer()

  @typedoc "An iterator result."
  @type result :: %{value: term(), done: boolean()}

  # ---------------------------------------------------------------------------
  # AsyncIterator.from
  # ---------------------------------------------------------------------------

  @doc """
  Gives an async iterator of a value, as `AsyncIterator.from(O)`.

    * An async iterator of this library: a `Web.AsyncIterator` stays the
      same, and a `Web.ReadableStreamAsyncIterator` gets a wrapper.
    * A `Web.ReadableStream`: the iterator of `Web.ReadableStream.values/2`,
      as `[Symbol.asyncIterator]()` of the stream. The iterator takes the
      lock of the stream.
    * A string: its code points, as the iterator of a `String`.
    * An enumerable, as an iterable: the iterator gives its elements, as
      CreateAsyncFromSyncIterator. An element that is a `Web.Promise` gives
      the value of the promise. The iterator takes the first element only at
      the first `next/1`, and `return/1` halts the enumerable.

  Raises `Web.TypeError` for each other value.

  ## Examples

      iex> iterator = Web.AsyncIterator.from([:a])
      iex> Web.await(Web.AsyncIterator.next(iterator))
      %{value: :a, done: false}
      iex> Web.await(Web.AsyncIterator.next(iterator))
      %{value: nil, done: true}

      iex> Web.AsyncIterator.from("hé") |> Web.AsyncIterator.to_array() |> Web.await()
      ["h", "é"]
  """
  @spec from(term()) :: t()
  def from(value), do: __from__(value, :iterate_strings)

  @doc false
  # GetIteratorFlattenable(O, async). `from/1` iterates a string, and
  # `flat_map/2` rejects it, as a primitive value.
  @spec __from__(term(), :iterate_strings | :reject_strings) :: t()
  def __from__(%__MODULE__{} = iterator, _strings), do: iterator

  def __from__(%ReadableStreamAsyncIterator{} = iterator, _strings),
    do: %__MODULE__{source: iterator}

  def __from__(%ReadableStream{} = stream, _strings),
    do: %__MODULE__{source: ReadableStream.values(stream)}

  def __from__(string, :iterate_strings) when is_binary(string),
    do: AsyncFromSyncIterator.start(String.codepoints(string))

  def __from__(value, _strings) do
    if is_binary(value) or is_nil(Enumerable.impl_for(value)) do
      raise Web.TypeError, "The value is not an async iterator or an iterable: #{inspect(value)}"
    end

    AsyncFromSyncIterator.start(value)
  end

  # ---------------------------------------------------------------------------
  # The methods of each async iterator
  # ---------------------------------------------------------------------------

  @doc """
  Takes the next value of the iterator, as `next()`. Returns a promise of
  an iterator result.

  The function takes each async iterator of this library.
  """
  @spec next(async_iterator()) :: Promise.t()
  def next(iterator), do: iterator |> iterator!() |> AsyncIteration.promise(:next)

  @doc """
  Stops the iteration, as `return()`. Returns a promise of
  `%{value: nil, done: true}`.

  A helper closes its source when the calls of `next/1` before it have
  their results: the promise fulfils after the close, and rejects with the
  error of a close that fails. A helper that is done gives the result at
  once. The method `return()` of a helper and of a wrapper has no
  argument: `value` goes only to the method of a
  `Web.ReadableStreamAsyncIterator`, as the reason of the cancel.
  """
  @spec return(async_iterator(), term()) :: Promise.t()
  def return(iterator, value \\ nil) do
    iterator |> iterator!() |> AsyncIteration.promise({:return, value})
  end

  # ---------------------------------------------------------------------------
  # The methods that give an iterator
  # ---------------------------------------------------------------------------

  @doc """
  Gives an iterator of the results of `mapper`, as `map(mapper)`.

  `mapper` gets the value and its counter. Concurrent calls of `next/1`
  run the mapper for many values at the same time.

  Raises `Web.TypeError` when `iterator` is not an async iterator, or
  `mapper` is not a function of arity 0 to 2.

  ## Examples

      iex> [:a, :b]
      ...> |> Web.AsyncIterator.from()
      ...> |> Web.AsyncIterator.map(fn value, counter -> {counter, value} end)
      ...> |> Enum.to_list()
      [{0, :a}, {1, :b}]
  """
  @spec map(async_iterator(), function()) :: t()
  def map(iterator, mapper) do
    iterator = iterator!(iterator)
    AsyncIteratorHelper.start(iterator, {:map, AsyncStep.callback!(mapper, 2, "map")})
  end

  @doc """
  Gives an iterator of the values that `predicate` selects, as
  `filter(predicate)`.

  `predicate` gets the value and its counter. It selects a value when its
  result is not `false` and not `nil`.

  Raises `Web.TypeError` when `iterator` is not an async iterator, or
  `predicate` is not a function of arity 0 to 2.

  ## Examples

      iex> 1..6
      ...> |> Web.AsyncIterator.from()
      ...> |> Web.AsyncIterator.filter(&(rem(&1, 2) == 0))
      ...> |> Enum.to_list()
      [2, 4, 6]
  """
  @spec filter(async_iterator(), function()) :: t()
  def filter(iterator, predicate) do
    iterator = iterator!(iterator)
    AsyncIteratorHelper.start(iterator, {:filter, AsyncStep.callback!(predicate, 2, "filter")})
  end

  @doc """
  Gives an iterator of the first `limit` values, as `take(limit)`.

  `limit` is a non-negative number or `:infinity`. A float goes to its
  integer part, as ToIntegerOrInfinity. The call of `next/1` after the
  last value closes the source.

  Raises `Web.TypeError` when `iterator` is not an async iterator, and
  `Web.RangeError` for each other `limit`.

  ## Examples

      iex> Stream.iterate(1, &(&1 + 1))
      ...> |> Web.AsyncIterator.from()
      ...> |> Web.AsyncIterator.take(3)
      ...> |> Enum.to_list()
      [1, 2, 3]
  """
  @spec take(async_iterator(), non_neg_integer() | float() | :infinity) :: t()
  def take(iterator, limit) do
    iterator = iterator!(iterator)
    AsyncIteratorHelper.start(iterator, {:take, limit!(limit, "take")})
  end

  @doc """
  Gives an iterator of the values after the first `limit` values, as
  `drop(limit)`.

  The first call of `next/1` reads and drops the first `limit` values.
  `limit` is as for `take/2`.

  Raises `Web.TypeError` when `iterator` is not an async iterator, and
  `Web.RangeError` for each other `limit`.

  ## Examples

      iex> [1, 2, 3, 4]
      ...> |> Web.AsyncIterator.from()
      ...> |> Web.AsyncIterator.drop(2)
      ...> |> Enum.to_list()
      [3, 4]
  """
  @spec drop(async_iterator(), non_neg_integer() | float() | :infinity) :: t()
  def drop(iterator, limit) do
    iterator = iterator!(iterator)
    AsyncIteratorHelper.start(iterator, {:drop, limit!(limit, "drop")})
  end

  @doc """
  Gives an iterator of the values of the iterables that `mapper` gives, as
  `flatMap(mapper)`.

  `mapper` gets the value and its counter. Its result is an async iterator,
  a `Web.ReadableStream`, or an enumerable, as for `from/1`. A string is
  not an iterable here: it rejects with `Web.TypeError`. The helper reads
  all the values of an inner iterator before it reads its source again,
  and `return/1` closes the inner iterator and then the source.

  Raises `Web.TypeError` when `iterator` is not an async iterator, or
  `mapper` is not a function of arity 0 to 2.

  ## Examples

      iex> [1, 2]
      ...> |> Web.AsyncIterator.from()
      ...> |> Web.AsyncIterator.flat_map(fn value -> [value, value * 10] end)
      ...> |> Enum.to_list()
      [1, 10, 2, 20]
  """
  @spec flat_map(async_iterator(), function()) :: t()
  def flat_map(iterator, mapper) do
    iterator = iterator!(iterator)
    AsyncIteratorHelper.start(iterator, {:flat_map, AsyncStep.callback!(mapper, 2, "flatMap")})
  end

  @doc """
  Gives an iterator that reads its source only with a permit of
  `governor`, as `limit(governor)` of the proposal for concurrency control.

  Each call of `next/1` acquires a token of the governor, reads the next
  value of the source, and releases the token when the read settles. Thus
  the governor limits the reads that run at the same time, for each number
  of calls of `next/1`. A non-negative integer is a `Web.CountingGovernor`
  of that capacity. The calls get their results in their sequence.
  `Web.Governor.wrap_iterator/2` is the same function, with its arguments
  in the other sequence.

  Raises `Web.TypeError` when `iterator` is not an async iterator, or
  `governor` is not a governor or an integer, and `Web.RangeError` for a
  negative integer.

  ## Examples

      iex> iterator = [:a, :b] |> Web.AsyncIterator.from() |> Web.AsyncIterator.limit(1)
      iex> Web.await(Web.AsyncIterator.to_array(iterator))
      [:a, :b]
  """
  @spec limit(async_iterator(), concurrency()) :: t()
  def limit(iterator, governor) do
    iterator = iterator!(iterator)
    AsyncIteratorHelper.start(iterator, {:limit, AsyncPermit.new!(governor)})
  end

  # ---------------------------------------------------------------------------
  # The methods that give a value
  # ---------------------------------------------------------------------------

  @doc """
  Reduces the values to one value, as `reduce(reducer)`, with the first
  value as the initial value.

  `reducer` gets the accumulator, the value, and its counter, and gives the
  next accumulator. The promise fulfils with the last accumulator. It
  rejects with `Web.TypeError` for an iterator with no value.

  The promise rejects with `Web.TypeError` when `iterator` is not an async
  iterator, or `reducer` is not a function of arity 0 to 3.

  ## Examples

      iex> [1, 2, 3] |> Web.AsyncIterator.from() |> Web.AsyncIterator.reduce(&+/2) |> Web.await()
      6
  """
  @spec reduce(async_iterator(), function()) :: Promise.t()
  def reduce(iterator, reducer) do
    consume(iterator, nil, fn -> {:reduce, AsyncStep.callback!(reducer, 3, "reduce"), :none} end)
  end

  @doc """
  Reduces the values to one value from `initial_value`, as
  `reduce(reducer, initialValue [, governor])`.

  `reducer` gets the accumulator, the value, and its counter. With a
  `concurrency` argument, the method reads many values at the same time,
  and calls the reducer for each value in the sequence of the values.

  ## Examples

      iex> ["a", "b"]
      ...> |> Web.AsyncIterator.from()
      ...> |> Web.AsyncIterator.reduce(fn acc, value, counter -> [{counter, value} | acc] end, [])
      ...> |> Web.await()
      [{1, "b"}, {0, "a"}]
  """
  @spec reduce(async_iterator(), function(), term(), concurrency() | nil) :: Promise.t()
  def reduce(iterator, reducer, initial_value, concurrency \\ nil) do
    consume(iterator, concurrency, fn ->
      {:reduce, AsyncStep.callback!(reducer, 3, "reduce"), {:ok, initial_value}}
    end)
  end

  @doc """
  Reads all the values into a list, as `toArray([governor])`.

  With a `concurrency` argument, the method reads many values at the same
  time. The list has the values in their sequence.

  ## Examples

      iex> Web.AsyncIterator.from(1..3) |> Web.AsyncIterator.to_array() |> Web.await()
      [1, 2, 3]
  """
  @spec to_array(async_iterator(), concurrency() | nil) :: Promise.t()
  def to_array(iterator, concurrency \\ nil) do
    consume(iterator, concurrency, fn -> :to_array end)
  end

  @doc """
  Calls `fun` for each value, as `forEach(fn [, governor])`. The promise
  fulfils with `:ok` after the last call.

  `fun` gets the value and its counter. With a `concurrency` argument, the
  calls run at the same time.

  ## Examples

      iex> [:a, :b]
      ...> |> Web.AsyncIterator.from()
      ...> |> Web.AsyncIterator.for_each(fn value -> send(self(), value) end)
      ...> |> Web.await()
      :ok
  """
  @spec for_each(async_iterator(), function(), concurrency() | nil) :: Promise.t()
  def for_each(iterator, fun, concurrency \\ nil) do
    consume(iterator, concurrency, fn -> {:for_each, AsyncStep.callback!(fun, 2, "forEach")} end)
  end

  @doc """
  Tells if `predicate` selects a value, as `some(predicate [, governor])`.

  The promise fulfils with `true` at the first selected value, after the
  close of the iterator, and with `false` at the end.

  ## Examples

      iex> [1, 2, 3] |> Web.AsyncIterator.from() |> Web.AsyncIterator.some(&(&1 > 2)) |> Web.await()
      true
  """
  @spec some(async_iterator(), function(), concurrency() | nil) :: Promise.t()
  def some(iterator, predicate, concurrency \\ nil) do
    consume(iterator, concurrency, fn -> {:some, AsyncStep.callback!(predicate, 2, "some")} end)
  end

  @doc """
  Tells if `predicate` selects each value, as
  `every(predicate [, governor])`.

  The promise fulfils with `false` at the first value that the predicate
  does not select, after the close of the iterator, and with `true` at the
  end.

  ## Examples

      iex> [1, 2, 3] |> Web.AsyncIterator.from() |> Web.AsyncIterator.every(&(&1 > 0)) |> Web.await()
      true
  """
  @spec every(async_iterator(), function(), concurrency() | nil) :: Promise.t()
  def every(iterator, predicate, concurrency \\ nil) do
    consume(iterator, concurrency, fn -> {:every, AsyncStep.callback!(predicate, 2, "every")} end)
  end

  @doc """
  Gives the first value that `predicate` selects, as
  `find(predicate [, governor])`.

  The promise fulfils with the value, after the close of the iterator, or
  with `nil` at the end. With a `concurrency` argument, the result is the
  first selected value in the sequence of the values, also when the
  predicate selects a later value first.

  ## Examples

      iex> [1, 2, 3] |> Web.AsyncIterator.from() |> Web.AsyncIterator.find(&(&1 > 1)) |> Web.await()
      2
  """
  @spec find(async_iterator(), function(), concurrency() | nil) :: Promise.t()
  def find(iterator, predicate, concurrency \\ nil) do
    consume(iterator, concurrency, fn -> {:find, AsyncStep.callback!(predicate, 2, "find")} end)
  end

  # An async method: an error of GetIteratorDirect or of an argument
  # rejects the promise.
  defp consume(iterator, concurrency, kind) do
    iterator = iterator!(iterator)
    kind = kind.()
    permit = AsyncPermit.new!(if is_nil(concurrency), do: 1, else: concurrency)
    AsyncIteratorConsumer.start(iterator, kind, permit)
  rescue
    error in [Web.TypeError, Web.RangeError] -> Promise.reject(error)
  end

  # ---------------------------------------------------------------------------
  # Arguments
  # ---------------------------------------------------------------------------

  # GetIteratorDirect: the value must be an async iterator.
  defp iterator!(iterator) do
    if is_nil(AsyncIteration.impl_for(iterator)) do
      raise Web.TypeError, "The value is not an async iterator: #{inspect(iterator)}"
    end

    iterator
  end

  # ToNumber, ToIntegerOrInfinity, and the checks of `take` and `drop`. A
  # float above -1 goes to an integer that is not negative.
  defp limit!(:infinity, _method), do: :infinity
  defp limit!(limit, _method) when is_integer(limit) and limit >= 0, do: limit
  defp limit!(limit, _method) when is_float(limit) and limit > -1.0, do: trunc(limit)

  defp limit!(limit, method) do
    raise Web.RangeError,
          "The limit of #{method} must be a non-negative number or :infinity, got: " <>
            inspect(limit)
  end
end

defimpl Enumerable, for: Web.AsyncIterator do
  alias Web.Internal.AsyncIteration
  alias Web.Internal.AsyncStep

  # The enumeration reads one value for each element, as `for await`. A
  # halt closes the iterator, as the `break` of a loop. An error of the
  # reducer closes the iterator, and then goes to the caller.
  def reduce(iterator, {:halt, acc}, _fun) do
    case AsyncStep.close(iterator, {:normal, acc}) do
      {:normal, acc} -> {:halted, acc}
      {:throw, reason} -> raise_error(reason)
    end
  end

  def reduce(iterator, {:suspend, acc}, fun), do: {:suspended, acc, &reduce(iterator, &1, fun)}

  def reduce(iterator, {:cont, acc}, fun) do
    case iterator |> AsyncIteration.request(:next, self()) |> AsyncStep.await() do
      {:fulfilled, %{done: true}} ->
        {:done, acc}

      {:fulfilled, %{value: value}} ->
        reduce(iterator, apply_reducer(iterator, fun, value, acc), fun)

      {:rejected, reason} ->
        raise_error(reason)
    end
  end

  defp apply_reducer(iterator, fun, value, acc) do
    fun.(value, acc)
  catch
    kind, reason ->
      _completion = AsyncStep.close(iterator, {:throw, reason})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp raise_error(reason) when is_exception(reason), do: raise(reason)

  defp raise_error(reason) do
    raise Web.TypeError, message: "The async iterator rejected.", cause: reason
  end

  def count(_iterator), do: {:error, __MODULE__}
  def member?(_iterator, _element), do: {:error, __MODULE__}
  def slice(_iterator), do: {:error, __MODULE__}
end
