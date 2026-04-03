# 🌐 Web: WHATWG Extension to BEAM
> A protocol-agnostic, zero-buffer suite of Web Standard APIs for Elixir.

[![Hex.pm](https://img.shields.io/hexpm/v/web.svg)](https://hex.pm/packages/web)
[![Docs](https://img.shields.io/badge/hexdocs-latest-blue.svg)](https://hexdocs.pm/web)

---

## 🚀 Why Web?
Most Elixir networking libraries buffer data into memory by default. `Web` is built for **Zero-Buffer Streaming**, ensuring your applications remain responsive and low-memory even when handling gigabytes of data.

By implementing WHATWG standards as **Native Process-backed** entities (`:gen_statem`), `Web` provides a consistent, predictable, and backpressure-aware interface for HTTP, TCP, and custom protocols.

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

    # 3. Fetch and stream the results lazily
    fetch(request) 
  end
end

{:ok, response} = GitHub.repositories()

# Zero-buffer streaming: chunks are written to stdout as they arrive
response.body 
|> Stream.take(5) 
|> Enum.each(&IO.write/1)
```

---

## 📖 API Usage & Examples

### `Web.ReadableStream` — The Streaming Engine
The heart of the library. Every stream is a managed process that handles **Backpressure**, **Locking**, and **Teeing**.

```elixir
# Create a stream from any enumerable (List, File.stream, etc.)
stream = ReadableStream.from(["chunk1", "chunk2"])

# Split one stream into two independent branches (Zero-copy)
{branch_a, branch_b} = ReadableStream.tee(stream)

Task.start(fn -> Enum.each(branch_a, &process_data/1) end)
Task.start(fn -> Enum.each(branch_b, &log_data/1) end)
```

### `Web.Request` & `Web.Response`
First-class containers for network data with high-level factories and standard body readers.

```elixir
# High-level factories for common responses
res = Response.json(%{status: "ok"})
redirect = Response.redirect("https://elixir-lang.org")

# Automatic status and body readers
if res.ok do
  {:ok, data} = Response.json(res) # Terminal consumer
end

# Multi-protocol support (HTTP/TCP)
req = Request.new("tcp://localhost:8080", method: "SEND", body: "ping")
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