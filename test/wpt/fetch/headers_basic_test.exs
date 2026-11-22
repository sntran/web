# Port of web-platform-tests fetch/api/headers/headers-basic.any.js
# WPT revision 61ad038e419a0bfacee26801e584b5057c3fbd60
#
# Forms of JS in this file:
#   - `new Headers(init)` is `Web.Headers.new/1`. A JS sequence of pairs is a
#     list of `{name, value}` tuples. A JS record is a map.
#   - A `Web.Headers` is a value. A JS method that changes the headers is a
#     function that gives new headers.
#   - JS `null` is `nil`. JS `String(v)` is `string/1`: `nil` gives "null",
#     and each other value gives `to_string(v)`.
#   - `headers[Symbol.iterator]()` is the `Enumerable` protocol.
#     `headers.forEach(f)` is `Web.Headers.for_each/2`.
#
# Not ported:
#   - "Create headers from undefined parameter": Elixir has no `undefined`.
#     The form with no argument is in "Create headers from no parameter".
#   - "Create headers with existing headers with custom iterator": the test
#     puts a `Symbol.iterator` function on one object. An Elixir struct has
#     no iterator of its own.
#   - "Iteration skips elements removed while iterating",
#     "Removing elements already iterated over causes an element to be
#     skipped during iteration",
#     "Appending a value pair during iteration causes it to be reached during
#     iteration",
#     "Prepending a value pair before the current element position causes it
#     to be skipped during iteration and adds the current element a second
#     time": these tests change the headers during an iteration. A
#     `Web.Headers` cannot change. A change makes new headers, and the
#     iteration continues on the old headers.
#
# Parts of the ported tests that are not ported:
#   - The entry "name5" of `headerDict`. Its value is `undefined`, and Elixir
#     has no `undefined`.
#   - `checkIteratorProperties` in "Check keys method", "Check values method"
#     and "Check entries method". It examines the prototype chain and the
#     property descriptor of `next` of a JS iterator. An Elixir stream has no
#     prototype and no `next`. For the same reason, the check that `next()`
#     stays done after the end is not ported.

defmodule Web.WPT.Fetch.HeadersBasicTest do
  use ExUnit.Case, async: true

  alias Web.Headers

  # `headerDict` of the WPT file, as a list of pairs in the same sequence.
  # The entry "name5" (value `undefined`) is not in the list.
  @header_seq [
    {"name1", "value1"},
    {"name2", "value2"},
    {"name3", "value3"},
    {"name4", nil},
    {"name6", 1},
    {"Content-Type", "value4"}
  ]

  # `headerDict` as a record.
  @header_dict Map.new(@header_seq)

  # `String(v)` of JavaScript.
  defp string(nil), do: "null"
  defp string(value), do: to_string(value)

  # `headerEntriesDict` of the WPT file.
  @header_entries_dict %{
    "name1" => "value1",
    "Name2" => "value2",
    "name" => "value3",
    "content-Type" => "value4",
    "Content-Typ" => "value5",
    "Content-Types" => "value6"
  }

  @sorted_header_dict Map.new(@header_entries_dict, fn {name, value} ->
                        {String.downcase(name), value}
                      end)
  @header_values Map.values(@header_entries_dict)
  @sorted_header_keys @sorted_header_dict |> Map.keys() |> Enum.sort()

  test "Create headers from no parameter" do
    Headers.new()
  end

  test "Create headers from empty object" do
    Headers.new(%{})
  end

  test "Create headers with null should throw" do
    assert_raise Web.TypeError, fn -> Headers.new(nil) end
  end

  test "Create headers with 1 should throw" do
    assert_raise Web.TypeError, fn -> Headers.new(1) end
  end

  test "Create headers with sequence" do
    headers = Headers.new(@header_seq)

    for {name, value} <- @header_seq do
      assert Headers.get(headers, name) == string(value),
             "name: #{name} has value: #{inspect(value)}"
    end

    assert Headers.get(headers, "length") == nil,
           "init should be treated as a sequence, not as a dictionary"
  end

  test "Create headers with record" do
    headers = Headers.new(@header_dict)

    for {name, value} <- @header_seq do
      assert Headers.get(headers, name) == string(value),
             "name: #{name} has value: #{inspect(value)}"
    end
  end

  test "Create headers with existing headers" do
    headers = Headers.new(@header_dict)
    headers2 = Headers.new(headers)

    for {name, value} <- @header_seq do
      assert Headers.get(headers2, name) == string(value),
             "name: #{name} has value: #{inspect(value)}"
    end
  end

  test "Check append method" do
    Enum.reduce(@header_seq, Headers.new(), fn {name, value}, headers ->
      headers = Headers.append(headers, name, value)

      assert Headers.get(headers, name) == string(value),
             "name: #{name} has value: #{inspect(value)}"

      headers
    end)
  end

  test "Check set method" do
    Enum.reduce(@header_seq, Headers.new(), fn {name, value}, headers ->
      headers = Headers.set(headers, name, value)

      assert Headers.get(headers, name) == string(value),
             "name: #{name} has value: #{inspect(value)}"

      headers
    end)
  end

  test "Check has method" do
    headers = Headers.new(@header_dict)

    for {name, _value} <- @header_seq do
      assert Headers.has(headers, name), "headers has name #{name}"
    end

    refute Headers.has(headers, "nameNotInHeaders"),
           "headers do not have header: nameNotInHeaders"
  end

  test "Check delete method" do
    Enum.reduce(@header_seq, Headers.new(@header_dict), fn {name, _value}, headers ->
      assert Headers.has(headers, name), "headers have a header: #{name}"
      headers = Headers.delete(headers, name)
      refute Headers.has(headers, name), "headers do not have anymore a header: #{name}"
      headers
    end)
  end

  test "Check get method" do
    headers = Headers.new(@header_dict)

    for {name, value} <- @header_seq do
      assert Headers.get(headers, name) == string(value),
             "name: #{name} has value: #{inspect(value)}"
    end

    assert Headers.get(headers, "nameNotInHeaders") == nil,
           "header: nameNotInHeaders has no value"
  end

  test "Check keys method" do
    headers = Headers.new(@header_entries_dict)
    actual = Headers.keys(headers)

    # The iteration gives each key in sorted sequence, and then it stops.
    assert Enum.to_list(actual) == @sorted_header_keys

    for key <- Headers.keys(headers) do
      assert key in @sorted_header_keys
    end
  end

  test "Check values method" do
    headers = Headers.new(@header_entries_dict)
    actual = Headers.values(headers)

    # The iteration gives the value of each key in sorted sequence, and then
    # it stops.
    assert Enum.to_list(actual) == Enum.map(@sorted_header_keys, &@sorted_header_dict[&1])

    for value <- Headers.values(headers) do
      assert value in @header_values
    end
  end

  test "Check entries method" do
    headers = Headers.new(@header_entries_dict)
    actual = Headers.entries(headers)

    # The iteration gives each pair in the sequence of the sorted keys, and
    # then it stops.
    assert Enum.to_list(actual) ==
             Enum.map(@sorted_header_keys, &{&1, @sorted_header_dict[&1]})

    for {name, value} <- Headers.entries(headers) do
      assert value == @sorted_header_dict[name]
    end
  end

  test "Check Symbol.iterator method" do
    headers = Headers.new(@header_entries_dict)

    # The iteration gives each pair in the sequence of the sorted keys, and
    # then it stops.
    assert Enum.to_list(headers) ==
             Enum.map(@sorted_header_keys, &{&1, @sorted_header_dict[&1]})
  end

  test "Check forEach method" do
    headers = Headers.new(@header_entries_dict)
    test_pid = self()

    Headers.for_each(headers, fn value, key, object ->
      send(test_pid, {:for_each, key, value, object})
    end)

    # Each message has the same form. Thus `assert_received` gets the oldest
    # message, and the sequence of the messages is the sequence of the calls.
    for expected_key <- @sorted_header_keys do
      assert_received {:for_each, key, value, object}
      assert key == expected_key
      assert value == @sorted_header_dict[expected_key]
      assert object == headers
    end

    refute_received {:for_each, _key, _value, _object}
  end
end
