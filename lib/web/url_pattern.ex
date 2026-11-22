defmodule Web.URLPattern do
  @moduledoc """
  An implementation of `URLPattern` of the WHATWG URL Pattern Standard.

  `new/2` compiles a pattern string, or a map of the patterns of the
  components (a `URLPatternInit`). `test/2` and `exec/2` match a URL with
  the pattern, and `exec/2` gives the groups of each component.

  ## Pattern syntax

    * `:name` is a named group. It matches up to the next separator of the
      component: "/" in the pathname, and "." in the hostname.
    * `:name(regexp)` is a named group with a regular expression.
    * `(regexp)` is a group with a regular expression and a number as its
      name: `"0"`, `"1"`, and so on.
    * `*` is a group that matches all characters. Its name is a number.
    * `?` (optional), `+` (one or more), and `*` (zero or more) after a
      group are modifiers.
    * `{...}` groups text without a capture, for example `{/prefix}?`.

  The regular expressions have the syntax of ECMAScript with the flag `v`.

  The pattern string of each component (for example `pattern.pathname`) is
  the canonical text that the Standard specifies: `/foo/(.*)` becomes
  `/foo/*`, and `{/bar}` becomes `/bar`.

  An error of a pattern raises `Web.TypeError`, as the Standard specifies.

  ## Examples

      iex> pattern = Web.URLPattern.new(%{pathname: "/users/:id"})
      iex> Web.URLPattern.test(pattern, "https://example.com/users/42")
      true

      iex> pattern = Web.URLPattern.new(%{pathname: "/users/:id"})
      iex> result = Web.URLPattern.exec(pattern, "https://example.com/users/42")
      iex> result[:pathname][:groups]
      %{"id" => "42"}

      iex> Web.URLPattern.new(%{pathname: "/foo/(.*)"}).pathname
      "/foo/*"

  ## AsyncContext integration

  Use `match_context/3` to put the groups of a match in the ambient
  execution context. Each asynchronous task that runs from it can read them:

      pattern = Web.URLPattern.new(%{pathname: "/api/:version/:resource"})

      Web.URLPattern.match_context(pattern, request.url, fn ->
        params = Web.AsyncContext.Variable.get(Web.URLPattern.params())
        params["version"]   # e.g. "v2"
        params["resource"]  # e.g. "users"
      end)

  In a `Web.Stream` or a `Web.Promise`, `Web.AsyncContext.Snapshot` gives
  the same `params()` variable:

      stream = Web.ReadableStream.new(%{
        pull: fn controller ->
          params = Web.AsyncContext.Variable.get(Web.URLPattern.params())
          # params["id"] is available here
          ...
        end
      })

  The same `Snapshot` keeps the variables of `Web.AsyncContext` and the
  groups of `URLPattern`:

      user_var = Web.AsyncContext.Variable.new(name: "user")

      Web.AsyncContext.Variable.run(user_var, "alice", fn ->
        pattern = Web.URLPattern.new(%{pathname: "/items/:id"})

        Web.URLPattern.match_context(pattern, %{pathname: "/items/99"}, fn ->
          Web.AsyncContext.Variable.get(user_var)          # => "alice"
          Web.AsyncContext.Variable.get(Web.URLPattern.params()) # => %{"id" => "99"}
        end)
      end)
  """

  alias Web.AsyncContext.Variable
  alias Web.URL
  alias Web.URLPattern.{Cache, Canonical, Compiler, ConstructorString, Init}

  @components [:protocol, :username, :password, :hostname, :port, :pathname, :search, :hash]

  @default_options %{delimiter: "", prefix: "", ignore_case: false}
  @hostname_options %{delimiter: ".", prefix: "", ignore_case: false}
  @pathname_options %{delimiter: "/", prefix: "/", ignore_case: false}

  defstruct protocol: "*",
            username: "*",
            password: "*",
            hostname: "*",
            port: "*",
            pathname: "*",
            search: "*",
            hash: "*",
            # The component of the Standard for each component name: the
            # regular expression, the group name list, and the part list.
            compiled: %{},
            ignore_case: false

  @type component_result :: %{
          input: String.t(),
          groups: %{optional(String.t()) => String.t() | nil}
        }

  @type result :: %{
          protocol: component_result(),
          username: component_result(),
          password: component_result(),
          hostname: component_result(),
          port: component_result(),
          pathname: component_result(),
          search: component_result(),
          hash: component_result(),
          inputs: list()
        }

  @type t :: %__MODULE__{
          protocol: String.t(),
          username: String.t(),
          password: String.t(),
          hostname: String.t(),
          port: String.t(),
          pathname: String.t(),
          search: String.t(),
          hash: String.t(),
          compiled: map(),
          ignore_case: boolean()
        }

  # ---------------------------------------------------------------------------
  # The AsyncContext variable of the groups (one for each node)
  # ---------------------------------------------------------------------------

  @params_term_key {__MODULE__, :url_params_variable}
  @pinned_prefix {__MODULE__, :pinned}

  @doc """
  Returns the `Web.AsyncContext.Variable` that keeps the groups of a match.

  The variable is a singleton: the first call makes it and keeps it in
  `:persistent_term`. An asynchronous task can call
  `Variable.get(Web.URLPattern.params())` to read the groups that
  `match_context/3` puts in the context.
  """
  @spec params() :: Variable.t()
  def params do
    var =
      case :persistent_term.get(@params_term_key, nil) do
        nil ->
          v = Variable.new(name: "url_params")
          :persistent_term.put(@params_term_key, v)
          v

        v ->
          v
      end

    # `Variable.new/1` registers the key only in the process that makes the
    # variable. Another process gets the variable from `:persistent_term`
    # without the key in its registry, and `Snapshot.new/0` then does not
    # find the key. Thus each process registers the key here.
    registry_key = Variable.registry_key()
    registry = Process.get(registry_key, MapSet.new())

    unless MapSet.member?(registry, var.key) do
      Process.put(registry_key, MapSet.put(registry, var.key))
    end

    var
  end

  # ---------------------------------------------------------------------------
  # new/2
  # ---------------------------------------------------------------------------

  @doc """
  Compiles a URL pattern: the constructor of `URLPattern`.

  `input` can be:

    * a pattern string (the constructor string of the Standard), for
      example `"https://example.com/:path"`. A relative pattern string
      needs a base URL.
    * a map of the patterns of the components (a `URLPatternInit`), for
      example `%{pathname: "/users/:id", hostname: "example.com"}`. The key
      `:base_url` gives the base URL. A component that is not in the map
      matches all values, or comes from the base URL.

  The second argument can be the base URL (a string), or a map of options:

    * `:base_url` - the base URL of a pattern string.
    * `:ignore_case` - `true` for a match that ignores the case. The
      default is `false`.

  Raises `Web.TypeError` when the pattern is not valid, when a relative
  pattern string has no base URL, and when a map has a base URL in the
  second argument.

  ## Examples

      iex> p = Web.URLPattern.new("https://example.com/*")
      iex> Web.URLPattern.test(p, "https://example.com/page")
      true

      iex> p = Web.URLPattern.new("/books/:id", "https://example.com")
      iex> {p.hostname, p.pathname}
      {"example.com", "/books/:id"}

      iex> p = Web.URLPattern.new(%{pathname: "/foo/:bar"})
      iex> result = Web.URLPattern.exec(p, %{pathname: "/foo/baz"})
      iex> result[:pathname][:groups]
      %{"bar" => "baz"}

      iex> Web.URLPattern.new("/foo")
      ** (Web.TypeError) A relative pattern string needs a base URL.
  """
  @spec new(String.t() | map(), String.t() | map()) :: t()
  def new(input \\ %{}, options \\ %{})

  def new(input, base_url) when is_binary(base_url), do: new(input, %{base_url: base_url})

  def new(input, options) when (is_binary(input) or is_map(input)) and is_map(options) do
    base_url = Map.get(options, :base_url)
    ignore_case = Map.get(options, :ignore_case, false) == true
    key = {input, base_url, ignore_case}

    fetch_cached_pattern(Map.get(options, :pinned, false), key, fn ->
      create(input, base_url, ignore_case)
    end)
  end

  defp fetch_cached_pattern(true, key, builder) do
    term_key = {@pinned_prefix, key}

    case :persistent_term.get(term_key, nil) do
      nil ->
        pattern = builder.()
        :persistent_term.put(term_key, pattern)
        pattern

      pattern ->
        pattern
    end
  end

  defp fetch_cached_pattern(false, key, builder) do
    case Cache.get(key) do
      {:ok, pattern} ->
        pattern

      :miss ->
        pattern = builder.()
        Cache.put(key, pattern)
        pattern
    end
  end

  # "Create a URL pattern".
  defp create(input, base_url, ignore_case) do
    wildcards = Map.new(@components, &{&1, "*"})

    processed =
      Map.merge(wildcards, input |> create_init(base_url) |> Init.process(:pattern, %{}))

    default_port = Canonical.default_port(processed.protocol)

    processed =
      if default_port != nil and processed.port == Integer.to_string(default_port),
        do: %{processed | port: ""},
        else: processed

    protocol = Compiler.compile(processed.protocol, &Canonical.protocol/1, @default_options)

    hostname =
      if ipv6_pattern?(processed.hostname),
        do: Compiler.compile(processed.hostname, &Canonical.ipv6_hostname/1, @hostname_options),
        else: Compiler.compile(processed.hostname, &Canonical.hostname/1, @hostname_options)

    # Only the pathname, the search, and the hash ignore the case.
    options = %{@default_options | ignore_case: ignore_case}
    path_options = %{@pathname_options | ignore_case: ignore_case}

    pathname =
      if special_protocol?(protocol),
        do: Compiler.compile(processed.pathname, &Canonical.pathname/1, path_options),
        else: Compiler.compile(processed.pathname, &Canonical.opaque_pathname/1, options)

    compiled = %{
      protocol: protocol,
      username: Compiler.compile(processed.username, &Canonical.userinfo/1, @default_options),
      password: Compiler.compile(processed.password, &Canonical.userinfo/1, @default_options),
      hostname: hostname,
      port: Compiler.compile(processed.port, &Canonical.port/1, @default_options),
      pathname: pathname,
      search: Compiler.compile(processed.search, &Canonical.search/1, options),
      hash: Compiler.compile(processed.hash, &Canonical.hash/1, options)
    }

    struct(
      %__MODULE__{compiled: compiled, ignore_case: ignore_case},
      Map.new(compiled, fn {key, component} -> {key, component.pattern} end)
    )
  end

  defp create_init(input, base_url) when is_binary(input) do
    init = ConstructorString.parse(input)

    cond do
      base_url != nil -> Map.put(init, :base_url, base_url)
      Map.has_key?(init, :protocol) -> init
      true -> raise Web.TypeError, "A relative pattern string needs a base URL."
    end
  end

  defp create_init(input, nil), do: Init.normalize(input)

  defp create_init(_input, _base_url),
    do: raise(Web.TypeError, "A URLPatternInit has its base URL in the key :base_url.")

  # "Hostname pattern is an IPv6 address".
  defp ipv6_pattern?(<<?[, _rest::binary>>), do: true
  defp ipv6_pattern?(<<char, ?[, _rest::binary>>) when char in [?{, ?\\], do: true
  defp ipv6_pattern?(_input), do: false

  # "Protocol component matches a special scheme".
  defp special_protocol?(protocol),
    do: Enum.any?(~w(ftp file http https ws wss), &(Compiler.match(protocol, &1) != nil))

  # ---------------------------------------------------------------------------
  # Attributes
  # ---------------------------------------------------------------------------

  @doc """
  Returns `true` when a component of the pattern has a group with a
  regular expression: the attribute `hasRegExpGroups`.

  ## Examples

      iex> Web.URLPattern.has_reg_exp_groups(Web.URLPattern.new(%{pathname: "/:id(\\\\d+)"}))
      true

      iex> Web.URLPattern.has_reg_exp_groups(Web.URLPattern.new(%{pathname: "/:id"}))
      false
  """
  @spec has_reg_exp_groups(t()) :: boolean()
  def has_reg_exp_groups(%__MODULE__{compiled: compiled}),
    do: Enum.any?(compiled, fn {_name, component} -> component.has_regexp_groups end)

  # ---------------------------------------------------------------------------
  # test/3 and exec/3
  # ---------------------------------------------------------------------------

  @doc """
  Returns `true` when the input matches the pattern.

  The input is a URL string, a `Web.URL`, or a map of the components (a
  `URLPatternInit`). A relative URL string needs `base_url`.

  ## Examples

      iex> p = Web.URLPattern.new(%{pathname: "/foo/:bar"})
      iex> Web.URLPattern.test(p, %{pathname: "/foo/baz"})
      true

      iex> p = Web.URLPattern.new(%{pathname: "/foo/:bar"})
      iex> Web.URLPattern.test(p, %{pathname: "/other"})
      false
  """
  @spec test(t(), String.t() | map() | URL.t(), String.t() | nil) :: boolean()
  def test(%__MODULE__{} = pattern, input \\ %{}, base_url \\ nil),
    do: exec(pattern, input, base_url) != nil

  @doc """
  Matches the input with the pattern: the method `exec`.

  Returns `nil` when the input does not match. Otherwise returns a map with
  the key `:inputs` (the input, and the base URL when it is given) and a
  key for each component: `%{input: String.t(), groups: map()}`. A group
  that does not take part in the match has the value `nil`.

  The input is a URL string, a `Web.URL`, a `Web.Request`, or a map of the
  components (a `URLPatternInit`). A relative URL string needs `base_url`.
  An input that is not valid does not match. Raises `Web.TypeError` when
  the input is a map and `base_url` is given.

  The match of a `Web.Request` uses its URL, and does not read its body.

  ## Examples

      iex> p = Web.URLPattern.new(%{pathname: "/u/:id"})
      iex> Web.URLPattern.exec(p, "https://x.com/u/7")[:pathname][:groups]
      %{"id" => "7"}

      iex> p = Web.URLPattern.new(%{pathname: "/u/:id"})
      iex> Web.URLPattern.exec(p, "/u/7", "https://x.com")[:inputs]
      ["/u/7", "https://x.com"]
  """
  @spec exec(t(), String.t() | map() | URL.t(), String.t() | nil) :: result() | nil
  def exec(%__MODULE__{} = pattern, input \\ %{}, base_url \\ nil) do
    case match_input(input, base_url) do
      {:ok, values, inputs} -> match_components(pattern, values, inputs)
      :error -> nil
    end
  end

  # The steps of "match" that give the value of each component.
  defp match_input(%Web.Request{url: url}, base_url), do: match_input(url, base_url)
  defp match_input(%URL{} = url, _base_url), do: {:ok, url_values(url), [URL.href(url)]}

  defp match_input(input, nil) when is_binary(input) do
    case URL.parse(input) do
      %URL{} = url -> {:ok, url_values(url), [input]}
      nil -> :error
    end
  end

  defp match_input(input, base_url) when is_binary(input) and is_binary(base_url) do
    with %URL{} = base <- URL.parse(base_url),
         %URL{} = url <- URL.parse(input, base) do
      {:ok, url_values(url), [input, base_url]}
    else
      nil -> :error
    end
  end

  defp match_input(input, nil) when is_map(input) and not is_struct(input) do
    defaults = Map.new(@components, fn key -> {key, ""} end)
    {:ok, input |> Init.normalize() |> Init.process(:url, defaults), [input]}
  rescue
    Web.TypeError -> :error
  end

  defp match_input(input, base_url) when is_map(input) and is_binary(base_url),
    do: raise(Web.TypeError, "A URLPatternInit has its base URL in the key :base_url.")

  defp match_input(_input, _base_url), do: :error

  defp url_values(%URL{} = url) do
    %{
      protocol: Init.scheme(url),
      username: url.username,
      password: url.password,
      hostname: URL.hostname(url),
      port: url.port,
      pathname: URL.pathname(url),
      search: Init.query(url),
      hash: Init.fragment(url)
    }
  end

  defp match_components(pattern, values, inputs) do
    Enum.reduce_while(@components, %{inputs: inputs}, fn key, result ->
      input = Map.fetch!(values, key)

      case Compiler.match(Map.fetch!(pattern.compiled, key), input) do
        nil -> {:halt, nil}
        groups -> {:cont, Map.put(result, key, %{input: input, groups: groups})}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # match_context/3 (AsyncContext integration)
  # ---------------------------------------------------------------------------

  @doc """
  Matches the pattern with `input`. When the input matches, runs `fun` with
  the named groups of all components in the variable `params/0`.

  Returns the result of `fun`, or `nil` when the input does not match.

  ## Examples

      iex> pattern = Web.URLPattern.new(%{pathname: "/users/:id"})
      iex> Web.URLPattern.match_context(pattern, %{pathname: "/users/99"}, fn ->
      ...>   Web.AsyncContext.Variable.get(Web.URLPattern.params())
      ...> end)
      %{"id" => "99"}
  """
  @spec match_context(t(), String.t() | map() | URL.t(), (-> result)) :: result | nil
        when result: var
  def match_context(%__MODULE__{} = pattern, input, fun) when is_function(fun, 0) do
    case exec(pattern, input) do
      nil -> nil
      result -> Variable.run(params(), named_groups(result), fun)
    end
  end

  # The groups with a name that is not a number.
  defp named_groups(result) do
    for key <- @components,
        {name, value} <- result[key].groups,
        not String.match?(name, ~r/\A\d/),
        into: %{},
        do: {name, value}
  end

  # ---------------------------------------------------------------------------
  # compare_component/3
  # ---------------------------------------------------------------------------

  @doc """
  Compares one component of two URL patterns.

  Returns `1` when `left` is more specific, `-1` when `right` is more
  specific, and `0` when they are equal for the component. The comparison
  examines the parts of the two patterns in sequence. Fixed text is more
  specific than a regular expression, a regular expression is more specific
  than a segment wildcard (`:name`), and a segment wildcard is more
  specific than a full wildcard (`*`). Then the modifiers, the prefix, the
  value, and the suffix decide.
  """
  @spec compare_component(atom() | String.t(), t(), t()) :: -1 | 0 | 1
  def compare_component(component, %__MODULE__{} = left, %__MODULE__{} = right) do
    component = component_name!(component)
    compare_parts(left.compiled[component].parts, right.compiled[component].parts)
  end

  defp component_name!(component) when component in @components, do: component

  defp component_name!(component) when is_binary(component) do
    Enum.find(@components, &(Atom.to_string(&1) == component)) ||
      raise ArgumentError, "Unknown URLPattern component: #{inspect(component)}"
  end

  defp component_name!(component),
    do: raise(ArgumentError, "Unknown URLPattern component: #{inspect(component)}")

  @empty_fixed %{type: :fixed_text, modifier: :none, prefix: "", value: "", suffix: ""}

  defp compare_parts([], []), do: 0
  defp compare_parts([left | _rest], []), do: compare_part(left, @empty_fixed)
  defp compare_parts([], [right | _rest]), do: compare_part(@empty_fixed, right)

  defp compare_parts([left | left_rest], [right | right_rest]) do
    case compare_part(left, right) do
      0 -> compare_parts(left_rest, right_rest)
      result -> result
    end
  end

  defp compare_part(left, right) do
    with 0 <- compare(type_rank(left.type), type_rank(right.type)),
         0 <- compare(modifier_rank(left.modifier), modifier_rank(right.modifier)),
         0 <- compare(left.prefix, right.prefix),
         0 <- compare(left.value, right.value) do
      compare(left.suffix, right.suffix)
    end
  end

  defp type_rank(:fixed_text), do: 3
  defp type_rank(:regexp), do: 2
  defp type_rank(:segment_wildcard), do: 1
  defp type_rank(:full_wildcard), do: 0

  defp modifier_rank(:none), do: 3
  defp modifier_rank(:one_or_more), do: 2
  defp modifier_rank(:optional), do: 1
  defp modifier_rank(:zero_or_more), do: 0

  defp compare(left, right) when left < right, do: -1
  defp compare(left, right) when left > right, do: 1
  defp compare(_left, _right), do: 0
end
