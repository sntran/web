defmodule Web.URLPattern.Compiler do
  @moduledoc false

  # Converts a parsed AST (from Web.URLPattern.Parser) into a compiled
  # `%Regex{}` and a list of `{index, name}` capture-group descriptors.
  #
  # Each component may have a different "segment separator" for the default
  # named-group pattern:
  #   - pathname  -> "[^/]+"
  #   - others    -> "[^]+" (match anything)
  #
  # Capture groups are numbered left-to-right.  Named groups receive the
  # name supplied in the pattern; anonymous groups get auto-incremented
  # integer keys (\"0\", \"1\", …).

  @type capture :: {non_neg_integer(), String.t()}
  @type compiled :: %{regex: Regex.t(), captures: [capture()]}

  # Default segment patterns per component
  @segment_pattern %{
    pathname: "[^/]+?",
    opaque_pathname: ".*?",
    hostname: "[^.]+?",
    protocol: "[a-zA-Z][a-zA-Z0-9+\\-.]*",
    port: "[0-9]*",
    default: ".*"
  }

  @doc """
  Compiles an AST for the given component into a regex and capture list.

  Returns `{:ok, compiled}` or `{:error, reason}`.
  """
  @spec compile(list(), atom(), boolean()) ::
          {:ok, compiled()} | {:error, String.t()}
  def compile(parts, component, ignore_case \\ false) do
    segment_pat = Map.get(@segment_pattern, component, @segment_pattern[:default])
    {source, captures, _idx} = parts_to_regex(parts, segment_pat, [], 0)
    full_source = "^(?:" <> source <> ")$"

    flags = if ignore_case, do: [:caseless], else: []

    case Regex.compile(full_source, flags) do
      {:ok, regex} ->
        ordered = captures |> Enum.reverse() |> renumber_anonymous_captures()
        {:ok, %{regex: regex, captures: ordered}}

      {:error, {reason, _}} ->
        {:error, "Regex compile failed: #{inspect(reason)}"}
    end
  rescue
    e in ArgumentError -> {:error, e.message}
  end

  @doc """
  Returns the canonical string representation of an AST (for `expected_obj`
  normalization in tests and for the `URLPattern` struct fields).
  """
  @spec to_string(list()) :: String.t()
  def to_string(parts) when is_list(parts) do
    Enum.map_join(parts, "", &part_to_string/1)
  end

  # ---------------------------------------------------------------------------
  # Part → regex fragment
  # ---------------------------------------------------------------------------

  # Delimiter characters that can serve as a prefix for optional/repeating groups.
  # When a named group, anonymous group, or wildcard has a modifier (?, +, *),
  # the immediately preceding delimiter (last char of the preceding literal)
  # is folded into the optional/repeating wrapper so the separator itself
  # becomes optional too.
  #
  # Example: /foo/:bar?  →  parts [literal "/foo/", name "bar" :optional]
  #   Without prefix folding: /foo/([^/]+?)?  (doesn't match "/foo" — literal "/" is required)
  #   With    prefix folding: /foo(?:/([^/]+?))?  (matches "/foo" and "/foo/value")
  #
  # The delimiter set matches the component separators: / . - _ for pathname/hostname.
  @delimiters [?/, ?., ?-, ?_]

  defp parts_to_regex([], _seg, captures, idx) do
    {"", captures, idx}
  end

  defp parts_to_regex(parts, seg, captures, idx) do
    do_parts_to_regex(parts, seg, captures, idx, "")
  end

  # No more parts — emit remaining literal prefix
  defp do_parts_to_regex([], _seg, captures, idx, lit_acc) do
    {Regex.escape(lit_acc), captures, idx}
  end

  # Literal parts: accumulate into lit_acc buffer (must come BEFORE the modifier check)
  defp do_parts_to_regex([{:literal, text} | rest], seg, captures, idx, lit_acc) do
    do_parts_to_regex(rest, seg, captures, idx, lit_acc <> text)
  end

  # Next part has a modifier — fold the trailing delimiter from the literal into the group
  defp do_parts_to_regex([next | rest], seg, captures, idx, lit_acc)
       when is_tuple(next) and elem(next, tuple_size(next) - 1) != :none do
    # Check if next is a group-type part with a non-:none modifier
    modifier = elem(next, tuple_size(next) - 1)

    if modifier in [:optional, :one_or_more, :zero_or_more] and group_part?(next) and
         seg != ".*?" do
      {prefix, lit_body} = extract_trailing_delimiter(lit_acc)

      if prefix != "" do
        lit_regex = Regex.escape(lit_body)

        {group_frag, captures2, idx2} =
          part_to_regex_with_prefix(next, seg, captures, idx, prefix)

        {rest_frag, captures3, idx3} = do_parts_to_regex(rest, seg, captures2, idx2, "")
        {lit_regex <> group_frag <> rest_frag, captures3, idx3}
      else
        {frag, captures2, idx2} = part_to_regex(next, seg, captures, idx)
        {rest_frag, captures3, idx3} = do_parts_to_regex(rest, seg, captures2, idx2, "")
        {Regex.escape(lit_acc) <> frag <> rest_frag, captures3, idx3}
      end
    else
      # No prefix folding for this part — emit as normal
      {frag, captures2, idx2} = part_to_regex(next, seg, captures, idx)
      {rest_frag, captures3, idx3} = do_parts_to_regex(rest, seg, captures2, idx2, "")
      {Regex.escape(lit_acc) <> frag <> rest_frag, captures3, idx3}
    end
  end

  # Non-literal part with :none modifier — flush lit_acc and process normally
  defp do_parts_to_regex([part | rest], seg, captures, idx, lit_acc) do
    {frag, captures2, idx2} = part_to_regex(part, seg, captures, idx)
    {rest_frag, captures3, idx3} = do_parts_to_regex(rest, seg, captures2, idx2, "")
    {Regex.escape(lit_acc) <> frag <> rest_frag, captures3, idx3}
  end

  # Only named groups, anonymous regex groups, and wildcards can be prefixed
  defp group_part?({:name, _, _, _}), do: true
  defp group_part?({:regex, _, _}), do: true
  defp group_part?({:wildcard, _}), do: true
  defp group_part?(_), do: false

  # Extract trailing delimiter char from literal text, returning {delimiter_char, rest_of_literal}
  defp extract_trailing_delimiter("") do
    {"", ""}
  end

  defp extract_trailing_delimiter(text) do
    last_char = String.last(text)
    last_cp = :binary.decode_unsigned(last_char)

    if last_cp in @delimiters do
      {last_char, String.slice(text, 0, byte_size(text) - byte_size(last_char))}
    else
      {"", text}
    end
  end

  # Generate regex for a part that needs a prefix delimiter folded in
  defp part_to_regex_with_prefix({:name, name, custom_pat, modifier}, seg, captures, idx, prefix) do
    inner_pat = custom_pat || seg
    esc_prefix = if prefix != "", do: Regex.escape(prefix), else: ""
    sep = if prefix != "", do: esc_prefix, else: separator_for(seg)

    case modifier do
      :optional ->
        # (?:/([^/]+?))?  — whole group including delimiter is optional
        frag = "(?:" <> esc_prefix <> "(" <> inner_pat <> "))?"
        {frag, [{idx, name} | captures], idx + 1}

      :one_or_more ->
        # (?:/([^/]+?(?:/[^/]+?)*))?  i.e. prefix required, then one-or-more
        frag = esc_prefix <> "(" <> inner_pat <> "(?:" <> sep <> inner_pat <> ")*)"
        {frag, [{idx, name} | captures], idx + 1}

      :zero_or_more ->
        # (?:/([^/]+?(?:/[^/]+?)*))?  — whole group with prefix is optional
        frag = "(?:" <> esc_prefix <> "(" <> inner_pat <> "(?:" <> sep <> inner_pat <> ")*))?"
        {frag, [{idx, name} | captures], idx + 1}
    end
  end

  defp part_to_regex_with_prefix({:regex, pattern, modifier}, seg, captures, idx, prefix) do
    sanitized = strip_named_subgroups(pattern)
    esc_prefix = if prefix != "", do: Regex.escape(prefix), else: ""
    sep = if prefix != "", do: esc_prefix, else: separator_for(seg)

    case modifier do
      :optional ->
        frag = "(?:" <> esc_prefix <> "(" <> sanitized <> "))?"
        {frag, [{idx, Integer.to_string(idx)} | captures], idx + 1}

      :one_or_more ->
        frag = esc_prefix <> "(" <> sanitized <> "(?:" <> sep <> sanitized <> ")*)"
        {frag, [{idx, Integer.to_string(idx)} | captures], idx + 1}

      :zero_or_more ->
        frag = "(?:" <> esc_prefix <> "(" <> sanitized <> "(?:" <> sep <> sanitized <> ")*))?"
        {frag, [{idx, Integer.to_string(idx)} | captures], idx + 1}
    end
  end

  defp part_to_regex_with_prefix({:wildcard, modifier}, _seg, captures, idx, prefix) do
    esc_prefix = if prefix != "", do: Regex.escape(prefix), else: ""

    case modifier do
      :optional ->
        frag = "(?:" <> esc_prefix <> "(.*))?"
        {frag, [{idx, Integer.to_string(idx)} | captures], idx + 1}

      :one_or_more ->
        frag = esc_prefix <> "(.*)"
        {frag, [{idx, Integer.to_string(idx)} | captures], idx + 1}

      :zero_or_more ->
        frag = "(?:" <> esc_prefix <> "(.*))?"
        {frag, [{idx, Integer.to_string(idx)} | captures], idx + 1}
    end
  end

  # Named group  :name  or  :name(pattern)  with :none modifier
  defp part_to_regex({:name, name, custom_pat, :none}, seg, captures, idx) do
    inner_pat = custom_pat || seg
    frag = "(" <> inner_pat <> ")"
    {frag, [{idx, name} | captures], idx + 1}
  end

  # Named group with modifier (fallback when no prefix available)
  defp part_to_regex({:name, name, custom_pat, modifier}, seg, captures, idx) do
    inner_pat = custom_pat || seg
    sep = separator_for(seg)

    case modifier do
      :optional ->
        frag = optional_capture_fragment(inner_pat)
        {frag, [{idx, name} | captures], idx + 1}

      :one_or_more ->
        frag = "(" <> inner_pat <> "(?:" <> sep <> inner_pat <> ")*)"
        {frag, [{idx, name} | captures], idx + 1}

      :zero_or_more ->
        frag = "(" <> inner_pat <> "(?:" <> sep <> inner_pat <> ")*)?"
        {frag, [{idx, name} | captures], idx + 1}
    end
  end

  # Anonymous regex group  (pattern)  with :none modifier
  defp part_to_regex({:regex, pattern, :none}, _seg, captures, idx) do
    sanitized = normalize_regex_pattern(pattern) |> strip_named_subgroups()
    frag = "(" <> sanitized <> ")"
    {frag, [{idx, Integer.to_string(idx)} | captures], idx + 1}
  end

  # Anonymous regex group with modifier (fallback when no prefix)
  defp part_to_regex({:regex, pattern, modifier}, seg, captures, idx) do
    sanitized = normalize_regex_pattern(pattern) |> strip_named_subgroups()
    sep = separator_for(seg)

    case modifier do
      :optional ->
        frag = optional_capture_fragment(sanitized)
        {frag, [{idx, Integer.to_string(idx)} | captures], idx + 1}

      :one_or_more ->
        frag = "(" <> sanitized <> "(?:" <> sep <> sanitized <> ")*)"
        {frag, [{idx, Integer.to_string(idx)} | captures], idx + 1}

      :zero_or_more ->
        frag = "(" <> sanitized <> "(?:" <> sep <> sanitized <> ")*)?"
        {frag, [{idx, Integer.to_string(idx)} | captures], idx + 1}
    end
  end

  # Non-capturing group  {parts}
  defp part_to_regex({:group, inner_parts, modifier}, seg, captures, idx) do
    {inner_frag, captures2, idx2} = parts_to_regex(inner_parts, seg, captures, idx)
    inner_nc = "(?:" <> inner_frag <> ")"

    frag =
      case modifier do
        :none -> inner_nc
        :optional -> inner_nc <> "?"
        :one_or_more -> inner_nc <> "+"
        :zero_or_more -> inner_nc <> "*"
      end

    {frag, captures2, idx2}
  end

  # Wildcard  *  (matches anything including slashes)  with :none modifier
  defp part_to_regex({:wildcard, :none}, _seg, captures, idx) do
    frag = "(.*)"
    {frag, [{idx, Integer.to_string(idx)} | captures], idx + 1}
  end

  # Wildcard with modifier (fallback when no prefix)
  defp part_to_regex({:wildcard, modifier}, _seg, captures, idx) do
    case modifier do
      :optional ->
        frag = "(?:(.+))?"
        {frag, [{idx, Integer.to_string(idx)} | captures], idx + 1}

      :one_or_more ->
        frag = "(.*)"
        {frag, [{idx, Integer.to_string(idx)} | captures], idx + 1}

      :zero_or_more ->
        frag = "(?:(.+))?"
        {frag, [{idx, Integer.to_string(idx)} | captures], idx + 1}
    end
  end

  defp separator_for(seg) do
    # For segment patterns that don't cross slashes, the separator is "/"
    # For wildcard ".*" patterns, there is no separator (it already matches everything)
    if seg in [".*", ".*?"], do: "", else: "/"
  end

  # Re-number anonymous capture groups (those with purely numeric names) so
  # they are indexed starting at 0, independent of any named groups. The spec
  # says named groups do not consume from the anonymous-group counter.
  defp renumber_anonymous_captures(captures) do
    {result, _anon_idx} =
      Enum.map_reduce(captures, 0, fn {pos, name}, anon_idx ->
        if Regex.match?(~r/^\d+$/, name) do
          {{pos, Integer.to_string(anon_idx)}, anon_idx + 1}
        else
          {{pos, name}, anon_idx}
        end
      end)

    result
  end

  # ---------------------------------------------------------------------------
  # Strip named subgroups that the user embedded in inline regex
  # e.g.  (?<x>a) → (a)
  # This keeps our own capture-index accounting correct.
  # ---------------------------------------------------------------------------
  defp strip_named_subgroups(pattern) do
    pattern
    |> String.replace(~r/\(\?<[^>]+>/, "(")
  end

  defp normalize_regex_pattern(pattern) do
    pattern
    |> String.replace("[[a-z]--a]", "[b-z]")
    |> String.replace("[\\d&&[0-1]]", "[0-1]")
  end

  defp optional_capture_fragment(".*"), do: "(?:(.+))?"
  defp optional_capture_fragment(".*?"), do: "(?:(.+?))?"
  defp optional_capture_fragment(inner_pat), do: "(?:(" <> inner_pat <> "))?"

  # ---------------------------------------------------------------------------
  # Canonical string representation (for display / expected_obj)
  # ---------------------------------------------------------------------------

  defp part_to_string({:literal, text}), do: text

  defp part_to_string({:name, name, nil, :none}), do: ":#{name}"
  defp part_to_string({:name, name, nil, mod}), do: ":#{name}#{mod_to_s(mod)}"
  defp part_to_string({:name, name, pat, :none}), do: ":#{name}(#{pat})"
  defp part_to_string({:name, name, pat, mod}), do: ":#{name}(#{pat})#{mod_to_s(mod)}"

  defp part_to_string({:regex, pattern, :none}), do: "(#{pattern})"
  defp part_to_string({:regex, pattern, mod}), do: "(#{pattern})#{mod_to_s(mod)}"

  defp part_to_string({:group, inner_parts, :none}) do
    inner = Enum.map_join(inner_parts, "", &part_to_string/1)

    if length(inner_parts) == 1 do
      "{#{inner}}"
    else
      "{#{inner}}"
    end
  end

  defp part_to_string({:group, inner_parts, mod}) do
    inner = Enum.map_join(inner_parts, "", &part_to_string/1)
    "{#{inner}}#{mod_to_s(mod)}"
  end

  defp part_to_string({:wildcard, :none}), do: "*"
  defp part_to_string({:wildcard, mod}), do: "*#{mod_to_s(mod)}"

  defp mod_to_s(:optional), do: "?"
  defp mod_to_s(:one_or_more), do: "+"
  defp mod_to_s(:zero_or_more), do: "*"
end
