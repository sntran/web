defmodule Web.Test.SpecModel do
  @moduledoc false

  # Runs a TLA+ specification of `tla/` one step at a time. A property test
  # uses it as the model: the test does an operation on the real code, does
  # the same action on the specification, and compares the two states.

  alias Accord.Spec.Value
  alias Accord.TLA.Checker
  alias Accord.TLA.Checker.Eval
  alias Accord.TLA.Checker.Machine

  @directory Path.expand("../../tla", __DIR__)

  defstruct [:machine, :state, :model_values]

  @doc "The path of the specification `name`."
  def path(name), do: Path.join(@directory, name <> ".tla")

  @doc """
  Does the model check of the specification `name`. `replace` is a pair of
  texts, or a list of pairs, to change lines of the configuration.
  """
  def check(name, replace \\ nil, opts \\ []) do
    Checker.check(path(name), Keyword.put(opts, :config, config(name, replace)))
  end

  defp config(name, nil), do: Path.join(@directory, name <> ".cfg")
  defp config(name, {from, to}), do: config(name, [{from, to}])

  defp config(name, replacements) when is_list(replacements) do
    text =
      Enum.reduce(replacements, name |> config(nil) |> File.read!(), fn {from, to}, text ->
        true = String.contains?(text, from)
        String.replace(text, from, to)
      end)

    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}.cfg")
    File.write!(path, text)
    path
  end

  @doc """
  Loads the specification `name` and goes to its initial state. `replace`
  changes lines of the configuration, as for `check/3`.

  A property test starts the model again for each run, and a load takes 20
  to 30 ms. Thus the process keeps the model of its first load, and a later
  start gives that model again: the model is a value, thus a new run starts
  from the initial state. The checker keeps the data of a load in the
  dictionary of the process, thus each process loads its models itself. A
  start clears the cache of the checker, as a load does.
  """
  def start(name, replace \\ nil) do
    key = {__MODULE__, name, replace}

    case Process.get(key) do
      nil ->
        model = load(name, replace)
        Process.put(key, model)
        model

      model ->
        Eval.reset_cache()
        model
    end
  end

  defp load(name, replace) do
    {:ok, machine} = Machine.load(path(name), config: config(name, replace))
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

  @doc """
  Does each action of `actions` that the specification permits, again and
  again, until it permits none of them. These are the steps that the
  processes of the real system do with no command.
  """
  def settle(%__MODULE__{} = model, actions) do
    case Enum.find(actions, &enabled?(model, elem(&1, 0), elem(&1, 1))) do
      nil -> model
      {action, args} -> model |> step!(action, args) |> settle(actions)
    end
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
