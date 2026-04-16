defmodule Web.Response do
  @moduledoc """
  An implementation of the WHATWG Response standard.

  Represents an HTTP response, including status, headers, and a streamable body.
  Matches the zero-buffer streaming rule.
  """
  use Web.Body

  alias Web.AsyncContext
  alias Web.MIME

  defstruct [
    :body,
    :status,
    :ok,
    :status_text,
    :url,
    :type,
    :snapshot,
    headers: Web.Headers.new()
  ]

  @type t :: %__MODULE__{
          body: Enumerable.t() | nil,
          headers: Web.Headers.t(),
          status: non_neg_integer(),
          ok: boolean(),
          status_text: String.t(),
          url: String.t(),
          type: String.t(),
          snapshot: AsyncContext.Snapshot.t() | nil
        }

  @redirect_statuses [301, 302, 303, 307, 308]

  @doc """
  Constructs a new Response structure.

  Automatically normalizes the `:ok` boolean based on standard 2xx range (success for both HTTP and NNTP).

  ## Examples
      iex> resp = Web.Response.new(status: 200)
      iex> resp.ok
      true

      iex> resp = Web.Response.new(status: 404)
      iex> resp.ok
      false

      iex> resp = Web.Response.new(status: 206)
      iex> resp.ok
      true
  """
  def new(opts) when is_list(opts) do
    status = Keyword.get(opts, :status, 200)
    raw_body = Keyword.get(opts, :body)

    headers =
      Keyword.get(opts, :headers, %{})
      |> Web.Headers.new()
      |> Web.Body.put_inferred_content_type(raw_body)

    # JS fetch normalizes 2xx as ok: true
    # NNTP standard 2xx codes and HTTP 2xx codes both specify success.
    ok = status >= 200 and status < 300
    status_text = Keyword.get(opts, :status_text, "")

    %__MODULE__{
      body: Web.ReadableStream.from(raw_body),
      headers: headers,
      status: status,
      ok: ok,
      status_text: status_text,
      url: Keyword.get(opts, :url),
      type: Keyword.get(opts, :type, "default"),
      snapshot: AsyncContext.Snapshot.take()
    }
  end

  def new, do: new([])

  @doc """
  Constructs a new Response using a body and init options.
  """
  def new(body, init) when is_list(init) do
    init
    |> Keyword.put(:body, body)
    |> new()
  end

  @doc """
  Returns a network-error style response.
  """
  @spec error() :: t()
  def error do
    new(body: nil, status: 0, type: "error")
  end

  @doc """
  Creates a JSON response and sets the content type.
  """
  @spec json(any(), keyword()) :: t()
  def json(data, init \\ []) do
    encoded = Jason.encode!(data)

    headers =
      init
      |> Keyword.get(:headers, %{})
      |> Web.Headers.new()
      |> Web.Headers.set("content-type", "application/json")

    init
    |> Keyword.put(:headers, headers)
    |> Keyword.put_new(:status_text, "OK")
    |> then(&new(encoded, &1))
  end

  @doc """
  Creates a redirect response with an empty body and Location header.
  """
  @spec redirect(String.t(), non_neg_integer()) :: t()
  def redirect(url, status \\ 302) when is_integer(status) do
    if status not in @redirect_statuses do
      raise Web.TypeError, "Invalid redirect status #{status}"
    end

    status_text =
      case status do
        301 -> "Moved Permanently"
        302 -> "Found"
        303 -> "See Other"
        307 -> "Temporary Redirect"
        308 -> "Permanent Redirect"
      end

    new(
      body: nil,
      status: status,
      status_text: status_text,
      headers: %{"location" => to_string(url)}
    )
  end

  @doc false
  @spec resolved_content_type(t(), binary() | nil) :: String.t()
  def resolved_content_type(%__MODULE__{} = response, body_binary \\ nil) do
    header_value = Web.Headers.get(response.headers, "content-type")
    parsed_header = MIME.parse(header_value)

    cond do
      parsed_header != nil and not MIME.generic_binary?(parsed_header) ->
        parsed_header

      is_binary(body_binary) ->
        MIME.sniff(body_binary)

      is_binary(response.body) ->
        MIME.sniff(response.body)

      is_list(response.body) ->
        response.body |> IO.iodata_to_binary() |> MIME.sniff()

      true ->
        parsed_header || "application/octet-stream"
    end
  end
end
