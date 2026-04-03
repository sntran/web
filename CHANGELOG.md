# Changelog

All notable changes to this project are documented in this file.

## [Unreleased] - 2026-04-03

### Added

- `use Web` macro for easier API usage and module aliasing.
- `await` macro in `Web`.
- Spec-compliant `Web.ReadableStream` built on `:gen_statem`.
- Constructor-style `new/2` DSL macro.
- `ReadableStream.new/1`, `ReadableStream.tee/1`, and `ReadableStream.from/1`.
- Body mixin (`Web.Body`) now shared by `Web.Request` and `Web.Response` with these helpers:
	- `text/1`
	- `json/1`
	- `arrayBuffer/1`
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