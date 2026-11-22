defmodule Web.AggregateError do
  @moduledoc """
  An error that has a list of errors, as `AggregateError` of ECMAScript.

  `Web.Promise.any/1` rejects with this error when each input promise
  rejects. The field `errors` has the reasons, in the sequence of the
  input.
  """

  defexception [:errors]

  @type t :: %__MODULE__{errors: list()}

  @impl true
  def message(%{errors: errors}) do
    "All promises were rejected: #{inspect(errors)}"
  end
end
