defmodule Web.ByteLengthQueuingStrategy do
  @moduledoc """
  A byte-based queuing strategy for stream backpressure.

  The stream engine uses `size/1` to measure how much capacity a chunk consumes.
  This strategy treats each chunk's byte length as its size, which is useful when
  queue pressure should reflect the amount of binary data buffered rather than the
  number of chunks.

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

  def new(hwm), do: %__MODULE__{high_water_mark: hwm}
  def size(chunk), do: byte_size(chunk)
end

defmodule Web.CountQueuingStrategy do
  @moduledoc """
  A chunk-count-based queuing strategy for stream backpressure.

  This is the default strategy used by the stream engine. Each enqueued chunk
  consumes exactly `1` unit of capacity regardless of its contents.

  ## Examples

      iex> strategy = Web.CountQueuingStrategy.new(2)
      iex> strategy.high_water_mark
      2
      iex> Web.CountQueuingStrategy.size("any chunk")
      1

      iex> strategy = Web.CountQueuingStrategy.new(2)
      iex> stream = Web.TransformStream.new(%{}, high_water_mark: 2, writable_strategy: strategy)
      iex> writer = Web.WritableStream.get_writer(stream.writable)
      iex> Web.await(Web.WritableStreamDefaultWriter.write(writer, "chunk"))
      :ok
      iex> Web.await(Web.WritableStreamDefaultWriter.close(writer))
      :ok
      iex> Enum.to_list(stream.readable)
      ["chunk"]
  """
  defstruct high_water_mark: 1

  def new(hwm), do: %__MODULE__{high_water_mark: hwm}
  def size(_), do: 1
end
