defmodule Web.URLPattern.RegExp do
  @moduledoc false

  # The URL Pattern Standard compiles each regular expression with
  # "RegExpCreate(regular expression string, flags)", and the flags are "v"
  # or "vi". This module reads the source text with the syntax of
  # ECMAScript for the flag `v`, refuses the source text that ECMAScript
  # refuses, and writes the same expression in the syntax of PCRE2 for
  # `:re`.
  #
  # The two syntaxes are different, for example:
  #
  #   * `.` does not match a line terminator in ECMAScript. `\s` matches
  #     the white space and the line terminators of Unicode.
  #   * `\uFFFF`, `\u{1F600}`, and `\v` are escapes of ECMAScript. PCRE2
  #     writes `\x{FFFF}` and `\x{0B}`.
  #   * An escape such as `\H` or `\A`, a lone `{` or `}`, and a group such
  #     as `(?R)` are not valid in ECMAScript.
  #   * A class can contain classes, and can use the operators `&&`
  #     (intersection) and `--` (subtraction). This module writes these
  #     classes with lookaheads, for example `[[a-z]--[aeiou]]` becomes
  #     `(?:(?![aeiou])[a-z])`.
  #
  # Each error raises `Web.TypeError`: the Standard catches the exception of
  # RegExpCreate and throws a `TypeError`.

  import Bitwise

  @line_terminators [{?\n, ?\n}, {?\r, ?\r}, {0x2028, 0x2029}]

  # WhiteSpace and LineTerminator of ECMAScript, for `\s`.
  @white_space [
    {0x09, 0x0D},
    {0x20, 0x20},
    {0xA0, 0xA0},
    {0x1680, 0x1680},
    {0x2000, 0x200A},
    {0x2028, 0x2029},
    {0x202F, 0x202F},
    {0x205F, 0x205F},
    {0x3000, 0x3000},
    {0xFEFF, 0xFEFF}
  ]

  @syntax_characters ~c"^$\\.*+?()[]{}|"
  @class_syntax_characters ~c"()[]{}/-\\|"
  @class_reserved_punctuators ~c"&-!#%,:;<=>@`~"
  @class_double_punctuators ~c"&!#$%*+,.:;<=>?@^`~"

  @general_categories %{
    "Cased_Letter" => "LC",
    "Close_Punctuation" => "Pe",
    "Connector_Punctuation" => "Pc",
    "Control" => "Cc",
    "Currency_Symbol" => "Sc",
    "Dash_Punctuation" => "Pd",
    "Decimal_Number" => "Nd",
    "Enclosing_Mark" => "Me",
    "Final_Punctuation" => "Pf",
    "Format" => "Cf",
    "Initial_Punctuation" => "Pi",
    "Letter" => "L",
    "Letter_Number" => "Nl",
    "Line_Separator" => "Zl",
    "Lowercase_Letter" => "Ll",
    "Mark" => "M",
    "Math_Symbol" => "Sm",
    "Modifier_Letter" => "Lm",
    "Modifier_Symbol" => "Sk",
    "Nonspacing_Mark" => "Mn",
    "Number" => "N",
    "Open_Punctuation" => "Ps",
    "Other" => "C",
    "Other_Letter" => "Lo",
    "Other_Number" => "No",
    "Other_Punctuation" => "Po",
    "Other_Symbol" => "So",
    "Paragraph_Separator" => "Zp",
    "Private_Use" => "Co",
    "Punctuation" => "P",
    "Separator" => "Z",
    "Space_Separator" => "Zs",
    "Spacing_Mark" => "Mc",
    "Surrogate" => "Cs",
    "Symbol" => "S",
    "Titlecase_Letter" => "Lt",
    "Unassigned" => "Cn",
    "Uppercase_Letter" => "Lu",
    "digit" => "Nd",
    "punct" => "P",
    "Combining_Mark" => "M"
  }

  @doc false
  # Compiles the source text of an ECMAScript regular expression with the
  # flag `v`, and the flag `i` when `ignore_case` is true.
  @spec compile!(String.t(), boolean()) :: term()
  def compile!(source, ignore_case) do
    options = [:unicode, :dollar_endonly] ++ if(ignore_case, do: [:caseless], else: [])

    case :re.compile(translate!(source), options) do
      {:ok, regex} -> regex
      {:error, _reason} -> invalid()
    end
  end

  @doc false
  # Returns the PCRE2 source text of an ECMAScript regular expression.
  @spec translate!(String.t()) :: String.t()
  def translate!(source) when is_binary(source) do
    state = %{groups: 0, names: [], backreferences: [], named_references: [], dot_all: false}
    {output, _rest, state} = disjunction(source, [], state, 0)

    if Enum.any?(state.backreferences, &(&1 > state.groups)) or
         Enum.any?(state.named_references, &(&1 not in state.names)),
       do: invalid()

    IO.iodata_to_binary(output)
  end

  defp invalid, do: raise(Web.TypeError, "The regular expression is not valid.")

  # ---------------------------------------------------------------------------
  # Disjunctions and terms
  # ---------------------------------------------------------------------------

  # Reads terms until the end of the source, or until the ")" of the group
  # at the depth. Returns the rest after the ")".
  defp disjunction(<<>>, acc, state, 0), do: {acc, <<>>, state}
  defp disjunction(<<>>, _acc, _state, _depth), do: invalid()
  defp disjunction(<<?), rest::binary>>, acc, state, depth) when depth > 0, do: {acc, rest, state}
  defp disjunction(<<?), _rest::binary>>, _acc, _state, 0), do: invalid()

  defp disjunction(<<?|, rest::binary>>, acc, state, depth),
    do: disjunction(rest, [acc, ?|], state, depth)

  defp disjunction(source, acc, state, depth) do
    {kind, term, rest, state} = term(source, state)
    {quantifier, rest} = quantifier(rest)

    if quantifier != "" and kind != :atom, do: invalid()

    disjunction(rest, [acc, term, quantifier], state, depth)
  end

  defp term(<<?^, rest::binary>>, state), do: {:assertion, "^", rest, state}
  defp term(<<?$, rest::binary>>, state), do: {:assertion, "$", rest, state}
  defp term(<<?\\, ?b, rest::binary>>, state), do: {:assertion, "\\b", rest, state}
  defp term(<<?\\, ?B, rest::binary>>, state), do: {:assertion, "\\B", rest, state}
  defp term(<<"(?=", rest::binary>>, state), do: group("(?=", rest, state, :assertion)
  defp term(<<"(?!", rest::binary>>, state), do: group("(?!", rest, state, :assertion)
  defp term(<<"(?<=", rest::binary>>, state), do: group("(?<=", rest, state, :assertion)
  defp term(<<"(?<!", rest::binary>>, state), do: group("(?<!", rest, state, :assertion)
  defp term(<<"(?:", rest::binary>>, state), do: group("(?:", rest, state, :atom)

  defp term(<<"(?<", rest::binary>>, state) do
    case :binary.split(rest, ">") do
      [name, rest] ->
        if not group_name?(name) or name in state.names, do: invalid()

        state = %{state | groups: state.groups + 1, names: [name | state.names]}
        group(["(?<", name, ">"], rest, state, :atom)

      [_no_end] ->
        invalid()
    end
  end

  defp term(<<"(?", rest::binary>>, state), do: modifiers_group(rest, state)

  defp term(<<?(, rest::binary>>, state),
    do: group("(", rest, %{state | groups: state.groups + 1}, :atom)

  defp term(<<?., rest::binary>>, state) do
    dot = if state.dot_all, do: "[\\s\\S]", else: negated_set(@line_terminators)
    {:atom, dot, rest, state}
  end

  defp term(<<?[, rest::binary>>, state) do
    {class, rest} = class(rest)
    {:atom, emit_class(class), rest, state}
  end

  defp term(<<?\\, rest::binary>>, state), do: atom_escape(rest, state)
  defp term(<<char, _rest::binary>>, _state) when char in @syntax_characters, do: invalid()

  defp term(<<code_point::utf8, rest::binary>>, state),
    do: {:atom, literal(code_point), rest, state}

  defp group(open, rest, state, kind) do
    {body, rest, inner} = disjunction(rest, [], state, 1)
    {kind, [open, body, ?)], rest, %{inner | dot_all: state.dot_all}}
  end

  # "(?ims-ims:" of the modifiers of ECMAScript 2025.
  defp modifiers_group(rest, state) do
    with [flags, body] <- :binary.split(rest, ":"),
         {add, remove} <- split_flags(flags),
         true <- valid_flags?(add, remove) do
      dot_all =
        cond do
          ?s in remove -> false
          ?s in add -> true
          true -> state.dot_all
        end

      {kind, output, rest, inner} =
        group(["(?", flags, ":"], body, %{state | dot_all: dot_all}, :atom)

      {kind, output, rest, %{inner | dot_all: state.dot_all}}
    else
      _other -> invalid()
    end
  end

  defp split_flags(flags) do
    case :binary.split(flags, "-") do
      [add] -> {String.to_charlist(add), []}
      [add, remove] when remove != "" -> {String.to_charlist(add), String.to_charlist(remove)}
      _other -> :error
    end
  end

  defp valid_flags?(add, remove) do
    all = add ++ remove

    all != [] and Enum.all?(all, &(&1 in ~c"ims")) and Enum.uniq(all) == all
  end

  # A group name of ASCII characters: the tokenizer of the Standard gives
  # only ASCII characters in a regular expression.
  defp group_name?(name), do: Regex.match?(~r/\A[A-Za-z_$][A-Za-z0-9_$]*\z/, name)

  # ---------------------------------------------------------------------------
  # Quantifiers
  # ---------------------------------------------------------------------------

  defp quantifier(<<char, rest::binary>>) when char in ~c"*+?", do: lazy(<<char>>, rest)

  defp quantifier(<<?{, rest::binary>>) do
    case Regex.run(~r/\A(\d+)(?:(,)(\d*))?\}/, rest) do
      [whole, min | more] ->
        max =
          case more do
            [",", ""] -> nil
            [",", max] -> max
            [] -> min
          end

        if max != nil and String.to_integer(max) < String.to_integer(min), do: invalid()

        lazy(
          <<?{, whole::binary>>,
          binary_part(rest, byte_size(whole), byte_size(rest) - byte_size(whole))
        )

      nil ->
        invalid()
    end
  end

  defp quantifier(rest), do: {"", rest}

  defp lazy(quantifier, <<??, rest::binary>>), do: {quantifier <> "?", rest}
  defp lazy(quantifier, rest), do: {quantifier, rest}

  # ---------------------------------------------------------------------------
  # Escapes
  # ---------------------------------------------------------------------------

  defp atom_escape(<<char, rest::binary>>, state) when char in ~c"dDwW",
    do: {:atom, <<?\\, char>>, rest, state}

  defp atom_escape(<<?s, rest::binary>>, state), do: {:atom, set(@white_space), rest, state}

  defp atom_escape(<<?S, rest::binary>>, state),
    do: {:atom, negated_set(@white_space), rest, state}

  defp atom_escape(<<char, ?{, rest::binary>>, state) when char in ~c"pP" do
    {escape, rest} = property(char, rest)
    {:atom, escape, rest, state}
  end

  defp atom_escape(<<?k, ?<, rest::binary>>, state) do
    case :binary.split(rest, ">") do
      [name, rest] ->
        if not group_name?(name), do: invalid()

        {:atom, ["\\k<", name, ">"], rest,
         %{state | named_references: [name | state.named_references]}}

      [_no_end] ->
        invalid()
    end
  end

  defp atom_escape(<<digit, _rest::binary>> = source, state) when digit in ?1..?9 do
    [digits] = Regex.run(~r/\A\d+/, source)
    rest = binary_part(source, byte_size(digits), byte_size(source) - byte_size(digits))
    number = String.to_integer(digits)

    {:atom, ["\\g{", digits, "}"], rest,
     %{state | backreferences: [number | state.backreferences]}}
  end

  defp atom_escape(source, state) do
    case character_escape(source, false) do
      {:surrogate, rest} -> {:atom, "(?!)", rest, state}
      {code_point, rest} -> {:atom, literal(code_point), rest, state}
    end
  end

  # "CharacterEscape" with the flag `u`: returns `{code_point, rest}`, or
  # `{:surrogate, rest}` for a lone surrogate, which no text of Elixir can
  # have.
  defp character_escape(<<?f, rest::binary>>, _class?), do: {?\f, rest}
  defp character_escape(<<?n, rest::binary>>, _class?), do: {?\n, rest}
  defp character_escape(<<?r, rest::binary>>, _class?), do: {?\r, rest}
  defp character_escape(<<?t, rest::binary>>, _class?), do: {?\t, rest}
  defp character_escape(<<?v, rest::binary>>, _class?), do: {?\v, rest}

  defp character_escape(<<?c, letter, rest::binary>>, _class?)
       when letter in ?a..?z or letter in ?A..?Z,
       do: {rem(letter, 32), rest}

  defp character_escape(<<?0, digit, _rest::binary>>, _class?) when digit in ?0..?9, do: invalid()
  defp character_escape(<<?0, rest::binary>>, _class?), do: {0, rest}

  defp character_escape(<<?x, high, low, rest::binary>>, _class?) do
    if hex?(high) and hex?(low), do: {String.to_integer(<<high, low>>, 16), rest}, else: invalid()
  end

  defp character_escape(<<?u, ?{, rest::binary>>, _class?) do
    case :binary.split(rest, "}") do
      [hex, rest] when hex != "" ->
        if not Enum.all?(String.to_charlist(hex), &hex?/1), do: invalid()
        code_point = String.to_integer(hex, 16)
        if code_point > 0x10FFFF, do: invalid()
        surrogate_or(code_point, rest)

      _other ->
        invalid()
    end
  end

  defp character_escape(<<?u, a, b, c, d, rest::binary>>, _class?) do
    if not Enum.all?([a, b, c, d], &hex?/1), do: invalid()
    lead = String.to_integer(<<a, b, c, d>>, 16)

    with true <- lead in 0xD800..0xDBFF,
         <<?\\, ?u, e, f, g, h, after_trail::binary>> <- rest,
         true <- Enum.all?([e, f, g, h], &hex?/1),
         trail when trail in 0xDC00..0xDFFF <- String.to_integer(<<e, f, g, h>>, 16) do
      {0x10000 + ((lead - 0xD800) <<< 10) + (trail - 0xDC00), after_trail}
    else
      _no_pair -> surrogate_or(lead, rest)
    end
  end

  defp character_escape(<<char, rest::binary>>, _class?)
       when char in @syntax_characters or char == ?/,
       do: {char, rest}

  defp character_escape(<<char, rest::binary>>, true) when char in @class_reserved_punctuators,
    do: {char, rest}

  defp character_escape(<<?b, rest::binary>>, true), do: {?\b, rest}
  defp character_escape(_source, _class?), do: invalid()

  defp surrogate_or(code_point, rest) when code_point in 0xD800..0xDFFF, do: {:surrogate, rest}
  defp surrogate_or(code_point, rest), do: {code_point, rest}

  # `\p{...}` and `\P{...}`. ECMAScript writes the general categories with
  # long names, and with "General_Category=" or "gc=" before them.
  defp property(char, rest) do
    case :binary.split(rest, "}") do
      [name, rest] when name != "" ->
        if not Regex.match?(~r/\A[A-Za-z0-9_]+(=[A-Za-z0-9_]+)?\z/, name), do: invalid()
        {[?\\, char, ?{, property_name(name), ?}], rest}

      _other ->
        invalid()
    end
  end

  defp property_name(name) do
    case String.split(name, "=") do
      [category] ->
        Map.get(@general_categories, category, category)

      [key, value] when key in ["General_Category", "gc"] ->
        Map.get(@general_categories, value, value)

      [key, value] when key in ["Script", "sc"] ->
        "sc=" <> value

      [key, value] when key in ["Script_Extensions", "scx"] ->
        "scx=" <> value

      _other ->
        invalid()
    end
  end

  defp hex?(char), do: char in ?0..?9 or char in ?a..?f or char in ?A..?F

  # ---------------------------------------------------------------------------
  # Classes of the flag `v`
  #
  # A class is `{:class, negated?, operator, operands}`. The operator is
  # `:union`, `:intersection`, or `:subtraction`. An operand is
  # `{:range, low, high}`, `{:escape, pcre}` for an escape such as `\d`,
  # `{:strings, [String.t()]}` for `\q{...}`, or a class.
  # ---------------------------------------------------------------------------

  defp class(<<?^, rest::binary>>), do: class_contents(rest, true)
  defp class(rest), do: class_contents(rest, false)

  defp class_contents(<<?], rest::binary>>, negated?), do: {{:class, negated?, :union, []}, rest}

  defp class_contents(source, negated?) do
    {first, rest} = class_item(source, true)

    case rest do
      <<"&&", rest::binary>> ->
        class_operation(rest, negated?, :intersection, "&&", [operand!(first)])

      <<"--", rest::binary>> ->
        class_operation(rest, negated?, :subtraction, "--", [operand!(first)])

      _union ->
        class_union(rest, negated?, [first])
    end
  end

  defp class_union(<<?], rest::binary>>, negated?, items),
    do: {{:class, negated?, :union, Enum.reverse(items)}, rest}

  defp class_union(<<"&&", _rest::binary>>, _negated?, _items), do: invalid()
  defp class_union(<<"--", _rest::binary>>, _negated?, _items), do: invalid()

  defp class_union(source, negated?, items) do
    {item, rest} = class_item(source, true)
    class_union(rest, negated?, [item | items])
  end

  defp class_operation(source, negated?, operator, token, operands) do
    {item, rest} = class_item(source, false)
    operands = [item | operands]

    case rest do
      <<?], rest::binary>> ->
        {{:class, negated?, operator, Enum.reverse(operands)}, rest}

      <<^token::binary-size(2), rest::binary>> ->
        class_operation(rest, negated?, operator, token, operands)

      _other ->
        invalid()
    end
  end

  # A range is not an operand of `&&` or `--`.
  defp operand!({:range, low, high}) when low != high, do: invalid()
  defp operand!(item), do: item

  # One item of a class: a range or a character when `range?` is true, a
  # class, or an escape.
  defp class_item(<<?[, rest::binary>>, _range?), do: class(rest)

  defp class_item(<<?\\, ?q, ?{, rest::binary>>, _range?) do
    case :binary.split(rest, "}") do
      [body, rest] -> {{:strings, class_strings(body)}, rest}
      [_no_end] -> invalid()
    end
  end

  defp class_item(<<?\\, char, rest::binary>>, _range?) when char in ~c"dDwW",
    do: {{:escape, <<?\\, char>>}, rest}

  defp class_item(<<?\\, ?s, rest::binary>>, _range?),
    do: {{:class, false, :union, ranges(@white_space)}, rest}

  defp class_item(<<?\\, ?S, rest::binary>>, _range?),
    do: {{:class, true, :union, ranges(@white_space)}, rest}

  defp class_item(<<?\\, char, ?{, rest::binary>>, _range?) when char in ~c"pP" do
    {escape, rest} = property(char, rest)
    {{:escape, IO.iodata_to_binary(escape)}, rest}
  end

  defp class_item(source, range?) do
    {low, rest} = class_character(source)

    case rest do
      <<?-, next, _more::binary>> when range? and next not in [?-, ?]] ->
        <<?-, after_dash::binary>> = rest
        {high, rest} = class_character(after_dash)
        range(low, high, rest)

      _single ->
        range(low, low, rest)
    end
  end

  defp range(:surrogate, :surrogate, rest), do: {{:class, false, :union, []}, rest}
  defp range(low, high, _rest) when not is_integer(low) or not is_integer(high), do: invalid()
  defp range(low, high, _rest) when low > high, do: invalid()
  defp range(low, high, rest), do: {{:range, low, high}, rest}

  defp ranges(pairs), do: Enum.map(pairs, fn {low, high} -> {:range, low, high} end)

  # "ClassSetCharacter".
  defp class_character(<<?\\, rest::binary>>), do: character_escape(rest, true)

  defp class_character(<<char, char, _rest::binary>>) when char in @class_double_punctuators,
    do: invalid()

  defp class_character(<<char, _rest::binary>>) when char in @class_syntax_characters,
    do: invalid()

  defp class_character(<<code_point::utf8, rest::binary>>), do: {code_point, rest}
  defp class_character(_source), do: invalid()

  # The strings of `\q{...}`, with the longest strings first, as ECMAScript
  # tries them.
  defp class_strings(body) do
    body
    |> :binary.split("|", [:global])
    |> Enum.map(&class_string(&1, []))
    |> Enum.sort_by(&(-length(&1)))
  end

  defp class_string(<<>>, acc), do: Enum.reverse(acc)

  defp class_string(source, acc) do
    case class_character(source) do
      {:surrogate, _rest} -> invalid()
      {code_point, rest} -> class_string(rest, [code_point | acc])
    end
  end

  # ---------------------------------------------------------------------------
  # The output of a class
  # ---------------------------------------------------------------------------

  defp emit_class({:class, negated?, :union, items} = class) do
    cond do
      simple?(class) -> bracket(negated?, items)
      negated? -> ["(?:(?!", emit_class({:class, false, :union, items}), ")[\\s\\S])"]
      true -> union(items)
    end
  end

  # `A&&B&&C` is `(?=A)(?=B)C`, and `A--B--C` is `(?!B)(?!C)A`.
  defp emit_class({:class, negated?, operator, operands}) do
    body =
      case operator do
        :intersection ->
          [
            Enum.map(Enum.drop(operands, -1), &["(?=", emit_operand(&1), ")"]),
            emit_operand(List.last(operands))
          ]

        :subtraction ->
          [first | others] = operands
          [Enum.map(others, &["(?!", emit_operand(&1), ")"]), emit_operand(first)]
      end

    if negated?, do: ["(?:(?!", body, ")[\\s\\S])"], else: ["(?:", body, ")"]
  end

  defp simple?({:class, _negated?, :union, items}), do: Enum.all?(items, &simple_item?/1)

  defp simple_item?({:range, _low, _high}), do: true
  defp simple_item?({:escape, _escape}), do: true
  defp simple_item?(_item), do: false

  defp bracket(false, []), do: "(?!)"
  defp bracket(true, []), do: "[\\s\\S]"

  defp bracket(negated?, items),
    do: ["[", if(negated?, do: "^", else: ""), Enum.map(items, &bracket_item/1), "]"]

  defp bracket_item({:range, code_point, code_point}), do: hex(code_point)
  defp bracket_item({:range, low, high}), do: [hex(low), ?-, hex(high)]
  defp bracket_item({:escape, escape}), do: escape

  defp union(items) do
    {simple, others} = Enum.split_with(items, &simple_item?/1)
    strings = for {:strings, list} <- others, string <- list, do: string
    classes = for {:class, _, _, _} = class <- others, do: emit_class(class)

    alternatives =
      Enum.map(strings, fn code_points -> Enum.map(code_points, &literal/1) end) ++
        classes ++ if(simple == [], do: [], else: [bracket(false, simple)])

    # A union of this kind has a class or a string: one alternative or more.
    ["(?:", Enum.intersperse(alternatives, ?|), ")"]
  end

  defp emit_operand({:range, low, high}), do: bracket(false, [{:range, low, high}])
  defp emit_operand({:escape, escape}), do: escape
  defp emit_operand({:strings, list}), do: union([{:strings, list}])
  defp emit_operand({:class, _, _, _} = class), do: emit_class(class)

  defp set(pairs), do: bracket(false, ranges(pairs))
  defp negated_set(pairs), do: bracket(true, ranges(pairs))

  # A literal code point. PCRE2 reads `\x{...}` in each context.
  defp literal(code_point)
       when code_point in ?a..?z or code_point in ?A..?Z or code_point in ?0..?9,
       do: <<code_point>>

  defp literal(code_point), do: hex(code_point)

  defp hex(code_point), do: ["\\x{", Integer.to_string(code_point, 16), "}"]
end
