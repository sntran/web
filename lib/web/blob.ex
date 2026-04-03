defmodule Web.Blob do
  @moduledoc """
  WHATWG-style immutable Blob representation.

  ## Examples

      iex> blob = Web.Blob.new(["hello", " ", "world"], type: "text/plain")
      iex> {blob.size, blob.type}
      {11, "text/plain"}
  """

  @enforce_keys [:parts, :size, :type]
  defstruct [:parts, :size, :type]

  @type blob_part :: binary() | t()
  @type t :: %__MODULE__{
          parts: [blob_part()],
          size: non_neg_integer(),
          type: String.t()
        }

  @doc """
  Creates a new Blob from parts and optional content type.
  """
  @spec new([blob_part()], keyword()) :: t()
  def new(parts_list, opts \\ []) when is_list(parts_list) do
    type = opts |> Keyword.get(:type, "") |> normalize_type()

    size =
      Enum.reduce(parts_list, 0, fn part, acc ->
        acc + part_size(part)
      end)

    %__MODULE__{parts: parts_list, size: size, type: type}
  end

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
  Returns a readable stream view over Blob parts.
  """
  @spec stream(t()) :: Web.ReadableStream.t()
  def stream(%__MODULE__{} = blob) do
    Web.ReadableStream.from(blob)
  end

  @doc """
  Reads Blob contents as text.
  """
  @spec text(t()) :: {:ok, binary()}
  def text(%__MODULE__{} = blob) do
    {:ok, to_binary(blob)}
  end

  @doc """
  Reads Blob contents and decodes JSON.
  """
  @spec json(t()) :: {:ok, any()} | {:error, any()}
  def json(%__MODULE__{} = blob) do
    with {:ok, binary} <- text(blob) do
      Jason.decode(binary)
    end
  end

  @doc """
  Reads Blob contents as ArrayBuffer.
  """
  @spec arrayBuffer(t()) :: {:ok, Web.ArrayBuffer.t()}
  def arrayBuffer(%__MODULE__{} = blob) do
    with {:ok, binary} <- text(blob) do
      {:ok, Web.ArrayBuffer.new(binary)}
    end
  end

  @doc """
  Reads Blob contents as Uint8Array.
  """
  @spec bytes(t()) :: {:ok, Web.Uint8Array.t()}
  def bytes(%__MODULE__{} = blob) do
    with {:ok, array_buffer} <- arrayBuffer(blob) do
      {:ok, Web.Uint8Array.new(array_buffer)}
    end
  end

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
    |> Enum.reduce({0, []}, fn part, {offset, acc} ->
      part_len = part_size(part)
      part_start = offset
      part_end = offset + part_len

      if part_end <= start or part_start >= end_pos do
        {part_end, acc}
      else
        local_start = max(start - part_start, 0)
        local_end = min(end_pos - part_start, part_len)
        len = local_end - local_start

        sliced_part =
          case part do
            bin when is_binary(bin) -> binary_part(bin, local_start, len)
            %__MODULE__{} = blob -> slice(blob, local_start, local_start + len, blob.type)
          end

        {part_end, [sliced_part | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp normalize_index(index, size) when index < 0, do: max(size + index, 0)
  defp normalize_index(index, size), do: min(index, size)
end
