defmodule Web.URLPattern do
  @moduledoc """
  A spec-compliant implementation of the WHATWG URLPattern API.

  `Web.URLPattern` compiles a pattern string (or component map) into an
  efficient match structure and provides `test/2` and `exec/2` for URL
  matching with named-group extraction.

  ## Pattern Syntax

  Patterns support a rich syntax that maps closely to the browser URLPattern:

    * **Named groups** — `:name` matches a segment and captures it.
    * **Custom regex** — `:name(\\\\d+)` matches the custom pattern.
    * **Anonymous groups** — `(pattern)` captures without a name (`"0"`, `"1"`, …).
    * **Wildcards** — `*` matches anything (including slashes).
    * **Modifiers** — `?` (optional), `+` (one-or-more), `*` (zero-or-more).
    * **Non-capturing groups** — `{prefix}?` / `{prefix/suffix}`.

  ## Examples

      iex> pattern = Web.URLPattern.new(%{pathname: "/users/:id"})
      iex> Web.URLPattern.test(pattern, "https://example.com/users/42")
      true

      iex> pattern = Web.URLPattern.new(%{pathname: "/users/:id"})
      iex> result = Web.URLPattern.exec(pattern, "https://example.com/users/42")
      iex> result[:pathname][:groups]
      %{"id" => "42"}

  ## AsyncContext Integration

  Use `match_context/3` to inject route params into the ambient execution
  context, making them accessible to any downstream async task:

      pattern = Web.URLPattern.new(%{pathname: "/api/:version/:resource"})

      Web.URLPattern.match_context(pattern, request.url, fn ->
        params = Web.AsyncContext.Variable.get(Web.URLPattern.params())
        params["version"]   # e.g. "v2"
        params["resource"]  # e.g. "users"
      end)

  Inside a `Web.Stream` or `Web.Promise`, the same `params()` variable is
  recovered via `Web.AsyncContext.Snapshot`:

      stream = Web.ReadableStream.new(%{
        pull: fn controller ->
          params = Web.AsyncContext.Variable.get(Web.URLPattern.params())
          # params["id"] is available here
          ...
        end
      })

  ## Coexistence with AsyncContext Variables

  Both `request_id` (from `AsyncContext`) and `url_params` (from
  `URLPattern`) are captured in the same `Snapshot`:

      user_var = Web.AsyncContext.Variable.new("user")

      Web.AsyncContext.Variable.run(user_var, "alice", fn ->
        pattern = Web.URLPattern.new(%{pathname: "/items/:id"})

        Web.URLPattern.match_context(pattern, "/items/99", fn ->
          # Both coexist in the snapshot:
          Web.AsyncContext.Variable.get(user_var)          # => "alice"
          Web.AsyncContext.Variable.get(Web.URLPattern.params()) # => %{"id" => "99"}
        end)
      end)
  """

  alias Web.AsyncContext.Variable
  alias Web.URL
  alias Web.URLPattern.{Cache, Compiler, Parser}

  # All URL components that URLPattern tracks
  @components [:protocol, :username, :password, :hostname, :port, :pathname, :search, :hash]

  # Sentinel value for invalid input components (port that starts with non-digit,
  # protocol with non-ASCII, etc.).  A wildcard pattern must NOT match this.
  @invalid_component "!invalid!"

  # Default patterns when a component is omitted from the pattern input
  # "*" means "match anything"
  @wildcard_pattern "*"

  # Default ports per scheme — used to normalize port "80" for "http" to "" etc.
  @default_ports %{
    "http" => "80",
    "https" => "443",
    "ws" => "80",
    "wss" => "443",
    "ftp" => "21"
  }

  defstruct protocol: @wildcard_pattern,
            username: @wildcard_pattern,
            password: @wildcard_pattern,
            hostname: @wildcard_pattern,
            port: @wildcard_pattern,
            pathname: @wildcard_pattern,
            search: @wildcard_pattern,
            hash: @wildcard_pattern,
            # Compiled regex + captures per component
            compiled: %{},
            ignore_case: false

  @type component_result :: %{
          input: String.t(),
          groups: %{optional(String.t()) => String.t() | nil}
        }

  @type result :: %{
          optional(:protocol) => component_result(),
          optional(:username) => component_result(),
          optional(:password) => component_result(),
          optional(:hostname) => component_result(),
          optional(:port) => component_result(),
          optional(:pathname) => component_result(),
          optional(:search) => component_result(),
          optional(:hash) => component_result(),
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
  # Module-level Variable for ambient routing (singleton via :persistent_term)
  # ---------------------------------------------------------------------------

  @params_term_key {__MODULE__, :url_params_variable}
  @pinned_prefix {__MODULE__, :pinned}
  @component_name_map %{
    "protocol" => :protocol,
    "username" => :username,
    "password" => :password,
    "hostname" => :hostname,
    "port" => :port,
    "pathname" => :pathname,
    "search" => :search,
    "hash" => :hash
  }

  @doc """
  Returns the `Web.AsyncContext.Variable` used to store matched URL params.

  The variable is a singleton — it is created once on first call and stored
  in `:persistent_term`. Downstream async tasks can call
  `Variable.get(Web.URLPattern.params())` to retrieve route groups injected
  by `match_context/3`.
  """
  @spec params() :: Variable.t()
  def params do
    var =
      case :persistent_term.get(@params_term_key, nil) do
        nil ->
          v = Variable.new("url_params")
          :persistent_term.put(@params_term_key, v)
          v

        v ->
          v
      end

    # Ensure the key is registered in the CURRENT process's variable registry.
    # Variable.new/2 only registers in the process that first creates the variable,
    # but in concurrent test environments (async: true) other processes get the
    # persistent_term value without having it in their own registry — causing
    # Snapshot.take/0 to miss the key when capturing context.
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
  Compiles a URL pattern.

  `pattern_input` may be:
    * A **string** URL pattern (e.g. `"https://example.com/:path"`) with an
      optional `base_url` string as the second argument.
    * A **map** of component patterns, e.g.
      `%{pathname: "/users/:id", hostname: "example.com"}`.

  ## Options (second argument when `pattern_input` is a map)

    * `:ignore_case` (`boolean`) — case-insensitive matching. Default `false`.

  ## Examples

      iex> p = Web.URLPattern.new("https://example.com/*")
      iex> Web.URLPattern.test(p, "https://example.com/page")
      true

      iex> p = Web.URLPattern.new(%{pathname: "/foo/:bar"})
      iex> result = Web.URLPattern.exec(p, %{pathname: "/foo/baz"})
      iex> result[:pathname][:groups]
      %{"bar" => "baz"}

  Raises `ArgumentError` for invalid patterns.
  """
  @spec new(String.t() | map(), String.t() | map()) :: t()
  def new(pattern_input, options \\ %{})

  def new(pattern_input, options) when is_binary(pattern_input) do
    {base_url, ignore_case, pinned} = string_pattern_options(options)

    cache_key = {pattern_input, base_url, ignore_case}

    fetch_cached_pattern(pinned, cache_key, fn ->
      compile_string_pattern!(pattern_input, base_url, ignore_case)
    end)
  end

  def new(pattern_input, options) when is_map(pattern_input) do
    ignore_case = Map.get(options, :ignore_case, false)
    pinned = Map.get(options, :pinned, false)

    base_url = pattern_base_url(pattern_input, options)

    # Validate: baseURL must not be an empty string
    if base_url == "" do
      raise ArgumentError, "baseURL may not be an empty string"
    end

    cache_key = {pattern_input, ignore_case}

    fetch_cached_pattern(pinned, cache_key, fn ->
      compile_map_pattern!(pattern_input, base_url, ignore_case)
    end)
  end

  defp string_pattern_options(options) do
    base_url =
      case options do
        base when is_binary(base) -> base
        %{base_url: base} -> base
        _ -> nil
      end

    ignore_case = if match?(%{ignore_case: _}, options), do: options.ignore_case, else: false
    pinned = if match?(%{pinned: _}, options), do: options.pinned, else: false
    {base_url, ignore_case, pinned}
  end

  defp pattern_base_url(pattern_input, options) do
    Map.get(pattern_input, :baseURL) ||
      Map.get(pattern_input, "baseURL") ||
      Map.get(options, :base_url)
  end

  defp fetch_cached_pattern(true, cache_key, builder) do
    pt_key = {@pinned_prefix, cache_key}

    case :persistent_term.get(pt_key, nil) do
      nil ->
        result = builder.()
        :persistent_term.put(pt_key, result)
        result

      compiled ->
        compiled
    end
  end

  defp fetch_cached_pattern(false, cache_key, builder) do
    case Cache.get(cache_key) do
      {:ok, compiled} ->
        compiled

      :miss ->
        result = builder.()
        Cache.put(cache_key, result)
        result
    end
  end

  # ---------------------------------------------------------------------------
  # test/2
  # ---------------------------------------------------------------------------

  @doc """
  Returns `true` if the given URL (string or `Web.URL`) matches the pattern.

  ## Examples

      iex> p = Web.URLPattern.new(%{pathname: "/foo/:bar"})
      iex> Web.URLPattern.test(p, %{pathname: "/foo/baz"})
      true

      iex> p = Web.URLPattern.new(%{pathname: "/foo/:bar"})
      iex> Web.URLPattern.test(p, %{pathname: "/other"})
      false
  """
  @spec test(t(), String.t() | map() | URL.t()) :: boolean()
  def test(%__MODULE__{} = pattern, input) do
    exec(pattern, input) != nil
  end

  @spec test(t(), String.t() | map() | URL.t(), String.t()) :: boolean()
  def test(%__MODULE__{} = pattern, input, base_url) when is_binary(base_url) do
    exec(pattern, input, base_url) != nil
  end

  # ---------------------------------------------------------------------------
  # exec/2,3
  # ---------------------------------------------------------------------------

  @doc """
  Executes the pattern against the input URL.

  Returns a `URLPatternResult` map with per-component `%{input: ..., groups: ...}`,
  or `nil` if the URL does not match.

  The `input` can be:
    * A URL string — parsed with `Web.URL.new/1`.
    * A `Web.URL` struct — accessed directly.
    * A component map — `%{pathname: "...", hostname: "..."}`.

  Matching against a `Web.Request` never reads the body stream.

  ## Examples

      iex> p = Web.URLPattern.new(%{pathname: "/u/:id"})
      iex> Web.URLPattern.exec(p, "https://x.com/u/7")[:pathname][:groups]
      %{"id" => "7"}
  """
  @spec exec(t(), String.t() | map() | URL.t()) :: result() | nil
  def exec(%__MODULE__{} = pattern, input) do
    exec(pattern, input, nil)
  end

  @spec exec(t(), String.t() | map() | URL.t(), String.t() | nil) :: result() | nil
  def exec(%__MODULE__{}, input, base_url) when is_map(input) and is_binary(base_url) do
    raise ArgumentError,
          "baseURL must not be provided as a separate argument when input is a URLPatternInit map"
  end

  def exec(%__MODULE__{} = pattern, input, base_url) do
    case extract_components(input, base_url) do
      {:ok, components, inputs} ->
        match_all_components(pattern, components, inputs)

      :error ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # match_context/3  (AsyncContext integration)
  # ---------------------------------------------------------------------------

  @doc """
  Matches the pattern against `input` and, if successful, runs `fun` with the
  matched params injected into the ambient `url_params()` context variable.

  Returns the result of `fun`, or `nil` if the pattern does not match.

  ## Examples

      iex> pattern = Web.URLPattern.new(%{pathname: "/users/:id"})
      iex> Web.URLPattern.match_context(pattern, %{pathname: "/users/99"}, fn ->
      ...>   Web.AsyncContext.Variable.get(Web.URLPattern.params())
      ...> end)
      %{"id" => "99"}
  """
  @spec match_context(t(), String.t() | map() | URL.t(), (-> result)) :: result | nil
  def match_context(%__MODULE__{} = pattern, input, fun) when is_function(fun, 0) do
    case exec(pattern, input) do
      nil ->
        nil

      result ->
        groups = extract_all_groups(result)
        Variable.run(params(), groups, fun)
    end
  end

  @doc """
  Compares a single component between two URL patterns.

  Returns `1` when `left` is more specific, `-1` when `right` is more
  specific, and `0` when they are equivalent for the requested component.
  """
  @spec compare_component(atom() | String.t(), t(), t()) :: -1 | 0 | 1
  def compare_component(component, %__MODULE__{} = left, %__MODULE__{} = right) do
    component = normalize_component_name!(component)
    left_tokens = component |> parse_component_parts!(left) |> parts_to_compare_tokens()
    right_tokens = component |> parse_component_parts!(right) |> parts_to_compare_tokens()
    compare_token_lists(left_tokens, right_tokens)
  end

  # ---------------------------------------------------------------------------
  # Internal: string-pattern compilation
  # ---------------------------------------------------------------------------

  @compare_delimiters [?/, ?., ?-, ?_]

  defp normalize_component_name!(component) when component in @components, do: component

  defp normalize_component_name!(component) when is_binary(component) do
    case Map.fetch(@component_name_map, component) do
      {:ok, normalized} -> normalized
      :error -> raise ArgumentError, "Unknown URLPattern component: #{inspect(component)}"
    end
  end

  defp normalize_component_name!(component) do
    raise ArgumentError, "Unknown URLPattern component: #{inspect(component)}"
  end

  defp parse_component_parts!(component, %__MODULE__{} = pattern) do
    parse_component_parts!(pattern, component)
  end

  defp parse_component_parts!(%__MODULE__{} = pattern, component) do
    pattern
    |> Map.fetch!(component)
    |> Parser.parse()
    |> case do
      {:ok, parts} -> parts
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp parts_to_compare_tokens(parts) do
    parts
    |> build_compare_tokens()
    |> merge_adjacent_fixed_tokens()
    |> fold_compare_prefixes()
    |> merge_adjacent_fixed_tokens()
  end

  defp build_compare_tokens(parts) do
    Enum.flat_map(parts, &part_to_compare_tokens/1)
  end

  defp part_to_compare_tokens({:literal, text}) do
    [%{type: :fixed, modifier: :none, prefix: "", value: text, suffix: "", grouped: false}]
  end

  defp part_to_compare_tokens({:name, _name, nil, modifier}) do
    [
      %{
        type: :segment_wildcard,
        modifier: modifier,
        prefix: "",
        value: "",
        suffix: "",
        grouped: false
      }
    ]
  end

  defp part_to_compare_tokens({:name, _name, pattern, modifier}) when pattern in [".*", ".*?"] do
    [
      %{
        type: :full_wildcard,
        modifier: modifier,
        prefix: "",
        value: "",
        suffix: "",
        grouped: false
      }
    ]
  end

  defp part_to_compare_tokens({:name, _name, pattern, modifier}) do
    [%{type: :regex, modifier: modifier, prefix: "", value: pattern, suffix: "", grouped: false}]
  end

  defp part_to_compare_tokens({:regex, pattern, modifier}) do
    [%{type: :regex, modifier: modifier, prefix: "", value: pattern, suffix: "", grouped: false}]
  end

  defp part_to_compare_tokens({:wildcard, modifier}) do
    [
      %{
        type: :full_wildcard,
        modifier: modifier,
        prefix: "",
        value: "",
        suffix: "",
        grouped: false
      }
    ]
  end

  defp part_to_compare_tokens({:group, inner_parts, :none}) do
    build_compare_tokens(inner_parts)
  end

  defp part_to_compare_tokens({:group, inner_parts, modifier}) do
    [collapse_group_compare_token(inner_parts, modifier)]
  end

  defp collapse_group_compare_token(inner_parts, modifier) do
    inner_tokens = inner_parts |> build_compare_tokens() |> merge_adjacent_fixed_tokens()
    {prefix, inner_tokens} = pop_leading_fixed(inner_tokens)
    {suffix, inner_tokens} = pop_trailing_fixed(inner_tokens)

    case inner_tokens do
      [] ->
        %{
          type: :fixed,
          modifier: modifier,
          prefix: "",
          value: prefix <> suffix,
          suffix: "",
          grouped: true
        }

      [token] ->
        %{
          token
          | modifier: modifier,
            prefix: prefix <> token.prefix,
            suffix: token.suffix <> suffix,
            grouped: true
        }

      _ ->
        %{
          type: :fixed,
          modifier: modifier,
          prefix: "",
          value: Compiler.to_string(inner_parts),
          suffix: "",
          grouped: true
        }
    end
  end

  defp pop_leading_fixed([%{type: :fixed, modifier: :none, value: value} | rest]) do
    {value, rest}
  end

  defp pop_leading_fixed(tokens), do: {"", tokens}

  defp pop_trailing_fixed(tokens) do
    case Enum.reverse(tokens) do
      [%{type: :fixed, modifier: :none, value: value} | rest] -> {value, Enum.reverse(rest)}
      _ -> {"", tokens}
    end
  end

  defp merge_adjacent_fixed_tokens(tokens) do
    Enum.reduce(tokens, [], fn
      %{type: :fixed, modifier: :none, value: value, grouped: false},
      [%{type: :fixed, modifier: :none, value: previous, grouped: false} = token | rest] ->
        [%{token | value: previous <> value} | rest]

      token, acc ->
        [token | acc]
    end)
    |> Enum.reverse()
  end

  defp fold_compare_prefixes(tokens) do
    do_fold_compare_prefixes(tokens, [])
  end

  defp do_fold_compare_prefixes([], acc), do: Enum.reverse(acc)

  defp do_fold_compare_prefixes(
         [
           %{type: :fixed, modifier: :none, value: value} = fixed,
           %{modifier: modifier, prefix: "", grouped: false} = token
           | rest
         ],
         acc
       )
       when modifier != :none do
    {prefix, body} = extract_compare_prefix(value)

    if prefix == "" do
      do_fold_compare_prefixes([token | rest], [fixed | acc])
    else
      acc = if body == "", do: acc, else: [%{fixed | value: body} | acc]
      do_fold_compare_prefixes(rest, [%{token | prefix: prefix} | acc])
    end
  end

  defp do_fold_compare_prefixes([token | rest], acc) do
    do_fold_compare_prefixes(rest, [token | acc])
  end

  # Parser.parse/1 does not emit zero-length literal tokens for valid public
  # patterns, so this fallback only guards malformed internal token streams.
  # coveralls-ignore-start
  defp extract_compare_prefix("") do
    {"", ""}
  end

  # coveralls-ignore-stop

  defp extract_compare_prefix(value) do
    last_char = String.last(value)
    last_codepoint = :binary.decode_unsigned(last_char)

    if last_codepoint in @compare_delimiters do
      {last_char, String.slice(value, 0, byte_size(value) - byte_size(last_char))}
    else
      {"", value}
    end
  end

  defp compare_token_lists([], []), do: 0

  defp compare_token_lists([left | _rest], []),
    do: compare_tokens(left, empty_fixed_compare_token())

  defp compare_token_lists([], [right | _rest]),
    do: compare_tokens(empty_fixed_compare_token(), right)

  defp compare_token_lists([left | left_rest], [right | right_rest]) do
    case compare_tokens(left, right) do
      0 -> compare_token_lists(left_rest, right_rest)
      result -> result
    end
  end

  defp empty_fixed_compare_token do
    %{type: :fixed, modifier: :none, prefix: "", value: "", suffix: "", grouped: false}
  end

  defp compare_tokens(left, right) do
    with 0 <- compare_rank(token_type_rank(left.type), token_type_rank(right.type)),
         0 <-
           compare_rank(token_modifier_rank(left.modifier), token_modifier_rank(right.modifier)),
         0 <- compare_lexical(left.prefix, right.prefix),
         0 <- compare_lexical(left.value, right.value) do
      compare_lexical(left.suffix, right.suffix)
    end
  end

  defp token_type_rank(:fixed), do: 3
  defp token_type_rank(:regex), do: 2
  defp token_type_rank(:segment_wildcard), do: 1
  defp token_type_rank(:full_wildcard), do: 0

  defp token_modifier_rank(:none), do: 3
  defp token_modifier_rank(:one_or_more), do: 2
  defp token_modifier_rank(:optional), do: 1
  defp token_modifier_rank(:zero_or_more), do: 0

  defp compare_rank(left, right) when left < right, do: -1
  defp compare_rank(left, right) when left > right, do: 1
  defp compare_rank(_left, _right), do: 0

  defp compare_lexical(left, right) when left < right, do: -1
  defp compare_lexical(left, right) when left > right, do: 1
  defp compare_lexical(_left, _right), do: 0

  defp compile_string_pattern!(input, base_url, ignore_case) do
    # Parse the string as a URL with patterns in each component.
    # The URLPattern spec uses a custom URL-like parser that allows pattern
    # syntax where URL chars would normally go.
    parsed = parse_url_pattern_string!(input, base_url)
    compile_parsed_components!(parsed, ignore_case)
  end

  defp parse_url_pattern_string!(input, base_url) do
    # Resolve the input against base_url when provided.
    resolved =
      if base_url do
        resolve_against_base(input, base_url)
      else
        input
      end

    validate_no_unescaped_data_opaque_path!(resolved)

    # Try to split the URL-like string into components.
    # We use a heuristic: look for "://" or ":" with a path to detect the
    # protocol boundary, then split the remaining components.
    resolved
    |> split_url_pattern()
    |> escape_inherited_base_literals(input, base_url)
  end

  defp escape_inherited_base_literals(parsed, _input, nil), do: parsed

  defp escape_inherited_base_literals(parsed, input, base_url) do
    base = extract_base_pattern_components(base_url)

    parsed
    |> maybe_escape_inherited_component(:search, input, base, ["?"])
    |> maybe_escape_inherited_component(:hash, input, base, ["#"])
  end

  defp maybe_escape_inherited_component(parsed, component, input, base, markers) do
    explicit? = Enum.any?(markers, &String.contains?(input, &1))
    base_value = Map.get(base, component)
    parsed_value = Map.get(parsed, component)

    if explicit? or parsed_value in [nil, ""] or base_value in [nil, ""] or
         parsed_value != base_value do
      parsed
    else
      Map.put(parsed, component, escape_base_pattern_literal(parsed_value, component))
    end
  end

  defp validate_no_unescaped_data_opaque_path!(input) do
    # `data:foobar` (unescaped `:` and non-empty opaque path) is invalid for
    # URLPattern string construction. Escaped-colon forms (e.g. `data\:foo`)
    # are handled separately by the parser and must remain allowed.
    case Regex.run(~r/^data:(?!\/\/)(.+)$/s, input, capture: :all_but_first) do
      [rest] when rest != "" ->
        raise ArgumentError,
              "URL string with an opaque path is not allowed in URLPattern: #{inspect(input)}"

      _ ->
        :ok
    end
  end

  # Split a URL pattern string into component patterns.
  # Returns a map: %{protocol: "...", hostname: "...", ...}
  defp split_url_pattern(input) do
    # Handle the case of relative paths (no scheme) only when we have a base
    # or when the pattern starts with "/" or "./"
    cond do
      # Fragment-only
      String.starts_with?(input, "#") ->
        %{hash: strip_prefix(input, "#")}

      # Query-only
      String.starts_with?(input, "?") ->
        %{search: strip_prefix(input, "?")}

      # Paths starting with "/" are relative and require a base URL
      String.starts_with?(input, "/") ->
        raise ArgumentError,
              "Relative pattern string requires a base URL: #{inspect(input)}"

      # Relative (no scheme detected)
      relative_pattern?(input) ->
        raise ArgumentError,
              "Relative pattern string requires a base URL: #{inspect(input)}"

      true ->
        do_split_url_pattern(input)
    end
  end

  defp relative_pattern?(input) do
    # A pattern is relative if it has no scheme-like prefix.
    # Schemes look like: [a-zA-Z][a-zA-Z0-9+\-.]* optionally with {…} groups, then ":"
    # Also: "data\\:" (escaped colon) forms a valid protocol separator.
    has_scheme =
      Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9+\-.*{}\[\]|?]*(\\:|\:)/, input)

    not has_scheme and not String.starts_with?(input, "/")
  end

  defp do_split_url_pattern(input) do
    # Split off hash first, then search, then the rest.
    {before_hash, hash} = split_at_unescaped(input, "#")
    {before_search, search} = split_search_component(before_hash)

    {scheme_and_rest, pathname_and_rest} = split_scheme(before_search)

    %{protocol: scheme, authority: authority, path: path_part} =
      parse_scheme_authority_path(scheme_and_rest, pathname_and_rest)

    {authority, path_part} = maybe_split_group_boundary(authority, path_part)

    {username, password, hostname, port} = split_authority(authority)

    # Pathname defaulting for authority URLs:
    # - If search/hash is present and no explicit path is provided, pathname defaults to "/".
    # - Otherwise, omitted pathname stays omitted (wildcard at compilation time).
    effective_path =
      if path_part == "" and scheme != "" and authority != "" and (search != "" or hash != "") do
        "/"
      else
        path_part
      end

    %{}
    |> put_if_present(:protocol, scheme)
    |> put_if_present(:username, username)
    |> put_if_present(:password, password)
    |> put_if_present(:hostname, hostname)
    |> then(fn m ->
      # When an authority (hostname) is explicitly present in the URL string pattern,
      # the port must be set explicitly — even if empty — so that it only matches
      # URLs without an explicit (non-default) port.  An absent port ("*" wildcard)
      # would wrongly allow port 8080, 9000, etc. to match.
      if authority != "" do
        Map.put(m, :port, port || "")
      else
        put_if_present(m, :port, port)
      end
    end)
    |> put_if_present(:pathname, effective_path)
    |> put_if_present(:search, search)
    |> put_if_present(:hash, hash)
  end

  # Split at the first unescaped occurrence of `char`
  defp split_at_unescaped(input, char) do
    split_at_unescaped(input, char, "")
  end

  defp split_at_unescaped("", _char, acc), do: {acc, ""}

  defp split_at_unescaped(<<"\\", c::utf8, rest::binary>>, char, acc) do
    split_at_unescaped(rest, char, acc <> "\\" <> <<c::utf8>>)
  end

  defp split_at_unescaped(input, char, acc) do
    char_size = byte_size(char)

    if binary_part(input, 0, min(char_size, byte_size(input))) == char do
      after_char = binary_part(input, char_size, byte_size(input) - char_size)
      {acc, after_char}
    else
      <<c::utf8, rest::binary>> = input
      split_at_unescaped(rest, char, acc <> <<c::utf8>>)
    end
  end

  defp split_search_component(input) do
    # "?" is only a search separator if not escaped and not inside a regex group
    # We need to skip "?" inside "()" or "{}", or after named group ":name?" or wildcard "*?"
    # `after_group` tracks whether the previous token was a group (:name, (regex), *)
    # `depth` tracks paren nesting; `brace_depth` tracks brace nesting
    split_search_component(input, "", 0, 0, false)
  end

  defp split_search_component("", acc, _depth, _bd, _after_group), do: {acc, ""}

  defp split_search_component(<<"\\?", rest::binary>>, acc, 0, 0, _after_group) do
    # \? at top level (outside groups) — still acts as the search separator.
    # The backslash prevents URLPattern from treating ? as a modifier, but the
    # ? still splits pathname from search in URL pattern strings.
    {acc, rest}
  end

  defp split_search_component(<<"\\?", rest::binary>>, acc, depth, bd, _after_group) do
    # \? inside groups — keep as escaped literal
    split_search_component(rest, acc <> "\\?", depth, bd, false)
  end

  defp split_search_component(<<"(", rest::binary>>, acc, depth, bd, _) do
    split_search_component(rest, acc <> "(", depth + 1, bd, false)
  end

  defp split_search_component(<<")", rest::binary>>, acc, depth, bd, _) when depth > 0 do
    split_search_component(rest, acc <> ")", depth - 1, bd, true)
  end

  defp split_search_component(<<"{", rest::binary>>, acc, depth, bd, _) do
    split_search_component(rest, acc <> "{", depth, bd + 1, false)
  end

  defp split_search_component(<<"}", rest::binary>>, acc, depth, bd, _) when bd > 0 do
    split_search_component(rest, acc <> "}", depth, bd - 1, true)
  end

  defp split_search_component(<<"*", rest::binary>>, acc, 0, 0, _) do
    split_search_component(rest, acc <> "*", 0, 0, true)
  end

  defp split_search_component(<<":", c::utf8, rest::binary>>, acc, 0, 0, _)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or c == ?_ or c == ?$ or c >= 0x80 do
    # Start of a named group :name — consume the name chars, set after_group = true
    {name_rest, after_name} = consume_name_chars(<<c::utf8>> <> rest)
    split_search_component(after_name, acc <> ":" <> name_rest, 0, 0, true)
  end

  defp split_search_component(<<"?", rest::binary>>, acc, 0, 0, true) do
    # ? after a group-end token → modifier
    split_search_component(rest, acc <> "?", 0, 0, false)
  end

  defp split_search_component(<<"?", rest::binary>>, acc, 0, 0, false) do
    # ? not after group and not inside any group → search separator
    {acc, rest}
  end

  defp split_search_component(<<c::utf8, rest::binary>>, acc, depth, bd, _) do
    split_search_component(rest, acc <> <<c::utf8>>, depth, bd, false)
  end

  defp consume_name_chars(input), do: consume_name_chars(input, "")
  defp consume_name_chars("", acc), do: {acc, ""}

  defp consume_name_chars(<<c::utf8, rest::binary>>, acc) do
    if urlpattern_name_char?(c) do
      consume_name_chars(rest, acc <> <<c::utf8>>)
    else
      {acc, <<c::utf8>> <> rest}
    end
  end

  defp urlpattern_name_char?(c) do
    (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9) or
      c == ?_ or c == ?$ or c >= 0x80
  end

  defp split_scheme(input) do
    # Handle escaped colon "scheme\\:rest" → scheme = up to \\:
    if Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9+\-.]*\\:/, input) do
      [scheme | rest_parts] = String.split(input, "\\:", parts: 2)
      rest = Enum.join(rest_parts, "\\:")
      {scheme <> ":", rest}
    else
      # Try to find "://" or ":" scheme separator, but only if the pattern before
      # it looks like a valid URI scheme (letters, digits, +, -, ., ?, *, {, })
      [scheme, authority_marker, rest] =
        Regex.run(
          ~r/^([a-zA-Z][a-zA-Z0-9+\-.]*(?:\{[^}]*\})*[a-zA-Z0-9+\-.?*]*?):(\/\/)?(.*)$/s,
          input,
          capture: :all_but_first
        )

      if authority_marker == "//" do
        {scheme <> "://", rest}
      else
        {scheme <> ":", rest}
      end
    end
  end

  defp parse_scheme_authority_path(scheme_and_rest, rest) do
    if String.contains?(scheme_and_rest, "://") do
      scheme = String.replace_suffix(scheme_and_rest, "://", "")
      # authority is everything up to the first "/" in rest
      {authority, path} = split_at_first_slash(rest)
      %{protocol: scheme, authority: authority, path: path}
    else
      scheme = String.replace_suffix(scheme_and_rest, ":", "")

      # Special-scheme escaped forms like "https\:user\:pass@host" should
      # still parse authority even without an explicit "//".
      if special_scheme?(scheme) and String.contains?(rest, "@") do
        {authority, path} = split_at_first_slash(rest)
        %{protocol: scheme, authority: authority, path: path}
      else
        # opaque path (e.g. "data:...")
        %{protocol: scheme, authority: "", path: rest}
      end
    end
  end

  defp special_scheme?(scheme) do
    scheme in ["http", "https", "ws", "wss", "ftp", "file"]
  end

  defp split_at_first_slash(input) do
    split_at_first_slash(input, "", 0, 0, false, false)
  end

  defp split_at_first_slash("", acc, _pd, _bd, _brackets, _escaped), do: {acc, ""}

  defp split_at_first_slash(<<"\\", c::utf8, rest::binary>>, acc, pd, bd, brackets, false) do
    split_at_first_slash(rest, acc <> "\\" <> <<c::utf8>>, pd, bd, brackets, false)
  end

  defp split_at_first_slash(<<"(", rest::binary>>, acc, pd, bd, brackets, false) do
    split_at_first_slash(rest, acc <> "(", pd + 1, bd, brackets, false)
  end

  defp split_at_first_slash(<<")", rest::binary>>, acc, pd, bd, brackets, false) when pd > 0 do
    split_at_first_slash(rest, acc <> ")", pd - 1, bd, brackets, false)
  end

  defp split_at_first_slash(<<"{", rest::binary>>, acc, pd, bd, brackets, false) do
    split_at_first_slash(rest, acc <> "{", pd, bd + 1, brackets, false)
  end

  defp split_at_first_slash(<<"}", rest::binary>>, acc, pd, bd, brackets, false) when bd > 0 do
    split_at_first_slash(rest, acc <> "}", pd, bd - 1, brackets, false)
  end

  defp split_at_first_slash(<<"[", rest::binary>>, acc, 0, 0, false, false) do
    split_at_first_slash(rest, acc <> "[", 0, 0, true, false)
  end

  defp split_at_first_slash(<<"]", rest::binary>>, acc, 0, 0, true, false) do
    split_at_first_slash(rest, acc <> "]", 0, 0, false, false)
  end

  defp split_at_first_slash(<<"/", rest::binary>>, acc, 0, 0, false, false) do
    {acc, "/" <> rest}
  end

  defp split_at_first_slash(<<c::utf8, rest::binary>>, acc, pd, bd, brackets, _escaped) do
    split_at_first_slash(rest, acc <> <<c::utf8>>, pd, bd, brackets, false)
  end

  # Split a userinfo string into {username, password} where the separator ":"
  # must NOT be the start of a named group (i.e., not followed by a letter/underscore).
  defp split_userinfo_password(userinfo) do
    split_userinfo_password(userinfo, "", 0, 0)
  end

  defp split_userinfo_password("", acc, _depth, _brace_depth), do: {acc, nil}

  defp split_userinfo_password(<<"(", rest::binary>>, acc, depth, brace_depth) do
    split_userinfo_password(rest, acc <> "(", depth + 1, brace_depth)
  end

  defp split_userinfo_password(<<")", rest::binary>>, acc, depth, brace_depth) when depth > 0 do
    split_userinfo_password(rest, acc <> ")", depth - 1, brace_depth)
  end

  defp split_userinfo_password(<<"{", rest::binary>>, acc, depth, brace_depth) do
    split_userinfo_password(rest, acc <> "{", depth, brace_depth + 1)
  end

  defp split_userinfo_password(<<"}", rest::binary>>, acc, depth, brace_depth)
       when brace_depth > 0 do
    split_userinfo_password(rest, acc <> "}", depth, brace_depth - 1)
  end

  # Escaped colon in userinfo is treated as the username/password separator.
  defp split_userinfo_password(<<"\\:", rest::binary>>, acc, 0, 0) do
    {acc, rest}
  end

  defp split_userinfo_password(<<"\\:", rest::binary>>, acc, depth, brace_depth) do
    split_userinfo_password(rest, acc <> "\\:", depth, brace_depth)
  end

  # ":" followed by a letter/underscore/$ is a named group start — not a separator
  defp split_userinfo_password(<<":", c::utf8, rest::binary>>, acc, 0, 0)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or c == ?_ or c == ?$ or c >= 0x80 do
    split_userinfo_password(<<c::utf8>> <> rest, acc <> ":", 0, 0)
  end

  # ":" at top-level, not followed by name-start → password separator
  defp split_userinfo_password(<<":", rest::binary>>, acc, 0, 0) do
    {acc, rest}
  end

  defp split_userinfo_password(<<c::utf8, rest::binary>>, acc, depth, brace_depth) do
    split_userinfo_password(rest, acc <> <<c::utf8>>, depth, brace_depth)
  end

  defp split_authority(""), do: {nil, nil, nil, nil}

  defp split_authority(authority) do
    {userinfo, hostport} = split_authority_userinfo(authority)
    {username, password} = split_authority_credentials(userinfo)
    {hostname, port} = split_authority_hostport(hostport)

    {username, password, hostname, port}
  end

  defp split_authority_userinfo(authority) do
    case String.split(authority, "@", parts: 2) do
      [userinfo, hostport] -> {userinfo, hostport}
      [hostport] -> {nil, hostport}
    end
  end

  defp split_authority_credentials(nil), do: {nil, nil}

  defp split_authority_credentials(userinfo) do
    case split_userinfo_password(userinfo) do
      {user, nil} -> {user, nil}
      {user, pass} -> {user, pass}
    end
  end

  defp split_authority_hostport(hostport) do
    case Regex.run(
           ~r/^(\[.*\]|\[.*\]:[^?#]*)(?::(\d+|\*|:[a-zA-Z_][a-zA-Z0-9_]*|\([^)]*\)))?$/,
           hostport
         ) do
      [_, host, port] -> {host, port}
      [_, host] -> {host, nil}
      nil -> split_hostname_port(hostport)
    end
  end

  defp split_hostname_port(hostport) do
    # For IPv6 with brackets, don't split on ":"
    if String.starts_with?(hostport, "[") do
      [ipv6_prefix | rest] = String.split(hostport, "]", parts: 2)
      host = if rest == [], do: ipv6_prefix, else: ipv6_prefix <> "]"
      {host, nil}
    else
      case Regex.run(~r/^(.*?)(?::(\d+|\*|(?::[a-zA-Z_$][a-zA-Z0-9_$]*|\([^)]*\))))?$/s, hostport) ||
             [nil, hostport] do
        [_, h, p] when p != "" -> {h, p}
        [_, h | _] -> {h, nil}
      end
    end
  end

  defp resolve_against_base(input, base_url) when is_binary(base_url) and base_url != "" do
    # Use URI.merge directly with the raw base_url string to avoid Web.URL's
    # search-param normalization (which adds "=" to bare keys like "?foo" → "?foo=").
    uri =
      base_url
      |> URI.parse()
      |> URI.merge(input)
      |> URI.to_string()

    uri
  end

  defp resolve_against_base(input, _), do: input

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp strip_prefix(input, prefix) do
    binary_part(input, byte_size(prefix), byte_size(input) - byte_size(prefix))
  end

  # ---------------------------------------------------------------------------
  # Internal: map-pattern compilation
  # ---------------------------------------------------------------------------

  defp compile_map_pattern!(pattern_map, base_url, ignore_case) do
    # Normalize component patterns from the map.
    # Components not in the map get the wildcard pattern "*".
    # Exception: if a base_url is provided, fixed components inherit from it;
    # and components explicitly set to "" become the empty-match pattern.
    normalized_pattern_map = normalize_keys(pattern_map)
    base_components = maybe_inherit_pattern_base_components(normalized_pattern_map, base_url)

    # If the pattern map has a relative pathname AND a base URL is available,
    # resolve the pattern pathname against the base URL (spec §3.2).
    pattern_map =
      if base_url != nil do
        norm = normalized_pattern_map
        pn = Map.get(norm, :pathname, "")

        cond do
          Map.has_key?(norm, :pathname) and pn == "" ->
            # Empty pathname with baseURL should inherit the base pathname.
            Map.delete(norm, :pathname)

          pn != "" and not String.starts_with?(pn, "/") ->
            resolved = Web.URL.new(pn, base_url).pathname
            Map.put(norm, :pathname, resolved)

          true ->
            normalized_pattern_map
        end
      else
        normalized_pattern_map
      end

    component_map = build_component_map(pattern_map, base_components)
    compile_parsed_components!(component_map, ignore_case)
  end

  defp extract_base_components(base_url) do
    url = URL.new(base_url)

    %{
      protocol: url.protocol |> String.trim_trailing(":"),
      hostname: url.hostname,
      port: url.port,
      pathname: url.pathname
    }
  end

  defp extract_base_pattern_components(base_url) do
    url = URL.new(base_url)

    %{
      protocol: url.protocol |> String.trim_trailing(":"),
      hostname: url.hostname,
      port: url.port,
      pathname: url.pathname,
      search: url_search_raw(url),
      hash: url_hash_raw(url)
    }
  end

  defp url_search_raw(%URL{} = url) do
    # Web.URL normalizes bare search keys: "?foo" becomes "?foo=" internally.
    # Reconstruct the raw search string from URLSearchParams pairs without adding "=".
    pairs = url.search_params.pairs

    if pairs == [] do
      ""
    else
      Enum.map_join(pairs, "&", fn
        {k, ""} -> k
        {k, v} -> k <> "=" <> v
      end)
    end
  end

  defp url_hash_raw(%URL{} = url) do
    case Web.URL.hash(url) do
      "#" <> rest -> rest
      other -> other
    end
  end

  defp build_component_map(pattern_map, base_components) do
    # Remove special keys like :baseURL
    pattern_map =
      pattern_map
      |> Map.delete(:baseURL)
      |> Map.delete("baseURL")

    # Normalize atom/string keys
    pattern_map = normalize_keys(pattern_map)

    # For each component: pattern_map > base_components > wildcard default
    component_map =
      Enum.reduce(@components, %{}, fn component, acc ->
        value =
          cond do
            Map.has_key?(pattern_map, component) ->
              Map.get(pattern_map, component)

            Map.has_key?(base_components, component) ->
              # A base_url was provided and this component has a fixed literal value.
              # Escape URLPattern syntax chars so literal URL content (e.g. "*" in
              # a query string) is not misinterpreted as pattern syntax.
              Map.get(base_components, component) |> escape_base_pattern_literal(component)

            true ->
              @wildcard_pattern
          end

        Map.put(acc, component, value)
      end)

    # Pattern-side port normalization:
    # When protocol is an exact literal (e.g. "http") and port is the default
    # for that protocol (e.g. "80"), normalize the pattern port to "" (exactly
    # empty) per the URLPattern spec.
    normalize_pattern_default_port(component_map)
  end

  # Escape URLPattern syntax characters in a string that comes from an actual
  # URL component (base URL content) so it is treated as a literal pattern,
  # not as URLPattern wildcard/group syntax.
  defp escape_base_pattern_literal(value, _component) do
    value
    # Escape backslash first (so we don't double-escape subsequent replacements)
    |> String.replace("\\", "\\\\")
    |> String.replace("*", "\\*")
    |> String.replace("+", "\\+")
    |> String.replace("?", "\\?")
    |> String.replace("{", "\\{")
    |> String.replace("}", "\\}")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
  end

  defp normalize_keys(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, normalize_key(key), value)
    end)
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key("ignoreCase"), do: :ignoreCase

  defp normalize_key(key) when is_binary(key),
    do: Map.get(@component_name_map, key, String.to_atom(key))

  # ---------------------------------------------------------------------------
  # Internal: compile components to %__MODULE__{}
  # ---------------------------------------------------------------------------

  defp compile_parsed_components!(component_map, ignore_case) do
    compiled =
      Enum.reduce(@components, %{}, fn component, acc ->
        Map.put(acc, component, compile_component_pattern(component, component_map, ignore_case))
      end)

    build_compiled_struct(compiled, ignore_case)
  end

  defp compile_component_pattern(component, component_map, ignore_case) do
    raw_pattern = Map.get(component_map, component, @wildcard_pattern)
    encoded_pattern = encode_pattern(component, raw_pattern, component_map)
    compile_component = compiled_component_name(component, component_map)

    case Parser.parse(encoded_pattern) do
      {:ok, parts} -> compile_parsed_component(parts, compile_component, ignore_case)
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp compiled_component_name(:pathname, component_map) do
    if opaque_protocol_pattern?(Map.get(component_map, :protocol, @wildcard_pattern)) do
      :opaque_pathname
    else
      :pathname
    end
  end

  defp compiled_component_name(component, _component_map), do: component

  defp compile_parsed_component(parts, compile_component, ignore_case) do
    {:ok, compiled_component} = Compiler.compile(parts, compile_component, ignore_case)
    {Compiler.to_string(parts), compiled_component}
  end

  defp build_compiled_struct(compiled, ignore_case) do
    Enum.reduce(
      @components,
      %__MODULE__{ignore_case: ignore_case, compiled: compiled},
      fn component, struct ->
        {canonical, _} = Map.get(compiled, component)
        Map.put(struct, component, canonical)
      end
    )
  end

  # Encode component-specific characters in the pattern string before parsing.
  # This mirrors the spec's "process a base URL string" and component-specific
  # encoding steps.
  defp encode_pattern(:protocol, pattern) do
    # Protocol patterns: strip trailing ":"
    # Non-ASCII characters are not valid as literal or regex-group content
    # in protocol patterns (protocols must be ASCII), but named-group names
    # (:name syntax) may use Unicode identifiers per the URLPattern spec.
    stripped = String.trim_trailing(pattern, ":")

    if has_non_ascii_outside_named_groups?(stripped) do
      raise ArgumentError,
            "Protocol patterns must only contain ASCII characters, got: #{inspect(pattern)}"
    end

    stripped
    |> encode_special_chars(:protocol)
  end

  defp encode_pattern(:search, pattern) do
    # Search patterns: strip leading "?"
    stripped = String.trim_leading(pattern, "?")
    validate_no_non_ascii_in_regex!(stripped, :search)
    validate_no_non_ascii_group_names!(stripped, :search)
    encode_special_chars(stripped, :search)
  end

  defp encode_pattern(:hash, pattern) do
    # Hash patterns: strip leading "#"
    stripped = String.trim_leading(pattern, "#")
    validate_no_non_ascii_in_regex!(stripped, :hash)
    validate_no_non_ascii_group_names!(stripped, :hash)
    encode_special_chars(stripped, :hash)
  end

  defp encode_pattern(:hostname, pattern) do
    # Strip fragment: per spec, a "#" in a hostname component-level pattern
    # is treated as the start of a fragment (silently ignored).
    pattern_no_frag =
      case :binary.split(pattern, "#") do
        [before, _after] -> before
        [whole] -> whole
      end

    normalized =
      pattern_no_frag
      |> String.replace(["\n", "\r", "\t"], "")
      |> split_hostname_suffix("\\?")
      |> split_hostname_suffix("/")
      |> maybe_ascii_hostname_pattern()

    validate_hostname_pattern!(normalized)
    validate_no_non_ascii_in_regex!(normalized, :hostname)
    encode_special_chars(normalized, :hostname)
  end

  defp encode_pattern(:port, pattern) do
    validate_port_pattern!(pattern)
    encode_special_chars(pattern, :port)
  end

  defp encode_pattern(:pathname, pattern) do
    # Normalize dot-segments in pathname patterns that don't contain pattern syntax.
    # Only apply dot-segment removal to absolute paths (starting with "/").
    # Relative paths like "./foo" or "../foo" are kept as-is so they can match
    # similar relative path inputs.
    normalized =
      cond do
        String.contains?(pattern, [":", "*", "(", ")", "{", "}"]) ->
          pattern

        String.starts_with?(pattern, "/") ->
          pattern |> remove_dot_segments()

        true ->
          pattern
      end

    validate_no_non_ascii_in_regex!(normalized, :pathname)
    validate_no_non_ascii_group_names!(normalized, :pathname)
    encode_special_chars(normalized, :pathname)
  end

  defp encode_pattern(:username, pattern) do
    validate_no_non_ascii_in_regex!(pattern, :username)
    validate_no_non_ascii_group_names!(pattern, :username)
    encode_special_chars(pattern, :username)
  end

  defp encode_pattern(:password, pattern) do
    validate_no_non_ascii_in_regex!(pattern, :password)
    validate_no_non_ascii_group_names!(pattern, :password)
    encode_special_chars(pattern, :password)
  end

  defp encode_pattern(component, pattern, component_map) do
    case {component,
          opaque_protocol_pattern?(Map.get(component_map, :protocol, @wildcard_pattern))} do
      {:pathname, true} ->
        validate_no_non_ascii_in_regex!(pattern, :pathname)
        validate_no_non_ascii_group_names!(pattern, :pathname)
        encode_special_chars(pattern, :opaque_pathname)

      {:hostname, _} ->
        encode_pattern(:hostname, pattern)

      _ ->
        encode_pattern(component, pattern)
    end
  end

  # Encode non-pattern, non-ASCII chars that need percent-encoding in each
  # component. In pattern position we keep `*`, `:`, `(`, `)`, `{`, `}`, `?`,
  # `+`, `\` as syntactic characters.
  defp encode_special_chars(pattern, component) do
    encode_pattern_chars(pattern, component)
  end

  # For characters that are NOT pattern syntax, apply component-specific
  # percent-encoding of non-ASCII. We walk the string; as soon as we see a
  # pattern-syntax character we stop encoding and let the parser handle it.
  @pattern_syntax_chars [?*, ?:, ?(, ?), ?{, ?}, ??, ?+, ?\\]

  defp encode_pattern_chars("", _), do: ""

  defp encode_pattern_chars(<<"\\", c::utf8, rest::binary>>, comp) do
    # Escaped character — keep the escape and encode the char if needed
    encoded = encode_char_for_component(c, comp)
    "\\" <> encoded <> encode_pattern_chars(rest, comp)
  end

  # Colon followed by a name-start char: this is a named group ":name"
  # Pass the ":" and consume the name characters without encoding them
  defp encode_pattern_chars(<<":", c::utf8, rest::binary>>, comp)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or c == ?_ or c == ?$ or c >= 0x80 do
    {name_chars, after_name} = consume_name_raw(<<c::utf8>> <> rest)
    ":" <> name_chars <> encode_pattern_chars(after_name, comp)
  end

  defp encode_pattern_chars(<<c::utf8, rest::binary>>, comp)
       when c in @pattern_syntax_chars do
    <<c>> <> encode_pattern_chars(rest, comp)
  end

  defp encode_pattern_chars(<<c::utf8, rest::binary>>, comp) do
    encode_char_for_component(c, comp) <> encode_pattern_chars(rest, comp)
  end

  # Consume raw name chars (Unicode-aware, no encoding)
  defp consume_name_raw(input), do: consume_name_raw(input, "")
  defp consume_name_raw("", acc), do: {acc, ""}

  defp consume_name_raw(<<c::utf8, rest::binary>>, acc)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9) or
              c == ?_ or c == ?$ or c >= 0x80 do
    consume_name_raw(rest, acc <> <<c::utf8>>)
  end

  defp consume_name_raw(rest, acc), do: {acc, rest}

  # Pathname must percent-encode ASCII braces as URL code points.
  defp encode_char_for_component(?{, :pathname), do: "%7B"
  defp encode_char_for_component(?}, :pathname), do: "%7D"
  defp encode_char_for_component(?\s, :pathname), do: "%20"
  defp encode_char_for_component(?\s, :opaque_pathname), do: " "

  # For ASCII chars that need no encoding, just return as-is
  defp encode_char_for_component(c, _comp) when c < 0x80 do
    <<c>>
  end

  # For non-ASCII: apply percent-encoding for most components
  defp encode_char_for_component(c, :pathname) do
    <<c::utf8>> |> percent_encode_codepoint()
  end

  defp encode_char_for_component(c, :search) do
    <<c::utf8>> |> percent_encode_codepoint()
  end

  defp encode_char_for_component(c, :hash) do
    <<c::utf8>> |> percent_encode_codepoint()
  end

  defp encode_char_for_component(c, :username) do
    <<c::utf8>> |> percent_encode_codepoint()
  end

  defp encode_char_for_component(c, :password) do
    <<c::utf8>> |> percent_encode_codepoint()
  end

  defp encode_char_for_component(c, :hostname) do
    <<c::utf8>>
  end

  defp encode_char_for_component(c, _comp) do
    <<c::utf8>>
  end

  defp percent_encode_codepoint(char) do
    char
    |> :binary.bin_to_list()
    |> Enum.map_join("", fn byte ->
      "%" <> String.upcase(Integer.to_string(byte, 16) |> String.pad_leading(2, "0"))
    end)
  end

  # Percent-encode non-ASCII characters in a string, leaving ASCII and already
  # percent-encoded sequences untouched.
  defp percent_encode_non_ascii(input) do
    percent_encode_non_ascii(input, "")
  end

  defp percent_encode_non_ascii("", acc), do: acc

  # Skip already-encoded sequences %XX
  defp percent_encode_non_ascii(<<"%", a::utf8, b::utf8, rest::binary>>, acc)
       when a in ?0..?9 or a in ?a..?f or a in ?A..?F do
    percent_encode_non_ascii(rest, acc <> "%" <> <<a::utf8>> <> <<b::utf8>>)
  end

  # ASCII chars pass through unchanged
  defp percent_encode_non_ascii(<<c::utf8, rest::binary>>, acc) when c <= 0x7F do
    percent_encode_non_ascii(rest, acc <> <<c::utf8>>)
  end

  # Non-ASCII: percent-encode all UTF-8 bytes
  defp percent_encode_non_ascii(<<c::utf8, rest::binary>>, acc) do
    encoded = <<c::utf8>> |> percent_encode_codepoint()
    percent_encode_non_ascii(rest, acc <> encoded)
  end

  # ---------------------------------------------------------------------------
  # Hostname pattern validation
  # ---------------------------------------------------------------------------

  # Characters that make a hostname pattern invalid when they appear unescaped
  # and are not inside a group or regex region.
  # ---------------------------------------------------------------------------
  # Protocol ASCII validation helper
  # ---------------------------------------------------------------------------

  # Returns true if the pattern has non-ASCII characters outside of named-group
  # names (:name syntax). Named-group names may use Unicode identifiers per spec.
  # Literal parts and regex-group content must be ASCII in protocol patterns.
  defp has_non_ascii_outside_named_groups?(pattern) do
    has_non_ascii_outside_named_groups?(pattern, false, 0)
  end

  # in_name: true when consuming a :name
  # paren_depth: depth of regex (…) groups
  defp has_non_ascii_outside_named_groups?("", _in_name, _pd), do: false

  defp has_non_ascii_outside_named_groups?(<<"\\", _c::utf8, rest::binary>>, _in_name, pd) do
    has_non_ascii_outside_named_groups?(rest, false, pd)
  end

  # Named group start: ":letter" — consume name chars without checking non-ASCII
  defp has_non_ascii_outside_named_groups?(<<":", c::utf8, rest::binary>>, false, 0)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or c == ?_ or c == ?$ or c >= 0x80 do
    # Consume the entire name (Unicode ok inside)
    {_, after_name} = consume_name_raw(<<c::utf8>> <> rest)
    has_non_ascii_outside_named_groups?(after_name, false, 0)
  end

  defp has_non_ascii_outside_named_groups?(<<"(", rest::binary>>, _in_name, pd) do
    has_non_ascii_outside_named_groups?(rest, false, pd + 1)
  end

  defp has_non_ascii_outside_named_groups?(<<")", rest::binary>>, _in_name, pd) when pd > 0 do
    has_non_ascii_outside_named_groups?(rest, false, pd - 1)
  end

  defp has_non_ascii_outside_named_groups?(<<c::utf8, rest::binary>>, _in_name, pd) do
    if c > 0x7F do
      # Non-ASCII character outside a named-group name → violation
      true
    else
      has_non_ascii_outside_named_groups?(rest, false, pd)
    end
  end

  # ---------------------------------------------------------------------------
  # Non-ASCII in regex groups validation helpers
  # ---------------------------------------------------------------------------

  # Raises if the pattern contains non-ASCII characters inside regex `(...)` groups.
  # Regex content must be ASCII (per spec: percent-encode non-ASCII before pattern).
  defp validate_no_non_ascii_in_regex!(pattern, component) do
    if has_non_ascii_in_paren_group?(pattern) do
      raise ArgumentError,
            "Non-ASCII characters are not allowed inside regex groups in #{component} patterns: #{inspect(pattern)}"
    end
  end

  # Returns true when pattern has non-ASCII inside a `(...)` group (paren depth > 0).
  defp has_non_ascii_in_paren_group?(pattern), do: has_non_ascii_in_paren_group?(pattern, 0)

  defp has_non_ascii_in_paren_group?("", _pd), do: false

  defp has_non_ascii_in_paren_group?(<<"\\", _c::utf8, rest::binary>>, pd) do
    has_non_ascii_in_paren_group?(rest, pd)
  end

  # Named group ":name" — skip name chars (they are Unicode-safe)
  defp has_non_ascii_in_paren_group?(<<":", c::utf8, rest::binary>>, 0)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or c == ?_ or c == ?$ or c >= 0x80 do
    {_, after_name} = consume_name_raw(<<c::utf8>> <> rest)
    has_non_ascii_in_paren_group?(after_name, 0)
  end

  defp has_non_ascii_in_paren_group?(<<"(", rest::binary>>, pd) do
    has_non_ascii_in_paren_group?(rest, pd + 1)
  end

  defp has_non_ascii_in_paren_group?(<<")", rest::binary>>, pd) when pd > 0 do
    has_non_ascii_in_paren_group?(rest, pd - 1)
  end

  defp has_non_ascii_in_paren_group?(<<c::utf8, rest::binary>>, pd) do
    # Non-ASCII inside a paren group → violation
    if c > 0x7F and pd > 0 do
      true
    else
      has_non_ascii_in_paren_group?(rest, pd)
    end
  end

  # Raises if named-group names contain characters that are not valid ECMAScript
  # IdentifierName start/continue characters (no emoji, no lone surrogates).
  # Specifically, emoji (>= U+1F000) and lone surrogates are never valid.
  defp validate_no_non_ascii_group_names!(pattern, component) do
    if has_invalid_group_name?(pattern) do
      raise ArgumentError,
            "Named-group names must be valid ECMAScript identifiers in #{component} patterns: #{inspect(pattern)}"
    end
  end

  defp has_invalid_group_name?(pattern), do: has_invalid_group_name?(pattern, false)
  defp has_invalid_group_name?("", _in_name), do: false

  defp has_invalid_group_name?(<<"\\", _c::utf8, rest::binary>>, _) do
    has_invalid_group_name?(rest, false)
  end

  # Named group start ":c"
  defp has_invalid_group_name?(<<":", c::utf8, rest::binary>>, false)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or c == ?_ or c == ?$ do
    # Valid ASCII name start — consume the rest of the name
    has_invalid_group_name?(rest, true)
  end

  # Unicode name start (>= 0x80) — check it's a valid ID_Start (not emoji/surrogate/replacement)
  defp has_invalid_group_name?(<<":", c::utf8, rest::binary>>, false) when c >= 0x80 do
    # Emoji (>= 0x1F000), surrogate range (0xD800-0xDFFF), or U+FFFD (replacement char) → invalid
    if c >= 0x1F000 or (c >= 0xD800 and c <= 0xDFFF) or c == 0xFFFD do
      true
    else
      has_invalid_group_name?(rest, true)
    end
  end

  # Continue consuming name chars
  defp has_invalid_group_name?(<<c::utf8, rest::binary>>, true)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9) or
              c == ?_ or c == ?$ do
    has_invalid_group_name?(rest, true)
  end

  # Unicode continue char
  defp has_invalid_group_name?(<<c::utf8, rest::binary>>, true) when c >= 0x80 do
    if c >= 0x1F000 or (c >= 0xD800 and c <= 0xDFFF) or c == 0xFFFD do
      true
    else
      has_invalid_group_name?(rest, true)
    end
  end

  # End of name — any non-name char
  defp has_invalid_group_name?(<<_c::utf8, rest::binary>>, true) do
    has_invalid_group_name?(rest, false)
  end

  defp has_invalid_group_name?(<<_c::utf8, rest::binary>>, false) do
    has_invalid_group_name?(rest, false)
  end

  # ---------------------------------------------------------------------------
  # Characters that make a hostname pattern invalid when they appear unescaped
  # and are not inside a group or regex region.
  # Note: ":", "[", "]", "{", "}", "?", "+", "*" are handled specially below
  @forbidden_hostname_chars [?\s, ?%, ?<, ?>, ?@, ?^, ?|, ?#]

  defp validate_hostname_pattern!(pattern) do
    validate_hostname_chars!(pattern, 0, 0, false, false)
  end

  # paren_depth: nesting level of (...)
  # brace_depth: nesting level of {...}
  # in_brackets: inside [...] (IPv6 literal)
  # after_group: true when the prev top-level token was a group/wildcard/name
  defp validate_hostname_chars!("", _pd, _bd, in_brackets, _ag) do
    # Unclosed [...] bracket → invalid
    if in_brackets, do: raise(ArgumentError, "Unmatched '[' in hostname pattern"), else: :ok
  end

  # Backslash escape: check that escaped char is valid (e.g., \: is invalid)
  defp validate_hostname_chars!(<<"\\", c::utf8, rest::binary>>, 0, 0, false, _ag) do
    if c == ?: do
      raise ArgumentError, "Invalid hostname pattern character: \\:"
    end

    validate_hostname_chars!(rest, 0, 0, false, false)
  end

  defp validate_hostname_chars!(<<"\\", _c::utf8, rest::binary>>, pd, bd, in_brackets, ag) do
    validate_hostname_chars!(rest, pd, bd, in_brackets, ag)
  end

  defp validate_hostname_chars!(<<"(", rest::binary>>, pd, bd, in_brackets, _ag) do
    validate_hostname_chars!(rest, pd + 1, bd, in_brackets, false)
  end

  defp validate_hostname_chars!(<<")", rest::binary>>, pd, bd, in_brackets, _ag) when pd > 0 do
    validate_hostname_chars!(rest, pd - 1, bd, in_brackets, pd == 1)
  end

  defp validate_hostname_chars!(<<"{", rest::binary>>, pd, bd, in_brackets, _ag) do
    validate_hostname_chars!(rest, pd, bd + 1, in_brackets, false)
  end

  defp validate_hostname_chars!(<<"}", rest::binary>>, pd, bd, in_brackets, _ag) when bd > 0 do
    validate_hostname_chars!(rest, pd, bd - 1, in_brackets, bd == 1)
  end

  # "?" requires the previous token to have been a group/wildcard/named group
  defp validate_hostname_chars!(<<"?", rest::binary>>, 0, 0, false, after_group) do
    unless after_group do
      raise ArgumentError,
            "Invalid hostname pattern: '?' must follow a group or wildcard"
    end

    validate_hostname_chars!(rest, 0, 0, false, false)
  end

  # "+" and "*" at top level — allowed; "*" sets after_group=true for subsequent "?"
  defp validate_hostname_chars!(<<"+", rest::binary>>, 0, 0, false, _ag) do
    validate_hostname_chars!(rest, 0, 0, false, false)
  end

  defp validate_hostname_chars!(<<"+", rest::binary>>, 0, 0, true, _ag) do
    validate_hostname_chars!(rest, 0, 0, true, false)
  end

  defp validate_hostname_chars!(<<"*", rest::binary>>, 0, 0, false, _ag) do
    validate_hostname_chars!(rest, 0, 0, false, true)
  end

  defp validate_hostname_chars!(<<"*", rest::binary>>, 0, 0, true, _ag) do
    validate_hostname_chars!(rest, 0, 0, true, true)
  end

  # "[" starts IPv6 bracket context — only valid when not already in brackets
  defp validate_hostname_chars!(<<"[", rest::binary>>, 0, 0, false, _ag) do
    validate_hostname_chars!(rest, 0, 0, true, false)
  end

  # "[" when already in brackets or inside group → raise
  defp validate_hostname_chars!(<<"[", _rest::binary>>, 0, 0, true, _ag) do
    raise ArgumentError, "Invalid hostname pattern character: \"[\""
  end

  # "]" ends IPv6 bracket context
  defp validate_hostname_chars!(<<"]", rest::binary>>, 0, 0, true, _ag) do
    validate_hostname_chars!(rest, 0, 0, false, false)
  end

  # "]" when NOT in brackets → invalid
  defp validate_hostname_chars!(<<"]", _rest::binary>>, 0, 0, false, _ag) do
    raise ArgumentError, "Invalid hostname pattern character: \"]\""
  end

  # ":" when followed by a name-start char is a URLPattern named group — allow
  defp validate_hostname_chars!(<<":", c::utf8, rest::binary>>, 0, 0, in_brackets, _ag)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or c == ?_ or c == ?$ or c >= 0x80 do
    {_, after_name} = consume_name_raw(<<c::utf8>> <> rest)
    validate_hostname_chars!(after_name, 0, 0, in_brackets, true)
  end

  # ":" inside brackets (IPv6 address) is fine
  defp validate_hostname_chars!(<<":", rest::binary>>, 0, 0, true, _ag) do
    validate_hostname_chars!(rest, 0, 0, true, false)
  end

  defp validate_hostname_chars!(<<c::utf8, rest::binary>>, 0, 0, true, _ag)
       when (c >= ?0 and c <= ?9) or (c >= ?a and c <= ?f) or (c >= ?A and c <= ?F) or c == ?. do
    validate_hostname_chars!(rest, 0, 0, true, false)
  end

  defp validate_hostname_chars!(<<c::utf8, _rest::binary>>, 0, 0, true, _ag) do
    raise ArgumentError,
          "Invalid hostname pattern character inside IPv6 literal: #{inspect(<<c::utf8>>)}"
  end

  # Bare ":" at top level outside brackets — forbidden (not followed by name-start)
  defp validate_hostname_chars!(<<":", _rest::binary>>, 0, 0, false, _ag) do
    raise ArgumentError, "Invalid hostname pattern character: \":\""
  end

  defp validate_hostname_chars!(<<c::utf8, rest::binary>>, 0, 0, in_brackets, _ag) do
    if c in @forbidden_hostname_chars do
      raise ArgumentError,
            "Invalid hostname pattern character: #{inspect(<<c>>)}"
    end

    validate_hostname_chars!(rest, 0, 0, in_brackets, false)
  end

  # Inside paren or brace group — check for non-ASCII in hostname context
  defp validate_hostname_chars!(<<c::utf8, _rest::binary>>, _pd, _bd, _in_brackets, _ag)
       when c > 0x7F do
    # Non-ASCII inside any group context in a hostname pattern is not allowed
    raise ArgumentError,
          "Non-ASCII characters are not allowed in hostname patterns: #{inspect(<<c::utf8>>)}"
  end

  defp validate_hostname_chars!(<<_c::utf8, rest::binary>>, pd, bd, in_brackets, ag) do
    validate_hostname_chars!(rest, pd, bd, in_brackets, ag)
  end

  # ---------------------------------------------------------------------------
  # Port validation
  # ---------------------------------------------------------------------------

  defp validate_port_pattern!(pattern) do
    # Pure numeric ports above 65535 are invalid.
    # Patterns with wildcards/named-groups are fine.
    if Regex.match?(~r/^\d+$/, pattern) do
      port_num = String.to_integer(pattern)

      if port_num > 65_535 do
        raise ArgumentError, "Port number out of range: #{port_num}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Component extraction from input
  # ---------------------------------------------------------------------------

  defp extract_components(input, base_url), do: normalize_input(input, base_url)

  defp normalize_input(%Web.Request{url: url}, base_url), do: normalize_input(url, base_url)

  defp normalize_input(input, base_url) when is_binary(input) and not is_nil(base_url) do
    normalize_binary_input_with_base(input, base_url)
  end

  defp normalize_input(input, _base_url) when is_binary(input), do: normalize_binary_input(input)
  defp normalize_input(%URL{} = input, _base_url), do: {:ok, url_to_components(input), [input]}

  defp normalize_input(input, base_url) when is_map(input),
    do: {:ok, map_to_components(input, base_url), [input]}

  defp normalize_input(_input, _base_url), do: :error

  defp normalize_binary_input_with_base(input, base_url) do
    case resolve_url(input, base_url) do
      {:ok, combined} -> {:ok, url_to_components(combined, input), [input, base_url]}
      :error -> :error
    end
  end

  defp normalize_binary_input(input) do
    case parse_url_string(input) do
      {:ok, url, raw_for_components} -> {:ok, url_to_components(url, raw_for_components), [input]}
      :error -> :error
    end
  end

  defp resolve_url(input, base_url) when is_binary(base_url) do
    # `data:` URLs are non-hierarchical and cannot be used as a base URL
    # for relative resolution in URLPattern exec/test input processing.
    if String.starts_with?(String.downcase(base_url), "data:") do
      :error
    else
      {:ok, URL.new(input, base_url)}
    end
  rescue
    _ -> :error
  end

  defp parse_url_string(input) do
    parse_input = normalize_special_scheme_authority_input(input)

    # We use URL.new but validate it actually parsed a scheme
    url = URL.new(parse_input)

    if url.protocol == "" and not String.contains?(parse_input, "/") do
      :error
    else
      {:ok, url, parse_input}
    end
  end

  # Inputs like "https:user:pass@example.com" (special schemes without "//")
  # should be interpreted with authority semantics.
  defp normalize_special_scheme_authority_input(input) do
    case Regex.run(~r|^([a-zA-Z][a-zA-Z0-9+\-.]*):(?!//)([^/?#]*@[^?#]*)$|, input,
           capture: :all_but_first
         ) do
      [scheme, rest] ->
        if special_scheme?(String.downcase(scheme)) do
          scheme <> "://" <> rest
        else
          input
        end

      _ ->
        input
    end
  end

  defp url_to_components(%URL{} = url, raw_string \\ nil) do
    # For search: prefer raw string to avoid Web.URL normalizing "?foo" → "?foo=".
    # For hash/hostname/userinfo: Web.URL is fine (no problematic normalization),
    # BUT hostname strips IPv6 brackets which breaks pattern matching.
    # url_search_raw reconstructs search without adding "=" to bare keys.
    search_raw = url_search_raw(url)
    hash_raw = url_hash_raw(url)

    # For hostname: Web.URL strips IPv6 brackets (e.g. stores "::1" instead of "[::1]").
    # Restore brackets when needed.
    hostname_raw = normalize_hostname(url.hostname)
    protocol = url.protocol |> String.trim_trailing(":")

    # For username/password: Web.URL doesn't expose them; extract from raw URL string
    # but ONLY when raw_string looks like a full URL (has "://"), not a relative input.
    {username_raw, password_raw} =
      if is_binary(raw_string) and String.contains?(raw_string, "://") do
        raw_userinfo(raw_string)
      else
        {"", ""}
      end

    %{
      protocol: protocol,
      username: username_raw,
      password: password_raw,
      hostname: hostname_raw,
      port: url.port,
      pathname: normalize_string_input_pathname(url.pathname, raw_string, protocol),
      search: search_raw,
      hash: hash_raw
    }
    |> normalize_input_default_port()
  end

  # Normalize a hostname value (lower-case, preserve IPv6 brackets).
  defp normalize_hostname(h) do
    # Web.URL strips [] from IPv6; if hostname contains ":" it was IPv6
    if String.contains?(h, ":") do
      "[" <> h <> "]"
    else
      host_to_ascii(h)
    end
  end

  # Extract raw username and password from a URL string.
  # Returns {"", ""} if no userinfo present.
  defp raw_userinfo(url_string) do
    url_string
    |> extract_raw_authority()
    |> raw_authority_userinfo()
  end

  defp extract_raw_authority(url_string) do
    case Regex.run(~r|^[a-zA-Z][a-zA-Z0-9+\-.]*://([^/?#]*)|, url_string) do
      [_, authority] -> authority
      _ -> ""
    end
  end

  defp raw_authority_userinfo(authority) do
    case String.split(authority, "@", parts: 2) do
      [userinfo, _host] -> split_raw_userinfo(userinfo)
      [_host] -> {"", ""}
    end
  end

  defp split_raw_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, pass] -> {user, pass}
      [user] -> {user, ""}
    end
  end

  defp map_to_components(input_map, base_url) do
    # Determine the baseURL string for relative pathname resolution.
    base_url_str = input_base_url(input_map, base_url)

    # Normalize the input map, merging a baseURL if provided
    base_components = input_base_components(base_url_str)

    normalized = normalize_keys(input_map)
    explicit_pathname? = Map.has_key?(normalized, :pathname)

    components =
      Enum.reduce(@components, base_components || %{}, fn comp, acc ->
        case Map.get(normalized, comp) do
          nil -> Map.put_new(acc, comp, "")
          val -> Map.put(acc, comp, normalize_component_input(comp, val))
        end
      end)
      |> maybe_inherit_base_search(normalized, base_url_str)
      |> preserve_opaque_map_pathname(normalized, explicit_pathname?)
      |> normalize_input_default_port()

    resolve_relative_input_pathname(components, base_url_str, explicit_pathname?)
  end

  defp input_base_url(input_map, base_url) do
    cond do
      Map.has_key?(input_map, :baseURL) -> Map.get(input_map, :baseURL)
      Map.has_key?(input_map, "baseURL") -> Map.get(input_map, "baseURL")
      base_url != nil -> base_url
      true -> nil
    end
  end

  defp input_base_components(nil), do: nil

  defp input_base_components(base_url_str) do
    url = URL.new(base_url_str)
    url_to_components(url, base_url_str)
  end

  defp resolve_relative_input_pathname(components, nil, _explicit_pathname?), do: components
  defp resolve_relative_input_pathname(components, _base_url_str, false), do: components

  defp resolve_relative_input_pathname(components, base_url_str, true) do
    pathname = Map.get(components, :pathname, "")

    if pathname != "" and not String.starts_with?(pathname, "/") do
      Map.put(components, :pathname, URL.new(pathname, base_url_str).pathname)
    else
      components
    end
  end

  # Input-side: if protocol is a known scheme and port == its default, strip the port.
  defp normalize_input_default_port(%{protocol: proto, port: port} = components)
       when is_binary(proto) and is_binary(port) do
    default = Map.get(@default_ports, proto)

    if port != "" and default != nil and port == default do
      Map.put(components, :port, "")
    else
      components
    end
  end

  # Pattern-side: if protocol is an exact literal and port equals its default, strip to "".
  defp normalize_pattern_default_port(component_map) do
    protocol = Map.get(component_map, :protocol, @wildcard_pattern)
    port = Map.get(component_map, :port, @wildcard_pattern)
    default = Map.get(@default_ports, protocol)
    is_literal = not Regex.match?(~r/[*:({?+\\]/, protocol)

    if is_literal and port != @wildcard_pattern and default != nil and port == default do
      Map.put(component_map, :port, "")
    else
      component_map
    end
  end

  defp normalize_component_input(:protocol, val) do
    # URLPatternInit protocol input should not include a trailing ':'; treat
    # colon-containing values as invalid component input.
    if String.contains?(val, ":") do
      @invalid_component
    else
      normalized = val |> String.trim_trailing(":") |> String.downcase()
      # Non-ASCII chars in protocol make it an invalid scheme → return sentinel
      if String.match?(normalized, ~r/[^\x00-\x7F]/) do
        @invalid_component
      else
        normalized
      end
    end
  end

  defp normalize_component_input(:search, val) do
    val
    |> String.trim_leading("?")
    |> percent_encode_non_ascii()
  end

  defp normalize_component_input(:hash, val) do
    val
    |> String.trim_leading("#")
    |> percent_encode_non_ascii()
  end

  defp normalize_component_input(:port, val) do
    # Step 1: strip ASCII tab characters (URL parsers ignore tabs in port values)
    tab_stripped = String.replace(val, "\t", "")
    # Step 2: extract only the leading digit run; anything from the first non-digit onward
    # is stripped. If the original was non-empty but had no leading digits → invalid port.
    stripped = Regex.replace(~r/[^\d].*$/s, tab_stripped, "")

    if tab_stripped != "" and stripped == "" do
      @invalid_component
    else
      stripped
    end
  end

  defp normalize_component_input(:pathname, val) do
    encoded =
      val
      |> percent_encode_non_ascii()
      |> String.replace(" ", "%20")
      # { and } are not valid in URL paths and must be percent-encoded
      |> String.replace("{", "%7B")
      |> String.replace("}", "%7D")

    # Only normalize dot-segments for absolute paths (starting with "/").
    # Relative paths like "./foo" or "../foo" come from map inputs and
    # should be preserved as-is (they are resolved separately when a
    # baseURL is present).
    if String.starts_with?(encoded, "/") do
      normalize_pathname(encoded)
    else
      encoded
    end
  end

  defp normalize_component_input(:username, val) do
    percent_encode_non_ascii(val)
  end

  defp normalize_component_input(:password, val) do
    percent_encode_non_ascii(val)
  end

  defp normalize_component_input(:hostname, val) do
    val
    # URL parsing strips ASCII tab/newline from hostnames
    |> String.replace(["\n", "\r", "\t"], "")
    # Hostname stops at path/search/hash delimiters
    |> stop_at_uri_delimiters()
    |> host_to_ascii()
  end

  defp stop_at_uri_delimiters(h) do
    h
    |> String.split("/", parts: 2)
    |> hd()
    |> String.split("?", parts: 2)
    |> hd()
    |> String.split("#", parts: 2)
    |> hd()
  end

  defp normalize_pathname(path) when is_binary(path) do
    # Normalize . and .. segments
    path
    |> URI.parse()
    |> Map.get(:path, path)
    |> remove_dot_segments()
  end

  defp remove_dot_segments(path) do
    path
    |> String.split("/")
    |> Enum.reduce([], fn segment, acc ->
      case {segment, acc} do
        {".", _} -> acc
        {"..", _} -> Enum.drop(acc, 1)
        {seg, _} -> [seg | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.join("/")
    |> then(fn p ->
      if String.starts_with?(path, "/") and not String.starts_with?(p, "/") do
        "/" <> p
      else
        p
      end
    end)
  end

  defp preserve_opaque_map_pathname(components, normalized, true) do
    protocol = Map.get(components, :protocol, "")

    if opaque_scheme?(protocol) do
      case Map.get(normalized, :pathname) do
        nil -> components
        value -> Map.put(components, :pathname, to_string(value))
      end
    else
      components
    end
  end

  defp preserve_opaque_map_pathname(components, _normalized, _explicit_pathname?), do: components

  defp normalize_string_input_pathname(pathname, raw_string, protocol)
       when is_binary(raw_string) and is_binary(protocol) do
    if opaque_scheme?(protocol) do
      [_scheme, opaque_path] = String.split(raw_string, ":", parts: 2)
      opaque_path
    else
      normalize_component_input(:pathname, pathname)
    end
  end

  defp normalize_string_input_pathname(pathname, _raw_string, _protocol) do
    normalize_component_input(:pathname, pathname)
  end

  defp opaque_scheme?(scheme), do: scheme in ["about", "data", "javascript"]

  defp opaque_protocol_pattern?(pattern) do
    literal = String.downcase(pattern)

    cond do
      literal in ["about", "data", "javascript"] ->
        true

      Regex.match?(~r/^\(([^)]+)\)$/, literal) ->
        [_, inner] = Regex.run(~r/^\(([^)]+)\)$/, literal)

        inner
        |> String.split("|")
        |> Enum.all?(&(&1 in ["about", "data", "javascript"]))

      true ->
        false
    end
  end

  defp maybe_ascii_hostname_pattern(pattern) do
    if String.contains?(pattern, ["*", ":", "(", ")", "{", "}", "?", "+", "\\", "[", "]"]) do
      String.downcase(pattern)
    else
      host_to_ascii(pattern)
    end
  end

  defp host_to_ascii(hostname) do
    hostname
    |> String.downcase()
    |> String.split(".", trim: false)
    |> Enum.map_join(".", &label_to_ascii/1)
  end

  defp label_to_ascii(""), do: ""

  defp label_to_ascii(label) do
    if String.match?(label, ~r/^[\x00-\x7F]+$/) do
      label
    else
      "xn--" <> punycode_encode(label)
    end
  end

  defp punycode_encode(label) do
    codepoints = String.to_charlist(label)
    basic = Enum.filter(codepoints, &(&1 < 0x80))
    basic_part = basic |> List.to_string() |> String.downcase()
    basic_count = length(basic)
    needs_delimiter = basic_count > 0 and basic_count < length(codepoints)

    encoded_tail =
      punycode_encode_loop(
        codepoints,
        128,
        0,
        72,
        basic_count,
        basic_count,
        length(codepoints),
        []
      )
      |> List.to_string()

    if needs_delimiter do
      basic_part <> "-" <> encoded_tail
    else
      encoded_tail
    end
  end

  defp punycode_encode_loop(_codepoints, _n, _delta, _bias, _basic_count, h, total, acc)
       when h >= total,
       do: acc

  defp punycode_encode_loop(codepoints, n, delta, bias, basic_count, h, total, acc) do
    m =
      codepoints
      |> Enum.filter(&(&1 >= n))
      |> Enum.min()

    delta = delta + (m - n) * (h + 1)

    {delta, bias, h, acc} =
      Enum.reduce(codepoints, {delta, bias, h, acc}, fn cp,
                                                        {delta_acc, bias_acc, h_acc, out_acc} ->
        cond do
          cp < m ->
            {delta_acc + 1, bias_acc, h_acc, out_acc}

          cp == m ->
            {encoded, next_bias} =
              punycode_encode_delta(delta_acc, bias_acc, h_acc + 1, h_acc == basic_count)

            {0, next_bias, h_acc + 1, out_acc ++ encoded}

          true ->
            {delta_acc, bias_acc, h_acc, out_acc}
        end
      end)

    punycode_encode_loop(codepoints, m + 1, delta + 1, bias, basic_count, h, total, acc)
  end

  defp punycode_encode_delta(delta, bias, points, first_time?) do
    punycode_encode_delta(delta, bias, points, first_time?, 36, [])
  end

  defp punycode_encode_delta(delta, bias, points, first_time?, k, acc) do
    threshold = punycode_threshold(k, bias)

    if delta < threshold do
      {acc ++ [encode_digit(delta)], adapt_bias(delta, points, first_time?)}
    else
      value = threshold + rem(delta - threshold, 36 - threshold)

      punycode_encode_delta(
        div(delta - threshold, 36 - threshold),
        bias,
        points,
        first_time?,
        k + 36,
        acc ++ [encode_digit(value)]
      )
    end
  end

  defp maybe_inherit_base_search(components, normalized, base_url_str) do
    pathname_explicit? = Map.has_key?(normalized, :pathname)
    search_explicit? = Map.has_key?(normalized, :search)

    if base_url_str != nil and not pathname_explicit? and not search_explicit? and
         Map.has_key?(normalized, :hash) do
      url = URL.new(base_url_str)
      search = url_search_raw(url)

      if search == "" do
        components
      else
        Map.put(components, :search, search)
      end
    else
      components
    end
  end

  defp maybe_inherit_pattern_base_components(_pattern_map, nil), do: %{}

  defp maybe_inherit_pattern_base_components(pattern_map, base_url) do
    base = extract_base_components(base_url)

    if not Map.has_key?(pattern_map, :pathname) and not Map.has_key?(pattern_map, :search) and
         Map.has_key?(pattern_map, :hash) do
      url = URL.new(base_url)
      Map.put(base, :search, url_search_raw(url))
    else
      base
    end
  end

  defp maybe_split_group_boundary(authority, path_part) when path_part != "" or authority == "" do
    {authority, path_part}
  end

  defp maybe_split_group_boundary(authority, "") do
    case Regex.run(~r/^(.*)\{([^{}]*)\/\}([^\/]*)$/, authority, capture: :all_but_first) do
      [prefix, group_inner, _suffix] -> {prefix <> "{" <> group_inner <> "}", "*"}
      _ -> {authority, ""}
    end
  end

  defp split_hostname_suffix(pattern, marker) do
    {head, _tail} = split_top_level_marker(pattern, marker)
    head
  end

  defp split_top_level_marker(input, marker) do
    split_top_level_marker(input, marker, "", 0, 0, false)
  end

  defp split_top_level_marker("", _marker, acc, _pd, _bd, _brackets), do: {acc, ""}

  defp split_top_level_marker(input, marker, acc, 0, 0, false)
       when byte_size(input) >= byte_size(marker) and
              binary_part(input, 0, byte_size(marker)) == marker do
    {acc, binary_part(input, byte_size(marker), byte_size(input) - byte_size(marker))}
  end

  defp split_top_level_marker(<<"\\", c::utf8, rest::binary>>, marker, acc, pd, bd, brackets) do
    split_top_level_marker(rest, marker, acc <> "\\" <> <<c::utf8>>, pd, bd, brackets)
  end

  defp split_top_level_marker(<<"(", rest::binary>>, marker, acc, pd, bd, brackets) do
    split_top_level_marker(rest, marker, acc <> "(", pd + 1, bd, brackets)
  end

  defp split_top_level_marker(<<")", rest::binary>>, marker, acc, pd, bd, brackets) when pd > 0 do
    split_top_level_marker(rest, marker, acc <> ")", pd - 1, bd, brackets)
  end

  defp split_top_level_marker(<<"{", rest::binary>>, marker, acc, pd, bd, brackets) do
    split_top_level_marker(rest, marker, acc <> "{", pd, bd + 1, brackets)
  end

  defp split_top_level_marker(<<"}", rest::binary>>, marker, acc, pd, bd, brackets) when bd > 0 do
    split_top_level_marker(rest, marker, acc <> "}", pd, bd - 1, brackets)
  end

  defp split_top_level_marker(<<"[", rest::binary>>, marker, acc, 0, 0, false) do
    split_top_level_marker(rest, marker, acc <> "[", 0, 0, true)
  end

  defp split_top_level_marker(<<"]", rest::binary>>, marker, acc, 0, 0, true) do
    split_top_level_marker(rest, marker, acc <> "]", 0, 0, false)
  end

  defp split_top_level_marker(<<c::utf8, rest::binary>>, marker, acc, pd, bd, brackets) do
    split_top_level_marker(rest, marker, acc <> <<c::utf8>>, pd, bd, brackets)
  end

  defp punycode_threshold(k, bias), do: min(max(k - bias, 1), 26)

  defp adapt_bias(delta, points, first_time?) do
    delta = if first_time?, do: div(delta, 700), else: div(delta, 2)
    delta = delta + div(delta, points)
    adapt_bias_loop(delta, 0)
  end

  defp adapt_bias_loop(delta, k) do
    {delta, k} =
      Enum.reduce_while(Stream.cycle([:step]), {delta, k}, fn _, {delta_acc, k_acc} ->
        if delta_acc > div(35 * 26, 2) do
          {:cont, {div(delta_acc, 35), k_acc + 36}}
        else
          {:halt, {delta_acc, k_acc}}
        end
      end)

    k + div(36 * delta, delta + 38)
  end

  defp encode_digit(value) when value < 26, do: ?a + value
  defp encode_digit(value), do: ?0 + value - 26

  # ---------------------------------------------------------------------------
  # Component matching
  # ---------------------------------------------------------------------------

  defp match_all_components(%__MODULE__{} = pattern, components, inputs) do
    # If any input component is the @invalid_component sentinel (e.g., protocol
    # with non-ASCII, port starting with non-digit), the whole URL is invalid.
    if Enum.any?(@components, fn c -> Map.get(components, c) == @invalid_component end) do
      nil
    else
      results =
        Enum.reduce(@components, %{inputs: inputs}, fn component, acc ->
          accumulate_component_match(acc, component, components, pattern)
        end)

      filter_result(results, components)
    end
  end

  defp accumulate_component_match(nil, _component, _components, _pattern), do: nil

  defp accumulate_component_match(acc, component, components, pattern) do
    input_val = Map.get(components, component, "")
    {_canonical, compiled_component} = Map.get(pattern.compiled, component)

    case match_component(compiled_component, input_val) do
      nil -> nil
      {matched_input, groups} -> Map.put(acc, component, %{input: matched_input, groups: groups})
    end
  end

  defp match_component(%{regex: regex, captures: captures}, input_val) do
    case Regex.run(regex, input_val, capture: :all) do
      nil ->
        nil

      [_ | groups] ->
        group_map =
          captures
          |> Enum.with_index()
          |> Enum.reduce(%{}, fn {{_idx, name}, i}, acc ->
            raw = Enum.at(groups, i)
            Map.put(acc, name, raw)
          end)

        {input_val, group_map}
    end
  end

  # Filter out wildcard-matched components from the result unless the caller
  # explicitly asked for them. Per spec, we only include components that have
  # non-wildcard patterns.
  defp filter_result(nil, _components), do: nil

  defp filter_result(%{inputs: _} = result, _components) do
    # Remove components with empty groups that came from pure wildcard patterns
    # only if they weren't actually set in the result.
    result
  end

  defp extract_all_groups(result) do
    Enum.reduce(@components, %{}, fn comp, acc ->
      case Map.get(result, comp) do
        %{groups: groups} when map_size(groups) > 0 ->
          merge_named_groups(acc, groups)

        _ ->
          acc
      end
    end)
  end

  defp merge_named_groups(acc, groups) do
    case Enum.reject(groups, fn {key, _value} -> Regex.match?(~r/^\d+$/, key) end) do
      [] -> acc
      named -> Map.merge(acc, Map.new(named))
    end
  end
end
