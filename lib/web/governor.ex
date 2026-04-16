defmodule Web.Governor do
  @moduledoc """
  TC39 proposal-aligned governor helpers for limiting concurrent async work.

  A governor controls access to a bounded resource by handing out
  `Web.Governor.Token` values. The concrete governor implementation decides how
  acquisition, queueing, and release behave.
  """

  alias Web.Governor.Token
  alias Web.Promise

  @type t :: struct()

  @doc """
  Acquires a token from the governor.
  """
  @spec acquire(t()) :: Promise.t()
  def acquire(%module{} = governor) do
    module.acquire(governor)
  end

  @doc """
  Runs `fun` while holding a governor token.

  The token is released after `fun` settles, even if the callback raises or
  returns a rejected `%Web.Promise{}`.
  """
  @spec with(t(), function()) :: Promise.t()
  def with(%_{} = governor, fun) when is_function(fun) do
    Promise.new(fn resolve, reject ->
      case await_settled(acquire(governor)) do
        {:ok, token} ->
          try do
            fun
            |> invoke_fun(token)
            |> await_settled()
            |> settle(resolve, reject)
          catch
            _, reason ->
              reject.(reason)
          after
            Token.release(token)
          end

        {:error, reason} ->
          reject.(reason)
      end
    end)
  end

  @doc """
  Wraps a function so each call runs under the governor.
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

  defp invoke_fun(fun, _token) when is_function(fun, 0), do: fun.()
  defp invoke_fun(fun, token) when is_function(fun, 1), do: fun.(token)

  defp await_settled(%Promise{task: task}) do
    {:ok, Task.await(task, :infinity)}
  catch
    :exit, {{:shutdown, reason}, {Task, :await, _details}} -> {:error, reason}
    # coveralls-ignore-next-line
    :exit, {:shutdown, reason} -> {:error, reason}
    :exit, reason -> {:error, reason}
  end

  defp await_settled(value), do: {:ok, value}

  defp settle({:ok, value}, resolve, _reject), do: resolve.(value)
  defp settle({:error, reason}, _resolve, reject), do: reject.(reason)
end
