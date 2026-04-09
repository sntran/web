defmodule Web.Dispatcher.HTTP do
  @moduledoc "HTTP dispatcher using Finch with zero-buffer streaming."
  @behaviour Web.Dispatcher

  @max_redirects 20
  @redirect_statuses [301, 302, 303, 307, 308]
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

  defp do_fetch(_request, redirect_count) when redirect_count > @max_redirects do
    {:error, :too_many_redirects}
  end

  defp do_fetch(%Web.Request{} = request, redirect_count) do
    {request, request_body_for_fetch} = prepare_request_body(request)

    case Web.AbortSignal.subscribe(request.signal) do
      {:ok, signal_subscription} ->
        case build_finch_request(request, request_body_for_fetch) do
          {:ok, finch_request} ->
            {bridge_pid, bridge_ref, bridge_monitor} = start_stream_bridge(finch_request)

            case await_response_head(bridge_pid, bridge_ref, bridge_monitor, signal_subscription) do
              {:ok, status, headers} ->
                Web.AbortSignal.unsubscribe(signal_subscription)
                Process.demonitor(bridge_monitor, [:flush])

                stream =
                  Stream.resource(
                    fn -> build_stream_state(bridge_pid, bridge_ref, request.signal) end,
                    &receive_body_chunk/1,
                    &cleanup_stream/1
                  )

                {:ok,
                 Web.Response.new(
                   status: status,
                   status_text: Map.get(@status_texts, status, ""),
                   headers: headers,
                   body: stream,
                   url: Web.URL.href(request.url)
                 )}
                |> handle_redirect(request, redirect_count)

              {:error, reason} ->
                Web.AbortSignal.unsubscribe(signal_subscription)
                Process.demonitor(bridge_monitor, [:flush])
                cancel_bridge(bridge_pid, bridge_ref)
                {:error, reason}
            end

          {:error, reason} ->
            Web.AbortSignal.unsubscribe(signal_subscription)
            {:error, reason}
        end

      {:error, :aborted} ->
        {:error, :aborted}
    end
  end

  defp handle_redirect({:ok, response} = result, request, redirect_count) do
    redirect_mode = request.options[:redirect] || request.redirect || "follow"
    is_redirect = response.status in @redirect_statuses

    cond do
      is_redirect and redirect_mode == "error" ->
        close_body(response.body)
        {:error, :redirect_error}

      is_redirect and redirect_mode == "manual" ->
        result

      is_redirect and redirect_mode == "follow" ->
        case Web.Headers.get(response.headers, "location") do
          nil ->
            result

          location ->
            close_body(response.body)

            next_url =
              request.url
              |> Web.URL.href()
              |> URI.parse()
              |> URI.merge(location)
              |> URI.to_string()

            next_request = next_redirect_request(request, response.status, next_url)

            do_fetch(next_request, redirect_count + 1)
        end

      true ->
        result
    end
  end

  defp next_redirect_request(request, 303, next_url) do
    Web.Request.new(
      next_url,
      request.options
      |> Keyword.put(:method, "GET")
      |> Keyword.put(:headers, Web.Headers.delete(request.headers, "content-length"))
      |> Keyword.put(:body, nil)
      |> Keyword.put(:dispatcher, request.dispatcher)
    )
  end

  defp next_redirect_request(request, status, next_url) when status in [307, 308] do
    Web.Request.new(
      next_url,
      request.options
      |> Keyword.put(:method, request.method)
      |> Keyword.put(:headers, request.headers)
      |> Keyword.put(:body, request.body)
      |> Keyword.put(:dispatcher, request.dispatcher)
    )
  end

  defp next_redirect_request(request, _status, next_url) do
    Web.Request.new(
      next_url,
      request.options
      |> Keyword.put(:method, request.method)
      |> Keyword.put(:headers, request.headers)
      |> Keyword.put(:body, request.body)
      |> Keyword.put(:dispatcher, request.dispatcher)
    )
  end

  defp close_body(body_stream) do
    Enum.reduce_while(body_stream, :ok, fn _, acc -> {:halt, acc} end)
    :ok
  end

  defp build_finch_request(request, body) do
    normalized_body =
      case normalize_body(body || request.body) do
        {:ok, value} -> value
        value -> value
      end

    {:ok,
     Finch.build(
       request.method,
       Web.URL.href(request.url),
       Web.Headers.to_list(request.headers),
       normalized_body
     )}
  rescue
    error -> {:error, error}
  end

  defp prepare_request_body(
         %Web.Request{body: %Web.ReadableStream{} = body, redirect: "follow"} = request
       ) do
    if not Web.ReadableStream.disturbed?(body) and not Web.ReadableStream.locked?(body) do
      binary = body |> Enum.to_list() |> IO.iodata_to_binary()
      {%{request | body: binary}, binary}
    else
      {request, body}
    end
  end

  defp prepare_request_body(%Web.Request{} = request) do
    {request, request.body}
  end

  defp normalize_body(nil), do: nil
  defp normalize_body(body) when is_binary(body) or is_list(body), do: body

  defp normalize_body(%Web.ReadableStream{} = body) do
    {:ok, body |> Enum.to_list() |> IO.iodata_to_binary()}
  end

  defp normalize_body(body) do
    if Enumerable.impl_for(body) do
      {:stream, body}
    else
      body
    end
  end

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

        if state.waiting_consumer do
          send(state.waiting_consumer, {:bridge_error, ref, reason})
        else
          send(state.owner, {:bridge_failed, ref, reason})
        end

        bridge_loop(%{state | waiting_consumer: nil})

      {:bridge_next, ref, consumer} when ref == state.ref and not is_nil(state.pending_chunk) ->
        {worker_pid, chunk} = state.pending_chunk
        send(consumer, {:bridge_chunk, ref, chunk})
        send(worker_pid, {:bridge_ack, ref})
        bridge_loop(%{state | pending_chunk: nil})

      # coveralls-ignore-start
      {:bridge_next, ref, consumer} when ref == state.ref and state.terminal == :done ->
        send(consumer, {:bridge_done, ref})
        bridge_loop(state)

      # coveralls-ignore-stop

      {:bridge_next, ref, consumer} when ref == state.ref ->
        case state.terminal do
          # coveralls-ignore-start
          {:error, reason} ->
            send(consumer, {:bridge_error, ref, reason})
            bridge_loop(state)

          # coveralls-ignore-stop

          _ ->
            bridge_loop(%{state | waiting_consumer: consumer})
        end

      {:bridge_cancel, ref} when ref == state.ref ->
        if state.worker_pid && Process.alive?(state.worker_pid) do
          Process.exit(state.worker_pid, :kill)
        end

        :ok

      {:DOWN, monitor_ref, :process, worker_pid, reason}
      when monitor_ref == state.worker_monitor and worker_pid == state.worker_pid ->
        unless reason in [:normal, :killed] or match?({:shutdown, _}, reason) do
          send(state.owner, {:bridge_failed, state.ref, reason})
        end

        :ok
    end
  end

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
        receive_timeout: :infinity,
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
    case Web.AbortSignal.subscribe(signal) do
      {:ok, signal_subscription} ->
        %{
          bridge_pid: bridge_pid,
          bridge_ref: bridge_ref,
          bridge_monitor: Process.monitor(bridge_pid),
          signal_subscription: signal_subscription
        }

      {:error, :aborted} ->
        cancel_bridge(bridge_pid, bridge_ref)

        %{
          bridge_pid: bridge_pid,
          bridge_ref: bridge_ref,
          bridge_monitor: Process.monitor(bridge_pid),
          signal_subscription: nil,
          aborted?: true
        }
    end
  end

  defp receive_body_chunk(state) do
    if Map.get(state, :aborted?, false) do
      {:halt, state}
    else
      case Web.AbortSignal.receive_abort(state.signal_subscription, 0) do
        {:error, :aborted} ->
          # coveralls-ignore-next-line
          abort_and_halt(state)

        :ok ->
          send(state.bridge_pid, {:bridge_next, state.bridge_ref, self()})
          await_body_chunk(state)
      end
    end
  end

  defp await_body_chunk(state) do
    receive do
      {:bridge_chunk, ref, chunk} when ref == state.bridge_ref ->
        {[chunk], state}

      {:bridge_done, ref} when ref == state.bridge_ref ->
        {:halt, state}

      {:bridge_error, ref, _reason} when ref == state.bridge_ref ->
        {:halt, state}

      {:DOWN, monitor_ref, :process, pid, _reason}
      when monitor_ref == state.bridge_monitor and pid == state.bridge_pid ->
        {:halt, state}
    after
      50 ->
        case Web.AbortSignal.receive_abort(state.signal_subscription, 0) do
          {:error, :aborted} ->
            abort_and_halt(state)

          :ok ->
            # coveralls-ignore-next-line
            await_body_chunk(state)
        end
    end
  end

  defp abort_and_halt(state) do
    cancel_bridge(state.bridge_pid, state.bridge_ref)
    {:halt, Map.put(state, :aborted?, true)}
  end

  defp cleanup_stream(state) do
    Web.AbortSignal.unsubscribe(state.signal_subscription)
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
