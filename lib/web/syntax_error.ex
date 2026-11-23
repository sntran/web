defmodule Web.SyntaxError do
  @moduledoc """
  An exception for text that cannot be parsed, as `SyntaxError` of
  ECMAScript.

  For example, `Web.Response.json/1` rejects with this exception when the
  body is not JSON. The field `cause` has the error of the parser.
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
