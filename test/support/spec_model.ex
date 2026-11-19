defmodule Web.Test.SpecModel do
  @moduledoc false

  # Runs a TLA+ specification of `tla/` one step at a time. A property test
  # uses it as the model: the test does an operation on the real code, does
  # the same action on the specification, and compares the two states.

  alias Accord.Spec.Value
  alias Accord.TLA.Checker
  alias Accord.TLA.Checker.Machine

  @directory Path.expand("../../tla", __DIR__)

  defstruct [:machine, :state, :model_values]

  @doc "The path of the specification `name`."
  def path(name), do: Path.join(@directory, name <> ".tla")

  @doc """
  Does the model check of the specification `name`. `replace` is a pair of
  texts, to change one line of the configuration.
  """
  def check(name, replace \\ nil, opts \\ []) do
    Checker.check(path(name), Keyword.put(opts, :config, config(name, replace)))
  end

  defp config(name, nil), do: Path.join(@directory, name <> ".cfg")

  defp config(name, {from, to}) do
    text = name |> config(nil) |> File.read!()
    true = String.contains?(text, from)

    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}.cfg")
    File.write!(path, String.replace(text, from, to))
    path
  end

  @doc "Loads the specification `name` and goes to its initial state."
  def start(name) do
    {:ok, machine} = Machine.load(path(name))
    {:ok, [state]} = Machine.init_states(machine)
    %__MODULE__{machine: machine, state: state, model_values: Machine.model_values(machine)}
  end

  @doc "Tells if the specification permits the action in the current state."
  def enabled?(%__MODULE__{} = model, action, args \\ []) do
    match?({:ok, [_ | _]}, steps(model, action, args))
  end

  @doc """
  Does the action. The specification must permit it, and it must give one
  next state.
  """
  def step!(%__MODULE__{} = model, action, args \\ []) do
    case steps(model, action, args) do
      {:ok, [{state, _open}]} ->
        %{model | state: state}

      other ->
        raise "the specification does not permit #{action}#{inspect(args)} in " <>
                "#{inspect(to_map(model))}: #{inspect(other)}"
    end
  end

  defp steps(%__MODULE__{machine: machine, state: state, model_values: values}, action, args) do
    Machine.step(machine, state, action, Enum.map(args, &Value.to_tla(&1, values)))
  end

  @doc "The value of the variable `name`, as an Elixir term."
  def get(%__MODULE__{} = model, name), do: Map.fetch!(to_map(model), name)

  @doc "The current state, as a map from variable names to Elixir terms."
  def to_map(%__MODULE__{machine: machine, state: state}) do
    machine
    |> Machine.to_map(state)
    |> Map.new(fn {name, value} -> {name, Value.from_tla(value)} end)
  end
end
