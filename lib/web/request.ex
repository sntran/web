defmodule Web.Request do
  @moduledoc """
  An implementation of the WHATWG Request standard.

  Represents an HTTP request, including URL, method, headers, and body.
  Compatible with standard Web API concepts.
  """
  use Web.Body

  alias Web.AsyncContext

  defstruct [
    :url,
    :method,
    :body,
    :dispatcher,
    :redirect,
    :signal,
    :snapshot,
    :options,
    headers: Web.Headers.new()
  ]

  @type t :: %__MODULE__{
          url: Web.URL.t(),
          method: String.t(),
          headers: Web.Headers.t(),
          body: any(),
          dispatcher: module() | nil,
          redirect: String.t(),
          signal: Web.AbortSignal.t() | pid() | reference() | nil,
          snapshot: AsyncContext.Snapshot.t() | nil,
          options: keyword()
        }

  @doc """
  Initializes a new Web.Request struct.

  Accepts either an existing `Web.Request` or a URL string with optional `init` keyword options.

  ## Examples
      iex> req = Web.Request.new("http://example.com")
      iex> Web.Request.new(req, []) == req
      true

      iex> controller = Web.AbortController.new()
      iex> req = Web.Request.new("http://example.com", redirect: :manual, signal: controller.signal)
      iex> {req.redirect, match?(%Web.AbortSignal{}, req.signal)}
      {"manual", true}
      iex> Web.AbortController.abort(controller)
      :ok
  """
  def new(%__MODULE__{} = request, _init), do: request

  def new(%Web.URL{} = input, init) when is_list(init) do
    build_request(input, init)
  end

  def new(input, init) when is_binary(input) and is_list(init) do
    input
    |> build_request_url()
    |> build_request(init)
  end

  def new(input, _init) do
    raise Web.TypeError,
          "Request input must be a Web.URL struct or URL string, got: #{inspect(input)}"
  end

  @doc """
  Initializes a new Web.Request struct.

  Supports URL strings.
  """
  def new(input) do
    new(input, [])
  end

  defp build_request_url(input) do
    Web.URL.new(input)
  rescue
    ArgumentError ->
      input
      |> fallback_request_target()
      |> Web.URL.new()
  end

  defp fallback_request_target(input) do
    candidate =
      if String.starts_with?(input, ["/", "?", "#"]) do
        "http://localhost" <> input
      else
        "http://" <> input
      end

    try do
      Web.URL.new(candidate)
      candidate
    rescue
      ArgumentError -> "http://localhost/"
    end
  end

  defp build_request(url, init) do
    method = Keyword.get(init, :method, "GET") |> to_string() |> String.upcase()
    raw_body = Keyword.get(init, :body)

    headers =
      Keyword.get(init, :headers, %{})
      |> Web.Headers.new()
      |> Web.Body.put_inferred_content_type(raw_body)

    body = Web.ReadableStream.from(raw_body)
    dispatcher = Keyword.get(init, :dispatcher)
    redirect = Keyword.get(init, :redirect, "follow") |> to_string()

    snapshot = AsyncContext.Snapshot.take()
    signal = Keyword.get(init, :signal) || snapshot.ambient_signal

    options =
      init
      |> Keyword.drop([:method, :headers, :body, :dispatcher])
      |> Keyword.put(:redirect, redirect)
      |> Keyword.put(:signal, signal)

    %__MODULE__{
      url: url,
      method: method,
      headers: headers,
      body: body,
      dispatcher: dispatcher,
      redirect: redirect,
      signal: signal,
      snapshot: snapshot,
      options: options
    }
  end
end
