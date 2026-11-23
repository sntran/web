defmodule Web.URLPattern.Init do
  @moduledoc false

  # "Process a URLPatternInit" of the URL Pattern Standard ("3.2.
  # URLPatternInit processing").
  #
  # An init is a map with the keys `:protocol`, `:username`, `:password`,
  # `:hostname`, `:port`, `:pathname`, `:search`, `:hash`, and `:base_url`.
  # A key with the value `nil` is not in the init, as a member of a WebIDL
  # dictionary that is `undefined`.

  alias Web.URL
  alias Web.URLPattern.{Canonical, Compiler}

  @components [:protocol, :username, :password, :hostname, :port, :pathname, :search, :hash]

  @doc false
  # Returns the init with atom keys. A key can also be a string, and the
  # base URL can also be `:baseURL` or `"baseURL"`. Raises `Web.TypeError`
  # for a value that is not a string.
  @spec normalize(map()) :: %{optional(atom()) => String.t()}
  def normalize(input) when is_map(input) do
    Enum.reduce(input, %{}, fn {key, value}, acc ->
      case {key_name(key), value} do
        {nil, _value} -> acc
        {_name, nil} -> acc
        {name, value} when is_binary(value) -> Map.put(acc, name, value)
        {name, _value} -> raise Web.TypeError, "The #{name} of a URLPatternInit is not a string."
      end
    end)
  end

  defp key_name(key) when key in @components, do: key
  defp key_name(key) when key in [:base_url, :baseURL, "baseURL", "base_url"], do: :base_url

  defp key_name(key) when is_binary(key) do
    Enum.find(@components, &(Atom.to_string(&1) == key))
  end

  defp key_name(_key), do: nil

  @doc false
  # "Process a URLPatternInit". The type is `:pattern` or `:url`. The
  # defaults are the components that the result has before the init.
  @spec process(map(), :pattern | :url, map()) :: %{optional(atom()) => String.t()}
  def process(init, type, defaults) do
    base = base_url(init)
    result = if base, do: inherit(defaults, init, base, type), else: defaults

    result =
      Enum.reduce([:protocol, :username, :password, :hostname], result, fn key, acc ->
        if Map.has_key?(init, key),
          do: Map.put(acc, key, process_component(key, init[key], type)),
          else: acc
      end)

    protocol = Map.get(result, :protocol, "")

    result
    |> put_if(init, :port, &process_port(&1, protocol, type))
    |> put_if(init, :pathname, &process_pathname(base_pathname(&1, base, type), protocol, type))
    |> put_if(init, :search, &process_search(&1, type))
    |> put_if(init, :hash, &process_hash(&1, type))
  end

  defp put_if(result, init, key, fun) do
    case Map.fetch(init, key) do
      {:ok, value} -> Map.put(result, key, fun.(value))
      :error -> result
    end
  end

  defp base_url(%{base_url: base_url}) do
    case URL.parse(base_url) do
      %URL{} = url -> url
      nil -> raise Web.TypeError, "The baseURL of the URLPatternInit is not a valid URL."
    end
  end

  defp base_url(_init), do: nil

  # The steps for `init["baseURL"]`: each component that is not in the init
  # and that is less specific than no component of the init comes from the
  # base URL.
  defp inherit(result, init, base, type) do
    given = fn keys -> Enum.any?(keys, &Map.has_key?(init, &1)) end

    [
      {:protocol, [:protocol], scheme(base), true},
      {:username, [:protocol, :hostname, :port, :username], base.username, type != :pattern},
      {:password, [:protocol, :hostname, :port, :username, :password], base.password,
       type != :pattern},
      {:hostname, [:protocol, :hostname], URL.hostname(base), true},
      {:port, [:protocol, :hostname, :port], base.port, true},
      {:pathname, [:protocol, :hostname, :port, :pathname], URL.pathname(base), true},
      {:search, [:protocol, :hostname, :port, :pathname, :search], query(base), true},
      {:hash, [:protocol, :hostname, :port, :pathname, :search, :hash], fragment(base), true}
    ]
    |> Enum.reduce(result, fn {key, keys, value, inherit?}, acc ->
      cond do
        not inherit? or given.(keys) -> acc
        key == :port -> Map.put(acc, key, value)
        true -> Map.put(acc, key, base_string(value, type))
      end
    end)
  end

  @doc false
  # The parts of a URL for the URL Pattern Standard: the scheme, the query,
  # and the fragment have no "?", "#", or ":".
  @spec scheme(URL.t()) :: String.t()
  def scheme(url), do: String.replace_suffix(url.protocol, ":", "")

  @doc false
  @spec query(URL.t()) :: String.t()
  def query(url), do: url |> URL.search() |> String.replace_prefix("?", "")

  @doc false
  @spec fragment(URL.t()) :: String.t()
  def fragment(url), do: url |> URL.hash() |> String.replace_prefix("#", "")

  # "Process a base URL string".
  defp base_string(value, :pattern), do: Compiler.escape_pattern_string(value)
  defp base_string(value, _type), do: value

  # The steps for `init["pathname"]` with a base URL: a relative pathname
  # is relative to the directory of the path of the base URL.
  defp base_pathname(pathname, nil, _type), do: pathname

  defp base_pathname(pathname, base, type) do
    if opaque_path?(base) or absolute_pathname?(pathname, type) do
      pathname
    else
      base_path = base_string(URL.pathname(base), type)

      case :binary.matches(base_path, "/") do
        [] -> pathname
        matches -> binary_part(base_path, 0, elem(List.last(matches), 0) + 1) <> pathname
      end
    end
  end

  @doc false
  # A URL has an opaque path when it has no host and its path does not
  # start with "/".
  @spec opaque_path?(URL.t()) :: boolean()
  def opaque_path?(url) do
    not Canonical.special_scheme?(scheme(url)) and not url.authority_present? and
      url.hostname == "" and not String.starts_with?(url.pathname, "/")
  end

  # "Is an absolute pathname".
  defp absolute_pathname?("/" <> _rest, _type), do: true
  defp absolute_pathname?(_input, :url), do: false
  defp absolute_pathname?("\\/" <> _rest, _type), do: true
  defp absolute_pathname?("{/" <> _rest, _type), do: true
  defp absolute_pathname?(_input, _type), do: false

  defp process_component(:protocol, value, type) do
    stripped = String.replace_suffix(value, ":", "")
    if type == :pattern, do: stripped, else: Canonical.protocol(stripped)
  end

  defp process_component(_key, value, :pattern), do: value
  defp process_component(:hostname, value, _type), do: Canonical.hostname(value)
  defp process_component(_userinfo, value, _type), do: Canonical.userinfo(value)

  defp process_port(value, _protocol, :pattern), do: value
  defp process_port(value, protocol, _type), do: Canonical.port(value, protocol)

  defp process_pathname(value, _protocol, :pattern), do: value

  defp process_pathname(value, protocol, _type) do
    if protocol == "" or Canonical.special_scheme?(protocol),
      do: Canonical.pathname(value),
      else: Canonical.opaque_pathname(value)
  end

  defp process_search(value, type) do
    stripped = String.replace_prefix(value, "?", "")
    if type == :pattern, do: stripped, else: Canonical.search(stripped)
  end

  defp process_hash(value, type) do
    stripped = String.replace_prefix(value, "#", "")
    if type == :pattern, do: stripped, else: Canonical.hash(stripped)
  end
end
