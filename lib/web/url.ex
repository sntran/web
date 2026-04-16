defmodule Web.URL do
  @moduledoc """
  An implementation of the WHATWG URL standard.

  Provides a pure data structure representing a URL, compatible with both standard URLs
  and RClone-style URLs.
  """

  alias Web.URL.{Encoding, IP, Parser}

  defstruct protocol: "",
            username: "",
            password: "",
            hostname: "",
            port: "",
            pathname: "",
            search: nil,
            fragment: nil,
            hash: "",
            search_params: Web.URLSearchParams.new(),
            authority_present?: false,
            search_present?: false,
            hash_present?: false,
            kind: :standard

  @type t :: %__MODULE__{
          protocol: String.t(),
          username: String.t(),
          password: String.t(),
          hostname: String.t(),
          port: String.t(),
          pathname: String.t(),
          search: String.t() | nil,
          fragment: String.t() | nil,
          hash: String.t(),
          search_params: Web.URLSearchParams.t(),
          authority_present?: boolean(),
          search_present?: boolean(),
          hash_present?: boolean(),
          kind: :standard | :rclone
        }

  @rclone_scheme ~r/^[A-Za-z0-9.+-]*_[A-Za-z0-9_+.-]*:(?!\/\/)/

  @doc """
  Creates a URL from a string and optional base URL.

  ## Examples

      iex> url = Web.URL.new("https://example.com/search?q=elixir#docs")
      iex> {Web.URL.protocol(url), Web.URL.pathname(url), Web.URL.hash(url)}
      {"https:", "/search", "#docs"}

      iex> url = Web.URL.new("remote:path/to/file")
      iex> {Web.URL.protocol(url), Web.URL.pathname(url)}
      {"remote:", "path/to/file"}
  """
  @spec new(String.t() | t(), String.t() | t() | nil) :: t()
  def new(url, base \\ nil)

  def new(%__MODULE__{} = url, _base), do: url

  def new(url, base) when is_binary(url) do
    trimmed = Encoding.trim_c0_whitespace(url)

    if rclone_url?(trimmed), do: parse_rclone(trimmed), else: parse_standard(trimmed, base)
  end

  @doc """
  Returns the serialized URL (href).

  ## Examples

      iex> url = Web.URL.new("https://example.com/search?q=elixir#docs")
      iex> Web.URL.href(url)
      "https://example.com/search?q=elixir#docs"
  """
  @spec href(t()) :: String.t()
  def href(%__MODULE__{} = url) do
    search = serialize_search(url)
    hash = serialize_fragment(url)

    case url.kind do
      :rclone ->
        url.protocol <> url.pathname <> search <> hash

      :standard ->
        path = standard_path_for_href(url) || ""
        authority_prefix = credentials_prefix(url)

        cond do
          has_authority?(url) ->
            url.protocol <> "//" <> authority_prefix <> host(url) <> path <> search <> hash

          url.protocol != "" ->
            url.protocol <> path <> search <> hash

          true ->
            path <> search <> hash
        end
    end
  end

  @spec href(t(), String.t()) :: t()
  def href(%__MODULE__{} = _url, value) do
    new(value)
  end

  @doc """
  Returns the protocol portion of the URL.

  ## Examples

      iex> url = Web.URL.new("https://example.com")
      iex> Web.URL.protocol(url)
      "https:"
  """
  @spec protocol(t()) :: String.t()
  def protocol(%__MODULE__{} = url), do: url.protocol

  @doc """
  Sets the protocol of the URL.

  ## Examples

      iex> url = Web.URL.new("https://example.com")
      iex> Web.URL.set_protocol(url, "ftp") |> Web.URL.protocol()
      "ftp:"
  """
  @spec set_protocol(t(), String.t()) :: t()
  def set_protocol(%__MODULE__{} = url, value) do
    protocol =
      value
      |> to_string()
      |> Encoding.strip_ascii_tab_and_newline()
      |> String.split(":", parts: 2)
      |> hd()
      |> String.downcase()

    if String.match?(protocol, ~r/^[a-z][a-z0-9+.-]*$/) and
         protocol_transition_allowed?(url, protocol) do
      try do
        updated =
          url
          |> href()
          |> String.replace_prefix(url.protocol, protocol <> ":")
          |> new()

        if updated.pathname == "/" and has_authority?(updated) and
             not Parser.special_scheme?(updated.protocol) and updated.protocol != "file:" do
          %{updated | pathname: ""}
        else
          updated
        end
      rescue
        ArgumentError -> url
      end
    else
      url
    end
  end

  @doc """
  Returns the host portion (hostname and port) of the URL.

  ## Examples

      iex> url = Web.URL.new("https://example.com:4000/api")
      iex> Web.URL.host(url)
      "example.com:4000"
  """
  @spec host(t()) :: String.t()
  def host(%__MODULE__{hostname: "", port: _port}), do: ""

  def host(%__MODULE__{hostname: hostname, port: ""}) do
    maybe_bracket_ipv6(hostname)
  end

  def host(%__MODULE__{hostname: hostname, port: port}) do
    maybe_bracket_ipv6(hostname) <> ":" <> port
  end

  @spec host(t(), String.t()) :: t()
  def host(%__MODULE__{} = url, value) do
    candidate =
      value
      |> to_string()
      |> Encoding.strip_ascii_tab_and_newline()
      |> String.split(host_setter_delimiters(url.protocol), parts: 2)
      |> hd()

    {hostname, port} = IP.split_host_and_port(candidate)
    normalized_port = normalize_host_setter_port(url.port, candidate, port)

    case host_update_mode(url, hostname, port) do
      :invalid ->
        url

      :special ->
        update_special_host(url, hostname, normalized_port)

      :clear_credentials ->
        clear_empty_authority_credentials(url)

      :opaque ->
        update_opaque_host(url, hostname, normalized_port)
    end
  end

  @doc """
  Returns the hostname portion of the URL.

  ## Examples

      iex> url = Web.URL.new("https://example.com:4000/api")
      iex> Web.URL.hostname(url)
      "example.com"
  """
  @spec hostname(t()) :: String.t()
  def hostname(%__MODULE__{} = url), do: maybe_bracket_ipv6(url.hostname)

  @doc """
  Sets the hostname portion of the URL.

  ## Examples

      iex> url = Web.URL.new("https://example.com")
      iex> Web.URL.set_hostname(url, "google.com") |> Web.URL.hostname()
      "google.com"
  """
  @spec set_hostname(t(), String.t()) :: t()
  def set_hostname(%__MODULE__{} = url, value) do
    candidate =
      value
      |> to_string()
      |> Encoding.strip_ascii_tab_and_newline()
      |> String.split(host_setter_delimiters(url.protocol), parts: 2)
      |> hd()

    case hostname_update_mode(url, candidate) do
      :invalid ->
        url

      :special ->
        update_special_hostname(url, candidate)

      :clear_credentials ->
        clear_empty_authority_credentials(url)

      :opaque ->
        update_opaque_hostname(url, candidate)
    end
  end

  @doc """
  Returns the username portion of the URL.
  """
  @spec username(t()) :: String.t()
  def username(%__MODULE__{} = url), do: url.username

  @doc """
  Sets the username portion of the URL using URL userinfo percent-encoding.
  """
  @spec set_username(t(), String.t()) :: t()
  def set_username(%__MODULE__{} = url, value) do
    if url.protocol != "file:" and has_authority?(url) and url.hostname != "" do
      encoded = Encoding.encode_userinfo_component(value)

      %{
        url
        | username: encoded,
          kind: :standard,
          authority_present?: authority_present_after_update?(url, encoded)
      }
    else
      url
    end
  end

  @doc """
  Returns the password portion of the URL.
  """
  @spec password(t()) :: String.t()
  def password(%__MODULE__{} = url), do: url.password

  @doc """
  Sets the password portion of the URL using URL userinfo percent-encoding.
  """
  @spec set_password(t(), String.t()) :: t()
  def set_password(%__MODULE__{} = url, value) do
    if url.protocol != "file:" and has_authority?(url) and url.hostname != "" do
      encoded = Encoding.encode_userinfo_component(value)

      %{
        url
        | password: encoded,
          kind: :standard,
          authority_present?: authority_present_after_update?(url, encoded)
      }
    else
      url
    end
  end

  @doc """
  Returns the port portion of the URL.

  ## Examples

      iex> url = Web.URL.new("https://example.com:4000")
      iex> Web.URL.port(url)
      "4000"
  """
  @spec port(t()) :: String.t()
  def port(%__MODULE__{} = url), do: url.port

  @doc """
  Sets the port portion of the URL.

  ## Examples

      iex> url = Web.URL.new("https://example.com")
      iex> Web.URL.set_port(url, 8080) |> Web.URL.port()
      "8080"
  """
  @spec set_port(t(), String.t() | integer() | nil) :: t()
  def set_port(%__MODULE__{} = url, value) do
    if url.protocol == "file:" or url.hostname == "" do
      %{url | kind: :standard, port: ""}
    else
      port =
        case value do
          nil ->
            ""

          "" ->
            ""

          int when is_integer(int) ->
            Integer.to_string(int)

          binary ->
            normalize_port_setter_value(url.port, binary)
        end

      %{url | kind: :standard, port: normalize_default_port_for_setter(url.protocol, port)}
    end
  end

  @doc """
  Returns the pathname portion of the URL.

  ## Examples

      iex> url = Web.URL.new("https://example.com/api/v1")
      iex> Web.URL.pathname(url)
      "/api/v1"
  """
  @spec pathname(t()) :: String.t()
  def pathname(%__MODULE__{} = url), do: url.pathname

  @doc """
  Sets the pathname portion of the URL.

  ## Examples

      iex> url = Web.URL.new("https://example.com")
      iex> Web.URL.set_pathname(url, "new-path") |> Web.URL.pathname()
      "/new-path"
  """
  @spec set_pathname(t(), String.t()) :: t()
  def set_pathname(%__MODULE__{} = url, value) do
    if opaque_path_url?(url) do
      url
    else
      %{
        url
        | pathname:
            normalize_path(url, value |> to_string() |> Encoding.strip_ascii_tab_and_newline())
      }
    end
  end

  @doc """
  Returns the search (query) portion of the URL, including the '?'.

  ## Examples

      iex> url = Web.URL.new("https://example.com/search?q=elixir")
      iex> Web.URL.search(url)
      "?q=elixir"
  """
  @spec search(t()) :: String.t()
  def search(%__MODULE__{} = url) do
    case effective_search(url) do
      nil -> ""
      "" when url.search_present? -> "?"
      "" -> ""
      search -> "?" <> search
    end
  end

  @spec search(t(), String.t()) :: t()
  def search(%__MODULE__{} = url, value) do
    normalized = value |> to_string() |> Encoding.strip_ascii_tab_and_newline()

    case normalized do
      "" ->
        put_search(url, nil)

      "?" ->
        put_search(url, "")

      search ->
        stripped =
          if String.starts_with?(search, "?"), do: String.slice(search, 1..-1//1), else: search

        encoded = Encoding.encode_query_component(stripped, Parser.special_scheme?(url.protocol))
        put_search(url, encoded)
    end
  end

  @doc """
  Returns the hash portion of the URL, including the '#'.

  ## Examples

      iex> url = Web.URL.new("https://example.com/#top")
      iex> Web.URL.hash(url)
      "#top"
  """
  @spec hash(t()) :: String.t()
  def hash(%__MODULE__{fragment: nil}), do: ""
  def hash(%__MODULE__{fragment: "", hash_present?: true}), do: "#"
  def hash(%__MODULE__{fragment: ""}), do: ""
  def hash(%__MODULE__{fragment: fragment}), do: "#" <> fragment

  @spec hash(t(), String.t()) :: t()
  def hash(%__MODULE__{} = url, value) do
    case value |> to_string() |> Encoding.strip_ascii_tab_and_newline() do
      "" ->
        put_fragment(url, nil)

      "#" ->
        put_fragment(url, "")

      "#" <> fragment ->
        put_fragment(url, Encoding.encode_fragment_component(fragment))

      fragment ->
        put_fragment(url, Encoding.encode_fragment_component(fragment))
    end
  end

  @doc """
  Returns the origin of the URL.

  ## Examples

      iex> url = Web.URL.new("https://example.com:4000/api")
      iex> Web.URL.origin(url)
      "https://example.com:4000"
  """
  @spec origin(t()) :: String.t()
  def origin(%__MODULE__{kind: :rclone}), do: "null"

  def origin(%__MODULE__{protocol: "blob:", pathname: pathname}) do
    embedded = new(pathname)

    if embedded.protocol in ["http:", "https:", "file:"] do
      origin(embedded)
    else
      "null"
    end
  rescue
    ArgumentError -> "null"
  end

  def origin(%__MODULE__{protocol: "file:"}), do: "null"
  def origin(%__MODULE__{hostname: ""}), do: "null"

  def origin(%__MODULE__{} = url) do
    if Parser.special_scheme?(url.protocol) do
      url.protocol <> "//" <> host(url)
    else
      "null"
    end
  end

  @doc """
  Returns the search params as a Web.URLSearchParams struct.

  ## Examples

      iex> url = Web.URL.new("https://example.com/search?q=elixir")
      iex> params = Web.URL.search_params(url)
      iex> Web.URLSearchParams.get(params, "q")
      "elixir"
  """
  @spec search_params(t()) :: Web.URLSearchParams.t()
  def search_params(%__MODULE__{} = url), do: url.search_params

  @spec rclone?(t()) :: boolean()
  def rclone?(%__MODULE__{} = url), do: url.kind == :rclone

  defp rclone_url?(value), do: String.match?(value, @rclone_scheme)

  defp parse_standard(value, base) do
    value
    |> Parser.parse!(base)
    |> then(&struct(__MODULE__, &1))
  end

  defp parse_rclone(value) do
    [scheme, rest] = String.split(value, ":", parts: 2)
    {path_and_search, hash} = split_once(rest, "#")
    {path, search} = split_once(path_and_search, "?")
    search_value = search_value(path_and_search, search)
    fragment_value = fragment_value(rest, hash)
    protocol = normalize_protocol(scheme)
    normalized_search = normalize_search_value(search_value, protocol)

    %__MODULE__{
      kind: :rclone,
      protocol: protocol,
      username: "",
      password: "",
      hostname: "",
      port: "",
      pathname: path,
      search: normalized_search,
      fragment: normalize_fragment_value(fragment_value),
      search_params: Web.URLSearchParams.new(normalized_search || ""),
      hash: hash_value(normalize_fragment_value(fragment_value)),
      authority_present?: false,
      search_present?: String.contains?(path_and_search, "?"),
      hash_present?: String.contains?(rest, "#")
    }
  end

  defp split_once(value, separator) do
    case String.split(value, separator, parts: 2) do
      [left, right] -> {left, right}
      [left] -> {left, ""}
    end
  end

  defp standard_path_for_href(%{pathname: pathname, protocol: protocol}) when pathname == "" do
    if protocol == "file:" or Parser.special_scheme?(protocol) or protocol == "mock:" do
      "/"
    else
      nil
    end
  end

  defp standard_path_for_href(%__MODULE__{} = url) do
    if not has_authority?(url) and url.protocol != "" and
         not Parser.special_scheme?(url.protocol) and
         String.starts_with?(url.pathname, "//") do
      "/." <> url.pathname
    else
      url.pathname
    end
  end

  defp serialize_search(%__MODULE__{} = url) do
    case effective_search(url) do
      nil -> ""
      search -> "?" <> search
    end
  end

  defp serialize_fragment(%__MODULE__{fragment: nil}), do: ""
  defp serialize_fragment(%__MODULE__{fragment: fragment}), do: "#" <> fragment

  defp put_search(%__MODULE__{} = url, nil) do
    %{url | search: nil, search_params: Web.URLSearchParams.new(), search_present?: false}
  end

  defp put_search(%__MODULE__{} = url, search) do
    %{url | search: search, search_params: Web.URLSearchParams.new(search), search_present?: true}
  end

  defp put_fragment(%__MODULE__{} = url, nil) do
    %{url | fragment: nil, hash: "", hash_present?: false}
  end

  defp put_fragment(%__MODULE__{} = url, fragment) do
    %{url | fragment: fragment, hash: hash_value(fragment), hash_present?: true}
  end

  defp search_value(input, search) do
    if String.contains?(input, "?"), do: search, else: nil
  end

  defp fragment_value(input, fragment) do
    if String.contains?(input, "#"), do: fragment, else: nil
  end

  defp normalize_search_value(nil, _protocol), do: nil

  defp normalize_search_value(search, protocol) do
    Encoding.encode_query_component(search, Parser.special_scheme?(protocol))
  end

  defp effective_search(%__MODULE__{search: nil}), do: nil

  defp effective_search(%__MODULE__{} = url) do
    derived = Web.URLSearchParams.new(url.search || "")

    if url.search_params == derived do
      url.search
    else
      Web.URLSearchParams.to_string(url.search_params)
    end
  end

  defp normalize_fragment_value(nil), do: nil
  defp normalize_fragment_value(fragment), do: Encoding.encode_fragment_component(fragment)

  defp hash_value(nil), do: ""
  defp hash_value(""), do: ""
  defp hash_value(fragment), do: "#" <> fragment

  defp normalize_protocol(value) do
    protocol = to_string(value || "")

    protocol <> String.duplicate(":", min(byte_size(protocol), 1))
  end

  defp normalize_path(%{protocol: "file:", hostname: hostname}, path) do
    path
    |> to_string()
    |> String.replace("\\", "/")
    |> remove_dot_segments(true)
    |> Encoding.encode_path_component()
    |> normalize_file_drive_path()
    |> ensure_leading_slash(hostname)
  end

  defp normalize_path(%{hostname: hostname, protocol: protocol} = url, path) do
    path =
      path
      |> to_string()
      |> normalize_path_input(protocol)
      |> remove_dot_segments(false)
      |> Encoding.encode_path_component()

    finalize_normalized_path(path, hostname, protocol, path_only_hierarchical_url?(url))
  end

  defp normalize_port_value(current_port, value) do
    stripped = value |> to_string() |> Encoding.strip_ascii_tab_and_newline()

    case Regex.run(~r/^\d+/, stripped) do
      [digits] ->
        if String.to_integer(digits) <= 65_535 do
          digits
        else
          current_port
        end

      nil ->
        current_port
    end
  end

  defp normalize_port_setter_value(current_port, value) do
    stripped = value |> to_string() |> Encoding.strip_ascii_tab_and_newline()

    if stripped == "" and value != "",
      do: current_port,
      else: normalize_port_value(current_port, stripped)
  end

  defp normalize_host_setter_port(current_port, candidate, port) do
    if host_value_includes_port?(candidate) do
      if port == "" do
        current_port
      else
        normalize_port_value(current_port, port)
      end
    else
      current_port
    end
  end

  defp host_setter_delimiters(protocol) do
    if Parser.special_scheme?(protocol) do
      ["/", "?", "#", "\\"]
    else
      ["/", "?", "#"]
    end
  end

  defp host_value_includes_port?(candidate) do
    if String.starts_with?(candidate, "[") do
      Regex.match?(~r/^\[[^\]]+\]:/, candidate)
    else
      String.contains?(candidate, ":")
    end
  end

  defp normalize_default_port_for_setter(protocol, port) do
    if Parser.special_scheme?(protocol) and port == IP.default_port(protocol) do
      ""
    else
      port
    end
  end

  defp opaque_path_url?(%__MODULE__{} = url) do
    not has_authority?(url) and url.protocol != "" and not String.starts_with?(url.pathname, "/")
  end

  defp path_only_hierarchical_url?(%__MODULE__{} = url) do
    not has_authority?(url) and url.protocol != "" and String.starts_with?(url.pathname, "/")
  end

  defp has_authority?(%__MODULE__{} = url) do
    url.authority_present? or
      url.hostname != "" or url.username != "" or url.password != "" or url.protocol == "file:"
  end

  defp authority_present_after_update?(url, updated_component) do
    has_authority?(url) or updated_component != ""
  end

  defp protocol_transition_allowed?(%__MODULE__{} = url, protocol) do
    current_special? = Parser.special_scheme?(url.protocol)
    next_special? = Parser.special_scheme?(protocol <> ":")

    not ((current_special? and not next_special?) or
           (not current_special? and next_special?) or
           (protocol == "file" and credentials_or_port?(url)))
  end

  defp host_update_mode(url, hostname, port) do
    with :ok <- validate_host_path(url),
         :ok <- validate_empty_host_port(hostname, port),
         :ok <- validate_special_empty_host(url, hostname),
         :ok <- validate_file_port(url, port),
         :ok <- validate_empty_hostname_port(url, hostname) do
      next_host_update_mode(url, hostname)
    else
      :error -> :invalid
    end
  end

  defp hostname_update_mode(url, candidate) do
    with :ok <- validate_host_path(url),
         :ok <- validate_special_empty_host(url, candidate),
         :ok <- validate_empty_hostname_port(url, candidate) do
      next_hostname_update_mode(url, candidate)
    else
      :error -> :invalid
    end
  end

  defp next_host_update_mode(url, hostname) do
    cond do
      Parser.special_scheme?(url.protocol) -> :special
      hostname == "" and credentials_or_port?(url) -> :clear_credentials
      true -> :opaque
    end
  end

  defp next_hostname_update_mode(url, candidate) do
    cond do
      Parser.special_scheme?(url.protocol) -> :special
      candidate == "" and credentials_or_port?(url) -> :clear_credentials
      true -> :opaque
    end
  end

  defp validate_host_path(url) do
    if opaque_path_url?(url), do: :error, else: :ok
  end

  defp validate_empty_host_port(hostname, port) do
    if hostname == "" and port != "", do: :error, else: :ok
  end

  defp validate_special_empty_host(url, hostname) do
    if Parser.special_scheme?(url.protocol) and hostname == "" and url.protocol != "file:" do
      :error
    else
      :ok
    end
  end

  defp validate_file_port(url, port) do
    if url.protocol == "file:" and port != "", do: :error, else: :ok
  end

  defp validate_empty_hostname_port(url, hostname) do
    if hostname == "" and url.port != "", do: :error, else: :ok
  end

  defp update_special_host(url, hostname, normalized_port) do
    if hostname == "" or IP.valid_host?(hostname, url.protocol) do
      normalized_host = IP.normalize_host(hostname, url.protocol)

      normalized = %{
        url
        | kind: :standard,
          hostname: normalized_host,
          port: normalize_default_port_for_setter(url.protocol, normalized_port),
          authority_present?: authority_present_after_update?(url, normalized_host)
      }

      %{normalized | pathname: normalize_path(normalized, url.pathname)}
    else
      url
    end
  end

  defp update_special_hostname(url, candidate) do
    if candidate == "" or IP.valid_host?(candidate, url.protocol) do
      normalized_host = IP.normalize_host(candidate, url.protocol)

      normalized = %{
        url
        | kind: :standard,
          hostname: normalized_host,
          authority_present?: authority_present_after_update?(url, normalized_host)
      }

      %{normalized | pathname: normalize_path(normalized, url.pathname)}
    else
      url
    end
  end

  defp update_opaque_host(url, hostname, normalized_port) do
    if hostname == "" or IP.valid_opaque_host?(hostname) do
      normalized = %{
        url
        | kind: :standard,
          hostname: IP.normalize_opaque_host(hostname),
          port: if(hostname == "", do: "", else: normalized_port),
          authority_present?: true
      }

      %{normalized | pathname: normalize_path(normalized, url.pathname)}
    else
      url
    end
  end

  defp update_opaque_hostname(url, candidate) do
    if candidate == "" or IP.valid_opaque_host?(candidate) do
      normalized = %{
        url
        | kind: :standard,
          hostname: IP.normalize_opaque_host(candidate),
          port: if(candidate == "", do: "", else: url.port),
          authority_present?: true
      }

      %{normalized | pathname: normalize_path(normalized, url.pathname)}
    else
      url
    end
  end

  defp clear_empty_authority_credentials(url) do
    if url.hostname == "" do
      %{url | username: "", password: "", port: ""}
    else
      url
    end
  end

  defp normalize_path_input(value, protocol) do
    if Parser.special_scheme?(protocol) do
      String.replace(value, "\\", "/")
    else
      value
    end
  end

  defp finalize_normalized_path("", hostname, protocol, _hierarchical?)
       when hostname != "" and
              (protocol == "file:" or protocol in ["ftp:", "http:", "https:", "ws:", "wss:"]),
       do: "/"

  defp finalize_normalized_path("", hostname, _protocol, _hierarchical?) when hostname != "",
    do: ""

  defp finalize_normalized_path("", _hostname, _protocol, true), do: "/"
  defp finalize_normalized_path("", _hostname, _protocol, false), do: ""
  defp finalize_normalized_path("/" <> _ = path, _hostname, _protocol, _hierarchical?), do: path
  defp finalize_normalized_path(path, _hostname, _protocol, _hierarchical?), do: "/" <> path

  defp credentials_or_port?(url) do
    url.username != "" or url.password != "" or url.port != ""
  end

  defp credentials_prefix(%__MODULE__{username: "", password: ""}), do: ""
  defp credentials_prefix(%__MODULE__{username: username, password: ""}), do: username <> "@"

  defp credentials_prefix(%__MODULE__{username: username, password: password}),
    do: username <> ":" <> password <> "@"

  defp normalize_file_drive_path(path) do
    case path do
      <<drive::utf8, separator::utf8, rest::binary>>
      when ((drive >= ?A and drive <= ?Z) or (drive >= ?a and drive <= ?z)) and
             separator in [?:, ?|] ->
        "/" <> <<drive::utf8, ?:>> <> rest

      _ ->
        path
    end
  end

  defp remove_dot_segments(path, preserve_drive_root?) do
    raw_segments = String.split(path, "/", trim: false)

    trailing_directory? =
      raw_segments
      |> List.last()
      |> Kernel.||("")
      |> then(&(dot_segment_type(&1) in [:single, :double]))

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

  defp pop_path_segment(["", drive], true)
       when byte_size(drive) == 2 and binary_part(drive, 1, 1) == ":" do
    ["", drive]
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

  defp maybe_bracket_ipv6(hostname) do
    if String.contains?(hostname, ":") do
      "[" <> hostname <> "]"
    else
      hostname
    end
  end

  defp ensure_leading_slash("", _hostname), do: "/"

  defp ensure_leading_slash(path, hostname) do
    cond do
      String.starts_with?(path, "/") -> path
      hostname != "" -> "/" <> path
      true -> "/" <> path
    end
  end
end

defimpl String.Chars, for: Web.URL do
  def to_string(url), do: Web.URL.href(url)
end

defimpl Inspect, for: Web.URL do
  import Inspect.Algebra

  def inspect(url, _opts) do
    concat(["#Web.URL<", inspect(Web.URL.href(url)), ">"])
  end
end
