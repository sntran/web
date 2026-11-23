defmodule Web.AggregateError do
  @moduledoc """
  An error that has a list of errors, as `AggregateError` of ECMAScript.

  `Web.Promise.any/1` rejects with this error when each input promise
  rejects. The field `errors` has the reasons, in the sequence of the
  input.

  The fields `message` and `cause` are the arguments `message` and
  `options.cause` of the constructor `AggregateError(errors, message,
  options)`. With no message, `Exception.message/1` gives a text with the
  errors.
  """

  defexception [:errors, :message, :cause]

  @type t :: %__MODULE__{errors: list(), message: String.t() | nil, cause: term()}

  @impl true
  def message(%{message: message}) when is_binary(message), do: message

  def message(%{errors: errors}) do
    "All promises were rejected: #{inspect(errors)}"
  end
end
