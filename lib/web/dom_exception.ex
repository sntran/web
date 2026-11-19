# credo:disable-for-this-file Credo.Check.Consistency.ExceptionNames
defmodule Web.DOMException do
  @moduledoc """
  A WHATWG-style DOMException.
  """

  @codes %{
    "InvalidStateError" => 11,
    "SyntaxError" => 12,
    "AbortError" => 20,
    "TimeoutError" => 23,
    "DataCloneError" => 25
  }

  defexception [:name, :message, :code]

  @type t :: %__MODULE__{
          name: String.t(),
          message: String.t(),
          code: non_neg_integer()
        }

  @impl true
  def exception(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, "Error")
    message = Keyword.get(opts, :message, name)

    %__MODULE__{
      name: name,
      message: message,
      code: Map.get(@codes, name, 0)
    }
  end

  def exception(name) when is_binary(name) do
    exception(name: name)
  end

  @doc """
  The reason of a signal that aborted with no reason, as the DOM Standard
  specifies.
  """
  @spec abort_error() :: t()
  def abort_error do
    exception(name: "AbortError", message: "signal is aborted without reason")
  end

  @doc """
  The reason of a signal from `Web.AbortSignal.timeout/1`, as the DOM
  Standard specifies.
  """
  @spec timeout_error() :: t()
  def timeout_error do
    exception(name: "TimeoutError", message: "signal timed out")
  end
end
