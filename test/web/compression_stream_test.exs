defmodule Web.CompressionPBTTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog
  import Web, only: [await: 1]

  alias Web.ArrayBuffer
  alias Web.AsyncContext
  alias Web.CompressionStream
  alias Web.Console
  alias Web.DecompressionStream
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.Uint8Array
  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter

  @formats ~w[gzip deflate deflate-raw]

  # ---------------------------------------------------------------------------
  # Basic unit tests: construction and validation
  # ---------------------------------------------------------------------------

  describe "CompressionStream.new/1 construction" do
    test "accepts valid format strings" do
      for format <- @formats do
        cs = CompressionStream.new(format)
        assert %CompressionStream{readable: %ReadableStream{}, writable: %WritableStream{}} = cs
      end
    end

    test "rejects unknown format string with TypeError" do
      assert_raise Web.TypeError, ~r/Unsupported compression format/, fn ->
        CompressionStream.new("brotli")
      end
    end

    test "rejects non-string format with TypeError" do
      assert_raise Web.TypeError, ~r/must be a string/, fn ->
        CompressionStream.new(:gzip)
      end
    end
  end

  describe "DecompressionStream.new/1 construction" do
    test "accepts valid format strings" do
      for format <- @formats do
        ds = DecompressionStream.new(format)
        assert %DecompressionStream{readable: %ReadableStream{}, writable: %WritableStream{}} = ds
      end
    end

    test "rejects unknown format string with TypeError" do
      assert_raise Web.TypeError, ~r/Unsupported compression format/, fn ->
        DecompressionStream.new("lz4")
      end
    end

    test "rejects non-string format with TypeError" do
      assert_raise Web.TypeError, ~r/must be a string/, fn ->
        DecompressionStream.new(42)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Basic smoke tests
  # ---------------------------------------------------------------------------

  describe "basic compress/decompress smoke tests" do
    for format <- ~w[gzip deflate deflate-raw] do
      @format format
      test "#{format}: round-trip empty binary" do
        assert round_trip(<<>>, @format) == <<>>
      end

      test "#{format}: round-trip single byte" do
        assert round_trip(<<0>>, @format) == <<0>>
      end

      test "#{format}: round-trip short binary" do
        assert round_trip("hello world", @format) == "hello world"
      end

      test "#{format}: round-trip highly compressible data" do
        data = :binary.copy(<<0>>, 10_000)
        assert round_trip(data, @format) == data
      end
    end
  end

  # ---------------------------------------------------------------------------
  # PBT Property 1: Lossless Round-trip
  # ---------------------------------------------------------------------------

  property "Lossless Round-trip: compress then decompress yields the original binary" do
    check all(
            format <- member_of(@formats),
            data <- binary(min_length: 0, max_length: 4096),
            max_runs: 100
          ) do
      assert round_trip(data, format) == data
    end
  end

  # ---------------------------------------------------------------------------
  # PBT Property 2: Boundary Invariance
  # ---------------------------------------------------------------------------

  property "Boundary Invariance: decompressed result is identical regardless of input chunk size" do
    check all(
            format <- member_of(@formats),
            data <- binary(min_length: 1, max_length: 4096),
            chunk_size <- integer(1..256),
            max_runs: 50
          ) do
      single_chunk_result = round_trip(data, format)
      chunked_result = round_trip_chunked(data, format, chunk_size)

      assert single_chunk_result == data,
             "Single-chunk round-trip failed for #{format}"

      assert chunked_result == data,
             "Chunked round-trip (chunk_size=#{chunk_size}) failed for #{format}"
    end
  end

  # ---------------------------------------------------------------------------
  # PBT Property 3: Backpressure Gating
  # ---------------------------------------------------------------------------

  # This test verifies that the backpressure engine's enqueue_waiters queue
  # suspends the transform task when the readable queue is saturated. The test
  # is structurally deterministic: it polls for the invariant (enqueue_waiters ≥ 1)
  # rather than relying on a fixed sleep, then verifies the write is still in-flight.
  test "Backpressure Gating: transform task is suspended by enqueue_waiters mechanism" do
    # Incompressible (random) data ensures zlib emits multiple ~4 KB output
    # buffers for a single 100 KB deflate call. With the readable hwm=1, the
    # second buffer triggers wait_for_capacity → enqueue_waiters park.
    large_data = :crypto.strong_rand_bytes(100_000)

    cs = CompressionStream.new("deflate-raw")
    writer = WritableStream.get_writer(cs.writable)
    pid = cs.readable.controller_pid

    # Start writing in the background. Once the readable queue is full the
    # transform task parks itself in :enqueue_waiters and does NOT complete.
    write_task =
      Task.async(fn ->
        await(WritableStreamDefaultWriter.write(writer, large_data))
      end)

    # Structurally wait for the engine to park the transform task (up to 5s).
    # Polling the gen_statem state is deterministic — no fixed sleep required.
    assert wait_until(5_000, fn ->
             slots = :gen_statem.call(pid, :get_slots)
             :queue.len(slots.enqueue_waiters) >= 1
           end),
           "enqueue_waiters never reached ≥ 1 within 5s — backpressure not gating"

    # With the queue saturated the write_task must still be running.
    assert nil == Task.yield(write_task, 0),
           "Write completed before readable was drained — backpressure not holding"

    # Drain the readable side to release all parked tasks, then close.
    close_task = Task.async(fn -> await(WritableStreamDefaultWriter.close(writer)) end)
    _chunks = Enum.to_list(cs.readable)

    assert :ok == Task.await(write_task, 5_000)
    Task.await(close_task, 5_000)
  end

  # ---------------------------------------------------------------------------
  # PBT Property 4: Error Integrity
  # ---------------------------------------------------------------------------

  describe "Error Integrity: malformed or truncated data raises TypeError" do
    test "completely invalid bytes trigger TypeError during write (gzip)" do
      ds = DecompressionStream.new("gzip")
      writer = WritableStream.get_writer(ds.writable)

      # Write data that is not a valid gzip stream.
      error =
        catch_exit(
          await(WritableStreamDefaultWriter.write(writer, "absolutely not gzip \x00\xFF\xFE"))
        )

      assert %Web.TypeError{} = error,
             "Expected Web.TypeError from invalid gzip input, got: #{inspect(error)}"
    end

    test "invalid deflate bytes trigger TypeError (deflate)" do
      ds = DecompressionStream.new("deflate")
      writer = WritableStream.get_writer(ds.writable)

      error =
        catch_exit(
          await(WritableStreamDefaultWriter.write(writer, <<0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA>>))
        )

      assert %Web.TypeError{} = error
    end

    test "invalid raw deflate bytes trigger TypeError (deflate-raw)" do
      ds = DecompressionStream.new("deflate-raw")
      writer = WritableStream.get_writer(ds.writable)

      error =
        catch_exit(await(WritableStreamDefaultWriter.write(writer, <<0xFF, 0xFE, 0xFD, 0xFC>>)))

      assert %Web.TypeError{} = error
    end

    property "random garbage data always triggers TypeError on decompression" do
      # deflate-raw has no framing envelope (no magic bytes, no Adler-32/CRC32
      # checksum). Raw DEFLATE streams can begin with a stored-block header
      # (BTYPE=00) — just a 2-byte LEN/NLEN pair — so many random byte sequences
      # are accidentally valid 0-byte stored blocks. A reliable "garbage →
      # TypeError" property cannot be written for deflate-raw; it is excluded here.
      check all(
              format <- member_of(["gzip", "deflate"]),
              # Generate binaries that are extremely unlikely to be valid compressed streams.
              garbage <-
                binary(min_length: 8, max_length: 32)
                |> filter(&(not valid_compressed_prefix?(&1, format))),
              max_runs: 50
            ) do
        ds = DecompressionStream.new(format)
        writer = WritableStream.get_writer(ds.writable)

        result = catch_exit(await(WritableStreamDefaultWriter.write(writer, garbage)))

        assert %Web.TypeError{} = result,
               "Expected TypeError for garbage #{format} input, got: #{inspect(result)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Additional integration tests
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Uint8Array and invalid-chunk-type coverage
  # ---------------------------------------------------------------------------

  describe "Uint8Array and invalid chunk inputs" do
    test "runtime observation logs inherit async context metadata and console depth" do
      user = AsyncContext.Variable.new("user")

      log =
        capture_log(fn ->
          AsyncContext.Variable.run(user, "alice", fn ->
            :logger.update_process_metadata(%{
              request_id: "req-compress",
              user: AsyncContext.Variable.get(user),
              web_runtime_observe: true
            })

            Console.group("secure proxy")

            try do
              ReadableStream.from(["hello"])
              |> ReadableStream.pipe_through(CompressionStream.new("gzip"))
              |> Enum.to_list()
            after
              Console.group_end()
              :logger.set_process_metadata(%{})
            end
          end)
        end)

      assert log =~ "secure proxy"
      assert log =~ "  CompressionStream write 5B user=alice"
      assert log =~ "request_id: \"req-compress\""
      assert log =~ "group_depth: 1"
    end

    test "CompressionStream logs runtime observation events with default user and no context suffix" do
      log =
        capture_log(fn ->
          :logger.update_process_metadata(%{web_runtime_observe: true})

          try do
            ReadableStream.from(["hello world"])
            |> ReadableStream.pipe_through(CompressionStream.new("gzip"))
            |> ReadableStream.pipe_through(DecompressionStream.new("gzip"))
            |> Enum.to_list()
          after
            :logger.set_process_metadata(%{})
          end
        end)

      assert log =~ "CompressionStream write"
      assert log =~ "user=unknown"
      refute log =~ "metadata="
    end

    test "CompressionStream accepts Uint8Array chunk" do
      # Use pipe_through so the consumer drives the pipeline concurrently;
      # a sequential write→close→read deadlocks because the flush task parks
      # in enqueue_waiters until the reader drains the queue.
      arr = Uint8Array.new(ArrayBuffer.new("hello world"))
      cs = CompressionStream.new("gzip")
      ds = DecompressionStream.new("gzip")
      source = ReadableStream.from([arr])
      decompressed = source |> ReadableStream.pipe_through(cs) |> ReadableStream.pipe_through(ds)
      assert Enum.join(decompressed, "") == "hello world"
    end

    test "CompressionStream raises TypeError for non-binary non-Uint8Array chunk" do
      cs = CompressionStream.new("gzip")
      writer = WritableStream.get_writer(cs.writable)
      error = catch_exit(await(WritableStreamDefaultWriter.write(writer, 42)))
      assert %Web.TypeError{} = error
    end

    test "DecompressionStream accepts Uint8Array chunk" do
      # DecompressionStream flush produces no output (inflate(<<>>) returns [])
      # so the sequential write→close→read pattern is safe here.
      compressed = :zlib.gzip("hello world")
      arr = Uint8Array.new(ArrayBuffer.new(compressed))
      ds = DecompressionStream.new("gzip")
      source = ReadableStream.from([arr])
      assert Enum.join(ReadableStream.pipe_through(source, ds), "") == "hello world"
    end

    test "DecompressionStream raises TypeError for non-binary non-Uint8Array chunk" do
      ds = DecompressionStream.new("gzip")
      writer = WritableStream.get_writer(ds.writable)
      error = catch_exit(await(WritableStreamDefaultWriter.write(writer, :not_a_binary)))
      assert %Web.TypeError{} = error
    end

    test "DecompressionStream logs runtime observation events with default user and no context suffix" do
      log =
        capture_log(fn ->
          :logger.update_process_metadata(%{web_runtime_observe: true})

          try do
            compressed = :zlib.gzip("hello world")
            source = ReadableStream.from([compressed])
            decompressed = ReadableStream.pipe_through(source, DecompressionStream.new("gzip"))
            assert Enum.join(decompressed, "") == "hello world"
          after
            :logger.set_process_metadata(%{})
          end
        end)

      assert log =~ "DecompressionStream write"
      assert log =~ "user=unknown"
      refute log =~ "metadata="
    end

    test "DecompressionStream logs zlib failures when runtime observation is enabled" do
      log =
        capture_log(fn ->
          :logger.update_process_metadata(%{
            group_depth: 1,
            request_id: "req-decompress-error",
            user: "alice",
            web_runtime_observe: true
          })

          try do
            ds = DecompressionStream.new("gzip")
            writer = WritableStream.get_writer(ds.writable)
            error = catch_exit(await(WritableStreamDefaultWriter.write(writer, "not gzip")))
            assert %Web.TypeError{} = error
          after
            :logger.set_process_metadata(%{})
          end
        end)

      assert log =~ "DecompressionStream zlib failure"
      assert log =~ "request_id: \"req-decompress-error\""
      assert log =~ "group_depth: 1"
    end
  end

  # ---------------------------------------------------------------------------
  # Flush-error and cancel coverage
  # ---------------------------------------------------------------------------

  describe "DecompressionStream flush errors and cancel" do
    test "DecompressionStream cancel closes the zlib port without raising" do
      ds = DecompressionStream.new("gzip")
      writer = WritableStream.get_writer(ds.writable)
      compressed = :zlib.gzip("hello")
      await(WritableStreamDefaultWriter.write(writer, compressed))
      # Aborting invokes the cancel: callback which calls stop_agent.
      await(WritableStreamDefaultWriter.abort(writer, :test_cancel))
      :ok
    end

    test "DecompressionStream terminate closes the zlib agent" do
      ds = DecompressionStream.new("gzip")
      pid = ds.readable.controller_pid
      agent = Web.ReadableStream.__get_slots__(pid).impl_state.zlib_agent

      Web.Stream.terminate(pid, :cancel, :manual)

      assert wait_until(2_000, fn -> not Process.alive?(agent) end)
    end
  end

  # ---------------------------------------------------------------------------
  # ReadableStreamDefaultController.wait_for_capacity/1 error branch
  # ---------------------------------------------------------------------------

  describe "wait_for_capacity error branch" do
    test "returns :ok immediately when readable capacity is already available" do
      cs = CompressionStream.new("gzip")
      ctrl = %ReadableStreamDefaultController{pid: cs.readable.controller_pid}

      assert :ok == ReadableStreamDefaultController.wait_for_capacity(ctrl)
    end

    test "returns :ok when the stream is already closed" do
      cs = CompressionStream.new("gzip")
      pid = cs.readable.controller_pid
      ctrl = %ReadableStreamDefaultController{pid: pid}

      Web.Stream.terminate(pid, :close)

      assert wait_until(2_000, fn ->
               Web.ReadableStream.__get_slots__(pid).state == :closed
             end),
             "stream did not transition to :closed in time"

      assert :ok == ReadableStreamDefaultController.wait_for_capacity(ctrl)
    end

    test "returns :ok when the stream errors while a waiter is parked" do
      # Build an errored-stream scenario:
      #   1. Fill the readable queue to HWM=1.
      #   2. Park a task in wait_for_capacity (queue full, no drain).
      #   3. Error the stream → fail_stream fires enqueue_error_actions →
      #      parked task receives {:error, _} instead of :ok.
      #   4. wait_for_capacity returns :ok regardless, so the transform task
      #      can exit cleanly.
      cs = CompressionStream.new("gzip")
      pid = cs.readable.controller_pid
      ctrl = %ReadableStreamDefaultController{pid: pid}

      # Fill the queue so the next wait_for_capacity parks.
      Web.ReadableStream.enqueue(pid, "filler")

      # Park a task in wait_for_capacity.
      waiter = Task.async(fn -> ReadableStreamDefaultController.wait_for_capacity(ctrl) end)

      # Give the waiter time to register in enqueue_waiters.
      assert wait_until(2_000, fn ->
               :queue.len(:gen_statem.call(pid, :get_slots).enqueue_waiters) >= 1
             end),
             "Waiter did not park in enqueue_waiters within 2s"

      # Error the stream — enqueue_error_actions replies {:error, _} to the waiter.
      Web.ReadableStream.error(pid, :test_error)

      # wait_for_capacity must return :ok even for the error reply.
      assert :ok == Task.await(waiter, 2_000)
    end
  end

  describe "zlib port lifecycle" do
    test "zlib port is closed after stream completes normally" do
      # After compress + close, the zlib resource should be freed. We verify this
      # by ensuring a second identical operation works (port wasn't leaked open
      # blocking shared state).
      data = "port lifecycle test"

      r1 = round_trip(data, "gzip")
      r2 = round_trip(data, "gzip")

      assert r1 == data
      assert r2 == data
    end

    test "cancel closes the zlib port without raising" do
      cs = CompressionStream.new("gzip")
      writer = WritableStream.get_writer(cs.writable)

      await(WritableStreamDefaultWriter.write(writer, "hello"))

      # Abort the stream — should close the zlib port safely.
      await(WritableStreamDefaultWriter.abort(writer, :test_cancel))
      :ok
    end
  end

  describe "pipe_through integration" do
    test "compress → decompress pipeline yields original data" do
      data = "The quick brown fox jumps over the lazy dog. " |> String.duplicate(100)

      for format <- @formats do
        cs = CompressionStream.new(format)
        ds = DecompressionStream.new(format)

        source = ReadableStream.from([data])
        compressed = ReadableStream.pipe_through(source, cs)
        decompressed = ReadableStream.pipe_through(compressed, ds)

        assert Enum.join(decompressed, "") == data,
               "Pipeline round-trip failed for #{format}"
      end
    end

    test "compress → decompress of chunked data yields original data" do
      # 5 * 1000 = 5000 bytes; 5000 is divisible by 10, so no trailing bytes are lost.
      data = :binary.copy(<<1, 2, 3, 4, 5>>, 1000)
      chunks = for <<chunk::binary-size(10) <- data>>, do: chunk

      cs = CompressionStream.new("gzip")
      ds = DecompressionStream.new("gzip")

      source = ReadableStream.from(chunks)
      decompressed = source |> ReadableStream.pipe_through(cs) |> ReadableStream.pipe_through(ds)

      assert IO.iodata_to_binary(Enum.to_list(decompressed)) == data
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # End-to-end compress + decompress of `data` in a single chunk.
  defp round_trip(data, format) do
    cs = CompressionStream.new(format)
    ds = DecompressionStream.new(format)

    source = ReadableStream.from([data])
    compressed = ReadableStream.pipe_through(source, cs)
    decompressed = ReadableStream.pipe_through(compressed, ds)

    IO.iodata_to_binary(Enum.to_list(decompressed))
  end

  # End-to-end compress + decompress of `data`, writing in `chunk_size`-byte pieces.
  defp round_trip_chunked(data, format, chunk_size) do
    cs = CompressionStream.new(format)
    ds = DecompressionStream.new(format)

    chunks = chunk_binary(data, chunk_size)
    source = ReadableStream.from(chunks)
    compressed = ReadableStream.pipe_through(source, cs)
    decompressed = ReadableStream.pipe_through(compressed, ds)

    IO.iodata_to_binary(Enum.to_list(decompressed))
  end

  defp chunk_binary(binary, size), do: do_chunk(binary, size, [])
  defp do_chunk(<<>>, _size, acc), do: Enum.reverse(acc)

  defp do_chunk(binary, size, acc) do
    take = min(byte_size(binary), size)
    <<chunk::binary-size(take), rest::binary>> = binary
    do_chunk(rest, size, [chunk | acc])
  end

  # Returns true if `data` looks like a valid header for the given format.
  # Used to filter out accidentally-valid generator output in the error PBT.
  defp valid_compressed_prefix?(data, "gzip"), do: match?(<<0x1F, 0x8B, _::binary>>, data)
  defp valid_compressed_prefix?(data, "deflate"), do: match?(<<0x78, _::binary>>, data)
  defp valid_compressed_prefix?(_data, "deflate-raw"), do: false

  # Polls `predicate.()` every 10 ms until it returns truthy or `timeout_ms` expires.
  # Returns true if the predicate became truthy; false if the deadline was reached.
  defp wait_until(timeout_ms, predicate) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(deadline, predicate)
  end

  defp do_wait_until(deadline, predicate) do
    if predicate.() do
      true
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        false
      else
        Process.sleep(10)
        do_wait_until(deadline, predicate)
      end
    end
  end
end
