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

  test "each legacy code is a constant, as the interface DOMException of Web IDL" do
    # The constants of Web IDL, in their sequence, and the name of each code.
    constants = [
      index_size_err: "IndexSizeError",
      domstring_size_err: nil,
      hierarchy_request_err: "HierarchyRequestError",
      wrong_document_err: "WrongDocumentError",
      invalid_character_err: "InvalidCharacterError",
      no_data_allowed_err: nil,
      no_modification_allowed_err: "NoModificationAllowedError",
      not_found_err: "NotFoundError",
      not_supported_err: "NotSupportedError",
      inuse_attribute_err: "InUseAttributeError",
      invalid_state_err: "InvalidStateError",
      syntax_err: "SyntaxError",
      invalid_modification_err: "InvalidModificationError",
      namespace_err: "NamespaceError",
      invalid_access_err: "InvalidAccessError",
      validation_err: nil,
      type_mismatch_err: "TypeMismatchError",
      security_err: "SecurityError",
      network_err: "NetworkError",
      abort_err: "AbortError",
      url_mismatch_err: "URLMismatchError",
      quota_exceeded_err: "QuotaExceededError",
      timeout_err: "TimeoutError",
      invalid_node_type_err: "InvalidNodeTypeError",
      data_clone_err: "DataCloneError"
    ]

    for {{function, name}, code} <- Enum.with_index(constants, 1) do
      assert apply(DOMException, function, []) == code
      if name, do: assert(DOMException.new("", name).code == code)
    end

    # The constants are all the functions with no argument, also the
    # default of `new/2`, and two internal functions.
    functions = for {name, 0} <- DOMException.__info__(:functions), do: name

    assert Enum.sort(functions) ==
             Enum.sort([
               :__struct__,
               :new,
               :abort_error,
               :timeout_error | Keyword.keys(constants)
             ])
  end

  test "raise with a name gives the name as the message, and the code of the name" do
    exception = assert_raise DOMException, fn -> raise DOMException, "NotFoundError" end

    assert {exception.name, exception.message, exception.code} ==
             {"NotFoundError", "NotFoundError", 8}

    exception = assert_raise DOMException, fn -> raise DOMException, message: "text" end
    assert {exception.name, exception.message, exception.code} == {"Error", "text", 0}
  end
end
