# 🌐 Web: WHATWG Extension to BEAM
> A protocol-agnostic, zero-buffer suite of Web Standard APIs for Elixir.

[![Hex.pm](https://img.shields.io/hexpm/v/web.svg)](https://hex.pm/packages/web)
[![Docs](https://img.shields.io/badge/hexdocs-latest-blue.svg)](https://hexdocs.pm/web)

---

## 🚀 Why Web?
Most Elixir networking libraries buffer data into memory by default. `Web` is built for **Zero-Buffer Streaming**, ensuring your applications remain responsive and low-memory even when handling gigabytes of data.

By implementing WHATWG standards as **Native Process-backed** entities (`:gen_statem`), `Web` provides a consistent, predictable, and backpressure-aware interface for HTTP, TCP, and custom protocols.

## ⚡ Performance Notes
The current responsive-core work added ref-tagged control receives, local
priority signaling, and `:message_queue_data, :off_heap` for stream engines.
On the benchmark machine below, those changes materially improved the control
plane under mailbox pressure.

| Benchmark | Before (`fa74d7f`) | After (`9babea0`) | Result |
| --- | --- | --- | --- |
| Selective receive at 100k mailbox depth | 1.76 s | 2.78 ms | 99.84% faster |
| Selective receive at 10k mailbox depth | 123.00 ms | 0.79 ms | 99.36% faster |
| 100 MiB burst final heap size | 225,340 words | 4,264 words | 98.11% lower |
| 100 MiB burst peak queue length | 1,415 | 905 | 36.04% lower |

For the compression pipeline, `CompressionStream` averaged `263.68 ms`
for `32 MiB` of input on this machine, which is about `121.36 MB/s`.

For multipart routing workloads, the new
[`examples/streaming_upload_proxy.exs`](examples/streaming_upload_proxy.exs)
simulates a `1 GiB` upload and logs `:erlang.memory(:total)` checkpoints while
streaming from `Response.form_data/1` to a sink via `ReadableStream.pipe_to/3`.
On the benchmark machine, the memory profile stayed flat within normal BEAM GC
variance instead of scaling with payload size.

The abort-latency benchmark remains noisy and is documented in
[`BENCHMARKS.md`](BENCHMARKS.md) as a caveat instead of a headline claim.

---

## 🛠 The "Web-First" DSL
If you’ve used the modern Web API in a browser, you already know how to use this library. We've mapped those standards to idiomatic Elixir.

```elixir
defmodule GitHub do
  use Web

  def repositories(query \\ "elixir") do
    # 1. Standard URL manipulation
    url = URL.new("https://api.github.com/search/repositories")
    
    params = 
      URL.search_params(url)
      |> URLSearchParams.set("q", query)
      |> URLSearchParams.append("sort", "stars")

    url = URL.search(url, URLSearchParams.to_string(params))

    # 2. Construct a Request with automatic header inference
    request = Request.new(url, 
      method: "GET",
      headers: %{"Accept" => "application/vnd.github.v3+json"}
    )

    # 3. Fetch via Promise and await the response
    await fetch(request)
  end
end

response = GitHub.repositories()

# Zero-buffer streaming: chunks are written to stdout as they arrive
response.body 
|> Stream.take(5) 
|> Enum.each(&IO.write/1)
```

### `Web.Promise` and `await/1`
Async APIs now return `%Web.Promise{}` values so you can compose fetches, body
reads, and stream writes before awaiting the final result.

```elixir
use Web

response = await fetch("https://api.github.com/zen")

text = await Response.text(response)

pair = await Promise.all([
    Promise.resolve(:ok),
    Promise.resolve(text)
  ])
```

---

## 📖 API Usage & Examples

### `Web.Promise` — Async Composition
`Web.Promise` gives you a browser-style promise API for composing async work
before you call `await/1`.

```elixir
# Resolve and reject explicit values
ok = Promise.resolve("ready")
value = await(ok)
# => "ready"

fallback =
  Promise.reject(:boom)
  |> Promise.catch(fn reason -> "recovered: #{reason}" end)
  |> await()
# => "recovered: boom"

# Wait for every promise to resolve
results =
  Promise.all([
    Promise.resolve(1),
    Promise.resolve(2)
  ])
  |> await()
# => [1, 2]

# Collect fulfillment and rejection outcomes together
settled =
  Promise.all_settled([
    Promise.resolve("ok"),
    Promise.reject(:nope)
  ])
  |> await()
# => [%{status: "fulfilled", value: "ok"}, %{status: "rejected", reason: :nope}]

# Return the first fulfilled promise
winner =
  Promise.any([
    Promise.reject(:first_failed),
    Promise.resolve("winner")
  ])
  |> await()
# => "winner"

# Return the first settled promise
raced =
  Promise.race([
    Promise.resolve("fast"),
    Promise.resolve("slow")
  ])
  |> await()
# => "fast"
```

### `Web.ReadableStream` — The Source
The source of every streaming pipeline. A `ReadableStream` is a managed process that provides data to consumers, handling **Backpressure** (throttling producers when consumers are slow), **Locking** (ensuring exclusive access), and **Teeing** (splitting streams for multiple consumers) in a zero-copy, process-safe way.

```elixir
# Create a stream from any enumerable (List, File.stream, etc.)
stream = ReadableStream.from(["chunk1", "chunk2"])

# Split one stream into two independent branches (Zero-copy)
{branch_a, branch_b} = ReadableStream.tee(stream)

Task.start(fn -> Enum.each(branch_a, &process_data/1) end)
Task.start(fn -> Enum.each(branch_b, &log_data/1) end)
```

### `Web.WritableStream` — The Sink
Writable streams are endpoints for consuming data, supporting backpressure and lock management. Use them to write data from readable streams or directly from your application.

```elixir
# Get a writable stream (for example, from a custom stream or a network response)
writable = WritableStream.new()
writer = WritableStream.get_writer(writable)

# Write chunks to the stream
:ok = await(WritableStreamDefaultWriter.write(writer, "hello "))
:ok = await(WritableStreamDefaultWriter.write(writer, "world!"))

# Close and release
:ok = await(WritableStreamDefaultWriter.close(writer))
:ok = WritableStreamDefaultWriter.release_lock(writer)
```

### `Web.TransformStream` — Stream Processing
Transform streams allow you to process, modify, or filter data as it flows through a pipeline. They are ideal for tasks like compression, encryption, or counting bytes.

```elixir
transform = TransformStream.new(%{
  transform: fn chunk, controller ->
    # Example: uppercase transformation
    upper = String.upcase(IO.iodata_to_binary(chunk))
    ReadableStreamDefaultController.enqueue(controller, upper)
  end,
  flush: fn controller ->
    ReadableStreamDefaultController.close(controller)
  end
})

source = ReadableStream.from(["foo", "bar"])
upper = ReadableStream.pipe_through(source, transform)
output = await(Response.text(Response.new(body: upper)))
# => "FOOBAR"
```

### `Web.ByteLengthQueuingStrategy` and `Web.CountQueuingStrategy`
Use queuing strategies to control how stream backpressure is measured.
`CountQueuingStrategy` counts each chunk as `1`, while
`ByteLengthQueuingStrategy` measures buffered chunks by their byte size.

```elixir
count_strategy = Web.CountQueuingStrategy.new(16)
byte_strategy = Web.ByteLengthQueuingStrategy.new(1024)

stream = ReadableStream.new(%{strategy: count_strategy})
sink = WritableStream.new(%{high_water_mark: 16})
```

### `ReadableStream.pipe_to/3` & `ReadableStream.pipe_through/3`
Use `pipe_to/3` to connect a source to any writable sink with backpressure-awareness, and `pipe_through/3` to attach transforms while returning the next readable stage.

```elixir
source = ReadableStream.from(["hello", " world"])

transform = TransformStream.new(%{
  transform: fn chunk, controller ->
    ReadableStreamDefaultController.enqueue(controller, String.upcase(chunk))
  end,
  flush: fn controller ->
    ReadableStreamDefaultController.close(controller)
  end
})

# pipe_through returns the transformed readable side
upper = ReadableStream.pipe_through(source, transform)
output = await(Response.text(Response.new(body: upper)))
# => "HELLO WORLD"

# pipe_to returns a %Web.Promise{} you can await
sink = WritableStream.new(%{})
pipe = ReadableStream.pipe_to(ReadableStream.from(["a"]), sink)
:ok = await(pipe)
```

### `Web.TextEncoder`, `Web.TextDecoder`, and Their Stream Variants
Use the text encoding helpers to move between Elixir strings and UTF-8 byte
views while keeping streamed decoding safe across chunk boundaries.

```elixir
encoder = TextEncoder.new()
bytes = TextEncoder.encode(encoder, "Hello, 🌍")
Web.Uint8Array.to_binary(bytes)
# => "Hello, 🌍"

decoder = TextDecoder.new("utf-8", %{fatal: false})
TextDecoder.decode(decoder, bytes)
# => "Hello, 🌍"
```

The stream wrappers compose directly with `ReadableStream.pipe_through/3`
pipelines.

```elixir
source = ReadableStream.from(["Hello, ", "🌍"])

encoded =
  source
  |> ReadableStream.pipe_through(TextEncoderStream.new())
  |> ReadableStream.pipe_through(TextDecoderStream.new())

await(Response.text(Response.new(body: encoded)))
# => "Hello, 🌍"
```

### `Web.CompressionStream` and `Web.DecompressionStream`
Use the compression stream wrappers to compress or decompress byte streams
inside the same `ReadableStream.pipe_through/3` pipelines.

```elixir
source = ReadableStream.from(["hello world"])

compressed =
  source
  |> ReadableStream.pipe_through(CompressionStream.new("gzip"))

round_tripped =
  compressed
  |> ReadableStream.pipe_through(DecompressionStream.new("gzip"))

await(Response.text(Response.new(body: round_tripped)))
# => "hello world"
```

### `Web.Request` & `Web.Response`
First-class containers for network data with high-level factories and standard body readers.

```elixir
# High-level factories for common responses
res = Response.json(%{status: "ok"})
redirect = Response.redirect("https://elixir-lang.org")

# Automatic status and body readers
if res.ok do
  data = await(Response.json(res))
end

# Multi-protocol support (HTTP/TCP)
req = Request.new("tcp://localhost:8080", method: "SEND", body: "ping")
```

### `Web.FormData` - Live Iteration and O(1) Streaming
`Web.FormData` is an `Enumerable` that yields `[name, value]` pairs, mirroring
browser `FormData.entries()` output. Multipart parses are live-backed by a
coordinator process, so fields are discovered lazily.

When iteration or lookup advances past an unread file part, the parser
automatically discards skipped file bodies before continuing. This preserves
`O(1)` memory usage and avoids deadlocks when users skip blocking file streams.

```elixir
boundary = "example-boundary"

response = Response.new(
  body: "--#{boundary}--\r\n",
  headers: %{"content-type" => "multipart/form-data; boundary=#{boundary}"}
)

form = await(Response.form_data(response))
Enum.to_list(form)
```

### `Web.URL` & `Web.URLSearchParams`
Pure, immutable URL parsing and ordered query parameter management.

```elixir
# URL parsing
url = URL.new("https://user:pass@example.com:8080/p/a/t/h?query=string#hash")
url.port # => 8080

# Params management
params = URLSearchParams.new("foo=bar&foo=baz")
URLSearchParams.get_all(params, "foo") # => ["bar", "baz"]
```

### `Web.Headers` — Security-First
Case-insensitive, enumerable header management with built-in protection against credential leakage.

```elixir
headers = Headers.new(%{"Content-Type" => "text/plain"})
headers = Headers.append(headers, "Set-Cookie", "id=123")

# Automatic Redaction in logs/IEx
IO.inspect(Headers.set(headers, "Authorization", "Bearer secret"))
# => %Web.Headers{"authorization" => "[REDACTED]", ...}
```

### `Web.AbortController` & `Web.AbortSignal`
A unified mechanism for cancelling any asynchronous operation.

```elixir
controller = AbortController.new()
signal = AbortController.signal(controller)

# Pass the signal to a fetch or any async task
Task.start(fn -> 
  # Logic that listens for AbortSignal.aborted?(signal)
end)

# Trigger cancellation
AbortController.abort(controller, "Too slow!")
```

### `Web.Blob`, `Web.ArrayBuffer`, & `Web.Uint8Array`
Immutable data types for efficient binary handling without premature memory flattening.

```elixir
# Build a Blob from multiple parts lazily
blob = Blob.new(["part1", some_other_blob], type: "text/plain")

# Standard byte views
buffer = ArrayBuffer.new(1024)
view = Uint8Array.new(buffer, 10, 100) # Offset 10, Length 100
```

---

## 📦 Features at a Glance

- **⚡ Zero-Buffer Streaming**: Data flows directly from the socket to your logic.
- **⚖️ Native Backpressure**: Sources automatically throttle when your application is busy.
- **👯 Spec-Compliant Cloning**: Branch body streams so multiple consumers can read the same data.
- **🔄 Redirect-Safe**: `307` and `308` redirects preserve streaming bodies automatically.
- **🧩 Protocol-Agnostic**: Core types support HTTP, TCP, and custom dispatchers.
- **🛡 Security-First**: Sensitive headers are redacted by default in terminal output.

---

## 🧪 Industrial-Grade Testing
Reliability is a core requirement. `Web` features exhaustive coverage for stream transitions, body consumption, and redirect handling.

```bash
mix test --cover
```

---
Built with ❤️ for the Elixir community.
