# Port of web-platform-tests fetch/api/headers/headers-errors.any.js
# WPT revision 61ad038e419a0bfacee26801e584b5057c3fbd60
#
# Forms of JS in this file:
#   - `new Headers(init)` is `Web.Headers.new/1`. A JS sequence of
#     sequences is a list of tuples.
#   - A JS object `{}` is the map `%{}`. JS converts `{}` to the name
#     "[object Object]", which is not a valid header name. Elixir does not
#     convert a map to a name. The two give a TypeError.
#   - The JS string "invalidĀ" has the code point U+0100. In Elixir it is
#     the UTF-8 bytes of the same text. JS gives a TypeError when it
#     converts the string to a ByteString. Elixir does not do this
#     conversion. But the bytes 0xC4 0x80 are not token bytes. Thus the
#     Fetch Standard refuses them in a header name, and the name tests
#     can show the TypeError.
#   - `headers.forEach(f)` is `Enum.each(headers, f)`. A JS `throw` of a
#     string is `throw/1`.
#
# Not ported:
#   - "Create headers giving bad header value as init argument",
#     "Check headers set with an invalid value invalidĀ",
#     "Check headers append with an invalid value invalidĀ": the TypeError
#     comes only from the JS conversion to a ByteString (the code point
#     U+0100 is not a byte). An Elixir string is a sequence of bytes, and
#     the Fetch Standard permits the bytes 0x80 to 0xFF in a header value.
#     Elixir cannot give a value that is not a sequence of bytes.
#   - "Headers forEach throws if argument is not callable": the library has
#     no `forEach` function. `Enum.each/2` of Elixir does the check of the
#     argument, not the library. Elixir also has no `undefined` and no call
#     with a missing argument.

defmodule Web.WPT.Fetch.HeadersErrorsTest do
  use ExUnit.Case, async: true

  alias Web.Headers

  # `badNames` of the WPT file, with the name that WPT gives to each one in
  # the test names.
  @bad_names [{"invalidĀ", "invalidĀ"}, {%{}, "[object Object]"}]

  test "Create headers giving an array having one string as init argument" do
    assert_raise Web.TypeError, fn -> Headers.new([{"name"}]) end
  end

  test "Create headers giving an array having three strings as init argument" do
    assert_raise Web.TypeError, fn ->
      Headers.new([{"invalid", "invalidValue1", "invalidValue2"}])
    end
  end

  test "Create headers giving bad header name as init argument" do
    assert_raise Web.TypeError, fn -> Headers.new([{"invalidĀ", "Value1"}]) end
  end

  for {name, label} <- @bad_names do
    @name name

    test "Check headers get with an invalid name #{label}" do
      headers = Headers.new()
      assert_raise Web.TypeError, fn -> Headers.get(headers, @name) end
    end
  end

  for {name, label} <- @bad_names do
    @name name

    test "Check headers delete with an invalid name #{label}" do
      headers = Headers.new()
      assert_raise Web.TypeError, fn -> Headers.delete(headers, @name) end
    end
  end

  for {name, label} <- @bad_names do
    @name name

    test "Check headers has with an invalid name #{label}" do
      headers = Headers.new()
      assert_raise Web.TypeError, fn -> Headers.has(headers, @name) end
    end
  end

  for {name, label} <- @bad_names do
    @name name

    test "Check headers set with an invalid name #{label}" do
      headers = Headers.new()
      assert_raise Web.TypeError, fn -> Headers.set(headers, @name, "Value1") end
    end
  end

  # The WPT file uses the name "invalidĀ" in each test of this loop, not the
  # name of the loop. The port does the same.
  for {_name, label} <- @bad_names do
    test "Check headers append with an invalid name #{label}" do
      headers = Headers.new()
      assert_raise Web.TypeError, fn -> Headers.append(headers, "invalidĀ", "Value1") end
    end
  end

  test "Headers forEach loop should stop if callback is throwing exception" do
    headers = Headers.new([{"name1", "value1"}, {"name2", "value2"}, {"name3", "value3"}])
    counter = :counters.new(1, [])

    result =
      try do
        Enum.each(headers, fn {name, _value} ->
          :counters.add(counter, 1, 1)
          if name == "name2", do: throw("error")
        end)

        :not_thrown
      catch
        :throw, error -> {:thrown, error}
      end

    # WPT calls `assert_unreached()` when the callback does not throw.
    assert {:thrown, error} = result
    assert :counters.get(counter, 1) == 2
    assert error == "error"
  end
end
