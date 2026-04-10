use Web

# 1. A producer that generates a "heartbeat" every 100ms
# We use a 20-iteration limit so it finishes on its own if not aborted.
source =
  ReadableStream.from(
    Stream.map(1..20, fn i ->
      "Heartbeat #{i} [#{DateTime.utc_now()}]\n"
    end)
  )

IO.puts("--- STARTING ROUND-TRIP PIPELINE ---")

# 2. Build the pipeline:
# Producer -> Gzip -> Gunzip -> UTF-8 Decoder -> IO
source
|> ReadableStream.pipe_through(CompressionStream.new("gzip"))
|> ReadableStream.pipe_through(DecompressionStream.new("gzip"))
|> ReadableStream.pipe_through(TextDecoderStream.new())
|> Enum.each(fn decoded_text ->
  # Now you see the actual text immediately as it clears the engine
  IO.write(decoded_text)

  # Tiny sleep just to make the "streaming" effect visible to the eye
  Process.sleep(50)
end)

IO.puts("--- PIPELINE COMPLETED ---")
