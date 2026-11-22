defmodule Web.Dispatcher.HTTP do
  @moduledoc false

  # HTTP dispatcher on Mint, with its own connection pools and zero-buffer streaming.
  @behaviour Web.Dispatcher

  # ## The process of a request
  #
  # The promise of `fetch` is a small process: the process of the request.
  # It follows the redirects, owns the socket of its connection while the
  # response comes, and holds the body. See `Web.Dispatcher.RequestProcess`
  # for the process and the body, and `Web.Dispatcher.HTTP.Exchange` for the
  # network side.

  alias Web.AsyncContext.Snapshot
  alias Web.Dispatcher.HTTP.Exchange
  alias Web.Dispatcher.RequestProcess
  alias Web.Headers

  @max_redirects 20
  @credential_headers ["authorization", "cookie", "proxy-authorization"]
  @request_body_headers [
    "content-encoding",
    "content-language",
    "content-length",
    "content-location",
    "content-type"
  ]
  @status_texts %{
    100 => "Continue",
    101 => "Switching Protocols",
    102 => "Processing",
    103 => "Early Hints",
    200 => "OK",
    201 => "Created",
    202 => "Accepted",
    203 => "Non-Authoritative Information",
    204 => "No Content",
    205 => "Reset Content",
    206 => "Partial Content",
    207 => "Multi-Status",
    208 => "Already Reported",
    226 => "IM Used",
    300 => "Multiple Choices",
    301 => "Moved Permanently",
    302 => "Found",
    303 => "See Other",
    304 => "Not Modified",
    305 => "Use Proxy",
    307 => "Temporary Redirect",
    308 => "Permanent Redirect",
    400 => "Bad Request",
    401 => "Unauthorized",
    402 => "Payment Required",
    403 => "Forbidden",
    404 => "Not Found",
    405 => "Method Not Allowed",
    406 => "Not Acceptable",
    407 => "Proxy Authentication Required",
    408 => "Request Timeout",
    409 => "Conflict",
    410 => "Gone",
    411 => "Length Required",
    412 => "Precondition Failed",
    413 => "Content Too Large",
    414 => "URI Too Long",
    415 => "Unsupported Media Type",
    416 => "Range Not Satisfiable",
    417 => "Expectation Failed",
    418 => "I'm a teapot",
    421 => "Misdirected Request",
    422 => "Unprocessable Content",
    423 => "Locked",
    424 => "Failed Dependency",
    425 => "Too Early",
    426 => "Upgrade Required",
    428 => "Precondition Required",
    429 => "Too Many Requests",
    431 => "Request Header Fields Too Large",
    451 => "Unavailable For Legal Reasons",
    500 => "Internal Server Error",
    501 => "Not Implemented",
    502 => "Bad Gateway",
    503 => "Service Unavailable",
    504 => "Gateway Timeout",
    505 => "HTTP Version Not Supported",
    506 => "Variant Also Negotiates",
    507 => "Insufficient Storage",
    508 => "Loop Detected",
    510 => "Not Extended",
    511 => "Network Authentication Required"
  }

  @impl true
  @spec fetch(Web.Request.t()) :: {:ok, Web.Response.t()} | {:error, any()}
  def fetch(%Web.Request{} = request) do
    case request |> __start__(& &1) |> Web.Promise.wait() do
      {:fulfilled, response} -> {:ok, response}
      {:rejected, reason} -> {:error, reason}
    end
  end

  @doc false
  # Starts the process of a request, and returns its promise: the process is
  # the promise. It settles with the response, or with `rejection.(reason)`
  # for a failure. `Web.fetch/2` gives its rules of rejection.
  @spec __start__(Web.Request.t(), (term() -> term())) :: Web.Promise.t()
  def __start__(%Web.Request{} = request, rejection) when is_function(rejection, 1) do
    RequestProcess.start(request, Exchange, rejection, &run_request(&1, 0, &2))
  end

  # ---------------------------------------------------------------------------
  # The process of the request
  # ---------------------------------------------------------------------------

  defp run_request(request, redirect_count, context) do
    case Exchange.start(request) do
      :ok ->
        head = await_head(context)
        handle_head(head, request, redirect_count, context)

      {:error, reason} ->
        reject(context, reason)
    end
  end

  defp reject(context, reason), do: RequestProcess.reject(context, reason)
  defp resolve(context, response), do: RequestProcess.resolve(context, response)
  defp next_event(context, timeout), do: RequestProcess.next_event(context, timeout)

  # ---------------------------------------------------------------------------
  # The head of the response
  # ---------------------------------------------------------------------------

  defp await_head(context) do
    case next_event(context, :infinity) do
      {:head, _kind, _status, _headers, _location, _protocol} = head -> head
      {:error, reason} -> {:error, reason}
      {:aborted, _reason} -> :aborted
      {:owner_down, _reason} -> :owner_down
      _promise_network_or_other_message -> await_head(context)
    end
  end

  defp handle_head({:head, :body, status, headers, _location, protocol}, request, count, context) do
    head = {request, count, status, headers, protocol}
    RequestProcess.hold_body(context, request, &response(head, &1))
  end

  defp handle_head({:head, :null, status, headers, _location, protocol}, request, count, context) do
    case await_end(context) do
      :ok -> resolve(context, response({request, count, status, headers, protocol}, nil))
      {:error, reason} -> reject(context, RequestProcess.body_error(reason))
      :aborted -> abort_request(context)
    end
  end

  defp handle_head({:head, :discard, status, _headers, location, _p}, request, count, context) do
    case await_end(context) do
      :aborted ->
        abort_request(context)

      # The end of the body of the redirect, or the connection closed for a
      # large body: the redirect continues.
      _done_or_error ->
        case follow_redirect(request, status, location, count) do
          {:ok, next_request} -> run_request(next_request, count + 1, context)
          {:error, reason} -> reject(context, reason)
        end
    end
  end

  # The connection closed at the head already.
  defp handle_head({:head, :redirect_error, _status, _headers, _location, _p}, _r, _c, context),
    do: reject(context, :redirect_error)

  defp handle_head({:error, reason}, _request, _count, context), do: reject(context, reason)
  defp handle_head(:aborted, _request, _count, context), do: abort_request(context)

  # A pending promise stops when its owner stops, and its work stops.
  defp handle_head(:owner_down, _request, _count, context),
    do: RequestProcess.stop_request(context)

  defp abort_request(context), do: RequestProcess.abort_request(context)

  # The end of a body that the process does not give: a response with no
  # body, or the body of a redirect.
  defp await_end(context) do
    case next_event(context, :infinity) do
      :done -> Exchange.finish()
      {:error, reason} -> {:error, reason}
      {:aborted, _reason} -> :aborted
      {:owner_down, _reason} -> RequestProcess.stop_request(context)
      _promise_network_or_other_message -> await_end(context)
    end
  end

  defp response({request, redirect_count, status, headers, protocol}, body) do
    Web.Response.__network__(
      status: status,
      status_text: status_text(status, protocol),
      headers: Headers.__network__(headers),
      body: body,
      url: Web.URL.href(request.url),
      redirected: redirect_count > 0,
      snapshot: Snapshot.new()
    )
  end

  @doc false
  # The status text of a response. The HTTP client does not give the reason
  # phrase of an HTTP/1.1 response, thus the text comes from a table of the
  # usual phrases. An HTTP/2 response has no reason phrase, and its status
  # text is the empty string, as the Fetch Standard specifies.
  @spec status_text(non_neg_integer(), :http1 | :http2) :: String.t()
  def status_text(status, :http1), do: Map.get(@status_texts, status, "")
  def status_text(_status, :http2), do: ""

  # ---------------------------------------------------------------------------
  # Redirects: the "HTTP-redirect fetch" procedure of the Fetch Standard
  # ---------------------------------------------------------------------------

  defp follow_redirect(_request, _status, _location, redirect_count)
       when redirect_count >= @max_redirects do
    {:error, :too_many_redirects}
  end

  defp follow_redirect(request, status, location, _redirect_count) do
    with {:ok, next_url} <- redirect_url(request.url, location) do
      redirect_request(request, status, next_url)
    end
  end

  # The location is relative to the URL of the request. A location with no
  # fragment gets the fragment of the request. An empty fragment is a
  # fragment: the location "/a#" keeps its "#".
  defp redirect_url(request_url, location) do
    next_url = Web.URL.new(location, Web.URL.href(request_url))

    cond do
      Web.URL.protocol(next_url) not in ["http:", "https:"] ->
        {:error, :redirect_unsupported_scheme}

      next_url.fragment == nil ->
        {:ok, Web.URL.hash(next_url, fragment_text(request_url))}

      true ->
        {:ok, next_url}
    end
  rescue
    Web.TypeError -> {:error, :redirect_invalid_location}
  end

  # The value for the setter of the hash: "#" for an empty fragment, as the
  # getter gives "" for it.
  defp fragment_text(%Web.URL{fragment: nil}), do: ""
  defp fragment_text(%Web.URL{fragment: fragment}), do: "#" <> fragment

  defp redirect_request(request, status, next_url) do
    headers = redirect_headers(request, next_url)

    cond do
      method_becomes_get?(status, request.method) ->
        {:ok, next_request(request, next_url, "GET", drop_body_headers(headers), nil)}

      is_nil(request.body) ->
        {:ok, next_request(request, next_url, request.method, headers, nil)}

      # A body from a stream cannot be sent a second time.
      is_nil(request.body_source) ->
        {:error, :redirect_stream_body}

      true ->
        {:ok, next_request(request, next_url, request.method, headers, request.body_source)}
    end
  end

  defp method_becomes_get?(status, "POST") when status in [301, 302], do: true
  defp method_becomes_get?(303, method), do: method not in ["GET", "HEAD"]
  defp method_becomes_get?(_status, _method), do: false

  # A redirect to a different origin must not get the credentials of the
  # first origin.
  defp redirect_headers(request, next_url) do
    if Web.URL.origin(request.url) == Web.URL.origin(next_url) do
      request.headers
    else
      Enum.reduce(@credential_headers, request.headers, &Web.Headers.delete(&2, &1))
    end
  end

  defp drop_body_headers(headers) do
    Enum.reduce(@request_body_headers, headers, &Web.Headers.delete(&2, &1))
  end

  defp next_request(request, next_url, method, headers, body) do
    next =
      Web.Request.new(
        next_url,
        request.options
        |> Keyword.put(:method, method)
        |> Keyword.put(:headers, headers)
        |> Keyword.put(:body, body)
      )

    %{next | dispatcher: request.dispatcher}
  end
end
