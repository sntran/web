# Benchmarks

The scripts in `bench/` measure the properties that the library promises:
a stream that keeps no data, a mailbox that does not delay an abort, and a
form upload with flat memory.

The numbers below are from one run of each script. Run the scripts on your
machine to get your numbers.

| Field | Value |
| --- | --- |
| Hardware | Intel Xeon @ 2.30 GHz, 4 cores, 15.7 GB of memory (a virtual machine) |
| Operating system | Linux 6.18 (x86_64) |
| Erlang/OTP | 29.1.2 |
| Elixir | 1.20.5 |

## Speed of a stream

```shell
mix run bench/stream_throughput.exs
```

The script reads 512 MiB in chunks of 64 KiB with `Enum`.

| Source | MiB each second | Chunks each second | Increase of memory |
| --- | --- | --- | --- |
| A readable stream | 13238 | 211811 | 1.2 MiB |
| The stream through one transform stream | 1417 | 22674 | 0.4 MiB |
| A response body of `fetch`, from a server on the machine | 1099–1230 | 600–882 | 1–21 MiB |

The memory does not increase with the number of bytes. The body of
`fetch` is limited by the server of the script, which sends from one
process.

Version 0.5.0 runs the callbacks of a stream in one worker process for the
life of the stream, and the internal readers take all the chunks of the
queue in one message. Before, each callback started a task through one
supervisor: a readable stream read 2028 MiB each second, and a transform
stream 841 MiB.

The cost of each chunk, for one process that reads 20000 chunks:

| Pipeline | Before 0.5.0 | 0.5.0 |
| --- | --- | --- |
| `ReadableStream.from` read with `Enum` | 26–32 µs | 2.5 µs |
| `from` through one `TransformStream` | 87 µs | 45 µs |
| Elixir `Stream` in one process (for comparison) | 0.07 µs | 0.07 µs |

Many streams at the same time use all the cores:

| Streams at the same time | Before 0.5.0 | 0.5.0 |
| --- | --- | --- |
| 1 | 38400 chunks/s | 536560 chunks/s |
| 4 | 52836 chunks/s | 2037905 chunks/s |
| 16 | 68457 chunks/s | 1870033 chunks/s |

## A form upload of 1 GiB

```shell
mix run bench/form_data_memory.exs
```

One file of 1 GiB goes through `Web.FormData` in the two directions.

| Direction | Seconds | Increase of memory |
| --- | --- | --- |
| Parse a `multipart/form-data` body, and read the file as a stream | 0.85 | 2.1 MB |
| Encode a form with a file that has a stream | 0.07 | 0.8 MB |

Before version 0.5.0, a read with `Enum` kept each chunk for 5 seconds:
the parse of this file added 1156 MB.

## An abort with a full mailbox

```shell
mix run bench/clogged_abort_latency.exs
```

The script puts write requests into the mailbox of a writable stream, then
aborts the stream. It measures the time to the call of the function
`abort` of the sink.

| Requests in the mailbox | Time (median of 9) |
| --- | --- |
| 1000 | 124 µs |
| 50000 | 131 µs |
| 200000 | 131 µs |

An abort is a priority message of Erlang/OTP: the stream gets it before the
requests, and the time does not change with the number of requests. Before
version 0.5.0, the stream handled each request first: with 5000 requests
the abort took 24.6 ms, and the time increased with the square of the
number of requests.

## Compression

```shell
mix run bench/throughput.exs
```

The script compresses 32 MiB with `Web.CompressionStream` and with `:zlib`
in a transform stream that the script makes.

| Pipeline | Time for 32 MiB |
| --- | --- |
| `Web.CompressionStream` | 92.3 ms |
| `:zlib` in a transform stream | 97.6 ms |

## Garbage collection of a stream process

```shell
mix run bench/gc_isolation.exs
```

The script writes 100 MiB to a writable stream and examines the stream
process: it had 0 garbage collections of its own data, and its heap had
227069 words at most. The chunks are binaries that the VM keeps outside
the heaps of the processes.

## Comparison with other HTTP clients

This comparison is not a script of the repository, because Req is not a
dependency of the package. It ran in a separate Mix project with Bandit as
the server, on the same machine, with the HTTP/1.1 pool of each client.

| Test | Finch | Req | `Web.fetch` 0.5.0 | `Web.fetch` before 0.5.0 |
| --- | --- | --- | --- | --- |
| Small JSON response, one request at a time | 89 µs | 99–116 µs | 410–430 µs | 632–678 µs |
| Small JSON response, 50 processes | 21185 req/s | 19289–19430 req/s | 7645–8221 req/s | 5209–5252 req/s |
| 256 MiB body as a stream | — | 1210 MiB/s | 1435 MiB/s | 1302–2319 MiB/s |
| 256 MiB body in memory | — | 681 MiB/s | 701 MiB/s | 765–813 MiB/s |

A small request with `fetch` and `Web.Response.text/1` starts six
processes: for the promises, the HTTP worker, a watcher, and the body
stream. Req starts none. This difference is the cost of a response whose
body is a stream that a different process can read and cancel.

The numbers vary by up to 2 times between runs on this virtual machine.

