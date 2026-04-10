# Benchmarks

This draft captures the benchmark suite for the responsive-core refactor and is intended to feed the main `README.md`.

## Environment

| Field | Value |
| --- | --- |
| Hardware | Intel Core i5-7400 @ 3.00 GHz, 4 cores, 15.57 GB RAM |
| OS | Linux 6.6.87.2-microsoft-standard-WSL2 (x86_64) |
| Erlang/OTP | 28.4 |
| Elixir | 1.19.5 |

## Selective Receive: O(1) Verification

Benchmark script: `mix run bench/selective_receive.exs`

Method:

- Preload a dedicated benchmark process mailbox with unrelated `{:data_chunk, n}` messages.
- Compare a legacy FIFO control receive (`receive do :control -> ... end`) against the ref-tagged selective receive pattern used by the responsive core (`receive do {:control, ^ref} -> ... end`).
- Reuse the same clogged mailbox for 2,000 control receives per iteration so mailbox setup cost does not dominate the result.

Assumption:

- This comparison now uses the current checkout `9babea0 (HEAD)` against the immediately previous commit `fa74d7f (HEAD~1)`.
- `fa74d7f` predates `Web.Stream.control_call/3`, `Web.Stream.control_cast/2`, and `Process.flag(:message_queue_data, :off_heap)` in [lib/web/stream.ex](/home/esente/Projects/sntran/web/lib/web/stream.ex), so the benchmark’s legacy side models the old untagged control-message receive behavior from that codebase while the current side models the ref-tagged receive now present at `HEAD`.

### Results

Benchee reports below are per benchmark iteration, where each iteration performs 2,000 control receives against the same preloaded mailbox.

| Mailbox Depth | `fa74d7f` (`HEAD~1`) avg | `9babea0` (`HEAD`) avg | Approx. per receive | Percent Improvement |
| --- | --- | --- | --- | --- |
| 1,000 | 13.06 ms | 0.64 ms | 6.53 us -> 0.32 us | 95.10% |
| 10,000 | 123.00 ms | 0.79 ms | 61.50 us -> 0.40 us | 99.36% |
| 100,000 | 1.76 s | 2.78 ms | 880.00 us -> 1.39 us | 99.84% |

Observed throughput ratios from Benchee:

- `1k`: `HEAD` is `20.33x` faster than `HEAD~1`.
- `10k`: `HEAD` is `155.28x` faster than `HEAD~1`.
- `100k`: `HEAD` is `631.67x` faster than `HEAD~1`.

### Summary

- The `fa74d7f` control path scales linearly with mailbox depth: `13.06 ms` at `1k`, `123.00 ms` at `10k`, and `1.76 s` at `100k`.
- The `9babea0` ref-tagged path stays effectively flat in the sub-millisecond to low-millisecond range: `0.64 ms`, `0.79 ms`, and `2.78 ms` for the same depths.
- This is the expected signature of Erlang's reference-optimized selective receive and is the core proof that control-plane messages no longer suffer mailbox-scanning overhead under data-plane pressure.

### Clogged Pipe Abort Latency

Benchmark script: `mix run bench/clogged_abort_latency.exs`

Method:

- Start a `WritableStream` with a blocked first write so the stream stays active.
- Flood the controller mailbox with 50,000 raw write calls.
- Measure elapsed microseconds from `WritableStream.abort(stream, :emergency_stop)` to the sink `abort/1` callback firing.
- Collect 15 samples per revision and report percentile latencies.

Results:

| Metric | `fa74d7f` (`HEAD~1`) | `9babea0` (`HEAD`) | Delta |
| --- | --- | --- | --- |
| p50 | 1,512,308 us | 1,446,793 us | 4.33% faster |
| p95 | 4,679,517 us | 16,133,241 us | 244.76% slower |
| p99 | 4,679,517 us | 16,133,241 us | 244.76% slower |
| avg | 2,194,247.2 us | 3,023,890.8 us | 37.81% slower |

Summary:

- This harness did not show the clean p99 win we expected from priority messaging.
- `HEAD` improved median abort latency slightly, but long-tail results were worse in this run.
- Because the distribution is noisy and the result contradicts the existing regression test, this benchmark should be treated as exploratory rather than README headline material until the abort path is instrumented more precisely inside the engine.

### Memory and GC Isolation

Benchmark script: `mix run bench/gc_isolation.exs`

Method:

- Create a `WritableStream` whose sink gzip-compresses each chunk through a zlib-owning `Agent`.
- Flood the stream controller with 1,600 writes of 64 KiB each for a total of 100 MiB.
- Sample `:erlang.process_info/2` for `:garbage_collection`, `:total_heap_size`, and `:message_queue_len` while the stream drains.

Results:

| Metric | `fa74d7f` (`HEAD~1`) | `9babea0` (`HEAD`) | Delta |
| --- | --- | --- | --- |
| GC count | 0 | 0 | no change observed |
| max heap words | 225,381 | 229,236 | 1.71% higher |
| final heap words | 225,340 | 4,264 | 98.11% lower |
| peak queue len | 1,415 | 905 | 36.04% lower |

Summary:

- We did not observe a GC-count reduction in this environment; both revisions stayed at `0` GCs during the sample window.
- The `:off_heap` queue flag still showed a meaningful isolation benefit after the burst: the controller in `HEAD` drained back to `4,264` heap words instead of remaining inflated at `225,340`.
- Peak queued messages also dropped from `1,415` to `905`, which suggests smoother recovery under burst pressure even though max heap size was roughly flat.

### Throughput Parity

Benchmark script: `mix run bench/throughput.exs`

Method:

- Run a full `ReadableStream.pipe_through/3` gzip pipeline over 32 MiB of input.
- Compare the built-in `CompressionStream` against a benchmark-local gzip stream that uses the same `Web.Stream` engine.
- Use Benchee to measure end-to-end runtime and derive MB/s.

Results:

| Pipeline | Avg runtime | Throughput | Relative result |
| --- | --- | --- | --- |
| `CompressionStream` | 263.68 ms | 121.36 MB/s | baseline |
| inline zlib stream | 454.42 ms | 70.42 MB/s | 1.72x slower |

Summary:

- The previous commit does not contain `CompressionStream`, so there is no direct `HEAD~1` throughput baseline for this feature.
- Within `HEAD`, the built-in `CompressionStream` was faster than the benchmark-local inline gzip stream by about 72.34%, so we did not detect a throughput regression from the new wrapper path on this machine.
