# Changelog

All notable changes to this project are documented in this file.

## [0.5.0] - 2026-11-19

### Added

- The constants of the Standards, as functions with no argument:
  `Web.Event.none/0`, `capturing_phase/0`, `at_target/0`, and
  `bubbling_phase/0`, the 25 legacy codes of `Web.DOMException`
  (`index_size_err/0` to `data_clone_err/0`), and
  `Web.Uint8Array.bytes_per_element/0`.
- `tla/LazySignal.tla`: the lazy signal of a request, its start by one of
  the copies, and the sequence of the abort events, with a conformance
  test. `tla/EventTarget.tla` has the listener steps of each target, with
  the old behaviors as values of `Bug`.
- The WPT files `fetch/api/abort/general.any.js` and
  `fetch/api/abort/request.any.js` run in the runner.
- The members of the Standards that were missing:
  - `for_each/2` of `Web.Headers`, `Web.URLSearchParams`, and
    `Web.FormData`, and `keys/1`, `values/1`, and `entries/1` where they
    were missing.
  - The constructors `Web.ReadableStreamDefaultReader.new/1`,
    `Web.ReadableStreamBYOBReader.new/1`, and
    `Web.WritableStreamDefaultWriter.new/1`, and `Web.Request.url/1`.
  - The default chunk `nil` of `enqueue/2` and `write/2`, as
    `optional any chunk`.
  - The option `:endings` of `Web.Blob.new/2` and `Web.File.new/3`
    (`"transparent"` or `"native"`).
  - `Web.Promise.then/3` with `onRejected`, and `Web.Promise.try/2`.
  - `Web.AsyncContext.Snapshot.wrap/1` and the arguments of
    `Snapshot.run/3` and `Variable.run/4`, as the proposal specifies.
  - `Web.Governor.wrap_iterator/2`, as `wrapIterator(it)` of the proposal
    for concurrency control.
  - `Web.MessageEvent.init_message_event/9`, `Web.Performance.Mark.new/2`,
    and `to_json/1` of the performance entries.
  - The field `cause` of `Web.RangeError`, and `message` and `cause` of
    `Web.AggregateError`.
- `tla/SocketClose.tla`: the close, the half close, and the upgrade of a
  socket, with a conformance test on a real TCP socket. Its `Bug` values
  are the old behaviors.
- The WPT files `fetch/data-urls/processing.any.js` and
  `fetch/data-urls/base64.any.js` run in the runner: 154 more tests pass.
- `Web.ReadableStream.values/2` and `Web.ReadableStreamAsyncIterator`, the
  async iterator of the Streams Standard: `next/1` and `return/2` return
  promises of `%{value: value, done: done}`. The option `prevent_cancel:`
  keeps the stream open after a `return/2`.
- `Web.ReadableStreamBYOBRequest.view/1`, and the option `min:` of
  `Web.ReadableStreamBYOBReader.read/3`.
- A queuing strategy can have its own `size` function: the option `:size`
  of `Web.ReadableStream.new/2`, `Web.WritableStream.new/2` with a
  strategy, and the strategies of `Web.TransformStream.new/2`. The size
  function runs in the process that enqueues or writes, thus it can call
  the controller again. A high water mark can be `:infinity`. New:
  `Web.CountQueuingStrategy.size/0`.
- `Web.TextDecoder` decodes the encodings of Chinese, Japanese, and Korean:
  gb18030, GBK, Big5, EUC-JP, ISO-2022-JP, Shift_JIS, and EUC-KR. The
  decoders follow the Encoding Standard, with the modes "replacement" and
  "fatal", and with `stream: true`. The index data comes from the index
  files of the Encoding Standard (CC BY 4.0), in
  `lib/web/encoding/multi_byte_indexes.txt`. The file names its source and
  the SHA-256 hash of each index file.
- `Web.TextDecoder.decode/1`, and `nil` as the input of `decode/2,3`: a
  call with no input ends a stream, as `decode()` in JavaScript.
- `Web.TextEncoder.encode_into/3`, the method `encodeInto()` of the
  Encoding Standard. A `Web.Uint8Array` is immutable, thus the function
  returns `{%{read: read, written: written}, destination}`, with the new
  destination.
- `Web.URL.parse/1,2`, `Web.URL.can_parse/1,2`, and `Web.URL.to_json/1`.
- `Web.URLSearchParams.has/3` and `Web.URLSearchParams.delete/3`, with a
  value, and `Web.URLSearchParams.size/1`.
- `Web.URLPattern.has_reg_exp_groups/1`, the attribute `hasRegExpGroups`.
  `Web.URLPattern.new/0`, `test/1`, and `exec/1` use the default input
  `{}` of the URL Pattern Standard.
- `Web.Request.text_stream/1`, `Web.Response.text_stream/1`, and
  `Web.Blob.text_stream/1`, the method `textStream()` of the Fetch Standard
  and of the File API: the bytes through a UTF-8 `Web.TextDecoderStream`.
- The attributes of a `Web.Request` of the Fetch Standard: the fields
  `destination`, `referrer`, `referrer_policy`, `mode`, `credentials`,
  `cache`, `integrity`, `keepalive`, `is_reload_navigation`,
  `is_history_navigation`, and `duplex`, and the options `:referrer`,
  `:referrer_policy`, `:mode`, `:credentials`, `:cache`, `:integrity`,
  `:keepalive`, `:priority`, and `:window` of `Web.Request.new/2`. The
  constructor raises `Web.TypeError` as the steps "new Request(input,
  init)" specify, for example for the mode "navigate", for "only-if-cached"
  with a mode that is not "same-origin", and for `keepalive` with a body
  from a stream.
- `Web.Headers` has the field `guard` of the Fetch Standard: `"none"` or
  `"immutable"`. See "Changed".
- `Web.URL.create_object_url/1` and `Web.URL.revoke_object_url/1`, with
  the blob URL store of the File API. A URL belongs to the process that
  made it: the store removes the URLs of a process that stops. A library
  has no document, thus a blob URL has an opaque origin:
  `blob:null/<UUID>`. `Web.fetch/2` of a blob URL gives the blob, with
  `Content-Length` and `Content-Type`, and a request with a `Range` header
  gets the status 206 and `Content-Range`. A method that is not GET, or a
  URL that is not in the store, gives a network error.
- `Web.EventTarget.new/0`. A dispatch runs the listeners in the process
  that dispatches, before `dispatch_event/2` returns, with the capture and
  bubble passes of the DOM Standard. The options `once`, `passive`, and
  `signal` work. `remove_event_listener/4` takes the options.
- The functions of `Web.Event` of the DOM Standard: `prevent_default/1`,
  `default_prevented/1`, `stop_propagation/1`,
  `stop_immediate_propagation/1`, `cancel_bubble/1`, `set_cancel_bubble/2`,
  `return_value/1`, `set_return_value/2`, `composed_path/1`,
  `current_target/1`, `src_element/1`, `event_phase/1`, and `init_event/4`,
  and `Web.CustomEvent.init_custom_event/5`. The new fields `composed`,
  `is_trusted`, and `time_stamp`. The flags of an event are in an
  `:atomics` array, thus all the copies of an event share them: a
  `prevent_default/1` in a listener changes the result of
  `dispatch_event/2`.
- A `Web.AbortSignal` is an event target, with `onabort/1` and
  `onabort/2`. The listeners of the event `abort` run in the process that
  aborts, before `Web.AbortController.abort/2` returns, as the steps
  "signal abort" specify. The signals of `Web.AbortSignal.any/1` that
  depend on it abort before the listeners run.
- `Web.File.last_modified` and the option `:last_modified` of
  `Web.File.new/3`. The default is the time of the construction, in
  milliseconds. `Web.Blob.slice/1..4` accept `nil` for the start and the
  end.
- The format `"brotli"` of `Web.CompressionStream` and
  `Web.DecompressionStream`, and the content coding `br` of `Web.fetch/2`.
  The decoder (RFC 7932) and the encoder are in Elixir, in
  `Web.Internal.Brotli`, with the static dictionary of the RFC in
  `lib/web/internal/brotli/dictionary.txt`. The decoder takes chunks of
  each size, and gives pieces of 64 KiB at most as the reader takes them.
  It decodes 30 to 42 MB of text each second, and 80 to 107 MB of map
  data, approximately 5 to 7 times slower than the C decoder. The encoder
  uses LZ77 with one hash candidate, and gives a ratio near the quality 1 of
  the reference encoder.
- The setting `config :web, brotli: :elixir | :native | :not_requested`
  selects the decoder of `br` and of the format `"brotli"`. `:native` uses
  the C decoder of the Hex package `brotli`, which the application adds:
  the library does not depend on it. `:not_requested` removes `br` from the
  default `accept-encoding` of a request. A value that is not valid, and
  `:native` with no package, raise `ArgumentError`.
- `tla/TransformStream.tla`: the backpressure of the two sides of a
  transform stream, and one call of the finish of the transformer.
- The TLA+ specifications `tla/PipeTo.tla` (the loop of a pipe),
  `tla/PriorityMessages.tla` (a priority message and the sequence of its
  sender), `tla/TransformLifetime.tla` (the lock of one side of a transform
  stream keeps the two sides), `tla/LazyStream.tla` (the state that the
  copies of a body in memory share), `tla/ByteTee.tla` (the tee of a byte
  stream), `tla/AbortSteps.tla` and `tla/AbortTimeouts.tla` (the steps
  "signal abort", and the timeouts of one process), `tla/EventTarget.tla`
  (the listeners, a dispatch, and the lifetime of a target), and
  `tla/FormDataParser.tla` (the live parser of a multipart form).
  `tla/AbortSignal.tla` has the listeners and the dependent signals, and
  `tla/SharedConnection.tla` has a socket that closed before the client
  knows it. Each one has a conformance test or a property test on the real
  code, and each known defect is one value of its constant `Bug`.
- `Web.fetch/2` decodes a response body with the header
  `Content-Encoding`, as the Fetch Standard specifies: `gzip`, `x-gzip`,
  `deflate` (the zlib format, or raw deflate data), `br`, and `zstd`. A
  list of codings is decoded in the opposite sequence. A coding that the
  library does not know gives the body with no change. The body is
  decoded chunk by chunk, in pieces of 64 KiB at most, and the headers of
  the response do not change. Data that cannot be decoded, or that is
  cut, gives the reader `Web.TypeError` with the decoder error in `cause`.
- A request with no header `accept-encoding` sends
  `gzip, deflate, br, zstd`.
  A request with a header `range` sends `identity`. A value of the caller
  is kept.

- A cancel, an abort, and an error of a stream are priority messages of
  Erlang/OTP 28: the stream gets them before the messages of the other
  processes in its mailbox, and after the earlier messages of the same
  process. Thus `write/2` and then `abort/2` from one process writes first,
  as in JavaScript. The sender sends a usual fence message before the
  priority message, and the stream takes the messages of the sender up to
  the fence first. With 5000 requests in the mailbox, an abort took
  24.6 ms before. It now takes approximately 1.3 ms with 50000 requests of
  a different process.
- The package is tested on Elixir 1.20 with Erlang/OTP 29, and on
  Elixir 1.19 with Erlang/OTP 28. The code compiles with no warning on the
  two versions.
- `examples/README.md`, an index of the examples, and a new
  `examples/demo.exs`: a short tour that needs no network.
- `bench/http_clients.exs`, which compares `Web.fetch/2` with Finch and
  Req on one server of the machine. The clients run in turns, in 8 rounds.
  Req and Finch are dependencies only in the environment `:dev`.
- `bench/operation_cost.exs`, which measures the cost of one element or one
  operation of a stream, of `text/1` of a body in memory, and of a promise.
- The HTTP client of `Web.fetch/2` is in the library, on the connection
  functions of Mint. Finch is not a dependency now. Each origin has a pool
  of 25 connections. The process of the request owns the socket while the
  response comes, thus no other process is between the network and the
  response. A small request takes approximately 10 µs less than with
  Finch. A stream read of a large body has approximately the same speed and
  memory, see `BENCHMARKS.md`.
- With `config :web, http_protocols: [:http2]`, the requests of an origin
  share one connection, and one process of the origin owns it. A request
  body goes in the window of HTTP/2: a part that is larger waits until the
  server makes the window larger. A request waits when the server allows
  no more streams.
- A request on an idle connection that the server closed, and a request
  that an HTTP/2 server did not process (`GOAWAY`, `REFUSED_STREAM`), go
  again on a new connection. A request with a body from a stream does not
  go again.
- The content decoder gives its output only as the reader takes it: the
  process of the request keeps 64 KiB of decoded data at most, also for a
  small compressed body that expands much.
- With `[:http2]`, a request in the queue of a connection that closes did
  not go to the server: it goes again on a new connection. A new
  connection has one stream until the settings of the server come, thus
  the client does not open more streams than the server allows. After an
  error of a frame, the connection still sees the close of the server: a
  request does not wait until the receive timeout.
- A response that comes before the end of a request body from a stream
  does not fail: the request stops to read the body stream only when it
  stops to send the body.
- The TLA+ specifications `tla/ConnectionPool.tla`, `tla/SocketFlow.tla`,
  and `tla/SharedConnection.tla`, with a conformance test of the pool, a
  conformance test of the reads of the socket, and property tests of the
  shared HTTP/2 connection and of the content decoder. A property test
  checks the properties of `tla/ResponseBody.tla` on the real body. A
  second conformance test compares `Web.CountingGovernor` with
  `tla/ConnectionPool.tla`: a governor and the pool count their slots with
  the same rules.
- The tests run 264 JavaScript files of web-platform-tests with no change,
  in the JavaScript engine QuickJS, against the library: `Headers`, `URL`,
  `URLSearchParams`, `URLPattern`, `TextEncoder`, `TextDecoder`,
  `TextEncoderStream`, `TextDecoderStream`, the streams of the Streams
  Standard with their readers, writers, and controllers, the queuing
  strategies, `CompressionStream`, `DecompressionStream`, `Request`,
  `Response`, `Blob`, `File`, `FormData`, `AbortController`, `AbortSignal`,
  `Event`, and `EventTarget`. A layer
  makes the JavaScript classes from the WebIDL files of WPT, and calls the
  library through a port. The library can call a JavaScript function, such
  as the `pull` of a source, and a promise of the library is a promise of
  JavaScript. The runner answers a call when the processes of the run are
  at rest, thus the result of each test is the same in each run. 19579 of
  20405 tests pass. The lists of the tests that do
  not pass, with the group of their cause, are in
  `test/wpt/quickjs/expectations/`. QuickJS is a tool of the tests only: the
  tests download a pinned release, and examine its SHA-256 hash.
- Ports of five files of web-platform-tests in `test/wpt/`: the default
  reader and the bad sources of the Streams tests, the basic headers and
  the header errors of the Fetch tests, and the abort event of the DOM
  tests. Each test has the name of its WPT test. 73 of the 86 tests pass.
  The 13 others show a difference of the library from a Standard, with the
  difference in a comment, and the tag `:wpt_failure`: the gate does not
  run them, and `mix test --only wpt_failure` does.
- The tests wait for other processes with a message, a monitor, or a
  promise, not with a sleep. A sleep stays only where it is a part of the
  scenario, such as a slow server or a time limit.
- `CONTRIBUTING.md`, with the rules for a change: the compliance with the
  Web Standards, the TLA+ specifications, the property tests, the tests
  that do not depend on time, the gate, and the benchmarks.
- The path of the URL goes to the server with no change, as in a browser:
  the HTTP client does not check it again. For example, a path can have
  `|`.
- A `Web.ReadableStream` of bytes in memory has no process until a stream
  read: the body of `Web.Response.new/1` and `Web.Request.new/2` for a
  binary, `ReadableStream.from/1` for a binary, a view, a buffer, or
  `Web.URLSearchParams`, and the body of a `fetch` response that ends 1 ms
  after its headers. The body functions, such as `Web.Response.text/1`,
  take the bytes with no process, and the promise of a body of 64 KiB or
  less is settled when the function returns. `get_reader/1`, a pipe, and
  `Enum` start the stream process at that time. All the copies of the
  struct have one state, in an `:atomics` array, and find the same stream
  process. A read examines the abort signal of the body. A copy on a
  different node does each operation on the node of the array. A stream
  with no process has no owner: a copy in a different process can read it
  after the process that made it stopped.

- Time limits for `Web.fetch/2`. `config :web, connect_timeout: ms` is the
  time to open a connection, also for `Web.connect/2`. The default is
  10000 ms. `config :web, receive_timeout: ms` is the time to wait for the
  response headers or for the next part of a body. The default is
  300000 ms. A request that fails for one of these limits rejects with
  `Web.TypeError`.
- `Web.TextDecoder` and `Web.TextDecoderStream` decode more encodings of
  the Encoding Standard: UTF-16LE, UTF-16BE, x-user-defined, and the 28
  single-byte encodings (IBM866, the ISO-8859 group, KOI8-R, KOI8-U,
  macintosh, windows-874, windows-1250 to windows-1258, and
  x-mac-cyrillic). Each label of the Standard for these encodings is
  accepted: for example, `latin1` and `ascii` are labels of windows-1252.
  The tables come from the index files of the Standard. The library has no
  decoder for the multi-byte encodings of Chinese, Japanese, and Korean.
- The setting `config :web, http_protocols: [...]` selects the HTTP versions
  of `Web.fetch/2`: `[:http1]` (the default), `[:http2]`, or
  `[:http1, :http2]`. With the two versions, the server of a TLS connection
  selects the version.
- The field `status_text` of a `Web.fetch/2` response is `""` for a
  response that comes from HTTP/2, as the Fetch Standard specifies:
  HTTP/2 has no reason phrase. For HTTP/1.1, the text stays the usual
  reason phrase of the status. The text follows the version of the
  connection of each response.
- A `Web.FormData` is a body of a request or a response. It is encoded as
  `multipart/form-data`, with the encoding algorithm of the HTML Standard:
  the line ends of a name and of a string become CR LF, and a line feed, a
  carriage return, and a quotation mark in a name or a file name become
  `%0A`, `%0D`, and `%22`. A file with no type has the type
  `application/octet-stream`. The bytes of a file are read from its stream
  chunk by chunk. A form with all its data in memory has a content length
  and can be sent again after a redirect. Before, the header `content-type`
  was set, but the body had the entries of the form, not bytes, and the
  request failed.
- The setting `config :web, tls_options: [...]` gives TLS options to
  `Web.fetch/2` and to the TLS sockets of `Web.connect/2`: a keyword list of
  options of the Erlang application `:ssl`. For example, `cacertfile`
  names a file of private certificate authorities.
- `Web.Uint8Array.from/1`, which makes a view with a new buffer from a
  binary, iodata, a `Web.ArrayBuffer`, or a `Web.Uint8Array`.
- A short form for `inspect/1` of a `Web.Uint8Array`:
  `#Web.Uint8Array<"hello">`.
- `Web.WritableStreamDefaultController.signal/1`, as the attribute `signal`:
  an abort signal that aborts when the stream is aborted.
- `Web.TransformStreamDefaultController`, the controller that the callbacks
  of a transform stream get.
- `closed/1` for `Web.ReadableStreamDefaultReader`,
  `Web.ReadableStreamBYOBReader`, and `Web.WritableStreamDefaultWriter`, as
  the attribute `closed`.
- `use Web` aliases `Web.CountQueuingStrategy` and
  `Web.ByteLengthQueuingStrategy`.
- `Web.RangeError` and `Web.SyntaxError`, as the errors of ECMAScript.
- `body_used?/1` for `Web.Request` and `Web.Response`, as the attribute
  `bodyUsed`.
- `Web.CountingGovernor.start_link/1`, `start/1`, and `get/1` for a governor
  that has no owner. Use `{Web.CountingGovernor, capacity: 4, name: MyName}`
  in a supervision tree for a governor that all the processes of an
  application use.
- `Web.Promise.finally/2`, `Web.Promise.await/1`, and `Web.Promise.wait/1`.
  `wait/1` returns the outcome as `{:fulfilled, value}` or
  `{:rejected, reason}`.
- The options `:linger` and `:detached` for `Web.Promise.new/2`, and the
  option `:linger` for `Web.Promise.with_resolvers/1`.
- The application setting `config :web, linger: ms` for the time that a
  settled promise or an ended stream stays available. The default is 5000 ms.
- Tests that count the processes of the VM, to find streams that stay after
  their work is complete.
- TLA+ specifications in the directory `tla/` for the promise, the lifetime
  of a stream, the abort signal, and the body of a `fetch` response.
  `mix test` examines each specification with the native checker of the
  package `accord`, which needs no Java. Each specification has a constant
  `Bug`. Each value of `Bug` removes one rule of the design, and a test
  makes sure that the checker then finds the violation.
- Conformance tests in `test/tla/`. They do random operations on the real
  promise, stream, and signal, do the same steps on the specification, and
  compare the two states after each step.
- Property tests for `Web.Promise`, `Web.ReadableStream`, `Web.URL`, and
  the redirect table of `Web.fetch/2`.
- A property test that compares `Web.CountingGovernor` with a model: a
  counter with a first-in, first-out queue.
- The application setting `config :web, unread_body_timeout: ms` for the
  body of a `Web.fetch/2` response that holds its connection. A body that no
  process starts to read in that time releases its connection, and a later
  read rejects. The default is 300000 ms. The value `:infinity` removes the
  limit. A body that ended 1 ms after its headers holds no connection, and
  has no limit.
- The option `:unread_timeout` for a stream that holds a resource.
- `use Web` aliases `Web.ReadableStreamDefaultReader`.
- Tests that count the processes of the VM, to find promises that a
  long-lived process keeps.
- `Web.Promise.with_resolvers/0` for externally settled promises with explicit
  `resolve` and `reject` functions, including creator-lifecycle cleanup when
  the owning process exits before settlement.
- `Web.ReadableByteStreamController`, `Web.ReadableStreamBYOBReader`, and
  `Web.ReadableStreamBYOBRequest` for WHATWG byte streams with BYOB reader
  support, capability-scoped pull fulfillment, and consumer-owned buffer
  reuse.
- `Web.Socket` plus `Web.connect/1-2` for capability-gated TCP/TLS sockets
  with WHATWG stream endpoints, lifecycle promises, and `STARTTLS` upgrade
  support.
- `examples/secure_byob_stream.exs`, demonstrating BYOB `ReadableStream`
  pulls, capability-scoped request fulfillment, and stable consumer buffer
  reuse across reads.
- `examples/smtp_client.exs`, demonstrating an SMTP `STARTTLS` login flow
  built on `Web.connect/2` and `Socket.start_tls/2`.
- `Web.Symbol` and `Web.Symbol.Protocol` for TC39-style well-known
  symbols, including disposable-resource support for `BroadcastChannel`
  and `Port`.
- `using ... do` in `Web`, with support for `<-`, `=`, and implicit
  bindings that guarantee `Symbol.dispose` runs in an `after` block.
- `Web.BroadcastChannel` for WHATWG-style same-name message fan-out across
  the BEAM, backed by `Web.BroadcastChannel.Dispatcher`,
  `Web.BroadcastChannel.Adapter`, and the default distributed
  `Web.BroadcastChannel.Adapter.PG`.
- `Web.MessagePort` and `Web.MessageChannel` for WHATWG-style capability
  messaging with transferable, process-backed port handles.
- `Web.MessageEvent` for message payload delivery with standard event fields,
  including `data`, `origin`, `source`, and `target`.
- `Web.Internal.EventTarget.Server` plus fixture coverage for registry-backed,
  process-local listener storage and abort-driven watcher cleanup.
- `examples/cluster_auth_sync.exs`, demonstrating cross-node
  `BroadcastChannel` delivery, structured-clone isolation, and
  `AsyncContext` propagation.
- `examples/secure_worker.exs`, demonstrating capability handover with a
  private `MessagePort` and a secret-holding worker.
- `Web.structured_clone/1` and `Web.structured_clone/2`, backed by
  `Web.Internal.StructuredData`, with support for structured cloning of
  primitives, collections, `DateTime`, `Regex`, `Headers`,
  `URLSearchParams`, `Blob`, `File`, `ArrayBuffer`, and `Uint8Array`
  values.
- `Web.DOMException` with `DataCloneError` support for structured-clone
  validation failures.
- `Web.Platform.Test.JSHarvester` and JS-source loading in
  `Web.Platform.Test`, enabling structured-clone WPT subset coverage from
  upstream `structured-clone-battery-of-tests*.js` fixtures.
- Structured-clone regression/property suites and dedicated
  `Web.ArrayBuffer` coverage tests for transfer detachment,
  shared-reference preservation, and concurrent table startup races.

- `Web.MessagePort.start/1`, and the port message queue of the HTML
  Standard: a port keeps its messages until `start/1` or `onmessage/2`.
- The event `close` of a `Web.MessagePort`, with `onclose/1` and
  `onclose/2`: a port gets it when the other port closes, or when the
  process that holds the other port stops.
- The event `messageerror`, with `onmessageerror/1` and `onmessageerror/2`,
  for `Web.MessagePort` and `Web.BroadcastChannel`.
- The field `ports` of a `Web.MessageEvent` has the transferred message
  ports. The transfer list of `Web.MessagePort.post_message/3` can also be
  `[transfer: list]`.
- `Web.Event`, the event with no data of the DOM Standard.
- `Web.SuppressedError`, as the error of ECMAScript for a disposal that
  fails after a different error.
- `Web.Symbol.async_iterator/0` and `Web.Symbol.disposable?/1`. A
  `Web.Socket`, a `Web.ReadableStreamDefaultReader`, a
  `Web.ReadableStreamBYOBReader`, and a `Web.WritableStreamDefaultWriter`
  are disposable.
- `Web.Console`: the format of the Console Standard (`%s`, `%d`, `%i`,
  `%f`, `%o`, `%O`, `%c`, `%%`), `dir/2`, `dirxml/1`, `clear/0`, the
  columns of `table/2`, and the data of `trace/1`. Each message has the
  metadata `console_method`.
- `Web.Performance`: the options `:start_time` and `:detail` of `mark/2`,
  the options `:start`, `:end`, `:duration`, and `:detail` of `measure/3`,
  the type of `get_entries_by_name/2`, and `to_json/0`.
- TLA+ specifications for the message port, the broadcast channel, the
  disposal of `using`, the console, and the performance entries, with a
  model check and a conformance test for each one.
- A test with a second node for `Web.BroadcastChannel`. It has the tag
  `:cluster`, and it does not run on a machine that cannot start Erlang
  distribution.

### Changed

- The streams follow more steps of the Streams Standard. In the WPT runner,
  1030 of 1157 stream tests pass, where 737 passed:
  - A byte stream transfers the buffer of a chunk, of a view that a BYOB
    read gives, and of a new view of a response. `respond/2` and
    `respond_with_new_view/2` raise `Web.TypeError` or `Web.RangeError` as
    the Standard specifies. A close with bytes in the queue waits until a
    read takes them. `autoAllocateChunkSize` and the tee of a byte stream
    follow the Standard.
  - A stream does not pull before `start` is complete, and pulls one time
    for each need. The `closed` promise of a reader is the same promise at
    each read. A cancel does not release the lock of the reader. A cancel
    of an errored stream rejects with its error.
  - A `WritableStream` has the state "erroring": an abort or an error waits
    for the write or the close that runs. A `write` fulfils when the sink
    calls `controller.error/2` and returns normally. All the callers of an
    abort get the same result.
  - A pipe propagates a close and an error forward and backward, also while
    a read or a write waits, and rejects with the reason of its signal. A
    pipe reads one chunk each time the destination is ready.
  - `Web.CountQueuingStrategy.new/1` and `Web.ByteLengthQueuingStrategy.new/1`
    keep the value: the stream checks it. They raise `Web.TypeError` for a
    value that is not a number. They raised `Web.RangeError` for a value
    below zero.
  - `Web.TextEncoderStream` converts a chunk that is not a string with
    `String.Chars`. `Web.TextDecoderStream` refuses `nil`. A detached
    buffer gives no bytes to `Web.TextDecoder.decode/3`.
- **Breaking:** `Web.URL.new/2` and the setter `Web.URL.href/2` raise
  `Web.TypeError` for a URL that is not valid, as the URL Standard
  specifies. They raised `ArgumentError`. Change a `rescue ArgumentError`
  for a URL to `rescue Web.TypeError`. `Web.Request.new/2`,
  `Web.Response.redirect/2`, and `Web.fetch/2` keep their messages.
- `Web.URL.search/1` and `Web.URL.hash/1` give `""` for an empty query and
  for an empty fragment, as the URL Standard specifies. They gave `"?"` and
  `"#"`. `Web.URL.href/1` keeps the `"?"` and the `"#"`. A request for
  `http://a/?` still asks for `/?`.
- `Web.URLSearchParams` follows the `application/x-www-form-urlencoded`
  rules of the URL Standard:
  - the parser makes no pair for an empty part between two `&`, and a
    sequence of bytes that is not valid UTF-8 becomes U+FFFD;
  - the serializer keeps `*`, `-`, `.`, `_`, and the ASCII letters and
    digits, and encodes `~` as `%7E`;
  - `sort/1` compares the UTF-16 code units of the names, as JavaScript
    does, and keeps the sequence of the pairs with the same name;
  - `new/1` accepts a pair as a list of two items, and raises
    `Web.TypeError` for an item that does not have two items.
- **Breaking:** `Web.URLPattern` follows the algorithms of the URL Pattern
  Standard: the tokenizer, the pattern parser, the constructor string
  parser, the steps "process a URLPatternInit", and the encoding callbacks.
  All the 373 URLPattern tests of WPT pass, where 252 passed.
  - A pattern that is not valid raises `Web.TypeError`. It raised
    `ArgumentError`. This includes a relative pattern string with no base
    URL, and a base URL as a separate argument of a map input.
  - The base URL gives each component that is less specific than the
    components of the input, and an empty base URL raises `Web.TypeError`.
  - The pattern string of a component is the canonical text of the
    Standard. For example, `/foo/(.*)` gives `/foo/*`.
  - A regular expression of a pattern has the syntax of ECMAScript with the
    flag `v`, and the library refuses the syntax that ECMAScript refuses.
  - `exec/3` gives `:inputs`, and a group that does not take part in the
    match is `nil`. An input that the URL parser refuses gives `nil`.
  - In `"https://user:pw@host"`, `:pw` is a named group of the username,
    as in the Standard. Write `user\:pw` for a password.
  - A map input gives its base URL in the key `:base_url`.
- **Breaking:** the body of a `Web.Request` and of a `Web.Response`
  follows the Fetch Standard. In the WPT runner, 521 of 697 fetch tests
  pass, where 457 passed.
  - A body function, such as `text/1`, takes the reader before it returns,
    and the lock stays: a later `get_reader/1` or `Enum` raises
    `Web.TypeError`.
  - `Web.Request.new/2` with a request as the input disturbs and locks the
    body of that request, also in `Web.fetch/2`. The option `body: nil`
    keeps the body of the input. A constructor that raises does not change
    the input.
  - A constructor refuses a stream that is disturbed or locked.
  - The headers of a response of `Web.fetch/2`, of `Web.Response.error/0`,
    and of `Web.Response.redirect/2` have the guard `"immutable"`:
    `Web.Headers.append/3`, `set/3`, and `delete/2` raise
    `Web.TypeError` for them. A new `Web.Headers`, `Web.Request`, or
    `Web.Response` from these headers has the guard `"none"`.
  - Each body that the library makes is a byte stream, and a `Web.Blob`
    body is one chunk. The clone of a body gives the second branch a
    structured clone of each chunk. A pipe disturbs the source at once.
- **Breaking:** `Web.File` follows the File API for its name. The field
  `name` is the name of the file, and the field `filename` is removed. The
  constructor is `Web.File.new(file_bits, file_name, options \\ [])`, as
  `new File(fileBits, fileName, options)`, with the options `:type` and
  `:last_modified`. Change `Web.File.new(parts, filename: name)` to
  `Web.File.new(parts, name)`. The name of a form field is the name of the
  entry of a `Web.FormData`, not a field of the file. A file part of a
  parsed form with no `Content-Type` has the type `text/plain`, as the
  steps of `formData()` specify.
- **Breaking:** `Web.AbortSignal.throw_if_aborted/1` raises the reason of
  the signal, also a reason that is not an exception, as `throwIfAborted()`
  throws. It put the reason in an `AbortError` before.
- **Breaking:** two `Web.Event` structs of the same type are not equal: each
  one has its own flags.
- **Breaking:** a callback of a source, a sink, or a transformer has no
  time limit, as in the Streams Standard. A callback that returns a promise
  that stays pending keeps its read, write, close, or abort pending, and
  the stream stays in its state. Before, the stream failed with a
  `Web.TypeError` after 30 s. Use an `AbortSignal` (for example
  `AbortSignal.timeout/1`) in the callback, or a time limit of your own,
  to stop a callback that waits too long. A callback, and a pull that goes
  to the process of an enumerable, start no timer now: a read of
  `ReadableStream.from/1` costs approximately 1 µs less for each element.
  See `BENCHMARKS.md`.
- **Breaking:** the public API has only the names of the Web Standards and
  of TC39, also of the TC39 proposals. Each name has its Elixir form: snake
  case, a setter with the name of the attribute (`name/2`), and the suffix
  `?` only for a boolean attribute. `start_link/1`, `child_spec/1`, and the
  implementations of the Elixir protocols stay public. An extension point
  is internal. See `CONTRIBUTING.md`. The changes:
  - The bytes: `Web.Uint8Array.to_binary/1`, `Web.ArrayBuffer.data/1`, and
    `Web.ArrayBuffer.detach/1` are internal. Use `to_string/1`: the two
    structs implement `String.Chars`.
  - The streams:
    - `Web.ReadableStream.read/1` is removed, and `get_desired_size/1` and
      `release_lock/2` are internal. Read and release with a reader.
    - `Web.WritableStream.write/2`, `ready/1,2`, `desired_size/1`,
      `backpressure?/1`, `release_lock/1,2`, `close/2`, and `abort/3` are
      removed. Use a writer.
    - `Web.WritableStreamDefaultController.desired_size/1` and the
      `wait_for_capacity/1` of the controllers are removed.
    - The second argument of `Web.ReadableStream.new/2` and
      `Web.WritableStream.new/2` is the queuing strategy: a keyword list, a
      map, or a strategy struct. The options of the engine are internal. A
      source is a map with the members of `UnderlyingSource`. A pid, a
      function, or a tuple as a source goes to `start_link/1`.
    - `Web.TransformStream.new/3` takes `transformer`, `writable_strategy`,
      and `readable_strategy`, as the constructor of the Standard.
    - `Web.ReadableStream.from/1` takes only an enumerable, as
      `ReadableStream.from(asyncIterable)`. A binary, a `Web.Blob`, a
      `Web.ArrayBuffer`, a `Web.Uint8Array`, and `nil` give a
      `Web.TypeError`: for a stream of bytes, use the body of
      `Web.Response.new(binary)` or `Web.Blob.stream/1`. A
      `Web.URLSearchParams` gives its pairs, and a `Web.ReadableStream` gives
      a new stream that reads it.
    - `Web.CountQueuingStrategy.new/1` and `Web.ByteLengthQueuingStrategy.new/1`
      take the dictionary `QueuingStrategyInit`, for example
      `new(high_water_mark: 4)`. The field `size` holds the function of the
      Standard: `strategy.size.(chunk)`.
    - The functions of a stream take a stream struct, not a pid.
      `pipe_to/3` and `pipe_through/3` give a `Web.TypeError` for a value
      that is not a stream.
    - The pipe options `:preventClose`, `:preventAbort`, and
      `:preventCancel` are removed: use `:prevent_close`, `:prevent_abort`,
      and `:prevent_cancel`.
    - The default reason of `cancel` and `abort` is `nil` (undefined), and
      each controller has `error/1`.
    - `Web.Stream`, the engine and its behaviour, and `Web.DSL` are
      internal.
  - Fetch, URL, and files:
    - `Web.URL.set_hostname/2`, `set_password/2`, `set_pathname/2`,
      `set_port/2`, `set_protocol/2`, and `set_username/2` are
      `hostname/2`, `password/2`, `pathname/2`, `port/2`, `protocol/2`, and
      `username/2`. `Web.URL.rclone?/1` is internal.
    - `Web.Response.new/1` takes a body, as `new Response(body)`, and
      `new/2` takes a body and the members of `ResponseInit` (`:status`,
      `:status_text`, and `:headers`). Change
      `Response.new(body: body, status: 201)` to
      `Response.new(body, status: 201)`.
    - `Web.Headers.get/2` has no default argument, `getSetCookie/1` is
      removed (use `get_set_cookie/1`), and `to_list/1` is internal.
    - `Web.URLSearchParams.has?/2` is removed (use `has/2`), and `to_list/1`
      is internal (use `Enum.to_list/1`).
    - `Web.FormData.has?/2` is `has/2`, and `new/1` is `new/0`.
      `Web.FormData.cancel/2` is removed, and `content_type/1` and
      `parse/3` are internal.
    - `Web.URLPattern.match_context/3`, `params/0`, `compare_component/3`,
      and the option `:pinned` are removed. `has_reg_exp_groups/1` is
      `has_reg_exp_groups?/1`, and `new/3` takes the input, the base URL,
      and the options, as the first constructor of the Standard.
    - `Web.Blob.json/1` is removed. `Web.Blob.new/0` makes an empty blob.
    - `Web.Body`, `Web.Resolver`, and `Web.Dispatcher` are internal, and
      the option `:dispatcher` of `Web.Request.new/2` and `Web.fetch/2` is
      removed.
  - The events, the promises, and the other interfaces:
    - `Web.EventTarget.addEventListener/4`, `dispatchEvent/2`, and
      `removeEventListener/4` are removed: use the snake_case names.
      `Web.EventTarget.Protocol` and the callbacks of `use Web.EventTarget`
      are internal.
    - `Web.Event.set_cancel_bubble/2` and `set_return_value/2` are
      `cancel_bubble/2` and `return_value/2`. The options `:target` and
      `:current_target` of the event constructors are removed.
    - `Web.AbortSignal.receive_abort/3` and `start_link/0`, and
      `Web.DOMException.abort_error/0` and `timeout_error/0`, are internal.
      `Web.DOMException.new/2` is the constructor
      `new DOMException(message, name)`.
    - `Web.Promise.new/1` and `Web.Promise.with_resolvers/0` have no
      options. `Web.Promise.await/1` and `wait/1` are internal: use
      `Web.await/1`. `Web.Promise.AggregateError` is `Web.AggregateError`.
    - `Web.Symbol.disposable?/1` and `Web.Symbol.Protocol` are internal.
    - `Web.AsyncContext.Snapshot.take/0` is `new/0`, and
      `Web.AsyncContext.Variable.new/1` takes `:name` and `:default_value`,
      as `new AsyncContext.Variable({name, defaultValue})`.
    - `Web.Governor.Token` is `Web.GovernorToken`, and `Web.using/2`
      releases it, as `[Symbol.dispose]()`. `Web.Governor.with/2` calls its
      function with no argument. `Web.CountingGovernor.start/1` is removed.
      `Web.CountingGovernor.get/1` stays: it gives the governor that a
      supervisor started.
    - `Web.BroadcastChannel.Adapter` is internal.
    - The fields `entryType` and `startTime` of `Web.Performance.Mark` and
      `Web.Performance.Measure` are `entry_type` and `start_time`, and the
      camelCase copies of the functions of `Web.Performance` and
      `Web.Console` are removed.
    - `Web.connect/2` takes only the option `:secure_transport`. The other
      options are settings of the application (`config :web, tls_options:`
      and `connect_timeout:`). `Web.Socket.start_tls/1` has no argument, as
      `startTls()`. The keys of `opened` are `remote_address` and
      `local_address`.
    - The option `:ignoreBOM` of `Web.TextDecoder.new/2` is removed: use
      `:ignore_bom`.
- **Breaking:** the results and the inputs of the public functions follow
  the Standards. The changes:
  - `Web.Blob.text/1`, `array_buffer/1`, and `bytes/1` (also of a
    `Web.File`) return a promise, as the File API specifies. Change
    `{:ok, text} = Blob.text(blob)` to `text = Web.await(Blob.text(blob))`.
  - The option `:signal` of `Web.Request.new/2`, `Web.fetch/2`,
    `pipe_to/3`, and `pipe_through/3`, and the signals of
    `Web.AbortSignal.any/1`, accept only a `Web.AbortSignal` (or `nil` for
    the option). Each other value gives a `Web.TypeError`.
  - `Web.fetch/2` does "scheme fetch" of the Fetch Standard: `about:blank`
    gives an empty HTML response, a `data:` URL goes through the "data: URL
    processor", and `file:` and each scheme that the library does not know
    give a network error. Before, such a URL went to the HTTP client. The
    schemes of the library, `tcp:` and the form `remote:path`, stay.
  - A setter that gets `nil` takes the string `"null"`, as Web IDL converts
    `null`: `Web.URL.port(url, nil)` makes no change, and a name or a value
    `nil` of `Web.URLSearchParams`, `Web.Headers`, or `Web.FormData` is
    `"null"`. Use `""` to clear a part of a URL. `Web.URL.port/2` with a
    number outside 0 to 65535 makes no change. `Web.FormData.append/4` and
    `set/4` with a file name and a value that is not a blob raise
    `Web.TypeError`.
  - The sockets follow the draft of the WinterTC Sockets API:
    - `Web.Socket.start_tls/1` returns the new socket at once, and its
      `opened` fulfils after the handshake. Remove the `await`. The first
      socket closes, and `Web.Socket.upgraded?/1` gives `true`. The field
      `upgraded` is removed.
    - `closed` and `Web.Socket.close/2` fulfil with `nil`. A failure
      rejects with a `Web.TypeError` whose message starts with
      "SocketError: ", and whose `cause` is the reason.
    - `close(reason)` cancels the readable side and aborts the writable
      side with the reason. The default reason is `nil`.
    - A cancel of the readable side, and a close or an abort of the
      writer, do not close the socket: a close of the writer sends a TCP
      half close. Call `Web.Socket.close/2` to close the socket.
    - The options `:allow_half_open`, `:sni`, and `:alpn` work. An option
      that is not valid raises at `Web.connect/2`. When the process that
      holds a socket stops, `closed` fulfils.
  - `Web.MessageChannel.new/0` returns a struct with `port1` and `port2`.
    Change `{port1, port2} = MessageChannel.new()` to
    `%{port1: port1, port2: port2} = MessageChannel.new()`.
  - A `Web.MessageEvent` is an `Event`, with the fields and the functions of
    `Web.Event`. The events `message`, `messageerror`, and `close` of a port
    or a channel are trusted, and a listener sees the phase AT_TARGET.
  - The getters `Web.Event.default_prevented/1`, `cancel_bubble/1`, and
    `return_value/1` are `default_prevented?/1`, `cancel_bubble?/1`, and
    `return_value?/1`: they are boolean attributes.
  - `Web.Performance.mark/2` and `measure/3` ignore an option that they do
    not know. A number as a start or end mark is the name of a mark: give a
    time with `:start` and `:end`.
- **Breaking:** each `Web.Request` has its own `Web.AbortSignal`, as the
  Fetch Standard specifies: a new signal that depends on the option
  `:signal` or on the signal of the input request, and a new dependent
  signal for `Web.Request.clone/1`. Thus `request.signal` is never `nil`,
  and it is not the signal of the option: use `aborted?/1`, `reason/1`, or
  a listener, not `==`. `Web.Request.new(request)` gives a new request. The
  signal is lazy: it has no process until a listener or `onabort/2` needs
  one, and each copy of the struct uses the same process. A read of the
  signal and `Web.fetch/2` start no process. `form_data/1` of a request
  does not use the signal of the request, as "consume body" specifies. The
  abort events of the signals that depend on one signal come in the
  sequence in which the signals were made.
- **Breaking:** the listener steps of each event target follow the DOM
  Standard:
  - `dispatch_event/2` of a `Web.MessagePort` or a `Web.BroadcastChannel`
    runs the listeners in the calling process, waits for them, and returns
    `false` when a listener cancels the event.
  - `dispatch_event/2` raises a `Web.DOMException` with the name
    `InvalidStateError` for an event that is in a dispatch, or that is not
    initialized, for example a map `%{type: "x"}` or a struct literal. Make
    the event with `Web.Event.new/2`, `Web.CustomEvent.new/2`,
    `Web.MessageEvent.new/2`, or `init_event/4`.
  - On a port and a channel, `:capture` and `:passive` have their effect, a
    `once` listener is removed before its call, and a listener that an
    earlier listener removed does not run.
    `Web.MessagePort.remove_event_listener/4` and
    `Web.BroadcastChannel.remove_event_listener/4` take the options.
  - An option `:signal` that is not a `Web.AbortSignal` raises
    `Web.TypeError`, also with the callback `nil`.
- `Web.Blob` follows the File API: the type becomes ASCII lowercase, and a
  type with a character outside U+0020 to U+007E becomes `""`. The functions
  of `Web.Blob` accept a `Web.File`. `Web.Blob.stream/1` is a byte stream,
  with one chunk for each part, of 64 KiB at most. `Web.FormData` makes a
  `Web.File` with the name `"blob"` from a blob, as the steps "create an
  entry" specify.
- A `Web.TransformStream` has two processes, one for each side, as
  InitializeTransformStream specifies: the writable side can be "erroring"
  while the readable side is readable. A cancel, an abort, and a close call
  the transformer one time, and the others get its result. An abort during
  a transform waits for that transform. The two sides share
  [[backpressure]] in one `:atomics` cell, and a transform stream with no
  function `transform` runs no worker. A pipe through a transform stream
  takes 27.5 µs for each small chunk, where it took 41.3 µs, and gives
  approximately 2100 MiB of chunks of 64 KiB each second, where it gave
  1400. See `BENCHMARKS.md`.
- The abort of a pipe follows the sequence of ReadableStreamPipeTo: the
  sink `abort` of the destination starts, and returns, before the source
  gets its `cancel`. When the destination has a write or a close in flight,
  the cancel comes first, as in JavaScript. Before, the two callbacks ran
  at the same time, and on a busy machine the `cancel` could come first. A
  pipe now waits until the sink `abort` returns before the cancel. The
  priority messages of Erlang/OTP 28 cannot
  give this sequence: they change the sequence of the messages in one
  mailbox only, not the work of two processes.
- `Web.WritableStream.abort/2` and `Web.WritableStreamDefaultWriter.abort/2`
  run the listeners of the signal of the controller in the calling process,
  in the abort steps, as WritableStreamAbort specifies. A listener can call
  `abort/2` or `close/1` again, with the result of the Standard. A stream
  with no signal costs no more messages. An abort that the library starts,
  for example the abort of a pipe, runs the listeners in a new process. A
  listener that awaits a result of the same stream waits until the time
  limit of the callback.
- The TLA+ specifications `tla/PipeAbort.tla` and `tla/PublicAbort.tla`,
  with a property test of the abort of a pipe on the real code.
- A `Web.ReadableStreamBYOBReader` has its own lock, as the default reader
  has. A reader that released its lock gets a `Web.TypeError` for a read
  and a cancel, a second `release_lock/1` has no effect, and `closed/1`
  gives the same promise until a release rejects it. A BYOB reader struct
  that you make yourself is not a reader of the stream.
- `Web.TransformStream.new/2` returns when the two sides have the end of a
  `start` that gives a value or a settled promise. Before, a cancel just
  after the constructor could find the writable side "erroring".
- The tee of a byte stream takes the current BYOB request of a branch when
  it starts a read, as pull1Algorithm and pull2Algorithm specify.
- A `Web.WritableStreamDefaultWriter` has its own lock, as a reader has. A
  writer that released its lock gets `Web.TypeError` for each operation.
  `ready` and `closed` give the same promise until the Standard replaces
  it. A size function that raises errors the stream, and the write rejects.
- The readable side of `Web.CompressionStream` and of
  `Web.DecompressionStream` has the high water mark 0, as the Compression
  Standard specifies: a transform starts only when a reader asks for a
  chunk, thus a write fulfils only after a read. Await a write after you
  start a read, or use a pipe. A compression stream enqueues all the output
  of a chunk at once. A decompression stream keeps its limit of 64 KiB for
  each piece: a write whose output is larger completes when the reads took
  its pieces.
- A decompression stream gives the output of a chunk before the
  `Web.TypeError` for data after the end, for each format.
- `README.md` does not say that the library has 100 % WPT compliance for
  `URL`. The JSON data of WPT for the parse of a URL passes, but the
  JavaScript files of WPT show differences: see "Web Platform Tests in
  QuickJS".
- The readable side of a `Web.Socket` reads the connection one message for
  each pull of the stream. The stream sends its pull to the socket process
  directly, with no worker, and has one pull at a time, as the Streams
  Standard specifies. The socket process makes no call to the stream for
  each chunk. A message of the connection has 64 KiB at most. A read of
  64 MiB gives approximately 1700 MiB/s, where it gave 157 MiB/s. A socket
  has 6 processes, where it had 7. A write asks the socket for its
  transport one time.
- A connection to an IP address gives the address to Erlang as a tuple.
  Erlang looks up a host in text as a name, also when it is an IP address:
  each new connection to an IP address takes approximately 200 µs less.
  This applies to `Web.fetch/2` and to `Web.connect/2`.
- `Web.fetch/2` of a `tcp:` URL, and of an rclone remote, has one process:
  the process of the request, which is also the promise, as for HTTP. It
  opens the socket, writes the request body, and holds the response body.
  Before, a body used 15 processes: a bridge, the processes of a
  `Web.Socket`, a second stream, and a process that examined the abort
  signal each 25 ms. A small response takes approximately 600 µs, where it
  took 1450 µs, and a stream read gives approximately 1700 MiB/s, where it
  gave 120 MiB/s. See `BENCHMARKS.md`. The body follows the rules of an HTTP
  body: an abort puts it in the errored state with the reason of the
  signal, where it ended with no error before. A signal that is aborted
  before the fetch makes no connection. A request body that is not bytes
  gives `{:error, %Web.TypeError{}}` from `Web.Dispatcher.TCP.fetch/1`,
  where it raised before.
- The process of an HTTP request sets its flag before it asks the socket
  for a message. Before, a message could come between the request and the
  flag. The TLA+ specification `tla/SocketFlow.tla` has the new invariant
  `FlagMatchesSocket`, and its property test examines it on the real
  process of an HTTP request and of a `tcp:` request.
- `Response.json/1` keeps the last value of a key that is in an object two
  times with less work: the decoder reverses the pairs of an object only
  when a key is in it two times. A large text decodes approximately 8 %
  faster.
- `Web.CompressionStream` and `Web.DecompressionStream` keep their zlib
  handle in the worker of the stream, and close it in the callback
  `terminate`. Before, each stream started an `Agent` to keep the handle.
  `Web.DecompressionStream` uses the decoder of `Web.fetch/2`: it gives
  chunks of 64 KiB at most.
- The process of a request does not set the socket again before it gives
  the connection back to the pool: the socket is passive already after the
  end of the response.
- The callbacks of a stream run in one worker process for the life of the
  stream. Before, each callback started a new task through one supervisor
  of the application. The supervisor `Web.TaskSupervisor` is removed. A
  promise and a pipe also start with no supervisor.
- The pull of `Web.ReadableStream.from/1` goes from the stream process to
  the process of the enumerable, and back, with no worker between them. A
  source that is a process gets its message `{:pull, stream}` from the
  stream process directly. A read of `from/1` with `Enum` takes
  approximately 7 µs for each element, where it took 26 µs, and many
  streams use all the cores: 4 streams at the same time read 490000
  elements each second, where they read 53000.
- The internal readers of a stream (`Enum`, a pipe, and the body functions
  such as `Web.Response.text/1`) take all the chunks of the queue in one
  message, as reads one after the other do. Such a read does not change
  the pulls: the stream pulls only as the Streams Standard specifies. A
  source that enqueues many chunks for one pull, such as the body of a
  `fetch` response, thus gives many chunks in one message. A pipe reads no
  more chunks at once than the desired size of its destination.
- **Breaking:** `Web.ReadableStream.from/1` of an enumerable follows
  `ReadableStream.from()` of the Streams Standard: the high water mark is
  0, and each pull takes one element. Thus the enumerable advances only
  for a read, one element for each read. Before, the stream took one
  element before the first read. A cancel stops the enumerable after the
  element of the pull that runs.
- A pull that runs at a cancel is stopped, and the cancel runs in a new
  worker. A callback that fails writes no crash report of a task.
- The URL parser, the headers, and the MIME parser use binary pattern
  matching in place of regular expressions. On Erlang/OTP 28 and later,
  each run of a regular expression imports its pattern again.
  `Web.Request.new/2` takes approximately 3 µs, where it took 106 µs. A
  usual URL of a request takes a short path of the parser.
- A request of `Web.fetch/2` has two processes. The process of the request
  is also the promise of `fetch`. It follows the redirects, and it holds a
  body that does not end 1 ms after its headers. Its worker runs the HTTP
  client and sends each event to it, thus the process of the request
  always answers: the readers, the abort signal, and the time limits.
  - A body that ends 1 ms after its headers goes in the struct of the
    response, and the worker gives that response directly to the
    processes that await the promise. Then the two processes have no
    work, and `text/1` starts none.
  - A body that the process of the request holds gives all its bytes to a
    read such as `text/1` in one message, and gives each piece to a stream
    read when the stream pulls. The worker stops to read the connection
    while 64 KiB have no reader.
  - The stream of a body monitors the process of the request: a stop of
    that process before the end of the body is an error, as before. A
    cancel stops the two processes, thus the connection does not stay.
  - The dispatcher gives the parts of the parsed URL to Finch, thus Finch
    does not parse the URL again with regular expressions.
  - A small request with `fetch` and `Web.Response.text/1` takes
    approximately 135 µs, where it took 630 to 680 µs, and 50 processes do
    18000 requests each second, where they did 5200. Req takes
    approximately 110 µs, and does 22600 requests each second. See
    `BENCHMARKS.md`.
- **Breaking:** the JSON functions use the module `JSON` of Elixir and the
  module `:json` of Erlang/OTP. The package does not depend on Jason now.
  - `Web.Response.json/2` encodes with the protocol `JSON.Encoder`. A
    struct that has only an implementation of `Jason.Encoder` raises
    `Web.TypeError`: derive `JSON.Encoder` for it.
  - `json/1` of a request or a response does the algorithm "parse JSON
    from bytes" of the Fetch Standard: the UTF-8 decode of the bytes, then
    `JSON.parse`. A byte order mark at the start is permitted, and bytes
    that are not valid UTF-8 become U+FFFD. Before, the two gave a
    rejection.
  - An object with the same key two times keeps the last value, as in
    ECMAScript.
  - `Web.Blob.json/1` returns `{:error, %JSON.DecodeError{}}` for text that
    is not JSON.
  - Some differences with ECMAScript stay. A number that is too large for
    a float, such as `1e400`, and the escape of a lone surrogate, such as
    `"\uD800"`, give a rejection. `-0` is the integer 0.
  - `json/1` of a body of 8 MiB takes approximately 171 ms, where it took
    429 ms. For a large body, the process of the promise gets a large heap
    at the start.
- `text/1` of a request or a response makes no copy of a body that has one
  chunk, and does the fast check of `String.valid?/2` for valid UTF-8.
  Only text that is not valid gets the scan that replaces each invalid
  sequence. A body of 8 MiB in one chunk takes approximately 2.2 ms, where
  it took 87 ms, and a body of 8 MiB in chunks of 64 KiB takes 8 ms, where
  it took 70 ms.
- **Breaking:** `Web.Blob.text/1` does the UTF-8 decode of the File API: a
  byte order mark goes away, and each sequence that is not valid UTF-8
  becomes U+FFFD. Before, it gave the bytes with no change.
- The tests load the modules of the package, of Elixir, of Logger, and of
  ExUnit before they start. Thus the first use of a module does not wait
  for the code server on a busy machine. Before, a test of the event
  `messageerror` failed sometimes for this cause.
- **Breaking:** the promise `closed` of a `Web.Socket` rejects when the
  socket fails, as the Sockets API specifies. It fulfils for a close, for
  a close of the peer, and for a cancel of the readable side. Before, it
  always fulfilled.
- **Breaking:** `Web.Socket.close/2` ends the two streams of the socket. A
  function on a socket that is closed returns immediately. The field
  `address` of the struct is a pid, and the option `:request_timeout` is
  removed.
- **Breaking:** `Web.await/1` is a function, not a macro, and it returns a
  value that is not a promise with no change, as `await` of ECMAScript.
  Before, a call needed `require Web`, and a value that was not a promise
  raised.
- **Breaking:** a pipe to a destination, or from a source, that is closed
  or stopped rejects with `Web.TypeError`. Before, it rejected with an atom
  such as `:closed`. A pipe to an errored destination rejects with the
  error of the destination and cancels the source. Before, it did not
  settle.
- **Breaking:** a body read on a stream that stops rejects with
  `Web.TypeError` and the cause. Before, it rejected with the atom
  `:not_locked_by_reader`.
- The callback `error/2` of the behaviour `Web.Stream`,
  `Web.ReadableStream.force_unknown_error/1`, and the socket option
  `:ssl_start_fun` are removed: nothing used them. The functions
  `Web.Stream.call` and `control_call` have no time limit argument.
- The code has 3 lines that the coverage does not count, where it had 59,
  and the coverage is 100 % with no line that only some runs cover.
- The benchmark scripts in `bench/` use the functions of this version.
  `bench/selective_receive.exs` is removed: it measured the VM, not the
  library.
- **Breaking:** `Web.structured_clone/2` accepts all data: atoms, tuples,
  bitstrings, improper lists, and structs that have only data. Before, a
  map with an atom key raised `DataCloneError`. A `Web.Promise`, a
  `Web.AbortSignal`, a `Web.AbortController`, a `Web.Request`, a
  `Web.Response`, and a `Web.ReadableStream` cannot be cloned. A detached `Web.ArrayBuffer` raises
  `DataCloneError`, not `Web.TypeError`, and options that are not correct
  raise `Web.TypeError`, not `ArgumentError`.
- `Web.structured_clone/2` reads the value one time, and the clone of data
  with no `Web.ArrayBuffer` or `Web.Blob` is the same term. Before, the
  function made a binary of each part of the value: its time increased
  with the square of the depth.
- **Breaking:** a function on a `Web.MessagePort` that is closed or
  detached has no effect and gives no error, as in a browser. Before, each
  function waited 100 ms and raised `DataCloneError`. Only the transfer of
  such a port raises `DataCloneError`.
- **Breaking:** `Web.MessagePort.add_event_listener/4` does not start the
  port, as in a browser. Call `Web.MessagePort.start/1`.
- **Breaking:** `Web.MessagePort.post_message/3` with the port itself in
  the transfer list raises `DataCloneError`.
- **Breaking:** `Web.BroadcastChannel.post_message/2` on a closed channel
  raises `InvalidStateError`, as the HTML Standard specifies. Each other
  function on a closed channel has no effect.
- **Breaking:** the structs `Web.MessagePort` and `Web.BroadcastChannel`
  have no field `onmessage`, and their field `address` is a pid. The field
  `origin` of a `Web.MessageEvent` is `""` when there is no origin.
- **Breaking:** the modules `Web.BroadcastChannel.Dispatcher` and
  `Web.BroadcastChannel.DispatcherSupervisor` are removed. An adapter of
  `Web.BroadcastChannel` gets the pid of each channel, not the pid of a
  dispatcher, and the message is `{:broadcast_channel_message, payload}`.
- The setting `:broadcast_governor` limits `post_message/2` in the process
  that sends the message.
- **Breaking:** `Web.using/2` follows the rules of ECMAScript. A value that
  is not disposable, and not `nil`, raises `Web.TypeError` before the
  block. When the block and the disposal fail, the macro raises
  `Web.SuppressedError`.
- **Breaking:** `Web.Console.time/1` does not start a timer that runs: it
  writes a warning. `Web.Console.assert/2` starts its message with
  `Assertion failed`. `Web.Console.table/2` has the column `(index)`, a
  map gives one row for each pair, and each line of a message in a group
  has the indent.
- **Breaking:** `Web.Performance.time_origin/0` is the time origin in
  milliseconds of Unix time. Before, it was a value of the monotonic
  clock, usually below zero. A mark that does not exist raises
  `Web.DOMException` with the name `SyntaxError`, not `ArgumentError`. The
  entries are in the sequence of their start times.
- The packages `mint` (1.11.0), `hpax` (1.1.0), and `idna` (8.0.0) are
  updated, because `mix hex.audit` reported security advisories for the
  versions before. `idna` 8.0.0 has the tables of Unicode 18.0.
- The fixtures of the Web Platform Tests are pinned to a newer commit, which
  agrees with Unicode 18.0.
- **Breaking:** `Web.URL` accepts each host that is all ASCII and has no
  forbidden code point, and changes it to lowercase, as the current URL
  Standard specifies. A label with the prefix `xn--` that is not valid is
  thus accepted in an ASCII host, as in browsers. Before, such a host was
  refused.
- **Breaking:** `Web.Request.new/2` does the checks of the `Request`
  constructor of the Fetch Standard, and raises `Web.TypeError` for input
  that the Standard refuses. Before, such input was accepted and sent.
  - The URL must be an absolute URL. A text with no scheme, such as
    `"example.com/path"` or `"/path"`, is refused. Before, such a text
    got the prefix `http://` or `http://localhost`.
  - A URL that includes credentials is refused.
  - The method must be an HTTP token, and must not be `CONNECT`, `TRACE`,
    or `TRACK`.
  - Only the methods `DELETE`, `GET`, `HEAD`, `OPTIONS`, `POST`, and `PUT`
    are changed to uppercase. Each other method keeps its case: `"patch"`
    stays `"patch"`. A method that is an atom is always changed to
    uppercase.
  - A body is refused with the methods `GET` and `HEAD`. This is also
    applicable to a `tcp:` request: give a method such as `"POST"`.
  - The redirect mode must be `"follow"`, `"error"`, or `"manual"`.
  - A body that is a stream needs the option `duplex: "half"`, as the Fetch
    Standard specifies. A stream is a `Web.ReadableStream`, or an enumerable
    that is not a list.
  - With a request as its input, `new/2` applies the members of `init`.
    Before, it ignored them.
- A request waits for a free connection with no time limit, as in a
  browser. Before, more than 25 requests to one origin at the same time
  could fail after 5000 ms.
- The default connect time of `Web.connect/2` changes from 5000 ms to
  10000 ms, which is the new setting `connect_timeout`.
- **Breaking:** a cancel and an abort settle after the callback of the
  source or sink, as the Streams Standard specifies.
  - The callback runs in a task. A promise that it returns is awaited, and
    a value that it throws is the rejection reason. Before, the callback
    ran in the process of the stream, and its promise was ignored.
  - A cancel of a closed stream, and a second cancel, call no callback.
  - A halt of an enumeration, such as `Enum.take/2`, cancels the stream and
    does not wait for the callback.
  - The promise of a cancel of one branch of `tee/1` stays pending until
    the second branch is cancelled or the stream ends. It rejects with the
    value that the cancel callback of the stream throws.
- **Breaking:** the constructors of the streams validate their input.
  - `Web.ReadableStream.new/2` raises `Web.TypeError` for an underlying
    source that is not valid, for a callback that is not a function, and
    for a type that is not `"bytes"`.
  - `Web.WritableStream.new/1` raises `Web.TypeError` for a sink that is not
    a map, and `Web.RangeError` for a sink with the key `:type`.
  - A limit that is not a number, or that is below zero, raises
    `Web.RangeError`.
  - `get_reader/2` accepts only the mode `"byob"`. The mode `"default"`
    raises `Web.TypeError`, as in the Standard.
  - `Web.ReadableStream.from/1` raises `Web.TypeError` for a value that is
    not enumerable. Before, it raised `ArgumentError`.
- **Breaking:** `pipe_to/3` and `pipe_through/3` have the two locks when they
  return. `pipe_through/3` raises `Web.TypeError` for a locked stream.
  Before, it returned and the pipe did nothing. A pipe releases its locks
  before its promise settles.
- The pipe options have Elixir names: `:prevent_close`, `:prevent_abort`, and
  `:prevent_cancel`. The names of the Standard are accepted also.
- `Web.URLPattern` accepts the class syntax of the regular expression flag
  `v` in a group: a nested class, a subtraction (`[[a-z]--[aeiou]]`), and an
  intersection (`[\\d&&[0-4]]`). Before, the library replaced two fixed
  texts of the conformance tests, and each other use of this syntax gave a
  result that was not correct.
- The response body of a `tcp:` request has the unread limit of
  `unread_body_timeout`, as an HTTP response body has.
- The control messages of a stream are usual messages. The code asked for
  priority messages, but that request had no effect, and it would put a
  `close` before the chunks that were enqueued before it.
- **Breaking:** `Web.TextDecoder.new/2` and `Web.TextDecoderStream.new/2`
  raise `Web.RangeError` for a label that is not valid, as the Encoding
  Standard specifies. Before, they raised `Web.TypeError`. A label can have
  ASCII whitespace at its two ends, and its ASCII letters can be uppercase;
  whitespace and letters that are not ASCII are not changed. The option
  `:ignore_bom` has its Elixir name; the name `:ignoreBOM` is accepted
  also.
- `Web.TextDecoder` starts again after a `decode/3` call with no `stream`
  option, as the Encoding Standard specifies. Thus it removes the byte
  order mark of the subsequent data also. Before, only the first data of a
  decoder lost its byte order mark.
- `Web.TextDecoderStream` has the fields `:encoding`, `:fatal`, and
  `:ignore_bom`, and `Web.TextEncoderStream` has the field `:encoding`.
- `Web.TextEncoderStream` gives no chunk for an empty string, joins a code
  point that is divided between two chunks, and gives U+FFFD for bytes that
  are not valid UTF-8. `Web.TextEncoder.encode/2` gives U+FFFD for such
  bytes also.
- The compression streams, and `Web.TextDecoder`, accept a
  `Web.ArrayBuffer` as a chunk of bytes.
- **Breaking:** `Web.TransformStream` follows the Streams Standard.
  - The transform of a chunk starts only when the readable side wants a
    chunk, and until then the write waits. Before, a transform stream gave
    no backpressure: each write was transformed immediately, and the chunks
    of a slow reader filled the memory.
  - The default limit of the readable side is 0. Thus a write to a
    transform stream that no process reads stays pending. Do not await a
    write before a process reads the readable side.
  - `new/2` gives a `%Web.TransformStream{}` struct. The option
    `:writable_strategy` is the strategy of the writable side. Before, it
    was a second name for `:readable_strategy`.
  - The callbacks get a `Web.TransformStreamDefaultController`, which has
    `enqueue/2`, `error/2`, `terminate/1`, and `desired_size/1`. The
    functions of `Web.ReadableStreamDefaultController` accept it also.
  - A cancel of the readable side errors the writable side with the reason
    of the cancel. An abort of the stream object gives its reason to the
    function `cancel` with no change.
  - `new/2` throws the value that the function `start` throws, raises
    `Web.TypeError` for a callback that is not a function, and raises
    `Web.RangeError` for the keys `:readable_type` and `:writable_type`.
  - `terminate/1` of the controller closes the readable side and puts the
    writable side in the errored state with a `Web.TypeError`. The writes
    that wait, a close that waits, and the promises `ready` and `closed` of
    the writer reject with that error. A `terminate/1` in the function
    `flush` does not prevent the close.
  - `new/2` does not wait for a promise that the function `start` returns.
    The writes wait until that promise fulfils. A rejection puts the two
    sides in the errored state.
- **Breaking:** each stream of bytes gives its chunks as `Web.Uint8Array`
  values, as the Web standards specify. Before, most of them gave binaries.
  This applies to:
  - the body of a `Web.Request` and of a `Web.Response`, for each form of
    the body and for each dispatcher;
  - `Web.Blob.stream/1` and `Web.File.stream/1`, and the file streams of
    `Web.FormData`;
  - the readable side of a `Web.Socket`, of `Web.CompressionStream`, and of
    `Web.DecompressionStream`;
  - a default read of a byte stream.

  `Web.ReadableStream.from/1` of an enumerable gives its elements with no
  change.

  Thus `Enum.join/1` on a body does not work. Use `Web.Response.text/1` or
  `Web.Response.bytes/1` for all the bytes, or `to_string/1` for one
  chunk. A stream that the caller made is not changed.
- Each consumer of bytes accepts a binary, a `Web.Uint8Array`, a
  `Web.ArrayBuffer`, or iodata: the functions of a body, the body of a
  request that a dispatcher sends, a write to a `Web.Socket`, a part of a
  `Web.Blob`, and a chunk for `Web.ReadableByteStreamController.enqueue/2`.
  The stream takes the buffer of a view that a byte source enqueues: that
  buffer becomes detached.
- **Breaking:** the function `start` of a source, a sink, or a transformer
  runs in the process that makes the stream, before the constructor
  returns, as in the Streams Standard. A value that it throws is thrown by
  `new`, and the stream process stops. The stream waits for a promise that
  it returns: until then the stream does not pull, and the writes wait.
  Before, the `start` of `Web.ReadableStream` and `Web.WritableStream` ran
  in a task: `new` returned before it, and a value that it threw put the
  stream in the errored state. A `start` that does not return stops its
  caller now.
- **Breaking:** `enqueue/2` and `close/1` of a controller raise
  `Web.TypeError` when the readable side is closed or errored, as the
  Streams Standard specifies. This applies to
  `Web.ReadableStreamDefaultController`, `Web.ReadableByteStreamController`,
  and `Web.TransformStreamDefaultController`. Before, the chunk was
  discarded with no message. A source that is a process, and that sends
  chunks to the stream process, is not changed.
- **Breaking:** `Web.WritableStream.close/1` of the stream object does the
  steps of the close of a writer: the writes that wait complete, the close
  callback of the sink runs, and the stream awaits a promise that the
  callback returns. A close of a stream that closes, is closed, or is
  errored rejects with a `Web.TypeError`. Before, the close stopped the
  write that was in progress, and did not await the promise.
- A callback that fails after it closed its stream has no effect on the
  stream. Before, the closed stream went to the errored state.
- **Breaking:** `Web.CountQueuingStrategy.new/1` and
  `Web.ByteLengthQueuingStrategy.new/1` raise `Web.RangeError` for a limit
  that is not a number or that is below zero.
- **Breaking:** the readers and writers of a stream follow the Streams
  Standard for these operations.
  - A stream gets the calls of one process in the sequence of the calls,
    also when the promises are not awaited. Before, a `write` and a `close`
    that were not awaited could change places, and the chunk was lost.
  - `read/1` of a reader returns a pending promise. Before, it stopped its
    caller until a chunk came. A reader has the field `:owner_pid`, thus
    each process that has the reader can read with it.
  - A release of the lock rejects the reads that are pending. A release of
    a lock that is released already has no effect. Before, it raised.
  - After an error, a `write` and the promise `ready` reject with the error
    of the stream. Before, they rejected with "This writer is no longer
    locked."
  - A second `close` of a writer rejects. An `abort` settles after the abort
    callback of the sink is complete, and rejects with the value that the
    callback throws.
  - `cancel/2`, `abort/2`, and `close/1` of a stream object reject with
    `Web.TypeError` when the stream is locked. Use the function of the
    reader or the writer.
  - The desired size of a closed stream is 0. Before, it was `nil`.
  - The two sides of a transform stream have separate locks. Before,
    `WritableStream.locked?/1` gave the lock of the readable side.
- **Breaking:** `Web.Response` follows the Fetch Standard.
  - `new/1` raises `Web.RangeError` for a status that is not from 200 to
    599, and `Web.TypeError` for a status text that is not a reason phrase,
    or for a body with the status 101, 103, 204, 205, or 304.
  - A response with no body has the body `nil`, and starts no stream. Before,
    each response had a stream. `Web.fetch/2` gives the body `nil` for a HEAD
    request and for a status that permits no body.
  - A body of no bytes, such as `Response.new(body: "")`, gives no chunk, as
    the Fetch Standard specifies. Before, it gave one empty chunk.
    `ReadableStream.from("")` still gives one empty chunk.
  - The default of `url` is `""`. The response of `Web.fetch/2` has the type
    `"basic"`.
  - `json/2` has an empty status text, keeps a `content-type` that `init`
    has, and raises `Web.TypeError` for a value that cannot be changed to
    JSON.
  - `redirect/2` has an empty status text, puts the serialized URL in the
    header `location`, raises `Web.TypeError` for a URL that is not valid,
    and raises `Web.RangeError` for a status that is not a redirect status.
  - `json/1` of a request or a response rejects with `Web.SyntaxError` when
    the body is not JSON. Before, the reason was `Jason.DecodeError`. The
    field `cause` has the `JSON.DecodeError` of the decoder, with the
    position of the error.
  - `blob/1` gets its type only from the header `content-type`. Before, it
    examined the bytes of the body when the header was absent or generic.
    Use `Web.MIME.sniff/1` to examine the bytes.
- **Breaking:** `Web.Headers` validates each name and each value, and
  raises `Web.TypeError` for a name that is not an HTTP token, or for a
  value that contains a NUL, CR, or LF character. It removes the HTTP
  whitespace at the two ends of a value.
- **Breaking:** `Web.fetch/2` does not raise. Input that
  `Web.Request.new/2` refuses, and a request whose body is already read or
  locked, give a rejection with `Web.TypeError`, and `fetch` makes no
  connection. `fetch` with a request as its input applies `init`.
- **Breaking:** a governor from `Web.CountingGovernor.new/1` has an owner,
  as a stream or an abort signal. It stops after its owner stopped, when no
  token is in use and no acquisition waits, and after the linger time.
  Before, the process of a governor never stopped.
- **Breaking:** a token of `Web.CountingGovernor` belongs to the owner of the
  process that acquired it. When that owner stops, the governor takes the
  token back. If you give a token to a different process, keep the owner
  alive until the release.
- **Breaking:** an aborted acquisition of `Web.AbortableGovernor` rejects
  with `Web.DOMException` (`AbortError`), and an acquisition from a governor
  that stopped rejects with `Web.TypeError`. Before, the reasons were the
  atoms `:aborted` and `:closed`.
- **Breaking:** `Web.ReadableStream.tee/1` follows the algorithm of the
  Streams Standard.
  - When the two branches are cancelled, the stream is cancelled, and the
    reason is the list of the two reasons. Before, the stream was not
    cancelled, and a stream with no end continued until its owner stopped.
  - A branch that no process reads keeps each chunk in its queue, with no
    limit, and does not slow down the other branch. Before, the read of one
    branch stopped after 16 chunks until a process read the other branch.
    Thus `Response.clone/1` permits a full read of one of the two responses.
  - The branches of a byte stream are byte streams.
  - A pull of a branch that has its chunk already does not read the
    source, as the chunk steps of the Standard. Thus the source gives no
    chunk that no branch asked for.
  - `tee/1` accepts a stream that is disturbed and not locked, and raises
    only for a locked stream. The stream stays locked until it stops.
  - One difference stays: the promise of `cancel/2` on one branch fulfils
    immediately. In the Standard, it stays pending until the second branch
    is cancelled.
- **Breaking:** `Web.ArrayBuffer` is a struct around a binary. It uses no
  table and no process, and the VM collects a buffer as each other term.
  - The detached state is one flag in an `:atomics` array. `detach/1`, a
    transfer, and `detached?/1` operate as before for all the copies of
    the struct on one node.
  - `Web.ArrayBuffer.transfer/2` is new. It moves the bytes to a new
    buffer and detaches the first buffer, as `ArrayBuffer.prototype.transfer()`
    of ECMAScript.
  - `write_at/3` is removed. No function changes the bytes of a buffer.
  - `new/1` raises `Web.TypeError` for input that is not a binary or a byte
    length.
- **Breaking:** a read with `Web.ReadableStreamBYOBReader` moves the buffer
  of the view into the stream, as the Streams Standard specifies. The
  buffer that you gave becomes detached. The result has a new view in a
  buffer of the same length: use `value.buffer` for the subsequent read.
  - At the end of the stream, `value` is a view of zero bytes in that
    buffer. Before, it was the view that you gave.
  - A view of zero bytes, or a view of a detached buffer, gives a rejection
    with `Web.TypeError`.
- **Breaking:** `Web.Promise` has a new engine. A pending promise is a small
  process, not a `Task`. The struct has the fields `:pid` and `:state`, and
  the field `:task` is removed.
  - Any process can await a promise, and can await it more than one time.
  - The executor can call `resolve` or `reject` at a later time, from any
    process. A promise stays pending when its executor returns and does not
    settle it. Before, the promise resolved to `nil`.
  - `then/2` and `catch/2` return immediately. The callback runs in a
    different process, with the `Web.AsyncContext` values of the caller.
    Before, these functions blocked the caller.
  - `all/1`, `all_settled/1`, `any/1`, and `race/1` work with pending
    promises. `race/1` does not stop the other promises.
  - A rejection is a state. The combinators handle the value
    `{:error, reason}` as a usual value. Before, `all_settled/1`, `any/1`,
    and `race/1` handled it as a rejection.
  - `resolve/1` and `reject/1` return plain data and start no process.
    `resolve/1` does not accept a `Task`.
  - A pending promise stops when its owner stops, and the work of its
    executor stops at the same time. Commands to a stream or a socket
    (`cancel`, `close`, `abort`, `write`, `pipe_to`) continue to their end.
  - A settled promise keeps its outcome until its first delivery, and then
    for the linger time. An `await` after that time rejects with
    `Web.TypeError`. The `opened`, `closed`, and `upgraded` promises of
    `Web.Socket` do not expire.
- **Breaking:** rejections have the forms of the Web Standards.
  - `Web.fetch/2` rejects with the abort reason of the signal, or with
    `Web.TypeError` for each other failure. The new field `cause` of
    `Web.TypeError` has the failure of the dispatcher. Before, the reason
    was an atom such as `:redirect_error`, or a struct of the HTTP client.
  - A signal that aborts with no reason has the reason
    `Web.DOMException` `AbortError`. `Web.AbortSignal.timeout/1` gives
    `TimeoutError`. Before, the reasons were the atoms `:aborted` and
    `:timeout`.
  - `Web.AbortSignal.throw_if_aborted/1` raises the reason of the signal.
  - A read, a write, a body function, and a pipe reject with the error of
    the stream. Before, some of them rejected with `{:errored, reason}`,
    `{:aborted, reason}`, or a general `Web.TypeError`.
  - The error of a stream is the value that its callback raised or threw.
    Before, a thrown value was `{:throw, value}`. A callback that does not
    return in time gives a `Web.TypeError`.
- **Breaking:** `Web.fetch/2` follows the redirect rules of the Fetch
  Standard.
  - `301` and `302` change `POST` to `GET`. `303` changes each method to
    `GET`, but not `GET` and `HEAD`. The body and the headers that describe
    it are removed.
  - A redirect to a different origin does not get the headers
    `authorization`, `cookie`, and `proxy-authorization`.
  - The location is relative to the URL of the request, and `Web.URL` reads
    it. A location with no fragment gets the fragment of the request.
  - A redirect that must send a stream body again rejects. A body from
    memory is sent again.
  - `Web.Response` has the field `redirected`.
- **Breaking:** `Web.fetch/2` sends a `Web.ReadableStream` body chunk by
  chunk. Before, it read the full stream into memory. A body from memory is
  sent as one block with a content length.
- **Breaking:** a `Web.Request` with no body has the body `nil` and starts
  no stream. `Web.Request` has the field `body_source`.
- **Breaking:** a response body that is not complete is an error. Before, a
  connection that closed too early, and an abort, gave a body that looked
  complete. The read now rejects with the error or the abort reason.
- **Breaking:** a stream goes to the errored state when its ambient
  `Web.AbortSignal` aborts. Before, it closed. An enumeration of an errored
  stream raises the error of the stream when that error is an exception.
- **Breaking:** a `Web.AbortSignal` that is not aborted has an owner. Its
  process stops when the owner stops and no process is subscribed to it.
  Before, the process of a signal that did not abort stayed. A signal that
  stopped is the same as an aborted signal.
- The reason of an aborted signal stays available for the linger time.
  Before, each abort put one entry in `:persistent_term`, and nothing
  removed it.
- **Breaking:** each stream has an owner, which is the process that made it,
  and each stream stops. Before, no stream process stopped, also after the
  stream was read to its end.
  - A stream that is ended, with all its chunks read, stops after the linger
    time.
  - When the owner stops, a stream that no process has locked waits for the
    linger time, then cancels (or aborts) and stops. In that time, a
    different process that got the stream in a message can lock it and
    continue.
  - A stream does not stop while it has work or unread chunks and a process
    holds its lock.
  - A function that uses a stopped stream does not exit. `locked?` gives
    `false`, `disturbed?` gives `true`, `cancel`, `close`, `abort`, and
    `release_lock` give `:ok`, and `get_reader`, `get_writer`, and `write`
    give `Web.TypeError`.
  - The promises and streams that a stream callback makes belong to the
    stream.
  - A stream has no link to the process that made it. An owner that stops
    with a failure or a shutdown gets no linger time: the stream cancels (or
    aborts) immediately, and its source gets the `cancel` call. A process
    that holds the lock continues to read. Before, the failure stopped the
    stream process immediately, with no `cancel` call, also while a
    different process read the stream. A failure of a stream process does
    not stop the process that made the stream.
  - The writer lock of a pipe does not keep the destination stream after
    the owner of the destination stopped. When the destination stops, the
    pipe ends and cancels its source. Await the promise of `pipe_to/3`, or
    keep the owner of the destination alive, until the pipe is complete.
- **Breaking:** a halt of an enumeration cancels the stream. `Enum.take/2`
  on a `Web.ReadableStream` stops its source. Before, the stream stayed
  open and the source continued.
- `Web.ReadableStream.pipe_through/3` and `tee/1` start their pipe without a
  promise, because no process awaits it.
- `Web.TextDecoder` keeps its state in a process that stops when its owner
  stops. `Web.Body` decodes text without a state process. Before, each
  decoder, and thus each `text/1` and `json/1` call, left one process.
- **Breaking:** `Web.URL` does the "domain to ASCII" operation in Elixir
  only. It follows Unicode Technical Standard #46 with the settings of the
  URL Standard. Before, the library read the expected results from the
  cached WPT fixture files in `tmp/wpt_cache`, and then called a Node.js
  process if `node` was installed. Both are removed, and the module
  `Web.URL.Idna` is removed. A host can give a different result now:
  - an empty label is permitted (`bücher..example`);
  - the IDNA2008 rules for U+00B7 and other CONTEXTO characters do not apply;
  - a label with the prefix `xn--` must decode to a valid label.
- The WPT fixtures are pinned to one commit of `web-platform-tests/wpt`
  (`@wpt_revision` in `test/support/wpt.ex`). A change upstream cannot change
  the test results.
- `Web.ReadableStream.new/2` now recognizes `%{type: "bytes"}` sources,
  provisions byte-length queueing defaults, supports `get_reader(..., mode:
  "byob")`, and surfaces pending BYOB requests through
  `ReadableByteStreamController.byob_request/1`. The default high water
  mark of a byte stream is 0, as the Streams Standard specifies.
- `Web.Socket` lifecycle promises now use `Web.Promise.with_resolvers/0`
  instead of ad hoc mailbox wiring for external settlement.
- `Web.ReadableStream.new/2` now accepts explicit queueing options and
  inherits high-water-mark and strategy metadata from the underlying source
  when present.
- `Web.Dispatcher.TCP` now routes all body streaming through a dedicated
  bridge built on `Web.Socket`, pulling exactly on downstream demand instead
  of autonomously pumping the transport.
- `Web.Dispatcher.TCP` now normalizes request bodies before connect-time
  writes, accepting `nil`, binaries, iodata, `ReadableStream` bodies, and
  enumerable iodata while rejecting unreadable payloads with `TypeError`.
- `Web.Socket` readable streams and `ReadableStream.from/1` enumerable-backed
  streams now opt into reader-owner revocation, so reader death cancels the
  underlying producer path automatically.
- `Web.ReadableStream.tee/1` now provisions branch `TransformStream`
  readable-side strategy metadata explicitly so branch backpressure matches
  the configured buffer size.
- `use Web` now imports `structured_clone/1`, `structured_clone/2`, and
  `using/2`, and now aliases `Web.Symbol`.
- `Web.EventTarget` now exposes a public, opaque-ref interface for
  process-backed evented structs, with listener state delegated to
  `Web.Internal.EventTarget.Server` through `Web.Registry`.
- `Web.BroadcastChannel` now stores opaque refs instead of public pids,
  implements `Web.EventTarget.Protocol`, routes listener operations through
  the shared event-target server, and resolves runtime metadata through
  `Web.Registry`.
- `Web.BroadcastChannel` and `Web.MessagePort` now authenticate internal
  calls through `%Web.Internal.Envelope{}` values that carry the bearer token
  and `AsyncContext` snapshot together.
- `Web.BroadcastChannel.Dispatcher` now uses the shared `Web.Registry`,
  keeps adapter and governor lookups local, and starts partitioned registries
  when it has to bootstrap itself.
- `Web.BroadcastChannel.t/0` and `Web.MessagePort.t/0` now carry explicit
  typedoc-backed public type exports for docs and LSP autocomplete.
- `Web.ArrayBuffer` now uses detachable backing storage with stable
  identities and a persistent named ETS owner process so transferred
  buffers detach safely and concurrent buffer creation cannot lose the
  shared table.
- `Web.Blob`, `Web.File`, and `Web.Uint8Array` now carry stable identities
  so structured cloning preserves shared references across repeated
  appearances in a serialized graph.
- `Web.Platform.Test` now loads either JSON or JS WPT resources, caches raw
  JS sources, and derives case names from richer fixture metadata such as
  `description`.

### Security

- **Breaking:** a TLS socket from `Web.connect/2` or
  `Web.Socket.start_tls/1` verifies the certificate of the server and its
  host name. Before, the default was `verify: :verify_none`: the socket
  accepted each certificate, and a process in the network path could read
  and change the data. The trust store is the store of the operating
  system, or `cacertfile` or `cacerts` in the setting
  `config :web, tls_options: [...]`. To stop the verification, put
  `verify: :verify_none` in that setting.

### Fixed

- After `error/2` of the controller of a writable stream, a write does not
  call the size function of the strategy, also while the stream is
  erroring, for example before the end of `start`. The stream removes the
  function at once, as WritableStreamDefaultControllerClearAlgorithms
  does. Before, it removed the function only when the stream was errored.
- A writer whose process stopped gets the outcome of `ready` and `closed`
  that the stream keeps, also when the old promise did not stop yet. The
  stop of the owner comes to its promise some time after the stop. Before,
  on a busy machine, the writer could get the old promise, which then
  stopped before its read. The stream now also examines the owner of the
  promise.
- A body in memory gives its bytes to the next reader when a copy of the
  body stops during a stream read, or when its stream process stops before
  its first read: no reader took the bytes. Before, the other copies
  waited 5 s, and then got "not available". A copy that asked for the
  stream process keeps it until it takes its lock. The steps "consume
  body" disturb the stream and take the bytes in one step. A second start
  of a stream process ends with no crash report. When a different process
  kills the stream process before its first read, the lock step of a copy
  asks for a new stream process, and gets the bytes: each path that takes a
  lock uses this step. A stream process that the shared state does not
  give, for example after a start that continued, stops. `tla/LazyStream.tla`
  has each of these cases as a value of `Bug`, also a claim that could take
  the bytes of a new stream process (ABA), which the model check found.
- A look at the state of a body in memory (`disturbed?`, `locked?`, and
  `body_used`) changes nothing, and starts no process. Before, a look
  during a start that stopped started a new starter. A start gives
  "not disturbed" until its stream process has a read, and a start of a
  closed stream gives "disturbed". `tla/LazyStream.tla` has the old
  behavior as a value of `Bug`, and a new invariant finds it. Tests do
  the steps of a claim and of a starter in the sequence of the model
  counterexamples (the ABA of the claim, and a stream process that
  starts during the rollback of a starter). Each test fails with the old
  behavior.
- A lock of a process that stopped does not refuse a new lock, and
  `locked?` is false for it. A process that saw that stop, for example
  with its own monitor, can call the stream before the stream gets the
  `:DOWN` message of the holder: Erlang keeps the order of the signals of
  one sender only. Before, the call got "already locked". Now the stream
  finds that the holder is not alive, takes its `:DOWN` message, does the
  usual steps of the stop with the true reason, and then does the call.
- When the owner of a transform stream fails, a side ends only when no
  lock of the two sides exists: the side asks the other side, which
  decides in its own process. Before, a lock that a process took at the
  same moment on the other side could be missed. `tla/TransformLifetime.tla`
  has the handshake, with the old behavior as a value of `Bug`.
- Each message to a stream that can wait before a priority message of the
  same process names its sender: the calls with no wait of the pipe, of
  the tees, and of the `Web.FormData` parser, the end of a pull of a
  source that is a process, the error of an enumerable, and the messages
  between the two sides of a transform stream.
- The tee of a byte stream ends its two branches when its source stopped
  before the tee handled a pull. Before, the tee process failed with a
  `MatchError`.
- A BYOB read that comes between the last chunk of a body and its close
  ends at the close. Before, it could wait forever.
- The live parser of a multipart `Web.FormData`, with the defects that
  `tla/FormDataParser.tla` found:
  - A `get` that waits for a field gets its answer when an iteration or a
    freeze goes past a file part. Before, it waited forever.
  - `Web.FormData.cancel/2`, an abort of the signal, and a stop of the
    owner stop the parser at once, also while the source gives no data.
  - The stream of a file part gets an error when the parse stops before
    the end of the part: the reason of the abort, or a `Web.TypeError`.
    Before, a reader could get the end of a short file. A file part that
    an iteration or a freeze goes past gets a `Web.TypeError`.
  - A stop of the owner runs the end of the parser: the file stream ends,
    and a call raises `Web.TypeError`, not an exit.
- With `[:http2]`, a request whose write fails because the server closed
  the socket, before the client read the close, goes again on a new
  connection: the server did not get it. Before, it failed with the error
  of the write (for example `:enotconn`), and the next requests went to the
  same connection and failed too. The connection now closes at such a
  write, and its other requests get their errors.
- A BYOB read of a branch of a tee of a byte stream ends when the source
  is canceled during the read of the tee, for example when the owner of the
  source stops. The cancel drops the buffer of the read, thus the read ends
  with a view of 0 bytes in a new buffer of the same size. Before, the read
  waited forever.
- A parsed `Web.FormData` whose parser stopped, for example after an abort
  of its body, raises `Web.TypeError` for a field that the parser did not
  read, as a stream that is gone does. It exited with `:noproc` before.
- A change of a `Web.URLSearchParams` of a URL runs the "update steps" of
  the URL Standard: a change that gives an empty serialization removes the
  `?` of the URL, and a change on a URL with no query gives the URL a
  query. Before, the URL kept its old query in these two cases. The request
  target of `Web.fetch/2` also has the changed query.
- A pipe to a stream that is closed or errored cancels the source. Before,
  the promise of the pipe did not settle.
- The last chunk of a pipe is not lost when the source closes during a
  read.
- An iteration of `Web.Headers` gives each value of `set-cookie` as a pair
  of its own, as the steps "sort and combine" of the Fetch Standard
  specify. `Enum.count/1` counts the pairs.
- `Web.Response.form_data/1` of an `application/x-www-form-urlencoded` body
  keeps a `"?"` at the start of the body as a part of the first name. Only
  the constructor of `URLSearchParams` removes it.
- `Web.fetch/2` and `Web.connect/2` connect to an IPv6 address, such as
  `http://[::1]:8080/`, `tcp://[::1]:8080`, `Web.connect("[::1]:8080")`, and
  `Web.connect(%{hostname: "::1", port: 8080})`. Before, Erlang did not try
  the address, and the result was `:nxdomain`. The text of an address for
  `Web.connect/2` takes an IPv6 address in brackets, as a URL does.
- `Web.DecompressionStream` decodes only as the reader takes the chunks.
  Before, one write decoded all its data at once: a gzip write of 20 KiB
  that expands to 20 MB put 20 MB in the queue of the stream. Now the
  stream keeps less than 200 KB, and the write waits for the reader.
- A cancel of a stream that closed with chunks in its queue discards the
  chunks and calls the cancel callback of the source, as the Streams
  Standard specifies: such a stream is readable until a read takes the last
  chunk. Before, the cancel had no effect, and a read got the chunks.
- A stream that closes with chunks in its queue stays readable until a
  read takes the last chunk, as the Streams Standard specifies. An error,
  or the abort of the signal of a fetch, at that time puts it in the
  errored state and discards the chunks. Before, the error had no effect:
  the abort of a fetch did not error a complete body that no process
  read.
- A URL with an upper-case scheme, such as `HTTPS://example.com/a`, keeps
  its host. Before, the host was `https` and the path was
  `//example.com/a`.
- `Web.MIME.parse/1` refuses a type with a line feed, such as
  `"text\n/html"`, as the MIME Sniffing Standard specifies.
- The enumerator of `Web.ReadableStream.from/1` stops when its stream
  process stops. Before, it stayed.
- The HTTP worker stops when the process that called `fetch` stops before
  the body. Before, the bridge and the worker stayed.
- A stream that a process reads with `Enum`, with `for`, or with a body
  function such as `Web.Response.text/1` keeps no chunk. Before, each read
  made a promise, and the promise kept its chunk for the linger time of
  5 seconds: a read of 256 MiB left 4235 processes and 268 MB in memory.
  The memory of a stream is now flat for each speed. A parse of a 1 GiB
  form upload added 1156 MB at its peak, and now adds 2.8 MB.
- `Web.fetch/2` ignores an informational response, such as 103 Early Hints
  or 100 Continue, that comes before the response. Before, it became the
  response, with no body.
- `Web.TransformStreamDefaultController.wait_for_capacity/1` continues
  when a read waits. Before, it had no end with the default limit of the
  readable side.
- A reducer of `Enum` that throws or exits releases the lock of the
  stream.
- A write to a `Web.Socket` that waits for a slow peer does not stop the
  reads of the socket. Before, the process of the socket sent the bytes:
  while a write waited, the socket did not read, and the two sides could
  wait for each other with no end.
- A write to a `Web.Socket` has no time limit. Before, a write that took
  more than 5 seconds failed with `:closed`, while the socket was open.
- The time of the write requests that wait in a writable stream does not
  increase with the square of their number.
- A message to a `Web.MessagePort` that has no listener at that time is not
  lost: it stays in the port message queue.
- A listener of a `Web.MessagePort` or a `Web.BroadcastChannel` can call
  each function of its port or channel. Before, a listener that sent a
  message on its port stopped the port.
- A listener that raises does not stop its port, its channel, or its event
  target. The error goes to the log.
- A slow listener of a `Web.BroadcastChannel` delays only its channel.
  Before, one process for each channel name, with a name in `:global`,
  delivered each message to one channel at a time and waited for it. A
  listener that did not return stopped all the channels of that name in
  the cluster, and the queue of that process had no limit.
- The application starts when an application of the user has started the
  default scope of `:pg`. The broadcast channels now have their own scope.
- `Web.structured_clone/2` accepts an improper list. Before, it raised
  `FunctionClauseError`.
- Two listeners from the same code with different values of their
  variables are two listeners of an event target. Before, the second one
  was ignored, and the removal of one removed the two.
- `Web.Console.assert/2` writes nothing for a value that is not `false` and
  not `nil`. Before, it wrote an error for a value such as `1`.
- `Web.Console.table/2` accepts a list of values that are not maps.
  Before, it raised `FunctionClauseError`.
- `Web.Performance.measure/2` finds a mark when a measure has the same
  name.
- The parser of `multipart/form-data` keeps each backslash of a field name
  and of a file name. Before, it removed them: the file name
  `C:\dir\file.txt` became `C:dirfile.txt`. Only a backslash before a
  quotation mark inside the text is an escape. The parser also reads the
  escapes `%0A`, `%0D`, and `%22` of a name, which a browser writes.
- A write to a `Web.Socket` of a chunk that is not bytes rejects with the
  `Web.TypeError`, and the writable side has that error. Before, the error
  had the form `{:transport_error, error}`, but the transport did not fail.
- `Web.AbortSignal.unsubscribe/1` removes the subscription from the signal.
  Before, the signal kept each subscribed process until that process
  stopped.
- The helper processes of `Web.AbortSignal.any/1` stop when the new signal
  stops.
- An errored stream stops after the linger time, also with chunks in its
  queue. No process can read those chunks.
- `Web.ArrayBuffer.new/1` does not leave data behind. Before, each buffer
  left one row with all its bytes in a table, and nothing removed the row.
  Thus each `array_buffer/1` of a body kept its bytes until the VM stopped.
  Each read of a buffer also called one process.
- A BYOB read with a view of a detached buffer gives a rejection. Before,
  it raised in the stream process.
- The example `examples/secure_byob_stream.exs` operates again. It used the
  field `:task` of the old promise.
- `Web.DecompressionStream` gives `Web.TypeError` when the stream closes
  before the end of the compressed data, and when data comes after that
  end. Before, it accepted such data and gave a part of the result, or
  ignored the remaining data, with no error.
- A readable stream does not call `pull` again and again when `pull` gives
  no chunk immediately. Before, the stream called such a `pull` without a
  pause: 36,725 calls in 300 ms in a measurement, each one in a new process.
  A socket that waited for data used the processor continuously.
- A readable stream with the limit 0 calls `pull` when a read waits, as the
  Streams Standard specifies. Before, it did not pull.
- `Web.Socket` settles its promises `opened` and `closed` when one of its
  streams stops with a failure. Before, a process that awaited `closed`
  waited without end.
- `Web.ReadableStream.tee/1` gives an error of the stream to the two
  branches immediately, as the Streams Standard specifies.
- `Web.fetch/2` rejects when the server gives no response headers, or stops
  in the body, for the receive time. Before, such a request waited without
  end unless it had a signal.
- `Web.fetch/2` rejects when the body of the request is already read.
  Before, it sent the request with an empty body and gave no error.
- `Web.CountingGovernor` does not lose capacity when a process stops with
  a token. Before, the token of a process that stopped was never released.
  With the new promise engine, this also occurred when the owner of
  `Web.Governor.with/2` stopped during the work, and each subsequent
  acquisition then waited without end.
- An acquisition waits no longer when the governor stops during the wait.
  It rejects.
- An abort after the grant keeps no data in the governor. Before, each such
  abort left one reference in the governor.
- An ended stream with the linger time `:infinity` stops after its owner
  stopped. Before, a lock on such a stream kept it without end.
- A pipe with a source that has no end stops after the processes that use
  it stopped. Before, such a pipe continued without end when its owner
  stopped normally.
- A `cancel` callback of a readable stream, or a `close` callback of a
  writable stream, that raises does not stop the stream process. The
  promise of `cancel` or `close` rejects with the thrown value, as the
  Streams Standard specifies. After a `close` callback that raises, the
  stream is in the errored state.
- A stream that is ended and empty stays for the linger time after its
  owner stopped normally. Before, it stopped immediately, and a process
  that got the stream in a message could get `Web.TypeError` from
  `get_reader`. `Web.Dispatcher.TCP` had this failure when the peer closed
  the connection immediately.
- `Web.URL` does not keep each host in a table. The table had no limit, and
  it was necessary only for the Node.js call that is now removed.
- A stream subscribes to its ambient `Web.AbortSignal` in its own process.
  Before, each such stream started one more process that did not stop.
- A read from an errored stream gives the error of the stream. Before, a
  reader could get "This reader is no longer locked."
- `Web.ReadableStream.from/1` accepts an enumerable that halts itself, such
  as `Stream.take/2`. Before, the stream raised `CaseClauseError`. The
  chunks `nil` and `:done` are usual chunks.
- `Web.ReadableStream.from/1` puts the stream in the errored state with the
  exception of an enumerable that raises. Before, the read waited for the
  task timeout.
- `Web.WritableStream.ready/2` returns when the stream stops. Before, it
  waited with no limit.
- `Web.URLPattern` uses the Unicode properties `ID_Start` and `ID_Continue`
  for the name of a group. Before, it accepted each character below U+1F000.
  A name with a variation selector after its first letter does not raise
  `MatchError`.
- The WPT fixture loader keeps each surrogate pair. Before, it removed a
  combining mark above U+FFFF that came first in a string, and the tests
  did not get the real input.
- `Web.Promise` inspect coverage no longer relies on a sleep-driven race for
  the in-progress pending-state assertion in `test/web/promise_test.exs`.
- `Web.Dispatcher.TCP` now seals end-to-end TCP backpressure by reading from
  the socket only inside the proxy stream's `pull` callback, allowing the
  socket transport to enter passive mode once its internal readable high-water
  mark is saturated.
- `Web.Dispatcher.TCP` cancellation, abort, reader-owner exit, and mid-pull
  socket failures now all converge on prompt bridge shutdown, socket close,
  and capability revocation without leaking reader locks.
- `Web.ReadableStream.from/1` now halts suspended enumerable continuations on
  cancellation, ensuring `Stream.resource/3` finalizers run even when the
  stream is cancelled before exhaustion.
- `Web.Stream` now supports optional `cancel_on_reader_exit` handling for
  readable producers, allowing transports and enumerable helpers to revoke
  themselves as soon as the locked reader disappears.
- `Web.Socket` write failures now close the readable side cleanly while
  surfacing the write error through the writable side, instead of reporting a
  generic transport teardown across both directions.
- Added targeted dispatcher and compression termination coverage, restoring
  the full suite to stable `100.0%` coverage with empirical TCP saturation
  proof and strict Credo compliance for the refactor.
- `Web.TransformStream` readable queue accounting now falls back to the
  writable-side high-water mark when a supplied readable strategy reports an
  invalid watermark, keeping readiness and desired-size tracking stable.
- `Web.BroadcastChannel` close and `onmessage` control paths now treat missing
  runtime registrations defensively, raising clear argument errors for unknown
  refs and returning safe no-op behavior where appropriate.
- `Web.EventTarget` listener cleanup now remains stable across nested
  dispatches, self-cast add/remove flows, pre-aborted signals, token signals,
  pid signals, and abrupt watcher-owner shutdown.
- `Web.Stream` now replies to writable-stream abort callers before draining
  queued failures, restoring low-latency priority signaling under mailbox
  pressure.
- Expected negative-path tests for governors, multipart parser startup, and
  IDNA node restarts now capture their logs locally so the full suite stays
  quiet without muting real failures.
- Added targeted `TextDecoder` and `ArrayBuffer` coverage cases, bringing
  the full `mix precommit` gate back to stable `100.0%` coverage.

## [0.4.0] - 2026-04-17

### Added

- `Web.Governor`, `Web.AbortableGovernor`, `Web.Governor.Token`, and
  `Web.CountingGovernor` for TC39 concurrency-control proposal-aligned
  concurrency limiting, including FIFO acquisition, abortable acquisition,
  token release helpers, and `Governor.with/2` / `Governor.wrap/2`
  ergonomics.
- `examples/fetch_pool.exs`, demonstrating pooled `Web.fetch` usage with
  `CountingGovernor`.
- `Web.File`.
- `Web.FormData` struct and streaming multipart parser.
- `Web.MIME` for MIME parsing, normalization, and signature-based sniffing
  used by response body helpers.
- `Web.URLPattern` with WHATWG-style pattern parsing, compilation, matching,
  generation, component comparison, and ambient route param injection via
  `match_context/3`.
- `Web.URLPattern.Cache`, `Web.URLPattern.Parser`, and
  `Web.URLPattern.Compiler`.
- `Web.AsyncContext` for BEAM-native async context propagation.
- `Web.AsyncContext.Variable` for scoped context values that participate in
  snapshot capture and restoration.
- `Web.AsyncContext.Snapshot` for capturing registered variables, logger
  metadata, `$callers`, and ambient abort signals.
- `Web.CustomEvent` for lightweight event payload construction.
- `Web.EventTarget` with listener registration, `once` handling, callback
  deduplication, and `AbortSignal`-driven listener cleanup.
- `Web.Performance` User Timing support with `mark/1`, `measure/1-3`,
  `getEntries*`, `clearMarks*`, and `clearMeasures*`.
- `Web.Console` helpers backed by Erlang `:logger`, including `assert`,
  `count`, `countReset`, `time`, `timeLog`, `timeEnd`, `trace`, grouping,
  and ASCII `table` rendering.
- `examples/streaming_upload_proxy.exs` demonstrating a WHATWG-only multipart
	ingestion flow (`Response.form_data/1` + `FormData.get/2`) that streams a
	simulated `1 GiB` file to a writable sink while reporting memory checkpoints.
- `examples/async_runtime_power.exs`, a runtime-focused demo showing ambient
  aborts, logger metadata, console grouping, multipart file parsing, and
  `CompressionStream` working together across process boundaries.

### Changed

- `README.md` now documents governor-based concurrency limiting and notes
  that `web` keeps `Web.fetch/2` unchanged instead of adding a custom
  `fetch(..., governor: ...)` option, matching the Stage 1 TC39
  concurrency-control proposal (`tc39/proposal-concurrency-control`,
  advanced to Stage 1 in July 2024).
- `use Web` now aliases `Web.Governor`, `Web.AbortableGovernor`, and
  `Web.CountingGovernor`.
- `use Web` now aliases `Web.AsyncContext`.
- `Web.URL` now aligns its internal state and serialization around WHATWG
  `search` and `hash` semantics, with improved special/non-special setter
  behavior, `file:` path normalization, IDNA handling, and rclone URL
  serialization.
- `Web.URLPattern` now reuses `Web.URL.Punycode` for host ASCII
  normalization and preserves the leading slash for malformed
  scheme-looking pathname inputs.
- `Web.Request.new/2`, `Web.Resolver.resolve/1`, and
  `Web.Dispatcher.TCP` now handle malformed, path-only, and remote-like
  targets more defensively.
- `Web.Response.blob/1` and response content-type resolution now parse
  explicit MIME types and sniff bodies when headers are absent or fall back
  to generic binary types.
- `Web.Promise.new/1` and `Web.Stream` task callbacks now capture and restore
  `Web.AsyncContext` snapshots, preserving logger metadata, scoped variables,
  `$callers`, and ambient abort signals across spawned tasks.
- Streams created inside `Web.AsyncContext.with_signal/2` now auto-bind to the
  ambient signal and cancel themselves when it aborts.
- `Web.ReadableStreamDefaultReader.read/1` now returns WHATWG-style
  `%{value: term(), done: boolean()}` results inside `%Web.Promise{}` values
  and rejects with the stored stream error reason when reads fail.
- `Web.ReadableStreamDefaultReader.cancel/2` now returns the underlying
  cancellation promise so callers can await stream shutdown.
- `Web.ReadableStream.pipe_to/3` now consumes WHATWG-shaped read results from
  default readers.
- `Web.TransformStream.new/2` now accepts `:readable_strategy` as the primary
  readable-side queue option and keeps `:writable_strategy` as a legacy alias.
- `Web.FormData.Parser` now captures and restores `Web.AsyncContext`
  snapshots, auto-binds to ambient abort signals, and propagates that context
  into live file streams it creates on demand.
- `Web.Application` now eagerly initializes the singleton
  `Web.URLPattern.params/0` variable during boot so route-param context stays
  stable across processes in async workloads and tests.
- `Web.Console.group/1` now keeps `group_depth` in logger metadata so grouped
  output survives async-context snapshot restore across task boundaries.
- `Web.CompressionStream` and `Web.DecompressionStream` now emit context-aware
  zlib observability logs from restored task contexts, including ambient
  metadata such as `request_id`, `user`, and console grouping depth.
- URL and MIME compliance coverage is now split into focused WPT-backed test
  suites, and `mix precommit` now uses exported coverage data so the full
  gate reports stable `100.0%` coverage summaries.

## [0.3.0] - 2026-04-10

### Added

- `Web.Stream` behaviour that abstracts streaming state machine.
- `use Web.Stream` macro.
- `Web.TransformStream` that uses `use Web.Stream`
- `Web.ReadableStream.pipe_to/3` and `Web.ReadableStream.pipe_through/3` for composable, backpressure-aware stream pipelines with optional `AbortSignal` interruption.
- `Web.Promise` with `resolve/1`, `reject/1`, `then/2`, `catch/2`, `all/1`, `all_settled/1`, `any/1`, and `race/1` helpers for composing async workflows.
- `examples/stream/byte_counter_stream.exs` demo showing a custom `use Web.Stream` byte counter and a `Web.TransformStream` byte counter producing the same byte total.
- WHATWG-style text encoding APIs: `Web.TextEncoder`, `Web.TextDecoder`,
  `Web.TextEncoderStream`, and `Web.TextDecoderStream`.
- `Web.ByteLengthQueuingStrategy` and `Web.CountQueuingStrategy` for
  strategy-aware stream buffering.
- `Web.CompressionStream` and `Web.DecompressionStream` for
  WHATWG-style gzip, deflate, and deflate-raw stream transforms.
- `BENCHMARKS.md` draft with selective-receive, abort-latency, GC-isolation,
  and throughput measurements for the responsive-core changes.

## Changed

- `Web.ReadableStream`, `Web.WritableStream` now use `use Web.Stream`.
- `Web.TransformStream` now follows WHATWG-style transformer callbacks:
  `start/1`, `transform/2`, and `flush/1`, with support for `:ok` or
  `%Web.Promise{}` returns.
- `examples/stream/byte_counter_stream.exs` now uses `ReadableStream.pipe_to/3` and `ReadableStream.pipe_through/3` instead of manual pump logic.
- `Web.fetch/2` now returns `%Web.Promise{}` and `await/1` now unwraps fulfilled values or exits with the rejection reason.
- Body readers such as `Response.text/1`, `Response.json/1`, `Request.array_buffer/1`, and writer operations such as `WritableStreamDefaultWriter.write/2` now return `%Web.Promise{}` values.
- `Web.Body.clone/1` now returns `{original, clone}` directly instead of an `{:ok, ...}` tuple.
- `Web.Body.text/1` now decodes through `Web.TextDecoder`, preserving UTF-8
  correctness across streamed chunk boundaries and honoring replacement or
  fatal decoding semantics.
- `Web.ReadableStream.tee/1` now uses bounded branch buffering so a fast branch
  can progress independently of a slower branch up to the configured queue
  size.
- `Web.Stream` now parks transform writes on readable backpressure instead of
  over-buffering producer-consumer queues.
- `Web.Stream` now routes internal control signals through ref-tagged receives,
  uses local priority messaging when available, and sets stream message queues
  to `:off_heap`.
- `README.md` now includes benchmark highlights for the responsive-core
  changes.

## [0.2.0] - 2026-04-03

### Added

- `use Web` macro for easier API usage and module aliasing.
- `await` macro in `Web`.
- `Web.Stream.__using__/1` macro for reusable stream module setup (`@behaviour` + `start_link/1`).
- Spec-compliant `Web.ReadableStream` built on `:gen_statem`.
- Constructor-style `new/2` DSL macro.
- `ReadableStream.new/1`, `ReadableStream.tee/1`, and `ReadableStream.from/1`.
- Body mixin (`Web.Body`) now shared by `Web.Request` and `Web.Response` with these helpers:
	- `text/1`
	- `json/1`
	- `array_buffer/1`
	- `bytes/1`
	- `blob/1`
	- `clone/1` (via `ReadableStream.tee/1`)
- Body mixin behavior details implemented:
	- Disturbed-body guard (`body already used`) for repeated reads.
	- Shared content-type inference in constructors when header is not provided.
- Typed Web data types implemented:
	- `Web.ArrayBuffer`
	- `Web.Uint8Array`
	- `Web.Blob`
- Typed body normalization implemented in `Request.new/2` and `Response.new/1` for:
	- `nil`
	- binary/string body
	- `%Web.URLSearchParams{}`
	- `%Web.Blob{}`
	- `%Web.ArrayBuffer{}`
	- `%Web.Uint8Array{}`
	- generic enumerables via `ReadableStream.from/1`
- Content-type inference implemented for:
	- `%Web.URLSearchParams{}` -> `application/x-www-form-urlencoded;charset=UTF-8`
	- binary/string body -> `text/plain;charset=UTF-8`
	- `%Web.Blob{type: type}` when `type` is non-empty
- Response factories implemented:
	- `Response.error/0`
	- `Response.json/2`
	- `Response.redirect/2`
- Protocol-agnostic HTTP status code mapping moved to `Web.Dispatcher.HTTP`.
- `Web.Headers` now implements `Enumerable` protocol (count, member?, reduce).
- `Web.Headers` now implements `Inspect` protocol with automatic redaction of sensitive headers (authorization, cookie, set-cookie, proxy-authorization).
- Request method normalization to uppercase via `String.upcase()`.
- Lazy Blob part traversal in `ReadableStream.from/1` ensures no eager flattening.
- Verified all body-reading methods honor the `[[disturbed]]` state via guard checks.
- Verified stream cloning via `tee/1` maintains branch independence and isolation.

### Changed

- `ReadableStream` refactored so the stream is the process itself.
- `Response.new/1` now accepts optional `:status_text` parameter (defaults to `""`).
- Additional module and examples documentation.

## [0.1.0] - 2026-03-29

### Added

- Core Fetch API surface: `fetch`, `Request`, `Response`, and `Headers`.
- Core URL and cancellation APIs: `URL`, `URLSearchParams`, `AbortController`, and `AbortSignal`.
