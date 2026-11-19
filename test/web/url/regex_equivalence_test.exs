defmodule Web.URL.RegexEquivalenceTest do
  # The URL code used regular expressions. It now uses binary pattern
  # matching. These properties compare each new function with the regular
  # expression of the first version, for random input. The regular
  # expressions stay only in this file.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Internal.Ascii
  alias Web.URL.Encoding
  alias Web.URL.URIParser

  # Text with many characters that the parsers examine.
  defp text(max_length \\ 24) do
    [
      ?a..?f,
      ?A..?F,
      ?0..?9,
      [?:, ?/, ??, ?#, ?@, ?[, ?], ?., ?+, ?-, ?_, ?%, ?\s, ?\n, ?\t, ?\r, ?|, ?\\, ?x, ?X, ?e],
      [0x00, 0x1F, 0x7F, 0xE9, 0x3002]
    ]
    |> Enum.flat_map(&Enum.to_list/1)
    |> member_of()
    |> list_of(max_length: max_length)
    |> map(&List.to_string/1)
  end

  property "URIParser.parse/1 gives the struct of URI.parse/1" do
    check all(value <- text(40), max_runs: 2_000) do
      assert URIParser.parse(value) == URI.parse(value)
    end

    for value <- [
          "",
          "//",
          "http:",
          "HTTP://User@Host:0080/p?q#f",
          "a://u@v@w:1",
          "x://[::1]:8080/path",
          "x://[::1]x:80",
          "x://[abc",
          "x://u\n@h/p#a\nb",
          "x://h:99999999",
          "1x://host",
          "mailto:a@b",
          "?q",
          "#f"
        ] do
      assert URIParser.parse(value) == URI.parse(value), inspect(value)
    end
  end

  property "trim_c0_whitespace/1 removes what the first regular expression removed" do
    check all(value <- text(), max_runs: 1_000) do
      expected = String.replace(value, ~r/^[\x00-\x20]+|[\x00-\x20]+$/u, "")
      assert Encoding.trim_c0_whitespace(value) == expected
    end
  end

  property "strip_ascii_tab_and_newline/1 removes what the first regular expression removed" do
    check all(value <- text(), max_runs: 1_000) do
      expected = String.replace(value, ~r/[\x09\x0A\x0D]/u, "")
      assert Encoding.strip_ascii_tab_and_newline(value) == expected
    end
  end

  test "the two trim functions raise ArgumentError for text that is not UTF-8" do
    assert_raise ArgumentError, "The URL is not valid UTF-8.", fn ->
      Encoding.trim_c0_whitespace(<<0xFF>>)
    end

    assert_raise ArgumentError, fn -> Encoding.strip_ascii_tab_and_newline(<<"a", 0xFF>>) end
    assert_raise ArgumentError, fn -> Web.URL.new("http://a.example/" <> <<0xFF>>) end
  end

  property "dot_segment_type/1 finds the dot segments of the first regular expression" do
    segment = [".", "%2e", "%2E", "%2", "e", "a", "%"] |> member_of() |> list_of(max_length: 4)

    check all(parts <- segment, max_runs: 1_000) do
      value = Enum.join(parts)

      expected =
        case Regex.replace(~r/%2e/i, value, ".") do
          "." -> :single
          ".." -> :double
          _other -> :none
        end

      assert Encoding.dot_segment_type(value) == expected
    end
  end

  property "the ASCII checks accept what the first regular expressions accepted" do
    check all(value <- text(), max_runs: 1_000) do
      no_newline = String.replace(value, "\n", "")

      assert Ascii.digits?(no_newline) == Regex.match?(~r/^\d+$/, no_newline)
      assert Ascii.octal_digits?(no_newline) == Regex.match?(~r/^[0-7]+$/, no_newline)
      assert Ascii.hex_digits?(no_newline) == Regex.match?(~r/^[0-9A-Fa-f]*$/, no_newline)

      assert Ascii.token?(no_newline) ==
               Regex.match?(~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/, no_newline)

      assert Ascii.ascii?(value) == (value == "" or Regex.match?(~r/^[\x00-\x7F]+$/, value))

      [digits] = Regex.run(~r/^\d*/, value)
      assert elem(Ascii.split_digits(value), 0) == digits
      assert Ascii.downcase(value) == lower_ascii(value)
    end
  end

  # A trailing line feed: "$" of a regular expression accepts it, and the
  # parsers remove each line feed before these checks.
  test "a check of digits does not accept a line feed at the end" do
    refute Ascii.digits?("12\n")
    assert Regex.match?(~r/^\d+$/, "12\n")
  end

  property "Web.Resolver accepts the remote names of the first regular expression" do
    check all(value <- text(), max_runs: 1_000) do
      expected =
        if String.match?(value, ~r/^[A-Za-z0-9][A-Za-z0-9+.-]*:(?!\/\/).*$/) do
          Web.Dispatcher.TCP
        else
          # The first version parsed each other input as a URL.
          try do
            value |> Web.URL.new() |> Web.Resolver.resolve()
          rescue
            ArgumentError -> Web.Dispatcher.HTTP
          end
        end

      assert Web.Resolver.resolve(value) == expected
    end
  end

  property "a status text is valid when the first regular expression accepted it" do
    check all(value <- text(), max_runs: 1_000) do
      expected = Regex.match?(~r/\A[\t \x21-\x7E\x80-\xFF]*\z/, value)

      result =
        try do
          Web.Response.new(status_text: value)
          true
        rescue
          Web.TypeError -> false
        end

      assert result == expected
    end
  end

  property "atob/1 refuses the text that the first regular expressions refused" do
    alphabet = [?A, ?z, ?0, ?+, ?/, ?=, ?=, ?\s, ?\n, ?\t, ?\f, ?\r, ?-, ?!]

    check all(chars <- list_of(member_of(alphabet), max_length: 12), max_runs: 2_000) do
      value = List.to_string(chars)
      trimmed = String.replace(value, ~r/[\t\n\f\r ]+/, "")

      invalid? =
        trimmed != "" and
          (Regex.match?(~r/[^A-Za-z0-9+\/=]/, trimmed) or Regex.match?(~r/=.+[^=]/, trimmed))

      if invalid? do
        assert_raise Web.TypeError, fn -> Web.atob(value) end
      end
    end
  end

  property "MIME types parse as before, other than a line feed inside a type" do
    parts = member_of(["text", "TEXT", "/", "html", ";", "a", "=", "b", "\"", " ", "\t", "x-y"])

    check all(chunks <- list_of(parts, max_length: 8), max_runs: 1_000) do
      value = Enum.join(chunks)
      # The new parser and the first parser differ only for a line feed in a
      # type: the first regular expression accepted "text\n" as a token.
      assert Web.MIME.parse(value) == Web.MIME.parse(value <> " ")
    end

    assert Web.MIME.parse("text\n/html") == nil
    assert Web.MIME.parse("Text/HTML;Charset=UTF-8") == "text/html;charset=UTF-8"
    assert_raise ArgumentError, fn -> Web.MIME.parse(<<"text/", 0xFF>>) end
  end

  property "the URL functions with no regular expression give the same URL" do
    hosts = member_of(["example.com", "EXAMPLE.org", "127.0.0.1", "0x7f.1", "[::1]", "xn--nxa"])

    check all(
            scheme <- member_of(["http", "https", "ws", "ftp", "file", "foo", "a_b"]),
            host <- hosts,
            port <- member_of(["", ":0", ":80", ":8080", ":99999"]),
            path <- text(12),
            max_runs: 500
          ) do
      input = "#{scheme}://#{host}#{port}/#{path}"

      case safe_url(input) do
        {:ok, url} ->
          # The serialized URL gives the same URL again.
          assert Web.URL.href(Web.URL.new(Web.URL.href(url))) == Web.URL.href(url)

        :error ->
          :ok
      end
    end
  end

  defp safe_url(input) do
    {:ok, Web.URL.new(input)}
  rescue
    ArgumentError -> :error
  end

  defp lower_ascii(value) do
    for <<char <- value>>, into: "", do: <<if(char in ?A..?Z, do: char + 32, else: char)>>
  end
end
