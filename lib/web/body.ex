defmodule Web.Body do
  @moduledoc """
  Shared body-consumption helpers for Web API structs.

  `use Web.Body` injects three convenience functions:

  - `text/1` reads the body as a binary.
  - `json/1` reads the body as text and decodes it with `Jason`.
  - `arrayBuffer/1` reads the body as a binary.

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
      iex> {:ok, "hello"} = Web.Response.arrayBuffer(response)
      iex> {:error, %Web.TypeError{message: "body already used"}} = Web.Response.text(response)

      iex> request = Web.Request.new("https://example.com", body: "payload")
      iex> Web.Request.arrayBuffer(request)
      {:ok, "payload"}
  """

  @callback text(struct()) :: {:ok, binary()} | {:error, any()}
  @callback json(struct()) :: {:ok, any()} | {:error, any()}
  @callback arrayBuffer(struct()) :: {:ok, binary()} | {:error, any()}

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
    with :ok <- ensure_usable(body) do
      Web.ReadableStream.read_all(body)
    end
  end

  defp ensure_usable(body) do
    if Web.ReadableStream.disturbed?(body) do
      {:error, Web.TypeError.exception("body already used")}
    else
      :ok
    end
  end
end
