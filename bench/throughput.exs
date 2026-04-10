Mix.Task.run("app.start")
Code.require_file("support/gzip_bench_stream.exs", __DIR__)

defmodule Web.Benchmarks.Throughput do
  @moduledoc false

  import Web, only: [await: 1]

  alias Web.Bench.GzipBenchStream
  alias Web.CompressionStream
  alias Web.ReadableStream
  alias Web.Response

  @bytes 32 * 1024 * 1024
  @chunk_size 64 * 1024
  @chunk_count div(@bytes, @chunk_size)
  @chunk :binary.copy(<<"a">>, @chunk_size)

  def run do
    Benchee.run(
      %{
        "inline zlib stream" => fn -> run_pipeline(&GzipBenchStream.new/0) end,
        "CompressionStream" => fn -> run_pipeline(fn -> CompressionStream.new("gzip") end) end
      },
      time: 3,
      memory_time: 1,
      parallel: 1,
      formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
    )
  end

  defp run_pipeline(factory) do
    stream = factory.()
    source = ReadableStream.from(Stream.duplicate(@chunk, @chunk_count))
    compressed = ReadableStream.pipe_through(source, stream)
    _ = await(Response.bytes(Response.new(body: compressed)))
  end
end

Web.Benchmarks.Throughput.run()
