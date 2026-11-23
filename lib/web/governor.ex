defmodule Web.Governor do
  @moduledoc """
  The functions of a governor, as `Governor` of the TC39 proposal
  "concurrency control".

  A governor limits the work that runs at the same time. It gives a
  `Web.GovernorToken` for each acquisition. The module of the governor, for
  example `Web.CountingGovernor`, decides when an acquisition gets its
  token.

  ## Examples

      iex> governor = Web.CountingGovernor.new(2)
      iex> Web.await(Web.Governor.with(governor, fn -> :done end))
      :done
  """

  alias Web.AsyncIterator
  alias Web.GovernorToken
  alias Web.Internal.Arity
  alias Web.Promise

  @type t :: struct()

  @doc """
  Acquires a token from the governor, as `acquire()`. Returns a promise of
  a `Web.GovernorToken`.
  """
  @spec acquire(t()) :: Promise.t()
  def acquire(%module{} = governor) do
    module.acquire(governor)
  end

  @doc """
  Runs `fun` with no argument while the work holds a token, as `with(fn)`.
  Returns a promise of the result of `fun`.

  The token is released after `fun` settles, also when the callback raises
  or returns a `Web.Promise` that rejects.
  """
  @spec with(t(), (-> term())) :: Promise.t()
  def with(%_{} = governor, fun) when is_function(fun, 0) do
    Promise.new(fn resolve, reject ->
      case await_settled(acquire(governor)) do
        {:ok, token} ->
          try do
            fun.()
            |> await_settled()
            |> settle(resolve, reject)
          catch
            _, reason ->
              reject.(reason)
          after
            GovernorToken.release(token)
          end

        {:error, reason} ->
          reject.(reason)
      end
    end)
  end

  @doc """
  Returns a function that calls `fun` with `with/2`, as `wrap(fn)`. The new
  function takes the arguments of `fun` and returns a promise. `fun` can
  have 0 to 20 arguments.
  """
  @spec wrap(t(), function()) :: function()
  def wrap(%_{} = governor, fun) when is_function(fun) do
    Arity.wrap(fun, fn arguments -> __MODULE__.with(governor, fn -> apply(fun, arguments) end) end)
  end

  @doc """
  Returns an async iterator of the values of `iterator`, as
  `wrapIterator(it)`. Each step of `iterator` holds a token of the
  governor: the governor limits the steps that run at the same time.

  `iterator` is an enumerable, as an `Iterator`, or an async iterator of
  this library, as an `AsyncIterator`: see `Web.AsyncIterator.from/1`. The
  result is a `Web.AsyncIterator`, as the proposal specifies. It is
  `Web.AsyncIterator.limit/2` of the iterator: each call of
  `Web.AsyncIterator.next/1` acquires a token, takes the next value of
  `iterator`, and releases the token when the step settles. A step that
  raises releases the token, and `next/1` rejects with the error.
  `Web.AsyncIterator.return/1` stops `iterator`.

  Raises `Web.TypeError` for a value that is not an iterator.

  ## Examples

      iex> governor = Web.CountingGovernor.new(1)
      iex> iterator = Web.Governor.wrap_iterator(governor, [:a, :b])
      iex> Web.await(Web.AsyncIterator.next(iterator))
      %{value: :a, done: false}
      iex> Web.await(Web.AsyncIterator.next(iterator))
      %{value: :b, done: false}
      iex> Web.await(Web.AsyncIterator.next(iterator))
      %{value: nil, done: true}
  """
  @spec wrap_iterator(t(), Enumerable.t() | AsyncIterator.async_iterator()) :: AsyncIterator.t()
  def wrap_iterator(%_{} = governor, iterator) do
    iterator |> AsyncIterator.from() |> AsyncIterator.limit(governor)
  end

  defp await_settled(%Promise{} = promise) do
    case Promise.wait(promise) do
      {:fulfilled, value} -> {:ok, value}
      {:rejected, reason} -> {:error, reason}
    end
  end

  defp await_settled(value), do: {:ok, value}

  defp settle({:ok, value}, resolve, _reject), do: resolve.(value)
  defp settle({:error, reason}, _resolve, reject), do: reject.(reason)
end
