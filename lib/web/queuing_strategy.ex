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

  @type t :: %__MODULE__{high_water_mark: number()}

  @doc """
  Makes a strategy with the given limit in bytes. Raises `Web.RangeError` for
  a limit that is not a number, or that is below zero.
  """
  @spec new(number()) :: t()
  def new(high_water_mark) do
    %__MODULE__{
      high_water_mark: Web.CountQueuingStrategy.validate_high_water_mark!(high_water_mark)
    }
  end

  @doc """
  Returns the number of bytes of a chunk: a binary, a `Web.Uint8Array`, or a
  `Web.ArrayBuffer`.
  """
  @spec size(binary() | Web.Uint8Array.t() | Web.ArrayBuffer.t()) :: non_neg_integer()
  def size(chunk) when is_binary(chunk), do: byte_size(chunk)
  def size(%Web.Uint8Array{byte_length: byte_length}), do: byte_length
  def size(%Web.ArrayBuffer{} = buffer), do: Web.ArrayBuffer.byte_length(buffer)
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

  @type t :: %__MODULE__{high_water_mark: number()}

  @doc """
  Makes a strategy with the given limit in chunks. Raises `Web.RangeError`
  for a limit that is not a number, or that is below zero.
  """
  @spec new(number()) :: t()
  def new(high_water_mark) do
    %__MODULE__{high_water_mark: validate_high_water_mark!(high_water_mark)}
  end

  @doc """
  Returns 1 for each chunk.
  """
  @spec size(term()) :: 1
  def size(_chunk), do: 1

  @doc false
  # The Streams Standard refuses a limit that is not a number or that is
  # below zero.
  def validate_high_water_mark!(high_water_mark)
      when is_number(high_water_mark) and high_water_mark >= 0,
      do: high_water_mark

  def validate_high_water_mark!(high_water_mark) do
    raise Web.RangeError, "Invalid high water mark: #{inspect(high_water_mark)}"
  end
end
