defmodule Web.Internal.Arity do
  @moduledoc false

  # A function of ECMAScript takes each number of arguments, and a wrapper
  # such as `AsyncContext.Snapshot.wrap(fn)` gives them all to the function
  # that it wraps. A function of Erlang has a fixed arity. This module makes
  # a function with the arity of a given function: it collects the
  # arguments in a list, and gives the list to a callback.

  @max_arity 20

  @doc """
  Returns a function with the arity of `fun`. The function calls `callback`
  with the list of its arguments, and returns its result.

  Raises `ArgumentError` for an arity above #{@max_arity}.
  """
  @spec wrap(function(), (list() -> result)) :: function() when result: term()
  def wrap(fun, callback) when is_function(fun) and is_function(callback, 1) do
    {:arity, arity} = Function.info(fun, :arity)
    collect(arity, callback)
  end

  # One clause for each arity, made when the module compiles.
  for arity <- 0..@max_arity do
    arguments = Macro.generate_arguments(arity, __MODULE__)

    defp collect(unquote(arity), callback) do
      fn unquote_splicing(arguments) -> callback.(unquote(arguments)) end
    end
  end

  defp collect(arity, _callback) do
    raise ArgumentError,
          "The function can have 0 to #{@max_arity} arguments, got: #{arity}"
  end
end
