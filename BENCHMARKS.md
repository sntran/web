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
| A readable stream | 2093 | 33486 | 1.0 MiB |
| The stream through one transform stream | 733 | 11735 | 1.5 MiB |
| A response body of `fetch`, from a server on the machine | 1109 | 578 | 8.3 MiB |

Each chunk goes through one process for each stream, which costs
approximately 30 microseconds for each chunk and each stream. Thus the
speed in bytes increases with the size of the chunks: the body of `fetch`
has chunks of approximately 2 MiB.

The memory does not increase with the number of bytes.

## A form upload of 1 GiB

```shell
mix run bench/form_data_memory.exs
```

One file of 1 GiB goes through `Web.FormData` in the two directions.

| Direction | Seconds | Increase of memory |
| --- | --- | --- |
| Parse a `multipart/form-data` body, and read the file as a stream | 1.05 | 2.8 MB |
| Encode a form with a file that has a stream | 0.94 | 0.4 MB |

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
| 1000 | 115 µs |
| 50000 | 2.4 ms |
| 200000 | 10.7 ms |

An abort is a priority message of Erlang/OTP: the stream gets it before the
requests. Before version 0.5.0, the stream handled each request first:
with 5000 requests the abort took 24.6 ms, and the time increased with the
square of the number of requests.

## Compression

```shell
mix run bench/throughput.exs
```

The script compresses 32 MiB with `Web.CompressionStream` and with `:zlib`
in a transform stream that the script makes.

| Pipeline | Time for 32 MiB |
| --- | --- |
| `Web.CompressionStream` | 114.8 ms |
| `:zlib` in a transform stream | 117.7 ms |

## Garbage collection of a stream process

```shell
mix run bench/gc_isolation.exs
```

The script writes 100 MiB to a writable stream and examines the stream
process: it had 0 garbage collections of its own data, and its heap had
227920 words at most. The chunks are binaries that the VM keeps outside
the heaps of the processes.
