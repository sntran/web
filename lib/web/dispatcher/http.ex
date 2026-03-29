defmodule Web.Dispatcher.HTTP do
  @moduledoc "HTTP dispatcher using Mint in passive mode to support zero-buffer streaming."
  @behaviour Web.Dispatcher

  @max_redirects 20
  @redirect_statuses [301, 302, 303, 307, 308]

  @impl true
  @doc """
  Initiates an HTTP fetch, returning a streamable response body.

  ## Parameters
    - `request`: A `Web.Request` struct.

  ## Returns
    - `{:ok, Web.Response.t()}` on success.
    - `{:error, reason}` on failure.
  """
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
        do_fetch_with_signal(request, redirect_count, signal_subscription)

      # coveralls-ignore-start
      {:error, :aborted} ->
        {:error, :aborted}
        # coveralls-ignore-stop
    end
  end

  defp do_fetch_with_signal(request, redirect_count, signal_subscription) do
    scheme =
      request.url
      |> Web.URL.protocol()
      |> String.trim_trailing(":")
      |> case do
        "" -> "http"
        value -> value
      end
      |> String.to_atom()

    host = Web.URL.hostname(request.url)

    port =
      case Web.URL.port(request.url) do
        "" -> if(scheme == :https, do: 443, else: 80)
        value -> String.to_integer(value)
      end

    opts =
      case scheme do
        :https -> [transport_opts: [verify: :verify_none], mode: :passive]
        _ -> [mode: :passive]
      end

    case Mint.HTTP.connect(scheme, host, port, opts) do
      {:ok, conn} ->
        headers = request.headers |> Web.Headers.to_list()
        path = build_request_path(request.url)

        case Mint.HTTP.request(conn, request.method, path, headers, request.body) do
          {:ok, conn, request_ref} ->
            case receive_headers(conn, request_ref, signal_subscription) do
              {:ok, conn, status, resp_headers, data_chunks, done?} ->
                Web.AbortSignal.unsubscribe(signal_subscription)

                stream =
                  Stream.resource(
                    fn ->
                      build_stream_state(conn, request_ref, done?, data_chunks, request.signal)
                    end,
                    &receive_body_chunk/1,
                    &cleanup_stream/1
                  )

                {:ok,
                 Web.Response.new(
                   status: status,
                   headers: resp_headers,
                   body: stream,
                   url: Web.URL.href(request.url)
                 )}
                |> handle_redirect(request, redirect_count)

              {:error, :aborted} ->
                {:error, :aborted}

              {:error, _conn, reason, _responses} ->
                Web.AbortSignal.unsubscribe(signal_subscription)
                {:error, reason}
            end

          {:error, _conn, reason} ->
            Web.AbortSignal.unsubscribe(signal_subscription)
            # coveralls-ignore-start
            {:error, reason}
            # coveralls-ignore-stop
        end

      {:error, reason} ->
        Web.AbortSignal.unsubscribe(signal_subscription)
        {:error, reason}
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

  defp build_request_path(url) do
    path = Web.URL.pathname(url)
    search = Web.URL.search(url)

    cond do
      search == "" and path == "" -> "/"
      search == "" -> path
      path == "" -> "/" <> search
      true -> path <> search
    end
  end

  defp close_body(body_stream) do
    Enum.reduce_while(body_stream, :ok, fn _, acc -> {:halt, acc} end)
    :ok
  end

  # Internal recursive helper to drain the socket until status + headers are captured.
  defp receive_headers(conn, ref, signal_subscription, status \\ nil, headers \\ []) do
    case recv(conn, signal_subscription) do
      {:ok, next_conn, responses} ->
        {new_status, new_headers, data_chunks, done?} =
          Enum.reduce(responses, {status, headers, [], false}, fn
            {:status, ^ref, code}, {_, h, d, done} ->
              {code, h, d, done}

            {:headers, ^ref, hs}, {s, h, d, done} ->
              {s, h ++ hs, d, done}

            {:data, ^ref, chunk}, {s, h, d, done} ->
              {s, h, d ++ [chunk], done}

            {:done, ^ref}, {s, h, d, _} ->
              {s, h, d, true}

            # coveralls-ignore-start
            _, acc ->
              acc
              # coveralls-ignore-stop
          end)

        if new_status && new_headers != [] do
          {:ok, next_conn, new_status, new_headers, data_chunks, done?}
        else
          receive_headers(next_conn, ref, signal_subscription, new_status, new_headers)
        end

      {:error, next_conn, :aborted, _responses} ->
        Mint.HTTP.close(next_conn)
        Web.AbortSignal.unsubscribe(signal_subscription)
        {:error, :aborted}

      {:error, next_conn, reason, responses} ->
        case Web.AbortSignal.receive_abort(signal_subscription, 0) do
          # coveralls-ignore-start
          {:error, :aborted} ->
            Mint.HTTP.close(next_conn)
            Web.AbortSignal.unsubscribe(signal_subscription)
            {:error, :aborted}

          # coveralls-ignore-stop

          :ok ->
            Web.AbortSignal.unsubscribe(signal_subscription)
            {:error, next_conn, reason, responses}
        end
    end
  end

  # Stream generator logic. It yields chunks from the data buffer first, 
  # then performs fresh Mint.HTTP.recv calls until :done is seen.
  defp build_stream_state(conn, request_ref, done?, data_chunks, signal) do
    case Web.AbortSignal.subscribe(signal) do
      {:ok, signal_subscription} ->
        {conn, request_ref, if(done?, do: :done, else: :streaming), data_chunks,
         signal_subscription}

      # coveralls-ignore-start
      {:error, :aborted} ->
        {conn, request_ref, :aborted, [], nil}
        # coveralls-ignore-stop
    end
  end

  defp receive_body_chunk({conn, ref, :aborted, [], signal_subscription}) do
    {:halt, {conn, ref, :aborted, [], signal_subscription}}
  end

  defp receive_body_chunk({conn, ref, state, [chunk | rest], signal_subscription}) do
    {[chunk], {conn, ref, state, rest, signal_subscription}}
  end

  defp receive_body_chunk({conn, ref, :done, [], signal_subscription}) do
    {:halt, {conn, ref, :done, [], signal_subscription}}
  end

  defp receive_body_chunk({conn, ref, :streaming, [], signal_subscription}) do
    case recv(conn, signal_subscription) do
      {:ok, next_conn, responses} ->
        chunks =
          Enum.flat_map(responses, fn
            {:data, ^ref, chunk} ->
              [chunk]

            # coveralls-ignore-start
            _ ->
              []
              # coveralls-ignore-stop
          end)

        done? =
          Enum.any?(responses, fn
            # coveralls-ignore-start
            {:done, ^ref} -> true
            # coveralls-ignore-stop
            _ -> false
          end)

        state = if done?, do: :done, else: :streaming

        # coveralls-ignore-start
        if chunks == [] and not done? do
          receive_body_chunk({next_conn, ref, :streaming, [], signal_subscription})
        else
          {chunks, {next_conn, ref, state, [], signal_subscription}}
        end

      # coveralls-ignore-stop

      {:error, next_conn, _reason, _responses} ->
        {:halt, {next_conn, ref, :error, [], signal_subscription}}
    end
  end

  defp cleanup_stream({conn, _, _, _, signal_subscription}) do
    Web.AbortSignal.unsubscribe(signal_subscription)
    Mint.HTTP.close(conn)
  end

  defp recv(conn, signal_subscription) do
    case Web.AbortSignal.receive_abort(signal_subscription, 0) do
      {:error, :aborted} ->
        {:error, conn, :aborted, []}

      :ok ->
        case Mint.HTTP.recv(conn, 0, 50) do
          {:ok, next_conn, responses} ->
            {:ok, next_conn, responses}

          {:error, next_conn, %Mint.TransportError{reason: :timeout}, _responses} ->
            case Web.AbortSignal.receive_abort(signal_subscription, 0) do
              {:error, :aborted} -> {:error, next_conn, :aborted, []}
              :ok -> recv(next_conn, signal_subscription)
            end

          {:error, next_conn, reason, responses} ->
            case Web.AbortSignal.receive_abort(signal_subscription, 0) do
              {:error, :aborted} -> {:error, next_conn, :aborted, responses}
              :ok -> {:error, next_conn, reason, responses}
            end
        end
    end
  end
end
