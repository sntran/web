defmodule Web.ErrorTest do
  use ExUnit.Case, async: true

  # The errors of ECMAScript take the option `cause` of their constructor.

  test "RangeError has a message and a cause" do
    assert %Web.RangeError{message: "out", cause: nil} = Web.RangeError.exception("out")

    assert %Web.RangeError{message: "out", cause: :reason} =
             Web.RangeError.exception(message: "out", cause: :reason)

    error = assert_raise Web.RangeError, fn -> raise Web.RangeError, message: "x", cause: 1 end
    assert error.cause == 1
    assert Exception.message(error) == "x"
  end

  test "AggregateError has errors, a message, and a cause" do
    error = %Web.AggregateError{errors: [:a, :b]}
    assert Exception.message(error) =~ "All promises were rejected"
    assert Exception.message(error) =~ ":a"
    assert error.cause == nil

    error = Web.AggregateError.exception(errors: [:a], message: "two failed", cause: :first)
    assert Exception.message(error) == "two failed"
    assert error.cause == :first
  end
end
