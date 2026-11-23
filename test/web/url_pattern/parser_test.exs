defmodule Web.URLPattern.ParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.URLPattern.{Compiler, Parser}

  @default %{delimiter: "", prefix: "", ignore_case: false}
  @pathname %{delimiter: "/", prefix: "/", ignore_case: false}

  defp parse(input, options \\ @pathname), do: Parser.parse(input, options, & &1)

  describe "tokenize/2" do
    test "gives a token of each type" do
      assert Parser.tokenize("{a\\b}:n(x)?+*", :strict) == [
               {:open, 0, "{"},
               {:char, 1, "a"},
               {:escaped_char, 2, "b"},
               {:close, 4, "}"},
               {:name, 5, "n"},
               {:regexp, 7, "x"},
               {:other_modifier, 10, "?"},
               {:other_modifier, 11, "+"},
               {:asterisk, 12, "*"},
               {:end, 13, ""}
             ]
    end

    test "gives the index of a code point, not of a byte" do
      assert Parser.tokenize("é:café", :strict) == [
               {:char, 0, "é"},
               {:name, 1, "café"},
               {:end, 6, ""}
             ]
    end

    test "reads the groups in a regular expression" do
      assert Parser.tokenize("(a(?:b)\\))", :strict) == [
               {:regexp, 0, "a(?:b)\\)"},
               {:end, 10, ""}
             ]
    end

    test "gives an invalid-char token for each error with the lenient policy" do
      for {input, value} <- [
            {"\\", "\\"},
            {":", ":"},
            {"(", "("},
            {"()", "("},
            {"(?a)", "("},
            {"(é)", "("},
            {"(a\\é)", "("},
            {"(a\\", "("},
            {"(a(", "("},
            {"(a(b))", "("},
            {"(a", "("}
          ] do
        assert [{:invalid_char, 0, ^value} | _rest] = Parser.tokenize(input, :lenient)
      end
    end

    test "continues after an invalid-char token with the lenient policy" do
      assert Parser.tokenize("(a", :lenient) == [
               {:invalid_char, 0, "("},
               {:char, 1, "a"},
               {:end, 2, ""}
             ]
    end

    test "raises TypeError for each error with the strict policy" do
      for input <- ["\\", ":", ":1", "(", "()", "(?a)", "(é)", "(a(b))", "(a"] do
        assert_raise Web.TypeError, fn -> Parser.tokenize(input, :strict) end
      end
    end
  end

  test "valid_name_code_point?/2 has the identifier code points of ECMAScript" do
    for code_point <- [?a, ?Z, ?$, ?_, ?é, 0x2118, 0x3400] do
      assert Parser.valid_name_code_point?(code_point, true)
    end

    for code_point <- [?0, ?-, ?\s, 0x1F6B2, 0x200C] do
      refute Parser.valid_name_code_point?(code_point, true)
    end

    for code_point <- [?0, ?_, 0x200C, 0x200D, 0x0301] do
      assert Parser.valid_name_code_point?(code_point, false)
    end

    refute Parser.valid_name_code_point?(?-, false)
    refute Parser.valid_name_code_point?(0x1F6B2, false)
  end

  describe "parse/3" do
    test "gives the parts of the Standard" do
      assert parse("/foo/:bar?") == [
               %{
                 type: :fixed_text,
                 value: "/foo",
                 modifier: :none,
                 name: "",
                 prefix: "",
                 suffix: ""
               },
               %{
                 type: :segment_wildcard,
                 value: "",
                 modifier: :optional,
                 name: "bar",
                 prefix: "/",
                 suffix: ""
               }
             ]

      assert [%{type: :full_wildcard, name: "0"}, %{type: :regexp, value: "\\d+", name: "1"}] =
               parse("*(\\d+)", @default)

      assert [%{type: :fixed_text, value: "ab", modifier: :zero_or_more}] = parse("{ab}*")
      assert [%{type: :segment_wildcard, prefix: "a", suffix: "-b", name: "x"}] = parse("{a:x-b}")
    end

    test "gives the same part for a regular expression of a wildcard" do
      assert parse("/:a([^\\/]+?)") == parse("/:a")
      assert parse("(.*)") == parse("*")
    end

    test "joins the fixed text of a group with no modifier" do
      assert [%{type: :fixed_text, value: "/foo/bar", modifier: :none}] = parse("/foo{/bar}")
      assert parse("{}?") == []
    end

    test "keeps the text before a group that is not the prefix code point" do
      assert [%{value: "a"}, %{type: :segment_wildcard, prefix: ""}] = parse("a:x")
    end

    test "gives the encoding callback each fixed text" do
      parts = Parser.parse("/a{b}?:x", @pathname, &String.upcase/1)
      assert [%{value: "/A"}, %{value: "B"}, %{prefix: "", name: "x"}] = parts
    end

    test "raises TypeError for a pattern that is not valid" do
      for input <- ["/:id/:id", "{a{b}}", "{a", "a}", "a?", ":x?+", "("] do
        assert_raise Web.TypeError, fn -> parse(input) end
      end
    end
  end

  test "escape_regexp_string/1 escapes the syntax characters of a regular expression" do
    assert Parser.escape_regexp_string("a.+*?^${}()[]|/\\b") ==
             "a\\.\\+\\*\\?\\^\\$\\{\\}\\(\\)\\[\\]\\|\\/\\\\b"
  end

  property "the escaped text of a pattern string is one fixed text" do
    check all(text <- string(:ascii, min_length: 1, max_length: 20)) do
      assert parse(Compiler.escape_pattern_string(text), @default) == [
               %{
                 type: :fixed_text,
                 value: text,
                 modifier: :none,
                 name: "",
                 prefix: "",
                 suffix: ""
               }
             ]
    end
  end
end
