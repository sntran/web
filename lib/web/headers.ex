defmodule Web.Headers do
  @moduledoc """
  A case-insensitive HTTP headers struct conforming to JS Fetch Standard.
  """
  @behaviour Access

  defstruct headers: %{}

  @type t :: %__MODULE__{
          headers: %{String.t() => String.t()}
        }

  @doc """
  Creates a new Headers struct.

  Supports conversion from Map or Keyword List. All keys are String-downcased.

  ## Examples
      iex> h = Web.Headers.new(%{"Content-Type" => "text/plain"})
      iex> Web.Headers.get(h, "content-type")
      "text/plain"

      iex> h = Web.Headers.new([{"X-Foo", "bar"}, {"X-FOO", "baz"}])
      iex> Web.Headers.get(h, "x-foo")
      "baz"
  """
  def new(headers \\ %{})
  def new(%__MODULE__{} = headers), do: headers

  def new(headers) when is_map(headers) or is_list(headers) do
    normalized = Enum.into(headers, %{}, fn {k, v} -> {normalize_key(k), to_string(v)} end)
    %__MODULE__{headers: normalized}
  end

  @doc """
  Puts a key-value pair, downcasing the key.

  ## Examples
      iex> h = Web.Headers.new() |> Web.Headers.put("Accept", "application/json")
      iex> h["accept"]
      "application/json"
  """
  def put(%__MODULE__{headers: headers} = struct, key, value) do
    %{struct | headers: Map.put(headers, normalize_key(key), to_string(value))}
  end

  @doc "Retrieves a header value by case-insensitive key."
  def get(%__MODULE__{headers: headers}, key, default \\ nil) do
    Map.get(headers, normalize_key(key), default)
  end

  @doc "Checks if a header exists."
  def has_key?(%__MODULE__{headers: headers}, key) do
    Map.has_key?(headers, normalize_key(key))
  end

  @doc "Deletes a header by case-insensitive key."
  def delete(%__MODULE__{headers: headers} = struct, key) do
    %{struct | headers: Map.delete(headers, normalize_key(key))}
  end

  @doc "Converts modern Headers back to a standard list."
  def to_list(%__MODULE__{headers: headers}) do
    Map.to_list(headers)
  end

  defp normalize_key(key) when is_binary(key), do: String.downcase(key)
  defp normalize_key(key) when is_atom(key), do: normalize_key(Atom.to_string(key))

  @impl Access
  def fetch(struct, key), do: if(has_key?(struct, key), do: {:ok, get(struct, key)}, else: :error)

  @impl Access
  def get_and_update(struct, key, fun) do
    current = get(struct, key)

    case fun.(current) do
      {get_value, new_value} -> {get_value, put(struct, key, new_value)}
      :pop -> {current, delete(struct, key)}
    end
  end

  @impl Access
  def pop(struct, key), do: {get(struct, key), delete(struct, key)}
end
