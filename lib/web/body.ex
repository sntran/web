defmodule Web.Body do
  @moduledoc false

  # The body mixin of the Fetch Standard. A mixin has no interface object,
  # thus this module is internal. `use Web.Body` puts the methods of the
  # mixin in `Web.Request` and `Web.Response`: `array_buffer/1`, `blob/1`,
  # `bytes/1`, `form_data/1`, `json/1`, `text/1`, `text_stream/1`, and the
  # attribute `body_used?/1`. It also puts `clone/1` there, which the two
  # classes have.
  #
  # The methods follow the step "consume body" of the Fetch Standard. A body
  # method takes the reader of the body before it returns, and the reader
  # keeps its lock: after `text/1`, the body stream is disturbed and locked,
  # and `Web.ReadableStream.get_reader/1` raises `Web.TypeError`. A second
  # body method rejects with `Web.TypeError.exception("body already used")`.
  #
  # A chunk of a body stream must be bytes: a `Web.Uint8Array`, as the Fetch
  # Standard specifies, or a binary, iodata, or a `Web.ArrayBuffer`. A binary
  # is the usual form of bytes in Elixir. Each other chunk rejects with
  # `Web.TypeError`.
  #
  # The module also infers the header `Content-Type` for the constructors,
  # when the caller does not give that header: the step "extract a body".
  #
  #   * `%Web.URLSearchParams{}` gives
  #     `application/x-www-form-urlencoded;charset=UTF-8`.
  #   * A binary gives `text/plain;charset=UTF-8`.
  #   * `%Web.Blob{}` gives the type of the blob, when it is not empty.
  #   * `%Web.FormData{}` gives `multipart/form-data` with its boundary.

  alias Web.ArrayBuffer
  alias Web.FormData.Encoder
  alias Web.Internal.Bytes
  alias Web.Internal.JSON, as: JSONText
  alias Web.Internal.LazyStream
  alias Web.Uint8Array

  @callback text(struct()) :: Web.Promise.t()
  @callback json(struct()) :: Web.Promise.t()
  @callback form_data(struct()) :: Web.Promise.t()
  @callback array_buffer(struct()) :: Web.Promise.t()
  @callback bytes(struct()) :: Web.Promise.t()
  @callback blob(struct()) :: Web.Promise.t()
  @callback text_stream(struct()) :: Web.ReadableStream.t()
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
      Returns the body as a stream of text, as `textStream()` of the Fetch
      Standard: the body piped through a `Web.TextDecoderStream` for UTF-8.
      Each chunk is a string. The `content-type` header has no effect.

      The body is disturbed and locked when the function returns. A struct
      with no body gives a new stream with no chunks. Raises
      `Web.TypeError` if the body is already disturbed or locked.
      """
      @impl Web.Body
      def text_stream(%{body: _} = struct) do
        Web.Body.text_stream(struct)
      end

      @doc """
      Clones the struct body by teeing the underlying readable stream.

      Returns `{updated_original, clone}` where both have independent streams.
      The clone gets a structured clone of each chunk of a stream, as the
      Fetch Standard specifies. Raises `Web.TypeError` if the body is
      already disturbed or locked.
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
  # caller gave: the step "extract a body" of the Fetch Standard. The chunks
  # of the stream are `Web.Uint8Array` values. A stream from the caller
  # stays as it is. Each other body is a byte stream, thus a BYOB reader can
  # read it.
  @spec stream(term()) :: Web.ReadableStream.t()
  def stream(%Web.ReadableStream{} = stream), do: stream
  def stream(body) when is_binary(body), do: Web.ReadableStream.__bytes__(body)

  # A copy of the bytes of a buffer source, as the Fetch Standard specifies.
  def stream(%Web.ArrayBuffer{} = buffer), do: buffer |> ArrayBuffer.data() |> stream()
  def stream(%Web.Uint8Array{} = view), do: view |> Uint8Array.to_binary() |> stream()
  def stream(%Web.Blob{} = blob), do: blob |> Web.Blob.to_binary() |> stream()

  def stream(%Web.URLSearchParams{} = params),
    do: params |> Web.URLSearchParams.to_string() |> stream()

  # A form is encoded as `multipart/form-data`, as the Fetch Standard
  # specifies. The header `content-type` has the boundary of the form: see
  # `put_inferred_content_type/2`. A form with all its data in memory gives
  # its bytes. A form with a file stream reads the file when a process
  # reads the body. A form with no entries gives the close delimiter, as
  # RFC 7578 and the browsers do.
  def stream(%Web.FormData{} = form) do
    if Web.FormData.static?(form),
      do: form |> Encoder.encode() |> Enum.join() |> stream(),
      else: form |> Encoder.encode() |> stream()
  end

  # Each binary that an enumerable gives becomes a `Web.Uint8Array`.
  def stream(body) do
    if Enumerable.impl_for(body) do
      body |> Stream.map(&Bytes.chunk/1) |> Web.ReadableStream.from()
    else
      Web.ReadableStream.__from__(body)
    end
  end

  @doc false
  # The step "extract a body" of the Fetch Standard for the constructors: a
  # `ReadableStream` that a process read from, or that has a reader, throws
  # a `TypeError`.
  @spec extract!(term()) :: Web.ReadableStream.t()
  def extract!(%Web.ReadableStream{} = body) do
    if Web.ReadableStream.disturbed?(body) or Web.ReadableStream.__locked__(body) do
      raise Web.TypeError, "The body stream is already used or locked"
    end

    body
  end

  def extract!(body), do: stream(body)

  @doc false
  # The step "create a proxy" of the Streams Standard, for the body of a
  # request that a new request takes: the new body has the chunks of the
  # stream, and the stream is disturbed and locked. A stream with its bytes
  # in memory gives a new stream of the same bytes, with no process. Each
  # other stream is piped through an identity transform stream.
  @spec __proxy__(Web.ReadableStream.t()) :: Web.ReadableStream.t()
  def __proxy__(%Web.ReadableStream{controller_pid: nil, lazy: lazy} = stream) do
    case LazyStream.proxy(lazy) do
      {:ok, proxy} -> %Web.ReadableStream{lazy: proxy}
      :locked -> raise Web.TypeError, "ReadableStream is already locked"
      # The pipe takes the lock of the stream process with the lock step of
      # a reader: see `Web.ReadableStream.__lock__/2`.
      _process_readable_used_or_held -> pipe_proxy(stream)
    end
  end

  def __proxy__(%Web.ReadableStream{} = stream), do: pipe_proxy(stream)

  defp pipe_proxy(stream), do: Web.ReadableStream.pipe_through(stream, Web.TransformStream.new())

  @doc false
  def text(%{body: body}), do: consume_body(body, &Web.TextDecoder.decode_utf8/1)

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
  # The steps of `formData()`. A body of the type `multipart/form-data`
  # goes to the parser of `Web.FormData`, which reads the stream. Each
  # other body is read in full first, as "consume body" of the Fetch
  # Standard specifies: thus an error of the stream comes before the
  # `TypeError` of a type that is not a form.
  def form_data(%{body: body} = struct) do
    owner = self()
    explicit_signal = Map.get(struct, :signal)
    struct_snapshot = Map.get(struct, :snapshot)
    # Derive the signal: explicit field takes priority, then creation-time ambient.
    signal = explicit_signal || (struct_snapshot && struct_snapshot.ambient_signal)
    content_type = content_type(struct)

    case form_type(content_type) do
      :multipart ->
        Web.Promise.new(fn resolve, reject ->
          try do
            ensure_usable!(body)
            Web.AbortSignal.check!(signal)

            case parse_multipart(body, content_type, signal, struct_snapshot, owner) do
              {:ok, form_data} -> resolve.(form_data)
              {:error, reason} -> reject.(reason)
            end
          catch
            :throw, {:abort, reason} -> reject.(reason)
          end
        end)

      type ->
        consume(body, fn binary -> parse_form_bytes(type, binary, content_type) end, fn ->
          Web.AbortSignal.check!(signal)
        end)
    end
  end

  defp form_type(content_type) do
    lower = String.downcase(content_type)

    cond do
      String.starts_with?(lower, "multipart/form-data") -> :multipart
      String.starts_with?(lower, "application/x-www-form-urlencoded") -> :urlencoded
      true -> :other
    end
  end

  defp parse_form_bytes(:urlencoded, binary, _content_type),
    do: {:ok, parse_urlencoded_form_data(binary)}

  defp parse_form_bytes(:other, _binary, content_type) do
    {:error,
     Web.TypeError.exception("Cannot parse form data from content-type #{inspect(content_type)}")}
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
  # The steps of `textStream()`: the body piped through a `TextDecoderStream`
  # for UTF-8. The `content-type` of the body has no effect. A struct with
  # no body gives a new closed stream.
  def text_stream(%{body: nil}), do: Web.ReadableStream.__from__(nil)

  def text_stream(%{body: body}) do
    :ok = ensure_usable!(body)
    Web.ReadableStream.pipe_through(body, Web.TextDecoderStream.new("utf-8"))
  end

  @doc false
  # The steps of `clone()`: a tee of the body, with a structured clone of
  # each chunk for the second branch.
  def clone(%{body: nil} = struct), do: {struct, struct}

  def clone(%{body: body} = struct) do
    :ok = ensure_usable!(body)
    [branch_a, branch_b] = Web.ReadableStream.__tee__(body, true)
    {%{struct | body: branch_a}, %{struct | body: branch_b}}
  end

  @doc false
  # The body is used when it is not `nil` and a process read from it.
  def body_used?(%{body: nil}), do: false
  def body_used?(%{body: body}), do: Web.ReadableStream.disturbed?(body)

  # A body of bytes with no process gives its bytes with no wait: the body
  # function runs in the calling process, and its promise is settled. Thus
  # a read of a small body starts no process. A large body goes to the
  # process of a promise, because its function, such as a JSON parse, needs
  # a large heap for some time.
  @now_limit 65_536

  # The messages for a body that gives no reader.
  @used_message "body already used"
  @locked_message "ReadableStream is already locked"

  # The algorithm "consume body" of the Fetch Standard. The function takes
  # the reader of the body before it returns, and the reader keeps its
  # lock, as in the Standard: after `text/1`, the body is disturbed and
  # locked. The function `convert` changes the bytes into the value of the
  # promise.
  defp consume_body(body, convert), do: consume(body, convert, fn -> :ok end)

  # `check` runs in the process of the promise before the read, and can
  # throw `{:abort, reason}`.
  defp consume(body, convert, check) do
    case acquire(body) do
      {:bytes, binary} when byte_size(binary) <= @now_limit ->
        settle_now(binary, convert, check)

      {:error, reason} ->
        Web.Promise.reject(reason)

      acquired ->
        Web.Promise.new(fn resolve, reject ->
          try do
            check.()

            case read_acquired(acquired) do
              {:ok, binary} -> settle_with(convert.(binary), resolve, reject)
              {:error, reason} -> reject.(reason)
            end
          catch
            :throw, {:abort, reason} -> reject.(reason)
          end
        end)
    end
  end

  defp settle_now(binary, convert, check) do
    check.()

    case convert.(binary) do
      {:ok, value} -> Web.Promise.resolve(value)
      {:error, reason} -> Web.Promise.reject(reason)
      value -> Web.Promise.resolve(value)
    end
  catch
    :throw, {:abort, reason} -> Web.Promise.reject(reason)
  end

  defp settle_with({:ok, value}, resolve, _reject), do: resolve.(value)
  defp settle_with({:error, reason}, _resolve, reject), do: reject.(reason)
  defp settle_with(value, resolve, _reject), do: resolve.(value)

  # The steps of "consume body" that run before the function returns: the
  # check "unusable", and "get a reader". Returns `{:bytes, binary}` for a
  # body with its bytes in memory, `{:held, lazy}` for a body that a
  # process holds, `{:reader, pid, owner}` for a stream process, or
  # `{:error, reason}`.
  defp acquire(nil), do: {:bytes, ""}
  defp acquire(body) when is_binary(body), do: {:bytes, body}
  defp acquire(body) when is_list(body), do: {:bytes, IO.iodata_to_binary(body)}

  defp acquire(%Web.ReadableStream{controller_pid: nil, lazy: lazy} = stream) do
    case LazyStream.take(lazy) do
      {:ok, binary} ->
        {:bytes, binary}

      {:error, reason} ->
        {:error, reason}

      :held ->
        {:held, lazy}

      # A process that stopped before its first read gives the bytes to a
      # new take: see `Web.ReadableStream.__lock__/2`.
      {:process, pid} ->
        stream
        |> Web.ReadableStream.__lock__(pid, &acquire_process/1, fn -> acquire(stream) end)
        |> used_if_released()

      # A tee, a body function, and a proxy disturb the stream and keep its
      # lock.
      _locked_or_used ->
        {:error, Web.TypeError.exception(@used_message)}
    end
  end

  defp acquire(%Web.ReadableStream{controller_pid: pid}),
    do: pid |> acquire_process() |> used_if_released()

  # The reader belongs to the owner of the promise: the promise and its
  # work stop when the owner stops, and the stream then frees the lock. The
  # first read of "read all bytes" disturbs the stream before the function
  # returns, as in the Standard.
  defp acquire_process(pid) do
    owner = Web.Promise.owner()

    with false <- Web.Stream.call(pid, :disturbed?, {:error, :released}),
         {:ok, _lock} <- Web.Stream.call(pid, {:get_reader, owner}, {:error, :released}) do
      :ok = Web.Stream.call(pid, :disturb, :ok)
      {:reader, pid, owner}
    else
      {:error, :already_locked} -> {:error, Web.TypeError.exception(@locked_message)}
      {:error, :released} -> {:error, :released}
      true -> {:error, Web.TypeError.exception(@used_message)}
    end
  end

  # A stream process that stopped: the body was used.
  defp used_if_released({:error, :released}), do: {:error, Web.TypeError.exception(@used_message)}
  defp used_if_released(acquired), do: acquired

  # The steps of "consume body" in the process of the promise: "read all
  # bytes".
  defp read_acquired({:bytes, binary}), do: {:ok, binary}
  defp read_acquired({:held, lazy}), do: LazyStream.take_held(lazy)
  defp read_acquired({:reader, pid, owner}), do: read_stream_chunks(pid, owner, [])

  # A read from an errored stream rejects with the error of the stream, as
  # the Streams Standard specifies. A stream that stopped in the middle of a
  # read gives a `TypeError`, as each failure of a body in the Fetch
  # Standard.
  defp stream_error({:errored, reason}), do: reason

  defp stream_error(reason) do
    Web.TypeError.exception(message: "The body stream stopped.", cause: reason)
  end

  # The body reads the chunks in batches of 64 at most: it reads all of
  # them, thus the source can work ahead. The reader keeps its lock at the
  # end, as in the Fetch Standard.
  defp read_stream_chunks(pid, owner, acc) do
    case Web.ReadableStream.read_batch(pid, owner, 64) do
      {:chunks, chunks} -> add_chunks(pid, owner, chunks, acc)
      {:ok, chunk} -> add_chunks(pid, owner, [chunk], acc)
      :done -> {:ok, join_chunks(acc)}
      {:error, reason} -> {:error, stream_error(reason)}
    end
  end

  defp add_chunks(pid, owner, [], acc), do: read_stream_chunks(pid, owner, acc)

  # The Fetch Standard requires a `Uint8Array` chunk. A binary and iodata
  # are the forms of bytes of Elixir, and a `Web.ArrayBuffer` is accepted
  # also: see `Web.Internal.Bytes`. Each other chunk gives a `TypeError`.
  defp add_chunks(pid, owner, [chunk | chunks], acc) do
    case Bytes.to_binary(chunk) do
      {:ok, binary} -> add_chunks(pid, owner, chunks, [binary | acc])
      :error -> {:error, chunk_error()}
    end
  end

  # The chunks are in the sequence from the last to the first. A body with
  # one chunk is that chunk, with no copy.
  defp join_chunks([]), do: ""
  defp join_chunks([chunk]), do: chunk
  defp join_chunks(chunks), do: chunks |> :lists.reverse() |> IO.iodata_to_binary()

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

  # "unusable" of the Fetch Standard: the body stream is disturbed or
  # locked. The multipart parser of `Web.FormData` takes its own reader: it
  # refuses a stream that is locked.
  defp ensure_usable!(body) do
    cond do
      Web.ReadableStream.disturbed?(body) -> raise Web.TypeError, @used_message
      Web.ReadableStream.__locked__(body) -> raise Web.TypeError, @locked_message
      true -> :ok
    end
  end

  defp infer_content_type(%Web.URLSearchParams{}),
    do: "application/x-www-form-urlencoded;charset=UTF-8"

  defp infer_content_type(%Web.FormData{} = form_data), do: Web.FormData.content_type(form_data)

  defp infer_content_type(%Web.Blob{type: type}) when type != "", do: type
  defp infer_content_type(body) when is_binary(body), do: "text/plain;charset=UTF-8"
  defp infer_content_type(_body), do: nil

  defp parse_multipart(body, content_type, signal, struct_snapshot, owner) do
    with {:ok, boundary} <- multipart_boundary(content_type) do
      {:ok,
       Web.FormData.parse(body, boundary,
         signal: signal,
         struct_snapshot: struct_snapshot,
         owner: owner
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
    (Web.Headers.get(headers, "content-type") || "")
    |> Web.MIME.parse()
    |> Kernel.||("")
  end

  defp content_type(_), do: ""
end
