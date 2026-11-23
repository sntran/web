defmodule Web.Dispatcher.Blob do
  @moduledoc false

  # The dispatcher of `Web.fetch/2` for a `blob:` URL, as the steps "scheme
  # fetch" of the Fetch Standard specify for the scheme `"blob"`.
  #
  # The URL comes from `Web.URL.create_object_url/1`. The response has the
  # status 200, the bytes of the blob, and the headers `Content-Length` and
  # `Content-Type` with the size and the type of the blob. A request with a
  # `Range` header of one range, such as `bytes=0-99`, gets the status 206
  # with the bytes of the range and the header `Content-Range`.
  #
  # A method other than `GET`, a URL that is not in the blob URL store, and a
  # range that is not valid give a network error: `Web.fetch/2` rejects with
  # a `Web.TypeError`. The fragment of the URL has no effect.
  #
  # The dispatcher reads the store when the fetch starts. Thus a revoke of
  # the URL after the call of `Web.fetch/2` does not change the response.

  @behaviour Web.Dispatcher

  @impl true
  @spec fetch(Web.Request.t()) :: {:ok, Web.Response.t()} | {:error, any()}
  def fetch(%Web.Request{} = request), do: response(request)

  @doc false
  # The promise of `Web.fetch/2`. The response is ready at once: the bytes
  # of a blob are in memory.
  @spec __start__(Web.Request.t(), (term() -> term())) :: Web.Promise.t()
  def __start__(%Web.Request{} = request, rejection) when is_function(rejection, 1) do
    case response(request) do
      {:ok, response} -> Web.Promise.resolve(response)
      {:error, reason} -> Web.Promise.reject(rejection.(reason))
    end
  end

  defp response(%Web.Request{method: "GET", url: url} = request) do
    case Web.URL.__blob_url_entry__(url) do
      nil -> {:error, :blob_url_not_found}
      blob -> blob_response(request, blob)
    end
  end

  defp response(%Web.Request{}), do: {:error, :blob_url_method_not_get}

  defp blob_response(request, blob) do
    size = Map.get(blob, :size) || 0
    url = url_without_fragment(request.url)

    case Web.Headers.get(request.headers, "range") do
      nil ->
        {:ok,
         Web.Response.__network__(
           body: Web.Blob.stream(blob),
           status: 200,
           status_text: "OK",
           url: url,
           headers: [{"content-length", Integer.to_string(size)}, {"content-type", blob.type}]
         )}

      range ->
        range_response(blob, size, url, range)
    end
  end

  defp range_response(blob, size, url, range) do
    with {:ok, range_start, range_end} <- parse_range(range),
         {:ok, range_start, range_end} <- resolve_range(range_start, range_end, size) do
      sliced = Web.Blob.slice(blob, range_start, range_end + 1, blob.type)

      {:ok,
       Web.Response.__network__(
         body: Web.Blob.stream(sliced),
         status: 206,
         status_text: "Partial Content",
         url: url,
         headers: [
           {"content-length", Integer.to_string(sliced.size)},
           {"content-type", blob.type},
           {"content-range", "bytes #{range_start}-#{range_end}/#{size}"}
         ]
       )}
    end
  end

  # The steps "parse a single range header value", with whitespace.
  defp parse_range("bytes" <> rest) do
    with "=" <> rest <- skip_space(rest),
         {range_start, rest} <- digits(skip_space(rest)),
         "-" <> rest <- skip_space(rest),
         {range_end, ""} <- digits(skip_space(rest)),
         true <- range_start != nil or range_end != nil,
         true <- range_start == nil or range_end == nil or range_start <= range_end do
      {:ok, range_start, range_end}
    else
      _failure -> {:error, :blob_url_range_not_valid}
    end
  end

  defp parse_range(_value), do: {:error, :blob_url_range_not_valid}

  defp resolve_range(nil, suffix, size) do
    range_start = size - suffix
    {:ok, range_start, range_start + suffix - 1}
  end

  defp resolve_range(range_start, _range_end, size) when range_start >= size,
    do: {:error, :blob_url_range_not_valid}

  defp resolve_range(range_start, range_end, size) when is_nil(range_end) or range_end >= size,
    do: {:ok, range_start, size - 1}

  defp resolve_range(range_start, range_end, _size), do: {:ok, range_start, range_end}

  defp skip_space(<<char, rest::binary>>) when char in [?\s, ?\t], do: skip_space(rest)
  defp skip_space(rest), do: rest

  defp digits(text) do
    case Integer.parse(text) do
      {value, rest} when value >= 0 and binary_part(text, 0, 1) not in ["+", "-"] -> {value, rest}
      _none -> {nil, text}
    end
  end

  defp url_without_fragment(url), do: url |> Web.URL.href() |> String.split("#", parts: 2) |> hd()
end
