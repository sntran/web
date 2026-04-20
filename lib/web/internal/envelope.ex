defmodule Web.Internal.Envelope do
  @moduledoc false

  alias Web.AsyncContext.Snapshot

  @type headers :: %{required(String.t()) => term()}

  @type t :: %__MODULE__{
          headers: headers(),
          body: term()
        }

  defstruct [:headers, :body]

  @spec new(reference(), term(), map()) :: t()
  def new(token, body, snapshot \\ Snapshot.take())
      when is_reference(token) and is_map(snapshot) do
    %__MODULE__{
      headers: %{"Authorization" => token, "X-Async-Context" => snapshot},
      body: body
    }
  end
end
