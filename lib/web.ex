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

      promise = Web.fetch("https://api.github.com/zen")
      response = Web.await(promise)
      is_struct(response, Web.Response)
      true

      catch_exit(Web.await(Web.Promise.reject(:boom)))
      :boom
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
      alias Web.Promise
      alias Web.ReadableStream
      alias Web.ReadableStreamDefaultController
      alias Web.TransformStream
      alias Web.WritableStream
      alias Web.WritableStreamDefaultController
      alias Web.WritableStreamDefaultWriter
      alias Web.ArrayBuffer
      alias Web.Uint8Array
      alias Web.Blob

      :ok
    end
  end

  @doc """
  Awaits a `Web.Promise` and returns its fulfilled value.

  ## Examples

      iex> Web.await(Web.Promise.resolve("success"))
      "success"

      iex> catch_exit(Web.await(Web.Promise.reject(:not_found)))
      :not_found
  """
  defmacro await(expr) do
    quote do
      case unquote(expr) do
        %Web.Promise{task: task} ->
          try do
            Task.await(task, :infinity)
          catch
            :exit, {{:shutdown, reason}, {Task, :await, _details}} ->
              exit(reason)

            :exit, reason ->
              exit(reason)
          end

        other ->
          raise "await: unexpected result: #{inspect(other)}"
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
    - `%Web.Promise{}` resolving to `Web.Response.t()` on success.
    - The promise rejects with `reason` on failure.

  ## Examples

      iex> promise = Web.fetch("http://localhost_nxdomain")
      iex> is_struct(promise, Web.Promise)
      true

      iex> req = Web.Request.new("http://localhost_nxdomain")
      iex> is_struct(Web.fetch(req), Web.Promise)
      true
  """
  @spec fetch(String.t() | Web.URL.t() | Web.Request.t(), keyword()) ::
          Web.Promise.t()
  def fetch(input, init \\ [])

  def fetch(%Web.Request{} = request, _init) do
    try do
      Web.AbortSignal.check!(request.signal)

      Web.Promise.new(fn resolve, reject ->
        try do
          case do_fetch(request) do
            {:ok, response} -> resolve.(response)
            {:error, reason} -> reject.(reason)
          end
        catch
          # coveralls-ignore-next-line
          :throw, {:abort, reason} -> reject.(reason)
        end
      end)
    catch
      :throw, {:abort, reason} ->
        Web.Promise.reject(reason)
    end
  end

  def fetch(%Web.URL{} = input, init) do
    fetch(Web.Request.new(input, init))
  end

  def fetch(input, init) when is_binary(input) do
    fetch(Web.Request.new(input, init))
  end

  defp do_fetch(request) do
    Web.AbortSignal.check!(request.signal)

    dispatcher =
      request.dispatcher ||
        Web.Resolver.resolve(request.url)

    dispatcher.fetch(request)
  end
end
