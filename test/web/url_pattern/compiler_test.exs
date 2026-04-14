defmodule Web.URLPattern.CompilerTest do
  use ExUnit.Case, async: true

  alias Web.URLPattern.Compiler

  test "returns regex compile errors for invalid regex fragments" do
    assert {:error, message} = Compiler.compile([{:regex, "(", :none}], :pathname)
    assert message =~ "Regex compile failed"
  end

  test "rescues argument errors from malformed ast nodes" do
    assert {:error, message} = Compiler.compile([{:name, "id", 1, :none}], :pathname)
    assert message != ""
  end

  test "compiles literal, regex, and wildcard modifier fragments" do
    assert {:ok, %{regex: literal_regex}} = Compiler.compile([{:literal, "abc"}], :pathname)
    assert Regex.match?(literal_regex, "abc")

    assert {:ok, %{regex: regex_plus}} =
             Compiler.compile([{:regex, "a", :one_or_more}], :pathname)

    assert Regex.match?(regex_plus, "a/a")

    assert {:ok, %{regex: regex_star}} =
             Compiler.compile([{:regex, "a", :zero_or_more}], :pathname)

    assert Regex.match?(regex_star, "")
    assert Regex.match?(regex_star, "a/a")

    assert {:ok, %{regex: wildcard_plus}} =
             Compiler.compile([{:wildcard, :one_or_more}], :pathname)

    assert Regex.match?(wildcard_plus, "value")

    assert {:ok, %{regex: wildcard_star}} =
             Compiler.compile([{:wildcard, :zero_or_more}], :pathname)

    assert Regex.match?(wildcard_star, "")
  end

  test "uses the optional wildcard capture fragment for dot-star custom patterns" do
    assert {:ok, %{regex: regex}} =
             Compiler.compile([{:name, "id", ".*", :optional}], :pathname)

    assert Regex.match?(regex, "")
    assert Regex.match?(regex, "segment")
  end

  test "stringifies named patterns with modifiers" do
    assert Compiler.to_string([{:name, "id", "\\d+", :one_or_more}]) == ":id(\\d+)+"
  end
end
