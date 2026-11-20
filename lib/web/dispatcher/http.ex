defmodule Web.Dispatcher.HTTP do
  @moduledoc "HTTP dispatcher using Finch with zero-buffer streaming."
  @behaviour Web.Dispatcher

  # ## The processes of a request
  #
  # The promise of `fetch` is a small process. The process of the request
  # follows the redirects and holds the body. Its worker runs the request of
  # the HTTP client, and sends each event to it. The process of the request
  # never waits in the HTTP client, thus it always answers: the readers, the
  # abort signal, and the time limits.
  #
  #   * At the headers, the process waits for the end of the body for 1 ms.
  #     A body that ends in that time goes in the struct of the response,
  #     and the two processes stop. Thus a small response has no process,
  #     and `text/1` starts none. See `Web.Internal.LazyStream`.
  #   * Else the promise settles with the response, as the Fetch Standard
  #     specifies, and the process holds the body. A read of all the bytes,
  #     such as `text/1`, gets them in one message at the end of the body. A
  #     stream read makes a stream process, and the process gives each piece
  #     to it when it pulls.
  #   * The worker stops to read the connection while the process has
  #     64 KiB that no reader took: the backpressure.
  #   * A body that no process reads in the time of `unread_body_timeout`
  #     releases its connection, and a later read rejects. When the owner
  #     stops, the body waits for the linger time, as a stream does.
  #
  # A worker that stops before the end of the body gives an error to each
  # read: a body that is not complete never looks complete. A cancel or an
  # abort stops the worker, thus the connection does not stay. See
  # `tla/ResponseBody.tla`.

  alias Web.AsyncContext.Snapshot
  alias Web.Headers
  alias Web.Internal.Bytes
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

  # The process of a request and its worker start with a heap for the work
  # of one request: a heap that grows step by step needs garbage
  # collections.
  @heap_words 4_096

  @null_body_statuses [101, 103, 204, 205, 304]

  # The keys of the state of the worker in its process dictionary. The
  # content decoder gives each piece to a function with no other argument.
  @inflight_key {__MODULE__, :inflight}
  @kept_key {__MODULE__, :kept}
  @decoder_key {__MODULE__, :decoder}
  @owner_key {__MODULE__, :owner}

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
    # The worker is linked to this process: a stop of this process stops the
    # worker, and the exit of the worker is a message here.
    Process.flag(:trap_exit, true)
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

    # The work is complete: the exit of the worker and the signal have no
    # more use. The process keeps the outcome for the linger time.
    Web.AbortSignal.unsubscribe(subscription)
    Process.flag(:trap_exit, false)
    flush_exits()
    PromiseCell.linger()
  end

  defp flush_exits do
    receive do
      {:EXIT, _pid, _reason} -> flush_exits()
    after
      0 -> :ok
    end
  end

  defp run_request(request, redirect_count, context) do
    case build_finch_request(request) do
      {:ok, finch_request} ->
        worker = start_worker(finch_request, request, redirect_count)
        head = await_head(worker, context)
        release_request_body(request)

        handle_head(head, worker, request, redirect_count, context)

      {:error, reason} ->
        reject(context, reason)
    end
  end

  defp reject(context, reason), do: PromiseCell.settle({:rejected, context.rejection.(reason)})
  defp resolve(_context, response), do: PromiseCell.settle({:fulfilled, response})

  # The events of the worker, of the signal, and of the readers of the body
  # come as messages. Each wait of this process uses this function.
  defp next_event(worker, context, timeout) do
    %{pid: pid, ref: ref} = worker

    receive do
      {^ref, event} -> event
      {^ref, :data, piece} -> {:data, piece}
      {^ref, :error, reason} -> {:error, reason}
      {:EXIT, ^pid, :normal} -> :worker_stopped
      {:EXIT, ^pid, reason} -> {:error, {:connection_process_stopped, reason}}
      message -> other_event(message, worker, context)
    after
      timeout -> :timeout
    end
  end

  # A message of the promise: an await, or the end of the owner. Then an
  # abort, a message of a reader, or a message with no use. An await of a
  # pending promise goes to the worker also: the worker can give it a
  # complete response directly.
  defp other_event(message, worker, context) do
    case PromiseCell.handle(message) do
      :handled ->
        with {:subscribe, ref} <- message,
             false <- PromiseCell.settled?(),
             do: send(worker.pid, {worker.ref, :waiter, ref})

        :promise_message

      {:owner_down, reason} ->
        {:owner_down, reason}

      :expired ->
        :promise_message

      :unknown ->
        abort_or_message(message, context)
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

  defp await_head(worker, context) do
    case next_event(worker, context, :infinity) do
      {:head, _phase, _status, _headers, _location} = head -> head
      {:error, reason} -> {:error, reason}
      {:aborted, _reason} -> :aborted
      {:owner_down, _reason} -> :owner_down
      _promise_or_other_message -> await_head(worker, context)
    end
  end

  defp handle_head({:head, :body, status, headers, _location}, worker, request, count, context) do
    start_body(worker, {request, count, status, headers}, context)
  end

  defp handle_head({:head, :null, status, headers, _location}, worker, request, count, context) do
    case await_end(worker, context) do
      :done -> resolve(context, response(request, count, status, headers, nil))
      {:error, reason} -> reject(context, body_error(reason))
      :aborted -> abort_request(worker, context)
    end
  end

  defp handle_head({:head, :discard, status, _headers, location}, worker, request, count, context) do
    case await_end(worker, context) do
      :aborted ->
        abort_request(worker, context)

      # The end of the body of the redirect, or the worker closed a large
      # body: the redirect continues.
      _done_or_error ->
        case follow_redirect(request, status, location, count) do
          {:ok, next_request} -> run_request(next_request, count + 1, context)
          {:error, reason} -> reject(context, reason)
        end
    end
  end

  defp handle_head(
         {:head, :redirect_error, _status, _headers, _location},
         worker,
         _r,
         _c,
         context
       ) do
    stop_worker(worker)
    reject(context, :redirect_error)
  end

  defp handle_head({:error, reason}, _worker, _request, _count, context),
    do: reject(context, reason)

  # The worker can give a complete response before this process gets the
  # abort: the flag tells which outcome the promise has.
  defp handle_head(:aborted, worker, _request, _count, context),
    do: claim(worker, context, fn -> abort_request(worker, context) end)

  # A pending promise stops when its owner stops, and its work stops.
  defp handle_head(:owner_down, worker, _request, _count, _context), do: stop_request(worker)

  defp stop_request(worker) do
    stop_worker(worker)
    exit(:normal)
  end

  defp abort_request(worker, context) do
    stop_worker(worker)
    reject(context, :aborted)
  end

  # The end of a body that the worker does not give: a response with no
  # body, or the body of a redirect.
  defp await_end(worker, context) do
    case next_event(worker, context, :infinity) do
      :done -> :done
      {:error, reason} -> {:error, reason}
      {:aborted, _reason} -> :aborted
      {:owner_down, _reason} -> stop_request(worker)
      _promise_or_other_message -> await_end(worker, context)
    end
  end

  defp response(request, redirect_count, status, headers, body, snapshot \\ Snapshot.take()) do
    Web.Response.__network__(
      status: status,
      status_text: status_text(status, request.url),
      headers: Headers.__network__(headers),
      body: body,
      url: Web.URL.href(request.url),
      redirected: redirect_count > 0,
      snapshot: snapshot
    )
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

  defp receive_timeout do
    Application.get_env(:web, :receive_timeout, @default_receive_timeout)
  end

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

  # The response of a body that this process holds is made only when the
  # promise settles with it: on the fast path, the worker gives the
  # response.
  defp start_body(worker, head, context) do
    {request, _count, _status, _headers} = head

    body = %{
      worker: worker,
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
  # time. The worker and this process share a flag: the first of the two
  # that sets it gives the outcome of the promise. The worker sets it for a
  # body that is complete, and gives the response directly to the processes
  # that await it. This process sets it at the end of the time, at the
  # limit of the queue, at a failure, or at an abort.
  defp collect(body, until) do
    body.worker
    |> next_event(body.context, collect_wait(until))
    |> collect_event(body, until)
  end

  defp collect_wait(until) do
    max(div(until - System.monotonic_time(:microsecond) + 999, 1_000), 0)
  end

  defp collect_event({:data, piece}, body, until) do
    body = add_piece(body, piece)

    if body.size >= @held_high_water_mark,
      do: claim(body, fn -> settle_held(body) end),
      else: collect(body, until)
  end

  defp collect_event({:delivered, response, refs}, _body, _until) do
    PromiseCell.settle({:fulfilled, response}, refs)
  end

  # The end of the body does not come in this time: the worker gives the
  # response of a body that ends while the promise is pending, and a body
  # that is larger than the queue makes this process settle the promise
  # first. A failure, or an abort, gives a response whose body has the
  # error.
  defp collect_event({:error, reason}, body, _until) do
    claim(body, fn -> fail(body, body_error(reason)) end)
  end

  defp collect_event({:aborted, reason}, body, _until) do
    claim(body, fn ->
      stop_worker(body.worker)
      fail(body, reason)
    end)
  end

  defp collect_event({:owner_down, _reason}, body, _until), do: stop_request(body.worker)
  defp collect_event(:timeout, body, _until), do: claim(body, fn -> settle_held(body) end)

  # The exit of the worker after its last message, a message of the promise,
  # or a message with no use.
  defp collect_event(_other, body, until), do: collect(body, until)

  defp claim(body, fun), do: claim(body.worker, body.context, fun)

  # This process gives the outcome, or the worker gave it already: then the
  # message of the worker comes, and it is the outcome.
  defp claim(worker, context, fun) do
    case :atomics.compare_exchange(worker.flag, 1, 0, 1) do
      :ok -> fun.()
      _worker_gave_it -> await_delivered(worker, context)
    end
  end

  defp await_delivered(worker, context) do
    case next_event(worker, context, :infinity) do
      {:delivered, response, refs} -> PromiseCell.settle({:fulfilled, response}, refs)
      _other -> await_delivered(worker, context)
    end
  end

  # The body failed before the promise settled: the response has the error
  # in its struct, and this process stops.
  defp fail(body, error) do
    lazy = %{body.lazy | source: {:error, error}}
    resolve(body.context, head_response(body.head, %ReadableStream{lazy: lazy}))
  end

  defp head_response({request, count, status, headers}, stream_body) do
    response(request, count, status, headers, stream_body)
  end

  # The promise settles with the response, and this process holds its body
  # until a read.
  defp settle_held(body) do
    resolve(body.context, head_response(body.head, %ReadableStream{lazy: body.lazy}))
    hold(body)
  end

  defp add_piece(body, piece) do
    %{body | pieces: [piece | body.pieces], size: body.size + byte_size(piece)}
  end

  defp bytes(body), do: body.pieces |> :lists.reverse() |> IO.iodata_to_binary()

  # The process holds the body. It answers the readers, and applies the
  # lifetime rules of a stream to a body that no process reads.
  defp hold(body) do
    body.worker
    |> next_event(body.context, hold_timeout(body))
    |> hold_event(body)
  end

  defp hold_event({:data, piece}, body),
    do: body |> add_piece(piece) |> take_piece(piece) |> hold()

  defp hold_event(:done, body), do: body |> end_body({:ok, :done}) |> hold_or_stop()

  defp hold_event({:error, reason}, body),
    do: body |> end_body({:error, body_error(reason)}) |> hold_or_stop()

  defp hold_event({:aborted, reason}, body), do: abort(body, reason)
  defp hold_event({:owner_down, reason}, body), do: body |> owner_down(reason) |> hold_or_stop()

  defp hold_event({:message, {:web_body, ref, request}}, %{lazy: %{ref: ref}} = body),
    do: body |> reader_request(request) |> hold_or_stop()

  defp hold_event({:message, message}, body), do: body |> other_message(message) |> hold_or_stop()
  defp hold_event(:timeout, body), do: stop_body(body)

  # The exit of the worker after its last message, or a message of the
  # promise.
  defp hold_event(_other, body), do: hold(body)

  defp hold_or_stop(:stop), do: :ok
  defp hold_or_stop(body), do: hold(body)

  # A body that no process reads has a time limit, and the linger time of
  # an owner that stopped.
  defp hold_timeout(%{mode: :buffer} = body), do: remaining(body.deadline)
  defp hold_timeout(_body), do: :infinity

  # A read of all the bytes takes the bytes that the process has, and each
  # subsequent piece: the worker gets the credit for them at once.
  defp reader_request(body, {:take, reply, pid}) do
    ack(body, body.size)
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

  # The end of the body from the worker: `{:ok, :done}`, or the error.
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

  # A new piece from the worker. A read of all the bytes gives its credit
  # back at once. A stream that wants a chunk gets it.
  defp take_piece(%{mode: :take} = body, piece) do
    ack(body, byte_size(piece))
    body
  end

  defp take_piece(%{mode: :stream, stream_wants?: true} = body, _piece), do: flush_pieces(body)
  defp take_piece(body, _piece), do: body

  # The pieces go to the stream, and their credit goes back to the worker.
  defp flush_pieces(body) do
    for piece <- :lists.reverse(body.pieces) do
      ReadableStream.enqueue(body.stream, Web.Uint8Array.from(piece))
    end

    ack(body, body.size)
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

  # The worker sends pieces while the process has less than the limit of
  # bytes with no credit: see `worker_send/1`. Each byte gets its credit one
  # time, when it leaves the buffer of the process.
  defp ack(_body, 0), do: :ok
  defp ack(%{worker: %{pid: pid, ref: ref}}, bytes), do: send(pid, {ref, :ack, bytes})

  # An abort errors the body: each read gets the reason of the signal. The
  # connection closes.
  defp abort(body, reason) do
    stop_worker(body.worker)

    case body.mode do
      :buffer -> hold(%{body | ended: {:error, reason}, pieces: [], size: 0})
      :take -> answer_take(%{body | ended: {:error, reason}})
      :stream -> :ok
    end
  end

  # The body stops with no read: the time limit, the end of the owner, or a
  # stream that stopped. The connection closes, and a later read rejects.
  defp stop_body(body) do
    stop_worker(body.worker)
    :stop
  end

  defp stop_worker(%{pid: pid}) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
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
  # The worker
  # ---------------------------------------------------------------------------

  # The worker runs the request of the HTTP client, and sends each event to
  # the process of the request. It decodes the body, and it stops to read
  # the connection while the process has 64 KiB with no credit: the
  # backpressure.
  defp start_worker(finch_request, request, redirect_count) do
    ref = make_ref()
    flag = :atomics.new(1, signed: false)

    state = %{
      owner: self(),
      ref: ref,
      method: request.method,
      redirect: redirect_mode(request),
      status: nil,
      headers: nil,
      phase: :head,
      discarded: 0,
      # The data for a response that the worker gives to the processes
      # that await the promise: see `deliver_complete/1`.
      request: request,
      redirect_count: redirect_count,
      flag: flag,
      waiters: PromiseCell.waiters(),
      snapshot: Snapshot.take()
    }

    pid =
      :erlang.spawn_opt(fn -> run_worker(finch_request, state) end, [
        :link,
        min_heap_size: @heap_words
      ])

    %{pid: pid, ref: ref, flag: flag}
  end

  defp run_worker(finch_request, state) do
    Process.put(@inflight_key, 0)
    Process.put(@kept_key, {[], 0})

    result =
      try do
        Finch.stream_while(
          finch_request,
          Web.Application.finch_name(finch_request.scheme),
          state,
          &worker_event/2,
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
        # The HTTP client closed the connection.
        :error, reason -> {:error, reason, Process.get(__MODULE__, state)}
      end

    finish_worker(result)
  end

  defp finish_worker({:ok, %{phase: :body} = state}) do
    # The pieces of the end go to the process of the request: the worker
    # does not stop for them.
    :cont = finish_decoder(Process.get(@decoder_key))
    deliver_complete(state)
  rescue
    error in ContentDecoder.Error -> send(state.owner, {state.ref, :error, error})
  end

  defp finish_worker({:ok, state}), do: send(state.owner, {state.ref, :done})
  defp finish_worker({:error, reason, state}), do: send(state.owner, {state.ref, :error, reason})

  # A body that is complete while the promise is pending: the worker gives
  # the response directly to the processes that await the promise, and then
  # to the process of the request. Thus the response needs no other process
  # on its way. The flag lets one of the two processes only give the
  # outcome: see `collect/2`.
  defp deliver_complete(state) do
    with {pieces, _size} <- Process.get(@kept_key),
         :ok <- :atomics.compare_exchange(state.flag, 1, 0, 1) do
      binary = pieces |> :lists.reverse() |> IO.iodata_to_binary()
      lazy = LazyStream.new({:bytes, binary}, state.request.signal)
      body = %ReadableStream{lazy: lazy}

      response =
        response(
          state.request,
          state.redirect_count,
          state.status,
          state.headers,
          body,
          state.snapshot
        )

      refs = forwarded_waiters(state.ref, state.waiters)
      for ref <- refs, do: send(ref, {:web_promise, ref, {:fulfilled, response}})
      send(state.owner, {state.ref, {:delivered, response, refs}})
    else
      _no -> send(state.owner, {state.ref, :done})
    end
  end

  defp forwarded_waiters(ref, waiters) do
    receive do
      {^ref, :waiter, waiter} -> forwarded_waiters(ref, [waiter | waiters])
    after
      0 -> waiters
    end
  end

  defp finish_decoder(nil), do: :cont
  defp finish_decoder(decoder), do: ContentDecoder.finish(decoder, &worker_send/1)

  defp worker_event({:status, status}, state), do: {:cont, remember(%{state | status: status})}

  # An informational response (a status from 100 to 199, but not 101) comes
  # before the response. The Fetch Standard ignores it: the worker waits for
  # the subsequent status and headers.
  defp worker_event({:headers, _headers}, %{phase: :head, status: status} = state)
       when status in 100..199 and status != 101 do
    {:cont, %{state | status: nil}}
  end

  defp worker_event({:headers, headers}, %{phase: :head} = state) do
    location =
      case List.keyfind(headers, "location", 0) do
        {_name, value} -> value
        nil -> nil
      end

    phase = response_phase(state, location)
    send(state.owner, {state.ref, {:head, phase, state.status, headers, location}})
    state = %{state | headers: headers}

    if phase == :body do
      Process.put(@owner_key, {state.owner, state.ref})
      Process.put(@decoder_key, ContentDecoder.new(headers))
    end

    if phase == :redirect_error,
      do: {:halt, state},
      else: {:cont, remember(%{state | phase: phase})}
  end

  # The trailers of a response. The Fetch Standard does not give them to the
  # caller.
  defp worker_event({:headers, _trailers}, state), do: {:cont, state}
  defp worker_event({:trailers, _trailers}, state), do: {:cont, state}

  defp worker_event({:data, chunk}, %{phase: :body} = state) do
    result =
      case Process.get(@decoder_key) do
        nil ->
          worker_send(chunk)

        decoder ->
          {result, decoder} = ContentDecoder.decode(decoder, chunk, &worker_send/1)
          Process.put(@decoder_key, decoder)
          result
      end

    {result, state}
  end

  # The body of a redirect goes away. A large body closes the connection.
  defp worker_event({:data, chunk}, %{phase: :discard} = state) do
    state = %{state | discarded: state.discarded + byte_size(chunk)}
    if state.discarded > @held_high_water_mark, do: {:halt, state}, else: {:cont, state}
  end

  defp worker_event({:data, _chunk}, state), do: {:cont, state}

  # One piece of the body, after the content decoding. The worker waits for
  # credit when the process of the request has too many bytes.
  defp worker_send(piece) do
    {owner, ref} = Process.get(@owner_key)
    send(owner, {ref, :data, piece})
    keep_piece(Process.get(@kept_key), piece)
    inflight = Process.get(@inflight_key) + byte_size(piece)
    Process.put(@inflight_key, await_credit(ref, inflight))
    :cont
  end

  # The worker keeps the pieces of a body up to the limit of the queue: a
  # body that is larger goes to the process of the request.
  defp keep_piece({pieces, size}, piece) when size + byte_size(piece) <= @held_high_water_mark do
    Process.put(@kept_key, {[piece | pieces], size + byte_size(piece)})
  end

  defp keep_piece(_kept, _piece), do: Process.put(@kept_key, :none)

  defp await_credit(ref, inflight) when inflight >= @held_high_water_mark do
    receive do
      {^ref, :ack, bytes} -> await_credit(ref, inflight - bytes)
    end
  end

  defp await_credit(_ref, inflight), do: inflight

  # The kind of the response: a body, no body, a redirect to follow, or a
  # redirect that the redirect mode refuses.
  defp response_phase(%{status: status, redirect: redirect}, location)
       when status in @redirect_statuses and is_binary(location) and redirect == "error",
       do: :redirect_error

  defp response_phase(%{status: status, redirect: redirect}, location)
       when status in @redirect_statuses and is_binary(location) and redirect == "follow",
       do: :discard

  defp response_phase(%{status: status, method: method}, _location)
       when method == "HEAD" or status in @null_body_statuses,
       do: :null

  defp response_phase(_state, _location), do: :body

  defp redirect_mode(request), do: request.options[:redirect] || request.redirect || "follow"

  # The worker remembers its last state for a failure of the callback: see
  # `run_worker/2`.
  defp remember(state) do
    Process.put(__MODULE__, state)
    state
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
  defp release_request_body(%Web.Request{body: %Web.ReadableStream{controller_pid: pid}})
       when is_pid(pid) do
    Web.Stream.terminate_and_wait(pid, :cancel, :request_complete)
  end

  # A body with no process holds nothing.
  defp release_request_body(%Web.Request{body: %Web.ReadableStream{} = body}) do
    _promise = ReadableStream.cancel(body, :request_complete)
    :ok
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
      Headers.__has_lower__(headers, "accept-encoding") ->
        headers

      Headers.__has_lower__(headers, "range") ->
        Headers.__set_lower__(headers, "accept-encoding", "identity")

      true ->
        Headers.__set_lower__(headers, "accept-encoding", ContentDecoder.accept_encoding())
    end
  end
end
