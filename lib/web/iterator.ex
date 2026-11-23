defmodule Web.Iterator do
  @moduledoc """
  The iterator helpers of ECMAScript 2025, and `toAsync()` of the TC39
  proposal "async iterator helpers".

  `from/1` gives an iterator, as `Iterator.from()`. The other functions are
  the methods of `Iterator.prototype`. Each of them takes a `Web.Iterator`
  as its first argument.

      iex> iterator =
      ...>   [1, 2, 3, 4]
      ...>   |> Web.Iterator.from()
      ...>   |> Web.Iterator.map(fn value -> value * 10 end)
      ...>   |> Web.Iterator.filter(fn value -> value > 10 end)
      iex> Web.Iterator.to_array(iterator)
      [20, 30, 40]

  ## The methods

    * `next/1` and `return/1` are the methods of each iterator. They give
      an iterator result: `%{value: value, done: false}`, or
      `%{value: nil, done: true}` at the end.
    * `map/2`, `filter/2`, `take/2`, `drop/2`, and `flat_map/2` give a new
      iterator. The new iterator is lazy: it reads its source only for its
      own `next/1`.
    * `reduce/2`, `reduce/3`, `to_array/1`, `for_each/2`, `some/2`,
      `every/2`, and `find/2` read the iterator, and give the result.
    * `to_async/1` gives a `Web.AsyncIterator` of the iterator.

  A callback gets the value and its counter: the index of the value in the
  source, from 0. A callback of `reduce` gets the accumulator, the value,
  and the counter. A function of ECMAScript ignores the arguments that it
  does not declare: thus a callback can have fewer arguments, for example
  `&String.upcase/1`. A predicate selects a value when its result is not
  `false` and not `nil`.

  ## The state of an iterator

  An iterator of ECMAScript keeps its state: each call of `next/1` gives
  the next value. A `Web.Iterator` is thus a process, as the
  `Web.AsyncIterator` of an enumerable. `next/1` and `return/1` are calls
  of that process, in their sequence. A call from a different process
  waits until the step that runs ends.

  The process belongs to the process that made the iterator, as a
  `Web.ReadableStream`, and stops when that process stops. Then the
  iterator of an enumerable halts the enumerable. The process also stops
  at its end: after `done: true`, after an error, and after `return/1`.
  Then `next/1` and `return/1` give `done: true`, as a generator that is
  completed.

  The steps of a helper run in its process: the reads of its source, and
  its callback, with the `Web.AsyncContext` of the call that made the
  helper. The code of an enumerable runs in the process of its iterator:
  thus a resource that the enumerable opens belongs to that process. The
  callbacks of the methods that give a value run in the caller.

  ## Errors and the close of the source

  An error of a callback (a raise, a throw, or an exit) goes to the caller
  of `next/1`, with its kind. The helper first closes its source with
  `return/1` (IfAbruptCloseIterator), and is then done. An error of the
  source goes to the caller, and the helper does not close the source.

  As in ECMAScript 2025, a callback that is not a function, and a limit
  that is not valid, close the iterator, and then raise `Web.TypeError` or
  `Web.RangeError`. A method that gives a value closes the iterator when
  it has its result before the end, for example `some/2` at the first
  selected value.

  A step of a helper that calls `next/1` of an iterator that runs in its
  own chain of calls, for example a mapper that calls `next/1` of its own
  helper, raises `Web.TypeError`, as GeneratorValidate, and does not wait
  for itself. ECMAScript has one thread: in Elixir, two processes whose
  callbacks call the iterators of each other in a cycle wait for each
  other, as two processes that call each other. See
  `tla/SyncIterator.tla`.

  ## Elixir glue

  A `Web.Iterator` is an `Enumerable`. The enumeration reads one value at
  a time, and a halt of the enumeration closes the iterator, as `break` in
  `for (const value of iterator)`.

      iex> ["a", "b", "c"] |> Web.Iterator.from() |> Enum.take(2)
      ["a", "b"]

  An enumerable is an iterable: `from/1` and the result of the mapper of
  `flat_map/2` take each enumerable, as `[Symbol.iterator]()` of an object.
  """

  alias Web.Internal.AsyncFromSyncIterator
  alias Web.Internal.AsyncStep
  alias Web.Internal.SyncIterator

  defstruct [:pid]

  @typedoc "A sync iterator. The fields are private."
  @type t :: %__MODULE__{pid: pid()}

  @typedoc "An iterator result."
  @type result :: %{value: term(), done: boolean()}

  # ---------------------------------------------------------------------------
  # Iterator.from
  # ---------------------------------------------------------------------------

  @doc """
  Gives an iterator of a value, as `Iterator.from(O)`.

    * A `Web.Iterator` stays the same.
    * A string: its code points, as the iterator of a `String`.
    * An enumerable, as an iterable: the iterator gives its elements. It
      takes the first element only at the first `next/1`, and `return/1`
      halts the enumerable.

  Raises `Web.TypeError` for each other value (GetIteratorFlattenable).

  ## Examples

      iex> iterator = Web.Iterator.from([:a])
      iex> Web.Iterator.next(iterator)
      %{value: :a, done: false}
      iex> Web.Iterator.next(iterator)
      %{value: nil, done: true}

      iex> "hé" |> Web.Iterator.from() |> Web.Iterator.to_array()
      ["h", "é"]
  """
  @spec from(term()) :: t()
  def from(%__MODULE__{} = iterator), do: iterator

  def from(value) do
    case SyncIterator.cursor(value, :iterate_strings) do
      {:ok, cursor} -> SyncIterator.start({:cursor, cursor})
      {:error, error} -> raise error
    end
  end

  # ---------------------------------------------------------------------------
  # The methods of each iterator
  # ---------------------------------------------------------------------------

  @doc """
  Takes the next value of the iterator, as `next()`.

  Returns `%{value: value, done: false}`, or `%{value: nil, done: true}` at
  the end. An error of the step raises in the caller, with its kind.

  ## Examples

      iex> iterator = Web.Iterator.from(1..2)
      iex> Web.Iterator.next(iterator)
      %{value: 1, done: false}
  """
  @spec next(t()) :: result()
  def next(iterator), do: iterator |> iterator!() |> SyncIterator.call(:next)

  @doc """
  Stops the iteration, as `return()`. Returns `%{value: nil, done: true}`.

  A helper closes its source (IteratorClose), and `flat_map/2` closes its
  inner iterator first. The iterator of an enumerable halts the
  enumerable. An error of the close raises. An iterator that is done gives
  the result and closes nothing.

  ## Examples

      iex> iterator = Web.Iterator.from([1, 2])
      iex> Web.Iterator.return(iterator)
      %{value: nil, done: true}
      iex> Web.Iterator.next(iterator)
      %{value: nil, done: true}
  """
  @spec return(t()) :: result()
  def return(iterator), do: iterator |> iterator!() |> SyncIterator.call(:return)

  # ---------------------------------------------------------------------------
  # The methods that give an iterator
  # ---------------------------------------------------------------------------

  @doc """
  Gives an iterator of the results of `mapper`, as `map(mapper)`.

  `mapper` gets the value and its counter.

  Raises `Web.TypeError` when `iterator` is not a `Web.Iterator`, or, after
  the close of the iterator, when `mapper` is not a function of arity 0 to
  2.

  ## Examples

      iex> [:a, :b]
      ...> |> Web.Iterator.from()
      ...> |> Web.Iterator.map(fn value, counter -> {counter, value} end)
      ...> |> Enum.to_list()
      [{0, :a}, {1, :b}]
  """
  @spec map(t(), function()) :: t()
  def map(iterator, mapper) do
    iterator = iterator!(iterator)
    SyncIterator.start({:map, iterator, callback!(iterator, mapper, 2, "map")})
  end

  @doc """
  Gives an iterator of the values that `predicate` selects, as
  `filter(predicate)`.

  `predicate` gets the value and its counter. The counter counts each
  value of the source.

  ## Examples

      iex> 1..6
      ...> |> Web.Iterator.from()
      ...> |> Web.Iterator.filter(&(rem(&1, 2) == 0))
      ...> |> Enum.to_list()
      [2, 4, 6]
  """
  @spec filter(t(), function()) :: t()
  def filter(iterator, predicate) do
    iterator = iterator!(iterator)
    SyncIterator.start({:filter, iterator, callback!(iterator, predicate, 2, "filter")})
  end

  @doc """
  Gives an iterator of the first `limit` values, as `take(limit)`.

  `limit` is a non-negative number or `:infinity`. A float goes to its
  integer part, as ToIntegerOrInfinity. The call of `next/1` after the
  last value closes the source.

  Raises `Web.TypeError` when `iterator` is not a `Web.Iterator`, and,
  after the close of the iterator, `Web.RangeError` for each other
  `limit`.

  ## Examples

      iex> Stream.iterate(1, &(&1 + 1))
      ...> |> Web.Iterator.from()
      ...> |> Web.Iterator.take(3)
      ...> |> Enum.to_list()
      [1, 2, 3]
  """
  @spec take(t(), non_neg_integer() | float() | :infinity) :: t()
  def take(iterator, limit) do
    iterator = iterator!(iterator)
    SyncIterator.start({:take, iterator, limit!(iterator, limit, "take")})
  end

  @doc """
  Gives an iterator of the values after the first `limit` values, as
  `drop(limit)`.

  The first call of `next/1` reads and drops the first `limit` values.
  `limit` is as for `take/2`.

  ## Examples

      iex> [1, 2, 3, 4]
      ...> |> Web.Iterator.from()
      ...> |> Web.Iterator.drop(2)
      ...> |> Enum.to_list()
      [3, 4]
  """
  @spec drop(t(), non_neg_integer() | float() | :infinity) :: t()
  def drop(iterator, limit) do
    iterator = iterator!(iterator)
    SyncIterator.start({:drop, iterator, limit!(iterator, limit, "drop")})
  end

  @doc """
  Gives an iterator of the values of the iterables that `mapper` gives, as
  `flatMap(mapper)`.

  `mapper` gets the value and its counter. Its result is a `Web.Iterator`
  or an enumerable. A string is not an iterable here
  (GetIteratorFlattenable with reject-primitives): the helper closes its
  source, and raises `Web.TypeError`. The helper reads all the values of
  an inner iterator before it reads its source again, and `return/1`
  closes the inner iterator and then the source.

  ## Examples

      iex> [1, 2]
      ...> |> Web.Iterator.from()
      ...> |> Web.Iterator.flat_map(fn value -> [value, value * 10] end)
      ...> |> Enum.to_list()
      [1, 10, 2, 20]
  """
  @spec flat_map(t(), function()) :: t()
  def flat_map(iterator, mapper) do
    iterator = iterator!(iterator)
    SyncIterator.start({:flat_map, iterator, callback!(iterator, mapper, 2, "flatMap"), nil})
  end

  # ---------------------------------------------------------------------------
  # The methods that give a value
  # ---------------------------------------------------------------------------

  @doc """
  Reduces the values to one value, as `reduce(reducer)`, with the first
  value as the initial value.

  `reducer` gets the accumulator, the value, and its counter (from 1), and
  gives the next accumulator. Raises `Web.TypeError` for an iterator with
  no value.

  ## Examples

      iex> [1, 2, 3] |> Web.Iterator.from() |> Web.Iterator.reduce(&+/2)
      6
  """
  @spec reduce(t(), function()) :: term()
  def reduce(iterator, reducer) do
    iterator = iterator!(iterator)
    reducer = callback!(iterator, reducer, 3, "reduce")

    case SyncIterator.call(iterator, :next) do
      %{done: true} ->
        raise Web.TypeError, "Reduce of an empty iterator with no initial value."

      %{value: first} ->
        fold(iterator, reducer, first, 1)
    end
  end

  @doc """
  Reduces the values to one value from `initial_value`, as
  `reduce(reducer, initialValue)`.

  `reducer` gets the accumulator, the value, and its counter (from 0).

  ## Examples

      iex> ["a", "b"]
      ...> |> Web.Iterator.from()
      ...> |> Web.Iterator.reduce(fn acc, value, counter -> [{counter, value} | acc] end, [])
      [{1, "b"}, {0, "a"}]
  """
  @spec reduce(t(), function(), term()) :: term()
  def reduce(iterator, reducer, initial_value) do
    iterator = iterator!(iterator)
    fold(iterator, callback!(iterator, reducer, 3, "reduce"), initial_value, 0)
  end

  defp fold(iterator, reducer, accumulator, counter) do
    case SyncIterator.call(iterator, :next) do
      %{done: true} ->
        accumulator

      %{value: value} ->
        accumulator = SyncIterator.call_closing(reducer, [accumulator, value, counter], iterator)
        fold(iterator, reducer, accumulator, counter + 1)
    end
  end

  @doc """
  Reads all the values into a list, as `toArray()`.

  ## Examples

      iex> Web.Iterator.from(1..3) |> Web.Iterator.to_array()
      [1, 2, 3]
  """
  @spec to_array(t()) :: list()
  def to_array(iterator) do
    iterator = iterator!(iterator)
    collect(iterator, [])
  end

  defp collect(iterator, values) do
    case SyncIterator.call(iterator, :next) do
      %{done: true} -> Enum.reverse(values)
      %{value: value} -> collect(iterator, [value | values])
    end
  end

  @doc """
  Calls `fun` for each value, as `forEach(fn)`. Returns `:ok`.

  `fun` gets the value and its counter.

  ## Examples

      iex> [:a, :b]
      ...> |> Web.Iterator.from()
      ...> |> Web.Iterator.for_each(fn value -> send(self(), value) end)
      :ok
  """
  @spec for_each(t(), function()) :: :ok
  def for_each(iterator, fun) do
    iterator = iterator!(iterator)
    fun = callback!(iterator, fun, 2, "forEach")

    each_value(iterator, 0, fn arguments ->
      _result = fun.(arguments)
      :cont
    end) || :ok
  end

  @doc """
  Tells if `predicate` selects a value, as `some(predicate)`.

  Returns `true` at the first selected value, after the close of the
  iterator, and `false` at the end.

  ## Examples

      iex> [1, 2, 3] |> Web.Iterator.from() |> Web.Iterator.some(&(&1 > 2))
      true
  """
  @spec some(t(), function()) :: boolean()
  def some(iterator, predicate) do
    iterator = iterator!(iterator)
    predicate = callback!(iterator, predicate, 2, "some")

    each_value(iterator, 0, fn arguments ->
      if AsyncStep.truthy?(predicate.(arguments)), do: {:halt, true}, else: :cont
    end) || false
  end

  @doc """
  Tells if `predicate` selects each value, as `every(predicate)`.

  Returns `false` at the first value that the predicate does not select,
  after the close of the iterator, and `true` at the end.

  ## Examples

      iex> [1, 2, 3] |> Web.Iterator.from() |> Web.Iterator.every(&(&1 > 0))
      true
  """
  @spec every(t(), function()) :: boolean()
  def every(iterator, predicate) do
    iterator = iterator!(iterator)
    predicate = callback!(iterator, predicate, 2, "every")

    each_value(iterator, 0, fn arguments ->
      if AsyncStep.truthy?(predicate.(arguments)), do: :cont, else: {:halt, false}
    end) != false
  end

  @doc """
  Gives the first value that `predicate` selects, as `find(predicate)`.

  Returns the value, after the close of the iterator, or `nil` at the end.

  ## Examples

      iex> [1, 2, 3] |> Web.Iterator.from() |> Web.Iterator.find(&(&1 > 1))
      2
  """
  @spec find(t(), function()) :: term()
  def find(iterator, predicate) do
    iterator = iterator!(iterator)
    predicate = callback!(iterator, predicate, 2, "find")

    each_value(iterator, 0, fn [value, _counter] = arguments ->
      if AsyncStep.truthy?(predicate.(arguments)), do: {:halt, value}, else: :cont
    end)
  end

  # The loop of `forEach`, `some`, `every`, and `find`: calls `step` with
  # the value and its counter, until the end (the result is nil) or a
  # result `{:halt, result}`. An error of `step` closes the iterator. A
  # result before the end closes the iterator with a normal completion: an
  # error of that close raises.
  defp each_value(iterator, counter, step) do
    case SyncIterator.call(iterator, :next) do
      %{done: true} ->
        nil

      %{value: value} ->
        case SyncIterator.call_closing(step, [value, counter], iterator) do
          :cont ->
            each_value(iterator, counter + 1, step)

          {:halt, result} ->
            _closed = SyncIterator.call(iterator, :return)
            result
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Iterator.prototype.toAsync
  # ---------------------------------------------------------------------------

  @doc """
  Gives an async iterator of the iterator, as `toAsync()` of the TC39
  proposal "async iterator helpers".

  The result is a `Web.AsyncIterator`: CreateAsyncFromSyncIterator, in a
  wrapper. Its `Web.AsyncIterator.next/1` calls `next/1` of the iterator
  in a different process, and a value that is a `Web.Promise` gives the
  value of the promise. A promise that rejects closes the iterator, and
  the async iterator rejects. Its `Web.AsyncIterator.return/1` calls
  `return/1` of the iterator.

  Raises `Web.TypeError` when `iterator` is not a `Web.Iterator`.

  ## Examples

      iex> async =
      ...>   [1, 2]
      ...>   |> Web.Iterator.from()
      ...>   |> Web.Iterator.to_async()
      ...>   |> Web.AsyncIterator.map(fn value -> Web.Promise.resolve(value * 2) end)
      iex> Web.await(Web.AsyncIterator.to_array(async))
      [2, 4]
  """
  @spec to_async(t()) :: Web.AsyncIterator.t()
  def to_async(iterator), do: iterator |> iterator!() |> AsyncFromSyncIterator.start()

  # ---------------------------------------------------------------------------
  # Arguments
  # ---------------------------------------------------------------------------

  # "If O is not an Object, throw a TypeError exception."
  defp iterator!(%__MODULE__{} = iterator), do: iterator

  defp iterator!(value) do
    raise Web.TypeError, "The value is not an iterator: #{inspect(value)}"
  end

  # "If IsCallable(mapper) is false, then Let error be ThrowCompletion(a
  # newly created TypeError object). Return ? IteratorClose(iterated,
  # error)."
  defp callback!(iterator, fun, max, method) do
    AsyncStep.callback!(fun, max, method)
  rescue
    error in Web.TypeError ->
      SyncIterator.close_quietly(iterator)
      reraise error, __STACKTRACE__
  end

  # ToNumber, ToIntegerOrInfinity, and the checks of `take` and `drop`, with
  # the close of the iterator for a limit that is not valid.
  defp limit!(_iterator, :infinity, _method), do: :infinity
  defp limit!(_iterator, limit, _method) when is_integer(limit) and limit >= 0, do: limit
  defp limit!(_iterator, limit, _method) when is_float(limit) and limit > -1.0, do: trunc(limit)

  defp limit!(iterator, limit, method) do
    SyncIterator.close_quietly(iterator)

    raise Web.RangeError,
          "The limit of #{method} must be a non-negative number or :infinity, got: " <>
            inspect(limit)
  end
end

defimpl Enumerable, for: Web.Iterator do
  alias Web.Internal.SyncIterator

  # The enumeration reads one value for each element, as `for of`. A halt
  # closes the iterator, as the `break` of a loop: an error of that close
  # raises. An error of the reducer closes the iterator, and then goes to
  # the caller.
  def reduce(iterator, {:halt, acc}, _fun) do
    _closed = SyncIterator.call(iterator, :return)
    {:halted, acc}
  end

  def reduce(iterator, {:suspend, acc}, fun), do: {:suspended, acc, &reduce(iterator, &1, fun)}

  def reduce(iterator, {:cont, acc}, fun) do
    case SyncIterator.call(iterator, :next) do
      %{done: true} ->
        {:done, acc}

      %{value: value} ->
        reduce(
          iterator,
          SyncIterator.call_closing(fn [v, a] -> fun.(v, a) end, [value, acc], iterator),
          fun
        )
    end
  end

  def count(_iterator), do: {:error, __MODULE__}
  def member?(_iterator, _element), do: {:error, __MODULE__}
  def slice(_iterator), do: {:error, __MODULE__}
end
