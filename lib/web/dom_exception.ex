# credo:disable-for-this-file Credo.Check.Consistency.ExceptionNames
defmodule Web.DOMException do
  @moduledoc """
  An error with a name, as `DOMException` of the Web IDL Standard.

  The fields are the attributes of the Standard: `name`, `message`, and
  `code`. The legacy code of a name is in the table "DOMException names" of
  the Standard. Each other name has the code 0.

  ## Examples

      iex> error = Web.DOMException.new("The data cannot be cloned.", "DataCloneError")
      iex> {error.name, error.message, error.code}
      {"DataCloneError", "The data cannot be cloned.", 25}

      iex> error = Web.DOMException.new()
      iex> {error.name, error.message, error.code}
      {"Error", "", 0}
  """

  @codes %{
    "IndexSizeError" => 1,
    "HierarchyRequestError" => 3,
    "WrongDocumentError" => 4,
    "InvalidCharacterError" => 5,
    "NoModificationAllowedError" => 7,
    "NotFoundError" => 8,
    "NotSupportedError" => 9,
    "InUseAttributeError" => 10,
    "InvalidStateError" => 11,
    "SyntaxError" => 12,
    "InvalidModificationError" => 13,
    "NamespaceError" => 14,
    "InvalidAccessError" => 15,
    "TypeMismatchError" => 17,
    "SecurityError" => 18,
    "NetworkError" => 19,
    "AbortError" => 20,
    "URLMismatchError" => 21,
    "QuotaExceededError" => 22,
    "TimeoutError" => 23,
    "InvalidNodeTypeError" => 24,
    "DataCloneError" => 25
  }

  defexception [:name, :message, :code]

  @type t :: %__MODULE__{
          name: String.t(),
          message: String.t(),
          code: non_neg_integer()
        }

  @doc """
  Makes an error, as the constructor `new DOMException(message, name)`.

  The default message is `""`, and the default name is `"Error"`. The value
  of `code` comes from the name.
  """
  @spec new(String.t(), String.t()) :: t()
  def new(message \\ "", name \\ "Error") when is_binary(message) and is_binary(name) do
    %__MODULE__{name: name, message: message, code: Map.get(@codes, name, 0)}
  end

  @impl true
  def exception(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, "Error")
    new(Keyword.get(opts, :message, name), name)
  end

  def exception(name) when is_binary(name) do
    exception(name: name)
  end

  @doc false
  # The reason of a signal that aborted with no reason, as the DOM Standard
  # specifies.
  @spec abort_error() :: t()
  def abort_error do
    exception(name: "AbortError", message: "signal is aborted without reason")
  end

  @doc false
  # The reason of a signal from `Web.AbortSignal.timeout/1`, as the DOM
  # Standard specifies.
  @spec timeout_error() :: t()
  def timeout_error do
    exception(name: "TimeoutError", message: "signal timed out")
  end
end
