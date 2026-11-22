defmodule Web.RangeError do
  @moduledoc """
  An exception for a value that is not in the permitted range, as
  `RangeError` of ECMAScript.

  For example, `Web.Response.new/1` raises this exception for a status that
  is not in the range 200 to 599.

  The field `cause` has the error that caused this one, if there is one, as
  the option `cause` of the constructor `RangeError(message, options)`.
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
