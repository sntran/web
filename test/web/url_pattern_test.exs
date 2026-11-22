defmodule Web.URLPatternTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  use Web.Platform.Test,
    urls: [
      "https://raw.githubusercontent.com/web-platform-tests/wpt/master/urlpattern/resources/urlpatterntestdata.json",
      "https://raw.githubusercontent.com/web-platform-tests/wpt/master/urlpattern/resources/urlpattern-generate-test-data.json",
      "https://raw.githubusercontent.com/web-platform-tests/wpt/master/urlpattern/resources/urlpattern-compare-test-data.json"
    ],
    prefix: "URLPattern WPT compliance"

  alias Web.URLPattern
  alias Web.URLPattern.{Canonical, Compiler}

  @components ~w(protocol username password hostname port pathname search hash)a

  doctest URLPattern

  # ---------------------------------------------------------------------------
  # The data of WPT. `test/wpt/quickjs/url_pattern_test.exs` runs the same
  # data with the JavaScript files of WPT. These tests examine the same
  # results from Elixir.
  # ---------------------------------------------------------------------------

  @impl Web.Platform.Test
  def web_platform_test(%{"left" => left, "right" => right} = test_case) do
    left = URLPattern.new(left)
    right = URLPattern.new(right)
    component = test_case["component"]
    expected = test_case["expected"]

    assert URLPattern.compare_component(component, left, right) == expected
    assert URLPattern.compare_component(component, right, left) == -expected
    assert URLPattern.compare_component(component, left, left) == 0
  end

  def web_platform_test(%{"component" => component, "groups" => groups} = test_case) do
    pattern = URLPattern.new(test_case["pattern"])

    case test_case["expected"] do
      nil -> assert_raise ArgumentError, fn -> generate(pattern, component, groups) end
      expected -> assert generate(pattern, component, groups) == expected
    end
  end

  def web_platform_test(%{"pattern" => arguments} = test_case) do
    case test_case["expected_obj"] do
      "error" ->
        assert_raise Web.TypeError, fn -> build(arguments) end

      expected ->
        pattern = build(arguments)
        assert_components(pattern, expected || %{}, test_case["exactly_empty_components"] || [])
        assert_match(pattern, test_case)
    end
  end

  defp build([]), do: URLPattern.new()
  defp build([input]), do: URLPattern.new(input)
  defp build([input, base]) when is_binary(base), do: URLPattern.new(input, base)
  defp build([input, options]), do: URLPattern.new(input, options(options))

  defp build([input, base, options]) when is_binary(base),
    do: URLPattern.new(input, base, options(options))

  # WebIDL converts an object in the place of the base URL to a string.
  defp build([input, _object, options]), do: build([input, "[object Object]", options])

  defp options(%{"ignoreCase" => ignore_case}), do: %{ignore_case: ignore_case}
  defp options(_options), do: %{}

  defp assert_components(pattern, expected, empty) do
    for component <- @components do
      case {expected[Atom.to_string(component)], Atom.to_string(component) in empty} do
        {nil, true} -> assert Map.fetch!(pattern, component) == ""
        {nil, false} -> :ok
        {value, _empty?} -> assert Map.fetch!(pattern, component) == value
      end
    end
  end

  defp assert_match(pattern, %{"expected_match" => "error", "inputs" => inputs}) do
    assert_raise Web.TypeError, fn -> apply(URLPattern, :test, [pattern | inputs]) end
    assert_raise Web.TypeError, fn -> apply(URLPattern, :exec, [pattern | inputs]) end
  end

  defp assert_match(pattern, %{"expected_match" => expected, "inputs" => inputs})
       when is_map(expected) do
    assert apply(URLPattern, :test, [pattern | inputs])
    result = apply(URLPattern, :exec, [pattern | inputs])

    assert length(result.inputs) == length(expected["inputs"] || inputs)

    for component <- @components, value = expected[Atom.to_string(component)] do
      assert result[component].input == value["input"]
      assert result[component].groups == value["groups"]
    end
  end

  defp assert_match(pattern, %{"expected_match" => nil, "inputs" => inputs}) do
    refute apply(URLPattern, :test, [pattern | inputs])
    assert apply(URLPattern, :exec, [pattern | inputs]) == nil
  end

  defp assert_match(_pattern, _test_case), do: :ok

  # `URLPattern.generate()` of a proposal for the Standard: the text of a
  # component from the values of its groups. Only fixed text and segment
  # wildcards with no modifier can make the text. The encoding callback of
  # the component encodes each value of a group.
  defp generate(pattern, name, groups) do
    component = Enum.find(@components, &(Atom.to_string(&1) == name)) || raise ArgumentError
    compiled = pattern.compiled[component]

    value =
      Enum.map_join(compiled.parts, fn
        %{type: :fixed_text, modifier: :none, value: value} ->
          value

        %{type: :segment_wildcard, modifier: :none} = part ->
          group = Map.get(groups, part.name) || raise ArgumentError
          part.prefix <> encode(pattern, component, group) <> part.suffix

        _part ->
          raise ArgumentError
      end)

    if Compiler.match(compiled, value) == nil, do: raise(ArgumentError)
    value
  end

  # The pathname of a pattern with a special scheme has the encoding of a
  # path. Else it has the encoding of an opaque path.
  defp encode(pattern, :pathname, value) do
    if Enum.any?(~w(ftp file http https ws wss), &Compiler.match(pattern.compiled.protocol, &1)),
      do: Canonical.pathname(value),
      else: Canonical.opaque_pathname(value)
  end

  defp encode(_pattern, :hostname, value), do: Canonical.hostname(value)

  # ---------------------------------------------------------------------------
  # The errors of the Standard
  # ---------------------------------------------------------------------------

  describe "an error of a pattern" do
    test "is a TypeError" do
      for {input, base} <- [
            {%{pathname: "/:id/:id"}, nil},
            {%{pathname: "/(\\m)"}, nil},
            {%{hostname: "bad hostname"}, nil},
            {%{port: "100000"}, nil},
            {%{protocol: "(café)"}, nil},
            {%{pathname: "/foo", base_url: ""}, nil},
            {"/foo", nil},
            {"/foo", ""},
            {"https://foo{@example.com", nil},
            {%{pathname: "/foo"}, "https://example.com"}
          ] do
        assert_raise Web.TypeError, fn ->
          if base, do: URLPattern.new(input, base), else: URLPattern.new(input)
        end
      end
    end

    test "comes from a base URL in the second argument of a match with a map" do
      pattern = URLPattern.new(%{pathname: "/foo"})

      assert_raise Web.TypeError, fn ->
        URLPattern.test(pattern, %{pathname: "/foo"}, "https://x")
      end

      assert_raise Web.TypeError, fn -> URLPattern.exec(pattern, %{}, "https://x") end
    end

    test "comes from a value of a map that is not a string" do
      assert_raise Web.TypeError, fn -> URLPattern.new(%{pathname: 1}) end
    end
  end

  # ---------------------------------------------------------------------------
  # Pattern strings, base URLs, and results
  # ---------------------------------------------------------------------------

  describe "the pattern string of a component" do
    test "is the canonical text of the Standard" do
      for {input, component, expected} <- [
            {%{pathname: "/foo/(.*)"}, :pathname, "/foo/*"},
            {%{pathname: "/foo{/bar}"}, :pathname, "/foo/bar"},
            {%{pathname: ":foo\\bar"}, :pathname, "{:foo}bar"},
            {%{pathname: "*\\/*"}, :pathname, "*/{*}"},
            {%{pathname: "/foo\\:"}, :pathname, "/foo\\:"},
            {%{protocol: "(.*)"}, :protocol, "*"},
            {%{username: "café"}, :username, "caf%C3%A9"},
            {%{hostname: "café.com"}, :hostname, "xn--caf-dma.com"},
            {%{hostname: "[\\:\\:AB\\::num]"}, :hostname, "[\\:\\:ab\\::num]"},
            {%{protocol: "http", port: "80 "}, :port, "80"},
            {%{search: "?a", hash: "#b"}, :search, "a"},
            {%{search: "?a", hash: "#b"}, :hash, "b"},
            {"http://[\\:\\:1]/", :hostname, "[\\:\\:1]"},
            {"https://example.com/(foo\\?)bar", :pathname, "/(foo\\?)bar"}
          ] do
        assert Map.fetch!(URLPattern.new(input), component) == expected
      end
    end

    test "of a component that is not in a map matches all values" do
      pattern = URLPattern.new()

      for component <- @components, do: assert(Map.fetch!(pattern, component) == "*")
      assert URLPattern.test(pattern, "https://user:pw@example.com:8080/a?b#c")
    end
  end

  describe "a base URL" do
    test "gives the components that are less specific than the components of the map" do
      pattern =
        URLPattern.new(%{pathname: "/foo/bar", base_url: "https://example.com?query#hash"})

      assert {pattern.protocol, pattern.hostname, pattern.port} == {"https", "example.com", ""}
      assert {pattern.search, pattern.hash} == {"*", "*"}
      assert {pattern.username, pattern.password} == {"*", "*"}
    end

    test "gives the directory of a relative pathname" do
      pattern = URLPattern.new(%{pathname: "{/bar}", base_url: "https://example.com/foo/"})
      assert pattern.pathname == "/bar"

      pattern = URLPattern.new(%{pathname: "bar", base_url: "https://example.com/foo/x"})
      assert pattern.pathname == "/foo/bar"
    end

    test "of a pattern string makes a relative pattern string absolute" do
      pattern = URLPattern.new("../admin/*", "https://discussion.example/forum/?page=2")

      assert {pattern.protocol, pattern.hostname, pattern.pathname} ==
               {"https", "discussion.example", "/admin/*"}

      assert {pattern.search, pattern.hash} == {"*", "*"}
      assert URLPattern.new("?q", "https://example.com/a").pathname == "/a"
    end

    test "escapes the characters of the pattern syntax" do
      pattern = URLPattern.new(%{hash: "foo", base_url: "https://example.com/?q=*&v=?"})
      assert pattern.search == "q=\\*&v=\\?"
    end

    test "can also be the key :baseURL or \"baseURL\"" do
      for key <- [:baseURL, "baseURL", "base_url"] do
        pattern = URLPattern.new(%{"pathname" => "/a", key => "https://example.com"})
        assert pattern.hostname == "example.com"
      end
    end
  end

  test "has_reg_exp_groups?/1 tells if a component has a regular expression" do
    refute URLPattern.has_reg_exp_groups?(URLPattern.new())
    refute URLPattern.has_reg_exp_groups?(URLPattern.new(%{pathname: "/a/:foo/:baz?/b/*"}))
    assert URLPattern.has_reg_exp_groups?(URLPattern.new(%{pathname: "/:foo([a-z]+)?"}))
    assert URLPattern.has_reg_exp_groups?(URLPattern.new(%{hash: "(hi)"}))
  end

  describe "the result of exec/3" do
    test "has the inputs of the match" do
      pattern = URLPattern.new(%{pathname: "/u/:id"})
      url = Web.URL.new("https://x.com/u/7")

      assert URLPattern.exec(pattern, "https://x.com/u/7").inputs == ["https://x.com/u/7"]
      assert URLPattern.exec(pattern, "/u/7", "https://x.com").inputs == ["/u/7", "https://x.com"]
      assert URLPattern.exec(pattern, %{pathname: "/u/7"}).inputs == [%{pathname: "/u/7"}]
      assert URLPattern.exec(pattern, url).inputs == ["https://x.com/u/7"]
    end

    test "has the input and the groups of each component" do
      pattern = URLPattern.new("https://example.com/:x")
      result = URLPattern.exec(pattern, "https://example.com/y?q#h")

      assert result.protocol == %{input: "https", groups: %{}}
      assert result.pathname == %{input: "/y", groups: %{"x" => "y"}}
      assert result.search == %{input: "q", groups: %{"0" => "q"}}
      assert result.hash == %{input: "h", groups: %{"0" => "h"}}
      assert result.username == %{input: "", groups: %{"0" => ""}}
    end

    test "has nil for a group that does not take part in the match" do
      result =
        URLPattern.exec(URLPattern.new(%{hostname: "(sub.)?example.com"}), %{
          hostname: "example.com"
        })

      assert result.hostname.groups == %{"0" => nil}

      # ECMAScript does not accept an empty iteration of "(...)?".
      result = URLPattern.exec(URLPattern.new(%{pathname: "*{}**?"}), %{pathname: "foobar"})
      assert result.pathname.groups == %{"0" => "foobar", "1" => nil}

      # A group with a prefix keeps its empty text.
      result = URLPattern.exec(URLPattern.new(%{pathname: "/a{-(.*)}?"}), %{pathname: "/a-"})
      assert result.pathname.groups == %{"0" => ""}
    end

    test "canonicalizes the components of a map" do
      result = URLPattern.exec(URLPattern.new(), %{hostname: "mañana.example", pathname: "/a b"})

      assert result.hostname.input == "xn--maana-pta.example"
      assert result.pathname.input == "/a%20b"
    end

    test "is nil for an input that is not valid" do
      pattern = URLPattern.new()

      assert URLPattern.exec(pattern, "noscheme") == nil
      assert URLPattern.exec(pattern, "/foo", "data:text/plain,hello") == nil
      assert URLPattern.exec(pattern, "/foo", "http://[") == nil
      assert URLPattern.exec(pattern, %{hostname: "bad host"}) == nil
      assert URLPattern.exec(pattern, %{pathname: "/", base_url: "not a URL"}) == nil
      assert URLPattern.exec(pattern, 123) == nil
    end
  end

  test "test/3 returns a boolean" do
    pattern = URLPattern.new("https://example.com/foo")

    assert URLPattern.test(pattern, "https://example.com/foo")
    refute URLPattern.test(pattern, "https://example.com/bar")
    assert URLPattern.test(pattern, "/foo", "https://example.com")
    assert URLPattern.test(URLPattern.new(%{pathname: "*"}))
  end

  test "the option :ignore_case matches the text in all cases" do
    pattern = URLPattern.new(%{pathname: "/FOO/:id"}, %{ignore_case: true})
    assert URLPattern.test(pattern, %{pathname: "/foo/1"})

    pattern = URLPattern.new("https://example.com/FOO", %{ignore_case: true})
    assert URLPattern.test(pattern, "https://example.com/foo")
    refute URLPattern.test(URLPattern.new(%{pathname: "/FOO"}), %{pathname: "/foo"})
  end

  test "a pattern string can have the syntax of the components" do
    pattern = URLPattern.new("http{s}?://{:subdomain.}?shop.example/products/:id([0-9]+)#reviews")

    assert URLPattern.test(pattern, "https://kathryn@voyager.shop.example/products/74656#reviews")
    refute URLPattern.test(pattern, "https://shop.example/products/chair#reviews")

    # The username ends at "@": ":bar" is a named group, not a password.
    assert URLPattern.new("https://(foo):bar@example.com/").username == "(foo):bar"
  end

  test "a Web.Request matches with its URL" do
    request = Web.Request.new("https://example.com/items/7")
    pattern = URLPattern.new(%{pathname: "/items/:id"})

    assert URLPattern.exec(pattern, request)[:pathname][:groups] == %{"id" => "7"}
  end

  property "a pattern string of escaped text matches only the text" do
    check all(text <- string(:printable, min_length: 1, max_length: 12)) do
      pattern = URLPattern.new(%{hash: Compiler.escape_pattern_string(text)})
      expected = Canonical.hash(text)

      assert URLPattern.exec(pattern, %{hash: text}).hash == %{input: expected, groups: %{}}
      refute URLPattern.test(pattern, %{hash: text <> "x"})
    end
  end

  # ---------------------------------------------------------------------------
  # The functions of the library
  # ---------------------------------------------------------------------------

  describe "the cache" do
    test "gives the same struct for the same pattern" do
      assert URLPattern.new(%{pathname: "/foo/:id"}) == URLPattern.new(%{pathname: "/foo/:id"})
    end
  end

  describe "compare_component/3" do
    test "ranks the fixed text, the regular expressions, and the wildcards" do
      fixed = URLPattern.new(%{pathname: "/a"})
      regexp = URLPattern.new(%{pathname: "/:id(\\d+)"})
      segment = URLPattern.new(%{pathname: "/:id"})
      full = URLPattern.new(%{pathname: "/*"})

      assert URLPattern.compare_component(:pathname, fixed, regexp) == 1
      assert URLPattern.compare_component(:pathname, regexp, segment) == 1
      assert URLPattern.compare_component(:pathname, segment, full) == 1
      assert URLPattern.compare_component("pathname", full, full) == 0
    end

    test "raises ArgumentError for a name that is not a component" do
      pattern = URLPattern.new(%{pathname: "/"})

      assert_raise ArgumentError, ~r/Unknown URLPattern component/, fn ->
        URLPattern.compare_component("invalid", pattern, pattern)
      end

      assert_raise ArgumentError, ~r/Unknown URLPattern component/, fn ->
        URLPattern.compare_component(123, pattern, pattern)
      end
    end
  end
end
