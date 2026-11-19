# 🌐 Web: WHATWG & TC39 Extensions for the BEAM
> A protocol-agnostic, zero-buffer suite of Web Standard APIs for Elixir.

[![Build Status](https://github.com/sntran/web/workflows/CI/badge.svg)](https://github.com/sntran/web/actions)
[![Coverage Status](https://coveralls.io/repos/sntran/web/badge.svg?branch=main)](https://coveralls.io/r/sntran/web?branch=main)
[![Hex.pm](https://img.shields.io/hexpm/v/web.svg)](https://hex.pm/packages/web)
[![Docs](https://img.shields.io/badge/hexdocs-latest-blue.svg)](https://hexdocs.pm/web)

---

## 🚀 Beyond Fetch: A Standardized Runtime
`Web` provides a predictable, spec-pure interface for high-concurrency systems. While most Elixir libraries buffer data into memory by default, `Web` is built for **Zero-Buffer Streaming**. By implementing WHATWG and TC39 standards as **Native Process-backed** entities (`:gen_statem`), `Web` ensures your applications remain responsive even when handling gigabytes of data.

### Why Standards on the BEAM?
* **Predictability**: 100% WPT compliance for core primitives like `URL` and `MIME`.
* **Flow Control**: TC39-aligned concurrency management via `Web.Governor`.
* **Context Propagation**: Ambient `AsyncContext` for metadata that survives process boundaries.
* **Structured Data**: `structured_clone/2` of the HTML Standard, with transferable `ArrayBuffer`s and message ports.
* **Messaging**: `MessageChannel` and `MessagePort` of the HTML Standard, with the port message queue and transferable ports.
* **Cluster Coordination**: `BroadcastChannel` to the channels of all the connected BEAM nodes.
* **Developer Tools**: `Console` for `Logger`, and `Performance` for times, marks, and measures.
* **Capability Sockets**: WINTERCG-style `Socket` handles with readable/writable streams and `STARTTLS` upgrades.
* **Resource Disposal**: `Symbol.dispose` and a `using` macro with the rules of ECMAScript.
* **Zero-Buffer Performance**: Native streaming with backpressure-aware engines.

---

## 📦 Installation

Add `web` to the dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:web, "~> 0.5.0"}
  ]
end
```

The package needs Elixir 1.19 or later and Erlang/OTP 28 or later. The
tests run on Elixir 1.19 with Erlang/OTP 28, and on Elixir 1.20 with
Erlang/OTP 29.

For a first look, run the tour in this repository:

```shell
mix run examples/demo.exs
```

The directory [`examples/`](examples/README.md) has an index of all the
examples.

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

`use Web` also imports the macro `using`, which releases a resource at the
end of its block, as the `using` declaration of ECMAScript. The resource is
released also when the block raises.

```elixir
use Web

using channel <- BroadcastChannel.new("audit-log") do
  BroadcastChannel.post_message(channel, %{status: "started"})
end
```

A message port, a broadcast channel, a socket, a reader, and a writer are
disposable. A value that is not disposable raises `Web.TypeError` before
the block runs. When the block and the disposal fail, the macro raises
`Web.SuppressedError` with the two errors. See `Web.Symbol` to make a
struct disposable.

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

A token belongs to the process that acquired it. When that process stops,
also with a failure, the governor takes the token back. Thus the capacity
cannot decrease.

A governor from `CountingGovernor.new/1` belongs to the process that made
it, and stops after that process. For a governor that all the processes of
an application use, put it in a supervision tree:

```elixir
children = [
  {Web.CountingGovernor, capacity: 4, name: MyApp.FetchLimit}
]

governor = Web.CountingGovernor.get(MyApp.FetchLimit)
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

A promise behaves as it does on the Web. Any process can `await` it, and can
`await` it more than one time. `Promise.then/2`, `Promise.catch/2`, and
`Promise.finally/2` return a new promise immediately. `Promise.all/1`,
`Promise.all_settled/1`, `Promise.any/1`, and `Promise.race/1` accept pending
promises.

The BEAM has one rule that the Web does not have: a pending promise has an
owner, which is the process that made it. The promise stops when its owner
stops. After a promise settles, it keeps its outcome until the first `await`,
and then for a linger time (5000 ms by default,
`config :web, linger: ms`). Keep the awaited value, not the promise,
when you need the value later.

For externally controlled promise settlement, use
`Promise.with_resolvers/0` to get a promise plus explicit `resolve` and
`reject` functions.

```elixir
use Web

{promise, resolve, _reject} = Promise.with_resolvers()

Task.start(fn ->
  resolve.(%{status: :ready})
end)

await(promise)
# => %{status: :ready}
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

A stream is a process, and it has an owner: the process that made it. A
stream stops after it is ended and all its chunks are read. It also stops
when its owner stops and no process has locked it. A halt, such as
`Enum.take/2`, cancels the stream.

Read or cancel each response body. A body that no process starts to read
releases its connection after 300 seconds
(`config :web, unread_body_timeout: ms`), and a later read rejects.

`fetch` has no time limit for a full request, as in the Fetch Standard. Use
`AbortSignal.timeout/1` for that limit. Two settings limit the wait for the
network:

| Setting                             | Default   | Time                                                              |
| ----------------------------------- | --------- | ----------------------------------------------------------------- |
| `config :web, connect_timeout: ms`  | 10000 ms  | To open a connection.                                             |
| `config :web, receive_timeout: ms`  | 300000 ms | To wait for the response headers, or for the next part of a body. |

A request that fails for one of these limits rejects with `Web.TypeError`,
and the field `cause` has the timeout. The value `:infinity` removes a
limit.

`fetch` uses HTTP/1.1. The setting `:http_protocols` selects the HTTP
versions. The connection pools read it when the application starts.

| Setting                                         | Versions                                                          |
| ----------------------------------------------- | ----------------------------------------------------------------- |
| `config :web, http_protocols: [:http1]`         | HTTP/1.1 only. This is the default.                               |
| `config :web, http_protocols: [:http2]`         | HTTP/2 only. Many requests use one connection.                    |
| `config :web, http_protocols: [:http1, :http2]` | The server of a TLS connection selects the version (with ALPN).   |

The field `status_text` of a response follows the HTTP version. An HTTP/2
response has no reason phrase, thus its status text is `""`, as the Fetch
Standard specifies. For HTTP/1.1, the text is the usual reason phrase of
the status (for example `"OK"` for 200), because the HTTP client does not
give the phrase that the server sent. With the two versions, a response
from a TLS connection has the status text `""`.

```elixir
# Create a stream from any enumerable
source = ReadableStream.from(["chunk1", "chunk2"])

# Split one stream into two independent branches (Zero-copy)
[branch_a, branch_b] = ReadableStream.tee(source)

# Composable pipelines with pipe_through
upper =
  source
  |> ReadableStream.pipe_through(TransformStream.new(%{
      transform: fn chunk, controller ->
        ReadableStreamDefaultController.enqueue(controller, String.upcase(chunk))
      end
     }))

```

Standard-compliant gzip/deflate and text encoding that works across streamed chunk boundaries.
`TextDecoder` and `TextDecoderStream` decode UTF-8, UTF-16LE, UTF-16BE, and
the single-byte encodings of the Encoding Standard, such as windows-1252
(the label `latin1`), windows-1251, and KOI8-R.

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

#### Chunks of bytes

Each stream of bytes gives its chunks as `Uint8Array` values, as the Web
standards specify. This applies to the body of a request or a response, to
`Blob.stream/1`, to the readable side of a socket, of a compression stream,
and of `TextEncoderStream`, and to a default read of a byte stream.

```elixir
response = await(fetch("https://example.com/data"))

# All the bytes: use the functions of the body.
text = await(Response.text(response))

# Chunk by chunk: each chunk is a `Uint8Array`.
for chunk <- response.body do
  IO.write(Uint8Array.to_binary(chunk))
end
```

Each consumer of bytes accepts a binary, a `Uint8Array`, or an
`ArrayBuffer`: the body of a request, a write to a socket, and a chunk for
a compression stream or for `TextDecoderStream`.

Byte-oriented streams also support WHATWG-style BYOB reads. The reader
gives a `Uint8Array` view, and each read gives not more bytes than the view
can hold. The producer fills the view through a capability-scoped
`ReadableStreamBYOBRequest`, and `ReadableByteStreamController` gives the
active BYOB request and the desired size in bytes.

As in the Streams Standard, a BYOB read moves the buffer into the stream:
the buffer that you gave becomes detached, and the result has a new view in
a buffer of the same length. Use `value.buffer` for the subsequent read.

```elixir
use Web

stream =
  ReadableStream.new(%{
    type: "bytes",
    pull: fn controller ->
      case ReadableByteStreamController.byob_request(controller) do
        %ReadableStreamBYOBRequest{} = request ->
          ReadableStreamBYOBRequest.respond(request, "hello")

        nil ->
          :ok
      end
    end
  })

reader = ReadableStream.get_reader(stream, mode: "byob")
view = Uint8Array.new(ArrayBuffer.new(5))

%{value: value, done: false} = await(ReadableStreamBYOBReader.read(reader, view))
Uint8Array.to_binary(value)
# => "hello"

# The first buffer is detached. Use the buffer of the result again.
ArrayBuffer.detached?(view.buffer)
# => true
view = Uint8Array.new(value.buffer)
```

For a full buffer-reuse example, run:

```shell
mix run examples/secure_byob_stream.exs
```

### 🔌 Capability Sockets

WINTERCG-style sockets expose a capability-safe handle plus WHATWG
`ReadableStream` and `WritableStream` endpoints, so raw TCP/TLS sessions use
the same backpressure-aware primitives as the rest of the runtime.

```elixir
use Web

socket = Web.connect("example.com:443", secureTransport: "on")
await(socket.opened)

writer = WritableStream.get_writer(socket.writable)
reader = ReadableStream.get_reader(socket.readable)

await(WritableStreamDefaultWriter.write(writer, "GET / HTTP/1.1\r\nhost: example.com\r\n\r\n"))
chunk = await(ReadableStreamDefaultReader.read(reader))

# Each chunk of bytes is a `Uint8Array`.
Uint8Array.to_binary(chunk.value)
```

A TLS socket verifies the certificate of the server and its host name,
with the trust store of the operating system. `fetch` does the same. The
setting `:tls_options` gives TLS options to the two functions: a keyword
list of options of the Erlang application `:ssl`. For example, this setting
names a file of private certificate authorities:

```elixir
config :web, tls_options: [cacertfile: "/etc/ssl/private-ca.pem"]
```

One socket can have its own options, which come before the setting:
`Web.connect(address, secureTransport: "on", ssl_options: [cacertfile: path])`.
The option `verify: :verify_none` stops the verification. Use it only for a
test.

Explicit `STARTTLS` upgrades are supported through `Socket.start_tls/2`. For a
full SMTP handshake example, run:

```shell
mix run examples/smtp_client.exs
```

### 🌍 Data & Metadata

`structured_clone/2` is the structured clone of the HTML Standard. All
data can be cloned: numbers, atoms, binaries, lists, tuples, maps, and
structs that have only data. A value with an identity, such as an
`ArrayBuffer` or a `Blob`, gets a new identity. The option `:transfer` moves
a buffer or a message port, and detaches the source.

```elixir
use Web

buffer = ArrayBuffer.new("hello")

clone =
  structured_clone(%{payload: buffer, tags: [:a, :b]}, transfer: [buffer])

ArrayBuffer.data(clone.payload)
# => "hello"

ArrayBuffer.detached?(buffer)
# => true
```

A value that refers to something that runs cannot be cloned: a pid, a
function, a stream, a promise. The function then raises `Web.DOMException`
with the name `DataCloneError`, and changes nothing.

`Web.MessageChannel` makes two connected ports. A message that one port
sends arrives at the other port as an event `message`. A port can move to
the listener that gets a message: put it in the transfer list.

```elixir
use Web

{port1, port2} = MessageChannel.new()

MessagePort.onmessage(port2, fn event ->
  # Answer on the port that got the message.
  MessagePort.post_message(event.target, String.upcase(event.data))
end)

MessagePort.onmessage(port1, fn event -> IO.puts(event.data) end)
MessagePort.post_message(port1, "hello")
# Prints "HELLO".

MessagePort.close(port1)
```

The rules are those of a browser:

* A port keeps its messages until it starts. `onmessage/2` starts the port.
  After `add_event_listener/4`, call `MessagePort.start/1`.
* The other port gets the event `close` when a port closes, or when the
  process that holds the port stops.
* A function on a closed port has no effect and gives no error.
* The listeners of a port run in a process of that port. A listener can
  call each function of its port, and a listener that raises does not stop
  the port.

A port and a channel stay until `close/1`, or until the process that made
them stops. Close them, or use `using`.

`Web.BroadcastChannel` sends a message to each other open channel with the
same name, in this VM and on each connected node. The event has the node of
the sender in `origin`, and the listeners run in the `AsyncContext` of the
sender.

```elixir
use Web

request_id = AsyncContext.Variable.new("request_id")

sender = BroadcastChannel.new("auth-sync")

receiver =
  BroadcastChannel.new("auth-sync")
  |> BroadcastChannel.onmessage(fn event ->
    {
      event.origin,
      event.data.token,
      AsyncContext.Variable.get(request_id)
    }
  end)

AsyncContext.Variable.run(request_id, "req-42", fn ->
  BroadcastChannel.post_message(sender, %{token: "token-A"})
end)

using receiver do
  BroadcastChannel.close(sender)
end
```

Each channel sends to the other channels with no process between them.
Thus a slow listener delays only its channel, and the channels of a node
continue when a different node stops. The messages of one channel arrive
in their sequence.

For a full cross-node example, run:

```shell
mix run examples/cluster_auth_sync.exs
```

For an example that gives a port to a worker, and keeps the secrets of the
worker behind that port, run:

```shell
mix run examples/secure_worker.exs
```

`Web.Console` has the functions of `console` for the `Logger` of Elixir:
the levels, the format of the Console Standard, tables, groups, timers,
and counters. `Web.Performance` has `now/0`, marks, and measures of the
User Timing Standard.

```elixir
use Web

Console.group("import")
Console.time("rows")
Performance.mark("start")

Console.log(["%s has %d rows", "users.csv", 1200])
Console.table([%{name: "Ada", score: 10}, %{name: "Linus", score: 8}])

Console.time_end("rows")
# => rows: 3.214 ms
Performance.measure("import", "start").duration
# => 3.305
Console.group_end()
```

The groups, the timers, the counters, and the entries are the state of the
process that calls the functions.

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

Standard containers for blobs, files, and forms.

```elixir
# The type of a blob comes from the header `content-type`
html = Response.new(
  body: "<!doctype html><html>...",
  headers: [{"content-type", "text/html"}]
)

await(Response.blob(html)).type # => "text/html"

# Live FormData iteration with O(1) memory usage
form = await(Response.form_data(response))
Enum.to_list(form)

# A form as the body of a request: `multipart/form-data`
form =
  FormData.new()
  |> FormData.append("title", "Report")
  |> FormData.append("file", File.new(["bytes"], filename: "report.txt", type: "text/plain"))

await(fetch("https://example.com/upload", method: "POST", body: form))
```

A `FormData` body is encoded as the HTML Standard specifies, and the header
`content-type` gets the boundary. The bytes of a file are read from its
stream chunk by chunk. A form with all its data in memory has a content
length, and it can be sent again after a redirect.

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

### Specifications

The directory `tla/` has TLA+ specifications of the parts where an error is
easy to make and hard to find with an example test:

| Specification        | Subject                                                    |
| -------------------- | ---------------------------------------------------------- |
| `Promise.tla`        | One promise: it settles one time, and it stops.            |
| `StreamLifetime.tla` | When a stream process stops, and when it must stay.        |
| `AbortSignal.tla`    | Subscriptions, the abort message, and the stop of a signal. |
| `ResponseBody.tla`   | The body of a response: all its chunks, or an error.       |
| `MessagePort.tla`    | The port message queue, the start, the transfer, and the close. |
| `BroadcastChannel.tla` | The channels of one name, with a channel that is slow.   |
| `Disposal.tla`       | The blocks of `using`: each resource is released one time. |
| `Console.tla`        | The groups, the timers, and the counters of the console.   |
| `Performance.tla`    | The marks and the measures of a process.                   |

`mix test` examines each specification with the checker of
[`accord`](https://github.com/sntran/accord), which is written in Elixir and
needs no Java. The tests in `test/tla/` also do random operations on the
real code and on the specification together, and compare the two states
after each step.

Each specification has a constant `Bug`. Each of its values removes one
rule of the design, and a test makes sure that the checker finds it.

```shell
# Examine the specifications and run the conformance tests
mix test test/tla
```

* * * * *

Built with ❤️ for the Elixir community.
