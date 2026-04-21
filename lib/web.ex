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

  alias Web.Internal.StructuredData
  alias Web.TypeError

  defmacro __using__(_opts) do
    quote do
      import Web,
        only: [
          connect: 1,
          connect: 2,
          fetch: 1,
          fetch: 2,
          await: 1,
          using: 2,
          atob: 1,
          btoa: 1,
          structured_clone: 1,
          structured_clone: 2
        ]

      import Web.DSL, only: [new: 2]

      alias Web.AbortableGovernor
      alias Web.AbortController
      alias Web.AbortSignal
      alias Web.ArrayBuffer
      alias Web.AsyncContext
      alias Web.Blob
      alias Web.BroadcastChannel
      alias Web.CompressionStream
      alias Web.Console
      alias Web.CountingGovernor
      alias Web.CustomEvent
      alias Web.DecompressionStream
      alias Web.DOMException
      alias Web.EventTarget
      alias Web.File
      alias Web.FormData
      alias Web.Governor
      alias Web.Headers
      alias Web.MessageChannel
      alias Web.MessageEvent
      alias Web.MessagePort
      alias Web.Performance
      alias Web.Promise
      alias Web.ReadableStream
      alias Web.ReadableStreamDefaultController
      alias Web.Request
      alias Web.Response
      alias Web.Socket
      alias Web.Symbol
      alias Web.TextDecoder
      alias Web.TextDecoderStream
      alias Web.TextEncoder
      alias Web.TextEncoderStream
      alias Web.TransformStream
      alias Web.TypeError
      alias Web.Uint8Array
      alias Web.URL
      alias Web.URLSearchParams
      alias Web.WritableStream
      alias Web.WritableStreamDefaultController
      alias Web.WritableStreamDefaultWriter

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
  Runs a block with a disposable resource and guarantees `:dispose` runs after.

  Supports `using resource <- expression do ... end`,
  `using resource = expression do ... end`, and `using expression do ... end`.
  """
  defmacro using(binding, do: block) do
    build_using(binding, block, __CALLER__)
  end

  @doc """
  Decodes a Base64 string using forgiving Base64 semantics.
  """
  @spec atob(String.t()) :: String.t()
  def atob(string) when is_binary(string) do
    with {:ok, normalized} <- normalize_base64(string),
         {:ok, decoded} <- Base.decode64(normalized) do
      decoded
      |> :binary.bin_to_list()
      |> List.to_string()
    else
      :error ->
        raise TypeError.exception("Failed to execute atob: malformed base64 input")

      {:error, :invalid} ->
        raise TypeError.exception("Failed to execute atob: malformed base64 input")
    end
  end

  @doc """
  Encodes a byte string into Base64.
  """
  @spec btoa(String.t()) :: String.t()
  def btoa(string) when is_binary(string) do
    string
    |> byte_string_to_binary!()
    |> Base.encode64()
  end

  @doc """
  Returns a structured clone of `value`.

  ## Examples

      iex> clone = Web.structured_clone(%{"items" => [1, 2, 3]})
      iex> clone
      %{"items" => [1, 2, 3]}
  """
  @spec structured_clone(term(), keyword()) :: term()
  def structured_clone(value, options \\ []) do
    StructuredData.clone(value, options)
  end

  @doc """
  Opens a capability-gated TCP or TLS socket.
  """
  @spec connect(String.t() | map() | keyword(), map() | keyword()) :: Web.Socket.t()
  def connect(address, options \\ %{}) do
    Web.Socket.start_socket(self(), address, options)
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
    Web.AbortSignal.check!(request.signal)
    fetch_request(request)
  catch
    :throw, {:abort, reason} ->
      Web.Promise.reject(reason)
  end

  def fetch(%Web.URL{} = input, init) do
    fetch(Web.Request.new(input, init))
  end

  def fetch(input, init) when is_binary(input) do
    fetch(Web.Request.new(input, init))
  end

  defp fetch_request(request) do
    Web.Promise.new(fn resolve, reject ->
      try do
        case do_fetch_with_signal(request) do
          {:ok, response} -> resolve.(response)
          {:error, reason} -> reject.(reason)
        end
      catch
        # coveralls-ignore-next-line
        :throw, {:abort, reason} -> reject.(reason)
      end
    end)
  end

  defp do_fetch_with_signal(%Web.Request{signal: %Web.AbortSignal{} = signal} = request) do
    Web.AsyncContext.with_signal(signal, fn ->
      do_fetch(request)
    end)
  end

  defp do_fetch_with_signal(%Web.Request{} = request) do
    do_fetch(request)
  end

  defp do_fetch(request) do
    Web.AbortSignal.check!(request.signal)

    dispatcher =
      request.dispatcher ||
        Web.Resolver.resolve(request.url)

    dispatcher.fetch(request)
  end

  defp build_using({operator, _meta, [pattern, resource]}, block, caller)
       when operator in [:<-, :=] do
    resource_var = Macro.unique_var(:using_resource, caller.module || __MODULE__)

    quote do
      unquote(resource_var) = unquote(resource)
      unquote(pattern) = unquote(resource_var)

      try do
        unquote(block)
      after
        Web.Symbol.Protocol.symbol(unquote(resource_var), Web.Symbol.dispose(), [])
      end
    end
  end

  defp build_using(resource, block, caller) do
    resource_var = Macro.unique_var(:using_resource, caller.module || __MODULE__)

    quote do
      unquote(resource_var) = unquote(resource)

      try do
        unquote(block)
      after
        Web.Symbol.Protocol.symbol(unquote(resource_var), Web.Symbol.dispose(), [])
      end
    end
  end

  defp byte_string_to_binary!(string) do
    string
    |> String.to_charlist()
    |> Enum.reduce([], fn
      codepoint, acc when codepoint in 0..255 ->
        [codepoint | acc]

      _codepoint, _acc ->
        raise TypeError.exception(
                "Failed to execute btoa: input contains characters outside the Latin1 range"
              )
    end)
    |> Enum.reverse()
    |> :erlang.list_to_binary()
  end

  defp normalize_base64(string) do
    trimmed = String.replace(string, ~r/[\t\n\f\r ]+/, "")

    cond do
      trimmed == "" ->
        {:ok, ""}

      Regex.match?(~r/[^A-Za-z0-9+\/=]/, trimmed) ->
        {:error, :invalid}

      Regex.match?(~r/=.+[^=]/, trimmed) ->
        {:error, :invalid}

      true ->
        stripped = String.trim_trailing(trimmed, "=")
        padding_size = byte_size(trimmed) - byte_size(stripped)

        cond do
          padding_size > 2 ->
            {:error, :invalid}

          rem(byte_size(stripped), 4) == 1 ->
            {:error, :invalid}

          true ->
            required_padding = rem(4 - rem(byte_size(stripped), 4), 4)
            {:ok, stripped <> String.duplicate("=", required_padding)}
        end
    end
  end
end
