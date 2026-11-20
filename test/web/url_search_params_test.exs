defmodule Web.URLSearchParamsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.URL
  alias Web.URLSearchParams

  # Note: URLSearchParams tests in WPT are scattered across multiple .any.js files
  # rather than being in a single JSON data file like URL tests. For now, we rely
  # on the custom tests below to validate the implementation. Future work could
  # pull individual .any.js test files and adapt them.

  # ============================================================================
  # Custom protocol implementations (Enumerable, Access) - NOT covered by WPT
  # ============================================================================

  test "append, set, delete, sort, Enumerable, and Access protocols work together" do
    params =
      URLSearchParams.new([{"b", "2"}, {"a", "3"}, {"a", "1"}])
      |> URLSearchParams.append("c", "4")
      |> URLSearchParams.set("a", "9")

    assert params["a"] == "9"
    assert Enum.count(params) == 3
    assert Enum.to_list(params) == [{"b", "2"}, {"a", "9"}, {"c", "4"}]

    params = URLSearchParams.sort(params)
    assert Enum.to_list(params) == [{"a", "9"}, {"b", "2"}, {"c", "4"}]

    params = URLSearchParams.delete(params, "b")
    refute URLSearchParams.has?(params, "b")
    assert URLSearchParams.to_string(params) == "a=9&c=4"
  end

  test "supports Access protocol: get_and_update, pop, and bracket notation" do
    params = URLSearchParams.new(%{foo: "bar"})

    assert Access.fetch(params, "foo") == {:ok, "bar"}
    assert Access.fetch(params, "missing") == :error

    assert Access.get_and_update(params, "foo", fn current -> {current, "baz"} end) ==
             {"bar", %URLSearchParams{pairs: [{"foo", "baz"}]}}

    params = URLSearchParams.set(params, "foo", "baz")
    assert params["foo"] == "baz"

    assert Access.get_and_update(params, "foo", fn current -> {current, nil} end) ==
             {"baz", %URLSearchParams{pairs: []}}

    params = URLSearchParams.delete(params, "foo")
    params = URLSearchParams.set(params, "foo", "again")

    assert Access.get_and_update(params, "foo", fn _current -> :pop end) ==
             {"again", %URLSearchParams{pairs: []}}

    params = URLSearchParams.delete(params, "foo")
    assert Access.pop(params, "foo") == {nil, params}
  end

  test "supports map construction, default construction, and string conversion" do
    params = URLSearchParams.new(%{foo: "bar"})
    empty = URLSearchParams.new(nil)
    also_empty = URLSearchParams.new()

    assert URLSearchParams.has(params, "foo")
    assert Enum.empty?(empty)
    assert Enum.empty?(also_empty)
    assert Kernel.to_string(empty) == ""
    assert Kernel.to_string(also_empty) == ""

    refute Enum.member?(params, {"foo", "missing"})
    assert Enumerable.impl_for(params).slice(params) == {:error, Enumerable.Web.URLSearchParams}
  end

  test "preserves order, duplicate keys, and serializes using web encoding rules" do
    params = URLSearchParams.new("q=hello+world&tag=one&tag=two")

    assert URLSearchParams.get(params, "q") == "hello world"
    assert URLSearchParams.get_all(params, "tag") == ["one", "two"]
    assert URLSearchParams.has?(params, "tag")

    assert URLSearchParams.to_list(params) == [
             {"q", "hello world"},
             {"tag", "one"},
             {"tag", "two"}
           ]

    assert URLSearchParams.to_string(params) == "q=hello+world&tag=one&tag=two"
  end

  # ============================================================================
  # The rules of the URL Standard
  # ============================================================================

  test "the parser skips each empty sequence between two \"&\"" do
    for {input, pairs} <- [
          {"&", []},
          {"&a", [{"a", ""}]},
          {"a&", [{"a", ""}]},
          {"&&&a=b&&&&c=d&", [{"a", "b"}, {"c", "d"}]},
          {"?&a", [{"a", ""}]},
          {"=", [{"", ""}]},
          {"&=&", [{"", ""}]}
        ] do
      assert URLSearchParams.to_list(URLSearchParams.new(input)) == pairs, inspect(input)
    end
  end

  test "the parser decodes \"+\", percent-encoded bytes, and UTF-8 that is not valid" do
    for {input, pairs} <- [
          {"a+b=c+d", [{"a b", "c d"}]},
          {"%2B=%2b", [{"+", "+"}]},
          {"%61=%4D%4d", [{"a", "MM"}]},
          {"id=0&value=%", [{"id", "0"}, {"value", "%"}]},
          {"b=%2sf%2a", [{"b", "%2sf*"}]},
          {"%a_=a", [{"%a_", "a"}]},
          {"%FE%FF", [{"\uFFFD\uFFFD", ""}]},
          {"%C2x", [{"\uFFFDx", ""}]},
          {"%EF%BB%BFtest=%EF%BB%BF", [{"\uFEFFtest", "\uFEFF"}]},
          {"a==b", [{"a", "=b"}]}
        ] do
      assert URLSearchParams.to_list(URLSearchParams.new(input)) == pairs, inspect(input)
    end
  end

  test "a \"?\" at the start goes away only in the constructor" do
    assert URLSearchParams.to_list(URLSearchParams.new("??a=b")) == [{"?a", "b"}]

    url = Web.URL.new("https://example.com/??a=b&c=d")
    assert Web.URL.search(url) == "??a=b&c=d"
    assert URLSearchParams.to_list(Web.URL.search_params(url)) == [{"?a", "b"}, {"c", "d"}]

    url = Web.URL.search(url, "??x")
    assert URLSearchParams.to_list(Web.URL.search_params(url)) == [{"?x", ""}]
  end

  test "the serializer keeps the bytes * - . _ and the ASCII alphanumerics" do
    params = URLSearchParams.new([{"a*-._z", "A Z09"}, {"~!'()", "\u00E9\u{1F308}"}])

    assert URLSearchParams.to_string(params) ==
             "a*-._z=A+Z09&%7E%21%27%28%29=%C3%A9%F0%9F%8C%88"

    assert URLSearchParams.to_string(URLSearchParams.new([{"a+b", "%"}])) == "a%2Bb=%25"
  end

  test "sort/1 compares the UTF-16 code units, and keeps the sequence of equal names" do
    for {input, pairs} <- [
          {"\uFB03&\u{1F308}", [{"\u{1F308}", ""}, {"\uFB03", ""}]},
          {"z=b&a=b&z=a&a=a", [{"a", "b"}, {"a", "a"}, {"z", "b"}, {"z", "a"}]},
          {"\uFFFD=x&\uFFFC&\uFFFD=a", [{"\uFFFC", ""}, {"\uFFFD", "x"}, {"\uFFFD", "a"}]},
          {"bbb&bb&aaa&aa=x&aa=y",
           [{"aa", "x"}, {"aa", "y"}, {"aaa", ""}, {"bb", ""}, {"bbb", ""}]},
          {"z=z&=f&=t&=x", [{"", "f"}, {"", "t"}, {"", "x"}, {"z", "z"}]}
        ] do
      sorted = input |> URLSearchParams.new() |> URLSearchParams.sort()
      assert URLSearchParams.to_list(sorted) == pairs, inspect(input)
    end
  end

  test "sort/1 compares a name that is not valid UTF-8 as U+FFFD" do
    params = URLSearchParams.new([{<<0xFF>>, "1"}, {"\u{1F308}", "2"}, {"b", "3"}])

    assert URLSearchParams.to_list(URLSearchParams.sort(params)) ==
             [{"b", "3"}, {"\u{1F308}", "2"}, {<<0xFF>>, "1"}]
  end

  test "new/1 takes lists of two items, and refuses an item that is not a pair" do
    params = URLSearchParams.new([["a", "b"], ["c", 1], {"d", "e"}])
    assert URLSearchParams.to_list(params) == [{"a", "b"}, {"c", "1"}, {"d", "e"}]

    for item <- [[1], [1, 2, 3], [], "ab", {"a"}, {"a", "b", "c"}] do
      assert_raise Web.TypeError, ~r/must have two items/, fn ->
        URLSearchParams.new([["a", "b"], item])
      end
    end

    copy = URLSearchParams.new(params)
    assert copy == params
  end

  test "has/3 and delete/3 compare the value when it is not nil" do
    params = URLSearchParams.new("a=b&a=c&a=b&b=b")

    assert URLSearchParams.has(params, "a", "c")
    refute URLSearchParams.has(params, "a", "d")
    refute URLSearchParams.has(params, "b", "c")
    assert URLSearchParams.has(params, "a", nil)
    refute URLSearchParams.has(params, "c", nil)

    assert URLSearchParams.to_string(URLSearchParams.delete(params, "a", "b")) == "a=c&b=b"
    assert URLSearchParams.delete(params, "a", "d") == params
    assert URLSearchParams.to_string(URLSearchParams.delete(params, "a", nil)) == "b=b"
  end

  test "size/1 gives the number of pairs" do
    params = URLSearchParams.new("a=1&b=2&a=3")
    assert URLSearchParams.size(params) == 3
    assert URLSearchParams.size(URLSearchParams.delete(params, "a")) == 1
    assert URLSearchParams.size(URLSearchParams.append(params, "b", "4")) == 4
    assert URLSearchParams.size(URLSearchParams.new("&&")) == 0
  end

  # The "update steps" of the URL Standard: a change of the list of a URL
  # sets the query of the URL to the serialization of the list, and an empty
  # serialization is no query.
  describe "a change of the list of a URL" do
    defp change(url, fun), do: %{url | search_params: fun.(URL.search_params(url))}

    test "that empties the list removes the ? of the URL" do
      url =
        URL.new("http://example.com/?param1&param2")
        |> change(&URLSearchParams.delete(&1, "param1"))
        |> change(&URLSearchParams.delete(&1, "param2"))

      assert URL.href(url) == "http://example.com/"
      assert URL.search(url) == ""
    end

    test "that keeps an empty list removes the ? of the URL" do
      for fun <- [&URLSearchParams.delete(&1, "x"), &URLSearchParams.sort/1] do
        url = URL.new("http://example.com/?") |> change(fun)
        assert URL.href(url) == "http://example.com/"
      end
    end

    test "gives a query to a URL that has no query" do
      url = URL.new("http://example.com/") |> change(&URLSearchParams.append(&1, "a", "b c"))
      assert URL.href(url) == "http://example.com/?a=b+c"
    end

    test "keeps the opaque path and the fragment" do
      url = URL.new("data:space    ?test#test") |> change(&URLSearchParams.delete(&1, "test"))

      assert URL.pathname(url) == "space   %20"
      assert URL.href(url) == "data:space   %20#test"
    end

    test "does not change a URL with no change of its list" do
      assert URL.href(URL.new("http://example.com/?")) == "http://example.com/?"
      assert URL.href(URL.new("http://example.com/?a=b%20c")) == "http://example.com/?a=b%20c"

      url = URL.new("http://example.com/?x=1")
      assert URL.search_params(url) |> URLSearchParams.get("x") == "1"
      assert URL.href(url) == "http://example.com/?x=1"
    end

    test "can be a new list" do
      url = %{URL.new("http://example.com/?x=1") | search_params: URLSearchParams.new("a=1")}
      assert URL.href(url) == "http://example.com/?a=1"

      url = %{URL.new("http://example.com/?x=1") | search_params: URLSearchParams.new()}
      assert URL.href(url) == "http://example.com/"
    end

    property "gives a ? to the URL only when the serialization of the list is not empty" do
      check all(
              query <- one_of([constant(nil), string(:alphanumeric, max_length: 6)]),
              pairs <-
                list_of({string(:printable, max_length: 4), string(:printable, max_length: 4)},
                  max_length: 3
                )
            ) do
        url = URL.new("http://example.com/" <> if(query, do: "?" <> query, else: ""))

        url =
          change(url, fn params ->
            Enum.reduce(pairs, URLSearchParams.delete(params, "-"), fn {name, value}, acc ->
              URLSearchParams.append(acc, name, value)
            end)
          end)

        serialization = URLSearchParams.to_string(url.search_params)

        if serialization == "",
          do: assert(URL.href(url) == "http://example.com/"),
          else: assert(URL.href(url) == "http://example.com/?" <> serialization)
      end
    end
  end
end
