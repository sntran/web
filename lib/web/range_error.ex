defmodule Web.RangeError do
  @moduledoc """
  An exception for a value that is not in the permitted range, as
  `RangeError` of ECMAScript.

  For example, `Web.Response.new/1` raises this exception for a status that
  is not in the range 200 to 599.
  """
  defexception [:message]

  @type t :: %__MODULE__{message: String.t()}
end
