# Web: A Universal Fetch Library for Elixir

A protocol-agnostic, Web API-compliant `fetch` library for Elixir that mirrors the JavaScript Fetch Standard. 

Built with a "Dispatcher" architecture, `Web` provides a unified interface for HTTP, TCP, and connection-string-based protocols while maintaining a zero-buffer, streaming-first approach.

## Key Features

- **JS Fetch Parity**: Familiar `Request`, `Response`, and `Headers` structs.
- **Polymorphic Entry**: `Web.fetch/2` accepts either a URL string or a pre-constructed `Web.Request` struct.
- **RequestInit Support**: `Web.Request.new/2` accepts `method`, `headers`, `body`, `redirect`, `signal`, and `dispatcher`.
- **Fetch-Style Redirect Handling**: `Web.Dispatcher.HTTP` supports `"follow"`, `"manual"`, and `"error"` redirect modes with a 20-hop safety limit.
- **AbortController Support**: `Web.AbortController` and `Web.AbortSignal` can cancel in-flight fetches and active body streams.
- **AbortSignal Helpers**: Build pre-aborted, timeout-driven, or combined signals with `Web.AbortSignal.abort/1`, `timeout/1`, and `any/1`.
- **Case-Insensitive Headers**: `Web.Headers` implements the `Access` protocol with case-insensitive normalization.
- **Zero-Buffer Streaming**: `Web.Response.body` is an Elixir `Stream` that yields chunks as they arrive from the socket, ensuring memory safety for large resources.
- **Extensible Dispatchers**: Plug in custom protocol handlers (HTTP, TCP, NNTP, etc.) via the `Web.Dispatcher` behaviour.
- **Rclone-Style Resolution**: Supports standard URIs (`https://...`) and connection strings (`remote:path/...`).
- **Validated & Documented**: 100% test coverage including property-based tests and interactive doctests.

## Installation

Add `:web` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:web, "~> 0.1.0"}
  ]
end
```

## Usage

### Simple HTTP Fetch
```elixir
{:ok, response} = Web.fetch("https://api.github.com/zen")
response.body |> Enum.each(&IO.write/1)
```

### Using a Request Struct
```elixir
req =
  Web.Request.new("https://example.com",
    method: :post,
    headers: %{"content-type" => "text/plain"},
    body: "data",
    redirect: "follow"
  )

{:ok, response} = Web.fetch(req)
```

### Redirect Modes
```elixir
# Follow redirects automatically (default)
{:ok, response} = Web.fetch("https://example.com")

# Return the 3xx response without following
{:ok, response} = Web.fetch("https://example.com", redirect: "manual")

# Fail if a redirect is encountered
{:error, :redirect_error} = Web.fetch("https://example.com", redirect: "error")
```

### TCP / Connection Strings
```elixir
# Routes automatically to Web.Dispatcher.TCP
{:ok, response} = Web.fetch("tcp://localhost:8080")
# Or rclone-style
{:ok, response} = Web.fetch("myserver:8080/data")
```

### Advanced Options
```elixir
Web.fetch("https://example.com", 
  method: "POST", 
  headers: %{"Content-Type" => "application/json"},
  body: "{\"key\": \"value\"}",
  redirect: "manual",
  dispatcher: MyCustomDispatcher # Override resolution logic
)
```

### AbortController
```elixir
controller = Web.AbortController.new()

task =
  Task.async(fn ->
    Web.fetch("https://example.com/slow", signal: controller.signal)
  end)

Process.sleep(50)
:ok = Web.AbortController.abort(controller, :timeout)

{:error, :aborted} = Task.await(task)
```

### AbortSignal Helpers
```elixir
# Already-aborted signal
signal = Web.AbortSignal.abort(:manual_cancel)
{:error, :aborted} = Web.fetch("https://example.com", signal: signal)

# Timeout signal
timeout_signal = Web.AbortSignal.timeout(1_000)
Web.fetch("https://example.com/slow", signal: timeout_signal)

# Abort when either source aborts
controller = Web.AbortController.new()
combined = Web.AbortSignal.any([controller.signal, Web.AbortSignal.timeout(5_000)])

Web.fetch("https://example.com", signal: combined)
```

### Abort During Streaming
```elixir
controller = Web.AbortController.new()
{:ok, response} = Web.fetch("tcp://localhost:4000", signal: controller.signal)

consumer =
  Task.async(fn ->
    response.body |> Enum.to_list()
  end)

Process.sleep(50)
:ok = Web.AbortController.abort(controller, :manual_cancel)

[] = Task.await(consumer)
```

## Architecture

- **`Web.Dispatcher`**: The core behavior for all protocol handlers.
- **`Web.Resolver`**: Logic to map URL schemes and prefixes to Dispatchers.
- **`Web.Headers`**: Case-insensitive map implementation for HTTP headers.
- **`Web.Dispatcher.HTTP`**: Powered by `Mint`, handles HTTP redirects internally, respects already-aborted signals, and aborts cleanly during header reads and body streaming.
- **`Web.Dispatcher.TCP`**: Base TCP implementation using `:gen_tcp`, with abort-aware streaming and immediate socket cleanup.
- **`Web.AbortController` / `Web.AbortSignal`**: Small cancellation primitives that mirror the browser Fetch API, including timeout and aggregate-signal support.

## Testing & Coverage

The library is hardened with comprehensive property-based tests and verified doctests.

```bash
# Run tests with coverage
mix test --cover
```
