defmodule Web.URL do
  @moduledoc """
  An implementation of the WHATWG URL standard.

  Provides a pure data structure representing a URL, compatible with both standard URLs
  and RClone-style URLs.
  """

  defstruct protocol: "",
            hostname: "",
            port: "",
            pathname: "",
            hash: "",
            search_params: Web.URLSearchParams.new(),
            kind: :standard

  @type t :: %__MODULE__{
          protocol: String.t(),
          hostname: String.t(),
          port: String.t(),
          pathname: String.t(),
          hash: String.t(),
          search_params: Web.URLSearchParams.t(),
          kind: :standard | :rclone
        }

  @rclone_scheme ~r/^[A-Za-z0-9_+.-]+:(?!\/\/)/

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
    cond do
      rclone_url?(url) ->
        parse_rclone(url)

      base != nil ->
        base
        |> href_from_base()
        |> URI.parse()
        |> URI.merge(url)
        |> URI.to_string()
        |> parse_standard()

      true ->
        parse_standard(url)
    end
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
    case url.kind do
      :rclone ->
        url.protocol <> url.pathname <> search(url) <> url.hash

      :standard ->
        path = standard_path_for_href(url) || ""

        cond do
          url.hostname != "" ->
            url.protocol <> "//" <> host(url) <> path <> search(url) <> url.hash

          url.protocol != "" ->
            url.protocol <> path <> search(url) <> url.hash

          true ->
            path <> search(url) <> url.hash
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
    %{url | protocol: normalize_protocol(value)}
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
  def host(%__MODULE__{hostname: hostname, port: ""}), do: hostname
  def host(%__MODULE__{hostname: hostname, port: port}), do: hostname <> ":" <> port

  @spec host(t(), String.t()) :: t()
  def host(%__MODULE__{} = url, value) do
    {hostname, port} =
      case String.split(to_string(value), ":", parts: 2) do
        [host] -> {host, ""}
        [host_port, value_port] -> {host_port, value_port}
      end

    normalized = %{url | kind: :standard, hostname: hostname, port: port}
    %{normalized | pathname: normalize_path(normalized, url.pathname)}
  end

  @doc """
  Returns the hostname portion of the URL.

  ## Examples

      iex> url = Web.URL.new("https://example.com:4000/api")
      iex> Web.URL.hostname(url)
      "example.com"
  """
  @spec hostname(t()) :: String.t()
  def hostname(%__MODULE__{} = url), do: url.hostname

  @doc """
  Sets the hostname portion of the URL.

  ## Examples

      iex> url = Web.URL.new("https://example.com")
      iex> Web.URL.set_hostname(url, "google.com") |> Web.URL.hostname()
      "google.com"
  """
  @spec set_hostname(t(), String.t()) :: t()
  def set_hostname(%__MODULE__{} = url, value) do
    normalized = %{url | kind: :standard, hostname: to_string(value)}
    %{normalized | pathname: normalize_path(normalized, url.pathname)}
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
    port =
      case value do
        nil -> ""
        "" -> ""
        int when is_integer(int) -> Integer.to_string(int)
        binary -> to_string(binary)
      end

    %{url | kind: :standard, port: port}
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
    %{url | pathname: normalize_path(url, to_string(value))}
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
    case Web.URLSearchParams.to_string(url.search_params) do
      "" -> ""
      query -> "?" <> query
    end
  end

  @spec search(t(), String.t()) :: t()
  def search(%__MODULE__{} = url, value) do
    query = if String.starts_with?(value, "?"), do: String.slice(value, 1..-1//1), else: value
    %{url | search_params: Web.URLSearchParams.new(query)}
  end

  @doc """
  Returns the hash portion of the URL, including the '#'.

  ## Examples

      iex> url = Web.URL.new("https://example.com/#top")
      iex> Web.URL.hash(url)
      "#top"
  """
  @spec hash(t()) :: String.t()
  def hash(%__MODULE__{} = url), do: url.hash

  @spec hash(t(), String.t()) :: t()
  def hash(%__MODULE__{} = url, value) do
    normalized =
      case to_string(value) do
        "" -> ""
        "#" <> _ = hash -> hash
        hash -> "#" <> hash
      end

    %{url | hash: normalized}
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
  def origin(%__MODULE__{hostname: ""}), do: "null"
  def origin(%__MODULE__{} = url), do: url.protocol <> "//" <> host(url)

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

  defp href_from_base(%__MODULE__{} = base), do: href(base)
  defp href_from_base(base) when is_binary(base), do: href(new(base))

  defp rclone_url?(value), do: String.match?(value, @rclone_scheme)

  defp parse_standard(value) do
    uri = URI.parse(value)
    protocol = normalize_protocol(uri.scheme)
    hostname = uri.host || ""
    explicit_port? = explicit_port?(uri)
    port = if explicit_port? and uri.port, do: Integer.to_string(uri.port), else: ""
    path = normalize_path(%{kind: :standard, hostname: hostname}, uri.path || "")

    %__MODULE__{
      kind: :standard,
      protocol: protocol,
      hostname: hostname,
      port: port,
      pathname: path,
      search_params: Web.URLSearchParams.new(uri.query || ""),
      hash: if(uri.fragment, do: "#" <> uri.fragment, else: "")
    }
  end

  defp explicit_port?(%URI{authority: authority}) when is_binary(authority) do
    String.match?(authority, ~r/:\d+$/)
  end

  defp explicit_port?(_uri), do: false

  defp parse_rclone(value) do
    [scheme, rest] = String.split(value, ":", parts: 2)
    {path_and_query, hash} = split_once(rest, "#")
    {path, query} = split_once(path_and_query, "?")

    %__MODULE__{
      kind: :rclone,
      protocol: normalize_protocol(scheme),
      hostname: "",
      port: "",
      pathname: path,
      search_params: Web.URLSearchParams.new(query),
      hash: if(hash == "", do: "", else: "#" <> hash)
    }
  end

  defp split_once(value, separator) do
    case String.split(value, separator, parts: 2) do
      [left, right] -> {left, right}
      [left] -> {left, ""}
    end
  end

  defp standard_path_for_href(%{hostname: hostname, pathname: pathname})
       when hostname != "" and pathname == "" do
    "/"
  end

  defp standard_path_for_href(%{pathname: pathname}), do: empty_to_nil(pathname)

  defp normalize_protocol(nil), do: ""
  defp normalize_protocol(""), do: ""

  defp normalize_protocol(value) do
    protocol = to_string(value)
    if String.ends_with?(protocol, ":"), do: protocol, else: protocol <> ":"
  end

  defp normalize_path(%{kind: :rclone}, path), do: to_string(path)

  defp normalize_path(%{hostname: hostname}, path) do
    path = to_string(path)

    cond do
      hostname != "" and path == "" -> "/"
      path == "" -> ""
      String.starts_with?(path, "/") -> path
      true -> "/" <> path
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
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
