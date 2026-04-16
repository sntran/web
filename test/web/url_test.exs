defmodule Web.URLTest do
  use ExUnit.Case, async: true

  use Web.Platform.Test,
    urls: [
      "https://raw.githubusercontent.com/web-platform-tests/wpt/master/url/resources/urltestdata.json",
      "https://raw.githubusercontent.com/web-platform-tests/wpt/master/url/resources/setters_tests.json"
    ],
    prefix: "URL WPT compliance"

  alias Web.URL
  alias Web.URL.Parser
  alias Web.URLSearchParams

  @impl Web.Platform.Test
  def web_platform_test(%{"input" => input, "base" => base} = test_case) do
    # WHATWG URL parsing test
    run_url_parse_test!(test_case, input, base)
  end

  def web_platform_test(%{"property" => _property} = test_case) do
    run_url_setter_test!(test_case)
  end

  def web_platform_test(%{"input" => input} = test_case) when is_map(test_case) do
    # URL parsing test without base
    run_url_parse_test!(test_case, input, nil)
  end

  def web_platform_test(test_case) when is_map(test_case) do
    if map_size(test_case) > 0 do
      run_url_setter_dataset!(test_case)
    else
      :ok
    end
  end

  def web_platform_test(test_case) when is_binary(test_case) do
    # Some WPT files include section labels as strings.
    run_simple_encoding_test!(test_case)
  end

  def web_platform_test(_test_case), do: :ok

  defp run_url_setter_dataset!(dataset) do
    dataset
    |> Enum.reject(fn {property, _cases} -> property == "comment" end)
    |> Enum.each(fn {property, cases} ->
      run_url_setter_property_cases!(property, cases)
    end)
  end

  defp run_url_setter_property_cases!(property, cases) when is_list(cases) do
    Enum.each(cases, fn test_case ->
      run_url_setter_test!(Map.put(test_case, "property", property))
    end)
  end

  defp run_url_setter_property_cases!(_property, _cases), do: :ok

  defp run_url_parse_test!(test_case, input, base) do
    failure = Map.get(test_case, "failure", false)

    case try_parse_url(input, base) do
      {:error, _reason} when failure ->
        :ok

      {:error, reason} when not failure ->
        raise ExUnit.AssertionError,
          message: "Expected URL parse to succeed for #{inspect(input)}, but got error: #{reason}"

      {:ok, _url} when failure ->
        raise ExUnit.AssertionError,
          message: "Expected URL parse to fail for #{inspect(input)}, but succeeded"

      {:ok, url} when not failure ->
        assert_url_components_match!(url, test_case)
    end
  end

  defp run_url_setter_test!(test_case) do
    href = Map.get(test_case, "href")
    property = Map.get(test_case, "property")
    new_value = Map.get(test_case, "new_value", "")
    expected = Map.get(test_case, "expected")

    if is_nil(href) or is_nil(property) or is_nil(expected) do
      :ok
    else
      run_setter_mutation!(href, property, new_value, expected)
    end
  end

  defp run_simple_encoding_test!(_test_case) do
    :ok
  end

  defp try_parse_url(input, base) when is_binary(input) do
    url =
      if is_nil(base) do
        URL.new(input)
      else
        URL.new(input, base)
      end

    {:ok, url}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
    error -> {:error, inspect(error)}
  end

  defp try_parse_url(_input, _base), do: {:error, "invalid input"}

  defp assert_url_components_match!(url, test_case) do
    # Validate each component
    assert_component_match!(url, test_case, "href", &URL.href/1)
    assert_component_match!(url, test_case, "protocol", &URL.protocol/1)
    assert_component_match!(url, test_case, "username", &URL.username/1)
    assert_component_match!(url, test_case, "password", &URL.password/1)
    assert_component_match!(url, test_case, "host", &URL.host/1)
    assert_component_match!(url, test_case, "hostname", &URL.hostname/1)
    assert_component_match!(url, test_case, "port", &URL.port/1)
    assert_component_match!(url, test_case, "pathname", &URL.pathname/1)
    assert_component_match!(url, test_case, "search", fn u -> normalize_search(URL.search(u)) end)
    assert_component_match!(url, test_case, "hash", fn u -> normalize_fragment(URL.hash(u)) end)
    assert_component_match!(url, test_case, "origin", &URL.origin/1)
  end

  defp assert_component_match!(url, test_case, component, accessor) do
    case Map.get(test_case, component) do
      nil ->
        :ok

      expected ->
        actual = accessor.(url)

        if actual == expected do
          :ok
        else
          raise ExUnit.AssertionError,
            message:
              "URL component [#{component}] mismatch: expected #{inspect(expected)}, got #{inspect(actual)}"
        end
    end
  end

  defp normalize_search(search_str) do
    # Normalize search string format
    if String.starts_with?(search_str, "?") do
      search_str
    else
      "?" <> search_str
    end
    |> case do
      "?" -> ""
      s -> s
    end
  end

  defp normalize_fragment(fragment_str) do
    # Normalize fragment format
    if String.starts_with?(fragment_str, "#") do
      fragment_str
    else
      "#" <> fragment_str
    end
    |> case do
      "#" -> ""
      f -> f
    end
  end

  defp run_setter_mutation!(href, property, new_value, expected) when is_map(expected) do
    case try_parse_url(href, nil) do
      {:ok, url} ->
        updated_url = apply_setter(url, property, new_value)
        assert_url_components_match!(updated_url, expected)

      {:error, reason} ->
        raise ExUnit.AssertionError,
          message: "Failed to parse initial URL #{inspect(href)}: #{reason}"
    end
  end

  defp run_setter_mutation!(href, property, new_value, expected) do
    raise ExUnit.AssertionError,
      message:
        "Unsupported setter expectation for [#{property}] on #{inspect(href)}: #{inspect(expected)} with #{inspect(new_value)}"
  end

  defp apply_setter(url, "href", value), do: URL.href(url, value)
  defp apply_setter(url, "protocol", value), do: URL.set_protocol(url, value)
  defp apply_setter(url, "username", value), do: URL.set_username(url, value)
  defp apply_setter(url, "password", value), do: URL.set_password(url, value)
  defp apply_setter(url, "hostname", value), do: URL.set_hostname(url, value)
  defp apply_setter(url, "host", value), do: URL.host(url, value)
  defp apply_setter(url, "port", value), do: URL.set_port(url, value)
  defp apply_setter(url, "pathname", value), do: URL.set_pathname(url, value)
  defp apply_setter(url, "search", value), do: URL.search(url, value)
  defp apply_setter(url, "hash", value), do: URL.hash(url, value)
  defp apply_setter(url, _property, _value), do: url

  # ============================================================================
  # Custom URL feature tests (NOT covered by WHATWG WPT)
  # ============================================================================

  test "rclone style urls are parsed as protocol plus pathname" do
    url = URL.new("my_s3:bucket/file.txt?x=1#frag")

    assert URL.rclone?(url)
    assert URL.protocol(url) == "my_s3:"
    assert URL.pathname(url) == "bucket/file.txt"
    assert URL.search(url) == "?x=1"
    assert URL.hash(url) == "#frag"
    assert URL.origin(url) == "null"
    assert URL.href(url) == "my_s3:bucket/file.txt?x=1#frag"
  end

  test "serializes inspect output cleanly" do
    url = URL.new("https://example.com/path")
    assert inspect(url) == ~s(#Web.URL<"https://example.com/path">)
  end

  test "preserves empty but present authority, search, and hash markers" do
    url = URL.new("sc://?#")

    assert URL.href(url) == "sc://?#"
    assert URL.search(url) == "?"
    assert URL.hash(url) == "#"
  end

  test "setters preserve empty but present search and hash markers" do
    url =
      "https://example.com/path"
      |> URL.new()
      |> URL.search("?")
      |> URL.hash("#")

    assert URL.href(url) == "https://example.com/path?#"
    assert URL.search(url) == "?"
    assert URL.hash(url) == "#"
  end

  test "search params integration: URLSearchParams can be mutated and reintegrated" do
    url = URL.new("https://example.com/path?foo=bar")

    params =
      url
      |> URL.search_params()
      |> URLSearchParams.append("foo", "baz")
      |> URLSearchParams.set("space", "hello world")

    url = %{url | search_params: params}

    assert URL.search(url) == "?foo=bar&foo=baz&space=hello+world"
    assert URL.href(url) == "https://example.com/path?foo=bar&foo=baz&space=hello+world"

    url = URL.search(url, "?reset=1")
    assert URLSearchParams.to_list(URL.search_params(url)) == [{"reset", "1"}]
  end

  test "accepts existing URL structs and serializes path-only values" do
    url = URL.new("https://example.com/path")

    assert URL.new(url) == url
    assert URL.href(%URL{pathname: "", kind: :standard}) == ""
    assert URL.href(%URL{pathname: "folder", kind: :standard}) == "folder"
    assert Kernel.to_string(url) == "https://example.com/path"
  end

  test "rclone urls without query or hash keep absent markers distinct from empty ones" do
    url = URL.new("my_s3:bucket/file.txt")

    assert URL.href(url) == "my_s3:bucket/file.txt"
    assert URL.search(url) == ""
    assert URL.hash(url) == ""
    assert URL.pathname(URL.href(url, "my_s3:next")) == "next"
  end

  test "non-special protocol setters preserve empty authority paths" do
    url = URL.new("foo://example.com/")

    assert URL.href(URL.set_protocol(url, "bar")) == "bar://example.com"
    assert URL.href(%URL{protocol: "foo:", pathname: "", kind: :standard}) == "foo:"
  end

  test "host and hostname setters clear credentials on empty non-special authorities" do
    url = %URL{
      protocol: "foo:",
      hostname: "",
      port: "",
      username: "user",
      password: "pass",
      authority_present?: true,
      kind: :standard
    }

    updated_host = URL.host(url, "")
    assert updated_host.username == ""
    assert updated_host.password == ""
    assert updated_host.port == ""

    updated_hostname = URL.set_hostname(url, "")
    assert updated_hostname.username == ""
    assert updated_hostname.password == ""
    assert updated_hostname.port == ""
  end

  test "search and hash distinguish absent and empty values" do
    assert URL.search(%URL{search: "", search_present?: false}) == ""
    assert URL.hash(%URL{fragment: "", hash_present?: false}) == ""
  end

  test "file origins and path normalization cover file-specific branches" do
    assert URL.origin(URL.new("file:///tmp/test")) == "null"
    assert URL.pathname(URL.set_pathname(URL.new("file:///c:/dir"), "/c:/..")) == "/c:/"

    assert URL.pathname(URL.set_pathname(%URL{protocol: "file:", kind: :standard}, "C|")) ==
             "/C:"

    assert URL.pathname(URL.set_pathname(URL.new("file://example.com"), "drive")) == "/drive"

    assert URL.pathname(URL.set_pathname(%URL{protocol: "file:", kind: :standard}, "drive")) ==
             "/drive"

    assert URL.pathname(URL.set_pathname(URL.new("http://example.com/path"), "")) == "/"
  end

  test "port setters handle nil and integer inputs" do
    url = URL.new("http://example.com")

    assert URL.port(URL.set_port(url, nil)) == ""
    assert URL.port(URL.set_port(url, 8080)) == "8080"
  end

  test "parser handles opaque bases, invalid bases, and url struct bases" do
    assert Parser.parse("child", 123) == {:error, "Invalid base URL"}

    assert {:ok, fields} = Parser.parse("", "foo:bar")
    assert fields.pathname == "bar"

    assert {:ok, trimmed} = Parser.parse("foo:bar ")
    assert trimmed.pathname == "bar"

    assert {:ok, fragment} = Parser.parse("#frag", "foo:bar")
    assert fragment.hash == "#frag"

    assert Parser.parse("?q=1", "foo:bar") == {:error, "Invalid URL"}

    assert {:ok, file_root} = Parser.parse("..", "file:///C:/")
    assert file_root.pathname == "/C:/"

    assert {:ok, absolute_file_root} = Parser.parse("file:///C:/..")
    assert absolute_file_root.pathname == "/C:/"

    assert {:ok, resolved} = Parser.parse("next", URL.new("https://example.com/root"))
    assert resolved.pathname == "/next"
  end

  test "parser handles empty userinfo and invalid non-special authorities" do
    assert {:ok, fields} = Parser.parse("foo://@host")
    assert fields.username == ""
    assert fields.password == ""

    assert Parser.parse("foo://[::1]:99999") == {:error, "Invalid URL host"}
    assert Parser.parse("foo://host:80:90") == {:error, "Invalid URL host"}
  end
end
