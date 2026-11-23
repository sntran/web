defmodule Web.File do
  @moduledoc """
  A blob with a name and a time of the last change, as `File` of the File
  API.

  `name` is the name of the file. `last_modified` is the time of the last
  change of the file, in milliseconds from the Unix epoch, as
  `lastModified` of the File API.

  The name of a field of a form is not a part of a file. It is the name of
  an entry of a `Web.FormData`.

  The functions of `Web.Blob` accept a file: `Web.Blob.text/1`,
  `Web.Blob.slice/4`, `Web.Blob.stream/1`, and the others.
  """

  @enforce_keys [:id, :parts, :size, :type, :name]
  defstruct [:id, :parts, :size, :type, :name, :stream, :last_modified]

  @type t :: %__MODULE__{
          id: reference() | nil,
          parts: [binary() | Web.Blob.t()],
          size: non_neg_integer() | nil,
          type: String.t(),
          name: String.t(),
          stream: Web.ReadableStream.t() | nil,
          last_modified: integer()
        }

  @doc """
  Creates a new File from the bits, the name of the file, and the options,
  as the constructor `File(fileBits, fileName, options)` of the File API.

  A bit is a part of `Web.Blob.new/2`. The name of the file is a string.
  The options are the members of the dictionary `FilePropertyBag`:

    * `:type` - the type of the file. The type follows the rules of the
      type of `Web.Blob.new/2`. The default is the empty string.
    * `:endings` - `"transparent"` (the default) or `"native"`, as for
      `Web.Blob.new/2`.
    * `:last_modified` - the time of the last change, in milliseconds from
      the Unix epoch. The default is the time now.

  ## Examples

      iex> file = Web.File.new(["bits"], "a.txt", type: "Text/Plain", last_modified: 123)
      iex> {file.name, file.size, file.type, file.last_modified}
      {"a.txt", 4, "text/plain", 123}
  """
  @spec new([Web.Blob.blob_part()], String.t(), keyword()) :: t()
  def new(file_bits, file_name, options \\ [])
      when is_list(file_bits) and is_binary(file_name) and is_list(options) do
    blob = Web.Blob.new(file_bits, Keyword.take(options, [:type, :endings]))

    %__MODULE__{
      id: make_ref(),
      parts: blob.parts,
      size: blob.size,
      type: blob.type,
      name: file_name,
      last_modified: Keyword.get_lazy(options, :last_modified, &now/0)
    }
  end

  @doc false
  @spec identity(t()) :: reference() | nil
  def identity(%__MODULE__{} = file), do: file.id

  @doc """
  Returns a readable stream view over file contents.

  If `stream` is present, it is returned directly. Otherwise a stream is created from Blob parts.
  """
  @spec stream(t()) :: Web.ReadableStream.t()
  def stream(%__MODULE__{stream: %Web.ReadableStream{} = stream}), do: stream

  def stream(%__MODULE__{parts: parts, type: type}) do
    Web.Blob.new(parts, type: type)
    |> Web.Blob.stream()
  end

  # The current date and time, as `Date.now()` of ECMAScript.
  defp now, do: System.os_time(:millisecond)
end
