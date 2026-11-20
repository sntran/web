defmodule Web.ByteLengthQueuingStrategy do
  @moduledoc """
  A queuing strategy that measures a chunk by its number of bytes, as
  `ByteLengthQueuingStrategy` of the Streams Standard.

  ## Examples

      iex> strategy = Web.ByteLengthQueuingStrategy.new(4)
      iex> strategy.high_water_mark
      4
      iex> Web.ByteLengthQueuingStrategy.size("hey")
      3

      iex> strategy = Web.ByteLengthQueuingStrategy.new(4)
      iex> {:ok, pid} = Web.Stream.start_link(Web.ReadableStream, strategy: strategy, high_water_mark: 4)
      iex> Web.ReadableStream.enqueue(pid, "hey")
      :ok
      iex> Web.ReadableStream.close(pid)
      :ok
      iex> Enum.to_list(%Web.ReadableStream{controller_pid: pid})
      ["hey"]
  """
  defstruct high_water_mark: 1

  @type t :: %__MODULE__{high_water_mark: Web.CountQueuingStrategy.high_water_mark()}

  @doc """
  Makes a strategy with the given limit in bytes.

  The strategy keeps the limit with no check, as the Streams Standard
  specifies: `:infinity`, `:neg_infinity`, and `:nan` are the values
  `Infinity`, `-Infinity`, and `NaN`. The constructor of a stream refuses a
  limit that is NaN or below zero with `Web.RangeError`. Raises
  `Web.TypeError` for a value that is not a number.
  """
  @spec new(Web.CountQueuingStrategy.high_water_mark()) :: t()
  def new(high_water_mark) do
    %__MODULE__{high_water_mark: Web.CountQueuingStrategy.__number__!(high_water_mark)}
  end

  @doc """
  Returns the number of bytes of a chunk, as the attribute `byteLength`:
  the size of a binary, or the field `:byte_length` of a map, for example
  of a `Web.Uint8Array`. A `Web.ArrayBuffer` gives its length.

  A chunk with no byte length gives `nil`, as `undefined` in the Standard.
  Raises `Web.TypeError` for `nil`.
  """
  @spec size(term()) :: term()
  def size(chunk) when is_binary(chunk), do: byte_size(chunk)
  def size(%Web.ArrayBuffer{} = buffer), do: Web.ArrayBuffer.byte_length(buffer)
  def size(%{byte_length: byte_length}), do: byte_length

  def size(nil) do
    raise Web.TypeError, "Cannot read the byte length of nil."
  end

  def size(_chunk), do: nil
end

defmodule Web.CountQueuingStrategy do
  @moduledoc """
  A queuing strategy that counts each chunk as 1, as `CountQueuingStrategy`
  of the Streams Standard. This is the default strategy.

  ## Examples

      iex> strategy = Web.CountQueuingStrategy.new(2)
      iex> strategy.high_water_mark
      2
      iex> Web.CountQueuingStrategy.size("any chunk")
      1

      iex> strategy = Web.CountQueuingStrategy.new(2)
      iex> stream = Web.TransformStream.new(%{}, readable_strategy: strategy)
      iex> writer = Web.WritableStream.get_writer(stream.writable)
      iex> Web.await(Web.WritableStreamDefaultWriter.write(writer, "chunk"))
      :ok
      iex> Web.await(Web.WritableStreamDefaultWriter.close(writer))
      :ok
      iex> Enum.to_list(stream.readable)
      ["chunk"]
  """
  defstruct high_water_mark: 1

  @typedoc """
  A high water mark: a number, or `:infinity`, `:neg_infinity`, or `:nan`
  for the values `Infinity`, `-Infinity`, and `NaN`.
  """
  @type high_water_mark :: number() | :infinity | :neg_infinity | :nan

  @type t :: %__MODULE__{high_water_mark: high_water_mark()}

  @doc """
  Makes a strategy with the given limit in chunks.

  The strategy keeps the limit with no check, as the Streams Standard
  specifies. The constructor of a stream refuses a limit that is NaN or
  below zero with `Web.RangeError`. Raises `Web.TypeError` for a value that
  is not a number.
  """
  @spec new(high_water_mark()) :: t()
  def new(high_water_mark) do
    %__MODULE__{high_water_mark: __number__!(high_water_mark)}
  end

  @doc """
  Returns 1. The function of the Streams Standard has no argument.
  """
  @spec size() :: 1
  def size, do: 1

  @doc """
  Returns 1 for each chunk.
  """
  @spec size(term()) :: 1
  def size(_chunk), do: 1

  @doc false
  # The value of the member `highWaterMark`: an unrestricted double of
  # WebIDL.
  def __number__!(value)
      when is_number(value) or value in [:infinity, :neg_infinity, :nan],
      do: value

  def __number__!(value) do
    raise Web.TypeError, "The high water mark must be a number, got: #{inspect(value)}"
  end
end
