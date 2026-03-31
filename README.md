
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
- **Unified Cancellation**: Abort any async operation with `AbortController` and `AbortSignal`.
- **Protocol-Agnostic**: Supports HTTP, TCP, and custom dispatchers.
- **Immutable Data Structures**: All core types are pure Elixir structs.
- **Industrial-Grade Testing**: 100% test coverage for all state transitions and edge cases.

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

### `Web.Response` — Stream-Native Response

```elixir
{:ok, resp} = Web.fetch("https://api.github.com/zen")
IO.puts(Enum.to_list(resp.body) |> to_string())
resp.status # => 200
resp.ok     # => true
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

---

## 🧪 Industrial-Grade Testing

We take reliability seriously. The `Web` library maintains **100% test coverage** ensuring every state transition and edge case is accounted for.

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

---

Built with ❤️ for the Elixir community.