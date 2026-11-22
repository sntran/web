defmodule Web.Internal.Iterable do
  @moduledoc false

  # The operation `forEach` of a pair iterable of Web IDL, for
  # `Web.Headers.for_each/2`, `Web.URLSearchParams.for_each/2`, and
  # `Web.FormData.for_each/2`.
  #
  # Web IDL invokes the callback with « value, key, object » for each pair.
  # A JavaScript function ignores the arguments that it does not declare.
  # A function of Elixir has a fixed arity: a callback of arity 0, 1, 2, or
  # 3 gets the first arguments of the three. Each other value raises
  # `Web.TypeError`, as the conversion of Web IDL to a callback function.
  # An exception of the callback goes to the caller ("rethrow").

  @doc false
  @spec for_each(Enumerable.t(), term(), term()) :: :ok
  def for_each(pairs, object, callback) do
    invoke = invoker(callback)

    Enum.each(pairs, fn
      {key, value} -> invoke.(value, key, object)
      [key, value] -> invoke.(value, key, object)
    end)
  end

  defp invoker(callback) when is_function(callback, 0),
    do: fn _value, _key, _object -> callback.() end

  defp invoker(callback) when is_function(callback, 1),
    do: fn value, _key, _object -> callback.(value) end

  defp invoker(callback) when is_function(callback, 2),
    do: fn value, key, _object -> callback.(value, key) end

  defp invoker(callback) when is_function(callback, 3), do: callback

  defp invoker(callback) do
    raise Web.TypeError,
          "The callback of forEach must be a function of arity 0 to 3, not #{inspect(callback)}."
  end
end
