defmodule Web.URLPattern.Parser do
  @moduledoc false

  # The tokenizer and the pattern parser of the URL Pattern Standard
  # ("2.1. Parsing pattern strings").
  #
  # A token is `{type, index, value}`. The type is one of `:open`, `:close`,
  # `:regexp`, `:name`, `:char`, `:escaped_char`, `:other_modifier`,
  # `:asterisk`, `:end`, and `:invalid_char`. The index is the position of
  # the first code point of the token in the input, in code points.
  #
  # A part is a map with the items of the Standard:
  #
  #     %{type: :fixed_text | :regexp | :segment_wildcard | :full_wildcard,
  #       value: String.t(), modifier: :none | :optional | :zero_or_more |
  #       :one_or_more, name: String.t(), prefix: String.t(),
  #       suffix: String.t()}
  #
  # An options map has the items `:delimiter`, `:prefix`, and
  # `:ignore_case`. Each error of the Standard raises `Web.TypeError`.

  @type token_type ::
          :open
          | :close
          | :regexp
          | :name
          | :char
          | :escaped_char
          | :other_modifier
          | :asterisk
          | :end
          | :invalid_char
  @type token :: {token_type(), non_neg_integer(), String.t()}
  @type modifier :: :none | :optional | :zero_or_more | :one_or_more
  @type part :: %{
          type: :fixed_text | :regexp | :segment_wildcard | :full_wildcard,
          value: String.t(),
          modifier: modifier(),
          name: String.t(),
          prefix: String.t(),
          suffix: String.t()
        }
  @type options :: %{delimiter: String.t(), prefix: String.t(), ignore_case: boolean()}

  # The full wildcard regexp value of the Standard.
  @full_wildcard ".*"

  # ---------------------------------------------------------------------------
  # Tokenizing
  # ---------------------------------------------------------------------------

  @doc false
  # "Tokenize": returns the token list of the input. The policy is `:strict`
  # or `:lenient`. With `:strict`, an error raises `Web.TypeError`.
  @spec tokenize(String.t(), :strict | :lenient) :: [token()]
  def tokenize(input, policy) when is_binary(input) do
    code_points = input |> String.to_charlist() |> List.to_tuple()
    tokenize(code_points, tuple_size(code_points), 0, policy, [])
  end

  defp tokenize(_code_points, length, index, _policy, tokens) when index >= length,
    do: Enum.reverse([{:end, index, ""} | tokens])

  defp tokenize(code_points, length, index, policy, tokens) do
    {index, tokens} =
      case elem(code_points, index) do
        ?* ->
          add(code_points, tokens, :asterisk, index, index + 1, index, 1)

        char when char in [?+, ??] ->
          add(code_points, tokens, :other_modifier, index, index + 1, index, 1)

        ?\\ ->
          tokenize_escape(code_points, length, index, policy, tokens)

        ?{ ->
          add(code_points, tokens, :open, index, index + 1, index, 1)

        ?} ->
          add(code_points, tokens, :close, index, index + 1, index, 1)

        ?: ->
          tokenize_name(code_points, length, index, policy, tokens)

        ?( ->
          tokenize_regexp(code_points, length, index, policy, tokens)

        _char ->
          add(code_points, tokens, :char, index, index + 1, index, 1)
      end

    tokenize(code_points, length, index, policy, tokens)
  end

  defp tokenize_escape(code_points, length, index, policy, tokens) do
    if index == length - 1 do
      tokenizing_error(code_points, tokens, policy, index, index + 1, index)
    else
      add(code_points, tokens, :escaped_char, index, index + 2, index + 1, 1)
    end
  end

  defp tokenize_name(code_points, length, index, policy, tokens) do
    name_start = index + 1
    name_end = name_end(code_points, length, name_start, name_start)

    if name_end <= name_start do
      tokenizing_error(code_points, tokens, policy, index, name_start, index)
    else
      add(code_points, tokens, :name, index, name_end, name_start, name_end - name_start)
    end
  end

  defp name_end(code_points, length, position, start) when position < length do
    if valid_name_code_point?(elem(code_points, position), position == start),
      do: name_end(code_points, length, position + 1, start),
      else: position
  end

  defp name_end(_code_points, _length, position, _start), do: position

  defp tokenize_regexp(code_points, length, index, policy, tokens) do
    start = index + 1

    case regexp_end(code_points, length, start, start, 1) do
      {:ok, position} when position - start - 1 > 0 ->
        add(code_points, tokens, :regexp, index, position, start, position - start - 1)

      _error_or_empty ->
        tokenizing_error(code_points, tokens, policy, index, start, index)
    end
  end

  # The steps of the loop for a "regexp" token. Returns `{:ok, position}`
  # with the position after the last ")", or `:error`. Only ASCII code
  # points can be in a regular expression, and a "(" in it must start a
  # group with "(?".
  defp regexp_end(code_points, length, position, start, depth) when position < length do
    char = elem(code_points, position)
    next = if position + 1 < length, do: elem(code_points, position + 1)

    case regexp_step(char, next, position == start, depth) do
      :error -> :error
      :done -> {:ok, position + 1}
      {skip, depth} -> regexp_end(code_points, length, position + skip, start, depth)
    end
  end

  # The end of the input with a depth that is not zero.
  defp regexp_end(_code_points, _length, _position, _start, _depth), do: :error

  # Returns `:error`, `:done`, or the count of code points to skip and the
  # new depth.
  defp regexp_step(char, _next, _first?, _depth) when char > 0x7F, do: :error
  defp regexp_step(??, _next, true, _depth), do: :error
  defp regexp_step(?\\, next, _first?, _depth) when next == nil or next > 0x7F, do: :error
  defp regexp_step(?\\, _next, _first?, depth), do: {2, depth}
  defp regexp_step(?), _next, _first?, 1), do: :done
  defp regexp_step(?), _next, _first?, depth), do: {1, depth - 1}
  defp regexp_step(?(, ??, _first?, depth), do: {1, depth + 1}
  defp regexp_step(?(, _next, _first?, _depth), do: :error
  defp regexp_step(_char, _next, _first?, depth), do: {1, depth}

  # "Add a token": the token starts at the index of the tokenizer, and the
  # tokenizer continues at `next`.
  defp add(code_points, tokens, type, index, next, value_position, value_length) do
    value = substring(code_points, value_position, value_length)
    {next, [{type, index, value} | tokens]}
  end

  # "Process a tokenizing error".
  defp tokenizing_error(_code_points, _tokens, :strict, _index, _next, _value_position),
    do: raise(Web.TypeError, "The pattern string is not valid.")

  defp tokenizing_error(code_points, tokens, :lenient, index, next, value_position),
    do:
      add(code_points, tokens, :invalid_char, index, next, value_position, next - value_position)

  defp substring(code_points, position, length) do
    position..(position + length - 1)//1
    |> Enum.map(&elem(code_points, &1))
    |> List.to_string()
  end

  @doc false
  # "Is a valid name code point": the IdentifierStart or the IdentifierPart
  # code points of ECMAScript.
  @spec valid_name_code_point?(non_neg_integer(), boolean()) :: boolean()
  def valid_name_code_point?(code_point, true),
    do: code_point in [?$, ?_] or property?(code_point, :id_start)

  def valid_name_code_point?(code_point, false),
    do: code_point in [?$, 0x200C, 0x200D] or property?(code_point, :id_continue)

  defp property?(code_point, _property) when code_point in ?a..?z or code_point in ?A..?Z,
    do: true

  defp property?(code_point, :id_continue) when code_point in ?0..?9 or code_point == ?_,
    do: true

  defp property?(code_point, _property) when code_point < 0x80, do: false

  defp property?(code_point, property),
    do: :re.run(<<code_point::utf8>>, property_regex(property)) != :nomatch

  defp property_regex(property) do
    key = {__MODULE__, property}

    case :persistent_term.get(key, nil) do
      nil ->
        source = if property == :id_start, do: "^\\p{ID_Start}$", else: "^\\p{ID_Continue}$"
        {:ok, regex} = :re.compile(source, [:unicode])
        :persistent_term.put(key, regex)
        regex

      regex ->
        regex
    end
  end

  # ---------------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------------

  @doc false
  # "Parse a pattern string": returns the part list. The encoding callback
  # validates and encodes each fixed text, and raises `Web.TypeError` for a
  # text that is not valid.
  @spec parse(String.t(), options(), (String.t() -> String.t())) :: [part()]
  def parse(input, options, encode) when is_binary(input) and is_function(encode, 1) do
    tokens = input |> tokenize(:strict) |> List.to_tuple()

    state = %{
      tokens: tokens,
      index: 0,
      encode: encode,
      segment_wildcard: segment_wildcard_regexp(options),
      prefix_code_point: options.prefix,
      parts: [],
      pending: "",
      next_numeric_name: 0
    }

    state |> parse_loop() |> Map.fetch!(:parts) |> Enum.reverse()
  end

  @doc false
  # "Generate a segment wildcard regexp".
  @spec segment_wildcard_regexp(options()) :: String.t()
  def segment_wildcard_regexp(options),
    do: "[^" <> escape_regexp_string(options.delimiter) <> "]+?"

  @doc false
  # "Escape a regexp string".
  @spec escape_regexp_string(String.t()) :: String.t()
  def escape_regexp_string(input) do
    for <<char <- input>>, into: "" do
      if char in ~c".+*?^${}()[]|/\\", do: <<?\\, char>>, else: <<char>>
    end
  end

  defp parse_loop(%{index: index, tokens: tokens} = state) when index >= tuple_size(tokens),
    do: state

  defp parse_loop(state) do
    {char_token, state} = try_consume(state, :char)
    {name_token, state} = try_consume(state, :name)
    {regexp_token, state} = try_consume_regexp_or_wildcard(state, name_token)

    cond do
      name_token != nil or regexp_token != nil ->
        prefix = token_value(char_token)

        {prefix, state} =
          if prefix != "" and prefix != state.prefix_code_point,
            do: {"", %{state | pending: state.pending <> prefix}},
            else: {prefix, state}

        state = add_pending_part(state)
        {modifier_token, state} = try_consume_modifier(state)

        state
        |> add_part(prefix, name_token, regexp_token, "", modifier_token)
        |> parse_loop()

      char_token != nil ->
        parse_loop(%{state | pending: state.pending <> token_value(char_token)})

      true ->
        parse_without_group(state)
    end
  end

  defp parse_without_group(state) do
    case try_consume(state, :escaped_char) do
      {{:escaped_char, _index, value}, state} ->
        parse_loop(%{state | pending: state.pending <> value})

      {nil, state} ->
        case try_consume(state, :open) do
          {nil, state} ->
            state = add_pending_part(state)
            {_end, state} = consume_required(state, :end)
            parse_loop(state)

          {_open, state} ->
            state |> parse_group() |> parse_loop()
        end
    end
  end

  # The sequence <open><char prefix><name><regexp><char suffix><close>
  # <modifier>.
  defp parse_group(state) do
    {prefix, state} = consume_text(state, "")
    {name_token, state} = try_consume(state, :name)
    {regexp_token, state} = try_consume_regexp_or_wildcard(state, name_token)
    {suffix, state} = consume_text(state, "")
    {_close, state} = consume_required(state, :close)
    {modifier_token, state} = try_consume_modifier(state)
    add_part(state, prefix, name_token, regexp_token, suffix, modifier_token)
  end

  defp try_consume(state, type) do
    case elem(state.tokens, state.index) do
      {^type, _index, _value} = token -> {token, %{state | index: state.index + 1}}
      _other -> {nil, state}
    end
  end

  defp try_consume_modifier(state) do
    case try_consume(state, :other_modifier) do
      {nil, state} -> try_consume(state, :asterisk)
      found -> found
    end
  end

  defp try_consume_regexp_or_wildcard(state, name_token) do
    case try_consume(state, :regexp) do
      {nil, state} when name_token == nil -> try_consume(state, :asterisk)
      found -> found
    end
  end

  defp consume_required(state, type) do
    case try_consume(state, type) do
      {nil, _state} -> raise Web.TypeError, "The pattern string is not valid."
      found -> found
    end
  end

  defp consume_text(state, text) do
    case try_consume(state, :char) do
      {nil, state} ->
        case try_consume(state, :escaped_char) do
          {nil, state} -> {text, state}
          {token, state} -> consume_text(state, text <> token_value(token))
        end

      {token, state} ->
        consume_text(state, text <> token_value(token))
    end
  end

  defp token_value(nil), do: ""
  defp token_value({_type, _index, value}), do: value

  # "Maybe add a part from the pending fixed value".
  defp add_pending_part(%{pending: ""} = state), do: state

  defp add_pending_part(state) do
    part = fixed_part(state.encode.(state.pending), :none)
    %{state | pending: "", parts: [part | state.parts]}
  end

  # "Add a part".
  defp add_part(state, prefix, name_token, regexp_token, suffix, modifier_token) do
    modifier = modifier(modifier_token)

    cond do
      name_token == nil and regexp_token == nil and modifier == :none ->
        %{state | pending: state.pending <> prefix}

      name_token == nil and regexp_token == nil ->
        state = add_pending_part(state)

        if prefix == "",
          do: state,
          else: %{state | parts: [fixed_part(state.encode.(prefix), modifier) | state.parts]}

      true ->
        state = add_pending_part(state)
        add_group_part(state, prefix, name_token, regexp_token, suffix, modifier)
    end
  end

  defp add_group_part(state, prefix, name_token, regexp_token, suffix, modifier) do
    {type, regexp_value} = group_type(regexp_token, state.segment_wildcard)
    {name, state} = group_name(name_token, state)

    if Enum.any?(state.parts, &(&1.name == name)) do
      raise Web.TypeError, "The pattern string has the group name #{inspect(name)} two times."
    end

    part = %{
      type: type,
      value: regexp_value,
      modifier: modifier,
      name: name,
      prefix: state.encode.(prefix),
      suffix: state.encode.(suffix)
    }

    %{state | parts: [part | state.parts]}
  end

  # The regexp value goes to a part type first. Thus a "regexp" token that
  # is equal to a segment wildcard or to a full wildcard is the same part
  # as a "name" token or an "asterisk" token.
  defp group_type(regexp_token, segment_wildcard) do
    regexp_value =
      case regexp_token do
        nil -> segment_wildcard
        {:asterisk, _index, _value} -> @full_wildcard
        {:regexp, _index, value} -> value
      end

    cond do
      regexp_value == segment_wildcard -> {:segment_wildcard, ""}
      regexp_value == @full_wildcard -> {:full_wildcard, ""}
      true -> {:regexp, regexp_value}
    end
  end

  defp group_name({:name, _index, value}, state), do: {value, state}

  defp group_name(nil, state) do
    {Integer.to_string(state.next_numeric_name),
     %{state | next_numeric_name: state.next_numeric_name + 1}}
  end

  defp fixed_part(value, modifier),
    do: %{type: :fixed_text, value: value, modifier: modifier, name: "", prefix: "", suffix: ""}

  defp modifier(nil), do: :none
  defp modifier({_type, _index, "?"}), do: :optional
  defp modifier({_type, _index, "*"}), do: :zero_or_more
  defp modifier({_type, _index, "+"}), do: :one_or_more
end
