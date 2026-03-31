defmodule Web do
  @moduledoc """
  A Universal Fetch Library for Elixir.

  This module provides a Web-compliant Fetch API for Elixir, matching the WHATWG Fetch standard.
  It supports zero-buffer streaming, abort signals, and an extensible dispatcher architecture.

  ## The "Web-First" DSL

  The `Web` module provides a `__using__` macro that imports common functions and aliases:

  ```elixir
  use Web

  # Now you can use:
  # fetch/1, fetch/2, await/1
  # URL.new, Request.new, Response.new, AbortController.new, etc.
  ```

  ## Examples

      # Simple HTTP GET
      {:ok, response} = Web.fetch("https://api.github.com/zen")
      response.body |> Enum.each(&IO.write/1)

      # Using await macro
      response = await Web.fetch("https://api.github.com/zen")
      response.body |> Enum.each(&IO.write/1)
  """

  defmacro __using__(_opts) do
    quote do
      import Web, only: [fetch: 1, fetch: 2, await: 1]
      import Web.DSL, only: [new: 2]

      alias Web.URL
      alias Web.URLSearchParams
      alias Web.Headers
      alias Web.Request
      alias Web.Response
      alias Web.AbortController
      alias Web.AbortSignal
      alias Web.ReadableStream
      alias Web.ReadableStreamDefaultController

      :ok
    end
  end

  @doc """
  Awaits a result in the form of `{:ok, value}` or raises on error.

  ## Examples

      iex> Web.await({:ok, "success"})
      "success"

      iex> Web.await({:error, :not_found})
      ** (RuntimeError) await: fetch failed: :not_found
  """
  defmacro await(expr) do
    quote do
      case unquote(expr) do
        {:ok, value} -> value
        {:error, reason} -> raise "await: fetch failed: #{inspect(reason)}"
        other -> raise "await: unexpected result: #{inspect(other)}"
      end
    end
  end

  @doc """
  Initiates a network fetch.

  Matches the Javascript Fetch API standard.

  ## Parameters
    - `input`: A string representing the URL, OR a pre-constructed `Web.Request` struct.
    - `init`: A keyword list of options (ignored if `input` is already a Request struct).
      - `:method` (String.t | atom) - HTTP method (default: "GET").
      - `:headers` (Map.t | List.t | Web.Headers.t) - Request headers.
      - `:body` (any) - Request payload.
      - `:redirect` (`"follow" | "error" | "manual"`) - Redirect handling mode.
      - `:signal` (`Web.AbortSignal.t()` | pid | reference) - Optional abort signal.
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
  @spec fetch(String.t() | Web.URL.t() | Web.Request.t(), keyword()) ::
          {:ok, Web.Response.t()} | {:error, any()}
  def fetch(input, init \\ [])

  def fetch(%Web.Request{} = request, _init) do
    do_fetch(request)
  catch
    :throw, {:abort, :aborted} -> {:error, :aborted}
  end

  def fetch(%Web.URL{} = input, init) do
    request = Web.Request.new(input, init)
    do_fetch(request)
  catch
    :throw, {:abort, :aborted} -> {:error, :aborted}
  end

  def fetch(input, init) when is_binary(input) do
    request = Web.Request.new(input, init)
    do_fetch(request)
  catch
    :throw, {:abort, :aborted} -> {:error, :aborted}
  end

  defp do_fetch(request) do
    Web.AbortSignal.check!(request.signal)

    dispatcher =
      request.dispatcher ||
        Web.Resolver.resolve(request.url)

    dispatcher.fetch(request)
  end
end
