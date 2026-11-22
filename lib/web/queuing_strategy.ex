defmodule Web.ByteLengthQueuingStrategy do
  @moduledoc """
  A queuing strategy that measures a chunk by its number of bytes, as
  `ByteLengthQueuingStrategy` of the Streams Standard.

  The two attributes of the Standard are the fields of the struct:

    * `high_water_mark` - the attribute `highWaterMark`.
    * `size` - the attribute `size`: a function that gives the byte length
      of a chunk, as the attribute `byteLength`. It is the size of a binary,
      or the field `:byte_length` of a map, for example of a
      `Web.Uint8Array`. A `Web.ArrayBuffer` gives its length. A chunk with
      no byte length gives `nil`, as `undefined` in the Standard. The
      function raises `Web.TypeError` for `nil`. Each strategy has the same
      function, as in the Standard.

  Thus the struct is also a dictionary `QueuingStrategy`: give it to the
  constructor of a stream as the strategy.

  ## Examples

      iex> strategy = Web.ByteLengthQueuingStrategy.new(high_water_mark: 4)
      iex> strategy.high_water_mark
      4
      iex> strategy.size.("hey")
      3

      iex> strategy = Web.ByteLengthQueuingStrategy.new(high_water_mark: 4)
      iex> source = %{start: fn controller -> Web.ReadableStreamDefaultController.enqueue(controller, "hey") end}
      iex> stream = Web.ReadableStream.new(source, strategy)
      iex> reader = Web.ReadableStream.get_reader(stream)
      iex> Web.await(Web.ReadableStreamDefaultReader.read(reader))
      %{value: "hey", done: false}
  """
  defstruct high_water_mark: 1, size: &Web.ByteLengthQueuingStrategy.__size__/1

  alias Web.Internal.QueuingStrategy

  @type t :: %__MODULE__{
          high_water_mark: Web.CountQueuingStrategy.high_water_mark(),
          size: (term() -> term())
        }

  @doc """
  Makes a strategy, as `new ByteLengthQueuingStrategy(init)`.

  The argument is the dictionary `QueuingStrategyInit`: a keyword list or a
  map with the key `:high_water_mark`, the limit in bytes. The strategy
  keeps the limit with no check, as the Streams Standard specifies:
  `:infinity`, `:neg_infinity`, and `:nan` are the values `Infinity`,
  `-Infinity`, and `NaN`. The constructor of a stream refuses a limit that
  is NaN or below zero with `Web.RangeError`.

  Raises `Web.TypeError` for an argument that is not a dictionary, with no
  key `:high_water_mark`, or with a value that is not a number.
  """
  @spec new(keyword() | map()) :: t()
  def new(init) do
    %__MODULE__{high_water_mark: QueuingStrategy.init!(init)}
  end

  @doc false
  # The function of the attribute `size`: see the field `size`.
  def __size__(chunk) when is_binary(chunk), do: byte_size(chunk)
  def __size__(%Web.ArrayBuffer{} = buffer), do: Web.ArrayBuffer.byte_length(buffer)
  def __size__(%{byte_length: byte_length}), do: byte_length

  def __size__(nil) do
    raise Web.TypeError, "Cannot read the byte length of nil."
  end

  def __size__(_chunk), do: nil
end

defmodule Web.CountQueuingStrategy do
  @moduledoc """
  A queuing strategy that counts each chunk as 1, as `CountQueuingStrategy`
  of the Streams Standard. This is the default strategy.

  The two attributes of the Standard are the fields of the struct:

    * `high_water_mark` - the attribute `highWaterMark`.
    * `size` - the attribute `size`: a function that gives 1 for each chunk.
      Each strategy has the same function, as in the Standard.

  Thus the struct is also a dictionary `QueuingStrategy`: give it to the
  constructor of a stream as the strategy.

  ## Examples

      iex> strategy = Web.CountQueuingStrategy.new(high_water_mark: 2)
      iex> strategy.high_water_mark
      2
      iex> strategy.size.("any chunk")
      1

      iex> strategy = Web.CountQueuingStrategy.new(high_water_mark: 2)
      iex> stream = Web.TransformStream.new(%{}, [], strategy)
      iex> writer = Web.WritableStream.get_writer(stream.writable)
      iex> Web.await(Web.WritableStreamDefaultWriter.write(writer, "chunk"))
      :ok
      iex> Web.await(Web.WritableStreamDefaultWriter.close(writer))
      :ok
      iex> Enum.to_list(stream.readable)
      ["chunk"]
  """
  defstruct high_water_mark: 1, size: &Web.CountQueuingStrategy.__size__/1

  alias Web.Internal.QueuingStrategy

  @typedoc """
  A high water mark: a number, or `:infinity`, `:neg_infinity`, or `:nan`
  for the values `Infinity`, `-Infinity`, and `NaN`.
  """
  @type high_water_mark :: number() | :infinity | :neg_infinity | :nan

  @type t :: %__MODULE__{high_water_mark: high_water_mark(), size: (term() -> 1)}

  @doc """
  Makes a strategy, as `new CountQueuingStrategy(init)`.

  The argument is the dictionary `QueuingStrategyInit`: a keyword list or a
  map with the key `:high_water_mark`, the limit in chunks. The strategy
  keeps the limit with no check, as the Streams Standard specifies. The
  constructor of a stream refuses a limit that is NaN or below zero with
  `Web.RangeError`.

  Raises `Web.TypeError` for an argument that is not a dictionary, with no
  key `:high_water_mark`, or with a value that is not a number.
  """
  @spec new(keyword() | map()) :: t()
  def new(init) do
    %__MODULE__{high_water_mark: QueuingStrategy.init!(init)}
  end

  @doc false
  # The function of the attribute `size`: see the field `size`.
  def __size__(_chunk), do: 1
end
