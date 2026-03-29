defmodule Web.Response do
  @moduledoc """
  Represents an HTTP, NNTP, TCP or generic Response object.
  Contains a streamable body matching the zero-buffer rule.
  """

  defstruct [
    :body,
    :status,
    :ok,
    :url,
    headers: Web.Headers.new()
  ]

  @type t :: %__MODULE__{
          body: Enumerable.t() | nil,
          headers: Web.Headers.t(),
          status: non_neg_integer(),
          ok: boolean(),
          url: String.t()
        }

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
  def new(opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    # JS fetch normalizes 2xx as ok: true
    # NNTP standard 2xx codes and HTTP 2xx codes both specify success.
    ok = status >= 200 and status <= 299

    %__MODULE__{
      body: Keyword.get(opts, :body),
      headers: Web.Headers.new(Keyword.get(opts, :headers, %{})),
      status: status,
      ok: ok,
      url: Keyword.get(opts, :url)
    }
  end
end
