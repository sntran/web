
# 🌐 Web Standard APIs for Elixir

A protocol-agnostic, Web API-compliant library for Elixir that brings the simplicity and power of the WHATWG Fetch Standard to the BEAM.

Built for **Zero-Buffer Streaming**, it ensures your applications remain responsive and low-memory even when handling gigabytes of data.

---

## 🛠 The "Web-First" DSL

You can try `Web` immediately without creating a project using `Mix.install`:

```elixir
Mix.install([
	{:web, "~> 0.2.0"}
])

defmodule GitHub do
	use Web

	def repositories(query \\ "elixir") do
		# 1. Construct a new URL
		url = URL.new("https://api.github.com/search/repositories")

		# 2. Modify properties via URLSearchParams
		params = 
			URL.search_params(url)
			|> URLSearchParams.set("q", query)
			|> URLSearchParams.append("sort", "stars")

		# 3. Apply params back to the URL
		url = URL.search(url, URLSearchParams.to_string(params))

		# 4. Construct a Request with the URL
		request = Request.new(url, 
			method: "GET",
			headers: %{"Accept" => "application/vnd.github.v3+json"}
		)

		# 5. Send to fetch
		fetch(request) 
	end
end

{:ok, response} = GitHub.repositories()
IO.puts("Status: #{response.status}")

# Stream the body lazily (Zero-Buffer)
# The body is an Elixir Stream yielding chunks as they arrive from the socket
response.body 
|> Stream.take(5) 
|> Enum.each(&IO.write/1)
```

---

## 📦 Features at a Glance

- **WHATWG-Compliant**: Implements the WHATWG Fetch, URL, Request, Response, ReadableStream, AbortController, and URLSearchParams standards.
- **Zero-Buffer Streaming**: Streams data directly from the source with no intermediate buffering.
- **Backpressure-Aware**: Automatically manages flow control for slow consumers.
- **Body Helpers**: `Request` and `Response` expose `text/1`, `json/1`, `arrayBuffer/1`, `bytes/1`, and `blob/1` with single-consumption semantics.
- **Normalized Bodies**: `Request.new/2` and `Response.new/1` normalize strings, binaries, `nil`, and enumerable inputs through `Web.ReadableStream.from/1`.
- **Cloneable Streams**: `Request.clone/1` and `Response.clone/1` branch body streams with `ReadableStream.tee/1` so both original and clone can be consumed independently.
- **Redirect-Safe Streaming Requests**: `307` and `308` redirects preserve request method and replayable stream bodies without draining them ahead of time.
- **Unified Cancellation**: Abort any async operation with `AbortController` and `AbortSignal`.
- **Protocol-Agnostic**: Supports HTTP, TCP, and custom dispatchers.
- **Immutable Data Structures**: All core types are pure Elixir structs.
- **Industrial-Grade Testing**: Broad coverage across stream lifecycle, redirect handling, cancellation, and edge cases.

---

## 🌐 Core Modules & Usage

### `Web.URL` — Universal URL Parsing

```elixir
url = Web.URL.new("https://example.com/search?q=elixir#docs")
url.protocol # => "https:"
url.pathname # => "/search"
url.hash     # => "#docs"
Web.URL.href(url) # => "https://example.com/search?q=elixir#docs"
```

### `Web.Request` — Standardized Request Container

```elixir
req = Web.Request.new("https://api.github.com/zen", method: :get, headers: %{accept: "text/plain"})
req.method # => "GET"
req.url.hostname # => "api.github.com"
```

Request bodies are normalized through `Web.ReadableStream.from/1`, so
plain strings, binaries, `nil`, and enumerable inputs all behave like
Web-style bodies.

```elixir
req = Web.Request.new("https://api.example.com/items", body: ["he", "llo"])
{:ok, "hello"} = Web.Request.text(req)
```

### `Web.Response` — Stream-Native Response

```elixir
{:ok, resp} = Web.fetch("https://api.github.com/zen")
IO.puts(Enum.to_list(resp.body) |> to_string())
resp.status # => 200
resp.ok     # => true
```

`Web.Response` also exposes body readers that honor the underlying
stream's `[[disturbed]]` state.

```elixir
resp = Web.Response.new(body: ~s({"ok":true}))
{:ok, %{"ok" => true}} = Web.Response.json(resp)
{:error, %Web.TypeError{message: "body already used"}} =
  Web.Response.text(resp)
```

Body readers now include typed data helpers:

```elixir
resp = Web.Response.new(body: "hello", headers: %{"content-type" => "text/plain"})

{:ok, array_buffer} = Web.Response.arrayBuffer(resp)
array_buffer.byte_length # => 5

resp = Web.Response.new(body: "hello")
{:ok, bytes} = Web.Response.bytes(resp)
Web.Uint8Array.to_binary(bytes) # => "hello"

resp = Web.Response.new(body: "hello", headers: %{"content-type" => "text/plain"})
{:ok, blob} = Web.Response.blob(resp)
{blob.size, blob.type} # => {5, "text/plain"}
```

Cloning preserves body availability for both branches:

```elixir
resp = Web.Response.new(body: "hello")
{:ok, {resp, clone}} = Web.Response.clone(resp)

{:ok, "hello"} = Web.Response.text(resp)
{:ok, "hello"} = Web.Response.text(clone)
```

### `Web.ArrayBuffer`, `Web.Uint8Array`, and `Web.Blob`

The library includes immutable WHATWG-style data types for binary payload handling.

```elixir
buffer = Web.ArrayBuffer.new("hello")
buffer.byte_length # => 5

bytes = Web.Uint8Array.new(buffer, 1, 3)
Web.Uint8Array.to_binary(bytes) # => "ell"

blob = Web.Blob.new(["hello", " ", "world"], type: "text/plain")
blob.size # => 11
```

### `Web.Headers` — Case-Insensitive, Multi-Value Headers

```elixir
headers = Web.Headers.new(%{"content-type" => "application/json", "set-cookie" => ["a=1", "b=2"]})
Web.Headers.get(headers, "content-type") # => "application/json"
Web.Headers.get_set_cookie(headers)      # => ["a=1", "b=2"]
```

### `Web.URLSearchParams` — Query Parameter Management

```elixir
params = Web.URLSearchParams.new("foo=bar&foo=baz")
Web.URLSearchParams.get_all(params, "foo") # => ["bar", "baz"]
params = Web.URLSearchParams.append(params, "foo", "qux")
Web.URLSearchParams.to_string(params) # => "foo=bar&foo=baz&foo=qux"
```

### `Web.AbortController` & `Web.AbortSignal` — Unified Cancellation

```elixir
controller = Web.AbortController.new()
Task.start(fn ->
	{:error, :aborted} = Web.fetch("https://slow.site", signal: controller.signal)
end)
Web.AbortController.abort(controller)
```

### `Web.ReadableStream` — Streaming & Multicasting

With **Zero-Buffer Streaming**, `Web` treats every response body as an Elixir `Stream`. Chunks are yielded directly from the socket as they arrive, enabling processing of massive files with constant memory usage.

`Web.ReadableStream.from/1` is the normalization boundary for body-like
values. It accepts `nil`, binaries, existing `ReadableStream`s, and
enumerable inputs and turns them into a consistent body representation.

#### Multi-Reader Magic with `tee()`

Split a single stream into two independent branches without buffering the entire source. Perfect for logging or computing hashes in parallel while saving data to disk.

```elixir
{branch_a, branch_b} = ReadableStream.tee(response.body)

# Branch A: Process as fast as possible
Task.start(fn -> Enum.each(branch_a, &IO.write/1) end)

# Branch B: Feed to another process or compute a checksum
checksum = Enum.reduce(branch_b, 0, fn chunk, acc -> acc + byte_size(chunk) end)
```

#### Backpressure Management

`Web` implementations respect **Backpressure**. The library monitors the consumption speed of its readers and automatically notifies the source to slow down when buffers are full.

When using `tee()`, the source pulls data at the speed of the **fastest** consumer, but guarantees the **slowest** consumer never overflows its internal queue by using a synchronized multicast strategy.

This is also what makes replayable `307` and `308` redirect handling
work for request bodies: the outgoing body can be duplicated without
consuming the redirect branch up front.

---

## 🧪 Industrial-Grade Testing

We take reliability seriously. The `Web` library has thorough coverage
for stream state transitions, body consumption, redirect handling, and
cancellation behavior.

Run the suite yourself:

```bash
mix test --cover
```

---

## 📖 Module Reference

Every core WHATWG concept is represented as a first-class Elixir citizen:

- **`Web.URL`**: Pure, immutable URL parsing and manipulation.
- **`Web.Request`**: Standardized HTTP/TCP request containers.
- **`Web.Response`**: Stream-native response objects.
- **`Web.Headers`**: Case-insensitive, multi-value HTTP headers.
- **`Web.URLSearchParams`**: Ordered, mutable query parameter storage.
- **`Web.ReadableStream`**: Full lifecycle management for streaming data.
- **`Web.AbortController`**: Unified cancellation mechanism for any async operation.
- **`Web.ArrayBuffer`**: Immutable binary buffer with explicit `byte_length`.
- **`Web.Uint8Array`**: Immutable byte-view over `Web.ArrayBuffer`.
- **`Web.Blob`**: Immutable binary parts container with typed MIME metadata.

---

Built with ❤️ for the Elixir community.
