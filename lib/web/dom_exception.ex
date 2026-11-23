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

  ## Constants

  The legacy codes of the interface `DOMException` are functions with no
  argument, from `index_size_err/0` (`INDEX_SIZE_ERR`, 1) to
  `data_clone_err/0` (`DATA_CLONE_ERR`, 25).

      iex> Web.DOMException.data_clone_err()
      25
      iex> Web.DOMException.new("", "DataCloneError").code == Web.DOMException.data_clone_err()
      true
  """

  defexception [:name, :message, :code]

  # The constants of the interface `DOMException` in Web IDL, with the
  # name of the table "DOMException names" that has the code. The codes 2,
  # 6, and 16 have no name in the table.
  @constants [
    {:index_size_err, "INDEX_SIZE_ERR", 1, "IndexSizeError"},
    {:domstring_size_err, "DOMSTRING_SIZE_ERR", 2, nil},
    {:hierarchy_request_err, "HIERARCHY_REQUEST_ERR", 3, "HierarchyRequestError"},
    {:wrong_document_err, "WRONG_DOCUMENT_ERR", 4, "WrongDocumentError"},
    {:invalid_character_err, "INVALID_CHARACTER_ERR", 5, "InvalidCharacterError"},
    {:no_data_allowed_err, "NO_DATA_ALLOWED_ERR", 6, nil},
    {:no_modification_allowed_err, "NO_MODIFICATION_ALLOWED_ERR", 7,
     "NoModificationAllowedError"},
    {:not_found_err, "NOT_FOUND_ERR", 8, "NotFoundError"},
    {:not_supported_err, "NOT_SUPPORTED_ERR", 9, "NotSupportedError"},
    {:inuse_attribute_err, "INUSE_ATTRIBUTE_ERR", 10, "InUseAttributeError"},
    {:invalid_state_err, "INVALID_STATE_ERR", 11, "InvalidStateError"},
    {:syntax_err, "SYNTAX_ERR", 12, "SyntaxError"},
    {:invalid_modification_err, "INVALID_MODIFICATION_ERR", 13, "InvalidModificationError"},
    {:namespace_err, "NAMESPACE_ERR", 14, "NamespaceError"},
    {:invalid_access_err, "INVALID_ACCESS_ERR", 15, "InvalidAccessError"},
    {:validation_err, "VALIDATION_ERR", 16, nil},
    {:type_mismatch_err, "TYPE_MISMATCH_ERR", 17, "TypeMismatchError"},
    {:security_err, "SECURITY_ERR", 18, "SecurityError"},
    {:network_err, "NETWORK_ERR", 19, "NetworkError"},
    {:abort_err, "ABORT_ERR", 20, "AbortError"},
    {:url_mismatch_err, "URL_MISMATCH_ERR", 21, "URLMismatchError"},
    {:quota_exceeded_err, "QUOTA_EXCEEDED_ERR", 22, "QuotaExceededError"},
    {:timeout_err, "TIMEOUT_ERR", 23, "TimeoutError"},
    {:invalid_node_type_err, "INVALID_NODE_TYPE_ERR", 24, "InvalidNodeTypeError"},
    {:data_clone_err, "DATA_CLONE_ERR", 25, "DataCloneError"}
  ]

  # The table "DOMException names": the legacy code of each name.
  @codes for {_function, _constant, code, name} <- @constants, name, into: %{}, do: {name, code}

  for {function, constant, code, name} <- @constants do
    @doc if name,
           do:
             "The constant `DOMException.#{constant}` (#{code}): the code of the name `#{name}`.",
           else: "The constant `DOMException.#{constant}` (#{code}). No name has this code."
    @spec unquote(function)() :: unquote(code)
    def unquote(function)(), do: unquote(code)
  end

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
