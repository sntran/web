defmodule Web.HeadersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Headers

  describe "new/1" do
    property "creates empty headers safely" do
      check all(empty <- constant(%{})) do
        assert Headers.new(empty).data == %{}
        assert Headers.new().data == %{}
      end
    end

    property "initializes from maps case-insensitively" do
      check all(
              key <- string(:alphanumeric, min_length: 1),
              val <- string(:alphanumeric, min_length: 1)
            ) do
        headers = Headers.new(%{String.upcase(key) => val})
        assert Headers.get(headers, String.downcase(key)) == val
      end
    end

    test "initializes from duplicate tuples by appending values" do
      headers = Headers.new([{"X-Test", "1"}, {"x-test", "2"}])

      assert headers.data == %{"x-test" => ["1", "2"]}
      assert Headers.get(headers, "X-Test") == "1, 2"
      assert Headers.to_list(headers) == [{"x-test", "1"}, {"x-test", "2"}]
    end

    test "initializes from existing struct idempotently" do
      base = Headers.new(%{"a" => "b"})
      assert Headers.new(base) == base
    end

    test "normalizes atom keys and values" do
      headers = Headers.new(%{key: :val})
      assert Headers.get(headers, "KEY") == "val"
    end
  end

  describe "header operations" do
    test "set/get/has/delete are case-insensitive" do
      headers =
        Headers.new()
        |> Headers.set("X-Test", 1)

      assert Headers.has(headers, "x-test")
      assert Headers.get(headers, "x-test") == "1"
      refute Headers.has(Headers.delete(headers, "X-TEST"), "x-test")
    end

    test "append joins multiple values for get/2" do
      headers =
        Headers.new()
        |> Headers.append("Accept", "text/plain")
        |> Headers.append("accept", "application/json")

      assert headers.data == %{"accept" => ["text/plain", "application/json"]}
      assert Headers.get(headers, "ACCEPT") == "text/plain, application/json"
    end

    test "set replaces appended values" do
      headers =
        Headers.new()
        |> Headers.append("x-test", "1")
        |> Headers.append("x-test", "2")
        |> Headers.set("X-Test", "3")

      assert headers.data == %{"x-test" => ["3"]}
      assert Headers.get(headers, "x-test") == "3"
    end

    test "get_set_cookie returns all set-cookie values" do
      headers =
        Headers.new()
        |> Headers.append("Set-Cookie", "a=1")
        |> Headers.append("set-cookie", "b=2")

      assert Headers.get(headers, "set-cookie") == "a=1, b=2"
      assert Headers.get_set_cookie(headers) == ["a=1", "b=2"]
      assert Headers.getSetCookie(headers) == ["a=1", "b=2"]
    end

    test "missing headers return nil by default" do
      assert Headers.get(Headers.new(), "missing") == nil
      assert Headers.get(Headers.new(), "missing", :default) == :default
    end
  end

  describe "Access behaviour implementation" do
    test "fetch and square-bracket access use normalized lookups" do
      headers = Headers.new(%{"Content-Type" => "text/plain"})

      assert headers["content-type"] == "text/plain"
      assert Headers.fetch(headers, "CONTENT-TYPE") == {:ok, "text/plain"}
      assert headers["missing"] == nil
      assert Headers.fetch(headers, "missing") == :error
    end

    test "get_and_update stores a replacement value" do
      headers = Headers.new()
      {nil, updated} = get_and_update_in(headers["a"], fn current -> {current, "b"} end)

      assert updated["a"] == "b"
    end

    test "get_and_update can pop a value" do
      headers = Headers.new(%{"a" => "b"})
      {"b", updated} = get_and_update_in(headers["a"], fn _ -> :pop end)

      assert updated["a"] == nil
    end

    test "pop removes a value" do
      headers = Headers.new(%{"a" => "b"})
      {"b", updated} = pop_in(headers["a"])

      assert updated["a"] == nil
    end
  end

  describe "iteration" do
    test "entries, keys, and values expose combined iterator views" do
      headers =
        Headers.new()
        |> Headers.append("B", "2")
        |> Headers.append("A", "1")
        |> Headers.append("A", "3")

      assert Enum.to_list(Headers.entries(headers)) == [{"a", "1, 3"}, {"b", "2"}]
      assert Enum.to_list(Headers.keys(headers)) == ["a", "b"]
      assert Enum.to_list(Headers.values(headers)) == ["1, 3", "2"]
    end

    test "Enumerable allows Enum functions directly on headers" do
      headers =
        Headers.new()
        |> Headers.append("A", "1")
        |> Headers.append("A", "2")
        |> Headers.set("B", "3")

      assert Enum.map(headers, fn {name, value} -> {name, value} end) == [
               {"a", "1, 2"},
               {"b", "3"}
             ]

      assert Enum.count(headers) == 2
      assert Enum.member?(headers, {"a", "1, 2"})
    end

    test "Enumerable slice reports unsupported slicing" do
      headers = Headers.new(%{"a" => "1"})
      impl = Enumerable.impl_for!(headers)

      assert impl.slice(headers) == {:error, impl}
    end
  end

  describe "the checks of the Fetch Standard" do
    test "refuse a name that is not an HTTP token, in each function" do
      headers = Headers.new(%{"a" => "1"})

      for name <- ["", "bad name", "a:b", "a\r\n", "é", "a(b", 1, nil, {"a"}] do
        for fun <- [
              fn -> Headers.new([{name, "x"}]) end,
              fn -> Headers.append(headers, name, "x") end,
              fn -> Headers.set(headers, name, "x") end,
              fn -> Headers.get(headers, name) end,
              fn -> Headers.has(headers, name) end,
              fn -> Headers.delete(headers, name) end
            ] do
          assert_raise Web.TypeError, ~r/Invalid header name/, fun
        end
      end
    end

    test "accept each character of an HTTP token in a name" do
      name = "!#$%&'*+-.^_`|~09AZaz"
      headers = Headers.new([{name, "x"}])
      assert Headers.get(headers, name) == "x"
      assert Enum.to_list(Headers.keys(headers)) == [String.downcase(name)]
    end

    test "refuse a value with a NUL, CR, or LF character" do
      for value <- ["a\r\nb: c", "a\nb", "a\rb", <<"a", 0, "b">>] do
        assert_raise Web.TypeError, ~r/Invalid header value/, fn ->
          Headers.new([{"x-test", value}])
        end

        assert_raise Web.TypeError, ~r/Invalid header value/, fn ->
          Headers.set(Headers.new(), "x-test", value)
        end
      end

      assert_raise Web.TypeError, ~r/Invalid header value/, fn ->
        Headers.new([{"x-test", %{}}])
      end
    end

    test "remove the HTTP whitespace at the two ends of a value" do
      headers = Headers.new([{"x-test", " \t\r\n a  b \n\r\t "}, {"x-empty", " \t "}])
      assert Headers.get(headers, "x-test") == "a  b"
      assert Headers.get(headers, "x-empty") == ""
    end

    test "accept a value that is a number or an atom" do
      headers = Headers.new([{"content-length", 12}, {"x-flag", true}])
      assert Headers.get(headers, "content-length") == "12"
      assert Headers.get(headers, "x-flag") == "true"
    end

    test "append the values of map keys that are the same name" do
      headers = Headers.new(%{"X-Test" => "1", "x-test" => "2"})
      assert Headers.get(headers, "x-test") |> String.split(", ") |> Enum.sort() == ["1", "2"]
    end

    test "refuse input that is not a collection of pairs" do
      assert_raise Web.TypeError, ~r/Each header must be a pair/, fn ->
        Headers.new(["a"])
      end

      assert_raise Web.TypeError, ~r/Headers must be/, fn -> Headers.new("a: b") end
    end

    property "a valid name and value are kept, with the name in lowercase" do
      token = string([?a..?z, ?A..?Z, ?0..?9, ?-, ?_], min_length: 1)
      value = string([0x21..0x7E], min_length: 1)

      check all(name <- token, value <- value) do
        headers = Headers.new([{name, value}])
        assert Headers.get(headers, name) == value
        assert Headers.has(headers, String.upcase(name))
        assert Enum.to_list(headers) == [{String.downcase(name), value}]
      end
    end

    property "each text is accepted with the standard result, or raises TypeError" do
      check all(name <- string(:printable), value <- string(:printable)) do
        try do
          Headers.new([{name, value}])
        rescue
          error in Web.TypeError -> assert error.message =~ "Invalid header"
        else
          headers ->
            [{stored_name, stored_value}] = Enum.to_list(headers)
            assert stored_name == String.downcase(name, :ascii)
            assert stored_value == String.trim(value, " ") |> trim_http_whitespace()
            refute stored_value =~ ~r/[\0\r\n]/
        end
      end
    end

    defp trim_http_whitespace(value) do
      value
      |> String.replace(~r/\A[\t\n\r ]+/, "")
      |> String.replace(~r/[\t\n\r ]+\z/, "")
    end
  end

  describe "inspect" do
    test "redacts sensitive header values" do
      output =
        Headers.new(%{
          "authorization" => "secret",
          "cookie" => "a=1",
          "set-cookie" => "b=2",
          "proxy-authorization" => "token",
          "x-safe" => "ok"
        })
        |> Kernel.inspect()

      assert output =~ "[REDACTED]"
      refute output =~ "secret"
      refute output =~ "a=1"
      refute output =~ "b=2"
      refute output =~ "token"
      assert output =~ "ok"
    end
  end
end
