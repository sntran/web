defmodule Web.Blob do
  @moduledoc """
  An immutable sequence of bytes with a type, as `Blob` of the File API.

  ## Examples

      iex> blob = Web.Blob.new(["hello", " ", "world"], type: "text/plain")
      iex> {blob.size, blob.type}
      {11, "text/plain"}

  The functions of this module also accept a `Web.File`, as `File` of the
  File API inherits from `Blob`.
  """

  alias Web.Internal.Bytes

  @enforce_keys [:id, :parts, :size, :type]
  defstruct [:id, :parts, :size, :type]

  @type blob_part ::
          binary() | t() | Web.File.t() | Web.Uint8Array.t() | Web.ArrayBuffer.t()
  @type t :: %__MODULE__{
          id: reference() | nil,
          parts: [binary() | t()],
          size: non_neg_integer(),
          type: String.t()
        }

  # The size of a chunk of `stream/1`.
  @chunk_size 65_536

  @doc """
  Creates a new Blob from parts and optional content type, as the
  constructor `new Blob(blobParts, options)` of the File API. With no
  parts, the blob is empty.

  The options are the members of `BlobPropertyBag`: `:type`, the type of
  the blob. The default is the empty string.

  A part is a binary, a `Web.Blob`, a `Web.File`, a `Web.Uint8Array`, or a
  `Web.ArrayBuffer`. The blob keeps a copy of the bytes of a view or a
  buffer, as the File API specifies.

  The type becomes ASCII lowercase. A type with a character outside the
  range U+0020 to U+007E becomes the empty string, as the constructor of
  the File API specifies.

  ## Examples

      iex> blob = Web.Blob.new(["a", Web.Uint8Array.from("bc"), Web.ArrayBuffer.new("d")])
      iex> {blob.size, Web.Blob.text(blob)}
      {4, {:ok, "abcd"}}

      iex> Web.Blob.new().size
      0

      iex> Web.Blob.new([], type: "Text/Plain").type
      "text/plain"

      iex> Web.Blob.new([], type: "image/gif\\t").type
      ""
  """
  @spec new([blob_part()], keyword()) :: t()
  def new(parts_list \\ [], opts \\ []) when is_list(parts_list) do
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
  Returns a new Blob with the bytes from `start` up to, but not including,
  `finish`, as `slice()` of the File API.

  A negative index counts from the end. An index that is `nil` is not
  given: the start is 0, and the end is the size. The content type
  follows the rules of the type of `new/2`.

  ## Examples

      iex> blob = Web.Blob.new(["hello world"])
      iex> blob |> Web.Blob.slice(-5) |> Web.Blob.text()
      {:ok, "world"}
      iex> blob |> Web.Blob.slice(nil, 5, "Text/Plain") |> Map.take([:size, :type])
      %{size: 5, type: "text/plain"}
  """
  @spec slice(t() | Web.File.t(), integer() | nil, integer() | nil, String.t() | nil) :: t()
  def slice(blob, start \\ nil, finish \\ nil, content_type \\ nil)

  def slice(%Web.File{} = file, start, finish, content_type),
    do: file |> from_file() |> slice(start, finish, content_type)

  def slice(%__MODULE__{} = blob, start, finish, content_type)
      when (is_integer(start) or is_nil(start)) and (is_integer(finish) or is_nil(finish)) do
    size = blob.size
    relative_start = normalize_index(start || 0, size)

    relative_end =
      case finish do
        nil -> size
        value -> normalize_index(value, size)
      end

    span = max(relative_end - relative_start, 0)
    parts = slice_parts(blob.parts, relative_start, span)

    new(parts, type: content_type || "")
  end

  @doc false
  @spec to_binary(t() | Web.File.t()) :: binary()
  def to_binary(%Web.File{} = file), do: file |> from_file() |> to_binary()

  def to_binary(%__MODULE__{parts: parts}) do
    parts
    |> Enum.map(fn
      part when is_binary(part) -> part
      %__MODULE__{} = blob -> to_binary(blob)
    end)
    |> IO.iodata_to_binary()
  end

  @doc """
  Returns a readable byte stream of the bytes of the blob, as `stream()` of
  the File API. Each chunk is a `Web.Uint8Array` with the bytes of one
  part, at most 64 KiB. A reader of the mode `"byob"` can read the stream.
  """
  @spec stream(t() | Web.File.t()) :: Web.ReadableStream.t()
  def stream(%Web.File{} = file), do: file |> from_file() |> stream()

  def stream(%__MODULE__{} = blob) do
    # The parts with bytes, with no copy of the bytes. The position of the
    # next chunk is the index of a part and the offset in the part: the
    # function `pull` of each read uses it, and the stream can call `pull`
    # from different processes.
    parts = blob |> binary_parts() |> Enum.reject(&(&1 == "")) |> List.to_tuple()
    position = :atomics.new(2, signed: false)

    Web.ReadableStream.new(%{
      type: "bytes",
      pull: fn controller -> pull_chunk(controller, parts, position) end
    })
  end

  defp binary_parts(%__MODULE__{parts: parts}) do
    Enum.flat_map(parts, fn
      part when is_binary(part) -> [part]
      %__MODULE__{} = blob -> binary_parts(blob)
    end)
  end

  defp pull_chunk(controller, parts, position) do
    index = :atomics.get(position, 1)

    if index == tuple_size(parts) do
      Web.ReadableByteStreamController.close(controller)
      respond_end(Web.ReadableByteStreamController.byob_request(controller))
    else
      part = elem(parts, index)
      offset = :atomics.get(position, 2)
      length = min(@chunk_size, byte_size(part) - offset)

      if offset + length == byte_size(part) do
        :atomics.put(position, 1, index + 1)
        :atomics.put(position, 2, 0)
      else
        :atomics.put(position, 2, offset + length)
      end

      chunk = binary_part(part, offset, length)
      Web.ReadableByteStreamController.enqueue(controller, Web.Uint8Array.from(chunk))
    end
  end

  # A BYOB read that waits at the end of the bytes gets the end of the
  # stream with its view.
  defp respond_end(nil), do: :ok
  defp respond_end(request), do: Web.ReadableStreamBYOBRequest.respond(request, 0)

  @doc """
  Returns a readable stream of the text of the blob, as `textStream()` of
  the File API. The stream decodes the bytes as UTF-8, and ignores the
  charset of the type. Each chunk is a string.

  ## Examples

      iex> blob = Web.Blob.new(["caf", <<0xC3>>, <<0xA9>>], type: "text/plain;charset=latin1")
      iex> blob |> Web.Blob.text_stream() |> Enum.join()
      "café"
  """
  @spec text_stream(t() | Web.File.t()) :: Web.ReadableStream.t()
  def text_stream(blob) do
    blob
    |> stream()
    |> Web.ReadableStream.pipe_through(Web.TextDecoderStream.new("utf-8"))
  end

  @doc """
  Reads the contents of the blob as text, as `text()` of the File API: the
  UTF-8 decode of the bytes. A byte order mark goes away, and each byte
  sequence that is not valid UTF-8 becomes U+FFFD.

  ## Examples

      iex> Web.Blob.text(Web.Blob.new([<<0xEF, 0xBB, 0xBF>>, "caf", <<0xC3, 0xA9>>, <<0xFF>>]))
      {:ok, "café�"}
  """
  @spec text(t() | Web.File.t()) :: {:ok, String.t()}
  def text(blob) do
    {:ok, blob |> to_binary() |> Web.TextDecoder.decode_utf8()}
  end

  @doc """
  Reads Blob contents as ArrayBuffer.
  """
  @spec array_buffer(t() | Web.File.t()) :: {:ok, Web.ArrayBuffer.t()}
  def array_buffer(blob) do
    {:ok, blob |> to_binary() |> Web.ArrayBuffer.new()}
  end

  @doc """
  Reads Blob contents as Uint8Array.
  """
  @spec bytes(t() | Web.File.t()) :: {:ok, Web.Uint8Array.t()}
  def bytes(blob) do
    with {:ok, array_buffer} <- array_buffer(blob) do
      {:ok, Web.Uint8Array.new(array_buffer)}
    end
  end

  # A file is a blob with a name. A file from a form stream has its bytes
  # in that stream: the stream gives them.
  defp from_file(%Web.File{stream: nil} = file) do
    %__MODULE__{id: file.id, parts: file.parts, size: file.size || 0, type: file.type}
  end

  defp from_file(%Web.File{} = file) do
    bytes =
      file
      |> Web.File.stream()
      |> Enum.map(&Bytes.to_binary!(&1, "The stream of a file"))
      |> IO.iodata_to_binary()

    %__MODULE__{id: file.id, parts: [bytes], size: byte_size(bytes), type: file.type}
  end

  defp normalize_part(%Web.Uint8Array{} = part), do: Web.Uint8Array.to_binary(part)
  defp normalize_part(%Web.ArrayBuffer{} = part), do: Web.ArrayBuffer.data(part)
  defp normalize_part(%Web.File{} = part), do: from_file(part)
  defp normalize_part(part), do: part

  defp part_size(part) when is_binary(part), do: byte_size(part)
  defp part_size(%__MODULE__{size: size}), do: size

  defp normalize_type(nil), do: ""

  defp normalize_type(type) do
    type = to_string(type)

    if printable_ascii?(type), do: ascii_downcase(type), else: ""
  end

  defp printable_ascii?(<<char, rest::binary>>) when char in 0x20..0x7E,
    do: printable_ascii?(rest)

  defp printable_ascii?(<<>>), do: true
  defp printable_ascii?(_type), do: false

  defp ascii_downcase(type) do
    for <<char <- type>>, into: "", do: <<if(char in ?A..?Z, do: char + 32, else: char)>>
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
