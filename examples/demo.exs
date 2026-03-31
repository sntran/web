Mix.install([
  {:web, "~> 0.2.0"}
])

# Import the "Web-First" DSL
use Web

IO.puts("--- Starting Web v0.2.0 Demo ---")

# 1. Create a ReadableStream from a custom counter source
# This source logs every time the controller asks for more data via pull().
source = %{
  pull: fn controller ->
    # In some environments, we might need to initialize the count
    count = (Process.get(:demo_count) || 0) + 1
    Process.put(:demo_count, count)

    # Check backpressure signal from the controller
    ds = Web.ReadableStreamDefaultController.desired_size(controller)
    IO.puts("[Source] Pulling item ##{count} (Desired size: #{ds})")

    Web.ReadableStreamDefaultController.enqueue(controller, count)

    if count >= 10 do
      IO.puts("[Source] All items enqueued. Closing.")
      Web.ReadableStreamDefaultController.close(controller)
    end
  end
}

# High water mark of 1 means it will pull only when needed
stream = Web.ReadableStream.new(source)

# 2. tee() the stream into two independent branches
IO.puts("[System] Teeing the stream into Branch A and Branch B")
{branch_a, branch_b} = Web.ReadableStream.tee(stream)

# 3. Consume Branch A (The "Fast" reader)
# Branch A uses Elixir's Enumerable protocol (via Enum) to consume as fast as the source provides.
task_a =
  Task.async(fn ->
    IO.puts("[Branch A] Fast reader starting...")

    Enum.each(branch_a, fn val ->
      IO.puts("[Branch A] Received: #{val}")
    end)

    IO.puts("[Branch A] Finished.")
  end)

# 4. Consume Branch B (The "Slow" reader)
# Branch B uses a direct reader and introduces a delay, creating backpressure.
task_b =
  Task.async(fn ->
    IO.puts("[Branch B] Slow reader starting...")
    reader = Web.ReadableStream.get_reader(branch_b)

    consume = fn recursive_fn ->
      case Web.ReadableStreamDefaultReader.read(reader) do
        :done ->
          :ok

        val ->
          IO.puts("[Branch B] Received: #{val}. Processing for 1 second...")
          # Processing delay
          Process.sleep(1000)
          recursive_fn.(recursive_fn)
      end
    end

    consume.(consume)
    IO.puts("[Branch B] Finished.")
  end)

# 5. Wait for both tasks to finish
Task.await(task_a, 20_000)
Task.await(task_b, 20_000)

IO.puts("--- Demo Completed Successfully ---")
