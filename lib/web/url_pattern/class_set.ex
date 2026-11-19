defmodule Web.URLPattern.ClassSet do
  @moduledoc false

  # The URL Pattern Standard compiles each regular expression with the flag
  # `v` of ECMAScript. With that flag, a character class can contain a class,
  # and can use two operators:
  #
  #     [[a-z]--[aeiou]]    the letters that are not vowels   (subtraction)
  #     [\d&&[0-4]]         the digits from 0 to 4            (intersection)
  #
  # PCRE2 has the same operations with a different syntax, the extended
  # character class: `(?[ [a-z] - [aeiou] ])`. This module changes each class
  # that uses the syntax of the flag `v` into an extended character class. A
  # class that does not use that syntax stays as it is.

  # Raises `ArgumentError` for a class that has no end.
  @spec translate(String.t()) :: String.t()
  def translate(pattern) when is_binary(pattern) do
    outside(pattern, [])
  catch
    :unterminated ->
      raise ArgumentError, "Invalid regex in pattern: a character class has no end"
  end

  # ---------------------------------------------------------------------------
  # The text that is not in a class
  # ---------------------------------------------------------------------------

  defp outside(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp outside(<<"\\", char::utf8, rest::binary>>, acc) do
    outside(rest, [<<"\\", char::utf8>> | acc])
  end

  defp outside(<<"[", rest::binary>>, acc) do
    {class, rest} = parse_class(rest)
    outside(rest, [emit_top(class) | acc])
  end

  defp outside(<<char::utf8, rest::binary>>, acc), do: outside(rest, [<<char::utf8>> | acc])

  # ---------------------------------------------------------------------------
  # The parser of a class
  #
  # A class is `%{negated?, operator, operands}`. An operand is a list of
  # items, and an item is `{:text, text}` or `{:class, class}`. The operator
  # `:union` has one operand.
  # ---------------------------------------------------------------------------

  defp parse_class(<<"^", rest::binary>>), do: parse_items(rest, true, :union, [], [])
  defp parse_class(rest), do: parse_items(rest, false, :union, [], [])

  defp parse_items(<<"]", rest::binary>>, negated?, operator, items, operands) do
    operands = Enum.reverse([Enum.reverse(items) | operands])
    {%{negated?: negated?, operator: operator, operands: operands}, rest}
  end

  defp parse_items(<<"&&", rest::binary>>, negated?, _operator, items, operands) do
    parse_items(rest, negated?, :intersection, [], [Enum.reverse(items) | operands])
  end

  defp parse_items(<<"--", rest::binary>>, negated?, _operator, items, operands) do
    parse_items(rest, negated?, :subtraction, [], [Enum.reverse(items) | operands])
  end

  defp parse_items(<<"[", rest::binary>>, negated?, operator, items, operands) do
    {class, rest} = parse_class(rest)
    parse_items(rest, negated?, operator, [{:class, class} | items], operands)
  end

  defp parse_items(<<"\\", rest::binary>>, negated?, operator, items, operands) do
    {escape, rest} = parse_escape(rest)
    parse_items(rest, negated?, operator, [{:text, "\\" <> escape} | items], operands)
  end

  defp parse_items(<<char::utf8, rest::binary>>, negated?, operator, items, operands) do
    parse_items(rest, negated?, operator, [{:text, <<char::utf8>>} | items], operands)
  end

  defp parse_items(<<>>, _negated?, _operator, _items, _operands), do: throw(:unterminated)

  # An escape with braces, such as `\p{Letter}` or `\u{1F600}`, is one item.
  defp parse_escape(<<letter, "{", rest::binary>>) when letter in ~c"pPqux" do
    case :binary.split(rest, "}") do
      [name, rest] -> {<<letter, "{", name::binary, "}">>, rest}
      [_no_end] -> throw(:unterminated)
    end
  end

  defp parse_escape(<<char::utf8, rest::binary>>), do: {<<char::utf8>>, rest}
  defp parse_escape(<<>>), do: throw(:unterminated)

  # ---------------------------------------------------------------------------
  # The output
  # ---------------------------------------------------------------------------

  defp emit_top(class) do
    if simple?(class), do: emit_simple(class), else: ["(?[", emit_expression(class), "])"]
  end

  # A class that PCRE2 reads in the same way as ECMAScript does.
  defp simple?(%{operator: :union, operands: [items]}) do
    Enum.all?(items, &match?({:text, _text}, &1))
  end

  defp simple?(_class), do: false

  defp emit_simple(%{negated?: negated?, operands: [items]}) do
    ["[", if(negated?, do: "^", else: ""), Enum.map(items, fn {:text, text} -> text end), "]"]
  end

  defp emit_expression(class) do
    if simple?(class) do
      emit_simple(class)
    else
      body =
        class.operands |> Enum.map(&emit_operand/1) |> Enum.intersperse(separator(class.operator))

      [if(class.negated?, do: "!", else: ""), "(", body, ")"]
    end
  end

  defp separator(:union), do: " + "
  defp separator(:intersection), do: " & "
  defp separator(:subtraction), do: " - "

  # An operand is the union of its items. The text items that come one after
  # the other make one bracket class, thus a range such as `a-z` stays whole.
  defp emit_operand(items) do
    items
    |> Enum.chunk_by(&match?({:text, _text}, &1))
    |> Enum.flat_map(fn
      [{:text, _text} | _rest] = texts -> [["[", Enum.map(texts, &elem(&1, 1)), "]"]]
      classes -> Enum.map(classes, fn {:class, class} -> emit_expression(class) end)
    end)
    |> case do
      [single] -> single
      parts -> ["(", Enum.intersperse(parts, " + "), ")"]
    end
  end
end
