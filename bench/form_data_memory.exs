Mix.Task.run("app.start")

defmodule Web.Benchmarks.FormDataMemory do
  @moduledoc false

  alias Web.FormData
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.ReadableStreamDefaultReader

  @boundary "memory-boundary"
  @chunk_size 64 * 1024
  @file_chunks 16_384
  @sample_interval 128

  def run do
    {stream, tracker} = source_stream()
    form_data = FormData.parse(stream, @boundary)
    file = FormData.get(form_data, "upload")
    file_stream = Web.File.stream(file)
    reader = ReadableStream.get_reader(file_stream)

    metrics = sample_read_loop(reader, form_data.coordinator, file_stream.controller_pid, tracker, 0, 0)

    IO.puts("""
    [Reader API] coordinator_pid=#{inspect(form_data.coordinator)}
    child_pid=#{inspect(file_stream.controller_pid)}
    source_pulls=#{metrics.source_pulls}
    bytes_read=#{metrics.bytes_read}
    max_coordinator_memory=#{metrics.max_coordinator_memory}
    max_child_memory=#{metrics.max_child_memory}
    """)
  end

  # Enumerable streaming bench: verifies O(1) coordinator memory while
  # iterating a 1 GB upload via `Enum.each` and reading the file stream inline.
  def run_enumerable do
    {stream, tracker} = source_stream()
    form_data = FormData.parse(stream, @boundary)

    max_coordinator_memory = :atomics.new(1, [])

    Enum.each(form_data, fn [_name, file] ->
      file
      |> Web.File.stream()
      |> Enum.each(fn chunk ->
        # Sample coordinator memory every @sample_interval chunks
        bytes = byte_size(chunk)
        if rem(bytes, @chunk_size * @sample_interval) == 0 do
          mem = process_memory(form_data.coordinator)
          current = :atomics.get(max_coordinator_memory, 1)
          if mem > current, do: :atomics.put(max_coordinator_memory, 1, mem)
        end
      end)
    end)

    FormData.cancel(form_data)

    IO.puts("""
    [Enumerable API] coordinator_pid=#{inspect(form_data.coordinator)}
    source_pulls=#{Agent.get(tracker, & &1.pulls)}
    max_coordinator_memory=#{:atomics.get(max_coordinator_memory, 1)}
    """)
  end

  defp source_stream do
    {:ok, tracker} =
      Agent.start_link(fn ->
        %{
          phase: :opening,
          remaining_chunks: @file_chunks,
          pulls: 0
        }
      end)

    stream =
      ReadableStream.new(%{
        pull: fn controller ->
          {event, _next_state} = Agent.get_and_update(tracker, fn state ->
            {event, next_state} = next_chunk(state)
            {{event, next_state}, %{next_state | pulls: state.pulls + 1}}
          end)

          case event do
            {:chunk, chunk} -> ReadableStreamDefaultController.enqueue(controller, chunk)
            :close -> ReadableStreamDefaultController.close(controller)
          end
        end
      })

    {stream, tracker}
  end

  defp next_chunk(%{phase: :opening, remaining_chunks: remaining} = state) do
    headers =
      "--#{@boundary}\r\n" <>
        "Content-Disposition: form-data; name=\"upload\"; filename=\"large.bin\"\r\n" <>
        "Content-Type: application/octet-stream\r\n\r\n"

    {{:chunk, headers}, %{state | phase: :file, remaining_chunks: remaining}}
  end

  defp next_chunk(%{phase: :file, remaining_chunks: remaining} = state) when remaining > 1 do
    {{:chunk, :binary.copy(<<0>>, @chunk_size)}, %{state | remaining_chunks: remaining - 1}}
  end

  defp next_chunk(%{phase: :file, remaining_chunks: 1} = state) do
    closing = :binary.copy(<<0>>, @chunk_size) <> "\r\n--#{@boundary}--\r\n"
    {{:chunk, closing}, %{state | phase: :done, remaining_chunks: 0}}
  end

  defp next_chunk(%{phase: :done} = state) do
    {:close, state}
  end

  defp sample_read_loop(reader, coordinator_pid, child_pid, tracker, bytes_read, max_memory) do
    case ReadableStreamDefaultReader.read(reader) do
      :done ->
        %{
          bytes_read: bytes_read,
          source_pulls: Agent.get(tracker, & &1.pulls),
          max_coordinator_memory: max(max_memory, process_memory(coordinator_pid)),
          max_child_memory: process_memory(child_pid)
        }

      chunk ->
        next_bytes_read = bytes_read + byte_size(chunk)

        next_max_memory =
          if rem(div(next_bytes_read, @chunk_size), @sample_interval) == 0 do
            max(max_memory, process_memory(coordinator_pid))
          else
            max_memory
          end

        sample_read_loop(reader, coordinator_pid, child_pid, tracker, next_bytes_read, next_max_memory)
    end
  end

  defp process_memory(pid) do
    case Process.info(pid, :memory) do
      {:memory, memory} -> memory
      _ -> 0
    end
  end
end

Web.Benchmarks.FormDataMemory.run()
Web.Benchmarks.FormDataMemory.run_enumerable()
