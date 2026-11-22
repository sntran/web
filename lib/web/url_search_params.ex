defmodule Web.URLSearchParams do
  @moduledoc """
  An implementation of the WHATWG URLSearchParams standard.

  Provides a storage for ordered query parameters.

  The struct is an `Enumerable` of `{name, value}` tuples, as the iterable
  of the Standard. Thus `Enum.to_list/1` gives the pairs.
  """

  import Kernel, except: [to_string: 1]

  defguardp hex?(char) when char in ?0..?9 or char in ?a..?f or char in ?A..?F

  defguardp form_safe?(char)
            when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?*, ?-, ?., ?_]

  # `url_query` is internal: the query of the URL that the list comes from,
  # or `nil`. Each change of the list sets it to `nil`. Thus `Web.URL`
  # knows that the list changed, also when the new list is equal to the old
  # list, and runs the "update steps" of the URL Standard.
  defstruct pairs: [], url_query: nil

  @type pair :: {String.t(), String.t()}
  @type t :: %__MODULE__{pairs: [pair()], url_query: String.t() | nil}

  @doc """
  Creates a URLSearchParams container.

  The value can be one of these:

    * A query string. The parser of `application/x-www-form-urlencoded`
      reads it. A "?" at the start goes away, and an empty part between two
      "&" gives no pair.
    * A map. Each key and its value make a pair.
    * A list of pairs. A pair is a tuple or a list of two items. Raises
      `Web.TypeError` for an item that does not have two items.

  ## Examples

      iex> params = Web.URLSearchParams.new("foo=bar&foo=baz")
      iex> Web.URLSearchParams.get_all(params, "foo")
      ["bar", "baz"]

      iex> Web.URLSearchParams.new("?&a=1&&b") |> Enum.to_list()
      [{"a", "1"}, {"b", ""}]

      iex> Web.URLSearchParams.new([["a", "1"], {"b", "2"}]) |> Web.URLSearchParams.to_string()
      "a=1&b=2"

      iex> Web.URLSearchParams.new([["a"]])
      ** (Web.TypeError) Each item of the sequence must have two items, not ["a"].
  """
  @spec new(String.t() | map() | Enumerable.t() | nil) :: t()
  def new(init \\ "")

  def new(nil), do: new("")

  def new(init) do
    %__MODULE__{pairs: normalize_init(init)}
  end

  @doc false
  # The query object of a URL: the parser reads the query of the URL. A "?"
  # at the start is a part of the first name, as the URL Standard specifies.
  # Only the constructor removes it.
  @spec __parse__(String.t()) :: t()
  def __parse__(query) when is_binary(query),
    do: %__MODULE__{pairs: form_parse(query), url_query: query}

  @doc """
  Appends a new name/value pair to the end of the query parameters.

  ## Examples

      iex> params = Web.URLSearchParams.new()
      iex> params = Web.URLSearchParams.append(params, "foo", "1")
      iex> params = Web.URLSearchParams.append(params, "foo", "2")
      iex> Web.URLSearchParams.get_all(params, "foo")
      ["1", "2"]
  """
  @spec append(t(), String.t(), String.t()) :: t()
  def append(%__MODULE__{} = params, name, value) do
    update(params, params.pairs ++ [{Kernel.to_string(name), Kernel.to_string(value)}])
  end

  @doc """
  Deletes each pair that has the given name. With a value, deletes only
  each pair that has the name and the value. A `nil` value is the same as no
  value.

  ## Examples

      iex> params = Web.URLSearchParams.new("foo=bar&baz=qux")
      iex> params = Web.URLSearchParams.delete(params, "foo")
      iex> Web.URLSearchParams.has(params, "foo")
      false

      iex> params = Web.URLSearchParams.new("a=1&a=2&a=1")
      iex> Web.URLSearchParams.delete(params, "a", "1") |> Web.URLSearchParams.to_string()
      "a=2"
  """
  @spec delete(t(), String.t(), String.t() | nil) :: t()
  def delete(%__MODULE__{} = params, name, value \\ nil) do
    update(params, Enum.reject(params.pairs, matcher(name, value)))
  end

  @doc """
  Returns the first value associated with the given name.

  ## Examples

      iex> params = Web.URLSearchParams.new("foo=bar&foo=baz")
      iex> Web.URLSearchParams.get(params, "foo")
      "bar"
  """
  @spec get(t(), String.t()) :: String.t() | nil
  def get(%__MODULE__{} = params, name) do
    name = Kernel.to_string(name)

    Enum.find_value(params.pairs, fn
      {^name, value} -> value
      _pair -> nil
    end)
  end

  @doc """
  Returns all values associated with the given name.

  ## Examples

      iex> params = Web.URLSearchParams.new("foo=bar&foo=baz")
      iex> Web.URLSearchParams.get_all(params, "foo")
      ["bar", "baz"]
  """
  @spec get_all(t(), String.t()) :: [String.t()]
  def get_all(%__MODULE__{} = params, name) do
    name = Kernel.to_string(name)

    Enum.flat_map(params.pairs, fn
      {^name, value} -> [value]
      _pair -> []
    end)
  end

  @doc """
  Returns true if a pair has the given name. With a value, returns true only
  if a pair has the name and the value. A `nil` value is the same as no
  value.

  ## Examples

      iex> params = Web.URLSearchParams.new("foo=bar")
      iex> Web.URLSearchParams.has(params, "foo")
      true
      iex> Web.URLSearchParams.has(params, "baz")
      false
      iex> Web.URLSearchParams.has(params, "foo", "bar")
      true
      iex> Web.URLSearchParams.has(params, "foo", "baz")
      false
  """
  @spec has(t(), String.t(), String.t() | nil) :: boolean()
  def has(%__MODULE__{} = params, name, value \\ nil) do
    Enum.any?(params.pairs, matcher(name, value))
  end

  @doc """
  Returns the number of pairs.

  ## Examples

      iex> params = Web.URLSearchParams.new("a=1&b=2&a=3")
      iex> Web.URLSearchParams.size(params)
      3
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = params), do: length(params.pairs)

  @doc """
  Sets the value associated with the given name. If multiple values exist, it deletes
  the others and updates the first one.

  ## Examples

      iex> params = Web.URLSearchParams.new("foo=bar&foo=baz")
      iex> params = Web.URLSearchParams.set(params, "foo", "new")
      iex> Web.URLSearchParams.get_all(params, "foo")
      ["new"]
  """
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
    update(params, if(seen?, do: pairs, else: pairs ++ [{name, value}]))
  end

  @doc """
  Sorts the query parameters by name. The sort compares the UTF-16 code
  units of the names, as JavaScript does. The pairs with the same name keep
  their sequence.

  ## Examples

      iex> params = Web.URLSearchParams.new("c=3&a=1&b=2&a=0")
      iex> Web.URLSearchParams.sort(params) |> Web.URLSearchParams.to_string()
      "a=1&a=0&b=2&c=3"

      iex> params = Web.URLSearchParams.new("\uFB03&\u{1F308}")
      iex> Web.URLSearchParams.sort(params) |> Enum.to_list()
      [{"\u{1F308}", ""}, {"\uFB03", ""}]
  """
  @spec sort(t()) :: t()
  def sort(%__MODULE__{} = params) do
    # The sort of Enum.sort_by/2 is stable.
    update(params, Enum.sort_by(params.pairs, fn {name, _value} -> code_units(name) end))
  end

  @doc """
  Returns the serialized query parameters as a string, in the format
  `application/x-www-form-urlencoded`. ASCII letters, digits, "*", "-", ".",
  and "_" stay. A space becomes "+". Each other byte of the UTF-8 text
  becomes "%" and two hexadecimal digits.

  ## Examples

      iex> params = Web.URLSearchParams.new([{"foo", "bar"}, {"baz", "qux"}])
      iex> Web.URLSearchParams.to_string(params)
      "foo=bar&baz=qux"

      iex> params = Web.URLSearchParams.new([{"a b", "*-._~é"}])
      iex> Web.URLSearchParams.to_string(params)
      "a+b=*-._%7E%C3%A9"
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = params) do
    Enum.map_join(params.pairs, "&", fn {name, value} ->
      form_encode(name) <> "=" <> form_encode(value)
    end)
  end

  @doc false
  # The list of the pairs. Use `Enum.to_list/1`: the struct is an
  # `Enumerable` of its pairs, as the iterable of the Standard.
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

  # A change of the list: the list is not the query of its URL now.
  defp update(params, pairs), do: %{params | pairs: pairs, url_query: nil}

  defp normalize_init("?" <> query), do: form_parse(query)
  defp normalize_init(init) when is_binary(init), do: form_parse(init)
  defp normalize_init(init), do: Enum.map(init, &pair!/1)

  # A map gives tuples. A sequence of sequences gives lists.
  defp pair!({name, value}), do: {Kernel.to_string(name), Kernel.to_string(value)}
  defp pair!([name, value]), do: {Kernel.to_string(name), Kernel.to_string(value)}

  defp pair!(item) do
    raise Web.TypeError, "Each item of the sequence must have two items, not #{inspect(item)}."
  end

  # A function that finds the pairs with the name, and with the value when
  # the value is not nil.
  defp matcher(name, nil) do
    name = Kernel.to_string(name)
    fn {key, _value} -> key == name end
  end

  defp matcher(name, value) do
    pair = {Kernel.to_string(name), Kernel.to_string(value)}
    &(&1 == pair)
  end

  # The parser of `application/x-www-form-urlencoded` in the URL Standard.
  # An empty sequence between two "&" gives no pair.
  defp form_parse(input) do
    for sequence <- :binary.split(input, "&", [:global]), sequence != "" do
      case :binary.split(sequence, "=") do
        [name, value] -> {form_decode(name), form_decode(value)}
        [name] -> {form_decode(name), ""}
      end
    end
  end

  # Each "+" becomes a space. Then the percent-decode, and the UTF-8 decode
  # without BOM: each sequence of bytes that is not valid UTF-8 becomes
  # U+FFFD. A byte order mark stays.
  defp form_decode(bytes) do
    decoded = bytes |> :binary.replace("+", " ", [:global]) |> percent_decode()

    if String.valid?(decoded), do: decoded, else: String.replace_invalid(decoded, "\uFFFD")
  end

  # A "%" that has no two hexadecimal digits after it stays.
  defp percent_decode(bytes) do
    if :binary.match(bytes, "%") == :nomatch, do: bytes, else: percent_decode(bytes, <<>>)
  end

  defp percent_decode(<<?%, high, low, rest::binary>>, acc) when hex?(high) and hex?(low),
    do: percent_decode(rest, <<acc::binary, String.to_integer(<<high, low>>, 16)>>)

  defp percent_decode(<<byte, rest::binary>>, acc),
    do: percent_decode(rest, <<acc::binary, byte>>)

  defp percent_decode(<<>>, acc), do: acc

  # The serializer of `application/x-www-form-urlencoded`, with the
  # percent-encode set of the same name.
  defp form_encode(text) do
    for <<byte <- text>>, into: "", do: form_encode_byte(byte)
  end

  defp form_encode_byte(byte) when form_safe?(byte), do: <<byte>>
  defp form_encode_byte(?\s), do: "+"
  defp form_encode_byte(byte), do: "%" <> Base.encode16(<<byte>>)

  # The UTF-16 code units of a name, in big-endian byte order: the bytes
  # sort in the sequence of the code units. Text that is not valid UTF-8
  # gets U+FFFD for each sequence that is not valid.
  defp code_units(name) do
    case :unicode.characters_to_binary(name, :utf8, :utf16) do
      units when is_binary(units) -> units
      _invalid -> name |> String.replace_invalid("\uFFFD") |> code_units()
    end
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
