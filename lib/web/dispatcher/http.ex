defmodule Web.Dispatcher.HTTP do
  @moduledoc "HTTP dispatcher using Mint in passive mode to support zero-buffer streaming."
  @behaviour Web.Dispatcher

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
    uri = URI.parse(request.url)
    scheme = String.to_atom(uri.scheme || "http")
    host = uri.host || ""
    port = uri.port || if scheme == :https, do: 443, else: 80

    # Note: verify_none is used for HTTPS by default in this implementation
    # to maintain "universal" simplicity, but should be strictly hardened
    # for production use if SSL peer verification is required.
    opts = case scheme do
      :https -> [transport_opts: [verify: :verify_none], mode: :passive]
      _ -> [mode: :passive]
    end

    case Mint.HTTP.connect(scheme, host, port, opts) do
      {:ok, conn} ->
        headers = request.headers |> Web.Headers.to_list()
        path = if uri.query, do: "#{uri.path}?#{uri.query}", else: uri.path || "/"

        case Mint.HTTP.request(conn, request.method, path, headers, request.body) do
          {:ok, conn, request_ref} ->
            # Step 1: Wait synchronously for the status and headers before returning
            # to the user, as the Web standard expects status codes to be available
            # upon the resolution of the fetch promise.
            case receive_headers(conn, request_ref) do
              {:ok, conn, status, resp_headers, data_chunks, done?} ->
                
                # Step 2: Use Stream.resource to lazily pull the remainder of the 
                # payload without buffering the entire body into memory.
                stream = Stream.resource(
                  fn -> {conn, request_ref, if(done?, do: :done, else: :streaming), data_chunks} end,
                  &receive_body_chunk/1,
                  fn {c, _, _, _} -> Mint.HTTP.close(c) end
                )

                {:ok, Web.Response.new(
                  status: status,
                  headers: resp_headers,
                  body: stream,
                  url: request.url
                )}

              {:error, _conn, reason, _responses} ->
                {:error, reason}
            end

          {:error, _conn, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Internal recursive helper to drain the socket until status + headers are captured.
  defp receive_headers(conn, ref, status \\ nil, headers \\ []) do
    case Mint.HTTP.recv(conn, 0, 5000) do
      {:ok, next_conn, responses} ->
        {new_status, new_headers, data_chunks, done?} =
          Enum.reduce(responses, {status, headers, [], false}, fn
            {:status, ^ref, code}, {_, h, d, done} -> {code, h, d, done}
            {:headers, ^ref, hs}, {s, h, d, done} -> {s, h ++ hs, d, done}
            {:data, ^ref, chunk}, {s, h, d, done} -> {s, h, d ++ [chunk], done}
            {:done, ^ref}, {s, h, d, _} -> {s, h, d, true}
            # coveralls-ignore-start
            _, acc -> acc
            # coveralls-ignore-stop
          end)

        if new_status && new_headers != [] do
          {:ok, next_conn, new_status, new_headers, data_chunks, done?}
        else
          # coveralls-ignore-start
          receive_headers(next_conn, ref, new_status, new_headers)
          # coveralls-ignore-stop
        end

      {:error, next_conn, reason, responses} ->
        {:error, next_conn, reason, responses}
    end
  end

  # Stream generator logic. It yields chunks from the data buffer first, 
  # then performs fresh Mint.HTTP.recv calls until :done is seen.
  defp receive_body_chunk({conn, ref, state, [chunk | rest]}) do
    {[chunk], {conn, ref, state, rest}}
  end
  defp receive_body_chunk({conn, ref, :done, []}) do
    {:halt, {conn, ref, :done, []}}
  end
  defp receive_body_chunk({conn, ref, :streaming, []}) do
    case Mint.HTTP.recv(conn, 0, 5000) do
      {:ok, next_conn, responses} ->
        chunks = Enum.flat_map(responses, fn
          {:data, ^ref, chunk} -> [chunk]
          _ -> []
        end)

        done? = Enum.any?(responses, fn
          {:done, ^ref} -> true
          _ -> false
        end)

        state = if done?, do: :done, else: :streaming

        # coveralls-ignore-start
        if chunks == [] and not done? do
          receive_body_chunk({next_conn, ref, :streaming, []})
        else
          {chunks, {next_conn, ref, state, []}}
        end
        # coveralls-ignore-stop

      {:error, next_conn, _reason, _responses} ->
        {:halt, {next_conn, ref, :error, []}}
    end
  end
  # coveralls-ignore-start
  defp receive_body_chunk(state), do: {:halt, state}
  # coveralls-ignore-stop
end
