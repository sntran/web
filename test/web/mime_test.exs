defmodule Web.MIMETest do
  use ExUnit.Case, async: true
  import Web, only: [await: 1]

  use Web.Platform.Test,
    urls: [
      "https://raw.githubusercontent.com/web-platform-tests/wpt/master/mimesniff/mime-types/resources/mime-types.json"
    ],
    prefix: "Response MIME Sniffing WPT compliance"

  alias Web.MIME
  alias Web.Response

  @impl Web.Platform.Test
  def web_platform_test(%{"input" => input, "output" => expected_mime} = test_case)
      when is_binary(input) and is_binary(expected_mime) do
    run_mime_sniffing_test!(test_case, input, expected_mime)
  end

  def web_platform_test(
        %{"header" => _header, "input" => _input, "output" => _output} = test_case
      ) do
    run_mime_sniffing_with_header_test!(test_case)
  end

  def web_platform_test(_test_case), do: :ok

  test "parse and essence handle nil and invalid inputs" do
    assert MIME.parse(nil) == nil
    assert MIME.parse("plain") == nil

    assert MIME.essence(nil) == nil
    assert MIME.essence("plain") == nil
    assert MIME.essence("Text/Plain; Charset=UTF-8") == "text/plain"
  end

  test "parse skips invalid parameters and preserves trailing backslashes" do
    assert MIME.parse("text/plain;") == "text/plain"
    assert MIME.parse("text/plain;   ") == "text/plain"
    assert MIME.parse("text/plain;;") == "text/plain"
    assert MIME.parse("text/plain; ;") == "text/plain"
    assert MIME.parse("text/plain; charset =utf-8;foo=bar") == "text/plain;foo=bar"
    assert MIME.parse("text/plain; char@set=utf-8;foo=bar") == "text/plain;foo=bar"
    assert MIME.parse("text/plain; charset;foo=bar") == "text/plain;foo=bar"
    assert MIME.parse("text/plain;a=foo\\") == "text/plain;a=\"foo\\\\\""
  end

  test "parse handles empty, duplicate, and quoted parameters" do
    assert MIME.parse("text/plain;;charset=\"utf-8\";charset=ignored;foo=bar") ==
             "text/plain;charset=utf-8;foo=bar"

    assert MIME.parse("text/plain;a=;foo=bar") == "text/plain;foo=bar"
    assert MIME.parse("text/plain;bad\"name=1;foo=bar") == "text/plain;foo=bar"
    assert MIME.parse("text/plain;a=\"b\\\\c\"") == "text/plain;a=\"b\\\\c\""
    assert MIME.parse("text/plain;a=\"") == "text/plain;a=\"\""
    assert MIME.parse("text/plain;a=\"b\\") == "text/plain;a=\"b\\\\\""
  end

  test "generic_binary handles nil and normalized values" do
    assert MIME.generic_binary?(nil)
    assert MIME.generic_binary?("")
    assert MIME.generic_binary?(" application/octet-stream ; charset=utf-8")
    refute MIME.generic_binary?("text/plain")
  end

  test "sniff detects supported signatures" do
    assert MIME.sniff(" <!doctype html><html>") == "text/html"
    assert MIME.sniff("<?xml version=\"1.0\"?><root/>") == "text/xml"
    assert MIME.sniff(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00>>) == "image/png"
    assert MIME.sniff(<<0xFF, 0xD8, 0xFF, 0x00>>) == "image/jpeg"
    assert MIME.sniff("GIF87a payload") == "image/gif"
    assert MIME.sniff("GIF89a payload") == "image/gif"
    assert MIME.sniff("%PDF-1.7\n") == "application/pdf"
    assert MIME.sniff("  {\"ok\":true}") == "application/json"
    assert MIME.sniff("plain text") == "application/octet-stream"
  end

  test "sniff accepts iodata" do
    assert MIME.sniff(["[", "1", "]"]) == "application/json"
  end

  test "blob/1 uses MIME parsing and sniffing for response bodies" do
    response =
      Response.new(
        body: "<!doctype html><html><head></head><body>x</body></html>",
        headers: [{"content-type", "application/octet-stream"}]
      )

    {response, clone} = Response.clone(response)
    blob = await(Response.blob(response))

    assert blob.type == "text/html"
    assert await(Response.text(clone)) =~ "<html>"
  end

  defp run_mime_sniffing_test!(_test_case, input, expected_mime) do
    actual_mime = MIME.parse(input) || ""

    if normalize_mime_type(actual_mime) == normalize_mime_type(expected_mime) do
      :ok
    else
      raise ExUnit.AssertionError,
        message:
          "MIME sniffing mismatch for input #{inspect(String.slice(input, 0..50))}: expected #{inspect(expected_mime)}, got #{inspect(actual_mime)}"
    end
  end

  defp run_mime_sniffing_with_header_test!(test_case) do
    input = Map.get(test_case, "input")
    header = Map.get(test_case, "header")
    expected_mime = Map.get(test_case, "output")

    if is_nil(input) or is_nil(header) or is_nil(expected_mime) do
      :ok
    else
      response = Response.new(body: input, headers: [{"content-type", header}])
      actual_mime = await(Response.blob(response)).type

      if normalize_mime_type(actual_mime) == normalize_mime_type(expected_mime) do
        :ok
      else
        raise ExUnit.AssertionError,
          message:
            "MIME sniffing with header mismatch: expected #{inspect(expected_mime)}, got #{inspect(actual_mime)}"
      end
    end
  end

  defp normalize_mime_type(mime) do
    mime
    |> String.downcase()
    |> String.trim()
  end
end
