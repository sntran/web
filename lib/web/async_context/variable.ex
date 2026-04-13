defmodule Web.AsyncContext.Variable do
  @moduledoc """
  A scoped asynchronous context variable inspired by TC39's `AsyncContext.Variable`.

  Each variable is an opaque handle backed by a unique process-dictionary key. Values
  are scoped: setting a variable inside `run/3` is visible only to code executing within
  that callback and any tasks that capture and restore the surrounding
  `Web.AsyncContext.Snapshot`.

  ## Creating a Variable

      iex> var = Web.AsyncContext.Variable.new("request_id")
      iex> is_struct(var, Web.AsyncContext.Variable)
      true

  ## Running with a Value

      iex> var = Web.AsyncContext.Variable.new("trace")
      iex> Web.AsyncContext.Variable.run(var, "abc-123", fn ->
      ...>   Web.AsyncContext.Variable.get(var)
      ...> end)
      "abc-123"

  ## Default Values

      iex> var = Web.AsyncContext.Variable.new("color", default: :blue)
      iex> Web.AsyncContext.Variable.get(var)
      :blue

  ## Context Propagation

  Variables registered via `new/2` are automatically captured by
  `Web.AsyncContext.Snapshot.take/0` and re-entered by
  `Web.AsyncContext.Snapshot.run/2`. This makes tracing, abort signals, and
  Logger metadata flow invisibly across BEAM process boundaries.
  """

  @registry_key {__MODULE__, :__registry__}

  defstruct [:name, :key, :default]

  @type t :: %__MODULE__{name: String.t(), key: term(), default: term()}

  @doc """
  Creates a new context variable.

  ## Options

    * `:default` — the value returned by `get/1` when the variable has not been
      set in the current scope. Defaults to `nil`.

  ## Examples

      iex> var = Web.AsyncContext.Variable.new("request_id")
      iex> var.name
      "request_id"
  """
  @spec new(String.t(), keyword()) :: t()
  def new(name, opts \\ []) when is_binary(name) do
    default = Keyword.get(opts, :default)
    key = {__MODULE__, make_ref()}

    var = %__MODULE__{name: name, key: key, default: default}

    # Register the key (not the full struct) so Snapshot.take/0 knows which
    # process-dictionary entries to capture. Storing only keys avoids redundant
    # duplication of name/default metadata in every snapshot.
    registry = Process.get(@registry_key, MapSet.new())
    Process.put(@registry_key, MapSet.put(registry, key))

    var
  end

  @doc """
  Returns the current value of the variable, or its default if unset.

  ## Examples

      iex> var = Web.AsyncContext.Variable.new("test", default: 42)
      iex> Web.AsyncContext.Variable.get(var)
      42
  """
  @spec get(t()) :: term()
  def get(%__MODULE__{key: key, default: default}) do
    case Process.get(key, :__async_context_unset__) do
      :__async_context_unset__ -> default
      value -> value
    end
  end

  @doc """
  Executes `fun` with `var` bound to `value`.

  The previous value (if any) is restored after `fun` returns, even if it raises.

  ## Examples

      iex> var = Web.AsyncContext.Variable.new("level")
      iex> Web.AsyncContext.Variable.run(var, 1, fn ->
      ...>   Web.AsyncContext.Variable.run(var, 2, fn ->
      ...>     Web.AsyncContext.Variable.get(var)
      ...>   end)
      ...> end)
      2
  """
  @spec run(t(), term(), (-> result)) :: result when result: var
  def run(%__MODULE__{key: key} = _var, value, fun) when is_function(fun, 0) do
    previous = Process.get(key, :__async_context_unset__)
    Process.put(key, value)

    try do
      fun.()
    after
      case previous do
        :__async_context_unset__ -> Process.delete(key)
        prev -> Process.put(key, prev)
      end
    end
  end

  @doc false
  @spec registry_key() :: term()
  def registry_key, do: @registry_key
end
