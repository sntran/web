defmodule Web.File do
  @moduledoc """
  WHATWG-style File representation extending Blob metadata with multipart context.

  `name` stores the multipart field name.
  `filename` stores the uploaded filename from Content-Disposition.
  `last_modified` stores the time of the last change of the file, in
  milliseconds from the Unix epoch, as `lastModified` of the File API.

  The functions of `Web.Blob` accept a file: `Web.Blob.text/1`,
  `Web.Blob.slice/4`, `Web.Blob.stream/1`, and the others.
  """

  @enforce_keys [:id, :parts, :size, :type, :name, :filename]
  defstruct [:id, :parts, :size, :type, :name, :filename, :stream, :last_modified]

  @type t :: %__MODULE__{
          id: reference() | nil,
          parts: [binary() | Web.Blob.t()],
          size: non_neg_integer() | nil,
          type: String.t(),
          name: String.t(),
          filename: String.t(),
          stream: Web.ReadableStream.t() | nil,
          last_modified: integer()
        }

  @doc """
  Creates a new File from Blob parts and multipart metadata.

  A part is a part of `Web.Blob.new/2`. The option `:last_modified` is the
  time of the last change in milliseconds from the Unix epoch. The default
  is the time now, as the constructor of the File API specifies.

  ## Examples

      iex> file = Web.File.new(["bits"], filename: "a.txt", last_modified: 123)
      iex> {file.filename, file.size, file.last_modified}
      {"a.txt", 4, 123}
  """
  @spec new([Web.Blob.blob_part()], keyword()) :: t()
  def new(parts, opts \\ []) when is_list(parts) do
    blob = Web.Blob.new(parts, type: Keyword.get(opts, :type, ""))
    size = Keyword.get(opts, :size, blob.size)

    %__MODULE__{
      id: make_ref(),
      parts: blob.parts,
      size: size,
      type: blob.type,
      name: Keyword.get(opts, :name, ""),
      filename: Keyword.get(opts, :filename, "blob"),
      stream: Keyword.get(opts, :stream),
      last_modified: Keyword.get_lazy(opts, :last_modified, &now/0)
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
