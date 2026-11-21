defmodule Web.URLPattern.CompilerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.URLPattern.{Canonical, Compiler, Parser}

  @default %{delimiter: "", prefix: "", ignore_case: false}
  @hostname %{delimiter: ".", prefix: "", ignore_case: false}
  @pathname %{delimiter: "/", prefix: "/", ignore_case: false}

  defp parts(input, options), do: Parser.parse(input, options, & &1)

  defp regexp(input, options \\ @pathname),
    do: Compiler.regexp_and_names(parts(input, options), options)

  defp pattern(input, options \\ @pathname),
    do: Compiler.pattern_string(parts(input, options), options)

  defp compile(input, options \\ @pathname), do: Compiler.compile(input, & &1, options)

  describe "regexp_and_names/2" do
    test "gives each form of the Standard" do
      assert regexp("/foo") == {"^\\/foo$", []}
      assert regexp("{foo}?") == {"^(?:foo)?$", []}
      assert regexp(":a") == {"^([^\\/]+?)$", ["a"]}
      assert regexp("(x)?") == {"^(x)?$", ["0"]}
      assert regexp("*+", @default) == {"^((?:.*)+)$", ["0"]}
      assert regexp("/:a?") == {"^(?:\\/([^\\/]+?))?$", ["a"]}
      assert regexp("{a:b-}") == {"^(?:a([^\\/]+?)-)$", ["b"]}

      assert regexp("/:a*") ==
               {"^(?:\\/((?:[^\\/]+?)(?:\\/(?:[^\\/]+?))*))?$", ["a"]}

      assert regexp("/:a+") == {"^(?:\\/((?:[^\\/]+?)(?:\\/(?:[^\\/]+?))*))$", ["a"]}
      assert regexp(":a.:b", @hostname) == {"^([^\\.]+?)\\.([^\\.]+?)$", ["a", "b"]}
    end
  end

  describe "pattern_string/2" do
    test "gives the canonical text of the Standard" do
      for {input, options, expected} <- [
            {"/foo/(.*)", @pathname, "/foo/*"},
            {"/foo/(.*)?", @pathname, "/foo/*?"},
            {"/foo{/bar}", @pathname, "/foo/bar"},
            {"{a}+", @pathname, "{a}+"},
            {"(foo)?(.*)", @pathname, "(foo)?*"},
            {"{:foo}{(.*)}", @pathname, "{:foo}(.*)"},
            {"{:foo}{(.*)bar}", @pathname, ":foo{*bar}"},
            {"{:foo}{bar(.*)}", @pathname, ":foo{bar*}"},
            {"{:foo}:bar(.*)", @pathname, ":foo:bar(.*)"},
            {"{:foo\\bar}", @pathname, "{:foo\\bar}"},
            {"{:foo-bar}", @pathname, "{:foo-bar}"},
            {":foo\\bar", @pathname, "{:foo}bar"},
            {":foo{}(.*)", @pathname, "{:foo}(.*)"},
            {"*{}**?", @pathname, "*(.*)?"},
            {"*\\/*", @pathname, "*/{*}"},
            {"/:foo\\bar", @pathname, "{/:foo}bar"},
            {"/([^\\/]+?)", @pathname, "/([^\\/]+?)"},
            {"([^\\.]+?)", @hostname, "([^\\.]+?)"},
            {"{a.(.*)}", @hostname, "{a.*}"},
            {"/foo\\:", @pathname, "/foo\\:"}
          ] do
        assert pattern(input, options) == expected, inspect(input)
      end
    end

    test "gives an empty text for no parts" do
      assert pattern("") == ""
    end

    test "gives no group for a name before fixed text that is empty" do
      # The opaque path of "?" is empty.
      component =
        Compiler.compile(":foo\\?", &Canonical.opaque_pathname/1, @default)

      assert component.pattern == ":foo"
    end
  end

  describe "compile/3 and match/2" do
    test "gives the groups of a match" do
      component = compile("/:a/(\\d+)?")

      assert Compiler.match(component, "/x/12") == %{"a" => "x", "0" => "12"}
      assert Compiler.match(component, "/x") == %{"a" => "x", "0" => nil}
      assert Compiler.match(component, "/x/") == nil
      assert Compiler.match(component, "/x/y") == nil
    end

    test "gives nil for a group after the last group that matches" do
      component = compile("(a)?(b)?", @default)
      assert Compiler.match(component, "a") == %{"0" => "a", "1" => nil}
    end

    test "gives nil for an empty iteration of a group with the form (value)?" do
      assert Compiler.match(compile("(x*)?", @default), "") == %{"0" => nil}
      assert Compiler.match(compile("(x*)", @default), "") == %{"0" => ""}
      assert Compiler.match(compile("{-(x*)}?", @default), "-") == %{"0" => ""}
    end

    test "tells if the pattern has a regular expression" do
      refute compile("/:a/*").has_regexp_groups
      assert compile("/:a(b)").has_regexp_groups
    end

    test "raises TypeError for a regular expression that is not valid" do
      for input <- ["(\\H)", "((?R))", "([a-]))"] do
        assert_raise Web.TypeError, fn -> compile(input) end
      end
    end

    test "ignores the case with the option" do
      component = Compiler.compile("/FOO", & &1, %{@pathname | ignore_case: true})
      assert Compiler.match(component, "/foo") == %{}
    end
  end

  test "escape_pattern_string/1 escapes the syntax of a pattern string" do
    assert Compiler.escape_pattern_string("a+*?:{}()\\b/") == "a\\+\\*\\?\\:\\{\\}\\(\\)\\\\b/"
  end

  # Pieces of pattern strings. Some joins of them are not valid.
  @pieces ["a", "b", "1", "/", ".", "-", ":foo", ":bar", ":x1", "(\\d+)", "(.*)", "([^\\/]+?)"] ++
            ["([^\\.]+?)", "*", "?", "+", "{", "}", "\\:", "\\{", "\\*", "\\b"]

  defp pattern_input do
    gen all(pieces <- list_of(member_of(@pieces), max_length: 8)) do
      Enum.join(pieces)
    end
  end

  test "the pattern string of adjacent fixed-text parts gives one part" do
    parts = parts("a{}?b", @default)
    assert Enum.map(parts, & &1.value) == ["a", "b"]
    assert Compiler.pattern_string(parts, @default) == "ab"
    assert joined(parts("ab", @default)) == joined(parts)
  end

  property "the pattern string of a part list gives the same part list" do
    check all(
            input <- pattern_input(),
            options <- member_of([@default, @hostname, @pathname]),
            max_runs: 500
          ) do
      case try_parts(input, options) do
        nil ->
          :ok

        parts ->
          text = Compiler.pattern_string(parts, options)

          assert joined(parts(text, options)) == joined(parts),
                 "#{inspect(input)} gives #{inspect(text)}"

          assert Compiler.pattern_string(parts(text, options), options) == text
      end
    end
  end

  # "Generate a pattern string" writes two fixed-text parts with no modifier
  # one after the other, and the parse of that text gives one part: `a{}?b`
  # gives the parts `a` and `b`, and the text `ab`. The two lists match the
  # same URLs. Thus the property compares the lists with such parts joined.
  defp joined(parts) do
    parts
    |> Enum.chunk_while(
      nil,
      fn
        %{type: :fixed_text, modifier: :none} = part,
        %{type: :fixed_text, modifier: :none} = acc ->
          {:cont, %{acc | value: acc.value <> part.value}}

        part, nil ->
          {:cont, part}

        part, acc ->
          {:cont, acc, part}
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
  end

  defp try_parts(input, options) do
    parts(input, options)
  rescue
    Web.TypeError -> nil
  end
end
