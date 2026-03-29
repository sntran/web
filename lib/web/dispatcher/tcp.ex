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
    url = request.url

    # Normalization: handle both scheme-style (tcp://) and remote-style (myserver:port) URIs.
    cleaned = if String.contains?(url, "://") do
      Regex.replace(~r/^[a-zA-Z]+:\/\//, url, "")
    else
      Regex.replace(~r/^[a-zA-Z0-9_-]+:/, url, "")
    end

    parts = String.split(cleaned, "/", parts: 2) |> List.first() |> String.split(":")
    
    host = Enum.at(parts, 0, "localhost") |> String.to_charlist()
    port = case Enum.at(parts, 1) do
      nil -> 80
      val -> String.to_integer(val)
    end

    # We use active: false for the initial handshake/send to keep state simple.
    opts = [:binary, active: false, packet: :raw]
    case :gen_tcp.connect(host, port, opts, 5000) do
      {:ok, socket} ->
        if request.body do
          :gen_tcp.send(socket, request.body)
        end

        # Transferring control into the Stream resource.
        # This function only executes when the user starts iterating the body.
        stream = Stream.resource(
          fn -> socket end,
          fn s ->
            # The 'no-buffer' rule: we only ask for one chunk at a time.
            :ok = :inet.setopts(s, active: :once)
            receive do
              {:tcp, ^s, data} ->
                {[data], s}
              {:tcp_closed, ^s} ->
                {:halt, s}
              # coveralls-ignore-start
              {:tcp_error, ^s, _reason} ->
                {:halt, s}
            after
              5000 ->
                {:halt, s}
              # coveralls-ignore-stop
            end
          end,
          fn s -> :gen_tcp.close(s) end
        )

        {:ok, Web.Response.new(
          status: 200, # Treat base TCP connection as HTTP 200 / success
          body: stream,
          url: request.url
        )}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
