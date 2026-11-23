defmodule Web.Response do
  @moduledoc """
  An implementation of the WHATWG Response standard.

  Represents an HTTP response, including status, headers, and a streamable body.
  Matches the zero-buffer streaming rule.

  ## The attributes

  The fields of the struct are the attributes of the `Response` class of the
  Fetch Standard, in snake case: `type`, `url`, `redirected`, `status`, `ok`,
  `status_text`, `headers`, and `body`. The function `body_used?/1` is the
  attribute `bodyUsed`. The other fields are internal.

  ## The body

  The methods of the body mixin of the Fetch Standard read the body:
  `text/1`, `json/1`, `array_buffer/1`, `bytes/1`, `blob/1`, `form_data/1`,
  and `text_stream/1`. Each method except `text_stream/1` returns a
  `Web.Promise`. A body can be read one time: a second method rejects with
  `Web.TypeError`. A chunk of a body stream must be bytes: a
  `Web.Uint8Array`, a binary, iodata, or a `Web.ArrayBuffer`.

      iex> response = Web.Response.new("hello")
      iex> Web.await(Web.Response.text(response))
      "hello"

      iex> response = Web.Response.new(~s({"ok":true}))
      iex> Web.await(Web.Response.json(response))
      %{"ok" => true}

      iex> response = Web.Response.new("hello")
      iex> %Web.ArrayBuffer{byte_length: 5} = Web.await(Web.Response.array_buffer(response))

      iex> response = Web.Response.new("hello")
      iex> {response, clone} = Web.Response.clone(response)
      iex> Web.await(Web.Response.text(response))
      "hello"
      iex> Web.await(Web.Response.text(clone))
      "hello"
  """
  use Web.Body

  alias Web.AsyncContext
  alias Web.Internal.JSON, as: JSONText

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
  Makes a response, as the constructor `new Response(body, init)` of the
  Fetch Standard. `new/0` gives a response with no body and the default
  init, and `new/1` gives a response with the body and the default init.

  The body is `nil` (no body), a binary or iodata, a `Web.ReadableStream`,
  a `Web.Blob`, a `Web.ArrayBuffer`, a `Web.Uint8Array`, a
  `Web.URLSearchParams`, a `Web.FormData`, or an enumerable of chunks of
  bytes.

  ## Options

  The options are the members of `ResponseInit`, in snake case:

    * `:status` - an integer from 200 to 599. The default is 200.
    * `:status_text` - the reason phrase. The default is `""`.
    * `:headers` - a `Web.Headers` struct, a map, or a list of pairs.

  The function raises for input that the Fetch Standard refuses:

    * `Web.RangeError` for a status that is not from 200 to 599;
    * `Web.TypeError` for a status text that is not a reason phrase;
    * `Web.TypeError` for a body together with a status that permits no body:
      101, 103, 204, 205, or 304;
    * `Web.TypeError` for a body that is a `Web.ReadableStream` that a
      process read from, or that has a reader;
    * `Web.TypeError` for a header name or a header value that is not valid.

  ## Examples

      iex> resp = Web.Response.new()
      iex> {resp.status, resp.ok, resp.body, resp.status_text, resp.url}
      {200, true, nil, "", ""}

      iex> resp = Web.Response.new(nil, status: 404)
      iex> resp.ok
      false

      iex> resp = Web.Response.new("partial", status: 206, status_text: "Partial Content")
      iex> {resp.ok, resp.status_text, Web.await(Web.Response.text(resp))}
      {true, "Partial Content", "partial"}
  """
  @spec new(term(), keyword()) :: t()
  def new(body \\ nil, init \\ [])

  def new(body, init) when is_list(init) do
    status = Keyword.get(init, :status, 200)
    status_text = Keyword.get(init, :status_text, "")

    :ok = validate_status!(status)
    :ok = validate_status_text!(status_text)
    :ok = validate_null_body!(status, body)
    :ok = validate_body_stream!(body)

    init
    |> Keyword.take([:status, :status_text, :headers])
    |> Keyword.put(:body, body)
    |> build()
  end

  def new(_body, init) do
    raise Web.TypeError, "Response init must be a keyword list, got: #{inspect(init)}"
  end

  @doc false
  # Makes the response of a dispatcher from the data of the network. The
  # checks of the constructor are not applicable: a server can give each
  # status. The headers have the guard "immutable", as the Fetch Standard
  # specifies for the response of `fetch`.
  @spec __network__(keyword()) :: t()
  def __network__(opts) when is_list(opts) do
    opts
    |> Keyword.put_new(:type, "basic")
    |> build()
    |> immutable()
  end

  # The step "create a Response object" with the guard "immutable".
  defp immutable(%__MODULE__{headers: headers} = response),
    do: %{response | headers: Web.Headers.__immutable__(headers)}

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
      # A dispatcher can give the snapshot of the process of the request.
      snapshot: Keyword.get_lazy(opts, :snapshot, &AsyncContext.Snapshot.new/0)
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
    if reason_phrase?(text) do
      :ok
    else
      raise Web.TypeError, "Invalid status text: #{inspect(text)}"
    end
  end

  defp validate_status_text!(text) do
    raise Web.TypeError, "Invalid status text: #{inspect(text)}"
  end

  defp reason_phrase?(<<char, rest::binary>>) when char == ?\t or (char >= 0x20 and char != 0x7F),
    do: reason_phrase?(rest)

  defp reason_phrase?(<<>>), do: true
  defp reason_phrase?(_text), do: false

  defp validate_null_body!(status, body)
       when status in @null_body_statuses and not is_nil(body) do
    raise Web.TypeError, "Response with null body status cannot have body"
  end

  defp validate_null_body!(_status, _body), do: :ok

  # The step "extract a body": a stream must not be disturbed or locked.
  defp validate_body_stream!(%Web.ReadableStream{} = body) do
    _stream = Web.Body.extract!(body)
    :ok
  end

  defp validate_body_stream!(_body), do: :ok

  @doc """
  Returns a network error response, as `Response.error()`.

  Its headers have the guard `"immutable"`: see `Web.Headers`.
  """
  @spec error() :: t()
  def error do
    [status: 0, type: "error"] |> build() |> immutable()
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
    JSONText.stringify!(data)
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
  307, or 308. The headers have the guard `"immutable"`: see `Web.Headers`.
  """
  @spec redirect(String.t() | Web.URL.t(), non_neg_integer()) :: t()
  def redirect(url, status \\ 302) do
    location = redirect_location!(url)

    if status not in @redirect_statuses do
      raise Web.RangeError, "Invalid redirect status: #{inspect(status)}"
    end

    [status: status, headers: %{"location" => location}] |> build() |> immutable()
  end

  defp redirect_location!(%Web.URL{} = url), do: Web.URL.href(url)

  defp redirect_location!(url) when is_binary(url) do
    url |> Web.URL.new() |> Web.URL.href()
  rescue
    Web.TypeError ->
      reraise Web.TypeError, [message: "Invalid URL: #{inspect(url)}"], __STACKTRACE__
  end

  defp redirect_location!(url) do
    raise Web.TypeError, "Invalid URL: #{inspect(url)}"
  end
end
