defmodule Web.URLPattern.RegExpTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.URLPattern
  alias Web.URLPattern.RegExp

  @alphabet ~c"abcdefgh01234"

  defp matches?(source, text, ignore_case \\ false),
    do: :re.run(text, RegExp.compile!("^(?:" <> source <> ")$", ignore_case)) != :nomatch

  # The set of the characters of the alphabet that a class matches.
  defp matched(source) do
    for char <- @alphabet, matches?(source, <<char>>), into: MapSet.new(), do: char
  end

  describe "translate!/1" do
    test "keeps the syntax that PCRE2 reads in the same way" do
      for source <-
            ["a|b", "(?:a)", "(?<n>a)\\k<n>", "(?=a)", "(?!a)", "(?<=a)", "(?<!a)", "^$"] ++
              ["\\d\\D\\w\\W\\b\\B", "a*?b+?c??", "a{2}b{2,}c{2,3}?", "(?i:a)", "(?-i:a)"] do
        assert RegExp.translate!(source) == source
      end
    end

    test "writes the escapes of ECMAScript in the syntax of PCRE2" do
      for {source, pcre} <- [
            {"\\u0041", "A"},
            {"\\u{1F600}", "\\x{1F600}"},
            {"\\uD83D\\uDE00", "\\x{1F600}"},
            {"\\x41\\x2e", "A\\x{2E}"},
            {"\\cJ", "\\x{A}"},
            {"\\0", "\\x{0}"},
            {"\\f\\n\\r\\t\\v", "\\x{C}\\x{A}\\x{D}\\x{9}\\x{B}"},
            {"\\/\\.", "\\x{2F}\\x{2E}"},
            {"(a)\\1", "(a)\\g{1}"},
            {"\\p{Letter}\\P{gc=Lu}", "\\p{L}\\P{Lu}"},
            {"\\p{Script=Greek}\\p{Script_Extensions=Latn}", "\\p{sc=Greek}\\p{scx=Latn}"},
            {"\\p{ID_Start}", "\\p{ID_Start}"},
            {"é", "\\x{E9}"}
          ] do
        assert RegExp.translate!(source) == pcre
      end
    end

    test "gives the matches of ECMAScript" do
      assert matches?("\\u0041", "A")
      refute matches?(".", "\n")
      refute matches?(".", "\u2028")
      assert matches?(".", "é")
      assert matches?("(?s:.)", "\n")
      assert matches?("(?s:(?-s:.)|x)", "x")
      refute matches?("(?s:(?-s:.))", "\n")
      assert matches?("\\s", "\u00A0")
      assert matches?("\\s", "\uFEFF")
      refute matches?("\\s", "a")
      assert matches?("\\S", "a")
      assert matches?("\\uD83D\\uDE00", "😀")
      refute matches?("\\uD83D", "😀")
      assert matches?("\\p{Script=Greek}+", "αβ")
      refute matches?("a", "a\n")
      assert matches?("A", "a", true)
      refute matches?("A", "a")
    end

    test "raises TypeError for the syntax that ECMAScript refuses" do
      for source <-
            ["\\H", "\\m", "\\-", "\\A", "\\z", "\\x4", "\\c1", "\\01", "\\u12", "\\u{110000}"] ++
              ["\\u{}", "\\u{1G}", "\\k", "\\k<y>", "\\k<1>", "\\k<a", "(a)\\2", "\\p{}", "\\p{L"] ++
              ["\\p{Foo=Bar}", "\\p{a-b}", "(?R)", "(?0)", "(?P<n>a)", "(?ii:a)", "(?-:a)"] ++
              ["(?x:a)", "(?i-i:a)", "(?<1a>x)", "(?<x>a)(?<x>b)", "(?<x", "(", ")", "a)"] ++
              ["a**", "*a", "a|*", "{", "}", "]", "a{", "a{2,1}", "(?=a)*", "(?<=a)+", "^*"] ++
              ["\\b+", "\\p{UnknownProperty}"] do
        assert_raise Web.TypeError, fn -> RegExp.compile!(source, false) end
      end
    end
  end

  describe "a class of the flag v" do
    test "has the escapes of a class" do
      assert RegExp.translate!("[a-z\\d]") == "[\\x{61}-\\x{7A}\\d]"
      assert RegExp.translate!("[\\-\\&\\b\\]]") == "[\\x{2D}\\x{26}\\x{8}\\x{5D}]"
      assert RegExp.translate!("[\\p{L}\\P{Nd}]") == "[\\p{L}\\P{Nd}]"
      assert matched("[\\s\\d]") == MapSet.new(~c"01234")
      assert matched("[\\S--[a-e]]") == MapSet.new(~c"fgh01234")
    end

    test "matches nothing when empty, and each character when negated and empty" do
      refute matches?("[]", "a")
      assert matches?("[^]", "\n")
    end

    test "matches the strings of \\q" do
      assert matches?("[\\q{abc|d}x]", "abc")
      assert matches?("[\\q{abc|d}x]", "x")
      refute matches?("[\\q{abc|d}x]", "ab")
      assert matches?("[\\q{}]", "")
      assert matches?("[[a-c]--\\q{b}]", "a")
      refute matches?("[[a-c]--\\q{b}]", "b")
    end

    test "matches a surrogate never" do
      refute matches?("[\\uD800]", "a")
      refute matches?("[\\uD800a]", "b")
    end

    test "raises TypeError for the syntax that the flag v refuses" do
      for source <-
            [
              "[",
              "[a-",
              "[a-]",
              "[ab--c]",
              "[a-c--b]",
              "[(]",
              "[)]",
              "[{]",
              "[}]",
              "[/]",
              "[|]",
              "[a&&b-c]",
              "[ab&&c]"
            ] ++
              ["[a--b&&c]", "[a&&&b]", "[a!!b]", "[a&&]", "[z-a]", "[\\q{a]", "[\\q{\\uD800}]"] ++
              ["[\\uD800-a]", "[\\", "[\\H]"] do
        assert_raise Web.TypeError, fn -> RegExp.compile!(source, false) end
      end
    end

    test "gives the sets of the flag v" do
      assert matched("[[a-h]--a]") == MapSet.new(~c"bcdefgh")
      assert matched("[\\d&&[0-1]]") == MapSet.new(~c"01")
      assert matched("[[a-h]--[aeh]--c]") == MapSet.new(~c"bdfg")
      assert matched("[[a-f]&&[d-h]&&[^e]]") == MapSet.new(~c"df")
      assert matched("[^[a-c][0-9]]") == MapSet.new(~c"defgh")
      assert matched("[^[a-c]&&[b-h]]") == MapSet.new(~c"adefgh01234")
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
      check all({source, expected} <- class_expression(), max_runs: 200) do
        assert matched(source) == expected
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
      assert_raise Web.TypeError, fn -> URLPattern.new(%{pathname: "/([[a-z]--a)"}) end
    end
  end
end
