# Changelog

All notable changes to this project are documented in this file.

## [Unreleased] - 2026-11-19

### Added

- Time limits for `Web.fetch/2`. `config :web, connect_timeout: ms` is the
  time to open a connection, also for `Web.connect/2`. The default is
  10000 ms. `config :web, receive_timeout: ms` is the time to wait for the
  response headers or for the next part of a body. The default is
  300000 ms. A request that fails for one of these limits rejects with
  `Web.TypeError`.
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
  body of a `Web.fetch/2` response. A body that no process starts to read in
  that time releases its connection, and a later read rejects. The default
  is 300000 ms. The value `:infinity` removes the limit.
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

### Changed

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
  - The default of `url` is `""`. The response of `Web.fetch/2` has the type
    `"basic"`.
  - `json/2` has an empty status text, keeps a `content-type` that `init`
    has, and raises `Web.TypeError` for a value that cannot be changed to
    JSON.
  - `redirect/2` has an empty status text, puts the serialized URL in the
    header `location`, raises `Web.TypeError` for a URL that is not valid,
    and raises `Web.RangeError` for a status that is not a redirect status.
  - `json/1` of a request or a response rejects with `Web.SyntaxError` when
    the body is not JSON. Before, the reason was `Jason.DecodeError`, which
    is now in the field `cause`.
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
  `ReadableByteStreamController.byob_request/1`.
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

### Fixed

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
