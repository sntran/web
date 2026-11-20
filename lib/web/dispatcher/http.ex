defmodule Web.Dispatcher.HTTP do
  @moduledoc "HTTP dispatcher on Mint, with its own connection pools and zero-buffer streaming."
  @behaviour Web.Dispatcher

  # ## The process of a request
  #
  # The promise of `fetch` is a small process: the process of the request.
  # It follows the redirects, owns the socket of its connection while the
  # response comes, and holds the body. The socket sends its messages to it
  # directly, and it never waits in a blocking call. Thus it always
  # answers: the readers, the abort signal, and the time limits. See
  # `Web.Dispatcher.HTTP.Exchange` for the network side.
  #
  #   * At the headers, the process waits for the end of the body for 1 ms.
  #     A body that ends in that time goes in the struct of the response,
  #     and the process stops. Thus a small response has no process, and
  #     `text/1` starts none. See `Web.Internal.LazyStream`.
  #   * Else the promise settles with the response, as the Fetch Standard
  #     specifies, and the process holds the body. A read of all the bytes,
  #     such as `text/1`, gets them in one message at the end of the body. A
  #     stream read makes a stream process, and the process gives each piece
  #     to it when it pulls.
  #   * The process stops to read its socket while it has 64 KiB that no
  #     reader took: the backpressure.
  #   * A body that no process reads in the time of `unread_body_timeout`
  #     releases its connection, and a later read rejects. When the owner
  #     stops, the body waits for the linger time, as a stream does.
  #
  # A connection that fails before the end of the body gives an error to
  # each read: a body that is not complete never looks complete. A cancel or
  # an abort closes the connection. See `tla/ResponseBody.tla`.

  alias Web.AsyncContext.Snapshot
  alias Web.Dispatcher.HTTP.Exchange
  alias Web.Headers
  alias Web.Internal.ContentDecoder
  alias Web.Internal.LazyStream
  alias Web.Internal.PromiseCell
  alias Web.ReadableStream

  # The bytes that a body keeps while no process reads it.
  @held_high_water_mark 65_536

  # The time in microseconds that the process waits for the end of the body
  # before the promise settles. A body that ends in this time goes in the
  # struct, and the response has no process. A body that does not end in
  # this time stays in this process, and the promise settles with the
  # headers, as the Fetch Standard specifies.
  @complete_wait 1_000

  # The process of a request starts with a heap for the work of one
  # request: a heap that grows step by step needs garbage collections.
  @heap_words 4_096

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
    owner = Web.Promise.owner()
    snapshot = Snapshot.take()
    context = %{rejection: rejection, owner: owner}

    pid =
      :erlang.spawn_opt(
        fn -> Snapshot.run(snapshot, fn -> run(request, context) end) end,
        min_heap_size: @heap_words
      )

    PromiseCell.promise(pid)
  end

  # ---------------------------------------------------------------------------
  # The process of the request
  # ---------------------------------------------------------------------------

  defp run(request, context) do
    # The process is the promise of `fetch`: a pending promise stops when its
    # owner stops, and a settled one keeps its outcome for the linger time.
    PromiseCell.start(context.owner)
    Web.Promise.put_owner(context.owner)

    subscription =
      case Web.AbortSignal.subscribe(request.signal) do
        {:ok, subscription} ->
          context = Map.put(context, :subscription, subscription)
          with_request_signal(request.signal, fn -> run_request(request, 0, context) end)
          subscription

        {:error, :aborted} ->
          reject(context, :aborted)
          nil
      end

    # The work is complete: the signal has no more use. The process keeps
    # the outcome for the linger time.
    Web.AbortSignal.unsubscribe(subscription)
    PromiseCell.linger()
  end

  defp run_request(request, redirect_count, context) do
    case Exchange.start(request) do
      :ok ->
        head = await_head(context)
        handle_head(head, request, redirect_count, context)

      {:error, reason} ->
        reject(context, reason)
    end
  end

  defp reject(context, reason), do: PromiseCell.settle({:rejected, context.rejection.(reason)})
  defp resolve(_context, response), do: PromiseCell.settle({:fulfilled, response})

  # The events of the network, of the signal, and of the readers of the body
  # come as messages. Each wait of this process uses this function. A
  # message of the network that gives no event is `:network`.
  defp next_event(context, timeout) do
    case Exchange.next() do
      {:ok, event} -> event
      :none -> receive_event(context, timeout)
    end
  end

  defp receive_event(context, timeout) do
    network = Exchange.wait_time()

    receive do
      message ->
        case Exchange.handle(message) do
          :handled -> network_event()
          :unknown -> other_event(message, context)
        end
    after
      min(timeout, network) ->
        if network <= timeout do
          Exchange.expire()
          network_event()
        else
          :timeout
        end
    end
  end

  defp network_event do
    case Exchange.next() do
      {:ok, event} -> event
      :none -> :network
    end
  end

  # A message of the promise: an await, or the end of the owner. Then an
  # abort, a message of a reader, or a message with no use.
  defp other_event(message, context) do
    case PromiseCell.handle(message) do
      :handled -> :promise_message
      {:owner_down, reason} -> {:owner_down, reason}
      :expired -> :promise_message
      :unknown -> abort_or_message(message, context)
    end
  end

  defp abort_or_message(message, context) do
    case abort_event(message, Map.get(context, :subscription)) do
      nil -> {:message, message}
      reason -> {:aborted, reason}
    end
  end

  # The messages of the subscription to the abort signal: see
  # `Web.AbortSignal.receive_abort/3`. A signal whose process stopped is an
  # aborted signal.
  defp abort_event({:abort, ref, reason}, %{type: :abort_signal, ref: ref}), do: reason
  defp abort_event({:abort, pid, reason}, %{type: :pid, pid: pid}), do: reason
  defp abort_event({:abort, token}, %{type: :token, token: token}), do: :aborted
  defp abort_event({:abort, token, reason}, %{type: :token, token: token}), do: reason

  defp abort_event({:DOWN, monitor, :process, _pid, reason}, %{monitor_ref: monitor} = sub) do
    case {sub.type, reason} do
      {:abort_signal, {:shutdown, {:aborted, reason}}} -> reason
      {:abort_signal, _reason} -> Web.AbortSignal.default_reason()
      {:pid, reason} -> reason
    end
  end

  defp abort_event(_message, _subscription), do: nil

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
    start_body({request, count, status, headers, protocol}, context)
  end

  defp handle_head({:head, :null, status, headers, _location, protocol}, request, count, context) do
    case await_end(context) do
      :ok -> resolve(context, response({request, count, status, headers, protocol}, nil))
      {:error, reason} -> reject(context, body_error(reason))
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
  defp handle_head(:owner_down, _request, _count, _context), do: stop_request()

  defp stop_request do
    Exchange.close()
    exit(:normal)
  end

  defp abort_request(context) do
    Exchange.close()
    reject(context, :aborted)
  end

  # The end of a body that the process does not give: a response with no
  # body, or the body of a redirect.
  defp await_end(context) do
    case next_event(context, :infinity) do
      :done -> Exchange.finish()
      {:error, reason} -> {:error, reason}
      {:aborted, _reason} -> :aborted
      {:owner_down, _reason} -> stop_request()
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
      snapshot: Snapshot.take()
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

  # The response of the request, and the streams that a read of its body
  # makes, get the signal of the request. Thus an abort puts the body in the
  # errored state.
  defp with_request_signal(%Web.AbortSignal{} = signal, fun) do
    Web.AsyncContext.with_signal(signal, fun)
  end

  defp with_request_signal(_signal, fun), do: fun.()

  # ---------------------------------------------------------------------------
  # The body of the response
  # ---------------------------------------------------------------------------

  defp start_body(head, context) do
    {request, _count, _status, _headers, _protocol} = head

    body = %{
      context: context,
      lazy: LazyStream.new({:held, self()}, request.signal),
      head: head,
      pieces: [],
      size: 0,
      ended: nil,
      mode: :buffer,
      taker: nil,
      stream: nil,
      stream_monitor: nil,
      stream_wants?: false,
      deadline: deadline(Web.Application.unread_body_timeout())
    }

    collect(body, System.monotonic_time(:microsecond) + @complete_wait)
  end

  # Before the promise settles: the process collects the body for a short
  # time. A body that ends in this time goes in the struct of the response.
  # The promise settles with the headers at the end of the time, at the
  # limit of the queue, at a failure, or at an abort.
  defp collect(body, until) do
    body.context
    |> next_event(collect_wait(until))
    |> collect_event(body, until)
  end

  defp collect_wait(until) do
    max(div(until - System.monotonic_time(:microsecond) + 999, 1_000), 0)
  end

  defp collect_event({:data, piece}, body, until) do
    body = add_piece(body, piece)
    if body.size >= @held_high_water_mark, do: settle_held(body), else: collect(body, until)
  end

  # The body is complete: it goes in the struct, and the process stops.
  defp collect_event(:done, body, _until) do
    lazy = %{body.lazy | source: {:bytes, bytes(body)}}
    resolve(body.context, response(body.head, %ReadableStream{lazy: lazy}))
    Exchange.finish()
  end

  # A failure, or an abort, gives a response whose body has the error.
  defp collect_event({:error, reason}, body, _until), do: fail(body, body_error(reason))

  defp collect_event({:aborted, reason}, body, _until) do
    Exchange.close()
    fail(body, reason)
  end

  defp collect_event({:owner_down, _reason}, _body, _until), do: stop_request()
  defp collect_event(:timeout, body, _until), do: settle_held(body)

  # A message of the network with no event, a message of the promise, or a
  # message with no use.
  defp collect_event(_other, body, until), do: collect(body, until)

  # The body failed before the promise settled: the response has the error
  # in its struct, and this process stops.
  defp fail(body, error) do
    lazy = %{body.lazy | source: {:error, error}}
    resolve(body.context, response(body.head, %ReadableStream{lazy: lazy}))
  end

  # The promise settles with the response, and this process holds its body
  # until a read.
  defp settle_held(body) do
    resolve(body.context, response(body.head, %ReadableStream{lazy: body.lazy}))
    hold(body)
  end

  defp add_piece(body, piece) do
    %{body | pieces: [piece | body.pieces], size: body.size + byte_size(piece)}
  end

  defp bytes(body), do: body.pieces |> :lists.reverse() |> IO.iodata_to_binary()

  # The process holds the body. It answers the readers, and applies the
  # lifetime rules of a stream to a body that no process reads.
  defp hold(body) do
    body.context
    |> next_event(hold_timeout(body))
    |> hold_event(body)
  end

  defp hold_event({:data, piece}, body),
    do: body |> add_piece(piece) |> take_piece(piece) |> hold()

  defp hold_event(:done, body) do
    Exchange.finish()
    body |> end_body({:ok, :done}) |> hold_or_stop()
  end

  defp hold_event({:error, reason}, body),
    do: body |> end_body({:error, body_error(reason)}) |> hold_or_stop()

  defp hold_event({:aborted, reason}, body), do: abort(body, reason)
  defp hold_event({:owner_down, reason}, body), do: body |> owner_down(reason) |> hold_or_stop()

  defp hold_event({:message, {:web_body, ref, request}}, %{lazy: %{ref: ref}} = body),
    do: body |> reader_request(request) |> hold_or_stop()

  defp hold_event({:message, message}, body), do: body |> other_message(message) |> hold_or_stop()
  defp hold_event(:timeout, body), do: stop_body(body)

  # A message of the network with no event, or a message of the promise.
  defp hold_event(_other, body), do: hold(body)

  defp hold_or_stop(:stop), do: :ok
  defp hold_or_stop(body), do: hold(body)

  # A body that no process reads has a time limit, and the linger time of
  # an owner that stopped.
  defp hold_timeout(%{mode: :buffer} = body), do: remaining(body.deadline)
  defp hold_timeout(_body), do: :infinity

  # A read of all the bytes takes the bytes that the process has, and each
  # subsequent piece: the bytes leave the buffer at once.
  defp reader_request(body, {:take, reply, pid}) do
    Exchange.credit(body.size)
    body = %{body | mode: :take, taker: {reply, pid}}
    if body.ended, do: answer_take(body), else: body
  end

  # A stream read: the stream gets the pieces that the process has, and then
  # each piece when it pulls.
  defp reader_request(body, {:stream, pid}) do
    body = %{body | mode: :stream, stream: pid, stream_monitor: Process.monitor(pid)}
    body |> flush_pieces() |> close_if_ended()
  end

  defp reader_request(%{mode: :stream, pieces: [_ | _]} = body, :pull), do: flush_pieces(body)
  defp reader_request(body, :pull), do: %{body | stream_wants?: true}

  defp other_message(body, {:DOWN, monitor, :process, _pid, _reason})
       when monitor == body.stream_monitor do
    stop_body(body)
  end

  defp other_message(body, _message), do: body

  # The owner stopped. A body that no process reads waits for the linger
  # time, then it stops. An owner that failed gives no linger time.
  defp owner_down(%{mode: :buffer} = body, reason) when reason in [:normal, :noproc] do
    %{body | deadline: min(body.deadline, deadline(Web.Promise.default_linger()))}
  end

  defp owner_down(%{mode: :buffer} = body, _reason), do: stop_body(body)
  defp owner_down(body, _reason), do: body

  # The end of the body from the network: `{:ok, :done}`, or the error.
  defp end_body(body, ended) do
    body = %{body | ended: ended}

    case body.mode do
      :buffer -> body
      :take -> answer_take(body)
      :stream -> close_if_ended(body)
    end
  end

  defp answer_take(%{taker: {reply, pid}} = body) do
    result =
      case body.ended do
        {:ok, :done} -> {:ok, bytes(body)}
        {:error, error} -> {:error, error}
      end

    send(pid, {reply, result})
    :stop
  end

  # A new piece from the network. A read of all the bytes takes it at once.
  # A stream that wants a chunk gets it.
  defp take_piece(%{mode: :take} = body, piece) do
    Exchange.credit(byte_size(piece))
    body
  end

  defp take_piece(%{mode: :stream, stream_wants?: true} = body, _piece), do: flush_pieces(body)
  defp take_piece(body, _piece), do: body

  # The pieces go to the stream, and leave the buffer of the process.
  defp flush_pieces(body) do
    for piece <- :lists.reverse(body.pieces) do
      ReadableStream.enqueue(body.stream, Web.Uint8Array.from(piece))
    end

    if body.size > 0, do: Exchange.credit(body.size)
    %{body | pieces: [], size: 0, stream_wants?: false}
  end

  defp close_if_ended(%{ended: nil} = body), do: body

  defp close_if_ended(%{ended: {:ok, :done}} = body) do
    body = flush_pieces(body)
    ReadableStream.close(body.stream)
    :stop
  end

  defp close_if_ended(%{ended: {:error, error}} = body) do
    ReadableStream.error(body.stream, error)
    :stop
  end

  # An abort errors the body: each read gets the reason of the signal. The
  # connection closes. A stream has the signal of the request: it gets the
  # abort itself.
  defp abort(%{mode: :stream} = body, _reason), do: stop_body(body)

  defp abort(body, reason) do
    Exchange.close()

    case body.mode do
      :buffer -> hold(%{body | ended: {:error, reason}, pieces: [], size: 0})
      :take -> answer_take(%{body | ended: {:error, reason}})
    end
  end

  # The body stops with no read: the time limit, the end of the owner, or a
  # stream that stopped. The connection closes, and a later read rejects.
  defp stop_body(_body) do
    Exchange.close()
    :stop
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # A network error in the body is a `TypeError`, as the Fetch Standard
  # specifies.
  defp body_error(%ContentDecoder.Error{} = error) do
    %Web.TypeError{message: "The response body cannot be decoded.", cause: error}
  end

  defp body_error(reason) do
    %Web.TypeError{message: "The response body is not complete.", cause: reason}
  end

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
end
