defmodule Web.DOMExceptionTest do
  use ExUnit.Case, async: true

  alias Web.DOMException

  doctest Web.DOMException

  describe "new/2" do
    test "gives the legacy code of each name of the table, and 0 for each other name" do
      codes = %{
        "IndexSizeError" => 1,
        "HierarchyRequestError" => 3,
        "NotFoundError" => 8,
        "InvalidStateError" => 11,
        "SyntaxError" => 12,
        "AbortError" => 20,
        "QuotaExceededError" => 22,
        "TimeoutError" => 23,
        "DataCloneError" => 25,
        "EncodingError" => 0,
        "NotAllowedError" => 0,
        "MyOwnError" => 0
      }

      for {name, code} <- codes do
        assert %DOMException{name: ^name, message: "text", code: ^code} =
                 DOMException.new("text", name)
      end
    end

    test "has the default name Error, and the default message is empty" do
      assert %DOMException{name: "Error", message: "message", code: 0} =
               DOMException.new("message")

      assert Exception.message(DOMException.new()) == ""
    end

    test "gives an exception that can be raised" do
      assert_raise DOMException, "The operation was aborted.", fn ->
        raise DOMException.new("The operation was aborted.", "AbortError")
      end
    end
  end

  test "raise with a name gives the name as the message, and the code of the name" do
    exception = assert_raise DOMException, fn -> raise DOMException, "NotFoundError" end

    assert {exception.name, exception.message, exception.code} ==
             {"NotFoundError", "NotFoundError", 8}

    exception = assert_raise DOMException, fn -> raise DOMException, message: "text" end
    assert {exception.name, exception.message, exception.code} == {"Error", "text", 0}
  end
end
