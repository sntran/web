defmodule Web.Dispatcher.HTTP do
  @moduledoc "HTTP dispatcher using Finch with zero-buffer streaming."
  @behaviour Web.Dispatcher

  @max_redirects 20
  @redirect_statuses [301, 302, 303, 307, 308]

  @impl true
  @spec fetch(Web.Request.t()) :: {:ok, Web.Response.t()} | {:error, any()}
  def fetch(%Web.Request{} = request) do
    do_fetch(request, 0)
  end

  defp do_fetch(_request, redirect_count) when redirect_count > @max_redirects do
    {:error, :too_many_redirects}
  end

  defp do_fetch(%Web.Request{} = request, redirect_count) do
    case Web.AbortSignal.subscribe(request.signal) do
      {:ok, signal_subscription} ->
        case build_finch_request(request) do
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
    %{
      request
      | url: Web.URL.new(next_url),
        method: "GET",
        body: nil,
        headers: Web.Headers.delete(request.headers, "content-length")
    }
  end

  defp next_redirect_request(request, _status, next_url) do
    %{request | url: Web.URL.new(next_url)}
  end

  defp close_body(body_stream) do
    Enum.reduce_while(body_stream, :ok, fn _, acc -> {:halt, acc} end)
    :ok
  end

  defp build_finch_request(request) do
    {:ok,
     Finch.build(
       request.method,
       Web.URL.href(request.url),
       Web.Headers.to_list(request.headers),
       normalize_body(request.body)
     )}
  rescue
    error -> {:error, error}
  end

  defp normalize_body(nil), do: nil
  defp normalize_body(body) when is_binary(body) or is_list(body), do: body

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

      {:bridge_next, ref, consumer} when ref == state.ref and state.terminal == :done ->
        send(consumer, {:bridge_done, ref})
        bridge_loop(state)

      {:bridge_next, ref, consumer} when ref == state.ref ->
        case state.terminal do
          {:error, reason} ->
            send(consumer, {:bridge_error, ref, reason})
            bridge_loop(state)

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

              {:bridge_cancel, ^ref} ->
                exit(:normal)
            end

          {:trailers, _trailers}, acc ->
            acc
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
          cancel_bridge(state.bridge_pid, state.bridge_ref)
          {:halt, Map.put(state, :aborted?, true)}

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
            cancel_bridge(state.bridge_pid, state.bridge_ref)
            {:halt, Map.put(state, :aborted?, true)}

          :ok ->
            await_body_chunk(state)
        end
    end
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
