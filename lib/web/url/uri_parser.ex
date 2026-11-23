defmodule Web.URL.URIParser do
  @moduledoc false

  # The function `URI.parse/1` of Elixir, with binary pattern matching in
  # the place of its two regular expressions. The result is the same struct
  # for each input. A property test compares the two functions.
  #
  # The regular expressions of `URI.parse/1` are:
  #
  #     ^(([a-z][a-z0-9\+\-\.]*):)?(//([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?   (caseless)
  #     (^(.*)@)?(\[[a-zA-Z0-9:.]*\]|[^:]*)(:(\d*))?                           (authority)
  #
  # The dot of a regular expression does not match a line feed. Thus the
  # fragment, and the user information, stop at a line feed.

  defguardp alpha?(char) when char in ?A..?Z or char in ?a..?z
  defguardp digit?(char) when char in ?0..?9

  alias Web.Internal.Ascii

  @spec parse(binary()) :: URI.t()
  def parse(string) when is_binary(string) do
    {scheme, rest} = split_scheme(string)
    {authority_with_slashes, rest} = split_authority_part(rest)
    {path, rest} = split_at(rest, path_end(rest, 0))
    {query, rest} = split_query(rest)
    fragment = split_fragment(rest)

    {authority, userinfo, host, port} = split_authority(authority_with_slashes)
    scheme = scheme && String.downcase(scheme)

    %URI{
      scheme: scheme,
      path: nilify(path),
      query: query,
      fragment: fragment,
      authority: authority,
      userinfo: userinfo,
      host: host,
      port: parse_port(port, scheme)
    }
  end

  # `(([a-z][a-z0-9\+\-\.]*):)?` with no case.
  defp split_scheme(<<char, rest::binary>> = string) when alpha?(char) do
    size = scheme_size(rest, 1)

    case string do
      <<scheme::binary-size(^size), ?:, rest::binary>> -> {scheme, rest}
      _other -> {nil, string}
    end
  end

  defp split_scheme(string), do: {nil, string}

  defp scheme_size(<<char, rest::binary>>, size)
       when alpha?(char) or digit?(char) or char in [?+, ?-, ?.],
       do: scheme_size(rest, size + 1)

  defp scheme_size(_rest, size), do: size

  # `(//([^/?#]*))?`
  defp split_authority_part("//" <> rest) do
    {authority, rest} = split_at(rest, authority_end(rest, 0))
    {"//" <> authority, rest}
  end

  defp split_authority_part(rest), do: {"", rest}

  # `(\?([^#]*))?`
  defp split_query("?" <> rest), do: split_at(rest, query_end(rest, 0))
  defp split_query(rest), do: {nil, rest}

  # `(#(.*))?`: the fragment stops at a line feed.
  defp split_fragment("#" <> rest), do: binary_part(rest, 0, line_end(rest, 0))
  defp split_fragment(_rest), do: nil

  # The inputs are short, thus a scan of the bytes is faster than
  # `:binary.match/2`, which compiles its pattern each time. Each function
  # gives the index of the first byte that ends a part.
  defp split_at(string, index),
    do: {binary_part(string, 0, index), binary_part(string, index, byte_size(string) - index)}

  defp authority_end(<<char, _rest::binary>>, index) when char in [?/, ??, ?#], do: index
  defp authority_end(<<_char, rest::binary>>, index), do: authority_end(rest, index + 1)
  defp authority_end(<<>>, index), do: index

  defp path_end(<<char, _rest::binary>>, index) when char in [??, ?#], do: index
  defp path_end(<<_char, rest::binary>>, index), do: path_end(rest, index + 1)
  defp path_end(<<>>, index), do: index

  defp query_end(<<?#, _rest::binary>>, index), do: index
  defp query_end(<<_char, rest::binary>>, index), do: query_end(rest, index + 1)
  defp query_end(<<>>, index), do: index

  defp line_end(<<?\n, _rest::binary>>, index), do: index
  defp line_end(<<_char, rest::binary>>, index), do: line_end(rest, index + 1)
  defp line_end(<<>>, index), do: index

  defp colon_end(<<?:, _rest::binary>>, index), do: index
  defp colon_end(<<_char, rest::binary>>, index), do: colon_end(rest, index + 1)
  defp colon_end(<<>>, index), do: index

  defp split_authority(""), do: {nil, nil, nil, nil}
  defp split_authority("//"), do: {"", nil, "", nil}

  defp split_authority("//" <> authority) do
    {userinfo, rest} = split_userinfo(authority)
    {host, rest} = split_host(rest)
    port = split_port(rest)

    host = if nilify(host), do: host |> String.trim_leading("[") |> String.trim_trailing("]")
    {authority, nilify(userinfo), host, nilify(port)}
  end

  # `(^(.*)@)?`: the last "@" before the first line feed.
  defp split_userinfo(authority) do
    line = binary_part(authority, 0, line_end(authority, 0))

    case :binary.matches(line, "@") do
      [] ->
        {nil, authority}

      matches ->
        {index, 1} = List.last(matches)

        {binary_part(authority, 0, index),
         binary_part(authority, index + 1, byte_size(authority) - index - 1)}
    end
  end

  # `(\[[a-zA-Z0-9:.]*\]|[^:]*)`
  defp split_host("[" <> rest = string) do
    size = bracket_size(rest, 0)

    case rest do
      <<inside::binary-size(^size), ?], tail::binary>> -> {"[" <> inside <> "]", tail}
      _other -> split_at(string, colon_end(string, 0))
    end
  end

  defp split_host(string), do: split_at(string, colon_end(string, 0))

  defp bracket_size(<<char, rest::binary>>, size)
       when alpha?(char) or digit?(char) or char in [?:, ?.],
       do: bracket_size(rest, size + 1)

  defp bracket_size(_rest, size), do: size

  # `(:(\d*))?`
  defp split_port(":" <> rest), do: rest |> Ascii.split_digits() |> elem(0)
  defp split_port(_rest), do: nil

  # Leading zeros are removed, and a port with more than 6 digits or out of
  # the range is discarded, as `URI.parse/1` does.
  defp parse_port(port, scheme) do
    case port && String.trim_leading(port, "0") do
      nil ->
        scheme && URI.default_port(scheme)

      "" ->
        0

      port when byte_size(port) <= 6 ->
        port = String.to_integer(port)
        if port in 0..65_535, do: port

      _other ->
        nil
    end
  end

  defp nilify(""), do: nil
  defp nilify(other), do: other
end
