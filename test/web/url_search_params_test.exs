defmodule Web.URLSearchParamsTest do
  use ExUnit.Case, async: true

  alias Web.URLSearchParams

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

  test "append, set, delete, sort, Enumerable, and Access all work together" do
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

  test "supports map construction, default construction, aliases, Access helpers, and string conversion" do
    params = URLSearchParams.new(%{foo: "bar"})
    empty = URLSearchParams.new(nil)
    also_empty = URLSearchParams.new()

    assert URLSearchParams.has(params, "foo")
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
    assert Enum.empty?(params)
    refute Enum.member?(params, {"foo", "baz"})
    assert Enumerable.impl_for(params).slice(params) == {:error, Enumerable.Web.URLSearchParams}
    assert Kernel.to_string(empty) == ""
    assert Kernel.to_string(also_empty) == ""
  end
end
