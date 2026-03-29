defmodule Web.Request do
  @moduledoc """
  Represents an HTTP, NNTP, TCP or generic Request object.
  """

  defstruct [
    :url,
    :method,
    :headers,
    :body,
    :dispatcher,
    :options
  ]

  @type t :: %__MODULE__{
          url: String.t(),
          method: String.t(),
          headers: Web.Headers.t(),
          body: any(),
          dispatcher: module() | nil,
          options: keyword()
        }

  @doc """
  Initializes a new Web.Request struct.
  
  Accepts either an existing `Web.Request` or a URL string with optional `init` keyword options.

  ## Examples
      iex> req = Web.Request.new("http://example.com")
      iex> Web.Request.new(req, []) == req
      true
  """
  def new(%__MODULE__{} = request, _init), do: request
  def new(input, init) do
    url = input
    method = Keyword.get(init, :method, "GET") |> to_string() |> String.upcase()
    headers = Web.Headers.new(Keyword.get(init, :headers, %{}))
    body = Keyword.get(init, :body)
    dispatcher = Keyword.get(init, :dispatcher)
    
    options = Keyword.drop(init, [:method, :headers, :body, :dispatcher])

    %__MODULE__{
      url: url,
      method: method,
      headers: headers,
      body: body,
      dispatcher: dispatcher,
      options: options
    }
  end

  @doc """
  Initializes a new Web.Request struct.
  
  Supports URL strings.
  """
  def new(input) do
    new(input, [])
  end
end
