defmodule Web do
  @moduledoc """
  A Universal Fetch Library for Elixir.

  Matches the Javascript Fetch API standard with zero-buffer streaming and an extensible dispatcher architecture.

  ## Examples

      # Simple HTTP GET
      {:ok, response} = Web.fetch("https://api.github.com/zen")
      response.body |> Enum.each(&IO.write/1)

      # Using a Web.Request struct
      req = Web.Request.new("https://example.com")
      {:ok, response} = Web.fetch(req)
  """

  @doc """
  Initiates a network fetch.

  Matches the Javascript Fetch API standard.

  ## Parameters
    - `input`: A string representing the URL, OR a pre-constructed `Web.Request` struct.
    - `init`: A keyword list of options (ignored if `input` is already a Request struct).
      - `:method` (String.t | atom) - HTTP method (default: "GET").
      - `:headers` (Map.t | List.t | Web.Headers.t) - Request headers.
      - `:body` (any) - Request payload.
      - `:dispatcher` (module) - Optional override for the request handler.

  ## Returns
    - `{:ok, Web.Response.t()}` on success.
    - `{:error, any()}` on failure.

  ## Examples

      iex> {:error, _} = Web.fetch("http://localhost_nxdomain")
      iex> is_tuple(Web.fetch("http://localhost_nxdomain"))
      true

      iex> req = Web.Request.new("http://localhost_nxdomain")
      iex> {:error, _} = Web.fetch(req)
  """
  @spec fetch(String.t() | Web.Request.t(), keyword()) :: {:ok, Web.Response.t()} | {:error, any()}
  def fetch(input, init \\ [])
  
  def fetch(%Web.Request{} = request, _init) do
    do_fetch(request)
  end

  def fetch(input, init) when is_binary(input) do
    request = Web.Request.new(input, init)
    do_fetch(request)
  end

  defp do_fetch(request) do
    dispatcher = 
      request.dispatcher || 
      Web.Resolver.resolve(request.url)

    dispatcher.fetch(request)
  end
end
