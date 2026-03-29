defmodule Web.HeadersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Headers

  describe "initialization" do
    property "creates empty headers safely" do
      check all empty <- constant(%{}) do
        assert Headers.new(empty).headers == %{}
        assert Headers.new().headers == %{}
      end
    end

    property "initializes from list and normalizes keys" do
      check all key <- string(:alphanumeric, min_length: 1),
                val <- string(:alphanumeric, min_length: 1) do
        k_str = to_string(key)
        v_str = to_string(val)
        headers = Headers.new([{k_str, v_str}])
        assert Headers.get(headers, String.downcase(k_str)) == v_str
      end
    end

    test "initializes from existing struct idempotently" do
      base = Headers.new(%{"a" => "b"})
      assert Headers.new(base) == base
    end

    test "initializes from atom keys" do
      headers = Headers.new(%{key: "val"})
      assert Headers.get(headers, "key") == "val"
    end
  end

  describe "Access behaviour implementation" do
    property "fetch and element referencing handle presence correctly" do
      check all h_map_raw <- map_of(string(:alphanumeric, min_length: 1), string(:alphanumeric, min_length: 1)) do
        h_map = h_map_raw |> Enum.uniq_by(fn {k, _} -> String.downcase(k) end) |> Map.new()
        h = Headers.new(h_map)
        
        for {k, v} <- h_map do
          k_down = String.downcase(k)
          assert ^v = h[k_down]
        end

        assert h["non_existent"] == nil
        assert Headers.fetch(h, "non_existent") == :error
      end
    end

    test "get_and_update" do
      h = Headers.new()
      {nil, h2} = get_and_update_in(h["a"], fn current -> {current, "b"} end)
      assert h2["a"] == "b"

      {"b", h3} = get_and_update_in(h2["a"], fn _ -> :pop end)
      assert h3["a"] == nil
    end

    test "pop" do
      h = Headers.new(%{"a" => "b"})
      {"b", h2} = pop_in(h["a"])
      assert h2["a"] == nil
    end

    test "put, get, has_key?, delete, to_list directly" do
      h = Headers.new()
      h = Headers.put(h, "FOO", "bar")
      assert Headers.has_key?(h, "foo")
      assert Headers.get(h, "fOO") == "bar"
      
      h = Headers.delete(h, "Foo")
      refute Headers.has_key?(h, "foo")
      
      h = Headers.put(h, :atom_key, "val")
      assert Headers.to_list(h) == [{"atom_key", "val"}]
    end
  end
end
