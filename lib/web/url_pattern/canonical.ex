defmodule Web.URLPattern.Canonical do
  @moduledoc false

  # The encoding callbacks of the URL Pattern Standard ("3.1. Encoding
  # callbacks"). Each callback validates and encodes a text with the steps
  # of the basic URL parser of the URL Standard, on the dummy URL
  # "https://dummy.invalid/". Each failure raises `Web.TypeError`.
  #
  # The callbacks run the parser states with a state override directly. The
  # state override does not stop at "?" or "#" in the path state, the query
  # state, and the fragment state. Thus a full URL parse of a text cannot
  # give the same result.

  alias Web.Internal.Ascii
  alias Web.URL
  alias Web.URL.{Encoding, IP}

  @default_ports %{"ftp" => 21, "http" => 80, "https" => 443, "ws" => 80, "wss" => 443}

  @doc false
  @spec special_scheme?(String.t()) :: boolean()
  def special_scheme?(scheme), do: scheme in ["ftp", "file", "http", "https", "ws", "wss"]

  @doc false
  @spec default_port(String.t()) :: non_neg_integer() | nil
  def default_port(scheme), do: Map.get(@default_ports, scheme)

  @doc false
  # "Canonicalize a protocol".
  @spec protocol(String.t()) :: String.t()
  def protocol(""), do: ""

  def protocol(value) do
    case URL.parse(value <> "://dummy.invalid/") do
      %URL{protocol: protocol} -> String.replace_suffix(protocol, ":", "")
      nil -> invalid("protocol")
    end
  end

  @doc false
  # "Canonicalize a username" and "canonicalize a password": the userinfo
  # percent-encode set.
  @spec userinfo(String.t()) :: String.t()
  def userinfo(value), do: Encoding.encode_userinfo_component(value)

  @doc false
  # "Canonicalize a hostname": the hostname state with a state override.
  @spec hostname(String.t()) :: String.t()
  def hostname(""), do: ""

  def hostname(value) do
    case value |> Encoding.strip_tab_newline() |> host_buffer(false, []) do
      {:ok, ""} -> invalid("hostname")
      {:ok, buffer} -> host(buffer)
      :error -> invalid("hostname")
    end
  end

  # The code points of the host, up to the end, "/", "?", "#", or "\". A ":"
  # that is not in brackets is a failure with the hostname state override.
  defp host_buffer(<<char, _rest::binary>>, _brackets?, acc) when char in ~c"/?#\\",
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp host_buffer(<<?:, _rest::binary>>, false, _acc), do: :error
  defp host_buffer(<<?[, rest::binary>>, _brackets?, acc), do: host_buffer(rest, true, [?[ | acc])

  defp host_buffer(<<?], rest::binary>>, _brackets?, acc),
    do: host_buffer(rest, false, [?] | acc])

  defp host_buffer(<<code_point::utf8, rest::binary>>, brackets?, acc),
    do: host_buffer(rest, brackets?, [<<code_point::utf8>> | acc])

  defp host_buffer(<<>>, _brackets?, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  # "Host parsing" of a special URL, and the serialization of the host.
  defp host(buffer) do
    if IP.valid_host?(buffer, "https:") do
      host = IP.normalize_host(buffer, "https:")
      if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
    else
      invalid("hostname")
    end
  end

  @doc false
  # "Canonicalize an IPv6 hostname".
  @spec ipv6_hostname(String.t()) :: String.t()
  def ipv6_hostname(value) do
    for <<char <- value>>, into: "" do
      if char in ?0..?9 or char in ?a..?f or char in ?A..?F or char in ~c"[]:",
        do: <<downcase(char)>>,
        else: invalid("hostname")
    end
  end

  defp downcase(char) when char in ?A..?Z, do: char + 32
  defp downcase(char), do: char

  @doc false
  # "Canonicalize a port": the port state with a state override. The
  # scheme gives the default port, which is the empty string.
  @spec port(String.t(), String.t() | nil) :: String.t()
  def port(value, scheme \\ nil)
  def port("", _scheme), do: ""

  def port(value, scheme) do
    case value |> Encoding.strip_tab_newline() |> Ascii.split_digits() do
      {"", _rest} ->
        invalid("port")

      {digits, _rest} ->
        number = String.to_integer(digits)

        cond do
          number > 65_535 -> invalid("port")
          number == default_port(scheme || "") -> ""
          true -> Integer.to_string(number)
        end
    end
  end

  @doc false
  # "Canonicalize a pathname": the path start state with a state override.
  # "/-" before a value with no leading "/" keeps the parser from adding a
  # "/" and from reading a "." at the start as a dot segment.
  @spec pathname(String.t()) :: String.t()
  def pathname(""), do: ""

  def pathname(value) do
    leading_slash? = String.starts_with?(value, "/")
    modified = if leading_slash?, do: value, else: "/-" <> value

    # The path start state of a special URL reads the "/" at the start.
    "/" <> rest = Encoding.strip_tab_newline(modified)
    path = path_segments(rest, [], [])

    result = Enum.map_join(path, &("/" <> &1))

    if leading_slash?, do: result, else: String.slice(result, 2..-1//1)
  end

  # The path state of a special URL with a state override: "/" and "\" end
  # a segment, and "?" and "#" are a part of the segment.
  defp path_segments(<<char, rest::binary>>, buffer, path) when char in ~c"/\\" do
    path = end_segment(buffer, path, true)
    path_segments(rest, [], path)
  end

  defp path_segments(<<code_point::utf8, rest::binary>>, buffer, path),
    do: path_segments(rest, [encode_path(code_point) | buffer], path)

  defp path_segments(<<>>, buffer, path), do: buffer |> end_segment(path, false) |> Enum.reverse()

  defp end_segment(buffer, path, slash?) do
    segment = buffer |> Enum.reverse() |> IO.iodata_to_binary()

    case Encoding.dot_segment_type(segment) do
      :double -> path |> shorten() |> add_empty_segment(not slash?)
      :single -> add_empty_segment(path, not slash?)
      :none -> [segment | path]
    end
  end

  defp shorten([]), do: []
  defp shorten([_last | path]), do: path

  defp add_empty_segment(path, true), do: ["" | path]
  defp add_empty_segment(path, false), do: path

  # The path percent-encode set.
  defp encode_path(code_point)
       when code_point in ~c" \"#<>?^`{}" or code_point < 0x20 or code_point > 0x7E,
       do: percent_encode(code_point)

  defp encode_path(code_point), do: <<code_point>>

  @doc false
  # "Canonicalize an opaque pathname": the opaque path state with a state
  # override. A "?" or a "#" ends the path.
  @spec opaque_pathname(String.t()) :: String.t()
  def opaque_pathname(value), do: value |> Encoding.strip_tab_newline() |> opaque_path([])

  defp opaque_path(<<char, _rest::binary>>, acc) when char in ~c"?#", do: finish(acc)

  defp opaque_path(<<?\s, rest::binary>>, acc) do
    space = if String.starts_with?(rest, ["?", "#"]), do: "%20", else: " "
    opaque_path(rest, [space | acc])
  end

  defp opaque_path(<<code_point::utf8, rest::binary>>, acc)
       when code_point < 0x20 or code_point > 0x7E,
       do: opaque_path(rest, [percent_encode(code_point) | acc])

  defp opaque_path(<<char, rest::binary>>, acc), do: opaque_path(rest, [char | acc])
  defp opaque_path(<<>>, acc), do: finish(acc)

  @doc false
  # "Canonicalize a search": the query state of a special URL with a state
  # override.
  @spec search(String.t()) :: String.t()
  def search(value),
    do: value |> Encoding.strip_tab_newline() |> Encoding.encode_query_component(true)

  @doc false
  # "Canonicalize a hash": the fragment state with a state override.
  @spec hash(String.t()) :: String.t()
  def hash(value),
    do: value |> Encoding.strip_tab_newline() |> Encoding.encode_fragment_component()

  defp percent_encode(code_point),
    do: for(<<(byte <- <<code_point::utf8>>)>>, into: "", do: "%" <> Base.encode16(<<byte>>))

  defp finish(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp invalid(component),
    do: raise(Web.TypeError, "The #{component} of the pattern is not valid.")
end
