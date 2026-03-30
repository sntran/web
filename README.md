# Web Standard APIs for Elixir

A protocol-agnostic, Web API-compliant library for Elixir that mirrors the JavaScript Fetch Standard.

Built with a "Dispatcher" architecture, `Web` provides a unified interface for HTTP, TCP, and connection-string-based protocols while maintaining a zero-buffer, streaming-first approach.

## Quick Start (Script / Livebook)

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

## Key Features

- **JS Fetch Parity**: Familiar `Request`, `Response`, and `Headers` structs.
- **Polymorphic Entry**: `Web.fetch/2` accepts a URL string, a `Web.URL`, or a `Web.Request` struct.
- **Pure Data Architecture**: `Web.URL` and `Web.URLSearchParams` are pure Elixir structs—no Agents or hidden state. 
- **Overloaded Functional API**: `Web.URL.href(url, "new_val")` style setters that return new immutable structs.
- **Fetch-Style Redirects**: `Web.Dispatcher.HTTP` supports `"follow"`, `"manual"`, and `"error"` modes.
- **AbortController Support**: Standardized cancellation for in-flight fetches and active body streams.
- **Zero-Buffer Streaming**: `Web.Response.body` is an Elixir `Stream` yielding chunks directly from the socket.
- **Rclone-Style Resolution**: Native support for connection strings (`remote:path/...`).

## Installation

Add `:web` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:web, "~> 0.1.0"}
  ]
end
```

## Usage with `use Web`

You can easily import the main API and aliases into your module using the `use Web` macro:

```elixir
defmodule MyClient do
  use Web

  def fetch_example() do
    url = URL.new("https://example.com")
    req = Request.new(url)
    {:ok, resp} = fetch(req)
    resp
  end
end
```

This will:

- Import `fetch/1`, `fetch/2`, and the `await/1` macro
- Alias the following modules for convenience:
  - `Web.URL`
  - `Web.URLSearchParams`
  - `Web.Headers`
  - `Web.Request`
  - `Web.Response`
  - `Web.AbortController`
  - `Web.AbortSignal`

### Await Macro

The `await/1` macro allows you to write:

```elixir
response = await fetch(req)
```

instead of pattern matching on `{:ok, response}`:

```elixir
{:ok, response} = fetch(req)
```

If the result is `{:error, reason}` or not in the expected format, `await` will raise an error. The macro is automatically imported when you `use Web`.

This makes it easy to use the core types and functions without verbose module names.

## Core Components

### `Request`

The `Request` struct represents a complete I/O operation. It is protocol-agnostic, allowing the same struct to be used for HTTP, TCP, or custom dispatchers.

* **Normalization**: The `:headers` field is automatically converted into a `Headers` struct.
* **Signal Support**: Pass a `AbortSignal` via the `:signal` option to enable timeouts or manual cancellation.
* **Redirect Control**: Supports `follow`, `manual`, and `error` modes.

### `Response`

The result of a successful `fetch`. 

* **Streaming Body**: The `:body` is an `Enumerable` (Stream), ensuring large resources are never fully buffered into memory.
* **Metadata**: Includes the final `url` (post-redirects), `status` code, and a normalized `Headers` container.

### `Headers`

A case-insensitive, multi-value container for protocol headers.

* **Spec Parity**: Implements `append`, `set`, `get`, `delete`, and `has`.
* **Multi-Value Support**: Correctly handles multiple values for a single key, including the specific `getSetCookie` exception.
* **Protocols**: Implements `Access` and `Enumerable`, allowing for `headers["content-type"]` and `Enum.map(headers, ...)`.

### `URL` & `URLSearchParams`

Pure data structs that handle both standard URIs and rclone-style connection strings.

* **Direct Access**: Access `url.protocol`, `url.hostname`, or `url.pathname` directly via dot notation.
* **Overloaded Getters/Setters**: Use `URL.href(url, "new_url")` to parse and update the entire struct immutably.
* **Ordered Params**: `URLSearchParams` preserves key order and duplicate keys.

### AbortController` & AbortSignal`

Standardized mechanism for coordinating the cancellation of one or more asynchronous operations.

* **`AbortController`**: The management object used to trigger cancellation. Create one with AbortController.new()`.
* **`.signal` Property**: A `AbortSignal` instance linked to the controller. This is the "read-only" observer passed to `fetch` to monitor the aborted state.
* **`AbortSignal` State**: Signals include an `aborted` boolean and a `reason` for the cancellation.
* **`AbortSignal.timeout(ms)`**: Static helper that returns a signal that automatically aborts after a specified duration—perfect for handling request timeouts.
* **`AbortSignal.any(signals)`**: Static helper that combines multiple signals into one; the combined signal aborts if ANY of the provided source signals abort.
* **`AbortSignal.abort(reason)`**: Static helper that returns a signal that is already in an aborted state.

## Architecture

- **`Dispatcher`**: The core behavior for all protocol handlers.
- **`Dispatcher.HTTP`**: Powered by `Finch`, handles connection pooling and redirects internally.
- **`Dispatcher.TCP`**: Base TCP implementation using `:gen_tcp` with abort-aware streaming.
- **`Headers`**: A case-insensitive, multi-value header container with `Access` and `Enumerable` support.

## Testing

`Web` is built with a commitment to reliability, featuring 100% test coverage including property-based tests for URL parsing and header normalization.

```bash
mix test --cover
```