defmodule LineTransformStream do
  @moduledoc """
  Example `TransformStream` that emits one chunk per delimited line.

  Incoming chunks are buffered until the configured delimiter appears. Complete
  lines are emitted without the delimiter, and any trailing partial line is
  flushed when the writable side closes.
  """

  alias Web.ReadableStreamDefaultController
  alias Web.TransformStream
  alias Web.TypeError

  defstruct [:readable, :writable]

  @type t :: %__MODULE__{
          readable: Web.ReadableStream.t(),
          writable: Web.WritableStream.t()
        }

  @spec new(binary()) :: t()
  def new(delimiter \\ "\r\n")

  def new(delimiter) when is_binary(delimiter) and delimiter != "" do
    {:ok, buffer_pid} = Agent.start_link(fn -> "" end)

    stream =
      TransformStream.new(%{
        transform: fn chunk, controller ->
          binary = normalize_chunk!(chunk)

          lines =
            Agent.get_and_update(buffer_pid, fn buffer ->
              split_complete_lines(buffer <> binary, delimiter)
            end)

          Enum.each(lines, fn line ->
            ReadableStreamDefaultController.enqueue(controller, line)
          end)

          :ok
        end,
        flush: fn controller ->
          rest = Agent.get_and_update(buffer_pid, fn buffer -> {buffer, ""} end)

          if rest != "" do
            ReadableStreamDefaultController.enqueue(controller, rest)
          end

          stop_buffer(buffer_pid)
          :ok
        end,
        cancel: fn _reason ->
          stop_buffer(buffer_pid)
        end
      })

    %__MODULE__{readable: stream.readable, writable: stream.writable}
  end

  def new(_delimiter) do
    raise TypeError.exception("LineTransformStream delimiter must be a non-empty binary")
  end

  defp normalize_chunk!(chunk) when is_binary(chunk), do: chunk

  defp normalize_chunk!(chunk) do
    IO.iodata_to_binary(chunk)
  rescue
    _error -> raise TypeError.exception("LineTransformStream chunks must be binary or iodata")
  end

  defp split_complete_lines(buffer, delimiter) do
    do_split_complete_lines(buffer, delimiter, [])
  end

  defp do_split_complete_lines(buffer, delimiter, lines) do
    case :binary.match(buffer, delimiter) do
      {index, delimiter_size} ->
        line = binary_part(buffer, 0, index)
        rest_offset = index + delimiter_size
        rest = binary_part(buffer, rest_offset, byte_size(buffer) - rest_offset)
        do_split_complete_lines(rest, delimiter, [line | lines])

      :nomatch ->
        {Enum.reverse(lines), buffer}
    end
  end

  defp stop_buffer(buffer_pid) do
    if Process.alive?(buffer_pid) do
      Agent.stop(buffer_pid)
    end

    :ok
  end
end
