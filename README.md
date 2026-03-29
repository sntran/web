# Web: A Universal Fetch Library for Elixir

A protocol-agnostic, Web API-compliant `fetch` library for Elixir that mirrors the JavaScript Fetch Standard. 

Built with a "Dispatcher" architecture, `Web` provides a unified interface for HTTP, TCP, and connection-string-based protocols while maintaining a zero-buffer, streaming-first approach.

## Key Features

- **JS Fetch Parity**: Familiar `Request`, `Response`, and `Headers` structs.
- **Polymorphic Entry**: `Web.fetch/2` accepts either a URL string or a pre-constructed `Web.Request` struct.
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
req = Web.Request.new("https://example.com", method: :post, body: "data")
{:ok, response} = Web.fetch(req)
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
  dispatcher: MyCustomDispatcher # Override resolution logic
)
```

## Architecture

- **`Web.Dispatcher`**: The core behavior for all protocol handlers.
- **`Web.Resolver`**: Logic to map URL schemes and prefixes to Dispatchers.
- **`Web.Headers`**: Case-insensitive map implementation for HTTP headers.
- **`Web.Dispatcher.HTTP`**: Powered by `Mint` for high-performance, non-pooled streaming.
- **`Web.Dispatcher.TCP`**: Base TCP implementation using `:gen_tcp` in `active: once` mode to manage backpressure.

## Testing & Coverage

The library is hardened with comprehensive property-based tests and verified doctests.

```bash
# Run tests with coverage
mix test --cover
```
