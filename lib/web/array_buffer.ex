defmodule Web.ArrayBuffer do
  @moduledoc """
  An `ArrayBuffer`: a sequence of bytes with a fixed length.

  A buffer is a struct around a binary. The BEAM shares a large binary
  between processes by reference, thus a buffer needs no table and no
  process, and the VM collects it as each other term.

  ## Detached buffers

  A buffer can be detached, as in ECMAScript. These operations detach a
  buffer:

    * `transfer/1` and `transfer/2`;
    * a transfer with `Web.structured_clone/2` or with a message port;
    * a read with `Web.ReadableStreamBYOBReader`.

  All the copies of the struct on the same node see the detached state. Use
  `data/1` and `byte_length/1` to read a buffer: `data/1` raises
  `Web.TypeError` for a detached buffer. The field `:data` of the struct does
  not show the detached state.

  The detached state is one flag in an `:atomics` array. The VM collects the
  flag together with the last copy of the struct. A struct that came from a
  different node has no flag on this node, and is never detached here.

  ## Examples

      iex> buffer = Web.ArrayBuffer.new("hello")
      iex> moved = Web.ArrayBuffer.transfer(buffer)
      iex> {Web.ArrayBuffer.data(moved), Web.ArrayBuffer.detached?(buffer)}
      {"hello", true}
      iex> Web.ArrayBuffer.byte_length(buffer)
      0
  """

  alias Web.TypeError

  @enforce_keys [:id, :data, :byte_length]
  defstruct [:id, :data, :byte_length]

  @type t :: %__MODULE__{
          id: reference() | nil,
          data: binary(),
          byte_length: non_neg_integer()
        }

  @detached 1

  @doc """
  Creates a new ArrayBuffer from a binary or from a byte length.

  ## Examples

      iex> buffer = Web.ArrayBuffer.new("hello")
      iex> {Web.ArrayBuffer.data(buffer), Web.ArrayBuffer.byte_length(buffer)}
      {"hello", 5}

      iex> buffer = Web.ArrayBuffer.new(4)
      iex> {Web.ArrayBuffer.data(buffer), Web.ArrayBuffer.byte_length(buffer)}
      {<<0, 0, 0, 0>>, 4}
  """
  @spec new(binary() | non_neg_integer()) :: t()
  def new(data) when is_binary(data) do
    %__MODULE__{id: new_flag(), data: data, byte_length: byte_size(data)}
  end

  def new(byte_length) when is_integer(byte_length) and byte_length >= 0 do
    new(:binary.copy(<<0>>, byte_length))
  end

  def new(other) do
    raise TypeError,
          "ArrayBuffer input must be a binary or a byte length, got: #{inspect(other)}"
  end

  @doc """
  Returns the bytes of the buffer.

  Raises `Web.TypeError` when the buffer is detached.
  """
  @spec data(t()) :: binary()
  def data(%__MODULE__{} = buffer) do
    if detached?(buffer) do
      raise TypeError.exception("Cannot access a detached ArrayBuffer")
    else
      buffer.data
    end
  end

  @doc """
  Returns the byte length of the buffer. A detached buffer has the length 0.
  """
  @spec byte_length(t()) :: non_neg_integer()
  def byte_length(%__MODULE__{} = buffer) do
    if detached?(buffer), do: 0, else: buffer.byte_length
  end

  @doc """
  Returns `true` if the buffer is detached.
  """
  @spec detached?(t()) :: boolean()
  def detached?(%__MODULE__{id: id}) when is_reference(id) do
    :atomics.get(id, 1) == @detached
  rescue
    # The struct came from a different node. Its flag is not on this node.
    ArgumentError -> false
  end

  def detached?(%__MODULE__{}), do: false

  @doc """
  Detaches the buffer and returns it with no bytes.

  All the copies of the struct on this node become detached.
  """
  @spec detach(t()) :: t()
  def detach(%__MODULE__{id: id} = buffer) do
    if is_reference(id), do: set_detached(id)
    %{buffer | data: <<>>, byte_length: 0}
  end

  @doc """
  Moves the bytes to a new buffer and detaches this buffer, as
  `ArrayBuffer.prototype.transfer()` of ECMAScript.

  With `new_length`, the new buffer has that length: the bytes are cut, or
  zero bytes are added.

  Raises `Web.TypeError` when the buffer is detached.

  ## Examples

      iex> buffer = Web.ArrayBuffer.new("hello")
      iex> Web.ArrayBuffer.data(Web.ArrayBuffer.transfer(buffer, 2))
      "he"

      iex> buffer = Web.ArrayBuffer.new("hi")
      iex> Web.ArrayBuffer.data(Web.ArrayBuffer.transfer(buffer, 4))
      <<"hi", 0, 0>>
  """
  @spec transfer(t(), non_neg_integer() | nil) :: t()
  def transfer(buffer, new_length \\ nil)

  def transfer(%__MODULE__{} = buffer, new_length)
      when is_nil(new_length) or (is_integer(new_length) and new_length >= 0) do
    if detached?(buffer) do
      raise TypeError.exception("Cannot transfer a detached ArrayBuffer")
    end

    data = resize(buffer.data, new_length)
    _detached = detach(buffer)
    new(data)
  end

  def transfer(%__MODULE__{}, new_length) do
    raise TypeError, "Invalid ArrayBuffer length: #{inspect(new_length)}"
  end

  @doc false
  # Returns the buffer with `chunk` at the byte offset. The length of the
  # buffer does not change. Only the one holder of a buffer can use this
  # function, because the result has the same identity.
  @spec replace(t(), non_neg_integer(), binary()) :: t()
  def replace(%__MODULE__{data: data} = buffer, offset, chunk)
      when is_integer(offset) and offset >= 0 and is_binary(chunk) and
             offset + byte_size(chunk) <= byte_size(data) do
    case {offset, byte_size(chunk) == byte_size(data)} do
      # The chunk is the full buffer. No copy is necessary.
      {0, true} ->
        %{buffer | data: chunk}

      _other ->
        tail_start = offset + byte_size(chunk)
        tail = binary_part(data, tail_start, byte_size(data) - tail_start)
        %{buffer | data: IO.iodata_to_binary([binary_part(data, 0, offset), chunk, tail])}
    end
  end

  @doc false
  @spec identity(t()) :: reference() | nil
  def identity(%__MODULE__{} = buffer), do: buffer.id

  # A new `:atomics` array has the value 0 in each slot: the buffer is attached.
  defp new_flag, do: :atomics.new(1, signed: false)

  defp set_detached(flag) do
    :atomics.put(flag, 1, @detached)
  rescue
    # The struct came from a different node. Its flag is not on this node.
    ArgumentError -> :ok
  end

  defp resize(data, nil), do: data
  defp resize(data, length) when length <= byte_size(data), do: binary_part(data, 0, length)
  defp resize(data, length), do: data <> :binary.copy(<<0>>, length - byte_size(data))
end
