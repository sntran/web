use Web

# 1. Create an "Infinite" producer of log lines
source =
  ReadableStream.from(
    Stream.repeatedly(fn ->
      "LOG EVENT: #{DateTime.utc_now()} - System healthy\n"
    end)
  )

# 2. Setup an AbortController for the "Emergency Stop"
controller = AbortController.new()

# 3. Define the pipeline: Source -> Compression (Gzip) -> Screen
# We use pipe_through to demonstrate how backpressure propagates
# through the compression Agent.
task =
  Task.async(fn ->
    try do
      source
      |> ReadableStream.pipe_through(CompressionStream.new("gzip"), signal: controller.signal)
      |> Enum.each(fn _chunk ->
        # In a real app, this would be a socket or file.
        # Here, we just show that data is flowing.
        IO.write(".")
      end)

      :ok
    rescue
      Web.TypeError ->
        :aborted
    end
  end)

# 4. Simulate a sudden system overload or user intervention
Process.sleep(2000)
IO.puts("\n\n[MAIN] TRIGGERING EMERGENCY ABORT...")

# Thanks to OTP 28 Priority Messaging, this signal jumps to the head
# of the mailbox even if the stream is saturated with Gzip chunks.
AbortController.abort(controller, "Operator shutdown")

case Task.yield(task, 500) do
  {:ok, :ok} -> IO.puts("[MAIN] Pipeline shut down gracefully and instantly.")
  {:ok, :aborted} -> IO.puts("[MAIN] Pipeline aborted cleanly after the emergency stop.")
  nil -> IO.puts("[MAIN] ERROR: Pipeline did not respond to high-priority signal!")
end
