defmodule Web.URL.FastPath do
  @moduledoc false

  # A short parse for the usual URL of a request: an absolute URL with the
  # scheme http, https, ws, or wss, a host name of ASCII letters, digits,
  # and "-", an optional port, and a path, a query, and a fragment that need
  # no percent-encoding and have no dot segment.
  #
  # Each other input gives `:error`, and `Web.URL.new/2` uses the full
  # parser. For each input that this module accepts, the result is the same
  # as the result of the full parser: a property test compares the two.

  defguardp alpha?(char) when char in ?A..?Z or char in ?a..?z
  defguardp digit?(char) when char in ?0..?9

  alias Web.Internal.Ascii

  @default_ports %{"http" => "80", "https" => "443", "ws" => "80", "wss" => "443"}

  # The bytes that need no percent-encoding in a path, a query, and a
  # fragment of a special URL. The sets are smaller than the sets of the URL
  # Standard: a byte that is not in them goes to the full parser.
  defguardp unreserved?(char)
            when alpha?(char) or digit?(char) or char in [?-, ?., ?_, ?~]

  defguardp sub_delim?(char) when char in [?!, ?$, ?&, ?(, ?), ?*, ?+, ?,, ?;, ?=, ?:, ?@]

  defguardp path_byte?(char) when unreserved?(char) or sub_delim?(char) or char == ?'
  defguardp query_byte?(char) when unreserved?(char) or sub_delim?(char) or char in [?/, ??]

  defguardp fragment_byte?(char)
            when unreserved?(char) or sub_delim?(char) or char in [?/, ??, ?']

  @spec parse(binary()) :: {:ok, map()} | :error
  def parse(input) do
    with {:ok, scheme, rest} <- scheme(input),
         {:ok, host, rest} <- host(rest),
         {:ok, port, rest} <- port(rest, Map.fetch!(@default_ports, scheme)),
         {:ok, path, rest} <- path(rest),
         {:ok, search, rest} <- query(rest),
         {:ok, fragment} <- fragment(rest) do
      {:ok,
       %{
         kind: :standard,
         protocol: scheme <> ":",
         username: "",
         password: "",
         hostname: host,
         port: port,
         pathname: path,
         search: search,
         fragment: fragment,
         hash: if(fragment in [nil, ""], do: "", else: "#" <> fragment),
         search_params: Web.URLSearchParams.new(search || ""),
         authority_present?: true,
         search_present?: search != nil,
         hash_present?: fragment != nil
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Scheme
  # ---------------------------------------------------------------------------

  defp scheme(<<scheme::binary-size(4), "://", rest::binary>>), do: known_scheme(scheme, rest)
  defp scheme(<<scheme::binary-size(5), "://", rest::binary>>), do: known_scheme(scheme, rest)
  defp scheme(<<scheme::binary-size(2), "://", rest::binary>>), do: known_scheme(scheme, rest)
  defp scheme(<<scheme::binary-size(3), "://", rest::binary>>), do: known_scheme(scheme, rest)
  defp scheme(_input), do: :error

  defp known_scheme(scheme, rest) do
    scheme = Ascii.downcase(scheme)
    if is_map_key(@default_ports, scheme), do: {:ok, scheme, rest}, else: :error
  end

  # ---------------------------------------------------------------------------
  # Host
  # ---------------------------------------------------------------------------

  # Labels of letters, digits, and "-", with one "." between two labels. The
  # last label starts with a letter: thus the host is not an IPv4 address.
  # An IPv4 address in its serialized form is also accepted.
  defp host(rest) do
    case host_size(rest, 0, true) do
      {:ok, size} ->
        <<host::binary-size(^size), rest::binary>> = rest
        {:ok, Ascii.downcase(host), rest}

      :error ->
        ipv4(rest)
    end
  end

  # Four decimal numbers from 0 to 255, with no leading zero: the URL
  # Standard serializes such an address with no change.
  defp ipv4(rest) do
    size = ipv4_size(rest, 0)
    <<host::binary-size(^size), tail::binary>> = rest

    with true <- host_end?(tail),
         [_, _, _, _] = parts <- :binary.split(host, ".", [:global]),
         true <- Enum.all?(parts, &octet?/1) do
      {:ok, host, tail}
    else
      _other -> :error
    end
  end

  defp ipv4_size(<<char, rest::binary>>, size) when digit?(char) or char == ?.,
    do: ipv4_size(rest, size + 1)

  defp ipv4_size(_rest, size), do: size

  defp host_end?(<<>>), do: true
  defp host_end?(<<char, _rest::binary>>), do: char in [?:, ?/, ??, ?#]

  defp port_end?(<<>>), do: true
  defp port_end?(<<char, _rest::binary>>), do: char in [?/, ??, ?#]

  defp octet?("0"), do: true

  defp octet?(<<first, _rest::binary>> = part) when first in ?1..?9 and byte_size(part) <= 3,
    do: Ascii.digits?(part) and String.to_integer(part) <= 255

  defp octet?(_part), do: false

  # The state is `true` at the start of a label. A label that starts with a
  # letter continues as `{:label, true}`, each other label as
  # `{:label, false}`.
  defp host_size(<<char, _rest::binary>>, index, {:label, true})
       when char in [?:, ?/, ??, ?#],
       do: {:ok, index}

  defp host_size(<<>>, index, {:label, true}), do: {:ok, index}

  defp host_size(<<?., rest::binary>>, index, {:label, _letter?}),
    do: host_size(rest, index + 1, true)

  defp host_size(<<char, rest::binary>>, index, true) when alpha?(char),
    do: host_size(rest, index + 1, {:label, true})

  defp host_size(<<char, rest::binary>>, index, true) when digit?(char) or char == ?-,
    do: host_size(rest, index + 1, {:label, false})

  defp host_size(<<char, rest::binary>>, index, {:label, _letter?} = label)
       when alpha?(char) or digit?(char) or char == ?-,
       do: host_size(rest, index + 1, label)

  defp host_size(_rest, _index, _state), do: :error

  # ---------------------------------------------------------------------------
  # Port
  # ---------------------------------------------------------------------------

  # One to five digits with no leading zero, and not more than 65535. The
  # default port of the scheme is the empty port.
  defp port(":" <> rest, default) do
    with {<<first, _digits::binary>> = digits, rest} when first != ?0 <- Ascii.split_digits(rest),
         true <- byte_size(digits) <= 5 and port_end?(rest),
         true <- String.to_integer(digits) <= 65_535 do
      {:ok, if(digits == default, do: "", else: digits), rest}
    else
      _other -> :error
    end
  end

  defp port(rest, _default), do: {:ok, "", rest}

  # ---------------------------------------------------------------------------
  # Path, query, and fragment
  # ---------------------------------------------------------------------------

  # A path with no dot segment. An empty path is "/".
  defp path("/" <> _rest = rest) do
    case path_size(rest, 0, 0, 0) do
      {:ok, size} ->
        <<path::binary-size(^size), rest::binary>> = rest
        {:ok, path, rest}

      :error ->
        :error
    end
  end

  defp path(rest), do: {:ok, "/", rest}

  # `segment` is the index of the segment, and `dots` is the number of its
  # bytes that are ".", while all its bytes are ".".
  defp path_size(<<char, _rest::binary>>, index, segment, dots) when char in [??, ?#],
    do: end_segment(index, segment, dots)

  defp path_size(<<>>, index, segment, dots), do: end_segment(index, segment, dots)

  defp path_size(<<?/, rest::binary>>, index, segment, dots) do
    case end_segment(index, segment, dots) do
      {:ok, _size} -> path_size(rest, index + 1, index + 1, 0)
      :error -> :error
    end
  end

  defp path_size(<<?., rest::binary>>, index, segment, dots) when dots == index - segment,
    do: path_size(rest, index + 1, segment, dots + 1)

  defp path_size(<<char, rest::binary>>, index, segment, _dots) when path_byte?(char),
    do: path_size(rest, index + 1, segment, -1)

  defp path_size(_rest, _index, _segment, _dots), do: :error

  # A segment of only "." or ".." is a dot segment.
  defp end_segment(index, segment, dots) when dots in [1, 2] and dots == index - segment,
    do: :error

  defp end_segment(index, _segment, _dots), do: {:ok, index}

  defp query("?" <> rest) do
    size = query_size(rest, 0)
    <<search::binary-size(^size), tail::binary>> = rest

    case tail do
      "" -> {:ok, search, ""}
      "#" <> _fragment -> {:ok, search, tail}
      _other -> :error
    end
  end

  defp query(rest), do: {:ok, nil, rest}

  defp query_size(<<char, rest::binary>>, size) when query_byte?(char),
    do: query_size(rest, size + 1)

  defp query_size(_rest, size), do: size

  # The rest is empty, or it starts with "#": the scans of the host, the
  # port, the path, and the query stop only there.
  defp fragment(""), do: {:ok, nil}
  defp fragment("#" <> rest), do: if(fragment_text?(rest), do: {:ok, rest}, else: :error)

  defp fragment_text?(<<char, rest::binary>>) when fragment_byte?(char),
    do: fragment_text?(rest)

  defp fragment_text?(<<>>), do: true
  defp fragment_text?(_rest), do: false
end
