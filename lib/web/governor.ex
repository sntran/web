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

  alias Web.GovernorToken
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
  have 0 to 8 arguments.
  """
  @spec wrap(t(), function()) :: function()
  def wrap(%_{} = governor, fun) when is_function(fun) do
    case :erlang.fun_info(fun, :arity) do
      {:arity, arity} -> wrap_with_arity(governor, fun, arity)
    end
  end

  defp wrap_with_arity(governor, fun, 0), do: fn -> __MODULE__.with(governor, fun) end

  defp wrap_with_arity(governor, fun, 1),
    do: fn a -> __MODULE__.with(governor, fn -> fun.(a) end) end

  defp wrap_with_arity(governor, fun, 2),
    do: fn a, b -> __MODULE__.with(governor, fn -> fun.(a, b) end) end

  defp wrap_with_arity(governor, fun, 3),
    do: fn a, b, c -> __MODULE__.with(governor, fn -> fun.(a, b, c) end) end

  defp wrap_with_arity(governor, fun, 4),
    do: fn a, b, c, d -> __MODULE__.with(governor, fn -> fun.(a, b, c, d) end) end

  defp wrap_with_arity(governor, fun, 5),
    do: fn a, b, c, d, e -> __MODULE__.with(governor, fn -> fun.(a, b, c, d, e) end) end

  defp wrap_with_arity(governor, fun, 6),
    do: fn a, b, c, d, e, f -> __MODULE__.with(governor, fn -> fun.(a, b, c, d, e, f) end) end

  defp wrap_with_arity(governor, fun, 7) do
    fn a, b, c, d, e, f, g -> __MODULE__.with(governor, fn -> fun.(a, b, c, d, e, f, g) end) end
  end

  defp wrap_with_arity(governor, fun, 8) do
    fn a, b, c, d, e, f, g, h ->
      __MODULE__.with(governor, fn -> fun.(a, b, c, d, e, f, g, h) end)
    end
  end

  defp wrap_with_arity(_governor, _fun, arity) do
    raise ArgumentError, "wrap/2 supports function arities 0..8, got: #{arity}"
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
