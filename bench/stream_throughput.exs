Mix.Task.run("app.start")

defmodule Web.Benchmarks.StreamThroughput do
  @moduledoc false

  # The speed of a stream, and the memory of the VM during the read:
  #
  #   * a readable stream that a process reads with `Enum`;
  #   * the same stream through one transform stream;
  #   * a response body from an HTTP server on this machine, with `fetch`.
  #
  # Usage: mix run bench/stream_throughput.exs

  @chunk_size 64 * 1024
  @chunks 8_192

  def run do
    IO.puts("bytes=#{@chunks * @chunk_size} chunk_bytes=#{@chunk_size}")
    report("readable stream", fn -> source() end)

    report("through a transform stream", fn ->
      Web.ReadableStream.pipe_through(source(), Web.TransformStream.new())
    end)

    url = start_server()
    report("fetch from this machine", fn -> Web.await(Web.fetch(url)).body end)
  end

  defp source do
    chunk = :binary.copy(<<0>>, @chunk_size)
    Web.ReadableStream.from(Stream.map(1..@chunks, fn _index -> chunk end))
  end

  defp report(label, make) do
    :erlang.garbage_collect()
    start = :erlang.memory(:total)

    {time, {bytes, count, peak}} =
      :timer.tc(fn ->
        Enum.reduce(make.(), {0, 0, 0}, fn chunk, {bytes, count, peak} ->
          peak = if rem(count, 256) == 0, do: max(peak, :erlang.memory(:total)), else: peak
          {bytes + size(chunk), count + 1, peak}
        end)
      end)

    seconds = time / 1_000_000

    IO.puts(
      "#{label}: mib_per_second=#{round(bytes / 1_048_576 / seconds)} " <>
        "chunks_per_second=#{round(count / seconds)} " <>
        "memory_increase_mib=#{Float.round(max(peak - start, 0) / 1_048_576, 1)}"
    )
  end

  # A stream from an enumerable gives its elements with no change. A body
  # gives `Web.Uint8Array` chunks.
  defp size(chunk) when is_binary(chunk), do: byte_size(chunk)
  defp size(%Web.Uint8Array{byte_length: length}), do: length

  # A server that sends the bytes with a content length.
  defp start_server do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      {:ok, _request} = :gen_tcp.recv(socket, 0)
      chunk = :binary.copy(<<0>>, @chunk_size)
      length = @chunks * @chunk_size
      :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: #{length}\r\n\r\n")
      Enum.each(1..@chunks, fn _index -> :gen_tcp.send(socket, chunk) end)
      Process.sleep(:infinity)
    end)

    "http://127.0.0.1:#{port}/"
  end
end

Web.Benchmarks.StreamThroughput.run()
