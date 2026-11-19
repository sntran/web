defmodule Web.Headers do
  @moduledoc """
  A case-insensitive, multi-value HTTP headers container.

  Each function validates its input as the Fetch Standard specifies:

    * A header name must be an HTTP token. A name that is not a token raises
      `Web.TypeError`.
    * A header value has its leading and trailing HTTP whitespace removed.
      A value that contains a NUL, CR, or LF character raises
      `Web.TypeError`.
  """

  @behaviour Access

  alias Web.Internal.Ascii

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

  def new(headers) when is_map(headers) or is_list(headers) do
    Enum.reduce(headers, %__MODULE__{}, fn
      {name, value}, acc ->
        append(acc, name, value)

      other, _acc ->
        raise Web.TypeError,
              "Each header must be a pair of a name and a value, got: #{inspect(other)}"
    end)
  end

  def new(headers) do
    raise Web.TypeError,
          "Headers must be a Web.Headers struct, a map, or a list of pairs, " <>
            "got: #{inspect(headers)}"
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

  @doc false
  # Returns `true` if `value` is an HTTP token (RFC 9110).
  @spec token?(term()) :: boolean()
  def token?(value), do: Ascii.token?(value)

  # A header name is an HTTP token. The map keeps it in lower case.
  defp normalize_name(name) when is_binary(name) do
    case Ascii.downcase_token(name) do
      :error -> raise Web.TypeError, "Invalid header name: #{inspect(name)}"
      lower -> lower
    end
  end

  defp normalize_name(name) when is_atom(name) and not is_nil(name) do
    name |> Atom.to_string() |> normalize_name()
  end

  defp normalize_name(name) do
    raise Web.TypeError, "Invalid header name: #{inspect(name)}"
  end

  @http_whitespace [?\t, ?\n, ?\r, ?\s]

  defp normalize_value(value) when is_binary(value) do
    value = value |> trim_leading_whitespace() |> trim_trailing_whitespace()

    if forbidden_value_byte?(value) do
      raise Web.TypeError, "Invalid header value: #{inspect(value)}"
    else
      value
    end
  end

  defp normalize_value(value) when is_number(value) or is_atom(value) do
    value |> to_string() |> normalize_value()
  end

  defp normalize_value(value) do
    raise Web.TypeError, "Invalid header value: #{inspect(value)}"
  end

  defp forbidden_value_byte?(<<char, _rest::binary>>) when char in [0, ?\r, ?\n], do: true
  defp forbidden_value_byte?(<<_char, rest::binary>>), do: forbidden_value_byte?(rest)
  defp forbidden_value_byte?(<<>>), do: false

  defp trim_leading_whitespace(<<byte, rest::binary>>) when byte in @http_whitespace,
    do: trim_leading_whitespace(rest)

  defp trim_leading_whitespace(value), do: value

  defp trim_trailing_whitespace(value) do
    size = byte_size(value)

    if size > 0 and :binary.last(value) in @http_whitespace do
      value |> binary_part(0, size - 1) |> trim_trailing_whitespace()
    else
      value
    end
  end
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
