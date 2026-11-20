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
| A readable stream from `ReadableStream.from/1` | 6358–6665 | 101729–106647 | 0.9 MiB |
| The stream through one transform stream | 1758–1930 | 28132–30882 | 0.3–0.4 MiB |
| A response body of `fetch`, from a server on the machine | 1383–1630 | 586–592 | 1.0–1.2 MiB |

The memory does not increase with the number of bytes. The body of
`fetch` is limited by the server of the script, which sends from one
process.

The streams follow the pull rules of the Streams Standard:

  * `ReadableStream.from/1` has the high water mark 0, and each pull takes
    one element of the enumerable. The stream process sends the pull to the
    process of the enumerable, and that process answers the stream
    process directly: a pull costs two messages, and no other process.
  * The pulls of one stream run one after the other. A larger high water
    mark thus does not make `from/1` faster: it only lets the source work
    before a read.
  * The internal readers (`Enum` and the body functions) take all the
    chunks of the queue in one message. A source that enqueues many chunks
    for one pull, such as the body of a `fetch` response, thus gives many
    chunks for each message. A pipe reads one chunk each time the
    destination is ready, as the Streams Standard specifies. With 20000
    small chunks, a pipe through a `TransformStream` takes 32–35 µs for each
    chunk, where the reads in batches took 32–41 µs, and `pipe_to/3` takes
    21–27 µs in the two versions: the difference is not larger than the
    noise of the measurement.

Version 0.5.0 runs the callbacks of a stream in one worker process for the
life of the stream. Before, each callback started a task through one
supervisor: a readable stream read 2028 MiB each second, and a transform
stream 841 MiB.

The cost of each element, for one process that reads 20000 small elements:

| Pipeline | Before 0.5.0 | 0.5.0 |
| --- | --- | --- |
| `ReadableStream.from` read with `Enum` | 26–32 µs | 7.1–7.8 µs |
| `ReadableStream.new` with a `pull` that enqueues one chunk, read with `Enum` | — | 9–11 µs |
| `from` through one `TransformStream` | 87 µs | 26–31 µs |
| `Web.Promise.new` and `Web.await` | — | 7.8–8.5 µs |
| A message to a process and its answer (for comparison) | 2.3 µs | 2.5 µs |
| Elixir `Stream` in one process (for comparison) | 0.07 µs | 0.07 µs |

Many streams at the same time use all the cores. The machine has 4 cores,
thus 16 streams do not read more than 4 streams.

| Streams at the same time | Before 0.5.0 | 0.5.0 |
| --- | --- | --- |
| 1 | 38400 chunks/s | 159597–193136 chunks/s |
| 4 | 52836 chunks/s | 489195–490112 chunks/s |
| 16 | 68457 chunks/s | 221742–226365 chunks/s |

## A form upload of 1 GiB

```shell
mix run bench/form_data_memory.exs
```

One file of 1 GiB goes through `Web.FormData` in the two directions, in
chunks of 64 KiB.

| Direction | Seconds | Increase of memory |
| --- | --- | --- |
| Parse a `multipart/form-data` body, and read the file as a stream | 0.81 | 1.8 MB |
| Encode a form with a file that has a stream | 0.37 | 0.3 MB |

Before version 0.5.0, a read with `Enum` kept each chunk for 5 seconds:
the parse of this file added 1156 MB.

The file stream of the encode comes from `ReadableStream.from/1`, and the
body of the form is a second such stream. Each chunk is thus two pulls
in series, approximately 22 µs. That is the cost of the pull rules of
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
| 1000 | 75–84 µs |
| 50000 | 74–90 µs |
| 200000 | 98–115 µs |

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
`Web.fetch/2` with Finch and with Req. Finch and Req use one Finch pool of
25 HTTP/1.1 connections, which the script starts. `Web.fetch/2` has its own
pool of 25 connections for the origin. The server sends no compressed
response. Each pair does the same work: Req with its JSON decode and
`fetch` with `json/1` give a map, and Req with no decode and `fetch` with
`text/1` give a binary. The clients run in turns, in 8 rounds, thus a slow
time of the machine has an effect on each client. Req and Finch are
dependencies only in the environment `:dev`.

| Test | Finch | Req | `Web.fetch` |
| --- | --- | --- | --- |
| Small JSON response, one request at a time, as a map | — | 116–125 µs | 132–134 µs |
| Small JSON response, one request at a time, as a binary | 90–93 µs | 108–112 µs | 123–129 µs |
| Small JSON response, 50 processes, as a map | — | 22073–22392 req/s | 20310–20559 req/s |
| Small JSON response, 50 processes, as a binary | 26883–27065 req/s | 23363–24118 req/s | 19374–21212 req/s |
| 256 MiB body, read as a stream | — | 1192–1372 MiB/s | 1538–2240 MiB/s, +10–24 MiB |
| 256 MiB body, read into memory | — | 764–815 MiB/s | 673–752 MiB/s |

Before version 0.5.0, a small request with `fetch` took 632–678 µs, and 50
processes did 5209–5252 requests each second. That comparison ran in a
separate Mix project on the same machine. With Finch as its HTTP client,
`fetch` took 135–141 µs for the small request as a binary.

The HTTP client of `fetch` is in the library, on the connection functions
of Mint. A request with `fetch` has one process: the process of the
request, which is also the promise. It gets the connection from the pool
of its origin, and owns the socket while the response comes. Thus the
messages of the socket come to it directly. Req has no process: it runs
Finch in the process that calls it. A process that waits for a message
must wake up when the message comes, thus each process between the
network and the caller adds time. For a small response, the body is in the
struct: the response has no process, and `text/1` starts none.

The process of the request is necessary: it answers a reader of a body
that comes slowly, the abort signal, and the time limits, while the
response comes. Finch has a blocking request function, and its pool has no
other public function, thus a process that uses Finch cannot answer while
it waits. The process of the request costs approximately 15–20 µs more
than Req for a small request, on this machine.

For a large body, the process of the request reads the socket and gives
the chunks to the stream. It reads one message of the socket at a time,
and it stops to read while it has 64 KiB that no reader took. Thus the
memory of a stream read stays small.

The numbers vary by up to 2 times between runs on this virtual machine.

## A `tcp:` fetch

```shell
mix run bench/tcp_fetch.exs
```

The script starts a server on the machine, and fetches `tcp:` URLs. The
old and the new code ran in turns, two times each.

| Test | Before | After |
| --- | --- | --- |
| Processes for each body that no process reads, with a signal | 15 | 1 |
| Small response (5 bytes, then the server closes) | 1416–1503 µs | 567–654 µs |
| Small response to `127.0.0.1` | — | 317 µs, before the change of the address: 451 µs |
| Stream read of 64 MiB | 119–122 MiB/s | 1685 MiB/s; with the default buffer of `:gen_tcp`, 468–600 MiB/s |

Before, `Web.Dispatcher.TCP` used `Web.connect/2`. A bridge process read the
socket stream, and gave each chunk to a second stream when it pulled. A
process watched the abort signal, and examined it each 25 ms. Now the
process of the request is the promise, as for HTTP: it opens the socket,
writes the request body, and holds the response body. It reads one message
of the socket at a time, and it gets the abort as a message. The holder of
the body is the same code as for HTTP: see `Web.Dispatcher.RequestProcess`.

A small response to `127.0.0.1` takes less time than to `localhost`: a
connection gives an IP address to Erlang as a tuple, with no lookup. A
lookup of `localhost` takes approximately 90 µs on this machine. The
default buffer of `:gen_tcp` gives messages of approximately 9 KiB, and
each message costs messages between processes: the process of the request
uses a buffer of 64 KiB.

## A `Web.connect/2` socket

`mix run bench/socket.exs` compares a read and a write of 64 MiB on a socket with raw
`:gen_tcp` in the process that reads, in turns, 5 times each. The numbers
are the medians of two runs. Other work used the machine at the same time,
thus compare the numbers of one column with the raw read.

| Test | Before | After | Raw `:gen_tcp` |
| --- | --- | --- | --- |
| Read of 64 MiB | 157–172 MiB/s | 1162–1719 MiB/s | 1618–2281 MiB/s |
| Write of 64 MiB | 737–883 MiB/s | 888–1009 MiB/s | — |
| Processes for each socket | 7 | 6 | — |

Before, the socket process enqueued each chunk, and then called the stream
to get its desired size. The pull of the stream ran in a worker, and sent
a message to the socket process. Now the stream sends its pull to the
socket process directly, and the socket asks its connection for one
message for each pull, with a buffer of 64 KiB. The three promises
`opened`, `closed`, and `upgraded` stay processes: each `Web.Promise` is a
process.
