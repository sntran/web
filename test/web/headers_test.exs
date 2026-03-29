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
      assert apply(Headers, :getSetCookie, [headers]) == ["a=1", "b=2"]
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

      assert Enum.map(headers, fn {name, value} -> {name, value} end) == [{"a", "1, 2"}, {"b", "3"}]
      assert Enum.count(headers) == 2
      assert Enum.member?(headers, {"a", "1, 2"})
    end

    test "Enumerable slice reports unsupported slicing" do
      headers = Headers.new(%{"a" => "1"})
      impl = Enumerable.impl_for!(headers)

      assert impl.slice(headers) == {:error, impl}
    end
  end
end
