# Examples

Each example is a script that runs in this project:

```shell
mix run examples/demo.exs
```

Start with `demo.exs`. The examples that need the network or a server say
so.

| Example | What it shows | Needs |
| --- | --- | --- |
| `demo.exs` | A short tour: `fetch`, a body as a stream, `tee` and `pipe_through`, an abort signal, and a governor. | Nothing |
| `fetch_pool.exs` | Four requests with two at a time, with `Web.CountingGovernor`. | The network |
| `stream/byte_counter_stream.exs` | A response body through a custom stream and through a transform stream. | The network |
| `stream/live_round_trip.exs` | A pipeline of transform streams: compress, decompress, and decode. | Nothing |
| `stream/hardened_pipeline.exs` | An abort signal stops a pipeline whose source has no end. | Nothing |
| `secure_byob_stream.exs` | A byte stream with a BYOB reader: the consumer gives the buffer, and each read fills it. | Nothing |
| `streaming_upload_proxy.exs` | A multipart upload of 1 GiB through `Web.FormData`: the file is a stream, and the memory stays flat. | Nothing |
| `async_runtime_power.exs` | `Web.AsyncContext`: the values, the logger metadata, and the abort signal go into the callbacks of streams and promises. | Nothing |
| `secure_worker.exs` | `Web.MessageChannel`: a worker gets a port, and its secrets stay behind that port. | Nothing |
| `cluster_auth_sync.exs` | `Web.BroadcastChannel` between two nodes. | Erlang distribution |
| `smtp_client.exs` | `Web.connect/2`: a TCP socket that starts TLS, with a line stream from `line_transform_stream.ex`. | An SMTP server |

`line_transform_stream.ex` is a module, not a script: a transform stream
that gives one chunk for each line.
