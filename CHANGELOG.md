# Changelog

All notable changes to this project are documented in this file.

## [Unreleased] - 2026-04-09

### Added

- `Web.File`.
- `Web.FormData` struct and streaming multipart parser.
- `examples/streaming_upload_proxy.exs` demonstrating a WHATWG-only multipart
	ingestion flow (`Response.form_data/1` + `FormData.get/2`) that streams a
	simulated `1 GiB` file to a writable sink while reporting memory checkpoints.

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
