defmodule Web.IterableTest do
  # The members of the pair iterables of Web IDL: `entries`, `keys`,
  # `values`, and `forEach`, for `Web.Headers`, `Web.URLSearchParams`, and
  # `Web.FormData`.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.FormData
  alias Web.Headers
  alias Web.URLSearchParams

  defp pairs do
    list_of(tuple({string([?a..?c], min_length: 1, max_length: 2), string(:alphanumeric)}),
      max_length: 6
    )
  end

  # The arguments of each call of the callback, in the sequence of the calls.
  defp calls(for_each, object, arity) do
    test = self()
    ref = make_ref()

    callback =
      case arity do
        0 -> fn -> send(test, {ref, []}) end
        1 -> fn value -> send(test, {ref, [value]}) end
        2 -> fn value, key -> send(test, {ref, [value, key]}) end
        3 -> fn value, key, object -> send(test, {ref, [value, key, object]}) end
      end

    assert for_each.(object, callback) == :ok
    collect(ref, [])
  end

  defp collect(ref, acc) do
    receive do
      {^ref, args} -> collect(ref, [args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The arguments that Web IDL gives: « value, key, object », and the first
  # `arity` of them for a callback with fewer arguments.
  defp expected(pairs, object, arity) do
    for {key, value} <- pairs, do: Enum.take([value, key, object], arity)
  end

  property "for_each/2 calls the callback with the value, the name, and the object" do
    check all(pairs <- pairs(), arity <- integer(0..3)) do
      params = URLSearchParams.new(pairs)
      assert calls(&URLSearchParams.for_each/2, params, arity) == expected(pairs, params, arity)

      form =
        Enum.reduce(pairs, FormData.new(), fn {k, v}, form -> FormData.append(form, k, v) end)

      assert calls(&FormData.for_each/2, form, arity) == expected(pairs, form, arity)

      # The pairs of headers are the pairs of "sort and combine".
      headers = Headers.new(pairs)
      combined = Enum.to_list(Headers.entries(headers))
      assert calls(&Headers.for_each/2, headers, arity) == expected(combined, headers, arity)
    end
  end

  property "keys/1, values/1, and entries/1 give the parts of the pairs in their sequence" do
    check all(pairs <- pairs()) do
      params = URLSearchParams.new(pairs)
      assert Enum.to_list(URLSearchParams.entries(params)) == pairs
      assert Enum.to_list(URLSearchParams.keys(params)) == Enum.map(pairs, &elem(&1, 0))
      assert Enum.to_list(URLSearchParams.values(params)) == Enum.map(pairs, &elem(&1, 1))

      form =
        Enum.reduce(pairs, FormData.new(), fn {k, v}, form -> FormData.append(form, k, v) end)

      assert Enum.to_list(FormData.entries(form)) == Enum.map(pairs, &Tuple.to_list/1)
      assert Enum.to_list(FormData.keys(form)) == Enum.map(pairs, &elem(&1, 0))
      assert Enum.to_list(FormData.values(form)) == Enum.map(pairs, &elem(&1, 1))
    end
  end

  test "the members of a parsed form read the entries of its stream" do
    boundary = "b"

    body =
      ~s(--b\r\ncontent-disposition: form-data; name="a"\r\n\r\n1\r\n) <>
        ~s(--b\r\ncontent-disposition: form-data; name="f"; filename="f.txt"\r\n\r\nbytes\r\n) <>
        "--b--\r\n"

    form = FormData.parse(body, boundary)
    assert Enum.to_list(FormData.keys(form)) == ["a", "f"]

    form = FormData.parse(body, boundary)
    assert ["1", %Web.File{name: "f.txt"}] = Enum.to_list(FormData.values(form))

    form = FormData.parse(body, boundary)
    assert [["1", "a"], [%Web.File{}, "f"]] = calls(&FormData.for_each/2, form, 2)
  end

  test "for_each/2 raises Web.TypeError for a callback that is not a function of arity 0 to 3" do
    for callback <- [nil, :callback, fn _a, _b, _c, _d -> :ok end] do
      for {for_each, object} <- [
            {&URLSearchParams.for_each/2, URLSearchParams.new("a=1")},
            {&FormData.for_each/2, FormData.append(FormData.new(), "a", "1")},
            {&Headers.for_each/2, Headers.new(%{"a" => "1"})}
          ] do
        assert_raise Web.TypeError, ~r/^The callback of forEach must be a function/, fn ->
          for_each.(object, callback)
        end
      end
    end
  end

  test "FormData converts nil to the text \"null\", and refuses a file name for a string" do
    form = FormData.new() |> FormData.append(nil, nil) |> FormData.set("a", nil)

    assert Enum.to_list(form) == [["null", "null"], ["a", "null"]]
    assert FormData.get(form, nil) == "null"
    assert FormData.get_all(form, nil) == ["null"]
    assert FormData.has(form, nil)
    refute form |> FormData.delete(nil) |> FormData.has("null")

    # The overload `append(name, blobValue, filename)` takes only a blob.
    for fun <- [&FormData.append/4, &FormData.set/4] do
      assert_raise Web.TypeError, ~r/must be a Blob/, fn -> fun.(form, "a", "text", "a.txt") end
    end

    blob = Web.Blob.new(["x"])

    assert %Web.File{name: "a.txt"} =
             form |> FormData.set("f", blob, "a.txt") |> FormData.get("f")
  end

  test "for_each/2 gives an exception of the callback to the caller, and stops" do
    params = URLSearchParams.new("a=1&b=2")
    test = self()

    assert_raise RuntimeError, "stop at a", fn ->
      URLSearchParams.for_each(params, fn value, name ->
        send(test, {:called, name, value})
        raise "stop at #{name}"
      end)
    end

    assert_received {:called, "a", "1"}
    refute_received {:called, "b", _value}
  end
end
