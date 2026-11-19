defmodule Web.URLPattern.ClassSetTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.URLPattern
  alias Web.URLPattern.ClassSet

  @alphabet ~c"abcdefgh01234"

  describe "translate/1" do
    test "does not change a pattern that has no syntax of the flag v" do
      for pattern <- [
            "[a-z]",
            "[^abc]+",
            "a[b]c\\[x",
            "\\d+",
            "",
            "(foo|bar)",
            "[a\\]b]",
            "[\\p{L}\\d]"
          ] do
        assert ClassSet.translate(pattern) == pattern
      end
    end

    test "raises for a class that has no end" do
      for pattern <- ["[a-z", "[[a-z]--a", "[\\", "[\\p{L", "[a\\]"] do
        assert_raise ArgumentError, ~r/character class has no end/, fn ->
          ClassSet.translate(pattern)
        end
      end
    end

    test "changes a class with an operator or a nested class into an extended class" do
      assert ClassSet.translate("[[a-z]--a]") == "(?[([a-z] - [a])])"
      assert ClassSet.translate("[\\d&&[0-1]]") == "(?[([\\d] & [0-1])])"
      assert ClassSet.translate("x[[a-c][x-z]]y") == "x(?[(([a-c] + [x-z]))])y"
      assert ClassSet.translate("[^[a-c]]") == "(?[!([a-c])])"
    end

    # The set of the characters of the alphabet that a pattern matches.
    defp matched(pattern) do
      regex = Regex.compile!("^" <> ClassSet.translate(pattern) <> "$", "u")
      for char <- @alphabet, Regex.match?(regex, <<char>>), into: MapSet.new(), do: char
    end

    test "gives the sets of the flag v" do
      assert matched("[[a-h]--a]") == MapSet.new(~c"bcdefgh")
      assert matched("[\\d&&[0-1]]") == MapSet.new(~c"01")
      assert matched("[[a-h]--[aeh]--c]") == MapSet.new(~c"bdfg")
      assert matched("[[a-f]&&[d-h]&&[^e]]") == MapSet.new(~c"df")
      assert matched("[^[a-c][0-9]]") == MapSet.new(~c"defgh")
      assert matched("[a[c-e]0]") == MapSet.new(~c"acde0")
      assert matched("[[[a-h]--[c-f]]&&[a-d]]") == MapSet.new(~c"ab")
      assert matched("[\\p{L}--[a-d]]") == MapSet.new(~c"efgh")
    end

    # A class expression as data, with its text in the syntax of the flag v
    # and the set of the characters that it matches.
    defp class_expression do
      leaf =
        gen all(chars <- uniq_list_of(member_of(@alphabet), min_length: 1, max_length: 5)) do
          {"[" <> List.to_string(chars) <> "]", MapSet.new(chars)}
        end

      tree(leaf, fn child ->
        one_of([
          gen all({left, left_set} <- child, {right, right_set} <- child) do
            {"[" <> left <> "--" <> right <> "]", MapSet.difference(left_set, right_set)}
          end,
          gen all({left, left_set} <- child, {right, right_set} <- child) do
            {"[" <> left <> "&&" <> right <> "]", MapSet.intersection(left_set, right_set)}
          end,
          gen all({left, left_set} <- child, {right, right_set} <- child) do
            {"[" <> left <> right <> "]", MapSet.union(left_set, right_set)}
          end,
          gen all({inner, inner_set} <- child) do
            {"[^" <> inner <> "]", MapSet.difference(MapSet.new(@alphabet), inner_set)}
          end
        ])
      end)
    end

    property "gives the same set as the operators of the flag v, for each expression" do
      check all({pattern, expected} <- class_expression(), max_runs: 200) do
        assert matched(pattern) == expected
      end
    end
  end

  describe "a URL pattern" do
    test "accepts a subtraction and an intersection in a group" do
      consonants = URLPattern.new(%{pathname: "/([[a-z]--[aeiou]]+)"})
      assert URLPattern.test(consonants, %{pathname: "/bcd"})
      refute URLPattern.test(consonants, %{pathname: "/bad"})

      low_digits = URLPattern.new(%{pathname: "/([\\d&&[0-4]]+)"})
      assert URLPattern.test(low_digits, %{pathname: "/0421"})
      refute URLPattern.test(low_digits, %{pathname: "/0451"})
    end

    test "refuses a class that has no end" do
      assert_raise ArgumentError, fn -> URLPattern.new(%{pathname: "/([[a-z]--a)"}) end
    end
  end
end
