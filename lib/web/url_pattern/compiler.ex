defmodule Web.URLPattern.Compiler do
  @moduledoc false

  # "Compile a component" of the URL Pattern Standard, with "generate a
  # regular expression and name list" (2.2) and "generate a pattern string"
  # (2.3).
  #
  # A component is a map:
  #
  #     %{pattern: String.t(), regex: :re.mp(), names: [String.t()],
  #       optional: [boolean()], has_regexp_groups: boolean(),
  #       parts: [Parser.part()]}
  #
  # `optional` tells for each name if its group has the form "(value)?".

  alias Web.URLPattern.{Parser, RegExp}

  @type component :: %{
          pattern: String.t(),
          regex: term(),
          names: [String.t()],
          optional: [boolean()],
          has_regexp_groups: boolean(),
          parts: [Parser.part()]
        }

  @full_wildcard ".*"

  @doc false
  # "Compile a component". Raises `Web.TypeError` for a pattern string that
  # is not valid, and for a regular expression that is not valid.
  @spec compile(String.t(), (String.t() -> String.t()), Parser.options()) :: component()
  def compile(input, encode, options) do
    parts = Parser.parse(input, options, encode)
    {source, names} = regexp_and_names(parts, options)

    %{
      pattern: pattern_string(parts, options),
      regex: RegExp.compile!(source, options.ignore_case),
      names: names,
      optional: for(part <- parts, part.type != :fixed_text, do: direct_optional?(part)),
      has_regexp_groups: Enum.any?(parts, &(&1.type == :regexp)),
      parts: parts
    }
  end

  @doc false
  # "RegExpBuiltinExec" and "create a component match result": returns the
  # map of the groups, or `nil` when the input does not match.
  @spec match(component(), String.t()) :: %{optional(String.t()) => String.t() | nil} | nil
  def match(%{regex: regex, names: names, optional: optional}, input) do
    case :re.run(input, regex, [{:capture, :all, :index}]) do
      {:match, [_whole | captures]} -> groups(Enum.zip(names, optional), captures, input, %{})
      :nomatch -> nil
    end
  end

  # A group that does not take part in the match is `undefined` in
  # JavaScript: `nil`. The groups after the last group that matches are not
  # in the list of `:re.run/3`.
  #
  # In ECMAScript, an iteration of a quantifier with a minimum of zero must
  # not match the empty string. Thus "(.*)?" at the end of the input does
  # not take part in the match. PCRE2 accepts the empty iteration, and the
  # group is "": this is `nil` here.
  defp groups([], _captures, _input, acc), do: acc

  defp groups([{name, optional?} | names], [{start, length} | captures], input, acc)
       when start >= 0 and (length > 0 or not optional?),
       do: groups(names, captures, input, Map.put(acc, name, binary_part(input, start, length)))

  defp groups([{name, _optional?} | names], [_unset | captures], input, acc),
    do: groups(names, captures, input, Map.put(acc, name, nil))

  defp groups([{name, _optional?} | names], [], input, acc),
    do: groups(names, [], input, Map.put(acc, name, nil))

  # The form "(value)?" of "generate a regular expression and name list".
  defp direct_optional?(part),
    do: part.modifier == :optional and part.prefix == "" and part.suffix == ""

  # ---------------------------------------------------------------------------
  # Regular expressions
  # ---------------------------------------------------------------------------

  @doc false
  # "Generate a regular expression and name list". The result is the source
  # text of an ECMAScript regular expression.
  @spec regexp_and_names([Parser.part()], Parser.options()) :: {String.t(), [String.t()]}
  def regexp_and_names(parts, options) do
    {body, names} =
      Enum.reduce(parts, {[], []}, fn part, {body, names} ->
        case part do
          %{type: :fixed_text} -> {[body | fixed_regexp(part)], names}
          _group -> {[body | group_regexp(part, options)], [part.name | names]}
        end
      end)

    {IO.iodata_to_binary(["^", body, "$"]), Enum.reverse(names)}
  end

  defp fixed_regexp(%{modifier: :none, value: value}), do: Parser.escape_regexp_string(value)

  defp fixed_regexp(%{modifier: modifier, value: value}),
    do: ["(?:", Parser.escape_regexp_string(value), ")", modifier_string(modifier)]

  defp group_regexp(part, options) do
    value =
      case part.type do
        :segment_wildcard -> Parser.segment_wildcard_regexp(options)
        :full_wildcard -> @full_wildcard
        :regexp -> part.value
      end

    prefix = Parser.escape_regexp_string(part.prefix)
    suffix = Parser.escape_regexp_string(part.suffix)
    repeat? = part.modifier in [:zero_or_more, :one_or_more]

    group_form(prefix == "" and suffix == "", repeat?, value, prefix, suffix, part.modifier)
  end

  # The four forms of a group of "generate a regular expression and name
  # list":
  #
  #     (<value>)<modifier>
  #     ((?:<value>)<modifier>)
  #     (?:<prefix>(<value>)<suffix>)<modifier>
  #     (?:<prefix>((?:<value>)(?:<suffix><prefix>(?:<value>))*)<suffix>)?
  defp group_form(true, false, value, _prefix, _suffix, modifier),
    do: ["(", value, ")", modifier_string(modifier)]

  defp group_form(true, true, value, _prefix, _suffix, modifier),
    do: ["((?:", value, ")", modifier_string(modifier), ")"]

  defp group_form(false, false, value, prefix, suffix, modifier),
    do: ["(?:", prefix, "(", value, ")", suffix, ")", modifier_string(modifier)]

  defp group_form(false, true, value, prefix, suffix, modifier) do
    [
      ["(?:", prefix, "((?:", value, ")(?:", suffix, prefix, "(?:", value, "))*)", suffix, ")"],
      if(modifier == :zero_or_more, do: "?", else: "")
    ]
  end

  # ---------------------------------------------------------------------------
  # Pattern strings
  # ---------------------------------------------------------------------------

  @doc false
  # "Generate a pattern string".
  @spec pattern_string([Parser.part()], Parser.options()) :: String.t()
  def pattern_string(parts, options) do
    parts = List.to_tuple(parts)
    last = tuple_size(parts) - 1

    0..last//1
    |> Enum.map(fn index ->
      previous = if index > 0, do: elem(parts, index - 1)
      next = if index < last, do: elem(parts, index + 1)
      part_string(elem(parts, index), previous, next, options)
    end)
    |> IO.iodata_to_binary()
  end

  defp part_string(%{type: :fixed_text, modifier: :none} = part, _previous, _next, _options),
    do: escape_pattern_string(part.value)

  defp part_string(%{type: :fixed_text} = part, _previous, _next, _options),
    do: ["{", escape_pattern_string(part.value), "}", modifier_string(part.modifier)]

  defp part_string(part, previous, next, options) do
    custom_name? = not ascii_digit?(part.name)

    grouping? =
      part.suffix != "" or (part.prefix != "" and part.prefix != options.prefix) or
        segment_needs_grouping?(part, next, custom_name?) or
        after_prefix_code_point?(part, previous, options)

    [
      if(grouping?, do: "{", else: ""),
      escape_pattern_string(part.prefix),
      if(custom_name?, do: [":", part.name], else: ""),
      group_body(part, previous, options, custom_name?, grouping?),
      suffix_escape(part, custom_name?),
      escape_pattern_string(part.suffix),
      if(grouping?, do: "}", else: ""),
      modifier_string(part.modifier)
    ]
  end

  # A group after fixed text that ends with the prefix code point needs a
  # group: else the prefix code point becomes the prefix of the group.
  defp after_prefix_code_point?(%{prefix: ""}, %{type: :fixed_text, value: value}, options),
    do: options.prefix != "" and String.ends_with?(value, options.prefix)

  defp after_prefix_code_point?(_part, _previous, _options), do: false

  # A named segment wildcard that the next part could continue, for example
  # ":foo" and then the text "bar", needs a group: "{:foo}bar".
  defp segment_needs_grouping?(part, next, custom_name?) do
    custom_name? and part.type == :segment_wildcard and part.modifier == :none and
      next != nil and next.prefix == "" and next.suffix == "" and next_continues_name?(next)
  end

  defp next_continues_name?(%{type: :fixed_text, value: value}), do: name_part_start?(value)
  defp next_continues_name?(next), do: ascii_digit?(next.name)

  defp group_body(%{type: :regexp, value: value}, _previous, _options, _custom?, _grouping?),
    do: ["(", value, ")"]

  defp group_body(%{type: :segment_wildcard}, _previous, options, false, _grouping?),
    do: ["(", Parser.segment_wildcard_regexp(options), ")"]

  defp group_body(%{type: :segment_wildcard}, _previous, _options, true, _grouping?), do: ""

  defp group_body(%{type: :full_wildcard} = part, previous, _options, custom?, grouping?) do
    if not custom? and
         (previous == nil or previous.type == :fixed_text or previous.modifier != :none or
            grouping? or part.prefix != ""),
       do: "*",
       else: ["(", @full_wildcard, ")"]
  end

  # A named segment wildcard and a suffix that could continue the name, for
  # example "{:foo\\bar}".
  defp suffix_escape(%{type: :segment_wildcard, suffix: suffix}, true) when suffix != "" do
    if name_part_start?(suffix), do: "\\", else: ""
  end

  defp suffix_escape(_part, _custom?), do: ""

  defp name_part_start?(<<code_point::utf8, _rest::binary>>),
    do: Parser.valid_name_code_point?(code_point, false)

  defp name_part_start?(_text), do: false

  # The name of a group is not empty.
  defp ascii_digit?(<<char, _rest::binary>>), do: char in ?0..?9

  @doc false
  # "Escape a pattern string".
  @spec escape_pattern_string(String.t()) :: String.t()
  def escape_pattern_string(input) do
    for <<char <- input>>, into: "" do
      if char in ~c"+*?:{}()\\", do: <<?\\, char>>, else: <<char>>
    end
  end

  # "Convert a modifier to a string".
  defp modifier_string(:zero_or_more), do: "*"
  defp modifier_string(:optional), do: "?"
  defp modifier_string(:one_or_more), do: "+"
  defp modifier_string(:none), do: ""
end
