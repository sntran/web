# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule Web.Dispatcher.HTTP do
  @moduledoc "HTTP dispatcher using Finch with zero-buffer streaming."
  @behaviour Web.Dispatcher

  alias Web.Internal.Bytes

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
      {bridge_pid, bridge_ref, bridge_monitor} = start_stream_bridge(finch_request)
      head = await_response_head(bridge_pid, bridge_ref, bridge_monitor, signal_subscription)
      Process.demonitor(bridge_monitor, [:flush])

      case head do
        {:ok, status, headers} ->
          stream =
            Stream.resource(
              fn -> build_stream_state(bridge_pid, bridge_ref, request.signal) end,
              &receive_body_chunk/1,
              &cleanup_stream/1
            )

          {:ok,
           with_request_signal(request.signal, fn ->
             Web.Response.__network__(
               status: status,
               status_text: Map.get(@status_texts, status, ""),
               headers: headers,
               body: response_body(stream, request.method, status),
               url: Web.URL.href(request.url),
               redirected: redirect_count > 0
             )
           end)}

        {:error, reason} ->
          cancel_bridge(bridge_pid, bridge_ref)
          {:error, reason}
      end
    end
  end

  # A body that no process reads holds its connection. Thus the body stream
  # has a time limit for the start of the read.
  @null_body_statuses [101, 103, 204, 205, 304]

  # The response of a HEAD request, and a response with a status that permits
  # no body, have the body `nil`, as the Fetch Standard specifies. The
  # function reads the response to its end, thus the connection is released.
  defp response_body(stream, method, status)
       when method == "HEAD" or status in @null_body_statuses do
    Stream.run(stream)
    nil
  end

  defp response_body(stream, _method, _status) do
    # Each chunk of the body is a `Web.Uint8Array`, as the Fetch Standard
    # specifies.
    stream
    |> Stream.map(&Web.Uint8Array.from/1)
    |> Web.ReadableStream.from_enumerable(unread_timeout: Web.Application.unread_body_timeout())
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
       Web.URL.href(request.url),
       Web.Headers.to_list(request.headers),
       request_body(request)
     )}
  rescue
    error -> {:error, error}
  end

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

  defp start_stream_bridge(finch_request) do
    bridge_ref = make_ref()
    owner = self()

    bridge_pid =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        bridge_loop(%{
          owner: owner,
          ref: bridge_ref,
          request: finch_request,
          worker_pid: nil,
          worker_monitor: nil,
          status: nil,
          headers: [],
          headers_received?: false,
          ready_sent?: false,
          waiting_consumer: nil,
          consumer_monitor: nil,
          pending_chunk: nil,
          terminal: nil
        })
      end)

    {bridge_pid, bridge_ref, Process.monitor(bridge_pid)}
  end

  defp bridge_loop(%{worker_pid: nil, request: request} = state) do
    bridge_pid = self()
    worker_pid = spawn(fn -> bridge_worker(bridge_pid, state.ref, request) end)
    bridge_loop(%{state | worker_pid: worker_pid, worker_monitor: Process.monitor(worker_pid)})
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp bridge_loop(state) do
    receive do
      {:bridge_status, ref, status} when ref == state.ref ->
        state
        |> Map.put(:status, status)
        |> maybe_send_ready()
        |> bridge_loop()

      {:bridge_headers, ref, headers} when ref == state.ref and not state.headers_received? ->
        state
        |> Map.put(:headers, headers)
        |> Map.put(:headers_received?, true)
        |> maybe_send_ready()
        |> bridge_loop()

      {:bridge_headers, ref, _trailers} when ref == state.ref ->
        # coveralls-ignore-next-line
        bridge_loop(state)

      {:bridge_data, ref, chunk, worker_pid}
      when ref == state.ref and is_nil(state.waiting_consumer) ->
        bridge_loop(%{state | pending_chunk: {worker_pid, chunk}})

      {:bridge_data, ref, chunk, worker_pid} when ref == state.ref ->
        send(state.waiting_consumer, {:bridge_chunk, ref, chunk})
        send(worker_pid, {:bridge_ack, ref})
        bridge_loop(%{state | waiting_consumer: nil})

      {:bridge_done, ref} when ref == state.ref ->
        state = %{state | terminal: :done}

        if state.waiting_consumer do
          send(state.waiting_consumer, {:bridge_done, ref})
        end

        bridge_loop(%{state | waiting_consumer: nil})

      {:bridge_error, ref, reason} when ref == state.ref ->
        state = %{state | terminal: {:error, reason}}

        cond do
          state.waiting_consumer ->
            send(state.waiting_consumer, {:bridge_error, ref, reason})

          not state.ready_sent? ->
            send(state.owner, {:bridge_failed, ref, reason})

          # The reader gets the error with its subsequent request.
          true ->
            :ok
        end

        bridge_loop(%{state | waiting_consumer: nil})

      {:bridge_next, ref, consumer} when ref == state.ref ->
        state |> monitor_consumer(consumer) |> answer_consumer(consumer) |> bridge_loop()

      {:bridge_cancel, ref} when ref == state.ref ->
        stop_worker(state)

      # The process that reads the body stopped and did not cancel.
      {:DOWN, monitor_ref, :process, _consumer, _reason}
      when monitor_ref == state.consumer_monitor ->
        stop_worker(state)

      # The worker stopped. The bridge stays, because the reader must get the
      # result of the request: the end of the body, or the error.
      {:DOWN, monitor_ref, :process, worker_pid, reason}
      when monitor_ref == state.worker_monitor and worker_pid == state.worker_pid ->
        state |> worker_stopped(reason) |> bridge_loop()
    end
  end

  defp monitor_consumer(%{consumer_monitor: nil} = state, consumer) do
    %{state | consumer_monitor: Process.monitor(consumer)}
  end

  defp monitor_consumer(state, _consumer), do: state

  defp answer_consumer(%{pending_chunk: {worker_pid, chunk}} = state, consumer) do
    send(consumer, {:bridge_chunk, state.ref, chunk})
    send(worker_pid, {:bridge_ack, state.ref})
    %{state | pending_chunk: nil}
  end

  defp answer_consumer(%{terminal: :done} = state, consumer) do
    send(consumer, {:bridge_done, state.ref})
    state
  end

  defp answer_consumer(%{terminal: {:error, reason}} = state, consumer) do
    send(consumer, {:bridge_error, state.ref, reason})
    state
  end

  defp answer_consumer(state, consumer), do: %{state | waiting_consumer: consumer}

  defp stop_worker(state) do
    if state.worker_pid && Process.alive?(state.worker_pid) do
      Process.exit(state.worker_pid, :kill)
    end

    :ok
  end

  # A worker that stopped before it gave the end of the body is an error.
  defp worker_stopped(%{terminal: nil} = state, reason) do
    error = {:connection_process_stopped, reason}

    cond do
      state.waiting_consumer ->
        send(state.waiting_consumer, {:bridge_error, state.ref, error})

      not state.ready_sent? ->
        send(state.owner, {:bridge_failed, state.ref, reason})

      true ->
        :ok
    end

    %{state | terminal: {:error, error}, waiting_consumer: nil}
  end

  defp worker_stopped(state, _reason), do: state

  defp bridge_worker(bridge_pid, ref, finch_request) do
    result =
      Finch.stream(
        finch_request,
        Web.Finch,
        :ok,
        fn
          {:status, status}, acc ->
            send(bridge_pid, {:bridge_status, ref, status})
            acc

          {:headers, headers}, acc ->
            send(bridge_pid, {:bridge_headers, ref, headers})
            acc

          {:data, chunk}, acc ->
            send(bridge_pid, {:bridge_data, ref, chunk, self()})

            receive do
              {:bridge_ack, ^ref} ->
                acc

              # coveralls-ignore-start
              {:bridge_cancel, ^ref} ->
                exit(:normal)
                # coveralls-ignore-stop
            end

          # coveralls-ignore-start
          {:trailers, _trailers}, acc ->
            acc
            # coveralls-ignore-stop
        end,
        # The time to wait for the response headers, and for each subsequent
        # part of the body. It does not include the time that the reader of
        # the body uses, nor the time to send the request body.
        receive_timeout: receive_timeout(),
        # A request waits for a free connection with no limit, as in a
        # browser. The signal of the request stops the wait.
        pool_timeout: :infinity,
        request_timeout: :infinity
      )

    case result do
      {:ok, _acc} ->
        send(bridge_pid, {:bridge_done, ref})

      {:error, reason, _acc} ->
        send(bridge_pid, {:bridge_error, ref, reason})
    end
  end

  # coveralls-ignore-next-line
  defp maybe_send_ready(%{ready_sent?: true} = state), do: state

  defp maybe_send_ready(%{status: status, headers_received?: true} = state)
       when not is_nil(status) do
    send(state.owner, {:bridge_ready, state.ref, status, state.headers})
    %{state | ready_sent?: true}
  end

  defp maybe_send_ready(state), do: state

  defp await_response_head(bridge_pid, bridge_ref, bridge_monitor, signal_subscription) do
    receive do
      {:bridge_ready, ^bridge_ref, status, headers} ->
        {:ok, status, headers}

      {:bridge_failed, ^bridge_ref, reason} ->
        {:error, reason}

      {:DOWN, ^bridge_monitor, :process, ^bridge_pid, reason} ->
        {:error, reason}
    after
      50 ->
        case Web.AbortSignal.receive_abort(signal_subscription, 0) do
          {:error, :aborted} ->
            cancel_bridge(bridge_pid, bridge_ref)
            {:error, :aborted}

          :ok ->
            await_response_head(bridge_pid, bridge_ref, bridge_monitor, signal_subscription)
        end
    end
  end

  defp build_stream_state(bridge_pid, bridge_ref, signal) do
    signal_subscription =
      case Web.AbortSignal.subscribe(signal) do
        {:ok, subscription} -> subscription
        {:error, :aborted} -> :aborted
      end

    %{
      bridge_pid: bridge_pid,
      bridge_ref: bridge_ref,
      bridge_monitor: Process.monitor(bridge_pid),
      signal: signal,
      signal_subscription: signal_subscription
    }
  end

  # A body that does not arrive completely is an error. The function raises,
  # and the body stream goes to the errored state. Thus a reader cannot use a
  # part of a body as the full body.
  defp receive_body_chunk(state) do
    check_abort!(state)
    send(state.bridge_pid, {:bridge_next, state.bridge_ref, self()})
    await_body_chunk(state)
  end

  defp await_body_chunk(state) do
    receive do
      {:bridge_chunk, ref, chunk} when ref == state.bridge_ref ->
        check_abort!(state)
        {[chunk], state}

      {:bridge_done, ref} when ref == state.bridge_ref ->
        {:halt, state}

      {:bridge_error, ref, reason} when ref == state.bridge_ref ->
        raise_body_error(reason)

      {:DOWN, monitor_ref, :process, pid, reason}
      when monitor_ref == state.bridge_monitor and pid == state.bridge_pid ->
        raise_body_error({:connection_process_stopped, reason})
    after
      50 ->
        check_abort!(state)
        await_body_chunk(state)
    end
  end

  defp check_abort!(%{signal_subscription: :aborted} = state), do: raise_abort(state, :aborted)

  defp check_abort!(state) do
    case Web.AbortSignal.receive_abort(state.signal_subscription, 0, true) do
      {:error, :aborted, reason} -> raise_abort(state, reason)
      :ok -> :ok
    end
  end

  defp raise_abort(state, reason) do
    cancel_bridge(state.bridge_pid, state.bridge_ref)

    case reason do
      :aborted -> raise abort_reason(state.signal)
      reason when is_exception(reason) -> raise reason
      reason -> raise Web.DOMException, name: "AbortError", message: inspect(reason)
    end
  end

  defp abort_reason(%Web.AbortSignal{} = signal) do
    Web.AbortSignal.reason(signal) || Web.AbortSignal.default_reason()
  end

  defp abort_reason(_signal), do: Web.AbortSignal.default_reason()

  # A network error in the body is a `TypeError`, as the Fetch Standard
  # specifies.
  defp raise_body_error(reason) do
    raise Web.TypeError, message: "The response body is not complete.", cause: reason
  end

  defp cleanup_stream(state) do
    if is_map(state.signal_subscription) do
      Web.AbortSignal.unsubscribe(state.signal_subscription)
    end

    Process.demonitor(state.bridge_monitor, [:flush])
    cancel_bridge(state.bridge_pid, state.bridge_ref)
  end

  defp cancel_bridge(bridge_pid, bridge_ref) do
    if Process.alive?(bridge_pid) do
      send(bridge_pid, {:bridge_cancel, bridge_ref})
    end

    :ok
  end
end
