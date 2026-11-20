defmodule Web.Blob do
  @moduledoc """
  WHATWG-style immutable Blob representation.

  ## Examples

      iex> blob = Web.Blob.new(["hello", " ", "world"], type: "text/plain")
      iex> {blob.size, blob.type}
      {11, "text/plain"}
  """

  alias Web.Internal.JSON, as: JSONText

  @enforce_keys [:id, :parts, :size, :type]
  defstruct [:id, :parts, :size, :type]

  @type blob_part :: binary() | t() | Web.Uint8Array.t() | Web.ArrayBuffer.t()
  @type t :: %__MODULE__{
          id: reference() | nil,
          parts: [blob_part()],
          size: non_neg_integer(),
          type: String.t()
        }

  @doc """
  Creates a new Blob from parts and optional content type.

  A part is a binary, a `Web.Blob`, a `Web.Uint8Array`, or a
  `Web.ArrayBuffer`. The blob keeps a copy of the bytes of a view or a
  buffer, as the File API specifies.

  ## Examples

      iex> blob = Web.Blob.new(["a", Web.Uint8Array.from("bc"), Web.ArrayBuffer.new("d")])
      iex> {blob.size, Web.Blob.text(blob)}
      {4, {:ok, "abcd"}}
  """
  @spec new([blob_part()], keyword()) :: t()
  def new(parts_list, opts \\ []) when is_list(parts_list) do
    type = opts |> Keyword.get(:type, "") |> normalize_type()
    parts_list = Enum.map(parts_list, &normalize_part/1)

    size =
      Enum.reduce(parts_list, 0, fn part, acc ->
        acc + part_size(part)
      end)

    %__MODULE__{id: make_ref(), parts: parts_list, size: size, type: type}
  end

  @doc false
  @spec identity(t()) :: reference() | nil
  def identity(%__MODULE__{} = blob), do: blob.id

  @doc """
  Returns a new Blob representing the selected range.
  """
  @spec slice(t(), integer(), integer() | nil, String.t()) :: t()
  def slice(blob, start, finish \\ nil, content_type \\ "")

  def slice(%__MODULE__{} = blob, start, finish, content_type)
      when is_integer(start) and (is_integer(finish) or is_nil(finish)) do
    size = blob.size
    relative_start = normalize_index(start, size)

    relative_end =
      case finish do
        nil -> size
        value -> normalize_index(value, size)
      end

    span = max(relative_end - relative_start, 0)
    parts = slice_parts(blob.parts, relative_start, span)

    new(parts, type: content_type)
  end

  @doc false
  @spec to_binary(t()) :: binary()
  def to_binary(%__MODULE__{parts: parts}) do
    parts
    |> Enum.map(fn
      part when is_binary(part) -> part
      %__MODULE__{} = blob -> to_binary(blob)
    end)
    |> IO.iodata_to_binary()
  end

  @doc """
  Returns a readable stream of the bytes of the blob. Each chunk is a
  `Web.Uint8Array`.
  """
  @spec stream(t()) :: Web.ReadableStream.t()
  def stream(%__MODULE__{} = blob) do
    Web.ReadableStream.from(blob)
  end

  @doc """
  Reads the contents of the blob as text, as `text()` of the File API: the
  UTF-8 decode of the bytes. A byte order mark goes away, and each byte
  sequence that is not valid UTF-8 becomes U+FFFD.

  ## Examples

      iex> Web.Blob.text(Web.Blob.new([<<0xEF, 0xBB, 0xBF>>, "caf", <<0xC3, 0xA9>>, <<0xFF>>]))
      {:ok, "café\uFFFD"}
  """
  @spec text(t()) :: {:ok, String.t()}
  def text(%__MODULE__{} = blob) do
    {:ok, blob |> to_binary() |> Web.TextDecoder.decode_utf8()}
  end

  @doc """
  Reads the contents of the blob as text, and parses it as JSON, as
  `JSON.parse` of ECMAScript. Returns `{:ok, value}`, or
  `{:error, %JSON.DecodeError{}}`.
  """
  @spec json(t()) :: {:ok, any()} | {:error, any()}
  def json(%__MODULE__{} = blob) do
    with {:ok, text} <- text(blob) do
      JSONText.parse(text)
    end
  end

  @doc """
  Reads Blob contents as ArrayBuffer.
  """
  @spec array_buffer(t()) :: {:ok, Web.ArrayBuffer.t()}
  def array_buffer(%__MODULE__{} = blob) do
    {:ok, blob |> to_binary() |> Web.ArrayBuffer.new()}
  end

  @doc """
  Reads Blob contents as Uint8Array.
  """
  @spec bytes(t()) :: {:ok, Web.Uint8Array.t()}
  def bytes(%__MODULE__{} = blob) do
    with {:ok, array_buffer} <- array_buffer(blob) do
      {:ok, Web.Uint8Array.new(array_buffer)}
    end
  end

  defp normalize_part(%Web.Uint8Array{} = part), do: Web.Uint8Array.to_binary(part)
  defp normalize_part(%Web.ArrayBuffer{} = part), do: Web.ArrayBuffer.data(part)
  defp normalize_part(part), do: part

  defp part_size(part) when is_binary(part), do: byte_size(part)
  defp part_size(%__MODULE__{size: size}), do: size

  defp normalize_type(nil), do: ""

  defp normalize_type(type) do
    type
    |> to_string()
    |> String.downcase()
  end

  defp slice_parts(_parts, _start, 0), do: []

  defp slice_parts(parts, start, span) do
    end_pos = start + span

    parts
    |> Enum.reduce({0, []}, &slice_part(&1, &2, start, end_pos))
    |> elem(1)
    |> Enum.reverse()
  end

  defp slice_part(part, {offset, acc}, start, end_pos) do
    part_len = part_size(part)
    part_start = offset
    part_end = offset + part_len

    if part_end <= start or part_start >= end_pos do
      {part_end, acc}
    else
      sliced_part = build_sliced_part(part, part_start, part_len, start, end_pos)
      {part_end, [sliced_part | acc]}
    end
  end

  defp build_sliced_part(part, part_start, part_len, start, end_pos) do
    local_start = max(start - part_start, 0)
    local_end = min(end_pos - part_start, part_len)
    len = local_end - local_start

    case part do
      bin when is_binary(bin) -> binary_part(bin, local_start, len)
      %__MODULE__{} = blob -> slice(blob, local_start, local_start + len, blob.type)
    end
  end

  defp normalize_index(index, size) when index < 0, do: max(size + index, 0)
  defp normalize_index(index, size), do: min(index, size)
end
