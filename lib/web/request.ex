defmodule Web.Request do
  @moduledoc """
  An implementation of the WHATWG Request standard.

  Represents an HTTP request, including URL, method, headers, and body.
  Compatible with standard Web API concepts.
  """
  use Web.Body

  alias Web.AsyncContext

  defstruct [
    :url,
    :method,
    :body,
    :body_source,
    :dispatcher,
    :redirect,
    :signal,
    :snapshot,
    :options,
    headers: Web.Headers.new()
  ]

  @type t :: %__MODULE__{
          url: Web.URL.t(),
          method: String.t(),
          headers: Web.Headers.t(),
          body: any(),
          body_source: term(),
          dispatcher: module() | nil,
          redirect: String.t(),
          signal: Web.AbortSignal.t() | pid() | reference() | nil,
          snapshot: AsyncContext.Snapshot.t() | nil,
          options: keyword()
        }

  @doc """
  Makes a request, as the `Request` constructor of the Fetch Standard.

  The input is a `Web.Request`, a `Web.URL`, or the text of an absolute URL.
  The members of `init` replace the values of an input request.

  The function raises `Web.TypeError` for input that the Fetch Standard
  refuses:

    * a URL that is not valid, or that includes credentials;
    * a method that is not an HTTP token, or that is `CONNECT`, `TRACE`, or
      `TRACK`;
    * a body together with the method `GET` or `HEAD`;
    * a header name or a header value that is not valid;
    * a redirect mode that is not `"follow"`, `"error"`, or `"manual"`;
    * a body that is a stream with no option `duplex: "half"`. A stream is a
      `Web.ReadableStream`, or an enumerable that is not a list.

  The methods `DELETE`, `GET`, `HEAD`, `OPTIONS`, `POST`, and `PUT` are
  changed to uppercase. Each other method keeps its case, thus `"patch"`
  stays `"patch"`. A method that is an atom is always changed to uppercase.

  ## Examples
      iex> req = Web.Request.new("http://example.com")
      iex> Web.Request.new(req, []) == req
      true

      iex> controller = Web.AbortController.new()
      iex> req = Web.Request.new("http://example.com", redirect: :manual, signal: controller.signal)
      iex> {req.redirect, match?(%Web.AbortSignal{}, req.signal)}
      {"manual", true}
      iex> Web.AbortController.abort(controller)
      :ok
  """
  def new(input, init \\ [])

  def new(%__MODULE__{} = request, []), do: request

  def new(%__MODULE__{} = request, init) when is_list(init) do
    override_request(request, init)
  end

  def new(%Web.URL{} = input, init) when is_list(init) do
    input
    |> validate_url()
    |> build_request(init)
  end

  def new(input, init) when is_binary(input) and is_list(init) do
    input
    |> parse_url()
    |> validate_url()
    |> build_request(init)
  end

  def new(input, init) when is_list(init) do
    raise Web.TypeError,
          "Request input must be a Web.Request struct, a Web.URL struct, or a URL string, " <>
            "got: #{inspect(input)}"
  end

  def new(_input, init) do
    raise Web.TypeError, "Request init must be a keyword list, got: #{inspect(init)}"
  end

  @doc false
  # A body that is read, or that has a reader, cannot be sent. The Fetch
  # Standard refuses such a request.
  @spec ensure_body_usable!(t()) :: :ok
  def ensure_body_usable!(%__MODULE__{body: nil}), do: :ok

  def ensure_body_usable!(%__MODULE__{body: body}) do
    cond do
      Web.ReadableStream.disturbed?(body) ->
        raise Web.TypeError, "Request body is already used"

      Web.ReadableStream.locked?(body) ->
        raise Web.TypeError, "Request body is locked"

      true ->
        :ok
    end
  end

  # The BEAM has no base URL. Thus the input must be an absolute URL.
  defp parse_url(input) do
    Web.URL.new(input)
  rescue
    ArgumentError ->
      reraise Web.TypeError, [message: "Invalid URL: #{inspect(input)}"], __STACKTRACE__
  end

  defp validate_url(%Web.URL{username: username, password: password} = url) do
    if username in [nil, ""] and password in [nil, ""] do
      url
    else
      # The message does not show the URL, because the URL has a secret.
      raise Web.TypeError, "Request cannot be constructed from a URL that includes credentials"
    end
  end

  # The methods that the Fetch Standard changes to uppercase. Each other
  # method keeps its case.
  @normalized_methods ~w(DELETE GET HEAD OPTIONS POST PUT)
  @forbidden_methods ~w(CONNECT TRACE TRACK)

  # An atom has no equivalent in the Fetch Standard. It is always changed to
  # uppercase, thus `:patch` gives "PATCH".
  defp normalize_method(method) when is_atom(method) and not is_nil(method) do
    method |> Atom.to_string() |> String.upcase(:ascii) |> normalize_method()
  end

  defp normalize_method(method) when is_binary(method) do
    upper = String.upcase(method, :ascii)

    cond do
      not Web.Headers.token?(method) ->
        raise Web.TypeError, "#{inspect(method)} is not a valid HTTP method"

      upper in @forbidden_methods ->
        raise Web.TypeError, "#{inspect(method)} HTTP method is unsupported"

      upper in @normalized_methods ->
        upper

      true ->
        method
    end
  end

  defp normalize_method(method) do
    raise Web.TypeError, "#{inspect(method)} is not a valid HTTP method"
  end

  @redirect_modes ~w(follow error manual)

  defp normalize_redirect(redirect) when is_binary(redirect) or is_atom(redirect) do
    redirect = to_string(redirect)

    if redirect in @redirect_modes do
      redirect
    else
      raise Web.TypeError,
            "#{inspect(redirect)} is not a valid redirect mode. " <>
              "Use \"follow\", \"error\", or \"manual\""
    end
  end

  defp normalize_redirect(redirect) do
    raise Web.TypeError, "#{inspect(redirect)} is not a valid redirect mode"
  end

  # The Fetch Standard requires `duplex: "half"` for a body that is a stream:
  # the request is sent in full before the response is read. No other value
  # is valid.
  defp validate_duplex(init, body) do
    case Keyword.fetch(init, :duplex) do
      {:ok, duplex} when duplex in ["half", :half] ->
        :ok

      {:ok, duplex} ->
        raise Web.TypeError, "#{inspect(duplex)} is not a valid duplex mode"

      :error ->
        if stream_body?(body) do
          raise Web.TypeError,
                "The option `duplex: \"half\"` is necessary for a body that is a stream"
        else
          :ok
        end
    end
  end

  # A body that is a stream has no source: it can be read only one time.
  defp stream_body?(nil), do: false
  defp stream_body?(%Web.FormData{}), do: false
  defp stream_body?(body), do: is_nil(body_source(body))

  defp validate_body(method, body) when method in ["GET", "HEAD"] and not is_nil(body) do
    raise Web.TypeError, "Request with GET/HEAD method cannot have body"
  end

  defp validate_body(_method, _body), do: :ok

  # The source of a body is its data, when the data is in memory. A request
  # with such a body can be sent again after a redirect. A body from a stream
  # has no source.
  defp body_source(body) when is_binary(body) or is_list(body), do: body

  defp body_source(%module{} = body)
       when module in [Web.URLSearchParams, Web.Blob, Web.ArrayBuffer, Web.Uint8Array],
       do: body

  defp body_source(_body), do: nil

  defp build_request(url, init) do
    method = init |> Keyword.get(:method, "GET") |> normalize_method()
    redirect = init |> Keyword.get(:redirect, "follow") |> normalize_redirect()
    raw_body = Keyword.get(init, :body)
    :ok = validate_body(method, raw_body)
    :ok = validate_duplex(init, raw_body)

    headers =
      Keyword.get(init, :headers, %{})
      |> Web.Headers.new()
      |> Web.Body.put_inferred_content_type(raw_body)

    # A request with no body has the body `nil`, as the Fetch Standard
    # specifies, and starts no stream. The stream starts after all the
    # checks, thus an input that is not valid starts no process.
    body = if is_nil(raw_body), do: nil, else: Web.Body.stream(raw_body)
    dispatcher = Keyword.get(init, :dispatcher)

    snapshot = AsyncContext.Snapshot.take()
    signal = Keyword.get(init, :signal) || snapshot.ambient_signal

    options =
      init
      |> Keyword.drop([:method, :headers, :body, :dispatcher])
      |> Keyword.put(:redirect, redirect)
      |> Keyword.put(:signal, signal)

    %__MODULE__{
      url: url,
      method: method,
      headers: headers,
      body: body,
      body_source: body_source(raw_body),
      dispatcher: dispatcher,
      redirect: redirect,
      signal: signal,
      snapshot: snapshot,
      options: options
    }
  end

  # Makes a request from a different request. Each member of `init` replaces
  # the value of the first request, as the Fetch Standard specifies.
  defp override_request(request, init) do
    method = init |> Keyword.get(:method, request.method) |> normalize_method()
    redirect = init |> Keyword.get(:redirect, request.redirect) |> normalize_redirect()
    :ok = validate_duplex(init, Keyword.get(init, :body))

    headers =
      case Keyword.fetch(init, :headers) do
        {:ok, headers} -> Web.Headers.new(headers)
        :error -> request.headers
      end

    {body, source, headers} =
      case Keyword.fetch(init, :body) do
        {:ok, nil} ->
          {nil, nil, headers}

        {:ok, raw_body} ->
          :ok = validate_body(method, raw_body)
          headers = Web.Body.put_inferred_content_type(headers, raw_body)
          {Web.Body.stream(raw_body), body_source(raw_body), headers}

        :error ->
          :ok = validate_body(method, request.body)
          :ok = ensure_body_usable!(request)
          {request.body, request.body_source, headers}
      end

    signal = Keyword.get(init, :signal) || request.signal

    options =
      request.options
      |> Keyword.merge(Keyword.drop(init, [:method, :headers, :body, :dispatcher]))
      |> Keyword.put(:redirect, redirect)
      |> Keyword.put(:signal, signal)

    %{
      request
      | method: method,
        headers: headers,
        body: body,
        body_source: source,
        dispatcher: Keyword.get(init, :dispatcher, request.dispatcher),
        redirect: redirect,
        signal: signal,
        options: options
    }
  end
end
