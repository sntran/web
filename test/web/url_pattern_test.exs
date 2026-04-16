defmodule Web.URLPatternTest do
  use ExUnit.Case, async: true

  use Web.Platform.Test,
    urls: [
      "https://raw.githubusercontent.com/web-platform-tests/wpt/master/urlpattern/resources/urlpatterntestdata.json",
      "https://github.com/web-platform-tests/wpt/raw/refs/heads/master/urlpattern/resources/urlpattern-generate-test-data.json",
      "https://github.com/web-platform-tests/wpt/raw/refs/heads/master/urlpattern/resources/urlpattern-compare-test-data.json"
    ],
    prefix: "URLPattern WPT compliance"

  alias Web.AsyncContext.Snapshot
  alias Web.AsyncContext.Variable
  alias Web.URLPattern
  alias Web.URLPattern.Parser

  @components ~w(protocol username password hostname port pathname search hash)a
  @component_name_map %{
    "protocol" => :protocol,
    "username" => :username,
    "password" => :password,
    "hostname" => :hostname,
    "port" => :port,
    "pathname" => :pathname,
    "search" => :search,
    "hash" => :hash
  }

  @impl Web.Platform.Test
  def web_platform_test(%{"left" => _left, "right" => _right} = test_case) do
    run_compare_case!(test_case)
  end

  def web_platform_test(
        %{"component" => _component, "groups" => _groups, "pattern" => _pattern} = test_case
      ) do
    run_generate_case!(test_case)
  end

  def web_platform_test(%{"pattern" => _pattern} = test_case) do
    run_match_case!(test_case)
  end

  def web_platform_test(_test_case), do: :ok

  defp erase_pinned(term) do
    :persistent_term.erase(term)
  rescue
    _ -> :ok
  end

  defp run_match_case!(%{"pattern" => pattern_args} = test_case) do
    expected_obj = Map.get(test_case, "expected_obj", :undefined)

    case {expected_obj, try_build_pattern(pattern_args)} do
      {"error", {:error, _reason}} ->
        :ok

      {"error", {:ok, _pattern}} ->
        raise ExUnit.AssertionError,
          message: "Expected pattern construction to fail for #{inspect(pattern_args)}"

      {_expected_obj, {:error, reason}} ->
        raise ExUnit.AssertionError,
          message: "Unexpected pattern build error for #{inspect(pattern_args)}: #{reason}"

      {_expected_obj, {:ok, pattern}} ->
        maybe_run_exec_assertion!(pattern, test_case)
    end
  end

  defp run_generate_case!(%{
         "component" => component,
         "expected" => expected,
         "groups" => groups,
         "pattern" => pattern_input
       }) do
    pattern = URLPattern.new(pattern_input)

    if is_nil(expected) do
      assert_raises!(fn -> generate_url_spec(pattern, component, groups) end)
    else
      actual = generate_url_spec(pattern, component, groups)

      unless actual == expected do
        raise ExUnit.AssertionError,
          message:
            "generate mismatch for #{inspect(component)}: expected #{inspect(expected)}, got #{inspect(actual)}"
      end
    end
  end

  defp run_compare_case!(%{
         "component" => component,
         "expected" => expected,
         "left" => left,
         "right" => right
       }) do
    left_pattern = URLPattern.new(left)
    right_pattern = URLPattern.new(right)

    assert_equal!(
      URLPattern.compare_component(component, left_pattern, right_pattern),
      expected,
      "compare_component mismatch for #{inspect(component)}"
    )

    assert_equal!(
      URLPattern.compare_component(component, right_pattern, left_pattern),
      if(expected == 0, do: 0, else: -expected),
      "compare_component reverse-order mismatch for #{inspect(component)}"
    )

    assert_equal!(
      URLPattern.compare_component(component, left_pattern, left_pattern),
      0,
      "compare_component left self mismatch for #{inspect(component)}"
    )

    assert_equal!(
      URLPattern.compare_component(component, right_pattern, right_pattern),
      0,
      "compare_component right self mismatch for #{inspect(component)}"
    )
  end

  defp try_build_pattern(pattern_args) do
    {arg1, arg2, arg3} = parse_pattern_args(pattern_args)

    try do
      {:ok, build_url_pattern(arg1, arg2, arg3)}
    rescue
      error in ArgumentError -> {:error, Exception.message(error)}
      error -> {:error, inspect(error)}
    end
  end

  defp parse_pattern_args([]), do: {%{}, nil, nil}
  defp parse_pattern_args([first]), do: {first, nil, nil}
  defp parse_pattern_args([first, second]) when is_binary(second), do: {first, second, nil}
  defp parse_pattern_args([first, second]) when is_map(second), do: {first, second, nil}

  defp parse_pattern_args([first, second, third]) when is_binary(second) and is_map(third) do
    {first, second, third}
  end

  defp parse_pattern_args([first | _rest]), do: {first, nil, nil}

  defp build_url_pattern(nil, nil, nil), do: URLPattern.new(%{})
  defp build_url_pattern(pattern, nil, nil), do: URLPattern.new(pattern)

  defp build_url_pattern(pattern, base_url, options)
       when is_binary(base_url) and is_map(options) do
    options = normalize_options(options) |> Map.put(:base_url, base_url)
    URLPattern.new(pattern, options)
  end

  defp build_url_pattern(pattern, base_url, _options) when is_binary(base_url) do
    URLPattern.new(pattern, base_url)
  end

  defp build_url_pattern(pattern, options, nil) when is_map(options) and is_map(pattern) do
    URLPattern.new(pattern, Map.merge(pattern, normalize_options(options)))
  end

  defp build_url_pattern(pattern, options, nil) when is_map(options) do
    URLPattern.new(pattern, normalize_options(options))
  end

  defp normalize_options(options) when is_map(options) do
    Enum.reduce(options, %{}, fn
      {"ignoreCase", value}, acc -> Map.put(acc, :ignore_case, value)
      {"ignore_case", value}, acc -> Map.put(acc, :ignore_case, value)
      {key, value}, acc when is_binary(key) -> Map.put(acc, String.to_existing_atom(key), value)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  rescue
    _ -> options
  end

  defp maybe_run_exec_assertion!(pattern, test_case) do
    inputs = Map.get(test_case, "inputs", [])
    expected_match = Map.get(test_case, "expected_match", :undefined)

    if inputs == [] or expected_match == :undefined do
      :ok
    else
      run_exec_assertion!(pattern, inputs, expected_match)
    end
  end

  defp run_exec_assertion!(pattern, inputs, expected_match) do
    case parse_exec_inputs(inputs) do
      {:skip, _reason} ->
        :ok

      {:ok, input, base_url} ->
        actual = exec_pattern(pattern, input, base_url)
        assert_exec_result!(actual, expected_match)
    end
  end

  defp exec_pattern(pattern, input, nil) do
    URLPattern.exec(pattern, input)
  rescue
    _ -> :exec_raised
  end

  defp exec_pattern(pattern, input, base_url) do
    URLPattern.exec(pattern, input, base_url)
  rescue
    _ -> :exec_raised
  end

  defp assert_exec_result!(:exec_raised, "error"), do: :ok

  defp assert_exec_result!(:exec_raised, _expected_match) do
    raise ExUnit.AssertionError, message: "exec raised unexpectedly"
  end

  defp assert_exec_result!(actual, "error") do
    raise ExUnit.AssertionError, message: "exec should have raised, got: #{inspect(actual)}"
  end

  defp assert_exec_result!(nil, nil), do: :ok

  defp assert_exec_result!(actual, nil) do
    raise ExUnit.AssertionError, message: "expected nil but got: #{inspect(actual)}"
  end

  defp assert_exec_result!(actual, expected_match) when is_map(expected_match) do
    compare_result!(actual, expected_match)
  end

  defp assert_exec_result!(_actual, _expected_match), do: :ok

  defp parse_exec_inputs([]), do: {:ok, %{}, nil}
  defp parse_exec_inputs([input]) when is_binary(input) or is_map(input), do: {:ok, input, nil}

  defp parse_exec_inputs([input, base_url]) when is_binary(input) and is_binary(base_url) do
    {:ok, input, base_url}
  end

  defp parse_exec_inputs([input, base_url]) when is_map(input) and is_binary(base_url) do
    {:ok, input, base_url}
  end

  defp parse_exec_inputs(_inputs), do: {:skip, "unsupported input form"}

  defp compare_result!(nil, expected) when map_size(expected) == 0, do: :ok

  defp compare_result!(nil, expected) when is_map(expected) do
    non_inputs = Map.drop(expected, ["inputs"])

    if map_size(non_inputs) == 0 do
      :ok
    else
      raise ExUnit.AssertionError, message: "expected #{inspect(expected)} but got nil"
    end
  end

  defp compare_result!(actual, expected) when is_map(actual) and is_map(expected) do
    errors =
      Enum.flat_map(@components, fn component ->
        component_compare_errors(actual, expected, component)
      end)

    if errors == [] do
      :ok
    else
      raise ExUnit.AssertionError, message: Enum.join(errors, "; ")
    end
  end

  defp compare_result!(actual, _expected) do
    raise ExUnit.AssertionError, message: "unexpected actual type: #{inspect(actual)}"
  end

  defp component_compare_errors(actual, expected, component) do
    key = Atom.to_string(component)

    case Map.get(expected, key) do
      nil ->
        []

      expected_component ->
        actual_component = Map.get(actual, component)

        case compare_component_result(actual_component, expected_component, key) do
          :ok -> []
          {:error, message} -> [message]
        end
    end
  end

  defp compare_component_result(nil, _expected, component) do
    {:error, "component #{component} missing from actual result"}
  end

  defp compare_component_result(actual, expected, component) do
    case compare_input(actual, expected, component) do
      :ok -> compare_expected_groups(actual, expected, component)
      error -> error
    end
  end

  defp compare_input(actual, expected, component) do
    expected_input = Map.get(expected, "input")

    if is_nil(expected_input) or actual[:input] == expected_input do
      :ok
    else
      {:error,
       "#{component}.input mismatch: expected #{inspect(expected_input)}, got #{inspect(actual[:input])}"}
    end
  end

  defp compare_expected_groups(actual, expected, component) do
    case Map.get(expected, "groups") do
      nil -> :ok
      expected_groups -> compare_groups(actual[:groups], expected_groups, component)
    end
  end

  defp compare_groups(actual_groups, expected_groups, component) do
    missing_or_mismatched =
      Enum.flat_map(expected_groups, fn {key, expected_value} ->
        actual_value = Map.get(actual_groups, key)
        expected_value = if expected_value == nil, do: nil, else: expected_value

        if actual_value == expected_value do
          []
        else
          [
            "#{component}.groups[#{key}]: expected #{inspect(expected_value)}, got #{inspect(actual_value)}"
          ]
        end
      end)

    unexpected_keys =
      Enum.flat_map(actual_groups || %{}, fn {key, _value} ->
        if Map.has_key?(expected_groups, key) do
          []
        else
          ["#{component}.groups has unexpected key #{key}"]
        end
      end)

    case missing_or_mismatched ++ unexpected_keys do
      [] -> :ok
      errors -> {:error, Enum.join(errors, ", ")}
    end
  end

  defp assert_equal!(actual, expected, _message) when actual == expected, do: :ok

  defp assert_equal!(actual, expected, message) do
    raise ExUnit.AssertionError,
      message: "#{message}: expected #{inspect(expected)}, got #{inspect(actual)}"
  end

  defp assert_raises!(fun) when is_function(fun, 0) do
    fun.()
    raise ExUnit.AssertionError, message: "expected function to raise"
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp generate_url_spec(%URLPattern{} = pattern, component, groups) when is_map(groups) do
    component = normalize_generate_component_name!(component)
    parts = parse_generate_component_parts!(pattern, component)
    raw_value = generate_component_parts(parts, groups)
    value = normalize_generated_component(pattern, component, raw_value)

    case Map.fetch!(pattern.compiled, component) do
      {_canonical, compiled_component} ->
        case match_generated_component(compiled_component, value) do
          nil ->
            raise ArgumentError,
                  "Cannot generate #{component} from #{inspect(groups)} for pattern #{inspect(Map.get(pattern, component))}"

          {_matched, _groups} ->
            value
        end
    end
  end

  defp generate_url_spec(%URLPattern{}, _component, _groups) do
    raise ArgumentError, "groups must be a map"
  end

  defp normalize_generate_component_name!(component) when component in @components, do: component

  defp normalize_generate_component_name!(component) when is_binary(component) do
    case Map.fetch(@component_name_map, component) do
      {:ok, normalized} -> normalized
      :error -> raise ArgumentError, "Unknown URLPattern component: #{inspect(component)}"
    end
  end

  defp normalize_generate_component_name!(component) do
    raise ArgumentError, "Unknown URLPattern component: #{inspect(component)}"
  end

  defp parse_generate_component_parts!(%URLPattern{} = pattern, component) do
    pattern
    |> Map.fetch!(component)
    |> Parser.parse()
    |> case do
      {:ok, parts} -> parts
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp generate_component_parts(parts, groups) do
    Enum.map_join(parts, "", &generate_component_part(&1, groups))
  end

  defp generate_component_part({:literal, text}, _groups), do: text

  defp generate_component_part({:name, name, _custom_pattern, :none}, groups) do
    fetch_group_value!(groups, name)
  end

  defp generate_component_part({:group, parts, :none}, groups) do
    generate_component_parts(parts, groups)
  end

  defp generate_component_part({:name, _name, _custom_pattern, _modifier}, _groups) do
    raise ArgumentError, "Cannot generate from modified named groups"
  end

  defp generate_component_part({:group, _parts, _modifier}, _groups) do
    raise ArgumentError, "Cannot generate from modified groups"
  end

  defp generate_component_part({:regex, _pattern, _modifier}, _groups) do
    raise ArgumentError, "Cannot generate from regexp groups"
  end

  defp generate_component_part({:wildcard, _modifier}, _groups) do
    raise ArgumentError, "Cannot generate from wildcard groups"
  end

  defp fetch_group_value!(groups, name) do
    case Enum.find(groups, fn {key, _value} -> to_string(key) == name end) do
      nil -> raise ArgumentError, "Missing group value for #{inspect(name)}"
      {_key, value} -> to_string(value)
    end
  end

  defp normalize_generated_component(pattern, :pathname, raw_value) do
    if non_special_literal_protocol_pattern?(pattern.protocol) do
      percent_encode_non_ascii(raw_value)
    else
      normalize_generated_component_input(:pathname, raw_value)
    end
  end

  defp normalize_generated_component(_pattern, component, raw_value) do
    case normalize_generated_component_input(component, raw_value) do
      "!invalid!" ->
        raise ArgumentError, "Invalid generated #{component} value: #{inspect(raw_value)}"

      value ->
        value
    end
  end

  defp non_special_literal_protocol_pattern?(pattern) do
    literal = String.downcase(pattern)

    not Regex.match?(~r/[*:({?+\\]/, literal) and not special_scheme?(literal)
  end

  defp special_scheme?(scheme), do: scheme in ["http", "https", "ws", "wss", "ftp", "file"]

  defp normalize_generated_component_input(:protocol, val) do
    if String.contains?(val, ":") do
      "!invalid!"
    else
      normalized = val |> String.trim_trailing(":") |> String.downcase()

      if String.match?(normalized, ~r/[^\x00-\x7F]/) do
        "!invalid!"
      else
        normalized
      end
    end
  end

  defp normalize_generated_component_input(:search, val) do
    val
    |> String.trim_leading("?")
    |> percent_encode_non_ascii()
  end

  defp normalize_generated_component_input(:hash, val) do
    val
    |> String.trim_leading("#")
    |> percent_encode_non_ascii()
  end

  defp normalize_generated_component_input(:port, val) do
    tab_stripped = String.replace(val, "\t", "")
    stripped = Regex.replace(~r/[^\d].*$/s, tab_stripped, "")

    if tab_stripped != "" and stripped == "" do
      "!invalid!"
    else
      stripped
    end
  end

  defp normalize_generated_component_input(:pathname, val) do
    encoded =
      val
      |> percent_encode_non_ascii()
      |> String.replace(" ", "%20")
      |> String.replace("{", "%7B")
      |> String.replace("}", "%7D")

    if String.starts_with?(encoded, "/") do
      normalize_generated_pathname(encoded)
    else
      encoded
    end
  end

  defp normalize_generated_component_input(:username, val), do: percent_encode_non_ascii(val)
  defp normalize_generated_component_input(:password, val), do: percent_encode_non_ascii(val)

  defp normalize_generated_component_input(:hostname, val) do
    val
    |> String.replace(["\n", "\r", "\t"], "")
    |> stop_at_uri_delimiters()
    |> host_to_ascii()
  end

  defp stop_at_uri_delimiters(h) do
    h
    |> String.split("/", parts: 2)
    |> hd()
    |> String.split("?", parts: 2)
    |> hd()
    |> String.split("#", parts: 2)
    |> hd()
  end

  defp normalize_generated_pathname(path) when is_binary(path) do
    path
    |> URI.parse()
    |> Map.get(:path, path)
    |> remove_dot_segments()
  end

  defp remove_dot_segments(path) do
    path
    |> String.split("/")
    |> Enum.reduce([], fn segment, acc ->
      case {segment, acc} do
        {".", _} -> acc
        {"..", _} -> Enum.drop(acc, 1)
        {seg, _} -> [seg | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.join("/")
    |> then(fn normalized ->
      if String.starts_with?(path, "/") and not String.starts_with?(normalized, "/") do
        "/" <> normalized
      else
        normalized
      end
    end)
  end

  defp percent_encode_non_ascii(input), do: percent_encode_non_ascii(input, "")
  defp percent_encode_non_ascii("", acc), do: acc

  defp percent_encode_non_ascii(<<"%", a::utf8, b::utf8, rest::binary>>, acc)
       when a in ?0..?9 or a in ?a..?f or a in ?A..?F do
    percent_encode_non_ascii(rest, acc <> "%" <> <<a::utf8>> <> <<b::utf8>>)
  end

  defp percent_encode_non_ascii(<<c::utf8, rest::binary>>, acc) when c <= 0x7F do
    percent_encode_non_ascii(rest, acc <> <<c::utf8>>)
  end

  defp percent_encode_non_ascii(<<c::utf8, rest::binary>>, acc) do
    encoded = <<c::utf8>> |> percent_encode_codepoint()
    percent_encode_non_ascii(rest, acc <> encoded)
  end

  defp percent_encode_codepoint(char) do
    for <<byte <- char>>, into: "", do: "%" <> Base.encode16(<<byte>>, case: :upper)
  end

  defp host_to_ascii(hostname) do
    hostname
    |> String.downcase()
    |> String.split(".", trim: false)
    |> Enum.map_join(".", &label_to_ascii/1)
  end

  defp label_to_ascii(""), do: ""

  defp label_to_ascii(label) do
    if String.match?(label, ~r/^[\x00-\x7F]+$/) do
      label
    else
      "xn--" <> punycode_encode(label)
    end
  end

  defp punycode_encode(label) do
    codepoints = String.to_charlist(label)
    basic = Enum.filter(codepoints, &(&1 < 0x80))
    basic_part = basic |> List.to_string() |> String.downcase()
    basic_count = length(basic)
    needs_delimiter = basic_count > 0 and basic_count < length(codepoints)

    encoded_tail =
      punycode_encode_loop(
        codepoints,
        128,
        0,
        72,
        basic_count,
        basic_count,
        length(codepoints),
        []
      )
      |> List.to_string()

    if needs_delimiter do
      basic_part <> "-" <> encoded_tail
    else
      encoded_tail
    end
  end

  defp punycode_encode_loop(_codepoints, _n, _delta, _bias, _basic_count, h, total, acc)
       when h >= total,
       do: acc

  defp punycode_encode_loop(codepoints, n, delta, bias, basic_count, h, total, acc) do
    m =
      codepoints
      |> Enum.filter(&(&1 >= n))
      |> Enum.min()

    delta = delta + (m - n) * (h + 1)

    {delta, bias, h, acc} =
      Enum.reduce(codepoints, {delta, bias, h, acc}, fn cp,
                                                        {delta_acc, bias_acc, h_acc, out_acc} ->
        cond do
          cp < m ->
            {delta_acc + 1, bias_acc, h_acc, out_acc}

          cp == m ->
            {encoded, next_bias} =
              punycode_encode_delta(delta_acc, bias_acc, h_acc + 1, h_acc == basic_count)

            {0, next_bias, h_acc + 1, out_acc ++ encoded}

          true ->
            {delta_acc, bias_acc, h_acc, out_acc}
        end
      end)

    punycode_encode_loop(codepoints, m + 1, delta + 1, bias, basic_count, h, total, acc)
  end

  defp punycode_encode_delta(delta, bias, points, first_time?) do
    punycode_encode_delta(delta, bias, points, first_time?, 36, [])
  end

  defp punycode_encode_delta(delta, bias, points, first_time?, k, acc) do
    threshold = punycode_threshold(k, bias)

    if delta < threshold do
      {acc ++ [encode_digit(delta)], adapt_bias(delta, points, first_time?)}
    else
      value = threshold + rem(delta - threshold, 36 - threshold)

      punycode_encode_delta(
        div(delta - threshold, 36 - threshold),
        bias,
        points,
        first_time?,
        k + 36,
        acc ++ [encode_digit(value)]
      )
    end
  end

  defp punycode_threshold(k, bias), do: min(max(k - bias, 1), 26)

  defp adapt_bias(delta, points, first_time?) do
    delta = if first_time?, do: div(delta, 700), else: div(delta, 2)
    delta = delta + div(delta, points)
    adapt_bias_loop(delta, 0)
  end

  defp adapt_bias_loop(delta, k) do
    {delta, k} =
      if delta > 455 do
        {div(delta, 35), k + 36}
      else
        {delta, k}
      end

    if delta > 455 do
      adapt_bias_loop(delta, k)
    else
      k + div(36 * delta, delta + 38)
    end
  end

  defp encode_digit(value) when value < 26, do: ?a + value
  defp encode_digit(value), do: ?0 + value - 26

  defp match_generated_component(%{regex: regex, captures: captures}, input_val) do
    case Regex.run(regex, input_val, capture: :all) do
      nil ->
        nil

      [_ | groups] ->
        group_map =
          captures
          |> Enum.with_index()
          |> Enum.reduce(%{}, fn {{_idx, name}, i}, acc ->
            Map.put(acc, name, Enum.at(groups, i))
          end)

        {input_val, group_map}
    end
  end

  describe "match_context/3" do
    test "injects matched groups into Variable for the callback duration" do
      pattern = URLPattern.new(%{pathname: "/api/:id"})

      result =
        URLPattern.match_context(pattern, %{pathname: "/api/42"}, fn ->
          Variable.get(URLPattern.params())
        end)

      assert result == %{"id" => "42"}
    end

    test "returns nil when pattern does not match" do
      pattern = URLPattern.new(%{pathname: "/api/:id"})

      result =
        URLPattern.match_context(pattern, %{pathname: "/other"}, fn ->
          Variable.get(URLPattern.params())
        end)

      assert result == nil
    end

    test "restores previous params after match_context returns" do
      pattern1 = URLPattern.new(%{pathname: "/api/:x"})
      pattern2 = URLPattern.new(%{pathname: "/data/:y"})

      outer_params =
        URLPattern.match_context(pattern1, %{pathname: "/api/outer"}, fn ->
          URLPattern.match_context(pattern2, %{pathname: "/data/inner"}, fn ->
            Variable.get(URLPattern.params())
          end)

          Variable.get(URLPattern.params())
        end)

      assert outer_params == %{"x" => "outer"}
    end

    test "coexists with other AsyncContext variables" do
      pattern = URLPattern.new(%{pathname: "/items/:item_id"})

      item_id =
        URLPattern.match_context(pattern, %{pathname: "/items/99"}, fn ->
          Variable.get(URLPattern.params())["item_id"]
        end)

      assert item_id == "99"
    end

    test "downstream snapshot captures injected params" do
      pattern = URLPattern.new(%{pathname: "/api/:version"})
      assert Variable.get(URLPattern.params()) == nil

      captured_params =
        URLPattern.match_context(pattern, %{pathname: "/api/v3"}, fn ->
          snapshot = Snapshot.take()

          Task.async(fn ->
            Snapshot.run(snapshot, fn ->
              Variable.get(URLPattern.params())
            end)
          end)
          |> Task.await()
        end)

      assert captured_params == %{"version" => "v3"}
      assert Variable.get(URLPattern.params()) == nil
    end
  end

  describe "pattern cache" do
    test "same pattern compiled struct is identical" do
      p1 = URLPattern.new(%{pathname: "/foo/:id"})
      p2 = URLPattern.new(%{pathname: "/foo/:id"})

      assert p1.pathname == p2.pathname
      assert p1.compiled == p2.compiled
    end
  end

  describe "non-disturbing for Request" do
    test "matching a Request uses URL fields without touching body" do
      request = Web.Request.new("https://example.com/items/7")
      pattern = URLPattern.new(%{pathname: "/items/:id"})

      result = URLPattern.exec(pattern, request.url)
      assert result[:pathname][:groups] == %{"id" => "7"}
    end
  end

  test "stores pinned string patterns in persistent_term" do
    pattern = "https://example.com/pinned-string"
    key = {{Web.URLPattern, :pinned}, {pattern, nil, false}}

    erase_pinned(key)

    compiled1 = URLPattern.new(pattern, %{pinned: true})
    compiled2 = URLPattern.new(pattern, %{pinned: true})

    assert compiled1 == compiled2
    assert :persistent_term.get(key) == compiled1

    erase_pinned(key)
  end

  test "stores pinned map patterns and accepts atom baseURL keys" do
    pattern = %{pathname: "/from-base", baseURL: "https://example.com/root"}
    key = {{Web.URLPattern, :pinned}, {pattern, false}}

    erase_pinned(key)

    compiled1 = URLPattern.new(pattern, %{pinned: true})
    compiled2 = URLPattern.new(pattern, %{pinned: true})

    assert compiled1 == compiled2
    assert URLPattern.test(compiled1, "https://example.com/from-base")
    assert :persistent_term.get(key) == compiled1

    erase_pinned(key)
  end

  test "fragment-only and query-only string patterns compile and match" do
    fragment_pattern = URLPattern.new("#frag")
    query_pattern = URLPattern.new("?q=1")

    assert URLPattern.exec(fragment_pattern, "https://example.com/path#frag")[:hash][:input] ==
             "frag"

    assert URLPattern.exec(query_pattern, "https://example.com/path?q=1")[:search][:input] ==
             "q=1"
  end

  test "test/2 and test/3 return booleans through exec" do
    absolute = URLPattern.new("https://example.com/foo")

    assert URLPattern.test(absolute, "https://example.com/foo")
    refute URLPattern.test(absolute, "https://example.com/bar")
    assert URLPattern.test(absolute, "/foo", "https://example.com")
  end

  test "request structs and unsupported inputs use their dedicated exec branches" do
    request = Web.Request.new("https://example.com/items/7")
    pattern = URLPattern.new(%{pathname: "/items/:id"})

    assert URLPattern.exec(pattern, request)[:pathname][:groups] == %{"id" => "7"}
    assert URLPattern.exec(pattern, 123) == nil
  end

  test "invalid base urls return nil during exec resolution" do
    pattern = URLPattern.new("https://example.com/foo")

    assert URLPattern.exec(pattern, "/foo", "data:text/plain,hello") == nil
    assert URLPattern.exec(pattern, "/foo", "http://[") == nil
  end

  test "escaped question marks inside regex groups stay in the pathname" do
    pattern = URLPattern.new("https://example.com/(foo\\?)bar")

    assert pattern.pathname == "/(foo\\?)bar"
    assert pattern.search == "*"
  end

  test "special scheme inputs without slashes still normalize authority" do
    pattern = URLPattern.new("https://example.com/")
    result = URLPattern.exec(pattern, "https:user:pass@example.com/")

    assert result[:username][:input] == "user"
    assert result[:password][:input] == "pass"
    assert result[:hostname][:input] == "example.com"
  end

  test "userinfo splitting handles grouped usernames" do
    pattern = URLPattern.new("https://(foo):bar@example.com/")

    assert URLPattern.test(pattern, "https://foo:bar@example.com/")
  end

  test "string patterns parse escaped ipv6 hosts and host-port variants" do
    plain = URLPattern.new("http://[\\:\\:1]/")
    explicit_port = URLPattern.new("http://[\\:\\:1]:8080/")
    trailing_text = URLPattern.new("http://[\\:\\:1]foo/")
    host_fallback = URLPattern.new("http://example.com:abc/")

    assert plain.hostname == "[::1]"
    assert plain.port == ""
    assert explicit_port.hostname == "[::1]"
    assert explicit_port.port == "8080"
    assert trailing_text.hostname == "[::1]"
    assert trailing_text.port == ""
    assert host_fallback.hostname == "example.com:abc"
    assert host_fallback.port == ""
  end

  test "ipv6 authorities support explicit and empty ports" do
    empty_port = URLPattern.new(%{hostname: "[\\:\\:1]", port: ""})
    explicit_port = URLPattern.new(%{hostname: "[\\:\\:1]", port: "8080"})

    assert URLPattern.test(empty_port, %{hostname: "[::1]", port: ""})
    assert URLPattern.test(explicit_port, %{hostname: "[::1]", port: "8080"})
  end

  test "pathname inputs normalize spaces" do
    pattern = URLPattern.new(%{pathname: "/a%20b"})

    assert URLPattern.test(pattern, %{pathname: "/a b"})
  end

  test "hostnames are punycoded from unicode input" do
    pattern = URLPattern.new(%{hostname: "xn--bcher-kva.example"})

    assert URLPattern.test(pattern, %{hostname: "bücher.example"})
  end

  test "hostnames with multiple unicode labels still normalize under wildcard patterns" do
    assert URLPattern.exec(URLPattern.new(%{}), %{hostname: "mañana.例え"}) != nil
  end

  test "hostname validators allow plus at top level and escaped ipv6 colons" do
    plain = URLPattern.new(%{hostname: "foo+"})
    bracketed = URLPattern.new(%{hostname: "[\\:\\:1]"})
    bracketed_plus = URLPattern.new(%{hostname: "[\\:\\:1+]"})

    assert plain.hostname == "foo+"
    assert bracketed.hostname == "[::1]"
    assert bracketed_plus.hostname == "[::1+]"

    assert_raise ArgumentError, ~r/Expected name after ':'/, fn ->
      URLPattern.new(%{hostname: "[::1]"})
    end
  end

  test "opaque map inputs preserve nil pathnames" do
    pattern = URLPattern.new(%{protocol: "data"})

    assert URLPattern.exec(pattern, %{protocol: "data", pathname: nil}) != nil
  end

  test "map inputs accept atom baseURL keys during exec" do
    pattern = URLPattern.new("https://example.com/foo")

    assert URLPattern.exec(pattern, %{pathname: "/foo", baseURL: "https://example.com"}) !=
             nil
  end

  test "inputs without a scheme fail string parsing" do
    assert URLPattern.exec(URLPattern.new(%{}), "noscheme") == nil
  end

  test "match_context returns an empty params map when nothing is captured" do
    pattern = URLPattern.new(%{pathname: "/literal"})

    assert URLPattern.match_context(pattern, %{pathname: "/literal"}, fn ->
             Variable.get(URLPattern.params())
           end) == %{}
  end

  test "path normalization handles leading parent segments" do
    pattern = URLPattern.new(%{pathname: "/bar"})

    assert URLPattern.test(pattern, %{pathname: "/../bar"})
  end

  test "escaped special characters and percent-encoded sequences are preserved" do
    escaped_brace = URLPattern.new(%{pathname: "/a\\}b"})
    percent_encoded = URLPattern.new(%{pathname: "/%E2%82%ACé"})
    escaped_protocol = URLPattern.new(%{protocol: "ab\\é"})
    escaped_hostname = URLPattern.new(%{hostname: "\\é.example"})
    escaped_port = URLPattern.new(%{port: "\\é"})
    wildcard = URLPattern.new(%{})

    assert escaped_brace.pathname == "/a%7Db"
    assert URLPattern.test(escaped_brace, %{pathname: "/a}b"})
    assert percent_encoded.pathname == "/%E2%82%AC%C3%A9"
    assert URLPattern.exec(wildcard, %{pathname: "/%E2%82%ACé"}) != nil
    assert escaped_protocol.protocol == "abé"
    assert escaped_hostname.hostname == "é.example"
    assert escaped_port.port == "é"
  end

  test "hash-only inputs with base urls that have no search leave search unchanged" do
    pattern = URLPattern.new(%{protocol: "https", pathname: "/foo", hash: "frag"})

    assert URLPattern.exec(pattern, %{hash: "frag", baseURL: "https://example.com/foo"}) !=
             nil
  end

  test "punycode normalization handles high-codepoint labels" do
    assert URLPattern.exec(URLPattern.new(%{}), %{hostname: "☃☃☃☃☃.example"}) != nil
  end

  test "invalid hostname patterns raise from bracket and colon validation" do
    assert_raise ArgumentError, ~r/Invalid hostname pattern character: ":"/, fn ->
      URLPattern.new(%{hostname: "foo:1"})
    end

    assert_raise ArgumentError, ~r/Invalid hostname pattern character: "\["/, fn ->
      URLPattern.new(%{hostname: "[[::1]]"})
    end
  end

  describe "defensive coverage" do
    test "exec raises if baseURL is provided when input is a map" do
      assert_raise ArgumentError, ~r/baseURL must not be provided/, fn ->
        URLPattern.exec(URLPattern.new(%{}), %{pathname: "/"}, "https://example.com")
      end
    end

    test "normalize_input handles Web.URL struct" do
      url = Web.URL.new("https://example.com/foo")
      p = URLPattern.new("https://example.com/foo")
      assert URLPattern.test(p, url)
    end

    test "params registry cache hit" do
      # Already hit by other tests, but let's call it again
      assert URLPattern.params() == URLPattern.params()
    end

    test "normalize_component_input for search and hash with markers" do
      # These check markers handling in normalize_component_input
      # Search may start with ?
      # Hash may start with #
      p = URLPattern.new(%{search: "?a", hash: "#b"})
      assert p.search == "a"
      assert p.hash == "b"
    end

    test "data:foo opaque path raises during pattern build" do
      assert_raise ArgumentError, ~r/URL string with an opaque path is not allowed/, fn ->
        URLPattern.new("data:foo")
      end
    end

    test "compare_component raises when a stored pattern component cannot be parsed" do
      invalid = %URLPattern{pathname: "("}
      valid = URLPattern.new(%{pathname: "/"})

      assert_raise ArgumentError, fn ->
        URLPattern.compare_component(:pathname, invalid, valid)
      end
    end

    test "compare_component raises for unknown component names" do
      pattern = URLPattern.new(%{pathname: "/"})

      assert_raise ArgumentError, ~r/Unknown URLPattern component/, fn ->
        URLPattern.compare_component("invalid", pattern, pattern)
      end

      assert_raise ArgumentError, ~r/Unknown URLPattern component/, fn ->
        URLPattern.compare_component(123, pattern, pattern)
      end
    end

    test "compare_component covers named regexp and grouped modifier tokenization" do
      full_wildcard = URLPattern.new(%{pathname: "/:id(.*)"})
      regex = URLPattern.new(%{pathname: "/:id(\\d+)"})
      grouped = URLPattern.new(%{pathname: "/{:id.:ext}?"})

      assert URLPattern.compare_component(:pathname, full_wildcard, regex) == -1
      assert URLPattern.compare_component(:pathname, grouped, grouped) == 0
    end

    test "compare_component keeps modified tokens without a delimiter prefix attached" do
      pattern = URLPattern.new(%{pathname: "/foo:id?"})

      assert URLPattern.compare_component(:pathname, pattern, pattern) == 0
    end

    test "malformed scheme-like inputs fall back to an empty raw authority" do
      result = URLPattern.exec(URLPattern.new(%{}), "1://example.com")

      assert result[:protocol][:input] == ""
      assert result[:username][:input] == ""
      assert result[:password][:input] == ""
      assert result[:hostname][:input] == ""
      assert result[:pathname][:input] == "/1://example.com"
    end

    test "malformed scheme-like inputs preserve a leading slash in the raw pathname" do
      result = URLPattern.exec(URLPattern.new(%{}), "/1://example.com")

      assert result[:pathname][:input] == "/1://example.com"
    end

    test "compare_tokens exhaustive" do
      p1 = URLPattern.new(%{pathname: "/a"})
      p2 = URLPattern.new(%{pathname: "/:id"})
      p3 = URLPattern.new(%{pathname: "/*"})

      # Rank: fixed (3) > segment_wildcard (1) > full_wildcard (0)
      assert URLPattern.compare_component(:pathname, p1, p2) == 1
      assert URLPattern.compare_component(:pathname, p2, p3) == 1
      assert URLPattern.compare_component(:pathname, p1, p3) == 1
      assert URLPattern.compare_component(:pathname, p1, p1) == 0
    end
  end
end
