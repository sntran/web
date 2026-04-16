defmodule Web.URL.EncodingTest do
  use ExUnit.Case, async: true

  use Web.Platform.Test,
    urls: [
      "https://raw.githubusercontent.com/web-platform-tests/wpt/master/url/resources/toascii.json",
      "https://raw.githubusercontent.com/web-platform-tests/wpt/master/url/resources/percent-encoding.json"
    ],
    prefix: "URL Encoding WPT compliance"

  alias Web.URL.{Encoding, IP}

  @impl Web.Platform.Test
  def web_platform_test(%{"input" => input, "output" => output} = test_case)
      when is_map(output) do
    run_percent_encoding_test!(test_case, input, output)
  end

  def web_platform_test(%{"input" => input, "output" => output} = test_case)
      when is_binary(output) or is_nil(output) do
    run_host_ascii_test!(test_case, input, output)
  end

  def web_platform_test(test_case) when is_binary(test_case) do
    run_simple_encoding_test!(test_case)
  end

  def web_platform_test(_test_case), do: :ok

  defp run_simple_encoding_test!(_test_case), do: :ok

  defp run_host_ascii_test!(test_case, input, expected_output) do
    if String.contains?(Map.get(test_case, "comment", ""), "(ignored)") do
      :ok
    else
      failure = Map.get(test_case, "failure", false)

      actual =
        if IP.valid_host?(input, "https:") do
          IP.normalize_host(input, "https:")
        else
          nil
        end

      cond do
        failure and is_nil(actual) ->
          :ok

        failure ->
          raise ExUnit.AssertionError,
            message:
              "Expected host parsing to fail for #{inspect(input)}, but got #{inspect(actual)}"

        actual == expected_output ->
          :ok

        true ->
          raise ExUnit.AssertionError,
            message:
              "Host ASCII mismatch for #{inspect(input)}: expected #{inspect(expected_output)}, got #{inspect(actual)}"
      end
    end
  end

  defp run_percent_encoding_test!(_test_case, input, outputs) do
    case Map.get(outputs, "utf-8") do
      nil ->
        :ok

      expected ->
        actual = Encoding.percent_encode_utf8(input)

        if actual == expected do
          :ok
        else
          raise ExUnit.AssertionError,
            message:
              "UTF-8 percent-encoding mismatch for #{inspect(input)}: expected #{inspect(expected)}, got #{inspect(actual)}"
        end
    end
  end

  test "encoding preserves percent escapes and encodes unicode bytes" do
    assert Encoding.percent_encode_non_ascii("%2F☃") == "%2F%E2%98%83"
    assert Encoding.percent_encode_utf8("%2F \u007F") == "%2F%20%7F"

    assert Encoding.normalize_special_path_separators("a\\b?c\\d#e\\f", true) ==
             "a/b?c\\d#e\\f"
  end
end
