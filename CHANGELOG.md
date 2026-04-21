# Changelog

All notable changes to this project are documented in this file.

## [Unreleased] - 2026-04-20

### Added

- `Web.Socket` plus `Web.connect/1-2` for capability-gated TCP/TLS sockets
  with WHATWG stream endpoints, lifecycle promises, and `STARTTLS` upgrade
  support.
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

- `Web.ReadableStream.new/2` now accepts explicit queueing options and
  inherits high-water-mark and strategy metadata from the underlying source
  when present.
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
