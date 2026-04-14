defmodule Web.URLPattern.ParserTest do
  use ExUnit.Case, async: true

  alias Web.URLPattern.Parser

  test "parses wildcard modifiers" do
    assert {:ok, [{:wildcard, :zero_or_more}]} = Parser.parse("**")
  end

  test "rejects a missing name after colon" do
    assert {:error, "Expected name after ':'"} = Parser.parse(":")
  end

  test "rejects unterminated regex groups" do
    assert {:error, "Unterminated regex group"} = Parser.parse("(")
  end

  test "rejects nested groups" do
    assert {:error, "Nested groups are not allowed in URLPattern"} = Parser.parse("{a{b}}")
  end

  test "rejects names that start with digits" do
    assert {:error, message} = Parser.parse(":1foo")
    assert message =~ "Name cannot start with a digit"
  end

  test "rejects recursive regex patterns" do
    assert {:error, message} = Parser.parse("((?R))")
    assert message =~ "Recursive regex patterns are not allowed"
  end
end
