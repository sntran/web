defmodule Web.Headers do
  @moduledoc """
  A case-insensitive, multi-value HTTP headers container.
  """

  @behaviour Access

  @set_cookie "set-cookie"

  defstruct data: %{}

  @type header_name :: String.t()
  @type header_value :: String.t()
  @type t :: %__MODULE__{
          data: %{header_name() => [header_value()]}
        }

  @doc """
  Creates a new headers struct from another `%Web.Headers{}`, a map, or a list of tuples.
  """
  @spec new(t() | map() | [{term(), term()}]) :: t()
  def new(headers \\ %{})
  def new(%__MODULE__{} = headers), do: headers

  def new(headers) when is_map(headers) do
    data =
      Enum.reduce(headers, %{}, fn {name, value}, acc ->
        Map.put(acc, normalize_name(name), [normalize_value(value)])
      end)

    %__MODULE__{data: data}
  end

  def new(headers) when is_list(headers) do
    Enum.reduce(headers, %__MODULE__{}, fn {name, value}, acc ->
      append(acc, name, value)
    end)
  end

  @doc """
  Appends a value to a header name.
  """
  @spec append(t(), term(), term()) :: t()
  def append(%__MODULE__{data: data} = headers, name, value) do
    normalized_name = normalize_name(name)
    normalized_value = normalize_value(value)

    updated_data =
      Map.update(data, normalized_name, [normalized_value], fn values ->
        values ++ [normalized_value]
      end)

    %{headers | data: updated_data}
  end

  @doc """
  Removes a header.
  """
  @spec delete(t(), term()) :: t()
  def delete(%__MODULE__{data: data} = headers, name) do
    %{headers | data: Map.delete(data, normalize_name(name))}
  end

  @doc """
  Returns a header value as a single string.
  """
  @spec get(t(), term(), term()) :: String.t() | term()
  def get(%__MODULE__{data: data}, name, default \\ nil) do
    normalized_name = normalize_name(name)

    case Map.get(data, normalized_name) do
      nil -> default
      values -> join_values(normalized_name, values)
    end
  end

  @doc """
  Returns all `set-cookie` header values without joining them.
  """
  @spec get_set_cookie(t()) :: [String.t()]
  def get_set_cookie(%__MODULE__{data: data}) do
    Map.get(data, @set_cookie, [])
  end

  def unquote(:getSetCookie)(headers), do: get_set_cookie(headers)

  @doc """
  Returns whether a header exists.
  """
  @spec has(t(), term()) :: boolean()
  def has(%__MODULE__{data: data}, name) do
    Map.has_key?(data, normalize_name(name))
  end

  @doc """
  Sets a header value, replacing any existing values.
  """
  @spec set(t(), term(), term()) :: t()
  def set(%__MODULE__{data: data} = headers, name, value) do
    %{headers | data: Map.put(data, normalize_name(name), [normalize_value(value)])}
  end

  @doc """
  Converts headers into a raw list of repeated tuples.
  """
  @spec to_list(t()) :: [{String.t(), String.t()}]
  def to_list(%__MODULE__{data: data}) do
    data
    |> Enum.sort_by(fn {name, _values} -> name end)
    |> Enum.flat_map(fn {name, values} ->
      Enum.map(values, fn value -> {name, value} end)
    end)
  end

  @doc """
  Returns a stream of `{name, value}` pairs using the combined header view.
  """
  @spec entries(t()) :: Enumerable.t()
  def entries(%__MODULE__{} = headers) do
    headers
    |> normalized_entries()
    |> Stream.map(& &1)
  end

  @doc """
  Returns a stream of header names.
  """
  @spec keys(t()) :: Enumerable.t()
  def keys(%__MODULE__{} = headers) do
    headers
    |> normalized_entries()
    |> Stream.map(&elem(&1, 0))
  end

  @doc """
  Returns a stream of header values using the combined header view.
  """
  @spec values(t()) :: Enumerable.t()
  def values(%__MODULE__{} = headers) do
    headers
    |> normalized_entries()
    |> Stream.map(&elem(&1, 1))
  end

  @impl Access
  def fetch(%__MODULE__{} = headers, key) do
    if has(headers, key) do
      {:ok, get(headers, key)}
    else
      :error
    end
  end

  @impl Access
  def get_and_update(%__MODULE__{} = headers, key, fun) do
    current = get(headers, key)

    case fun.(current) do
      {get_value, new_value} -> {get_value, set(headers, key, new_value)}
      :pop -> {current, delete(headers, key)}
    end
  end

  @impl Access
  def pop(%__MODULE__{} = headers, key) do
    {get(headers, key), delete(headers, key)}
  end

  @doc false
  @spec enumerable_entries(t()) :: [{String.t(), String.t()}]
  def enumerable_entries(%__MODULE__{} = headers) do
    normalized_entries(headers)
  end

  defp normalized_entries(%__MODULE__{data: data}) do
    data
    |> Enum.sort_by(fn {name, _values} -> name end)
    |> Enum.map(fn {name, values} -> {name, join_values(name, values)} end)
  end

  defp join_values(_name, [value]), do: value
  defp join_values(@set_cookie, values), do: Enum.join(values, ", ")
  defp join_values(_name, values), do: Enum.join(values, ", ")

  defp normalize_name(name) when is_binary(name), do: String.downcase(name)
  defp normalize_name(name) when is_atom(name), do: name |> Atom.to_string() |> normalize_name()

  defp normalize_value(value) when is_binary(value), do: value
  defp normalize_value(value), do: to_string(value)
end

defimpl Enumerable, for: Web.Headers do
  def count(%Web.Headers{} = headers), do: {:ok, map_size(headers.data)}

  def member?(%Web.Headers{} = headers, entry) do
    {:ok, entry in Web.Headers.enumerable_entries(headers)}
  end

  def slice(_headers), do: {:error, __MODULE__}

  def reduce(%Web.Headers{} = headers, acc, fun) do
    Enumerable.List.reduce(Web.Headers.enumerable_entries(headers), acc, fun)
  end
end

defimpl Inspect, for: Web.Headers do
  import Inspect.Algebra

  @redacted_names MapSet.new(["authorization", "cookie", "set-cookie", "proxy-authorization"])

  def inspect(%Web.Headers{} = headers, opts) do
    entries =
      headers
      |> Web.Headers.enumerable_entries()
      |> Enum.map(fn {name, value} ->
        if MapSet.member?(@redacted_names, name) do
          {name, "[REDACTED]"}
        else
          {name, value}
        end
      end)

    concat(["#Web.Headers<", to_doc(entries, opts), ">"])
  end
end
