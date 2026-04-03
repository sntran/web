defmodule Web.Request do
  @moduledoc """
  An implementation of the WHATWG Request standard.

  Represents an HTTP request, including URL, method, headers, and body.
  Compatible with standard Web API concepts.
  """
  use Web.Body

  defstruct [
    :url,
    :method,
    :body,
    :dispatcher,
    :redirect,
    :signal,
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

  def new(%Web.URL{} = input, init) do
    build_request(input, init)
  end

  def new(input, init) do
    input
    |> Web.URL.new()
    |> build_request(init)
  end

  @doc """
  Initializes a new Web.Request struct.

  Supports URL strings.
  """
  def new(input) do
    new(input, [])
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
    signal = Keyword.get(init, :signal)

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
      options: options
    }
  end
end
