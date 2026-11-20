defmodule Web.Dispatcher.HTTP do
  @moduledoc "HTTP dispatcher using Finch with zero-buffer streaming."
  @behaviour Web.Dispatcher

  # ## The processes of a request
  #
  # The worker runs the request of the HTTP client. It gives the status and
  # the headers of the response to the process that called `fetch/1`. That
  # process makes the body stream, and gives it to the worker. Then the
  # worker enqueues each chunk of the body directly into the stream:
  #
  #   * while the stream wants chunks (its desired size is above 0), the
  #     worker enqueues with no wait. Thus one pull can get many chunks;
  #   * when the stream has enough chunks, the worker waits for the next
  #     pull. The pull callback of the stream only sends a message to the
  #     worker. This is the backpressure: the worker does not read the
  #     connection while it waits;
  #   * at the end of the body, the worker closes the stream. When the
  #     connection fails, or the body cannot be decoded, the worker puts the
  #     stream in the errored state with a `Web.TypeError`.
  #
  # The watcher monitors the worker. A worker that stops with no message,
  # for example a worker that a different process kills, puts the stream in
  # the errored state: a body that is not complete never looks complete. The
  # cancel callback of the stream tells the watcher, and the watcher stops
  # the worker. See `tla/ResponseBody.tla`.

  alias Web.Internal.Bytes
  alias Web.Internal.ContentDecoder
  alias Web.ReadableStream

  @max_redirects 20
  @default_receive_timeout 300_000
  @redirect_statuses [301, 302, 303, 307, 308]
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
    do_fetch(request, 0)
  end

  defp do_fetch(%Web.Request{} = request, redirect_count) do
    case Web.AbortSignal.subscribe(request.signal) do
      {:ok, signal_subscription} ->
        result = send_request(request, signal_subscription, redirect_count)
        Web.AbortSignal.unsubscribe(signal_subscription)
        release_request_body(request)
        handle_redirect(result, request, redirect_count)

      {:error, :aborted} ->
        {:error, :aborted}
    end
  end

  defp send_request(request, signal_subscription, redirect_count) do
    with {:ok, finch_request} <- build_finch_request(request) do
      ref = make_ref()
      owner = self()
      {worker, monitor} = spawn_monitor(fn -> run_worker(owner, ref, finch_request) end)

      case await_response_head(worker, ref, monitor, signal_subscription) do
        {:ok, status, headers} ->
          {:ok,
           with_request_signal(request.signal, fn ->
             Web.Response.__network__(
               status: status,
               status_text: status_text(status, request.url),
               headers: headers,
               body: response_body({worker, ref, monitor}, signal_subscription, request, status),
               url: Web.URL.href(request.url),
               redirected: redirect_count > 0
             )
           end)}

        {:error, reason} ->
          Process.demonitor(monitor, [:flush])
          Process.exit(worker, :kill)
          {:error, reason}
      end
    end
  end

  # The status text of a response. The HTTP client does not give the reason
  # phrase of an HTTP/1.1 response, thus the text comes from a table of the
  # usual phrases. An HTTP/2 response has no reason phrase, and its status
  # text is the empty string, as the Fetch Standard specifies. With the two
  # versions, a TLS connection can use HTTP/2, thus its text is empty also.
  @doc false
  def status_text(status, url) do
    case Web.Application.http_protocols() do
      [:http1] -> Map.get(@status_texts, status, "")
      [:http2] -> ""
      [:http1, :http2] -> if cleartext?(url), do: Map.get(@status_texts, status, ""), else: ""
    end
  end

  defp cleartext?(url), do: Web.URL.protocol(url) == "http:"

  @null_body_statuses [101, 103, 204, 205, 304]

  # The response of a HEAD request, and a response with a status that permits
  # no body, have the body `nil`, as the Fetch Standard specifies. The worker
  # reads the response to its end, thus the connection is released, and this
  # process waits for it.
  defp response_body({worker, ref, monitor}, signal_subscription, request, status)
       when request.method == "HEAD" or status in @null_body_statuses do
    check_abort!(signal_subscription, worker)
    send(worker, {:http_body, ref, :discard})

    receive do
      {:http_done, ^ref} ->
        Process.demonitor(monitor, [:flush])
        nil

      {:http_failed, ^ref, reason} ->
        Process.demonitor(monitor, [:flush])
        raise_body_error(reason)

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        raise_body_error({:connection_process_stopped, reason})
    end
  end

  # The body stream keeps this number of bytes before the worker waits. Thus
  # the full body of a small response arrives also when no process reads it,
  # and its connection goes back to the pool.
  @body_high_water_mark 65_536

  # A body that no process reads, and that is larger than the queue of the
  # stream, holds its connection. Thus the body stream has a time limit for
  # the start of the read. A reader that stops cancels the body. The stream
  # is made in this process, thus its owner is the process that called
  # `fetch/1`, and it gets the signal of the request.
  defp response_body({worker, ref, monitor}, _signal_subscription, _request, _status) do
    watcher = spawn(fn -> watch(worker, ref) end)

    stream =
      ReadableStream.new(
        %{
          pull: fn _controller -> send(worker, {:http_pull, ref}) end,
          cancel: fn _reason -> send(watcher, {:http_cancel, ref}) end
        },
        high_water_mark: @body_high_water_mark,
        strategy: Web.ByteLengthQueuingStrategy.new(@body_high_water_mark),
        unread_timeout: Web.Application.unread_body_timeout(),
        cancel_on_reader_exit: true
      )

    send(watcher, {:http_stream, ref, stream.controller_pid})
    send(worker, {:http_body, ref, stream.controller_pid})
    Process.demonitor(monitor, [:flush])
    stream
  end

  defp receive_timeout do
    Application.get_env(:web, :receive_timeout, @default_receive_timeout)
  end

  # The body stream of the response subscribes to the signal of the request.
  # Thus an abort puts the body in the errored state immediately.
  defp with_request_signal(%Web.AbortSignal{} = signal, fun) do
    Web.AsyncContext.with_signal(signal, fun)
  end

  defp with_request_signal(_signal, fun), do: fun.()

  # ---------------------------------------------------------------------------
  # Redirects: the "HTTP-redirect fetch" procedure of the Fetch Standard
  # ---------------------------------------------------------------------------

  defp handle_redirect({:error, _reason} = error, _request, _redirect_count), do: error

  defp handle_redirect({:ok, response} = result, request, redirect_count) do
    location = Web.Headers.get(response.headers, "location")

    cond do
      response.status not in @redirect_statuses or is_nil(location) ->
        result

      redirect_mode(request) == "manual" ->
        result

      redirect_mode(request) == "error" ->
        close_body(response.body)
        {:error, :redirect_error}

      true ->
        close_body(response.body)
        follow_redirect(request, response.status, location, redirect_count)
    end
  end

  defp redirect_mode(request), do: request.options[:redirect] || request.redirect || "follow"

  defp follow_redirect(_request, _status, _location, redirect_count)
       when redirect_count >= @max_redirects do
    {:error, :too_many_redirects}
  end

  defp follow_redirect(request, status, location, redirect_count) do
    with {:ok, next_url} <- redirect_url(request.url, location),
         {:ok, next_request} <- redirect_request(request, status, next_url) do
      do_fetch(next_request, redirect_count + 1)
    end
  end

  # The location is relative to the URL of the request. A location with no
  # fragment gets the fragment of the request.
  defp redirect_url(request_url, location) do
    next_url = Web.URL.new(location, Web.URL.href(request_url))

    cond do
      Web.URL.protocol(next_url) not in ["http:", "https:"] ->
        {:error, :redirect_unsupported_scheme}

      Web.URL.hash(next_url) == "" ->
        {:ok, Web.URL.hash(next_url, Web.URL.hash(request_url))}

      true ->
        {:ok, next_url}
    end
  rescue
    ArgumentError -> {:error, :redirect_invalid_location}
  end

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
    Web.Request.new(
      next_url,
      request.options
      |> Keyword.put(:method, method)
      |> Keyword.put(:headers, headers)
      |> Keyword.put(:body, body)
      |> Keyword.put(:dispatcher, request.dispatcher)
    )
  end

  defp close_body(nil), do: :ok

  defp close_body(body_stream) do
    _ = Enum.reduce_while(body_stream, :ok, fn _, acc -> {:halt, acc} end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Request body
  # ---------------------------------------------------------------------------

  defp build_finch_request(request) do
    {:ok,
     Finch.build(
       request.method,
       request_uri(request.url),
       Web.Headers.to_list(request_headers(request.headers)),
       request_body(request)
     )}
  rescue
    error -> {:error, error}
  end

  # The HTTP client parses a URL string with `URI.parse/1`, which runs
  # regular expressions. The URL of the request is parsed already, thus the
  # dispatcher gives its parts. The host has no brackets, and the path and
  # the query are in their serialized form.
  defp request_uri(url) do
    %URI{
      scheme: url.protocol |> String.trim_trailing(":"),
      host: url.hostname,
      port: request_port(url),
      path: url.pathname,
      query: request_query(Web.URL.search(url))
    }
  end

  defp request_port(%Web.URL{port: "", protocol: "https:"}), do: 443
  defp request_port(%Web.URL{port: ""}), do: 80
  defp request_port(%Web.URL{port: port}), do: String.to_integer(port)

  defp request_query(""), do: nil
  defp request_query("?" <> query), do: query

  # The request is complete or it failed. Cancel a body stream that the
  # request did not read to its end, thus the stream stops.
  defp release_request_body(%Web.Request{body: %Web.ReadableStream{controller_pid: pid}}) do
    Web.Stream.terminate_and_wait(pid, :cancel, :request_complete)
  end

  defp release_request_body(_request), do: :ok

  defp request_body(%Web.Request{body: nil}), do: nil

  # The data of the body is in memory. Send it as one block, thus the request
  # has a content length.
  defp request_body(%Web.Request{body: %Web.ReadableStream{} = body, body_source: source})
       when not is_nil(source) do
    body |> Enum.map_join(&request_chunk/1)
  end

  # The body is a stream. Finch reads it chunk by chunk when it sends the
  # request.
  defp request_body(%Web.Request{body: %Web.ReadableStream{} = body}) do
    {:stream, Stream.map(body, &request_chunk/1)}
  end

  defp request_body(%Web.Request{body: body}) when is_binary(body) or is_list(body), do: body

  defp request_body(%Web.Request{body: body}) do
    if Enumerable.impl_for(body) do
      {:stream, body}
    else
      raise Web.TypeError, "The request body is not valid: #{inspect(body)}"
    end
  end

  # A chunk of a request body is a chunk of bytes, as the Fetch Standard
  # specifies.
  defp request_chunk(chunk), do: Bytes.to_binary!(chunk, "The request body")

  # The request has no header `accept-encoding`: it gets the codings that
  # the body decoder knows. A request with the header `range` gets
  # `identity`, as the Fetch Standard specifies: the range is a range of the
  # bytes that the server has.
  defp request_headers(headers) do
    cond do
      Web.Headers.has(headers, "accept-encoding") -> headers
      Web.Headers.has(headers, "range") -> Web.Headers.set(headers, "accept-encoding", "identity")
      true -> Web.Headers.set(headers, "accept-encoding", ContentDecoder.accept_encoding())
    end
  end

  # ---------------------------------------------------------------------------
  # The head of the response
  # ---------------------------------------------------------------------------

  # The signal of the request stops the wait for the head of the response.
  defp await_response_head(worker, ref, monitor, signal_subscription) do
    receive do
      {:http_head, ^ref, status, headers} ->
        {:ok, status, headers}

      {:http_failed, ^ref, reason} ->
        {:error, reason}

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        {:error, reason}
    after
      50 ->
        case Web.AbortSignal.receive_abort(signal_subscription, 0) do
          {:error, :aborted} -> {:error, :aborted}
          :ok -> await_response_head(worker, ref, monitor, signal_subscription)
        end
    end
  end

  # A signal that aborted before the end of the request stops it.
  defp check_abort!(signal_subscription, worker) do
    case Web.AbortSignal.receive_abort(signal_subscription, 0, true) do
      {:error, :aborted, reason} ->
        Process.exit(worker, :kill)
        raise_abort(reason)

      :ok ->
        :ok
    end
  end

  defp raise_abort(reason) when is_exception(reason), do: raise(reason)

  defp raise_abort(reason),
    do: raise(Web.DOMException, name: "AbortError", message: inspect(reason))

  # A network error in the body is a `TypeError`, as the Fetch Standard
  # specifies.
  defp raise_body_error(reason), do: raise(body_error(reason))

  defp body_error(%ContentDecoder.Error{} = error) do
    %Web.TypeError{message: "The response body cannot be decoded.", cause: error}
  end

  defp body_error(reason) do
    %Web.TypeError{message: "The response body is not complete.", cause: reason}
  end

  # ---------------------------------------------------------------------------
  # The watcher
  # ---------------------------------------------------------------------------

  # The watcher gets the stream from the process that made it. A worker that
  # stops before the end of the body puts the stream in the errored state.
  #
  # The worker can complete a small body before this process starts. A
  # monitor of a process that stopped gives the reason `:noproc`, thus the
  # watcher cannot know if the body is complete. Thus the worker waits for
  # `:http_watched` before it stops, and this message comes after the
  # monitor.
  defp watch(worker, ref) do
    monitor = Process.monitor(worker)
    send(worker, {:http_watched, ref})

    stream =
      receive do
        {:http_stream, ^ref, stream} -> stream
      end

    receive do
      {:http_cancel, ^ref} ->
        Process.exit(worker, :kill)

      {:DOWN, ^monitor, :process, ^worker, :normal} ->
        :ok

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        ReadableStream.error(stream, body_error({:connection_process_stopped, reason}))
    end
  end

  # ---------------------------------------------------------------------------
  # The worker
  # ---------------------------------------------------------------------------

  defp run_worker(owner, ref, finch_request) do
    acc = %{
      owner: owner,
      owner_monitor: Process.monitor(owner),
      ref: ref,
      status: nil,
      phase: :head,
      stream: nil,
      stream_monitor: nil,
      decoder: nil
    }

    result =
      try do
        Finch.stream_while(
          finch_request,
          Web.Application.finch_name(finch_request.scheme),
          acc,
          &handle_event/2,
          # The time to wait for the response headers, and for each
          # subsequent part of the body. It does not include the time that
          # the reader of the body uses, nor the time to send the request
          # body.
          receive_timeout: receive_timeout(),
          # A request waits for a free connection with no limit, as in a
          # browser. The signal of the request stops the wait.
          pool_timeout: :infinity,
          request_timeout: :infinity
        )
      catch
        # The callback failed, for example on data that cannot be decoded.
        # The HTTP client closed the connection. The last state of the
        # request is in the process dictionary.
        :error, reason -> {:error, reason, Process.get(__MODULE__, acc)}
      end

    report(result)
    await_watcher(result)
  end

  # A worker with a body stream stops only when its watcher monitors it.
  defp await_watcher({:ok, %{phase: :body} = acc}), do: receive_watched(acc.ref)
  defp await_watcher({:error, _reason, %{phase: :body} = acc}), do: receive_watched(acc.ref)
  defp await_watcher(_result), do: :ok

  defp receive_watched(ref) do
    receive do
      {:http_watched, ^ref} -> :ok
    end
  end

  defp handle_event({:status, status}, acc), do: {:cont, %{acc | status: status}}

  # An informational response (a status from 100 to 199, but not 101) comes
  # before the response. The Fetch Standard ignores it: the worker waits for
  # the subsequent status and headers.
  defp handle_event({:headers, _headers}, %{phase: :head, status: status} = acc)
       when status in 100..199 and status != 101 do
    {:cont, %{acc | status: nil}}
  end

  defp handle_event({:headers, headers}, %{phase: :head} = acc) do
    send(acc.owner, {:http_head, acc.ref, acc.status, headers})
    receive_body_target(acc, headers)
  end

  # The trailers of a response. The Fetch Standard does not give them to the
  # caller.
  defp handle_event({:headers, _trailers}, acc), do: {:cont, acc}
  defp handle_event({:trailers, _trailers}, acc), do: {:cont, acc}
  defp handle_event({:data, _chunk}, %{phase: :discard} = acc), do: {:cont, acc}
  defp handle_event({:data, chunk}, %{decoder: nil} = acc), do: {deliver(acc, chunk), acc}

  defp handle_event({:data, chunk}, acc) do
    {result, decoder} = ContentDecoder.decode(acc.decoder, chunk, &deliver(acc, &1))
    acc = remember(%{acc | decoder: decoder})
    {result, acc}
  end

  # The process that called `fetch/1` gives the body stream, or tells that
  # the response has no body. A process that stopped needs no response.
  defp receive_body_target(acc, headers) do
    owner_monitor = acc.owner_monitor

    receive do
      {:http_body, ref, :discard} when ref == acc.ref ->
        {:cont, remember(%{acc | phase: :discard})}

      {:http_body, ref, stream} when ref == acc.ref ->
        Process.demonitor(owner_monitor, [:flush])

        acc = %{
          acc
          | phase: :body,
            stream: stream,
            stream_monitor: Process.monitor(stream),
            decoder: ContentDecoder.new(headers)
        }

        {:cont, remember(acc)}

      {:DOWN, ^owner_monitor, :process, _owner, _reason} ->
        {:halt, %{acc | phase: :abandoned}}
    end
  end

  defp remember(acc) do
    Process.put(__MODULE__, acc)
    acc
  end

  # Enqueues one chunk, then waits while the stream has enough chunks.
  defp deliver(acc, chunk) do
    ReadableStream.enqueue(acc.stream, Web.Uint8Array.from(chunk))
    await_demand(acc, true)
  end

  # A stream that has enough chunks has chunks in its queue: a read that
  # waits takes a chunk at once. Thus a read makes the desired size larger,
  # and the stream calls pull again when it is above 0. The pull messages
  # that came before the check are of no use, and the worker drops them. A
  # pull that comes after the drop is new: the worker examines the desired
  # size again before it waits.
  defp await_demand(acc, drop?) do
    case ReadableStream.get_desired_size(acc.stream) do
      size when is_number(size) and size > 0 ->
        drop_pulls(acc.ref)
        :cont

      nil ->
        :halt

      _full when drop? ->
        drop_pulls(acc.ref)
        await_demand(acc, false)

      _full ->
        stream_monitor = acc.stream_monitor

        receive do
          {:http_pull, ref} when ref == acc.ref -> :cont
          {:DOWN, ^stream_monitor, :process, _stream, _reason} -> :halt
        end
    end
  end

  defp drop_pulls(ref) do
    receive do
      {:http_pull, ^ref} -> drop_pulls(ref)
    after
      0 -> :ok
    end
  end

  # The end of the request. The worker tells the process that waits: the
  # process that called `fetch/1` before the body, and the body stream after.
  defp report({:ok, %{phase: :body} = acc}) do
    # A stream that closes with chunks in its queue stays readable until a
    # read takes the last chunk: an abort of the request signal errors it.
    if finish_decoder(acc) == :cont do
      ReadableStream.close(acc.stream)
    end
  rescue
    error in ContentDecoder.Error -> ReadableStream.error(acc.stream, body_error(error))
  end

  defp report({:ok, %{phase: :discard} = acc}), do: send(acc.owner, {:http_done, acc.ref})
  defp report({:ok, %{phase: :abandoned}}), do: :ok

  defp report({:error, reason, %{phase: :body} = acc}) do
    ReadableStream.error(acc.stream, body_error(reason))
  end

  defp report({:error, reason, acc}), do: send(acc.owner, {:http_failed, acc.ref, reason})

  defp finish_decoder(%{decoder: nil}), do: :cont
  defp finish_decoder(acc), do: ContentDecoder.finish(acc.decoder, &deliver(acc, &1))
end
