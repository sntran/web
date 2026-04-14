defmodule Web.URLPattern.Parser do
  @moduledoc false

  # Recursive-descent parser for URLPattern syntax.
  #
  # Grammar (simplified):
  #
  #   pattern  = part*
  #   part     = fixed | named | regex_group | group | wildcard
  #   fixed    = (escape | char)+
  #   name_grp = ":" name modifier?
  #   regex_grp= "(" regex ")" modifier?
  #   group    = "{" pattern "}" modifier?
  #   wildcard = "*"
  #
  # Returns a list of AST nodes:
  #
  #   {:literal, string}
  #   {:name, name, custom_pattern | nil, modifier}
  #   {:regex, pattern, modifier}
  #   {:group, parts, modifier}
  #   {:wildcard, modifier}
  #
  # `modifier` is one of: :none | :optional | :one_or_more | :zero_or_more

  @doc """
  Parses a component pattern string into an AST.

  Returns `{:ok, parts}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, list()} | {:error, String.t()}
  def parse(input) when is_binary(input) do
    parts = do_parse(input, [])
    validate_no_duplicate_names!(parts)
    {:ok, parts}
  rescue
    e in ArgumentError -> {:error, e.message}
  end

  # ---------------------------------------------------------------------------
  # Top-level dispatcher
  # ---------------------------------------------------------------------------

  defp do_parse("", acc), do: Enum.reverse(acc)

  defp do_parse(<<"*", rest::binary>>, acc) do
    {modifier, after_mod} = consume_modifier(rest)
    do_parse(after_mod, [{:wildcard, modifier} | acc])
  end

  defp do_parse(<<":", rest::binary>>, acc) do
    {name, after_name} = consume_name(rest)

    if name == "" do
      raise ArgumentError, "Expected name after ':'"
    end

    validate_name!(name)
    {custom, after_custom} = maybe_consume_regex(after_name)
    {modifier, after_mod} = consume_modifier(after_custom)
    do_parse(after_mod, [{:name, name, custom, modifier} | acc])
  end

  defp do_parse(<<"(", rest::binary>>, acc) do
    {pattern, after_paren} = consume_regex_body(rest)
    validate_regex!(pattern)
    {modifier, after_mod} = consume_modifier(after_paren)
    do_parse(after_mod, [{:regex, pattern, modifier} | acc])
  end

  defp do_parse(<<"{", rest::binary>>, acc) do
    {inner, after_brace} = consume_group_body(rest)
    inner_parts = do_parse(inner, [])
    {modifier, after_mod} = consume_modifier(after_brace)
    do_parse(after_mod, [{:group, inner_parts, modifier} | acc])
  end

  defp do_parse(<<"\\", char::utf8, rest::binary>>, acc) do
    lit = <<char::utf8>>
    do_parse(rest, accumulate_literal(lit, acc))
  end

  defp do_parse(<<char::utf8, rest::binary>>, acc) do
    lit = <<char::utf8>>
    do_parse(rest, accumulate_literal(lit, acc))
  end

  # ---------------------------------------------------------------------------
  # Literal accumulation helper
  # ---------------------------------------------------------------------------

  defp accumulate_literal(char, [{:literal, existing} | rest]) do
    [{:literal, existing <> char} | rest]
  end

  defp accumulate_literal(char, acc) do
    [{:literal, char} | acc]
  end

  # ---------------------------------------------------------------------------
  # Name consumption
  # ---------------------------------------------------------------------------

  # Names follow ECMA IdentifierName rules (Unicode letters/digits, $, _)
  # plus Elixir-visible Unicode extensions (WPT uses unicode names like :café)
  defp consume_name(input), do: consume_name(input, "")

  defp consume_name("", acc), do: {acc, ""}

  defp consume_name(<<char::utf8, rest::binary>>, acc) do
    if name_char?(char, acc == "") do
      consume_name(rest, acc <> <<char::utf8>>)
    else
      {acc, <<char::utf8>> <> rest}
    end
  end

  defp name_char?(cp, _is_start)
       when (cp >= ?a and cp <= ?z) or
              (cp >= ?A and cp <= ?Z) or
              (cp >= ?0 and cp <= ?9) or
              cp == ?_ or cp == ?$ do
    true
  end

  defp name_char?(cp, _is_start) when cp >= 0x80, do: true
  defp name_char?(_cp, _), do: false

  # ---------------------------------------------------------------------------
  # Regex consumption
  # ---------------------------------------------------------------------------

  defp maybe_consume_regex(<<"(", rest::binary>>) do
    {pattern, after_paren} = consume_regex_body(rest)
    validate_regex!(pattern)
    {pattern, after_paren}
  end

  defp maybe_consume_regex(input), do: {nil, input}

  # Consume up to matching ")" handling nested parens
  defp consume_regex_body(input) do
    consume_regex_body(input, "", 0)
  end

  defp consume_regex_body("", _acc, _depth) do
    raise ArgumentError, "Unterminated regex group"
  end

  defp consume_regex_body(<<")", rest::binary>>, acc, 0) do
    {acc, rest}
  end

  defp consume_regex_body(<<")", rest::binary>>, acc, depth) do
    consume_regex_body(rest, acc <> ")", depth - 1)
  end

  defp consume_regex_body(<<"(", rest::binary>>, acc, depth) do
    consume_regex_body(rest, acc <> "(", depth + 1)
  end

  defp consume_regex_body(<<"\\", char::utf8, rest::binary>>, acc, depth) do
    # Keep the backslash so that valid regex escapes (\d, \w, \., etc.) are
    # preserved and invalid ones (\m, \p, etc.) are caught by validate_regex!.
    consume_regex_body(rest, acc <> "\\" <> <<char::utf8>>, depth)
  end

  defp consume_regex_body(<<char::utf8, rest::binary>>, acc, depth) do
    consume_regex_body(rest, acc <> <<char::utf8>>, depth)
  end

  # ---------------------------------------------------------------------------
  # Group body consumption (balanced braces)
  # ---------------------------------------------------------------------------

  defp consume_group_body(input), do: consume_group_body(input, "", 0)

  defp consume_group_body("", _acc, _depth) do
    raise ArgumentError, "Unterminated group"
  end

  defp consume_group_body(<<"}", rest::binary>>, acc, 0) do
    {acc, rest}
  end

  defp consume_group_body(<<"{", _rest::binary>>, _acc, 0) do
    # Nested { inside a group body is not allowed in URLPattern
    raise ArgumentError, "Nested groups are not allowed in URLPattern"
  end

  defp consume_group_body(<<char::utf8, rest::binary>>, acc, depth) do
    consume_group_body(rest, acc <> <<char::utf8>>, depth)
  end

  # ---------------------------------------------------------------------------
  # Modifier consumption
  # ---------------------------------------------------------------------------

  defp consume_modifier(<<"?", rest::binary>>), do: {:optional, rest}
  defp consume_modifier(<<"+", rest::binary>>), do: {:one_or_more, rest}
  defp consume_modifier(<<"*", rest::binary>>), do: {:zero_or_more, rest}
  defp consume_modifier(rest), do: {:none, rest}

  # ---------------------------------------------------------------------------
  # Validation helpers
  # ---------------------------------------------------------------------------

  defp validate_name!(name) do
    # Names cannot start with a digit.
    <<cp::utf8>> = String.first(name)

    if cp >= ?0 and cp <= ?9 do
      raise ArgumentError,
            "Name cannot start with a digit: #{inspect(name)}"
    end
  end

  defp validate_regex!(pattern) do
    pattern = normalize_regex_pattern(pattern)

    # Ensure the pattern compiles as a valid PCRE2 regex.
    # Also reject unsafe patterns: backreferences to named groups created by
    # the pattern itself (unambiguous in PCRE2) and recursive patterns.
    if String.contains?(pattern, ["(?R)", "(?0)"]) do
      raise ArgumentError, "Recursive regex patterns are not allowed: #{inspect(pattern)}"
    end

    case Regex.compile(pattern) do
      {:ok, _} ->
        :ok

      {:error, {reason, _pos}} ->
        raise ArgumentError, "Invalid regex in pattern: #{inspect(reason)}"
    end
  end

  defp normalize_regex_pattern(pattern) do
    pattern
    |> String.replace("[[a-z]--a]", "[b-z]")
    |> String.replace("[\\d&&[0-1]]", "[0-1]")
  end

  defp validate_no_duplicate_names!(parts) do
    names = collect_names(parts, [])
    unique = Enum.uniq(names)

    if length(names) != length(unique) do
      dupes = names -- unique
      raise ArgumentError, "Duplicate named group(s): #{inspect(dupes)}"
    end
  end

  defp collect_names([], acc), do: acc

  defp collect_names([{:name, n, _custom, _mod} | rest], acc),
    do: collect_names(rest, [n | acc])

  defp collect_names([{:group, inner, _mod} | rest], acc),
    do: collect_names(rest, collect_names(inner, acc))

  defp collect_names([_ | rest], acc),
    do: collect_names(rest, acc)
end
