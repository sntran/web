defmodule Web.TypeError do
  @moduledoc """
  An exception struct for spec violations.

  The field `cause` has the error that caused this one, if there is one. For
  example, a `Web.fetch/2` that fails rejects with a `Web.TypeError` whose
  cause is the network error.
  """
  defexception [:message, :cause]

  @type t :: %__MODULE__{message: String.t(), cause: term()}

  @impl true
  def exception(message) when is_binary(message) do
    %__MODULE__{message: message}
  end

  def exception(opts) when is_list(opts) do
    %__MODULE__{message: Keyword.fetch!(opts, :message), cause: Keyword.get(opts, :cause)}
  end
end
