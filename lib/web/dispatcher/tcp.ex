defmodule Web.Dispatcher.TCP do
  @moduledoc """
  The dispatcher of `Web.fetch/2` for a `tcp:` URL, and for an rclone
  remote such as `remote:host:port/path`.

  The request opens a TCP connection to the host and the port of the URL.
  The port 80 is the default. The request body goes to the peer first. The
  response has the status 200, the status text `"Connected"`, and a body
  with the bytes that the peer sends until it closes the connection.

  The response body follows the rules of the body of an HTTP response: it
  reads the socket only when a reader wants data, a cancel or an abort
  closes the connection, and a body that no process reads releases its
  connection after the time of `unread_body_timeout`.
  """

  @behaviour Web.Dispatcher

  # The promise of `fetch` is the process of the request: see
  # `Web.Dispatcher.RequestProcess`. The process owns the socket, and holds
  # the body. See `Web.Dispatcher.TCP.Connection` for the network side.

  alias Web.Dispatcher.RequestProcess
  alias Web.Dispatcher.TCP.Connection

  @impl true
  @spec fetch(Web.Request.t()) :: {:ok, Web.Response.t()} | {:error, any()}
  def fetch(%Web.Request{} = request) do
    case request |> __start__(& &1) |> Web.Promise.wait() do
      {:fulfilled, response} -> {:ok, response}
      {:rejected, reason} -> {:error, reason}
    end
  end

  @doc false
  # Starts the process of a request, and returns its promise. It settles
  # with the response, or with `rejection.(reason)` for a failure.
  @spec __start__(Web.Request.t(), (term() -> term())) :: Web.Promise.t()
  def __start__(%Web.Request{} = request, rejection) when is_function(rejection, 1) do
    RequestProcess.start(request, Connection, rejection, &run/2)
  end

  defp run(request, context) do
    case Connection.start(request) do
      :ok -> await_open(request, context)
      {:error, reason} -> RequestProcess.reject(context, reason)
    end
  end

  # The connection is open, and the request body went to the peer.
  defp await_open(request, context) do
    case RequestProcess.next_event(context, :infinity) do
      :open -> RequestProcess.hold_body(context, request, &response(request, &1))
      {:error, reason} -> RequestProcess.reject(context, reason)
      {:aborted, _reason} -> RequestProcess.abort_request(context)
      {:owner_down, _reason} -> RequestProcess.stop_request(context)
      _promise_network_or_other_message -> await_open(request, context)
    end
  end

  defp response(request, body) do
    Web.Response.__network__(
      status: 200,
      status_text: "Connected",
      body: body,
      url: Web.URL.href(request.url)
    )
  end
end
