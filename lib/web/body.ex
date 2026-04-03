defmodule Web.Body do
  @moduledoc """
  Shared body-consumption helpers for Web API structs.

  `use Web.Body` injects convenience functions:

  - `text/1` reads the body as a binary.
  - `json/1` reads the body as text and decodes it with `Jason`.
  - `arrayBuffer/1` reads the body as `%Web.ArrayBuffer{}`.
  - `bytes/1` reads the body as `%Web.Uint8Array{}`.
  - `blob/1` reads the body as `%Web.Blob{}`.
  - `clone/1` tees the body stream and returns updated original plus clone.

  The injected functions respect the stream's `[[disturbed]]` slot. Once a body has
  been consumed, subsequent calls return `{:error, Web.TypeError.exception("body already used")}`.

  ## Examples

      iex> response = Web.Response.new(body: "hello")
      iex> Web.Response.text(response)
      {:ok, "hello"}

      iex> response = Web.Response.new(body: ~s({"ok":true}))
      iex> Web.Response.json(response)
      {:ok, %{"ok" => true}}

      iex> response = Web.Response.new(body: "hello")
      iex> {:ok, %Web.ArrayBuffer{byte_length: 5}} = Web.Response.arrayBuffer(response)
      iex> {:error, %Web.TypeError{message: "body already used"}} = Web.Response.text(response)

      iex> request = Web.Request.new("https://example.com", body: "payload")
      iex> {:ok, array_buffer} = Web.Request.arrayBuffer(request)
      iex> {array_buffer.byte_length, array_buffer.data}
      {7, "payload"}

      iex> response = Web.Response.new(body: "hello")
      iex> {:ok, {response, clone}} = Web.Response.clone(response)
      iex> {:ok, "hello"} = Web.Response.text(response)
      iex> {:ok, "hello"} = Web.Response.text(clone)
  """

  @callback text(struct()) :: {:ok, binary()} | {:error, any()}
  @callback json(struct()) :: {:ok, any()} | {:error, any()}
  @callback arrayBuffer(struct()) :: {:ok, Web.ArrayBuffer.t()} | {:error, any()}
  @callback bytes(struct()) :: {:ok, Web.Uint8Array.t()} | {:error, any()}
  @callback blob(struct()) :: {:ok, Web.Blob.t()} | {:error, any()}
  @callback clone(struct()) :: {:ok, {struct(), struct()}} | {:error, any()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Web.Body

      @doc """
      Reads the body to completion and returns its UTF-8 text payload.

      Returns `{:error, %Web.TypeError{}}` when the body has already been consumed.
      """
      @impl Web.Body
      def text(struct) do
        Web.Body.text(struct)
      end

      @doc """
      Reads the body to completion and decodes it as JSON with `Jason`.

      Returns `{:error, %Web.TypeError{}}` when the body has already been consumed.
      Decoder failures are returned as `{:error, reason}`.
      """
      @impl Web.Body
      def json(struct) do
        Web.Body.json(struct)
      end

      @doc """
      Reads the body to completion and returns the raw binary payload.

      Returns `{:error, %Web.TypeError{}}` when the body has already been consumed.
      """
      @impl Web.Body
      def arrayBuffer(struct) do
        Web.Body.arrayBuffer(struct)
      end

      @doc """
      Reads the body to completion and returns a `Web.Uint8Array`.

      Returns `{:error, %Web.TypeError{}}` when the body has already been consumed.
      """
      @impl Web.Body
      def bytes(struct) do
        Web.Body.bytes(struct)
      end

      @doc """
      Reads the body to completion and returns a `Web.Blob`.

      Uses the `content-type` header as the Blob MIME type.
      Returns `{:error, %Web.TypeError{}}` when the body has already been consumed.
      """
      @impl Web.Body
      def blob(struct) do
        Web.Body.blob(struct)
      end

      @doc """
      Clones the struct body by teeing the underlying readable stream.

      Returns `{:ok, {updated_original, clone}}` where both have independent streams.
      """
      @impl Web.Body
      def clone(struct) do
        Web.Body.clone(struct)
      end
    end
  end

  @doc false
  def text(%{body: body}) do
    with :ok <- ensure_usable(body) do
      Web.ReadableStream.read_all(body)
    end
  end

  @doc false
  def json(%{body: body}) do
    with :ok <- ensure_usable(body),
         {:ok, binary} <- Web.ReadableStream.read_all(body) do
      Jason.decode(binary)
    end
  end

  @doc false
  def arrayBuffer(%{body: body}) do
    with :ok <- ensure_usable(body),
         {:ok, binary} <- Web.ReadableStream.read_all(body) do
      {:ok, Web.ArrayBuffer.new(binary)}
    end
  end

  @doc false
  def bytes(%{body: body} = struct) do
    with :ok <- ensure_usable(body),
         {:ok, %Web.ArrayBuffer{} = array_buffer} <- arrayBuffer(struct) do
      {:ok, Web.Uint8Array.new(array_buffer)}
    end
  end

  @doc false
  def blob(%{body: body} = struct) do
    with :ok <- ensure_usable(body),
         {:ok, binary} <- Web.ReadableStream.read_all(body) do
      {:ok, Web.Blob.new([binary], type: content_type(struct))}
    end
  end

  @doc false
  def clone(%{body: body} = struct) do
    try do
      with :ok <- ensure_usable(body) do
        {branch_a, branch_b} = Web.ReadableStream.tee(body)
        {:ok, {%{struct | body: branch_a}, %{struct | body: branch_b}}}
      end
    rescue
      e in Web.TypeError -> {:error, e}
    end
  end

  defp ensure_usable(body) do
    if Web.ReadableStream.disturbed?(body) do
      {:error, Web.TypeError.exception("body already used")}
    else
      :ok
    end
  end

  defp content_type(%{headers: %Web.Headers{} = headers}) do
    Web.Headers.get(headers, "content-type", "")
  end

  defp content_type(_), do: ""
end
