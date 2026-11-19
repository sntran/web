defmodule Web.Response do
  @moduledoc """
  An implementation of the WHATWG Response standard.

  Represents an HTTP response, including status, headers, and a streamable body.
  Matches the zero-buffer streaming rule.
  """
  use Web.Body

  alias Web.AsyncContext

  defstruct [
    :body,
    :status,
    :ok,
    :status_text,
    :url,
    :type,
    :snapshot,
    redirected: false,
    headers: Web.Headers.new()
  ]

  @type t :: %__MODULE__{
          body: %Web.ReadableStream{} | nil,
          headers: Web.Headers.t(),
          status: non_neg_integer(),
          ok: boolean(),
          status_text: String.t(),
          url: String.t(),
          type: String.t(),
          redirected: boolean(),
          snapshot: AsyncContext.Snapshot.t() | nil
        }

  @redirect_statuses [301, 302, 303, 307, 308]
  @null_body_statuses [101, 103, 204, 205, 304]

  @doc """
  Makes a response, as the `Response` constructor of the Fetch Standard.

  ## Options

    * `:body` - the body. A response with no body has the body `nil`.
    * `:status` - an integer from 200 to 599. The default is 200.
    * `:status_text` - the reason phrase. The default is `""`.
    * `:headers` - a `Web.Headers` struct, a map, or a list of pairs.

  These options are for a dispatcher, which makes the response of a
  `Web.fetch/2`: `:url`, `:redirected`, and `:type`.

  The function raises for input that the Fetch Standard refuses:

    * `Web.RangeError` for a status that is not from 200 to 599;
    * `Web.TypeError` for a status text that is not a reason phrase;
    * `Web.TypeError` for a body together with a status that permits no body:
      101, 103, 204, 205, or 304;
    * `Web.TypeError` for a header name or a header value that is not valid.

  ## Examples

      iex> resp = Web.Response.new(status: 200)
      iex> {resp.ok, resp.body, resp.status_text, resp.url}
      {true, nil, "", ""}

      iex> resp = Web.Response.new(status: 404)
      iex> resp.ok
      false

      iex> resp = Web.Response.new(status: 206)
      iex> resp.ok
      true
  """
  def new(opts) when is_list(opts) do
    status = Keyword.get(opts, :status, 200)
    status_text = Keyword.get(opts, :status_text, "")
    body = Keyword.get(opts, :body)

    :ok = validate_status!(status)
    :ok = validate_status_text!(status_text)
    :ok = validate_null_body!(status, body)

    build(opts)
  end

  def new(other) do
    raise Web.TypeError, "Response init must be a keyword list, got: #{inspect(other)}"
  end

  def new, do: new([])

  @doc """
  Makes a response from a body and init options. See `new/1`.
  """
  def new(body, init) when is_list(init) do
    init
    |> Keyword.put(:body, body)
    |> new()
  end

  def new(_body, init) do
    raise Web.TypeError, "Response init must be a keyword list, got: #{inspect(init)}"
  end

  @doc false
  # Makes the response of a dispatcher from the data of the network. The
  # checks of the constructor are not applicable: a server can give each
  # status.
  @spec __network__(keyword()) :: t()
  def __network__(opts) when is_list(opts) do
    opts
    |> Keyword.put_new(:type, "basic")
    |> build()
  end

  defp build(opts) do
    status = Keyword.get(opts, :status, 200)
    raw_body = Keyword.get(opts, :body)

    headers =
      Keyword.get(opts, :headers, %{})
      |> Web.Headers.new()
      |> Web.Body.put_inferred_content_type(raw_body)

    %__MODULE__{
      # A response with no body has the body `nil`, as the Fetch Standard
      # specifies, and starts no stream.
      body: if(is_nil(raw_body), do: nil, else: Web.Body.stream(raw_body)),
      headers: headers,
      status: status,
      ok: status in 200..299,
      status_text: Keyword.get(opts, :status_text, ""),
      url: Keyword.get(opts, :url) || "",
      type: Keyword.get(opts, :type, "default"),
      redirected: Keyword.get(opts, :redirected, false),
      snapshot: AsyncContext.Snapshot.take()
    }
  end

  defp validate_status!(status) when is_integer(status) and status in 200..599, do: :ok

  defp validate_status!(status) when is_integer(status) do
    raise Web.RangeError, "The status must be from 200 to 599, got: #{status}"
  end

  defp validate_status!(status) do
    raise Web.TypeError, "The status must be an integer, got: #{inspect(status)}"
  end

  # The reason phrase of HTTP: tab, space, and each visible byte.
  defp validate_status_text!(text) when is_binary(text) do
    if Regex.match?(~r/\A[\t \x21-\x7E\x80-\xFF]*\z/, text) do
      :ok
    else
      raise Web.TypeError, "Invalid status text: #{inspect(text)}"
    end
  end

  defp validate_status_text!(text) do
    raise Web.TypeError, "Invalid status text: #{inspect(text)}"
  end

  defp validate_null_body!(status, body)
       when status in @null_body_statuses and not is_nil(body) do
    raise Web.TypeError, "Response with null body status cannot have body"
  end

  defp validate_null_body!(_status, _body), do: :ok

  @doc """
  Returns a network error response, as `Response.error()`.
  """
  @spec error() :: t()
  def error do
    build(status: 0, type: "error")
  end

  @doc """
  Makes a JSON response, as `Response.json()`.

  The header `content-type` is `application/json`, unless `init` has that
  header. Raises `Web.TypeError` if `data` cannot be changed to JSON.
  """
  @spec json(any(), keyword()) :: t()
  def json(data, init \\ []) do
    encoded = encode_json!(data)

    headers = init |> Keyword.get(:headers, %{}) |> Web.Headers.new()

    headers =
      if Web.Headers.has(headers, "content-type") do
        headers
      else
        Web.Headers.set(headers, "content-type", "application/json")
      end

    new(encoded, Keyword.put(init, :headers, headers))
  end

  defp encode_json!(data) do
    Jason.encode!(data)
  rescue
    error ->
      reraise Web.TypeError,
              [message: "The value cannot be changed to JSON", cause: error],
              __STACKTRACE__
  end

  @doc """
  Makes a redirect response with no body, as `Response.redirect()`.

  The URL must be an absolute URL. Raises `Web.TypeError` for a URL that is
  not valid, and `Web.RangeError` for a status that is not 301, 302, 303,
  307, or 308.
  """
  @spec redirect(String.t() | Web.URL.t(), non_neg_integer()) :: t()
  def redirect(url, status \\ 302) do
    location = redirect_location!(url)

    if status not in @redirect_statuses do
      raise Web.RangeError, "Invalid redirect status: #{inspect(status)}"
    end

    build(status: status, headers: %{"location" => location})
  end

  defp redirect_location!(%Web.URL{} = url), do: Web.URL.href(url)

  defp redirect_location!(url) when is_binary(url) do
    url |> Web.URL.new() |> Web.URL.href()
  rescue
    ArgumentError ->
      reraise Web.TypeError, [message: "Invalid URL: #{inspect(url)}"], __STACKTRACE__
  end

  defp redirect_location!(url) do
    raise Web.TypeError, "Invalid URL: #{inspect(url)}"
  end
end
