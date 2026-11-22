defmodule Web.AsyncContext.Variable do
  @moduledoc """
  A variable of the asynchronous context, as `AsyncContext.Variable` of the
  TC39 proposal "AsyncContext".

  A variable has a value only in the callback of `run/4`, and in the work
  that a `Web.AsyncContext.Snapshot` of that callback runs. A promise and a
  stream of this library take a snapshot, thus their callbacks see the
  value in a different process.

  ## Examples

      iex> var = Web.AsyncContext.Variable.new(name: "trace")
      iex> Web.AsyncContext.Variable.run(var, "abc-123", fn ->
      ...>   Web.AsyncContext.Variable.get(var)
      ...> end)
      "abc-123"

  With no value, `get/1` gives the default value:

      iex> var = Web.AsyncContext.Variable.new(name: "color", default_value: :blue)
      iex> Web.AsyncContext.Variable.get(var)
      :blue

  `Web.AsyncContext.Snapshot.new/0` keeps the values of all the variables,
  and `Web.AsyncContext.Snapshot.run/3` uses them again.
  """

  @registry_key {__MODULE__, :__registry__}

  defstruct name: "", key: nil, default_value: nil

  @typedoc "A variable. The field `key` is private."
  @type t :: %__MODULE__{name: String.t(), key: term(), default_value: term()}

  @doc """
  Makes a variable, as the constructor `new AsyncContext.Variable(options)`.

  ## Options

    * `:name` - the name of the variable, for a person that reads it. The
      value becomes a string. The default is `""`;
    * `:default_value` - the value of `get/1` when the variable has no
      value. The default is `nil`.

  ## Examples

      iex> var = Web.AsyncContext.Variable.new(name: "request_id")
      iex> var.name
      "request_id"
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) when is_list(options) do
    name = options |> Keyword.get(:name, "") |> to_string()
    default_value = Keyword.get(options, :default_value)
    key = {__MODULE__, make_ref()}

    var = %__MODULE__{name: name, key: key, default_value: default_value}

    # Register the key (not the full struct) so Snapshot.new/0 knows which
    # process-dictionary entries to capture. Storing only keys avoids redundant
    # duplication of name/default metadata in every snapshot.
    registry = Process.get(@registry_key, MapSet.new())
    Process.put(@registry_key, MapSet.put(registry, key))

    var
  end

  @doc """
  Returns the value of the variable, or its default value when it has no
  value, as `get()`.

  ## Examples

      iex> var = Web.AsyncContext.Variable.new(default_value: 42)
      iex> Web.AsyncContext.Variable.get(var)
      42
  """
  @spec get(t()) :: term()
  def get(%__MODULE__{key: key, default_value: default_value}) do
    case Process.get(key, :__async_context_unset__) do
      :__async_context_unset__ -> default_value
      value -> value
    end
  end

  @doc """
  Runs `fun` with `value` as the value of the variable, as
  `run(value, fn, ...args)`. `fun` gets the arguments of the list `args`.
  Returns the result of `fun`.

  After `fun`, the variable has its value from before again, also when
  `fun` raises.

  ## Examples

      iex> var = Web.AsyncContext.Variable.new(name: "level")
      iex> Web.AsyncContext.Variable.run(var, 1, fn ->
      ...>   Web.AsyncContext.Variable.run(var, 2, fn ->
      ...>     Web.AsyncContext.Variable.get(var)
      ...>   end)
      ...> end)
      2
  """
  @spec run(t(), term(), function(), list()) :: term()
  def run(%__MODULE__{key: key} = _var, value, fun, args \\ [])
      when is_function(fun, length(args)) do
    previous = Process.get(key, :__async_context_unset__)
    Process.put(key, value)

    try do
      apply(fun, args)
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
