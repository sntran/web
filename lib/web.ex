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

  alias Web.Dispatcher.HTTP
  alias Web.Dispatcher.TCP
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
      alias Web.ByteLengthQueuingStrategy
      alias Web.CompressionStream
      alias Web.Console
      alias Web.CountingGovernor
      alias Web.CountQueuingStrategy
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
      alias Web.ReadableByteStreamController
      alias Web.ReadableStream
      alias Web.ReadableStreamBYOBReader
      alias Web.ReadableStreamBYOBRequest
      alias Web.ReadableStreamDefaultController
      alias Web.ReadableStreamDefaultReader
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
  Waits for a `Web.Promise` and returns its value, as `await` of ECMAScript.

  If the promise rejects, the calling process exits with the reason. See
  `Web.Promise.await/1`. A value that is not a promise is returned with no
  change, as in ECMAScript.

  ## Examples

      iex> Web.await(Web.Promise.resolve("success"))
      "success"

      iex> catch_exit(Web.await(Web.Promise.reject(:not_found)))
      :not_found

      iex> Web.await(:not_a_promise)
      :not_a_promise
  """
  @spec await(term()) :: term()
  def await(%Web.Promise{} = promise), do: Web.Promise.await(promise)
  def await(value), do: value

  @doc """
  Runs a block with a resource, and releases the resource at the end of the
  block, as the `using` declaration of ECMAScript.

  The three forms are:

      using resource <- expression do ... end
      using resource = expression do ... end
      using expression do ... end

  The macro returns the value of the block.

  ## Rules

    * The value of the expression must be disposable, or `nil`. See
      `Web.Symbol` for the disposable values. For each other value, the
      macro raises `Web.TypeError` and does not run the block.
    * A `nil` value has no disposal: the block runs.
    * The resource is released also when the block raises, throws, or
      exits. The value that the block threw is thrown again after the
      disposal.
    * When the disposal fails, its error is raised. When the block failed
      too, the macro raises `Web.SuppressedError` with the two errors.
    * A disposal that returns a `Web.Promise` is awaited.

  For more than one resource, put one `using` in a different one. The
  resources are then released in the opposite sequence.

  ## Examples

      iex> use Web
      iex> channel =
      ...>   using channel <- BroadcastChannel.new("example") do
      ...>     BroadcastChannel.post_message(channel, %{status: "started"})
      ...>     channel
      ...>   end
      iex> BroadcastChannel.post_message(channel, "after the block")
      ** (Web.DOMException) The BroadcastChannel is closed.

      iex> use Web
      iex> using value <- 5 do
      ...>   value
      ...> end
      ** (Web.TypeError) The value is not disposable: 5
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
  Returns a structured clone of `value`, as `structuredClone()` of the HTML
  Standard.

  A `Web.MessagePort` and a `Web.BroadcastChannel` use the same algorithm
  for each message.

  ## The values that can be cloned

  All data can be cloned: numbers, atoms, binaries, lists, tuples, maps, and
  structs that have only data. An Elixir term cannot change, thus the clone
  of such data is the same term.

  A value that has an identity gets a new identity:

    * a `Web.ArrayBuffer` and a `Web.Uint8Array`. A change of the clone,
      such as a detach, does not change the source;
    * a `Web.Blob` and a `Web.File`.

  Two references to one of these values are two references to one new
  value in the clone. A `Regex` is compiled again.

  ## The values that cannot be cloned

  The function raises `Web.DOMException` with the name `DataCloneError` for
  a value that refers to something that runs: a pid, a port, a reference,
  or a function. Thus a stream cannot be cloned. A `Web.Promise`, a
  `Web.AbortSignal`, a `Web.AbortController`, a `Web.Request`, and a
  `Web.Response` cannot be cloned in each of their states. A
  `Web.MessagePort` can only be transferred.

  ## Options

    * `:transfer` - a list of `Web.ArrayBuffer` and `Web.MessagePort`
      values to move, not to copy. The function detaches each one: the
      clone has the bytes of a buffer, and a new handle to a port.

  The function changes nothing when it raises.

  ## Examples

      iex> Web.structured_clone(%{status: :ok, items: [1, 2, {3, "four"}]})
      %{status: :ok, items: [1, 2, {3, "four"}]}

      iex> buffer = Web.ArrayBuffer.new("hello")
      iex> clone = Web.structured_clone(buffer, transfer: [buffer])
      iex> {Web.ArrayBuffer.data(clone), Web.ArrayBuffer.detached?(buffer)}
      {"hello", true}

      iex> Web.structured_clone(self())
      ** (Web.DOMException) A pid cannot be cloned.
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
    - `init`: A keyword list of options. Each option replaces the value of an input request.
      - `:method` (String.t | atom) - HTTP method (default: "GET").
      - `:headers` (Map.t | List.t | Web.Headers.t) - Request headers.
      - `:body` (any) - Request payload.
      - `:redirect` (`"follow" | "error" | "manual"`) - Redirect handling mode.
      - `:signal` (`Web.AbortSignal.t()` | pid | reference) - Optional abort signal.
      - `:dispatcher` (module) - Optional override for the request handler.

  ## Returns
    - `%Web.Promise{}` resolving to `Web.Response.t()` on success.
    - The function does not raise. Each failure is a rejection of the
      promise:
      - `Web.TypeError` for input that `Web.Request.new/2` refuses. The
        function then makes no connection.
      - The reason of the signal, when the signal aborts the request.
      - `Web.TypeError` with the failure in the field `cause`, for each
        network failure.

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
  def fetch(input, init \\ []) do
    request = Web.Request.new(input, init)
    :ok = Web.Request.ensure_body_usable!(request)
    Web.AbortSignal.check!(request.signal)
    fetch_request(request)
  rescue
    # Input that the `Request` constructor refuses gives a rejection, as the
    # Fetch Standard specifies. The function makes no connection.
    error in [TypeError] -> Web.Promise.reject(error)
  catch
    :throw, {:abort, reason} ->
      Web.Promise.reject(reason)
  end

  # The process of an HTTP or TCP request is the promise of `fetch`: see
  # `Web.Dispatcher.RequestProcess`.
  defp fetch_request(%Web.Request{dispatcher: dispatcher} = request)
       when dispatcher in [nil, HTTP, TCP] do
    module = dispatcher || Web.Resolver.resolve(request.url)
    module.__start__(request, &fetch_error(&1, request))
  end

  defp fetch_request(request), do: fetch_with_executor(request)

  defp fetch_with_executor(request) do
    Web.Promise.new(fn resolve, reject ->
      try do
        case do_fetch_with_signal(request) do
          {:ok, response} -> resolve.(response)
          {:error, reason} -> reject.(fetch_error(reason, request))
        end
      catch
        # A dispatcher throws this when the signal aborts the request.
        :throw, {:abort, reason} -> reject.(reason)
      end
    end)
  end

  # The Fetch Standard has two forms of rejection: the abort reason of the
  # signal, and `TypeError` for each other failure. The field `cause` of the
  # `TypeError` has the failure of the dispatcher.
  defp fetch_error(:aborted, %Web.Request{signal: %Web.AbortSignal{} = signal}) do
    Web.AbortSignal.reason(signal) || Web.AbortSignal.default_reason()
  end

  defp fetch_error(:aborted, _request), do: Web.AbortSignal.default_reason()
  defp fetch_error(%Web.DOMException{} = error, _request), do: error
  defp fetch_error(%TypeError{} = error, _request), do: error

  defp fetch_error(reason, _request) do
    TypeError.exception(message: "fetch failed" <> fetch_error_detail(reason), cause: reason)
  end

  defp fetch_error_detail(:redirect_error), do: ": the redirect mode is \"error\""
  defp fetch_error_detail(:too_many_redirects), do: ": too many redirects"

  defp fetch_error_detail(:redirect_stream_body),
    do: ": a redirect cannot send a stream body again"

  defp fetch_error_detail(:redirect_unsupported_scheme),
    do: ": the redirect URL must be HTTP or HTTPS"

  defp fetch_error_detail(:redirect_invalid_location), do: ": the redirect URL is not valid"

  defp fetch_error_detail(%{__exception__: true, reason: :timeout}),
    do: ": the server did not answer in time"

  defp fetch_error_detail(_reason), do: ""

  defp do_fetch_with_signal(%Web.Request{signal: %Web.AbortSignal{} = signal} = request) do
    Web.AsyncContext.with_signal(signal, fn ->
      do_fetch(request)
    end)
  end

  defp do_fetch_with_signal(%Web.Request{} = request) do
    do_fetch(request)
  end

  # A dispatcher that the caller gives in the option `:dispatcher`.
  defp do_fetch(%Web.Request{dispatcher: dispatcher} = request) do
    Web.AbortSignal.check!(request.signal)
    dispatcher.fetch(request)
  end

  defp build_using({operator, _meta, [pattern, resource]}, block, caller)
       when operator in [:<-, :=] do
    using_ast(pattern, resource, block, caller)
  end

  defp build_using(resource, block, caller) do
    using_ast(quote(do: _), resource, block, caller)
  end

  # The match of the pattern is in the function: the resource is released
  # also when the match fails.
  defp using_ast(pattern, resource, block, caller) do
    resource_var = Macro.unique_var(:using_resource, caller.module || __MODULE__)

    quote do
      unquote(resource_var) = unquote(resource)
      :ok = Web.Symbol.check_disposable!(unquote(resource_var))

      Web.Symbol.run_using(unquote(resource_var), fn ->
        unquote(pattern) = unquote(resource_var)
        unquote(block)
      end)
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

  defp base64_text?(<<char, rest::binary>>)
       when char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char in [?+, ?/, ?=],
       do: base64_text?(rest)

  defp base64_text?(<<>>), do: true
  defp base64_text?(_text), do: false

  # A "=", one character or more, and then a character that is not "=".
  defp data_after_padding?(text) do
    case :binary.match(text, "=") do
      :nomatch ->
        false

      {index, 1} ->
        tail_start = index + 2

        tail_start < byte_size(text) and
          binary_part(text, tail_start, byte_size(text) - tail_start) |> String.replace("=", "") !=
            ""
    end
  end

  defp normalize_base64(string) do
    trimmed = :binary.replace(string, ["\t", "\n", "\f", "\r", " "], "", [:global])

    cond do
      trimmed == "" ->
        {:ok, ""}

      not base64_text?(trimmed) ->
        {:error, :invalid}

      data_after_padding?(trimmed) ->
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
