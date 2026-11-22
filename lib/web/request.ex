defmodule Web.Request do
  @moduledoc """
  An implementation of the WHATWG Request standard.

  Represents an HTTP request, including URL, method, headers, and body.
  Compatible with standard Web API concepts.

  ## The attributes

  The fields of the struct are the attributes of the `Request` class of the
  Fetch Standard, in snake case: `method`, `url`, `headers`, `destination`,
  `referrer`, `referrer_policy`, `mode`, `credentials`, `cache`, `redirect`,
  `integrity`, `keepalive`, `is_reload_navigation`, `is_history_navigation`,
  `signal`, and `duplex`. The other fields are internal.

  A server runtime has no page and no CORS, as Node.js and Deno. Thus the
  values of `mode`, `credentials`, `cache`, `referrer`, `referrer_policy`,
  `integrity`, `keepalive`, and the option `:priority` do not change what
  `Web.fetch/2` sends. The constructor examines them as the Standard
  specifies.
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
    headers: Web.Headers.new(),
    destination: "",
    referrer: "about:client",
    referrer_policy: "",
    mode: "cors",
    credentials: "same-origin",
    cache: "default",
    integrity: "",
    keepalive: false,
    is_reload_navigation: false,
    is_history_navigation: false,
    duplex: "half"
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
          options: keyword(),
          destination: String.t(),
          referrer: String.t(),
          referrer_policy: String.t(),
          mode: String.t(),
          credentials: String.t(),
          cache: String.t(),
          integrity: String.t(),
          keepalive: boolean(),
          is_reload_navigation: boolean(),
          is_history_navigation: boolean(),
          duplex: String.t()
        }

  @doc """
  Makes a request, as the `Request` constructor of the Fetch Standard.

  The input is a `Web.Request`, a `Web.URL`, or the text of an absolute URL.
  The members of `init` replace the values of an input request.

  ## Options

  The options are the members of `RequestInit`, in snake case: `:method`,
  `:headers`, `:body`, `:referrer`, `:referrer_policy`, `:mode`,
  `:credentials`, `:cache`, `:redirect`, `:integrity`, `:keepalive`,
  `:signal`, `:duplex`, `:priority`, and `:window`. A value that is a
  string can also be an atom. The option `:dispatcher` sets the module that
  `Web.fetch/2` uses.

  The function raises `Web.TypeError` for input that the Fetch Standard
  refuses:

    * a URL that is not valid, or that includes credentials;
    * an option `:window` that is not `nil`;
    * a referrer that is not a valid URL. The BEAM has no base URL, thus
      the referrer must be an absolute URL, `"about:client"`, or `""`;
    * a value that is not in the enumeration of its option, for example the
      mode `"websocket"`;
    * the mode `"navigate"`;
    * the cache mode `"only-if-cached"` with a mode that is not
      `"same-origin"`;
    * a method that is not an HTTP token, or that is `CONNECT`, `TRACE`, or
      `TRACK`;
    * the mode `"no-cors"` with a method that is not `GET`, `HEAD`, or
      `POST`;
    * a header name or a header value that is not valid;
    * a body together with the method `GET` or `HEAD`. A body of the input
      request also counts;
    * a body that is a stream, together with the option `keepalive: true`,
      with no option `duplex: "half"`, or with a mode that is not
      `"same-origin"` or `"cors"`. A stream is a `Web.ReadableStream`, or an
      enumerable that is not a list;
    * a body that is a `Web.ReadableStream` that a process read from, or that
      has a reader;
    * an input request whose body a process read from, or that has a reader.

  A new request from a request with a body takes that body, as the Standard
  specifies: the body of the input request is then disturbed and locked.
  Give the option `:body` for a different body.

  The methods `DELETE`, `GET`, `HEAD`, `OPTIONS`, `POST`, and `PUT` are
  changed to uppercase. Each other method keeps its case, thus `"patch"`
  stays `"patch"`. A method that is an atom is always changed to uppercase.

  ## Examples
      iex> req = Web.Request.new("http://example.com")
      iex> Web.Request.new(req, []) == req
      true
      iex> {req.mode, req.credentials, req.cache, req.referrer, req.duplex}
      {"cors", "same-origin", "default", "about:client", "half"}

      iex> controller = Web.AbortController.new()
      iex> req = Web.Request.new("http://example.com", redirect: :manual, signal: controller.signal)
      iex> {req.redirect, match?(%Web.AbortSignal{}, req.signal)}
      {"manual", true}
      iex> Web.AbortController.abort(controller)
      :ok

      iex> Web.Request.new("http://example.com", mode: "no-cors", method: "PUT")
      ** (Web.TypeError) The mode "no-cors" permits only the methods GET, HEAD, and POST.
  """
  def new(input, init \\ [])

  # A request with no body and no init: the new request has the same values.
  def new(%__MODULE__{body: nil} = request, []), do: request

  def new(%__MODULE__{} = request, init) when is_list(init) do
    construct(request, init, request, nil)
  end

  def new(%Web.URL{} = input, init) when is_list(init) do
    input
    |> validate_url()
    |> url_request()
    |> construct(init, nil, "cors")
  end

  def new(input, init) when is_binary(input) and is_list(init) do
    input
    |> parse_url()
    |> validate_url()
    |> url_request()
    |> construct(init, nil, "cors")
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
    Web.TypeError ->
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

  # A new request of the Fetch Standard for a URL: the struct has the
  # default values of a request.
  defp url_request(url),
    do: %__MODULE__{url: url, method: "GET", redirect: "follow", body: nil, options: []}

  # ---------------------------------------------------------------------------
  # The steps of the constructor
  # ---------------------------------------------------------------------------

  # The enumerations of WebIDL for the members of `RequestInit`.
  @referrer_policies [
    "",
    "no-referrer",
    "no-referrer-when-downgrade",
    "same-origin",
    "origin",
    "strict-origin",
    "origin-when-cross-origin",
    "strict-origin-when-cross-origin",
    "unsafe-url"
  ]
  @modes ["navigate", "same-origin", "no-cors", "cors"]
  @credentials_modes ["omit", "same-origin", "include"]
  @cache_modes ["default", "no-store", "reload", "no-cache", "force-cache", "only-if-cached"]
  @redirect_modes ["follow", "error", "manual"]
  @priorities ["high", "low", "auto"]

  # The steps of the `Request` constructor of the Fetch Standard after the
  # parse of the input. `input` is the input request or `nil`, and
  # `fallback_mode` is the mode for a URL input. The steps that can throw
  # come first, thus a request that the constructor refuses does not change
  # the body of its input.
  defp construct(request, init, input, fallback_mode) do
    :ok = validate_window!(init)

    request =
      request
      |> reset_for_init(init)
      |> put_referrer(init)
      |> put_option(init, :referrer_policy, @referrer_policies)
      |> put_mode(init, fallback_mode)
      |> put_option(init, :credentials, @credentials_modes)
      |> put_cache(init)
      |> put_redirect(init)
      |> put_integrity(init)
      |> put_keepalive(init)
      |> put_method(init)

    :ok = validate_priority!(init)
    :ok = validate_no_cors_method!(request)

    headers =
      case Keyword.fetch(init, :headers) do
        {:ok, headers} when not is_nil(headers) -> Web.Headers.new(headers)
        _no_headers -> Web.Headers.new(request.headers)
      end

    input_body = input && input.body
    init_body = Keyword.get(init, :body)

    if request.method in ["GET", "HEAD"] and not (is_nil(init_body) and is_nil(input_body)) do
      raise Web.TypeError, "Request with GET/HEAD method cannot have body"
    end

    {request, headers} = put_init_body(request, headers, init, init_body)
    :ok = validate_duplex!(init)
    :ok = validate_stream_body!(request, init, init_body, input)

    # A body of the input request is the last step: a step that throws must
    # not change that body.
    request = if is_nil(init_body), do: take_input_body(request, input), else: request

    finish(request, headers, init)
  end

  # The Fetch Standard: "If init["window"] exists and is non-null, then
  # throw a TypeError." `nil` is null in Elixir.
  defp validate_window!(init) do
    case Keyword.get(init, :window) do
      nil -> :ok
      window -> raise Web.TypeError, "The option window must be nil, got: #{inspect(window)}"
    end
  end

  # "If init is not empty": a new request from a request with init is not a
  # navigation, and has the default referrer.
  defp reset_for_init(request, []), do: request

  defp reset_for_init(request, _init) do
    mode = if request.mode == "navigate", do: "same-origin", else: request.mode

    %{
      request
      | mode: mode,
        is_reload_navigation: false,
        is_history_navigation: false,
        referrer: "about:client",
        referrer_policy: ""
    }
  end

  # The field has the value of the getter `referrer`: `""` for
  # "no-referrer", `"about:client"` for "client", or the URL as a string. A
  # server runtime has no origin, as in Node.js: thus the step for a URL
  # that is not same origin has no effect.
  defp put_referrer(request, init) do
    case Keyword.get(init, :referrer) do
      nil -> request
      "" -> %{request | referrer: ""}
      referrer when is_binary(referrer) -> %{request | referrer: parse_referrer(referrer)}
      other -> raise Web.TypeError, "#{inspect(other)} is not a valid referrer"
    end
  end

  defp parse_referrer(referrer) do
    case Web.URL.parse(referrer) do
      %Web.URL{protocol: "about:", pathname: "client"} -> "about:client"
      %Web.URL{} = url -> Web.URL.href(url)
      nil -> raise Web.TypeError, "Invalid referrer URL: #{inspect(referrer)}"
    end
  end

  # A member of an enumeration of WebIDL. A value that is not in the
  # enumeration throws a `TypeError`.
  defp put_option(request, init, key, values) do
    case Keyword.get(init, key) do
      nil -> request
      value -> Map.put(request, key, enum!(value, key, values))
    end
  end

  defp enum!(value, key, values) when is_binary(value) or is_atom(value) do
    text = to_string(value)

    if text in values do
      text
    else
      raise Web.TypeError,
            "#{inspect(value)} is not a valid #{enum_name(key)}. " <>
              "Use one of: #{Enum.map_join(values, ", ", &inspect/1)}"
    end
  end

  defp enum!(value, key, _values) do
    raise Web.TypeError, "#{inspect(value)} is not a valid #{enum_name(key)}"
  end

  defp enum_name(:referrer_policy), do: "referrer policy"
  defp enum_name(:credentials), do: "credentials mode"
  defp enum_name(key) when key in [:mode, :cache, :redirect], do: "#{key} mode"
  defp enum_name(:priority), do: "priority"

  # "Let mode be init["mode"] if it exists, and fallbackMode otherwise. If
  # mode is "navigate", then throw a TypeError."
  defp put_mode(request, init, fallback_mode) do
    mode =
      case Keyword.get(init, :mode) do
        nil -> fallback_mode
        value -> enum!(value, :mode, @modes)
      end

    case mode do
      nil -> request
      "navigate" -> raise Web.TypeError, "The mode \"navigate\" is not valid for a new request"
      mode -> %{request | mode: mode}
    end
  end

  defp put_cache(request, init) do
    request = put_option(request, init, :cache, @cache_modes)

    if request.cache == "only-if-cached" and request.mode != "same-origin" do
      raise Web.TypeError,
            "The cache mode \"only-if-cached\" permits only the mode \"same-origin\""
    end

    request
  end

  defp put_redirect(request, init) do
    case Keyword.get(init, :redirect) do
      nil -> request
      value -> %{request | redirect: enum!(value, :redirect, @redirect_modes)}
    end
  end

  defp put_integrity(request, init) do
    case Keyword.get(init, :integrity) do
      nil -> request
      integrity when is_binary(integrity) -> %{request | integrity: integrity}
      other -> raise Web.TypeError, "#{inspect(other)} is not a valid integrity value"
    end
  end

  defp put_keepalive(request, init) do
    case Keyword.get(init, :keepalive) do
      nil -> request
      keepalive when is_boolean(keepalive) -> %{request | keepalive: keepalive}
      other -> raise Web.TypeError, "#{inspect(other)} is not a valid keepalive value"
    end
  end

  defp put_method(request, init) do
    case Keyword.get(init, :method) do
      nil -> request
      method -> %{request | method: normalize_method(method)}
    end
  end

  # The priority of a request has no field: the `Request` class of the
  # Standard does not show it.
  defp validate_priority!(init) do
    case Keyword.get(init, :priority) do
      nil -> :ok
      value -> if enum!(value, :priority, @priorities), do: :ok
    end
  end

  # The CORS-safelisted methods.
  @no_cors_methods ["GET", "HEAD", "POST"]

  defp validate_no_cors_method!(%{mode: "no-cors", method: method})
       when method not in @no_cors_methods do
    raise Web.TypeError, "The mode \"no-cors\" permits only the methods GET, HEAD, and POST."
  end

  defp validate_no_cors_method!(_request), do: :ok

  # The methods that the Fetch Standard changes to uppercase. Each other
  # method keeps its case.
  @normalized_methods ~w(DELETE GET HEAD OPTIONS POST PUT)
  @forbidden_methods ~w(CONNECT TRACE TRACK)

  # An atom has no equivalent in the Fetch Standard. It is always changed to
  # uppercase, thus `:patch` gives "PATCH".
  defp normalize_method(method) when is_atom(method) and not is_nil(method) do
    method |> Atom.to_string() |> String.upcase(:ascii) |> normalize_method()
  end

  # The usual case: a method that is in its normalized form already.
  defp normalize_method(method) when method in @normalized_methods, do: method

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

  # The Fetch Standard has one duplex mode: `"half"`, the request is sent in
  # full before the response is read. No other value is valid.
  defp validate_duplex!(init) do
    case Keyword.get(init, :duplex) do
      nil -> :ok
      duplex when duplex in ["half", :half] -> :ok
      duplex -> raise Web.TypeError, "#{inspect(duplex)} is not a valid duplex mode"
    end
  end

  # The step "extract a body" for the init body: a stream must be usable,
  # and `keepalive` refuses a stream.
  defp put_init_body(request, headers, _init, nil), do: {request, headers}

  defp put_init_body(request, headers, _init, raw_body) do
    if request.keepalive and stream_body?(raw_body) do
      raise Web.TypeError, "A request with keepalive cannot have a body that is a stream"
    end

    body = Web.Body.extract!(raw_body)
    headers = Web.Body.put_inferred_content_type(headers, raw_body)
    {%{request | body: body, body_source: body_source(raw_body)}, headers}
  end

  # A body with no source is a stream: it can be read only one time. It
  # needs the option `duplex: "half"`, and the mode "same-origin" or "cors".
  defp validate_stream_body!(request, init, init_body, input) do
    stream? =
      if is_nil(init_body),
        do: not is_nil(input) and not is_nil(input.body) and is_nil(input.body_source),
        else: stream_body?(init_body)

    cond do
      not stream? ->
        :ok

      not is_nil(init_body) and is_nil(Keyword.get(init, :duplex)) ->
        raise Web.TypeError,
              "The option `duplex: \"half\"` is necessary for a body that is a stream"

      request.mode not in ["same-origin", "cors"] ->
        raise Web.TypeError,
              "A body that is a stream needs the mode \"same-origin\" or \"cors\""

      true ->
        :ok
    end
  end

  # "If initBody is null and inputBody is non-null": the body of the input
  # must be usable, and the new request gets a proxy of it.
  defp take_input_body(request, %__MODULE__{body: body} = input) when not is_nil(body) do
    :ok = ensure_body_usable!(input)
    %{request | body: Web.Body.__proxy__(body), body_source: input.body_source}
  end

  defp take_input_body(request, _input), do: request

  defp finish(request, headers, init) do
    snapshot = request.snapshot || AsyncContext.Snapshot.new()
    signal = Keyword.get(init, :signal) || request.signal || snapshot.ambient_signal

    options =
      request.options
      |> Keyword.merge(Keyword.drop(init, [:method, :headers, :body, :dispatcher]))
      |> Keyword.put(:redirect, request.redirect)
      |> Keyword.put(:signal, signal)

    %{
      request
      | headers: headers,
        dispatcher: Keyword.get(init, :dispatcher, request.dispatcher),
        signal: signal,
        snapshot: snapshot,
        options: options
    }
  end

  # A body that is a stream has no source: it can be read only one time.
  defp stream_body?(%Web.FormData{}), do: false
  defp stream_body?(body), do: is_nil(body_source(body))

  # The source of a body is its data, when the data is in memory. A request
  # with such a body can be sent again after a redirect. A body from a stream
  # has no source.
  defp body_source(body) when is_binary(body) or is_list(body), do: body

  defp body_source(%module{} = body)
       when module in [Web.URLSearchParams, Web.Blob, Web.ArrayBuffer, Web.Uint8Array],
       do: body

  # A form with all its data in memory can be encoded again.
  defp body_source(%Web.FormData{} = form), do: if(Web.FormData.static?(form), do: form)

  defp body_source(_body), do: nil
end
