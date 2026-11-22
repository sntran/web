defmodule Web.Dispatcher.Scheme do
  @moduledoc false

  # The dispatcher of `Web.fetch/2` for the schemes of the steps "scheme
  # fetch" of the Fetch Standard that need no network:
  #
  #   * `about:` - `about:blank` gives the status 200, the status text
  #     `"OK"`, the header `Content-Type: text/html;charset=utf-8`, and an
  #     empty body. Each other `about:` URL gives a network error.
  #   * `data:` - the steps "data: URL processor" give the MIME type and the
  #     body. The response has the status 200, the status text `"OK"`, and
  #     the header `Content-Type` with the MIME type. A URL that the
  #     processor refuses gives a network error.
  #   * each other scheme that the library does not fetch, for example
  #     `file:`, gives a network error: "When in doubt, return a network
  #     error".
  #
  # A network error rejects the promise of `Web.fetch/2` with a
  # `Web.TypeError`. The method and the body of the request have no effect.
  # The URL of a response has no fragment.

  @behaviour Web.Dispatcher

  alias Web.Internal.Ascii

  @impl true
  @spec fetch(Web.Request.t()) :: {:ok, Web.Response.t()} | {:error, any()}
  def fetch(%Web.Request{} = request), do: response(request.url)

  @doc false
  # The promise of `Web.fetch/2`. The response is ready at once: the body is
  # in the URL, or it is empty.
  @spec __start__(Web.Request.t(), (term() -> term())) :: Web.Promise.t()
  def __start__(%Web.Request{} = request, rejection) when is_function(rejection, 1) do
    case response(request.url) do
      {:ok, response} -> Web.Promise.resolve(response)
      {:error, reason} -> Web.Promise.reject(rejection.(reason))
    end
  end

  defp response(url) do
    case Web.URL.protocol(url) do
      "about:" -> about_response(url)
      "data:" -> data_response(url)
      scheme -> {:error, {:scheme_not_supported, scheme}}
    end
  end

  # "If request's current URL's path is the string "blank", then return a
  # new response whose status message is `OK`, header list is
  # « (`Content-Type`, `text/html;charset=utf-8`) », and body is the empty
  # byte sequence as a body."
  defp about_response(url) do
    if Web.URL.pathname(url) == "blank" do
      {:ok, ok_response(url, "text/html;charset=utf-8", "")}
    else
      {:error, :about_url_not_blank}
    end
  end

  defp data_response(url) do
    case process_data_url(url) do
      {:ok, mime_type, body} -> {:ok, ok_response(url, mime_type, body)}
      :error -> {:error, :data_url_not_valid}
    end
  end

  defp ok_response(url, content_type, body) do
    Web.Response.__network__(
      status: 200,
      status_text: "OK",
      headers: [{"content-type", content_type}],
      body: body,
      url: serialize_without_fragment(url)
    )
  end

  # The URL serializer with "exclude fragment" set to true.
  defp serialize_without_fragment(url), do: url |> Web.URL.hash("") |> Web.URL.href()

  # The steps "data: URL processor" of the Fetch Standard. Returns
  # `{:ok, mime_type, body}`, with the serialized MIME type, or `:error`.
  defp process_data_url(url) do
    # Steps 2 and 3: the serialized URL with no fragment and no "data:".
    "data:" <> input = serialize_without_fragment(url)

    # Steps 5 to 9: the MIME type is the text before the first ",", with no
    # ASCII whitespace at the two ends. With no ",", the URL is not valid.
    case :binary.split(input, ",") do
      [mime_type, encoded_body] ->
        mime_type |> strip_ascii_whitespace() |> decode_body(percent_decode(encoded_body))

      [_no_comma] ->
        :error
    end
  end

  # Step 11: a MIME type that ends with ";base64" has a body in the
  # forgiving-base64 encoding.
  defp decode_body(mime_type, body) do
    case base64_mime_type(mime_type) do
      {:base64, mime_type} ->
        with {:ok, body} <- forgiving_base64_decode(body),
             do: {:ok, parse_mime_type(mime_type), body}

      :plain ->
        {:ok, parse_mime_type(mime_type), body}
    end
  end

  # "If mimeType ends with U+003B (;), followed by zero or more U+0020
  # SPACE, followed by an ASCII case-insensitive match for "base64"": the
  # MIME type without these code points.
  defp base64_mime_type(mime_type) do
    case Regex.run(~r/\A(.*);[ ]*base64\z/is, mime_type, capture: :all_but_first) do
      [mime_type] -> {:base64, mime_type}
      nil -> :plain
    end
  end

  # Steps 12 to 14: a MIME type that starts with ";" gets "text/plain"
  # before it. A MIME type that the parser refuses is
  # `text/plain;charset=US-ASCII`.
  defp parse_mime_type(";" <> _rest = mime_type), do: parse_mime_type("text/plain" <> mime_type)
  defp parse_mime_type(mime_type), do: Web.MIME.parse(mime_type) || "text/plain;charset=US-ASCII"

  defguardp ascii_whitespace?(char) when char in [?\t, ?\n, ?\f, ?\r, ?\s]
  defguardp hex?(char) when char in ?0..?9 or char in ?a..?f or char in ?A..?F

  defp strip_ascii_whitespace(text) do
    whitespace? = &ascii_whitespace?/1
    text |> Ascii.trim_leading(whitespace?) |> Ascii.trim_trailing(whitespace?)
  end

  # The "percent-decode" of the URL Standard: a "%" with no two hexadecimal
  # digits after it stays.
  defp percent_decode(bytes), do: percent_decode(bytes, <<>>)

  defp percent_decode(<<?%, high, low, rest::binary>>, acc) when hex?(high) and hex?(low),
    do: percent_decode(rest, <<acc::binary, String.to_integer(<<high, low>>, 16)>>)

  defp percent_decode(<<byte, rest::binary>>, acc),
    do: percent_decode(rest, <<acc::binary, byte>>)

  defp percent_decode(<<>>, acc), do: acc

  # The "forgiving-base64 decode" of the Infra Standard. The body is the
  # isomorphic decode of the bytes: each byte is one code point, thus the
  # steps can work on the bytes.
  defp forgiving_base64_decode(data) do
    data = for <<char <- data>>, not ascii_whitespace?(char), into: <<>>, do: <<char>>

    # "If data's code point length divides by 4 leaving no remainder, then:
    # If data ends with one or two U+003D (=) code points, then remove them
    # from data."
    data =
      if rem(byte_size(data), 4) == 0,
        do: data |> String.replace_suffix("=", "") |> String.replace_suffix("=", ""),
        else: data

    # A length with the remainder 1, and a code point that is not in the
    # alphabet of base64, for example "=", give a failure.
    if rem(byte_size(data), 4) == 1, do: :error, else: Base.decode64(data, padding: false)
  end
end
