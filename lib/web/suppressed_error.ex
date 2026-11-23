defmodule Web.SuppressedError do
  @moduledoc """
  The error of a disposal that failed after a different error, as
  `SuppressedError` of ECMAScript.

  `Web.using/2` raises it when its block failed, and the disposal of the
  resource failed too. No error is lost:

    * `error` - the value that the disposal threw;
    * `suppressed` - the value that the block threw.

  A value is an exception, or the value of a `throw`, or the reason of an
  `exit`. When more than one disposal failed, `suppressed` is the
  `Web.SuppressedError` of the disposal before.
  """

  defexception [:error, :suppressed, message: "An error was suppressed during disposal."]

  @type t :: %__MODULE__{error: term(), suppressed: term(), message: String.t()}
end
