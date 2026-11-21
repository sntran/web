Mix.Task.run("app.start")

defmodule Web.Benchmarks.FormDataMemory do
  @moduledoc false

  # A multipart form with one large file goes through the library in the
  # two directions, and the memory of the VM stays flat:
  #
  #   * parse: `Web.FormData.parse/2` reads a `multipart/form-data` body
  #     from a stream. The file of the form is a stream too;
  #   * encode: a `Web.FormData` with a file that has a stream is the body
  #     of a response. The body is a stream of `multipart/form-data` bytes.
  #
  # Usage: mix run bench/form_data_memory.exs

  alias Web.FormData

  @boundary "memory-boundary"
  @chunk_size 64 * 1024
  @chunks 16_384
  @sample_interval 256

  def run do
    IO.puts("file_bytes=#{@chunks * @chunk_size}")
    report("parse", fn -> parse() end)
    report("encode", fn -> encode() end)
  end

  defp report(label, fun) do
    :erlang.garbage_collect()
    start = :erlang.memory(:total)
    {time, {bytes, peak}} = :timer.tc(fun)

    IO.puts(
      "#{label}: bytes=#{bytes} seconds=#{Float.round(time / 1_000_000, 2)} " <>
        "memory_at_start=#{start} largest_memory=#{peak} increase=#{peak - start}"
    )
  end

  # The body of an upload, as a stream: the headers of the part, the bytes
  # of the file, and the last boundary.
  defp parse do
    headers =
      "--#{@boundary}\r\n" <>
        "Content-Disposition: form-data; name=\"upload\"; filename=\"large.bin\"\r\n" <>
        "Content-Type: application/octet-stream\r\n\r\n"

    body = Stream.concat([[headers], file_chunks(), ["\r\n--#{@boundary}--\r\n"]])

    body
    |> Web.ReadableStream.from()
    |> FormData.parse(@boundary)
    |> FormData.get("upload")
    |> Web.File.stream()
    |> count_bytes()
  end

  defp encode do
    # A file of the library that gives its bytes from a stream, as a file
    # of a parsed form does.
    file = Web.File.new([], "large.bin", type: "application/octet-stream")
    file = %{file | stream: Web.ReadableStream.from(file_chunks())}

    form = FormData.new(boundary: @boundary) |> FormData.append("upload", file)

    Web.Response.new(body: form).body
    |> count_bytes()
  end

  defp file_chunks do
    chunk = :binary.copy(<<0>>, @chunk_size)
    Stream.map(1..@chunks, fn _index -> chunk end)
  end

  # Reads the stream to its end. Returns the number of bytes, and the
  # largest memory of the VM during the read.
  defp count_bytes(stream) do
    {bytes, _count, peak} =
      Enum.reduce(stream, {0, 0, 0}, fn chunk, {bytes, count, peak} ->
        peak =
          if rem(count, @sample_interval) == 0 do
            max(peak, :erlang.memory(:total))
          else
            peak
          end

        {bytes + chunk.byte_length, count + 1, peak}
      end)

    {bytes, peak}
  end
end

Web.Benchmarks.FormDataMemory.run()
