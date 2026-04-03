defmodule Web.Dispatcher.TCP do
  @moduledoc """
  TCP dispatcher implementing the no-buffer streaming rule using `active: once`.
  Ensures backpressure for large resources. Easily extendable by future NNTP logic.
  """
  @behaviour Web.Dispatcher

  @impl true
  @doc """
  Connects to a TCP raw socket and returns a response containing a lazy-pulling body stream.

  The stream manages the socket state internally via `active: once`, ensuring that bytes
  are only pulled as fast as the consumer processes them.

  ## Parameters
    - `request`: A `Web.Request` struct containing the target URL and optional body.

  ## Returns
    - `{:ok, Web.Response.t()}` with a streamable body.
    - `{:error, reason}` if the connection fails.
  """
  @spec fetch(Web.Request.t()) :: {:ok, Web.Response.t()} | {:error, any()}
  def fetch(%Web.Request{} = request) do
    do_fetch(request)
  end

  defp do_fetch(%Web.Request{} = request) do
    {host, port} = connection_target(request.url)

    opts = [:binary, active: false, packet: :raw]

    case :gen_tcp.connect(host, port, opts, 5000) do
      {:ok, socket} ->
        if request.body do
          case Web.ReadableStream.read_all(request.body) do
            {:ok, body} -> :gen_tcp.send(socket, body)
            {:error, reason} -> raise reason
          end
        end

        stream =
          Stream.resource(
            fn -> build_stream_state(socket, request.signal) end,
            &receive_chunk/1,
            &cleanup_stream/1
          )

        {:ok,
         Web.Response.new(
           status: 200,
           status_text: "Connected",
           body: stream,
           url: Web.URL.href(request.url)
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_stream_state(socket, signal) do
    case Web.AbortSignal.subscribe(signal) do
      {:ok, signal_subscription} -> {socket, signal_subscription}
      {:error, :aborted} -> {:aborted, socket}
    end
  end

  defp receive_chunk({:aborted, socket}) do
    {:halt, {:aborted, socket}}
  end

  defp receive_chunk({socket, signal_subscription}) do
    case recv(socket, signal_subscription) do
      {:ok, data} ->
        {[data], {socket, signal_subscription}}

      {:error, :aborted} ->
        {:halt, {socket, signal_subscription}}

      {:error, :closed} ->
        {:halt, {socket, signal_subscription}}

      # coveralls-ignore-start
      {:error, _reason} ->
        {:halt, {socket, signal_subscription}}
        # coveralls-ignore-stop
    end
  end

  defp recv(socket, signal_subscription) do
    case Web.AbortSignal.receive_abort(signal_subscription, 0) do
      # coveralls-ignore-start
      {:error, :aborted} ->
        {:error, :aborted}

      # coveralls-ignore-stop

      :ok ->
        case :gen_tcp.recv(socket, 0, 50) do
          {:ok, data} ->
            {:ok, data}

          {:error, :timeout} ->
            case Web.AbortSignal.receive_abort(signal_subscription, 0) do
              {:error, :aborted} -> {:error, :aborted}
              :ok -> recv(socket, signal_subscription)
            end

          {:error, :closed} ->
            {:error, :closed}

          # coveralls-ignore-start
          {:error, reason} ->
            {:error, reason}
            # coveralls-ignore-stop
        end
    end
  end

  defp cleanup_stream({:aborted, socket}) do
    :gen_tcp.close(socket)
  end

  defp cleanup_stream({socket, signal_subscription}) do
    Web.AbortSignal.unsubscribe(signal_subscription)
    :gen_tcp.close(socket)
  end

  defp connection_target(url) do
    if Web.URL.rclone?(url) do
      authority =
        url
        |> Web.URL.pathname()
        |> String.split("/", parts: 2)
        |> List.first()

      parts = String.split(authority, ":", parts: 2)

      host = Enum.at(parts, 0, "localhost") |> String.to_charlist()

      port =
        case Enum.at(parts, 1) do
          nil -> 80
          value -> String.to_integer(value)
        end

      {host, port}
    else
      host = Web.URL.hostname(url) |> String.to_charlist()

      port =
        case Web.URL.port(url) do
          "" -> 80
          value -> String.to_integer(value)
        end

      {host, port}
    end
  end
end
