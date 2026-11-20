# Benchmarks

The scripts in `bench/` measure the properties that the library promises:
a stream that keeps no data, a mailbox that does not delay an abort, and a
form upload with flat memory. One script compares `Web.fetch/2` with other
HTTP clients.

The numbers below are from one or two runs of each script. A range shows
two runs. Run the scripts on your machine to get your
numbers.

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
| A readable stream from `ReadableStream.from/1` | 4014–4615 | 64226–73840 | 0.8 MiB |
| The stream through one transform stream | 1645–1969 | 26320–31508 | 0.3 MiB |
| A response body of `fetch`, from a server on the machine | 1124–1290 | 869 | 8–20 MiB |

The memory does not increase with the number of bytes. The body of
`fetch` is limited by the server of the script, which sends from one
process.

The streams follow the pull rules of the Streams Standard:

  * `ReadableStream.from/1` has the high water mark 0, and each pull takes
    one element of the enumerable. Thus each chunk of the first line is one
    pull: a cycle of messages between the stream, its worker process, and
    the process of the enumerable.
  * The pulls of one stream run one after the other. A larger high water
    mark thus does not make `from/1` faster: it only lets the source work
    before a read.
  * The internal readers (`Enum`, a pipe, and the body functions) take all
    the chunks of the queue in one message. A source that enqueues many
    chunks for one pull, such as the body of a `fetch` response, thus gives
    many chunks for each message.

Version 0.5.0 runs the callbacks of a stream in one worker process for the
life of the stream. Before, each callback started a task through one
supervisor: a readable stream read 2028 MiB each second, and a transform
stream 841 MiB.

The cost of each element, for one process that reads 20000 small elements:

| Pipeline | Before 0.5.0 | 0.5.0 |
| --- | --- | --- |
| `ReadableStream.from` read with `Enum` | 26–32 µs | 14–17 µs |
| `ReadableStream.new` with a `pull` that enqueues one chunk, read with `Enum` | — | 9–14 µs |
| `from` through one `TransformStream` | 87 µs | 31–42 µs |
| `Web.Promise.new` and `Web.await` | — | 7–9 µs |
| A message to a process and its answer (for comparison) | 2.3 µs | 2.3 µs |
| Elixir `Stream` in one process (for comparison) | 0.07 µs | 0.07 µs |

Many streams at the same time use all the cores. The machine has 4 cores,
thus 16 streams do not read more than 4 streams.

| Streams at the same time | Before 0.5.0 | 0.5.0 |
| --- | --- | --- |
| 1 | 38400 chunks/s | 59916–77032 chunks/s |
| 4 | 52836 chunks/s | 144416–154646 chunks/s |
| 16 | 68457 chunks/s | 126122–176991 chunks/s |

## A form upload of 1 GiB

```shell
mix run bench/form_data_memory.exs
```

One file of 1 GiB goes through `Web.FormData` in the two directions, in
chunks of 64 KiB.

| Direction | Seconds | Increase of memory |
| --- | --- | --- |
| Parse a `multipart/form-data` body, and read the file as a stream | 0.72–1.15 | 1.0–2.1 MB |
| Encode a form with a file that has a stream | 0.57–0.84 | 0.3–0.8 MB |

Before version 0.5.0, a read with `Enum` kept each chunk for 5 seconds:
the parse of this file added 1156 MB.

The file stream of the encode comes from `ReadableStream.from/1`, and the
body of the form is a second such stream. Each chunk is thus two pulls
in series, approximately 29 µs. That is the cost of the pull rules of
the Streams Standard: a stream that takes chunks before a read encoded
the file in 0.07 s.

## An abort with a full mailbox

```shell
mix run bench/clogged_abort_latency.exs
```

The script puts write requests into the mailbox of a writable stream, then
aborts the stream. It measures the time to the call of the function
`abort` of the sink.

| Requests in the mailbox | Time (median of 9) |
| --- | --- |
| 1000 | 84 µs |
| 50000 | 90 µs |
| 200000 | 98 µs |

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

```shell
mix run bench/http_clients.exs
```

The script starts one Bandit server on the machine, and compares
`Web.fetch/2` with Finch, which `Web.fetch/2` uses, and with Req. The three
clients use the same HTTP/1.1 pool, and the server sends no compressed
response. Each pair does the same work: Req with its JSON decode and
`fetch` with `json/1` give a map, and Req with no decode and `fetch` with
`text/1` give a binary. Req is a dependency only in the environment
`:dev`.

| Test | Finch | Req | `Web.fetch` |
| --- | --- | --- | --- |
| Small JSON response, one request at a time, as a map | — | 99–109 µs | 286–309 µs |
| Small JSON response, one request at a time, as a binary | 81–88 µs | 95–103 µs | 307–318 µs |
| Small JSON response, 50 processes, as a map | — | 18567–23741 req/s | 7823–10640 req/s |
| Small JSON response, 50 processes, as a binary | 19036–26954 req/s | 20278–26520 req/s | 8322–8829 req/s |
| 256 MiB body, read as a stream | — | 1431–1563 MiB/s | 1908–3034 MiB/s, +8–12 MiB |
| 256 MiB body, read into memory | — | 746–779 MiB/s | 825–827 MiB/s |

Before version 0.5.0, a small request with `fetch` took 632–678 µs, and 50
processes did 5209–5252 requests each second. That comparison ran in a
separate Mix project on the same machine.

A small request with `fetch` starts approximately six processes: for the
promises, the HTTP worker, a watcher, and the body stream. Req starts none.
This difference is the cost of a response whose body is a stream that a
different process can read and cancel. The work is CPU work: the client
does not wait for a time limit or for a message that comes late.

The numbers vary by up to 2 times between runs on this virtual machine.
