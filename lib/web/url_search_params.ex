defmodule Web.URLSearchParams do
  @moduledoc """
  Ordered query parameter storage matching the URLSearchParams Web API shape.
  """

  import Kernel, except: [to_string: 1]

  defstruct pairs: []

  @type pair :: {String.t(), String.t()}
  @type t :: %__MODULE__{pairs: [pair()]}

  @doc """
  Creates a URLSearchParams container.

  ## Examples

      iex> params = Web.URLSearchParams.new("foo=bar&foo=baz")
      iex> Web.URLSearchParams.get_all(params, "foo")
      ["bar", "baz"]
  """
  @spec new(String.t() | map() | Enumerable.t() | nil) :: t()
  def new(init \\ "")

  def new(nil), do: new("")

  def new(init) do
    %__MODULE__{pairs: normalize_init(init)}
  end

  @spec append(t(), String.t(), String.t()) :: t()
  def append(%__MODULE__{} = params, name, value) do
    %{params | pairs: params.pairs ++ [{Kernel.to_string(name), Kernel.to_string(value)}]}
  end

  @spec delete(t(), String.t()) :: t()
  def delete(%__MODULE__{} = params, name) do
    name = Kernel.to_string(name)
    %{params | pairs: Enum.reject(params.pairs, fn {key, _value} -> key == name end)}
  end

  @spec get(t(), String.t()) :: String.t() | nil
  def get(%__MODULE__{} = params, name) do
    name = Kernel.to_string(name)

    Enum.find_value(params.pairs, fn
      {^name, value} -> value
      _pair -> nil
    end)
  end

  @spec get_all(t(), String.t()) :: [String.t()]
  def get_all(%__MODULE__{} = params, name) do
    name = Kernel.to_string(name)

    Enum.flat_map(params.pairs, fn
      {^name, value} -> [value]
      _pair -> []
    end)
  end

  @spec has?(t(), String.t()) :: boolean()
  def has?(%__MODULE__{} = params, name) do
    not is_nil(get(params, name))
  end

  @spec has(t(), String.t()) :: boolean()
  def has(%__MODULE__{} = params, name), do: has?(params, name)

  @spec set(t(), String.t(), String.t()) :: t()
  def set(%__MODULE__{} = params, name, value) do
    name = Kernel.to_string(name)
    value = Kernel.to_string(value)

    {pairs, seen?} =
      Enum.reduce(params.pairs, {[], false}, fn
        {^name, _existing}, {acc, false} -> {[{name, value} | acc], true}
        {^name, _existing}, {acc, true} -> {acc, true}
        pair, {acc, seen?} -> {[pair | acc], seen?}
      end)

    pairs = Enum.reverse(pairs)
    %{params | pairs: if(seen?, do: pairs, else: pairs ++ [{name, value}])}
  end

  @spec sort(t()) :: t()
  def sort(%__MODULE__{} = params) do
    pairs =
      params.pairs
      |> Enum.with_index()
      |> Enum.sort_by(fn {{key, _value}, index} -> {key, index} end)
      |> Enum.map(&elem(&1, 0))

    %{params | pairs: pairs}
  end

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = params) do
    Enum.map_join(params.pairs, "&", fn {key, value} ->
      "#{URI.encode_www_form(key)}=#{URI.encode_www_form(value)}"
    end)
  end

  @spec to_list(t()) :: [pair()]
  def to_list(%__MODULE__{} = params), do: params.pairs

  @doc false
  def fetch(%__MODULE__{} = params, key) do
    case get(params, key) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  @doc false
  def get_and_update(%__MODULE__{} = params, key, function) do
    current = get(params, key)

    case function.(current) do
      {get_value, nil} ->
        {get_value, delete(params, key)}

      {get_value, new_value} ->
        {get_value, set(params, key, new_value)}

      :pop ->
        {current, delete(params, key)}
    end
  end

  @doc false
  def pop(%__MODULE__{} = params, key) do
    current = get(params, key)
    {current, delete(params, key)}
  end

  defp normalize_init(init) when is_binary(init) do
    query = if String.starts_with?(init, "?"), do: String.slice(init, 1..-1//1), else: init

    query
    |> URI.query_decoder()
    |> Enum.map(fn {key, value} -> {key, value} end)
  end

  defp normalize_init(init) when is_map(init) do
    Enum.map(init, fn {key, value} -> {Kernel.to_string(key), Kernel.to_string(value)} end)
  end

  defp normalize_init(init) do
    Enum.map(init, fn {key, value} -> {Kernel.to_string(key), Kernel.to_string(value)} end)
  end
end

defimpl Enumerable, for: Web.URLSearchParams do
  def count(params), do: {:ok, length(Web.URLSearchParams.to_list(params))}

  def member?(params, value), do: {:ok, value in Web.URLSearchParams.to_list(params)}

  def reduce(params, acc, fun) do
    Enumerable.List.reduce(Web.URLSearchParams.to_list(params), acc, fun)
  end

  def slice(_params), do: {:error, __MODULE__}
end

defimpl String.Chars, for: Web.URLSearchParams do
  def to_string(params), do: Web.URLSearchParams.to_string(params)
end
