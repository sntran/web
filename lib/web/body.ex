defmodule Web.Body do
  @moduledoc """
  Shared body-consumption helpers for Web API structs.

  `use Web.Body` injects convenience functions:

  - `text/1` reads the body as a binary.
  - `json/1` reads the body as text and decodes it with `Jason`.
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

      iex> request = Web.Request.new("https://example.com", body: "payload")
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

  @callback text(struct()) :: Web.Promise.t()
  @callback json(struct()) :: Web.Promise.t()
  @callback form_data(struct()) :: Web.Promise.t()
  @callback array_buffer(struct()) :: Web.Promise.t()
  @callback bytes(struct()) :: Web.Promise.t()
  @callback blob(struct()) :: Web.Promise.t()
  @callback clone(struct()) :: {struct(), struct()}
  defmacro __using__(_opts) do
    # coveralls-ignore-start
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
      Reads the body to completion and resolves with decoded JSON via `Jason`.
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
    end

    # coveralls-ignore-stop
  end

  @doc false
  def text(%{body: body}) do
    Web.Promise.new(fn resolve, reject ->
      ensure_usable!(body)

      case read_body_to_text(body) do
        {:ok, text} -> resolve.(text)
        {:error, reason} -> reject.(reason)
      end
    end)
  end

  @doc false
  def json(%{body: body}) do
    consume_body(body, &Jason.decode/1)
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
      type =
        if Map.get(struct, :__struct__) == Web.Response do
          Web.Response.resolved_content_type(struct, binary)
        else
          content_type(struct)
        end

      Web.Blob.new([binary], type: type)
    end)
  end

  @doc false
  def clone(%{body: body} = struct) do
    ensure_usable!(body)
    [branch_a, branch_b] = Web.ReadableStream.tee(body)
    {%{struct | body: branch_a}, %{struct | body: branch_b}}
  end

  defp consume_body(body, mapper) do
    Web.Promise.new(fn resolve, reject ->
      ensure_usable!(body)

      case read_body_to_binary(body) do
        {:ok, binary} ->
          handle_consumed_body(mapper.(binary), resolve, reject)

        {:error, reason} ->
          reject.(reason)
      end
    end)
  end

  defp handle_consumed_body({:ok, value}, resolve, _reject), do: resolve.(value)
  defp handle_consumed_body({:error, reason}, _resolve, reject), do: reject.(reason)
  defp handle_consumed_body(value, resolve, _reject), do: resolve.(value)

  defp read_body_to_binary(nil), do: {:ok, ""}
  defp read_body_to_binary(body) when is_binary(body), do: {:ok, body}
  defp read_body_to_binary(body) when is_list(body), do: {:ok, IO.iodata_to_binary(body)}

  defp read_body_to_binary(%Web.ReadableStream{controller_pid: pid}) do
    case Web.ReadableStream.get_reader(pid) do
      :ok ->
        read_stream_chunks(pid, [])

      {:error, :already_locked} ->
        {:error, Web.TypeError.exception("ReadableStream is already locked")}
    end
  end

  defp read_stream_chunks(pid, acc) do
    case Web.ReadableStream.read(pid) do
      {:ok, chunk} ->
        read_stream_chunks(pid, [chunk | acc])

      :done ->
        Web.ReadableStream.release_lock(pid)
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, reason} ->
        Web.ReadableStream.release_lock(pid)
        {:error, reason}
    end
  end

  defp read_body_to_text(nil), do: {:ok, ""}

  defp read_body_to_text(body) when is_binary(body) or is_list(body) do
    decode_text_body(body)
  end

  defp read_body_to_text(%Web.ReadableStream{controller_pid: pid}) do
    decoder = Web.TextDecoder.new()

    case Web.ReadableStream.get_reader(pid) do
      :ok ->
        read_stream_text_chunks(pid, decoder, [])

      {:error, :already_locked} ->
        {:error, Web.TypeError.exception("ReadableStream is already locked")}
    end
  end

  defp read_stream_text_chunks(pid, decoder, acc) do
    case Web.ReadableStream.read(pid) do
      {:ok, chunk} ->
        with {:ok, binary} <- normalize_text_chunk(chunk),
             decoded <- Web.TextDecoder.decode(decoder, binary, %{stream: true}) do
          read_stream_text_chunks(pid, decoder, [decoded | acc])
        else
          {:error, reason} ->
            Web.ReadableStream.release_lock(pid)
            {:error, reason}
        end

      :done ->
        Web.ReadableStream.release_lock(pid)

        final = Web.TextDecoder.decode(decoder, "", %{stream: false})
        {:ok, acc |> Enum.reverse() |> Kernel.++([final]) |> IO.iodata_to_binary()}

      {:error, reason} ->
        Web.ReadableStream.release_lock(pid)
        {:error, reason}
    end
  end

  defp decode_text_body(body) do
    binary =
      cond do
        is_binary(body) -> body
        is_list(body) -> IO.iodata_to_binary(body)
      end

    {:ok, Web.TextDecoder.decode(Web.TextDecoder.new(), binary)}
  end

  defp normalize_text_chunk(chunk) when is_binary(chunk), do: {:ok, chunk}
  defp normalize_text_chunk(%Web.Uint8Array{} = chunk), do: {:ok, Web.Uint8Array.to_binary(chunk)}
  defp normalize_text_chunk(chunk) when is_list(chunk), do: {:ok, IO.iodata_to_binary(chunk)}

  defp normalize_text_chunk(_chunk) do
    {:error, Web.TypeError.exception("Body stream chunk must be binary, Uint8Array, or iodata")}
  end

  @doc false
  def put_inferred_content_type(%Web.Headers{} = headers, body) do
    cond do
      Web.Headers.has(headers, "content-type") ->
        headers

      inferred = infer_content_type(body) ->
        Web.Headers.set(headers, "content-type", inferred)

      true ->
        headers
    end
  end

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

  defp parse_urlencoded_form_data(binary) do
    params = Web.URLSearchParams.new(binary)

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

  defp content_type(%{headers: %Web.Headers{} = headers} = struct) do
    if Map.get(struct, :__struct__) == Web.Response do
      Web.Response.resolved_content_type(struct)
    else
      headers
      |> Web.Headers.get("content-type", "")
      |> Web.MIME.parse()
      |> Kernel.||("")
    end
  end

  defp content_type(_), do: ""
end
