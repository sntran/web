# 🌐 Web: WHATWG & TC39 Extensions for the BEAM
> A protocol-agnostic, zero-buffer suite of Web Standard APIs for Elixir.

[![Build Status](https://github.com/sntran/web/workflows/CI/badge.svg)](https://github.com/sntran/web/actions)
[![Coverage Status](https://coveralls.io/repos/sntran/web/badge.svg?branch=main)](https://coveralls.io/r/sntran/web?branch=main)
[![Hex.pm](https://img.shields.io/hexpm/v/web.svg)](https://hex.pm/packages/web)
[![Docs](https://img.shields.io/badge/hexdocs-latest-blue.svg)](https://hexdocs.pm/web)

---

## 🚀 Beyond Fetch: A Standardized Runtime
`Web` provides a predictable, spec-pure interface for high-concurrency systems. [cite_start]While most Elixir libraries buffer data into memory by default, `Web` is built for **Zero-Buffer Streaming**[cite: 20]. By implementing WHATWG and TC39 standards as **Native Process-backed** entities (`:gen_statem`), `Web` ensures your applications remain responsive even when handling gigabytes of data.

### Why Standards on the BEAM?
* **Predictability**: 100% WPT compliance for core primitives like `URL` and `MIME`.
* **Flow Control**: TC39-aligned concurrency management via `Web.Governor`.
* **Context Propagation**: Ambient `AsyncContext` for metadata that survives process boundaries.
* **Structured Data**: WHATWG-style `structured_clone/2` with transferable `ArrayBuffer`s.
* **Cluster Coordination**: `BroadcastChannel` fan-out across BEAM nodes with sender-origin metadata.
* **Zero-Buffer Performance**: Native streaming with backpressure-aware engines.

---

## 🛠 The "Web-First" DSL
If you’ve used the modern Web API in a browser, you already know how to use this library. We've mapped those standards to idiomatic Elixir.

```elixir
defmodule GitHub do
  use Web

  @spec repositories(String.t()) :: Promise.t()
  def repositories(query \\ "elixir") do
    url = URL.new("https://api.github.com/search/repositories")
    
    params = 
      URL.search_params(url)
      |> URLSearchParams.set("q", query)
      |> URLSearchParams.append("sort", "stars")

    url = URL.search(url, URLSearchParams.to_string(params))

    headers = Headers.new(%{
      "Accept" => "application/vnd.github.v3+json"
    })

    request = Request.new(url, 
      method: "GET",
      headers: headers,
      redirect: "follow",
      signal: AbortSignal.timeout(30_000)
    )

    # 3. Fetch and return the Promise of the Response
    fetch(request) |> Promise.then(&Response.json/1)
  end
end

Web.await(GitHub.repositories())
```

📖 API Usage & Examples
-----------------------

### ⚡ Concurrency & Async Logic

`Web.fetch` remains spec-pure. To limit concurrency, apply the TC39 proposal-aligned `Governor` API to throttle your work explicitly.

```elixir
use Web

# Limit to 2 concurrent operations globally
governor = CountingGovernor.new(2)

requests =
  for url <- ["https://a.com", "https://b.com", "https://c.com"] do
    Governor.with(governor, fn ->
      fetch(url)
    end)
  end

responses = await(Promise.all(requests))

```

Async APIs return `%Web.Promise{}` values. Promise executors capture the current `Web.AsyncContext`, so logger metadata and signals flow into spawned tasks automatically.

```elixir
use Web

response = await fetch("https://api.github.com/zen")
text = await Response.text(response)

# Composite multiple async operations
pair = await Promise.all([
  Promise.resolve(:ok),
  Promise.resolve(text)
])

```

`Web.AsyncContext` carries scoped values across promise and stream task boundaries.

```elixir
use Web

request_id = AsyncContext.Variable.new("request_id")

AsyncContext.Variable.run(request_id, "req-42", fn ->
  # Spawning a task or promise here still has access to the request_id
  await(Promise.resolve(AsyncContext.Variable.get(request_id)))
end)
# => "req-42"
```

### 🌊 Zero-Buffer Streaming

Managed processes that provide data with spec-compliant backpressure.

```elixir
# Create a stream from any enumerable
source = ReadableStream.from(["chunk1", "chunk2"])

# Split one stream into two independent branches (Zero-copy)
{branch_a, branch_b} = ReadableStream.tee(source)

# Composable pipelines with pipe_through
upper =
  source
  |> ReadableStream.pipe_through(TransformStream.new(%{
      transform: fn chunk, controller ->
        ReadableStreamDefaultController.enqueue(controller, String.upcase(chunk))
      end
     }))

```

Standard-compliant gzip/deflate and UTF-8 encoding that works across streamed chunk boundaries.

```elixir
source = ReadableStream.from(["Hello, ", "🌍"])

encoded =
  source
  |> ReadableStream.pipe_through(TextEncoderStream.new())
  |> ReadableStream.pipe_through(CompressionStream.new("gzip"))
  |> ReadableStream.pipe_through(DecompressionStream.new("gzip"))
  |> ReadableStream.pipe_through(TextDecoderStream.new())

await(Response.text(Response.new(body: encoded)))
# => "Hello, 🌍"
```

### 🌍 Data & Metadata

Structured cloning is available directly from `Web` and preserves supported
Web container types, shared references, and transferable `ArrayBuffer`
semantics.

```elixir
use Web

buffer = ArrayBuffer.new("hello")

clone =
  structured_clone(%{"payload" => buffer}, transfer: [buffer])

ArrayBuffer.data(clone["payload"])
# => "hello"

ArrayBuffer.byte_length(buffer)
# => 0
```

Unsupported values and non-transferable entries raise `Web.DOMException`
with the standard `DataCloneError` name.

`Web.BroadcastChannel` turns those structured-clone guarantees into an
idiomatic, distributed coordination primitive. Every broadcast clones its
payload before fan-out, preserves sender `origin` metadata across nodes, and
restores `AsyncContext` values while listeners run.

```elixir
use Web

request_id = AsyncContext.Variable.new("request_id")

sender = BroadcastChannel.new("auth-sync")

receiver =
  BroadcastChannel.new("auth-sync")
  |> BroadcastChannel.onmessage(fn event ->
    {
      event.origin,
      event.data["token"],
      AsyncContext.Variable.get(request_id)
    }
  end)

AsyncContext.Variable.run(request_id, "req-42", fn ->
  BroadcastChannel.post_message(sender, %{"token" => "token-A"})
end)

BroadcastChannel.close(sender)
BroadcastChannel.close(receiver)
```

For a full cross-node example, run:

```shell
mix run examples/cluster_auth_sync.exs
```

Strict WHATWG URL parsing with ordered search params, IDNA host handling, and rclone-style URL support.

```elixir
# WHATWG-style URL parsing
url = URL.new("https://user:pass@example.com:8080/p/a/t/h?query=string#hash")

# URLPattern for matching and ambient route param injection
pattern = URLPattern.new(%{pathname: "/users/:id"})

URLPattern.match_context(pattern, "https://example.com/users/42", fn ->
  # Automatically retrieves captured "id" => "42" from context
  AsyncContext.Variable.get(URLPattern.params())
end)
```

Standard containers that handle MIME-aware sniffing and live multipart iteration.

```elixir
# MIME-aware blobs sniff generic binaries
html = Response.new(
  body: "<!doctype html><html>...",
  headers: [{"content-type", "application/octet-stream"}]
)

await(Response.blob(html)).type # => "text/html"

# Live FormData iteration with O(1) memory usage
form = await(Response.form_data(response))
Enum.to_list(form)
```

* * * * *

🧪 Testing & Compliance
-----------------------

`Web` combines cached JSON fixtures and harvested JS batteries from
**Web Platform Tests (WPT)** with property tests and strict coverage gates.

```shell
# Run the full lint + test + coverage gate
mix precommit

# Run the compliance suite directly
mix test --cover
```

* * * * *

Built with ❤️ for the Elixir community.
