defmodule Web.File do
  @moduledoc """
  WHATWG-style File representation extending Blob metadata with multipart context.

  `name` stores the multipart field name.
  `filename` stores the uploaded filename from Content-Disposition.
  """

  @enforce_keys [:id, :parts, :size, :type, :name, :filename]
  defstruct [:id, :parts, :size, :type, :name, :filename, :stream]

  @type t :: %__MODULE__{
          id: reference() | nil,
          parts: [binary() | Web.Blob.t()],
          size: non_neg_integer() | nil,
          type: String.t(),
          name: String.t(),
          filename: String.t(),
          stream: Web.ReadableStream.t() | nil
        }

  @doc """
  Creates a new File from Blob parts and multipart metadata.
  """
  @spec new([binary() | Web.Blob.t()], keyword()) :: t()
  def new(parts, opts \\ []) when is_list(parts) do
    blob = Web.Blob.new(parts, type: Keyword.get(opts, :type, ""))
    size = Keyword.get(opts, :size, blob.size)

    %__MODULE__{
      id: make_ref(),
      parts: parts,
      size: size,
      type: blob.type,
      name: Keyword.get(opts, :name, ""),
      filename: Keyword.get(opts, :filename, "blob"),
      stream: Keyword.get(opts, :stream)
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
end
