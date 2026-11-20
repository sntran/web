defmodule Web.Body do
  @moduledoc """
  Shared body-consumption helpers for Web API structs.

  `use Web.Body` injects convenience functions:

  - `text/1` reads the body as a binary.
  - `json/1` reads the body as text and parses it as JSON, as the Fetch
    Standard specifies, with the JSON decoder of Erlang/OTP.
  - `array_buffer/1` reads the body as `%Web.ArrayBuffer{}`.
  - `bytes/1` reads the body as `%Web.Uint8Array{}`.
  - `blob/1` reads the body as `%Web.Blob{}`.
  - `clone/1` tees the body stream and returns updated original plus clone.

  It also provides shared `Content-Type` inference used by `Web.Request.new/2` and
  `Web.Response.new/1` when the caller does not supply that header:

  - `%Web.URLSearchParams{}` defaults to `application/x-www-form-urlencoded;charset=UTF-8`
  - plain string/binary bodies default to `text/plain;charset=UTF-8`
  - `%Web.Blob{}` uses the blob's non-empty `type`

  The injected functions respect the stream's `[[disturbed]]` slot. Once a body has
  been consumed, subsequent calls reject with `Web.TypeError.exception("body already used")`.

  ## Examples

      iex> response = Web.Response.new(body: "hello")
      iex> Web.await(Web.Response.text(response))
      "hello"

      iex> response = Web.Response.new(body: ~s({"ok":true}))
      iex> Web.await(Web.Response.json(response))
      %{"ok" => true}

      iex> response = Web.Response.new(body: "hello")
      iex> %Web.ArrayBuffer{byte_length: 5} = Web.await(Web.Response.array_buffer(response))

      iex> request = Web.Request.new("https://example.com", method: "POST", body: "payload")
      iex> array_buffer = Web.await(Web.Request.array_buffer(request))
      iex> {array_buffer.byte_length, array_buffer.data}
      {7, "payload"}

      iex> response = Web.Response.new(body: "hello")
      iex> {response, clone} = Web.Response.clone(response)
      iex> Web.await(Web.Response.text(response))
      "hello"
      iex> Web.await(Web.Response.text(clone))
      "hello"
  """

  alias Web.FormData.Encoder
  alias Web.Internal.Bytes
  alias Web.Internal.JSON, as: JSONText
  alias Web.Internal.LazyStream

  @callback text(struct()) :: Web.Promise.t()
  @callback json(struct()) :: Web.Promise.t()
  @callback form_data(struct()) :: Web.Promise.t()
  @callback array_buffer(struct()) :: Web.Promise.t()
  @callback bytes(struct()) :: Web.Promise.t()
  @callback blob(struct()) :: Web.Promise.t()
  @callback clone(struct()) :: {struct(), struct()}
  defmacro __using__(_opts) do
    quote do
      @behaviour Web.Body

      @doc """
      Reads the body to completion and resolves with its UTF-8 text payload.
      """
      @impl Web.Body
      def text(%{body: _} = struct) do
        Web.Body.text(struct)
      end

      @doc """
      Reads the body to completion, decodes it as UTF-8 text, and resolves
      with the value of the JSON text, as `JSON.parse` of ECMAScript does.

      An object becomes a map with string keys, and `null` becomes `nil`.
      Text that is not JSON rejects with `Web.SyntaxError`.
      """
      @impl Web.Body
      def json(%{body: _} = struct) do
        Web.Body.json(struct)
      end

      @doc """
      Reads the body and resolves with `%Web.FormData{}`.
      """
      @impl Web.Body
      def form_data(%{body: _} = struct) do
        Web.Body.form_data(struct)
      end

      @doc """
      Reads the body to completion and resolves with a `Web.ArrayBuffer`.
      """
      @impl Web.Body
      def array_buffer(%{body: _} = struct) do
        Web.Body.array_buffer(struct)
      end

      @doc """
      Reads the body to completion and resolves with a `Web.Uint8Array`.
      """
      @impl Web.Body
      def bytes(%{body: _} = struct) do
        Web.Body.bytes(struct)
      end

      @doc """
      Reads the body to completion and resolves with a `Web.Blob`.

      Uses the `content-type` header as the Blob MIME type.
      """
      @impl Web.Body
      def blob(%{body: _} = struct) do
        Web.Body.blob(struct)
      end

      @doc """
      Clones the struct body by teeing the underlying readable stream.

      Returns `{updated_original, clone}` where both have independent streams.
      Raises `Web.TypeError` if the body is already disturbed or locked.
      """
      @impl Web.Body
      def clone(%{body: _} = struct) do
        Web.Body.clone(struct)
      end

      @doc """
      Returns `true` if a process read from the body, as the attribute
      `bodyUsed`. A request or a response with no body gives `false`.
      """
      @spec body_used?(struct()) :: boolean()
      def body_used?(%{body: _} = struct) do
        Web.Body.body_used?(struct)
      end
    end
  end

  @doc false
  # Makes the body stream of a request or a response from the body that the
  # caller gave. The chunks of the stream are `Web.Uint8Array` values, as
  # the Fetch Standard specifies. A stream from the caller stays as it is.
  @spec stream(term()) :: Web.ReadableStream.t()
  def stream(%Web.ReadableStream{} = stream), do: stream
  def stream(body) when is_binary(body), do: Web.ReadableStream.__bytes__(body)

  def stream(%struct{} = body)
      when struct in [Web.Blob, Web.ArrayBuffer, Web.Uint8Array, Web.URLSearchParams] do
    Web.ReadableStream.from(body)
  end

  # A form is encoded as `multipart/form-data`, as the Fetch Standard
  # specifies. The header `content-type` has the boundary of the form: see
  # `put_inferred_content_type/2`.
  def stream(%Web.FormData{} = form), do: form |> Encoder.encode() |> stream()

  # Each binary that an enumerable gives becomes a `Web.Uint8Array`.
  def stream(body) do
    if Enumerable.impl_for(body) do
      body |> Stream.map(&Bytes.chunk/1) |> Web.ReadableStream.from()
    else
      Web.ReadableStream.from(body)
    end
  end

  @doc false
  def text(%{body: body}) do
    case take_now(body) do
      {:ok, binary} ->
        Web.Promise.resolve(Web.TextDecoder.decode_utf8(binary))

      {:error, reason} ->
        Web.Promise.reject(reason)

      :later ->
        Web.Promise.new(fn resolve, reject ->
          ensure_usable_stream!(body)
          settle_with(read_body_to_text(body), resolve, reject)
        end)
    end
  end

  defp settle_with({:ok, value}, resolve, _reject), do: resolve.(value)
  defp settle_with({:error, reason}, _resolve, reject), do: reject.(reason)

  @doc false
  # The algorithm "parse JSON from bytes" of the Fetch Standard: the UTF-8
  # decode of the bytes, then `JSON.parse`.
  def json(%{body: body}) do
    consume_body(body, fn bytes -> bytes |> Web.TextDecoder.decode_utf8() |> parse_json() end)
  end

  # Text that is not JSON gives `SyntaxError`, as `JSON.parse` of ECMAScript.
  # The parse runs in the process of the promise, which stops after it.
  defp parse_json(text) do
    case JSONText.parse(text, reserve_heap: true) do
      {:ok, value} ->
        {:ok, value}

      {:error, error} ->
        {:error,
         Web.SyntaxError.exception(
           message: "The body is not valid JSON: #{Exception.message(error)}",
           cause: error
         )}
    end
  end

  @doc false
  def form_data(%{body: body} = struct) do
    owner = self()
    explicit_signal = Map.get(struct, :signal)
    struct_snapshot = Map.get(struct, :snapshot)
    # Derive the signal: explicit field takes priority, then creation-time ambient.
    signal = explicit_signal || (struct_snapshot && struct_snapshot.ambient_signal)

    Web.Promise.new(fn resolve, reject ->
      try do
        ensure_usable!(body)
        Web.AbortSignal.check!(signal)

        case parse_form_data(body, content_type(struct), signal, struct_snapshot, owner) do
          {:ok, form_data} -> resolve.(form_data)
          {:error, reason} -> reject.(reason)
        end
      catch
        :throw, {:abort, reason} -> reject.(reason)
      end
    end)
  end

  @doc false
  def array_buffer(%{body: body}) do
    consume_body(body, &Web.ArrayBuffer.new/1)
  end

  @doc false
  def bytes(%{body: body}) do
    consume_body(body, fn binary ->
      binary
      |> Web.ArrayBuffer.new()
      |> Web.Uint8Array.new()
    end)
  end

  @doc false
  def blob(%{body: body} = struct) do
    consume_body(body, fn binary ->
      Web.Blob.new([binary], type: content_type(struct))
    end)
  end

  @doc false
  def clone(%{body: nil} = struct), do: {struct, struct}

  def clone(%{body: body} = struct) do
    ensure_usable!(body)
    [branch_a, branch_b] = Web.ReadableStream.tee(body)
    {%{struct | body: branch_a}, %{struct | body: branch_b}}
  end

  @doc false
  # The body is used when it is not `nil` and a process read from it.
  def body_used?(%{body: nil}), do: false
  def body_used?(%{body: body}), do: Web.ReadableStream.disturbed?(body)

  defp consume_body(body, mapper) do
    case take_now(body) do
      {:ok, binary} ->
        handle_consumed_body(mapper.(binary), &Web.Promise.resolve/1, &Web.Promise.reject/1)

      {:error, reason} ->
        Web.Promise.reject(reason)

      :later ->
        Web.Promise.new(fn resolve, reject ->
          ensure_usable_stream!(body)
          consume_read(read_body_to_binary(body), mapper, resolve, reject)
        end)
    end
  end

  defp consume_read({:ok, binary}, mapper, resolve, reject),
    do: handle_consumed_body(mapper.(binary), resolve, reject)

  defp consume_read({:error, reason}, _mapper, _resolve, reject), do: reject.(reason)

  defp handle_consumed_body({:ok, value}, resolve, _reject), do: resolve.(value)
  defp handle_consumed_body({:error, reason}, _resolve, reject), do: reject.(reason)
  defp handle_consumed_body(value, resolve, _reject), do: resolve.(value)

  # A body of bytes with no process gives its bytes with no wait: the body
  # function runs in the calling process, and its promise is settled. Thus
  # a read of a small body starts no process. A large body goes to the
  # process of a promise, because its function, such as a JSON parse, needs
  # a large heap for some time.
  @now_limit 65_536

  defp take_now(%Web.ReadableStream{controller_pid: nil, lazy: %{source: {kind, binary}} = lazy})
       when kind in [:bytes, :chunk] and byte_size(binary) <= @now_limit do
    case LazyStream.take(lazy) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, reason}
      {:process, _pid} -> :later
      _used_or_locked -> {:error, Web.TypeError.exception("body already used")}
    end
  end

  defp take_now(_body), do: :later

  defp read_body_to_binary(nil), do: {:ok, ""}
  defp read_body_to_binary(body) when is_binary(body), do: {:ok, body}
  defp read_body_to_binary(body) when is_list(body), do: {:ok, IO.iodata_to_binary(body)}

  # The messages for a stream that gives no reader: the stream has a
  # reader, or it stopped after the check of `ensure_usable!/1`.
  @reader_errors %{
    already_locked: "ReadableStream is already locked",
    released: "body already used"
  }

  # A stream with no process gives all its bytes with no process.
  defp read_body_to_binary(%Web.ReadableStream{controller_pid: nil, lazy: lazy}) do
    case LazyStream.take(lazy) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, reason}
      {:process, pid} -> read_body_to_binary(%Web.ReadableStream{controller_pid: pid})
      :locked -> {:error, Web.TypeError.exception(@reader_errors.already_locked)}
      :used -> {:error, Web.TypeError.exception(@reader_errors.released)}
    end
  end

  defp read_body_to_binary(%Web.ReadableStream{controller_pid: pid}) do
    case Web.ReadableStream.get_reader(pid) do
      :ok -> read_stream_chunks(pid, [])
      {:error, reason} -> {:error, Web.TypeError.exception(Map.fetch!(@reader_errors, reason))}
    end
  end

  # A read from an errored stream rejects with the error of the stream, as
  # the Streams Standard specifies. A stream that stopped in the middle of a
  # read gives a `TypeError`, as each failure of a body in the Fetch
  # Standard.
  defp stream_error({:errored, reason}), do: reason

  defp stream_error(reason) do
    Web.TypeError.exception(message: "The body stream stopped.", cause: reason)
  end

  # The body reads the chunks in batches of 64 at most: it reads all of
  # them, thus the source can work ahead.
  defp read_stream_chunks(pid, acc) do
    case Web.ReadableStream.read_batch(pid, self(), 64) do
      {:chunks, chunks} -> add_chunks(pid, chunks, acc)
      {:ok, chunk} -> add_chunks(pid, [chunk], acc)
      :done -> finish_chunks(pid, :done, acc)
      {:error, _reason} = error -> finish_chunks(pid, error, acc)
    end
  end

  defp add_chunks(pid, [], acc), do: read_stream_chunks(pid, acc)

  defp add_chunks(pid, [chunk | chunks], acc) do
    case Bytes.to_binary(chunk) do
      {:ok, binary} ->
        add_chunks(pid, chunks, [binary | acc])

      :error ->
        Web.ReadableStream.release_lock(pid)
        {:error, chunk_error()}
    end
  end

  defp finish_chunks(pid, :done, acc) do
    Web.ReadableStream.release_lock(pid)
    {:ok, join_chunks(acc)}
  end

  defp finish_chunks(pid, {:error, reason}, _acc) do
    Web.ReadableStream.release_lock(pid)
    {:error, stream_error(reason)}
  end

  # The chunks are in the sequence from the last to the first. A body with
  # one chunk is that chunk, with no copy.
  defp join_chunks([]), do: ""
  defp join_chunks([chunk]), do: chunk
  defp join_chunks(chunks), do: chunks |> :lists.reverse() |> IO.iodata_to_binary()

  # The text of a body is the UTF-8 decode of its bytes, with no byte order
  # mark, as the Fetch Standard specifies.
  defp read_body_to_text(body) do
    with {:ok, binary} <- read_body_to_binary(body) do
      {:ok, Web.TextDecoder.decode_utf8(binary)}
    end
  end

  defp chunk_error do
    Web.TypeError.exception("Body stream chunk must be binary, Uint8Array, or iodata")
  end

  @doc false
  def put_inferred_content_type(%Web.Headers{} = headers, body) do
    case infer_content_type(body) do
      nil ->
        headers

      inferred ->
        if Web.Headers.__has_lower__(headers, "content-type"),
          do: headers,
          else: Web.Headers.__set_lower__(headers, "content-type", inferred)
    end
  end

  # A stream with no process gives its own errors at the read: the change
  # of its state and the check are one operation.
  defp ensure_usable_stream!(%Web.ReadableStream{controller_pid: nil}), do: :ok
  defp ensure_usable_stream!(body), do: ensure_usable!(body)

  defp ensure_usable!(body) do
    if Web.ReadableStream.disturbed?(body) do
      raise Web.TypeError, "body already used"
    end
  end

  defp infer_content_type(%Web.URLSearchParams{}),
    do: "application/x-www-form-urlencoded;charset=UTF-8"

  defp infer_content_type(%Web.FormData{} = form_data), do: Web.FormData.content_type(form_data)

  defp infer_content_type(%Web.Blob{type: type}) when type != "", do: type
  defp infer_content_type(body) when is_binary(body), do: "text/plain;charset=UTF-8"
  defp infer_content_type(_body), do: nil

  defp parse_form_data(body, content_type, signal, struct_snapshot, owner) do
    cond do
      String.starts_with?(String.downcase(content_type), "multipart/form-data") ->
        with {:ok, boundary} <- multipart_boundary(content_type) do
          {:ok,
           Web.FormData.parse(body, boundary,
             signal: signal,
             struct_snapshot: struct_snapshot,
             owner: owner
           )}
        end

      String.starts_with?(String.downcase(content_type), "application/x-www-form-urlencoded") ->
        with {:ok, binary} <- read_body_to_binary(body) do
          {:ok, parse_urlencoded_form_data(binary)}
        end

      true ->
        {:error,
         Web.TypeError.exception(
           "Cannot parse form data from content-type #{inspect(content_type)}"
         )}
    end
  rescue
    e in Web.TypeError -> {:error, e}
  end

  # The parser of `application/x-www-form-urlencoded` reads all the bytes: a
  # "?" at the start is a part of the first name. Only the constructor of
  # `URLSearchParams` removes it.
  defp parse_urlencoded_form_data(binary) do
    params = Web.URLSearchParams.__parse__(binary)

    Enum.reduce(Web.URLSearchParams.to_list(params), Web.FormData.new(), fn {name, value}, form ->
      Web.FormData.append(form, name, value)
    end)
  end

  defp multipart_boundary(content_type) do
    pattern = ~S/(?:^|;\s*)boundary=(?:"([^"]+)"|([^;]+))/

    case :re.run(content_type, pattern, [{:capture, :all_but_first, :binary}]) do
      {:match, captures} ->
        captures
        |> Enum.find("", &(is_binary(&1) and &1 != ""))
        |> String.trim()
        |> case do
          "" -> {:error, Web.TypeError.exception("multipart/form-data boundary is missing")}
          "\"\"" -> {:error, Web.TypeError.exception("multipart/form-data boundary is missing")}
          boundary -> {:ok, boundary}
        end

      _ ->
        {:error, Web.TypeError.exception("multipart/form-data boundary is missing")}
    end
  end

  # The MIME type comes only from the header `content-type`, as the Fetch
  # Standard specifies. The content of the body has no effect.
  defp content_type(%{headers: %Web.Headers{} = headers}) do
    headers
    |> Web.Headers.get("content-type", "")
    |> Web.MIME.parse()
    |> Kernel.||("")
  end

  defp content_type(_), do: ""
end
