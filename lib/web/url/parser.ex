defmodule Web.URL.Parser do
  @moduledoc false

  alias Web.URL.{Encoding, IP}

  @special_schemes MapSet.new(["file", "ftp", "http", "https", "ws", "wss"])

  @spec parse(String.t(), String.t() | map() | nil) :: {:ok, map()} | {:error, String.t()}
  def parse(input, base \\ nil) when is_binary(input) do
    source =
      input
      |> Encoding.trim_c0_whitespace()
      |> Encoding.strip_ascii_tab_and_newline()

    do_parse(source, base)
  end

  @spec parse!(String.t(), String.t() | map() | nil) :: map()
  def parse!(input, base \\ nil) do
    case parse(input, base) do
      {:ok, fields} -> fields
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec special_scheme?(String.t()) :: boolean()
  def special_scheme?(scheme) do
    scheme
    |> to_string()
    |> String.trim_trailing(":")
    |> String.downcase()
    |> then(&MapSet.member?(@special_schemes, &1))
  end

  defp do_parse("", base) when base != nil, do: build_relative("", base)
  defp do_parse("", _base), do: {:error, "Invalid URL"}

  defp do_parse(source, base) do
    case split_scheme(source) do
      {:ok, scheme, rest} -> build_absolute(source, scheme, rest, base)
      :error when base != nil -> build_relative(source, base)
      :error -> {:error, "Invalid URL: relative URL without a base"}
    end
  end

  defp build_absolute(source, scheme, rest, base) do
    normalized = normalize_for_scheme(source, scheme)
    authority_present? = authority_present_in_input?(normalized)
    normalized_rest = String.replace_prefix(normalized, scheme <> ":", "")

    build_absolute_for_scheme(rest, scheme, base, normalized, normalized_rest, authority_present?)
  end

  defp build_relative(source, base) do
    base_href = href_from_base(base)

    case split_scheme(base_href) do
      {:ok, "file", _rest} ->
        build_file_relative(source, base_href)

      {:ok, scheme, _rest} ->
        build_relative_for_scheme(source, base_href, scheme)

      :error ->
        {:error, "Invalid base URL"}
    end
  end

  defp build_special_relative(rest, scheme, base) do
    base_href = href_from_base(base)

    with {:ok, base_scheme, _rest} <- split_scheme(base_href),
         true <- String.downcase(base_scheme) == String.downcase(scheme) do
      if scheme == "file" and file_windows_drive_reference?(rest) do
        build_file_drive_reference(rest, base_file_host(base_href))
      else
        normalized_base = normalize_for_scheme(base_href, base_scheme)
        normalized_rest = Encoding.normalize_special_path_separators(rest, true)
        merged = URI.merge(URI.parse(normalized_base), normalized_rest)

        authority_present? =
          Enum.any?([
            not is_nil(merged.host),
            not is_nil(merged.authority),
            authority_present_in_input?(normalized_rest),
            authority_present_in_input?(normalized_base)
          ])

        merged
        |> build_fields(scheme, authority_present?, URI.to_string(merged))
      end
    else
      _ ->
        build_special_relative_fallback(rest, scheme)
    end
  end

  defp build_non_special_hierarchical(source, scheme) do
    {:ok, _scheme, rest} = split_scheme(source)
    after_slashes = binary_part(rest, 2, byte_size(rest) - 2)

    case after_slashes do
      <<char::utf8, _::binary>> when char in [?/, ??, ?#] ->
        build_empty_authority_fields(after_slashes, scheme)

      "" ->
        build_empty_authority_fields("", scheme)

      _ ->
        source |> URI.parse() |> build_fields(scheme, true, source)
    end
  end

  defp build_empty_authority_fields(path_and_tail, scheme) do
    {pathname, search, fragment, search_present?, hash_present?} =
      split_opaque_path(path_and_tail)

    protocol = normalize_protocol(scheme)
    normalized_search = normalize_search_value(search, protocol)
    normalized_fragment = normalize_fragment_value(fragment)

    {:ok,
     %{
       kind: :standard,
       protocol: protocol,
       username: "",
       password: "",
       hostname: "",
       port: "",
       pathname: Encoding.percent_encode_non_ascii(pathname),
       search: normalized_search,
       fragment: normalized_fragment,
       search_params: Web.URLSearchParams.new(normalized_search || ""),
       hash: hash_value(normalized_fragment),
       authority_present?: true,
       search_present?: search_present?,
       hash_present?: hash_present?
     }}
  end

  defp build_fields(%URI{} = uri, scheme, authority_present?, source) do
    context = build_field_context(uri, scheme, authority_present?, source)

    case resolve_field_hostname(context) do
      {:ok, hostname, normalize_default?} ->
        build_standard_uri_fields(context, hostname, normalize_default?)

      :error ->
        {:error, "Invalid URL host"}
    end
  end

  defp build_opaque_fields(source, scheme) do
    {:ok, _scheme, rest} = split_scheme(source)
    {pathname, search, fragment, search_present?, hash_present?} = split_opaque_path(rest)
    protocol = normalize_protocol(scheme)
    normalized_search = normalize_search_value(search, protocol)
    normalized_fragment = normalize_fragment_value(fragment)
    normalized_pathname = normalize_opaque_path(pathname, normalized_search, normalized_fragment)

    {:ok,
     %{
       kind: :standard,
       protocol: protocol,
       username: "",
       password: "",
       hostname: "",
       port: "",
       pathname: normalized_pathname,
       search: normalized_search,
       fragment: normalized_fragment,
       search_params: Web.URLSearchParams.new(normalized_search || ""),
       hash: hash_value(normalized_fragment),
       authority_present?: false,
       search_present?: search_present?,
       hash_present?: hash_present?
     }}
  end

  defp split_scheme(input), do: split_scheme(input, [], true)

  defp split_scheme("", _acc, _at_start), do: :error

  defp split_scheme(":" <> rest, acc, false) when acc != [] do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  end

  defp split_scheme(<<?/, _rest::binary>>, _acc, _at_start), do: :error
  defp split_scheme(<<??, _rest::binary>>, _acc, _at_start), do: :error
  defp split_scheme(<<?#, _rest::binary>>, _acc, _at_start), do: :error
  defp split_scheme(<<"\\", _rest::binary>>, _acc, _at_start), do: :error

  defp split_scheme(<<char::utf8, rest::binary>>, acc, at_start) do
    if scheme_char?(char, at_start) do
      split_scheme(rest, [String.downcase(<<char::utf8>>) | acc], false)
    else
      :error
    end
  end

  defp scheme_char?(char, true) do
    (char >= ?a and char <= ?z) or (char >= ?A and char <= ?Z)
  end

  defp scheme_char?(char, false) do
    scheme_char?(char, true) or (char >= ?0 and char <= ?9) or char in [?+, ?-, ?.]
  end

  defp normalize_for_scheme(source, scheme) do
    Encoding.normalize_special_path_separators(source, special_scheme?(scheme))
  end

  defp normalize_opaque_path(pathname, search, fragment) do
    normalized = percent_encode_opaque_path(pathname)

    case Regex.run(~r/( +)$/u, normalized, capture: :all_but_first) do
      [spaces] when search != nil or fragment != nil ->
        String.trim_trailing(normalized, " ") <>
          String.duplicate(" ", String.length(spaces) - 1) <> "%20"

      _ ->
        String.trim_trailing(normalized, " ")
    end
  end

  defp valid_special_authority?(""), do: true

  defp valid_special_authority?(authority) do
    host_port = authority |> String.split("@") |> List.last()

    cond do
      String.contains?(host_port, ["[", "]"]) ->
        String.match?(host_port, ~r/^\[[^\]]+\](?::\d+)?$/)

      String.graphemes(host_port) |> Enum.count(&(&1 == ":")) > 1 ->
        false

      String.contains?(host_port, ":") ->
        [_host, port] = String.split(host_port, ":", parts: 2)
        port == "" or Regex.match?(~r/^\d+$/, port)

      true ->
        true
    end
  end

  defp split_opaque_path(rest) do
    do_split_opaque_path(rest, :path, [], [], [], false, false)
  end

  defp do_split_opaque_path(
         "",
         _state,
         path_acc,
         query_acc,
         fragment_acc,
         search_present?,
         hash_present?
       ) do
    {
      path_acc |> Enum.reverse() |> IO.iodata_to_binary(),
      if(search_present?, do: query_acc |> Enum.reverse() |> IO.iodata_to_binary(), else: nil),
      if(hash_present?, do: fragment_acc |> Enum.reverse() |> IO.iodata_to_binary(), else: nil),
      search_present?,
      hash_present?
    }
  end

  defp do_split_opaque_path(
         "?" <> rest,
         :path,
         path_acc,
         query_acc,
         fragment_acc,
         _search_present?,
         hash_present?
       ) do
    do_split_opaque_path(rest, :query, path_acc, query_acc, fragment_acc, true, hash_present?)
  end

  defp do_split_opaque_path(
         "#" <> rest,
         state,
         path_acc,
         query_acc,
         fragment_acc,
         search_present?,
         _hash_present?
       )
       when state in [:path, :query] do
    do_split_opaque_path(
      rest,
      :fragment,
      path_acc,
      query_acc,
      fragment_acc,
      search_present?,
      true
    )
  end

  defp do_split_opaque_path(
         <<char::utf8, rest::binary>>,
         :path,
         path_acc,
         query_acc,
         fragment_acc,
         search_present?,
         hash_present?
       ) do
    do_split_opaque_path(
      rest,
      :path,
      [<<char::utf8>> | path_acc],
      query_acc,
      fragment_acc,
      search_present?,
      hash_present?
    )
  end

  defp do_split_opaque_path(
         <<char::utf8, rest::binary>>,
         :query,
         path_acc,
         query_acc,
         fragment_acc,
         search_present?,
         hash_present?
       ) do
    do_split_opaque_path(
      rest,
      :query,
      path_acc,
      [<<char::utf8>> | query_acc],
      fragment_acc,
      search_present?,
      hash_present?
    )
  end

  defp do_split_opaque_path(
         <<char::utf8, rest::binary>>,
         :fragment,
         path_acc,
         query_acc,
         fragment_acc,
         search_present?,
         hash_present?
       ) do
    do_split_opaque_path(
      rest,
      :fragment,
      path_acc,
      query_acc,
      [<<char::utf8>> | fragment_acc],
      search_present?,
      hash_present?
    )
  end

  defp authority_present_in_input?(input) do
    case split_scheme(input) do
      {:ok, _scheme, rest} -> String.starts_with?(rest, "//")
      :error -> String.starts_with?(input, "//")
    end
  end

  defp search_present_in_input?(input) do
    input
    |> String.split("#", parts: 2)
    |> hd()
    |> String.contains?("?")
  end

  defp hash_present_in_input?(input), do: String.contains?(input, "#")

  defp opaque_base_reference?(base_href) do
    {:ok, _scheme, rest} = split_scheme(base_href)
    not String.starts_with?(rest, "/") and not String.starts_with?(rest, "//")
  end

  defp build_opaque_fragment_reference(source, base_href) do
    with {:ok, base_fields} <- parse(base_href) do
      fragment = source |> String.trim_leading("#") |> normalize_fragment_value()

      {:ok,
       %{
         base_fields
         | fragment: fragment,
           hash: hash_value(fragment),
           hash_present?: true
       }}
    end
  end

  defp extract_port(%URI{} = uri, protocol, normalize_default?) do
    if explicit_port?(uri) do
      extract_explicit_port(uri.port, protocol, normalize_default?)
    else
      {:ok, ""}
    end
  end

  defp extract_explicit_port(_port, "file:", _normalize_default?), do: :error
  defp extract_explicit_port(port, _protocol, _normalize_default?) when port > 65_535, do: :error

  defp extract_explicit_port(port, protocol, normalize_default?) do
    port = Integer.to_string(port)
    {:ok, if(normalize_default?, do: normalize_default_port(port, protocol), else: port)}
  end

  defp build_relative_with_base_scheme(source, base_href, scheme) do
    normalized_base = normalize_for_scheme(base_href, scheme)
    normalized_source = normalize_for_scheme(source, scheme)
    base_uri = URI.parse(normalized_base)

    merged =
      base_uri
      |> URI.merge(normalized_source)
      |> preserve_file_drive_root(base_uri, normalized_source, scheme)

    authority_present? =
      authority_present_in_input?(normalized_source) or
        authority_present_in_input?(normalized_base) or
        not is_nil(merged.host) or not is_nil(merged.authority)

    merged
    |> build_fields(scheme, authority_present?, URI.to_string(merged))
  end

  defp build_file_drive_reference(source, base_host) do
    normalized_source = Encoding.normalize_special_path_separators(source, true)
    path_source = String.trim_leading(normalized_source, "/")
    {pathname, search, fragment, search_present?, hash_present?} = split_opaque_path(path_source)
    normalized_search = normalize_search_value(search, "file:")
    normalized_fragment = normalize_fragment_value(fragment)

    hostname =
      if String.starts_with?(normalized_source, "//") do
        ""
      else
        IP.normalize_host(base_host || "", "file:")
      end

    {:ok,
     %{
       kind: :standard,
       protocol: "file:",
       username: "",
       password: "",
       hostname: hostname,
       port: "",
       pathname: normalize_path(hostname, "file:", pathname),
       search: normalized_search,
       fragment: normalized_fragment,
       search_params: Web.URLSearchParams.new(normalized_search || ""),
       hash: hash_value(normalized_fragment),
       authority_present?: true,
       search_present?: search_present?,
       hash_present?: hash_present?
     }}
  end

  defp file_windows_drive_reference?(source) do
    source
    |> Encoding.normalize_special_path_separators(true)
    |> String.trim_leading("/")
    |> starts_with_windows_drive_letter?()
  end

  defp starts_with_windows_drive_letter?(value) do
    String.match?(value, ~r/^[A-Za-z](?::|\|)(?:$|[\/\\?#])/)
  end

  defp base_file_host(base_href) do
    base_href
    |> URI.parse()
    |> Map.get(:host, "")
  end

  defp search_from_uri(%URI{} = uri, source, protocol) do
    if search_present_in_input?(source) do
      normalize_search_value(uri.query || "", protocol)
    else
      nil
    end
  end

  defp fragment_from_uri(%URI{} = uri, source) do
    if hash_present_in_input?(source), do: normalize_fragment_value(uri.fragment || ""), else: nil
  end

  defp normalize_search_value(nil, _protocol), do: nil

  defp normalize_search_value(search, protocol) do
    Encoding.encode_query_component(search, special_scheme?(protocol))
  end

  defp normalize_fragment_value(nil), do: nil
  defp normalize_fragment_value(fragment), do: Encoding.encode_fragment_component(fragment)

  defp preserve_file_drive_root(%URI{} = merged, %URI{} = base_uri, source, "file") do
    base_path = base_uri.path || ""

    case file_drive_root_mode(merged.path, base_path, source) do
      :base_path ->
        %{merged | host: base_uri.host, authority: base_uri.authority, path: base_path}

      :drive_root ->
        %{
          merged
          | host: base_uri.host,
            authority: base_uri.authority,
            path: windows_drive_root(base_path)
        }

      :unchanged ->
        merged
    end
  end

  defp preserve_file_drive_root(%URI{} = merged, _base_uri, _source, _scheme), do: merged

  defp build_absolute_for_scheme(
         rest,
         "file",
         base,
         normalized,
         normalized_rest,
         authority_present?
       ) do
    cond do
      file_windows_drive_reference?(rest) and
          (is_nil(base) or String.starts_with?(rest, "//")) ->
        build_file_drive_reference(rest, "")

      String.starts_with?(normalized_rest, ".//") ->
        build_empty_authority_fields(String.slice(normalized_rest, 1..-1//1), "file")

      not is_nil(base) and not String.starts_with?(rest, "//") ->
        build_special_relative(rest, "file", base)

      true ->
        parse_and_build_fields(normalized, "file", authority_present?)
    end
  end

  defp build_absolute_for_scheme(
         rest,
         scheme,
         base,
         normalized,
         normalized_rest,
         authority_present?
       ) do
    if special_scheme?(scheme) do
      build_special_absolute(rest, scheme, base, normalized, normalized_rest, authority_present?)
    else
      build_non_special_absolute(rest, normalized, scheme)
    end
  end

  defp build_special_absolute(rest, scheme, base, normalized, normalized_rest, authority_present?) do
    cond do
      is_nil(base) and special_authority_repair_needed?(normalized_rest) ->
        build_repaired_special_source(scheme, normalized_rest)

      not is_nil(base) and not String.starts_with?(rest, "//") ->
        build_special_relative(rest, scheme, base)

      true ->
        parse_and_build_fields(normalized, scheme, authority_present?)
    end
  end

  defp build_non_special_absolute(rest, normalized, scheme) do
    cond do
      String.starts_with?(rest, "//") ->
        build_non_special_hierarchical(normalized, scheme)

      String.starts_with?(rest, "/") ->
        parse_and_build_fields(normalized, scheme, false)

      true ->
        build_opaque_fields(normalized, scheme)
    end
  end

  defp build_file_relative(source, base_href) do
    if file_windows_drive_reference?(source) do
      build_file_drive_reference(source, base_file_host(base_href))
    else
      build_relative_with_base_scheme(source, base_href, "file")
    end
  end

  defp build_relative_for_scheme(source, base_href, scheme) do
    normalized_source = normalize_for_scheme(source, scheme)

    case relative_resolution_mode(base_href, normalized_source, scheme) do
      :repair_special ->
        build_repaired_special_source(scheme, normalized_source)

      :opaque_self ->
        parse(base_href)

      :opaque_fragment ->
        build_opaque_fragment_reference(normalized_source, base_href)

      :opaque_invalid ->
        {:error, "Invalid URL"}

      :merge ->
        build_relative_with_base_scheme(source, base_href, scheme)
    end
  end

  defp relative_resolution_mode(base_href, normalized_source, scheme) do
    cond do
      special_scheme?(scheme) and String.starts_with?(normalized_source, "///") ->
        :repair_special

      opaque_base_reference?(base_href) ->
        opaque_relative_mode(normalized_source)

      true ->
        :merge
    end
  end

  defp opaque_relative_mode(""), do: :opaque_self
  defp opaque_relative_mode("#" <> _rest), do: :opaque_fragment
  defp opaque_relative_mode(_source), do: :opaque_invalid

  defp build_special_relative_fallback(rest, scheme) do
    normalized = normalize_for_scheme(scheme <> ":" <> rest, scheme)
    normalized_rest = String.replace_prefix(normalized, scheme <> ":", "")

    if scheme == "file" do
      parse_and_build_fields(normalized, scheme, authority_present_in_input?(normalized))
    else
      build_special_relative_fallback_for_scheme(scheme, normalized, normalized_rest)
    end
  end

  defp build_special_relative_fallback_for_scheme(scheme, normalized, normalized_rest) do
    if special_authority_repair_needed?(normalized_rest) do
      build_repaired_special_source(scheme, normalized_rest)
    else
      parse_and_build_fields(normalized, scheme, authority_present_in_input?(normalized))
    end
  end

  defp special_authority_repair_needed?(normalized_rest) do
    normalized_rest != "" and not String.starts_with?(normalized_rest, "//") and
      not String.starts_with?(normalized_rest, "?") and
      not String.starts_with?(normalized_rest, "#")
  end

  defp build_repaired_special_source(scheme, suffix) do
    repaired = scheme <> "://" <> String.trim_leading(suffix, "/")
    parse_and_build_fields(repaired, scheme, true)
  end

  defp parse_and_build_fields(source, scheme, authority_present?) do
    source
    |> URI.parse()
    |> build_fields(scheme, authority_present?, source)
  end

  defp build_field_context(%URI{} = uri, scheme, authority_present?, source) do
    protocol = normalize_protocol(uri.scheme || scheme)
    {username, password} = encode_userinfo(uri.userinfo)

    %{
      uri: uri,
      scheme: scheme,
      source: source,
      protocol: protocol,
      search: search_from_uri(uri, source, protocol),
      fragment: fragment_from_uri(uri, source),
      username: username,
      password: password,
      host: uri.host || "",
      authority: uri.authority || "",
      authority_present?: authority_present?
    }
  end

  defp encode_userinfo(userinfo) do
    userinfo
    |> parse_userinfo()
    |> then(fn {username, password} ->
      {
        Encoding.encode_userinfo_component(username),
        Encoding.encode_userinfo_component(password)
      }
    end)
  end

  defp resolve_field_hostname(%{scheme: scheme} = context) do
    if special_scheme?(scheme) do
      resolve_special_field_hostname(context)
    else
      resolve_non_special_field_hostname(context)
    end
  end

  defp resolve_special_field_hostname(%{source: source} = context) do
    if special_authority_contains_null?(source) do
      :error
    else
      resolve_special_field_hostname_without_null(context)
    end
  end

  defp resolve_special_field_hostname_without_null(%{
         authority: authority,
         host: host,
         protocol: protocol
       }) do
    if valid_special_authority?(authority) and valid_bracketed_special_host?(authority, host) and
         (protocol == "file:" or host != "") and IP.valid_host?(host, protocol) do
      {:ok, IP.normalize_host(host, protocol), true}
    else
      :error
    end
  end

  defp resolve_non_special_field_hostname(%{authority: authority, host: host, protocol: protocol}) do
    valid_authority? = valid_non_special_authority?(authority, host)

    cond do
      valid_authority? and ipv6_host?(host) ->
        {:ok, IP.normalize_host(host, protocol), false}

      valid_authority? and IP.valid_opaque_host?(host) ->
        {:ok, IP.normalize_opaque_host(host), false}

      true ->
        :error
    end
  end

  defp build_standard_uri_fields(
         %{uri: uri, protocol: protocol} = context,
         hostname,
         normalize_default?
       ) do
    case extract_port(uri, protocol, normalize_default?) do
      {:ok, port} ->
        {:ok, standard_uri_fields(context, hostname, port)}

      :error ->
        {:error, "Invalid URL host"}
    end
  end

  defp standard_uri_fields(%{uri: uri} = context, hostname, port) do
    %{
      kind: :standard,
      protocol: context.protocol,
      username: context.username,
      password: context.password,
      hostname: hostname,
      port: port,
      pathname: normalize_path(hostname, context.protocol, uri.path || ""),
      search: context.search,
      fragment: context.fragment,
      search_params: Web.URLSearchParams.new(context.search || ""),
      hash: hash_value(context.fragment),
      authority_present?: context.authority_present?,
      search_present?: not is_nil(context.search),
      hash_present?: not is_nil(context.fragment)
    }
  end

  defp file_drive_root_mode("/", base_path, source) do
    cond do
      windows_drive_root_path?(base_path) and (String.starts_with?(source, ".") or source == "/") ->
        :base_path

      source == "/" and windows_drive_prefix?(base_path) ->
        :drive_root

      true ->
        :unchanged
    end
  end

  defp file_drive_root_mode(_merged_path, _base_path, _source), do: :unchanged

  defp ipv6_host?(host) do
    match?({:ok, _}, :inet.parse_ipv6strict_address(String.to_charlist(host)))
  end

  defp valid_bracketed_special_host?(authority, host) do
    host_port = authority |> String.split("@") |> List.last()

    if String.contains?(host_port, ["[", "]"]) do
      match?({:ok, _}, :inet.parse_ipv6strict_address(String.to_charlist(host)))
    else
      true
    end
  end

  defp valid_non_special_authority?(authority, host) do
    host_port = authority |> String.split("@") |> List.last()

    cond do
      host_port == "" ->
        not String.contains?(authority, "@")

      String.contains?(host_port, ["[", "]"]) ->
        String.match?(host_port, ~r/^\[[^\]]+\](?::\d+)?$/) and host != ""

      String.contains?(host_port, ":") ->
        [host_part, port] = String.split(host_port, ":", parts: 2)
        host_part != "" and Regex.match?(~r/^\d+$/, port)

      true ->
        true
    end
  end

  defp hash_value(nil), do: ""
  defp hash_value(""), do: ""
  defp hash_value(fragment), do: "#" <> fragment

  defp normalize_protocol(value) do
    protocol =
      value
      |> Kernel.||("")
      |> to_string()
      |> String.downcase()
      |> String.trim_trailing(":")

    if protocol == "", do: "", else: protocol <> ":"
  end

  defp normalize_default_port(port, protocol) do
    if port == IP.default_port(protocol), do: "", else: port
  end

  defp explicit_port?(%URI{authority: authority}) when is_binary(authority) do
    String.match?(authority, ~r/:\d+$/)
  end

  defp explicit_port?(_uri), do: false

  defp normalize_path(_hostname, "file:", path) do
    path
    |> to_string()
    |> String.replace("\\", "/")
    |> remove_dot_segments(true)
    |> Encoding.encode_path_component()
    |> normalize_file_drive_path()
    |> ensure_leading_slash()
  end

  defp normalize_path(hostname, protocol, path) do
    path = path |> to_string() |> remove_dot_segments(false) |> Encoding.encode_path_component()

    cond do
      hostname != "" and path == "" and (protocol == "file:" or special_scheme?(protocol)) -> "/"
      hostname != "" and path == "" -> ""
      path == "" -> ""
      true -> ensure_leading_slash(path)
    end
  end

  defp normalize_file_drive_path(path) do
    case path do
      <<drive::utf8, separator::utf8, rest::binary>>
      when ((drive >= ?A and drive <= ?Z) or (drive >= ?a and drive <= ?z)) and
             separator in [?:, ?|] ->
        if rest == "" or String.starts_with?(rest, ["/", "\\", "?", "#"]) do
          "/" <> <<drive::utf8, ?:>> <> rest
        else
          path
        end

      _ ->
        path
    end
  end

  defp ensure_leading_slash(""), do: "/"

  defp ensure_leading_slash(path) do
    if String.starts_with?(path, "/") do
      path
    else
      "/" <> path
    end
  end

  defp remove_dot_segments(path, preserve_drive_root?) do
    raw_segments = String.split(path, "/", trim: false)

    trailing_directory? = dot_segment_type(List.last(raw_segments) || "") in [:single, :double]

    segments =
      raw_segments
      |> Enum.reduce([], fn
        segment, acc ->
          case dot_segment_type(segment) do
            :single -> acc
            :double -> pop_path_segment(acc, preserve_drive_root?)
            :none -> acc ++ [segment]
          end
      end)

    segments = if trailing_directory?, do: segments ++ [""], else: segments
    Enum.join(segments, "/")
  end

  defp pop_path_segment([], _preserve_drive_root?), do: []
  defp pop_path_segment([""], _preserve_drive_root?), do: [""]

  defp pop_path_segment(segments, true) do
    drive = List.last(segments) || ""

    if byte_size(drive) == 2 and binary_part(drive, 1, 1) == ":" and
         (match?([_drive], segments) or match?(["", _drive], segments)) do
      segments
    else
      Enum.drop(segments, -1)
    end
  end

  defp pop_path_segment(segments, _preserve_drive_root?), do: Enum.drop(segments, -1)

  defp dot_segment_type(segment) do
    normalized = Regex.replace(~r/%2e/i, segment, ".")

    case normalized do
      "." -> :single
      ".." -> :double
      _ -> :none
    end
  end

  defp percent_encode_opaque_path(path) do
    path
    |> to_string()
    |> do_percent_encode_opaque_path([])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp do_percent_encode_opaque_path("", acc), do: acc

  defp do_percent_encode_opaque_path(<<char::utf8, rest::binary>>, acc)
       when char < 0x20 or char == 0x7F or char > 0x7F do
    encoded =
      <<char::utf8>>
      |> :binary.bin_to_list()
      |> Enum.map_join("", fn byte ->
        "%" <> String.upcase(Integer.to_string(byte, 16) |> String.pad_leading(2, "0"))
      end)

    do_percent_encode_opaque_path(rest, [encoded | acc])
  end

  defp do_percent_encode_opaque_path(<<char::utf8, rest::binary>>, acc) do
    do_percent_encode_opaque_path(rest, [<<char::utf8>> | acc])
  end

  defp windows_drive_root_path?(path) do
    String.match?(path, ~r/^\/[A-Za-z]:\/$/)
  end

  defp windows_drive_prefix?(path) do
    String.match?(path, ~r/^\/[A-Za-z]:\//)
  end

  defp windows_drive_root(path) do
    [prefix | _rest] = Regex.run(~r/^\/[A-Za-z]:\//, path)
    prefix
  end

  defp parse_userinfo(nil), do: {"", ""}

  defp parse_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [username, password] -> {username, password}
      [username] -> {username, ""}
    end
  end

  defp href_from_base(%{__struct__: Web.URL} = base), do: Web.URL.href(base)
  defp href_from_base(base) when is_binary(base), do: base
  defp href_from_base(_base), do: ""

  defp special_authority_contains_null?(source) do
    case split_scheme(source) do
      {:ok, _scheme, "//" <> rest} ->
        authority = rest |> String.split(["/", "?", "#"], parts: 2) |> hd()
        String.contains?(authority, <<0>>)

      _ ->
        false
    end
  end
end
