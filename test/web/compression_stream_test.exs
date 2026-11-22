defmodule Web.CompressionPBTTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.ArrayBuffer
  alias Web.CompressionStream
  alias Web.DecompressionStream
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.ReadableStreamDefaultReader
  alias Web.Uint8Array
  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter

  @formats ~w[brotli gzip deflate deflate-raw]

  # The readable side has the high water mark 0, as the Compression Standard
  # specifies. Thus the transform of a chunk starts only when a read waits,
  # and a test starts a read before it waits for a write.
  defp start_read(stream) do
    stream.readable |> ReadableStream.get_reader() |> ReadableStreamDefaultReader.read()
  end

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
        CompressionStream.new("br")
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
    for format <- ~w[brotli gzip deflate deflate-raw] do
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

  # The backpressure of the Streams Standard for a transform with the
  # readable high water mark 0: a write starts only when a read asks for a
  # chunk, and the output of a write goes to the queue at once.
  test "Backpressure Gating: the next write starts only when a read waits for a chunk" do
    # Random data does not compress: zlib gives more than one output buffer
    # for one deflate call of 100 KB.
    cs = CompressionStream.new("deflate-raw")
    writer = WritableStream.get_writer(cs.writable)
    reader = ReadableStream.get_reader(cs.readable)
    pid = cs.readable.controller_pid

    first_read = ReadableStreamDefaultReader.read(reader)
    first = WritableStreamDefaultWriter.write(writer, :crypto.strong_rand_bytes(100_000))
    second = WritableStreamDefaultWriter.write(writer, :crypto.strong_rand_bytes(100_000))

    # The first read starts the first write. The first buffer goes to the
    # read, and the other buffers go to the queue: the write is complete.
    assert :ok = await(first)
    assert %{done: false, value: %Uint8Array{}} = await(first_read)

    # No read waits for a chunk, thus the second write does not start.
    slots = ReadableStream.__get_slots__(pid)
    assert slots.active_task == nil
    assert :queue.len(slots.queued_write_requests) == 1
    assert :queue.is_empty(slots.enqueue_waiters)
    queued = :queue.len(slots.queue)
    assert queued >= 1

    # The reads take the chunks of the queue. They do not start the second
    # write.
    for _ <- 1..queued,
        do: assert(%{done: false} = await(ReadableStreamDefaultReader.read(reader)))

    assert Web.Promise.peek(second) == :pending
    assert ReadableStream.__get_slots__(pid).active_task == nil

    # A read that waits for a chunk starts the second write.
    next_read = ReadableStreamDefaultReader.read(reader)
    assert :ok = await(second)
    assert %{done: false, value: %Uint8Array{}} = await(next_read)

    close = WritableStreamDefaultWriter.close(writer)
    _chunks = read_all(reader)
    assert :ok = await(close)
  end

  # ---------------------------------------------------------------------------
  # PBT Property 4: Error Integrity
  # ---------------------------------------------------------------------------

  describe "Error Integrity: malformed or truncated data raises TypeError" do
    test "completely invalid bytes trigger TypeError during write (gzip)" do
      ds = DecompressionStream.new("gzip")
      writer = WritableStream.get_writer(ds.writable)
      read = start_read(ds)

      # Write data that is not a valid gzip stream.
      error =
        catch_exit(
          await(WritableStreamDefaultWriter.write(writer, "absolutely not gzip \x00\xFF\xFE"))
        )

      assert %Web.TypeError{} = error,
             "Expected Web.TypeError from invalid gzip input, got: #{inspect(error)}"

      assert %Web.TypeError{} = catch_exit(await(read))
    end

    test "invalid deflate bytes trigger TypeError (deflate)" do
      ds = DecompressionStream.new("deflate")
      writer = WritableStream.get_writer(ds.writable)
      read = start_read(ds)

      error =
        catch_exit(
          await(WritableStreamDefaultWriter.write(writer, <<0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA>>))
        )

      assert %Web.TypeError{} = error
      assert %Web.TypeError{} = catch_exit(await(read))
    end

    test "invalid raw deflate bytes trigger TypeError (deflate-raw)" do
      ds = DecompressionStream.new("deflate-raw")
      writer = WritableStream.get_writer(ds.writable)
      read = start_read(ds)

      error =
        catch_exit(await(WritableStreamDefaultWriter.write(writer, <<0xFF, 0xFE, 0xFD, 0xFC>>)))

      assert %Web.TypeError{} = error
      assert %Web.TypeError{} = catch_exit(await(read))
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
        read = start_read(ds)

        result = catch_exit(await(WritableStreamDefaultWriter.write(writer, garbage)))

        assert %Web.TypeError{} = result,
               "Expected TypeError for garbage #{format} input, got: #{inspect(result)}"

        assert %Web.TypeError{} = catch_exit(await(read))
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
    test "CompressionStream accepts Uint8Array chunk" do
      # The pipe reads while it writes. The readable side has the high water
      # mark 0: a write waits for a read.
      arr = Uint8Array.new(ArrayBuffer.new("hello world"))
      cs = CompressionStream.new("gzip")
      ds = DecompressionStream.new("gzip")
      source = ReadableStream.from([arr])
      decompressed = source |> ReadableStream.pipe_through(cs) |> ReadableStream.pipe_through(ds)
      assert Web.TestBytes.join(decompressed) == "hello world"
    end

    test "CompressionStream raises TypeError for non-binary non-Uint8Array chunk" do
      cs = CompressionStream.new("gzip")
      writer = WritableStream.get_writer(cs.writable)
      read = start_read(cs)
      error = catch_exit(await(WritableStreamDefaultWriter.write(writer, 42)))
      assert %Web.TypeError{} = error
      assert %Web.TypeError{} = catch_exit(await(read))
    end

    test "DecompressionStream accepts Uint8Array chunk" do
      # The pipe reads while it writes. The readable side has the high water
      # mark 0: a write waits for a read.
      compressed = :zlib.gzip("hello world")
      arr = Uint8Array.new(ArrayBuffer.new(compressed))
      ds = DecompressionStream.new("gzip")
      source = ReadableStream.from([arr])
      assert Web.TestBytes.join(ReadableStream.pipe_through(source, ds)) == "hello world"
    end

    test "DecompressionStream raises TypeError for non-binary non-Uint8Array chunk" do
      ds = DecompressionStream.new("gzip")
      writer = WritableStream.get_writer(ds.writable)
      read = start_read(ds)
      error = catch_exit(await(WritableStreamDefaultWriter.write(writer, :not_a_binary)))
      assert %Web.TypeError{} = error
      assert %Web.TypeError{} = catch_exit(await(read))
    end
  end

  # ---------------------------------------------------------------------------
  # Flush-error and cancel coverage
  # ---------------------------------------------------------------------------

  describe "DecompressionStream with data that expands much" do
    test "decodes only as the reader takes the chunks, in small chunks" do
      # 20 MB of zeros are approximately 20 KB with gzip.
      size = 20 * 1_048_576
      compressed = :zlib.gzip(:binary.copy(<<0>>, size))
      ds = DecompressionStream.new("gzip")
      writer = WritableStream.get_writer(ds.writable)
      reader = ReadableStream.get_reader(ds.readable)
      first_read = ReadableStreamDefaultReader.read(reader)
      write = WritableStreamDefaultWriter.write(writer, compressed)

      # The first read gets one small piece of the output. Then the write
      # waits for the next read, and the queue of the readable side is
      # empty: the readable side has the high water mark 0.
      wait_for_full_readable_side(ds.readable.controller_pid)
      assert %{done: false, value: first} = await(first_read)
      assert first.byte_length < 200_000
      assert Web.Promise.peek(write) == :pending
      assert ReadableStream.get_desired_size(ds.readable.controller_pid) == 0

      # The worker of the stream, which runs the write, keeps less than 1 MB
      # of the output: the decoder makes the next piece only when the
      # readable side has space.
      {:dictionary, dictionary} = Process.info(ds.readable.controller_pid, :dictionary)
      worker = :proplists.get_value({Web.Stream, :worker}, dictionary)
      {:binary, binaries} = Process.info(worker, :binary)
      assert binaries |> Enum.map(&elem(&1, 1)) |> Enum.sum() < 1_048_576

      close = WritableStreamDefaultWriter.close(writer)
      sizes = read_sizes(reader, [first.byte_length])

      assert Enum.sum(sizes) == size
      assert Enum.max(sizes) < 200_000
      assert :ok = await(write)
      assert :ok = await(close)
    end

    defp read_sizes(reader, sizes) do
      case await(ReadableStreamDefaultReader.read(reader)) do
        %{done: true} -> sizes
        %{value: chunk} -> read_sizes(reader, [chunk.byte_length | sizes])
      end
    end
  end

  describe "DecompressionStream flush errors and cancel" do
    test "DecompressionStream cancel closes the zlib port without raising" do
      ds = DecompressionStream.new("gzip")
      writer = WritableStream.get_writer(ds.writable)
      read = start_read(ds)
      compressed = :zlib.gzip("hello")
      await(WritableStreamDefaultWriter.write(writer, compressed))
      assert %{done: false, value: chunk} = await(read)
      assert Uint8Array.to_binary(chunk) == "hello"
      # Aborting invokes the cancel: callback which calls stop_agent.
      await(WritableStreamDefaultWriter.abort(writer, :test_cancel))
      :ok
    end

    # The callbacks run in one process, as the worker of a stream runs
    # them: the handle of the first chunk closes at a cancel.
    test "the terminate callback closes the zlib handle of each stream" do
      state = %{format: "gzip", decoder: nil}
      partial = binary_part(:zlib.gzip(:binary.copy("hello", 1_000)), 0, 10)
      ctrl = %ReadableStreamDefaultController{pid: self()}

      assert {:ok, %{decoder: [%{zlib: zlib}]} = state} =
               DecompressionStream.write(partial, ctrl, state)

      assert :ok = DecompressionStream.terminate({:cancel, :manual}, state)
      assert_raise ErlangError, fn -> :zlib.inflate(zlib, "x") end
      assert :ok = DecompressionStream.terminate({:cancel, :manual}, %{state | decoder: nil})

      zlib = :zlib.open()
      :ok = :zlib.deflateInit(zlib)
      state = %{window_bits: 31, zlib: zlib}
      assert :ok = CompressionStream.terminate({:cancel, :manual}, state)
      assert_raise ErlangError, fn -> :zlib.deflate(zlib, "x") end

      # A second close has no effect, as a close of a handle of a worker that
      # stopped.
      assert :ok = CompressionStream.terminate({:cancel, :manual}, state)
      assert :ok = CompressionStream.terminate({:cancel, :manual}, %{state | zlib: nil})
    end
  end

  # ---------------------------------------------------------------------------
  # ReadableStreamDefaultController.wait_for_capacity/1 error branch
  # ---------------------------------------------------------------------------

  describe "wait_for_capacity error branch" do
    test "waits for a read, and returns :ok at once while a read waits" do
      cs = CompressionStream.new("gzip")
      pid = cs.readable.controller_pid
      ctrl = %ReadableStreamDefaultController{pid: pid}

      # The readable side has the high water mark 0: with no read, it has no
      # space.
      waiter = Task.async(fn -> ReadableStreamDefaultController.wait_for_capacity(ctrl) end)

      assert wait_until(2_000, fn ->
               :queue.len(:gen_statem.call(pid, :get_slots).enqueue_waiters) >= 1
             end),
             "Waiter did not park in enqueue_waiters within 2s"

      _read = start_read(cs)
      assert :ok == Task.await(waiter, 2_000)

      # The read still waits for a chunk. Thus the readable side has space.
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
      #   1. Put a chunk in the readable queue (the high water mark is 0).
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
      reader = ReadableStream.get_reader(cs.readable)
      read = ReadableStreamDefaultReader.read(reader)

      await(WritableStreamDefaultWriter.write(writer, "hello"))

      # The first output of gzip is its header.
      assert %{done: false, value: %Uint8Array{}} = await(read)

      # Abort the stream — should close the zlib port safely. A read after
      # the abort gets the reason of the abort.
      await(WritableStreamDefaultWriter.abort(writer, :test_cancel))
      assert catch_exit(await(ReadableStreamDefaultReader.read(reader))) == :test_cancel
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

        assert Web.TestBytes.join(decompressed) == data,
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

      assert Web.TestBytes.join(decompressed) == data
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

    Web.TestBytes.join(decompressed)
  end

  # End-to-end compress + decompress of `data`, writing in `chunk_size`-byte pieces.
  defp round_trip_chunked(data, format, chunk_size) do
    cs = CompressionStream.new(format)
    ds = DecompressionStream.new(format)

    chunks = chunk_binary(data, chunk_size)
    source = ReadableStream.from(chunks)
    compressed = ReadableStream.pipe_through(source, cs)
    decompressed = ReadableStream.pipe_through(compressed, ds)

    Web.TestBytes.join(decompressed)
  end

  defp chunk_binary(binary, size), do: do_chunk(binary, size, [])
  defp do_chunk(<<>>, _size, acc), do: Enum.reverse(acc)

  defp do_chunk(binary, size, acc) do
    take = min(byte_size(binary), size)
    <<chunk::binary-size(^take), rest::binary>> = binary
    do_chunk(rest, size, [chunk | acc])
  end

  # Returns true if `data` looks like a valid header for the given format.
  # Used to filter out accidentally-valid generator output in the error PBT.
  # A zlib header is valid when its method is deflate (8), its window is at
  # most 32 KB, and its two bytes are a multiple of 31. Garbage with a valid
  # header can be the start of a valid deflate stream.
  defp valid_compressed_prefix?(data, "gzip"), do: match?(<<0x1F, 0x8B, _::binary>>, data)

  defp valid_compressed_prefix?(<<cinfo::4, cm::4, flg, _::binary>>, "deflate"),
    do: cm == 8 and cinfo <= 7 and rem((cinfo * 16 + cm) * 256 + flg, 31) == 0

  defp valid_compressed_prefix?(_data, "deflate"), do: false
  defp valid_compressed_prefix?(_data, "deflate-raw"), do: false

  # Reads the chunks until the end of the stream.
  defp read_all(reader) do
    case await(ReadableStreamDefaultReader.read(reader)) do
      %{done: true} -> []
      %{value: chunk} -> [chunk | read_all(reader)]
    end
  end

  # Waits until the transform waits for space on the readable side. Then
  # the stream does no more work before a read.
  defp wait_for_full_readable_side(pid) do
    assert wait_until(2_000, fn ->
             not :queue.is_empty(ReadableStream.__get_slots__(pid).enqueue_waiters)
           end)
  end

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

defmodule Web.CompressionRuntimeLogTest do
  # The tests examine the log with `capture_log`, which adds a handler to
  # the logger. Other tests add and remove logger handlers at the same time.
  # Then the logger of Erlang/OTP can lose the handler of the capture: it
  # handles a remove while an add is in progress, and then it puts back the
  # list of handlers from before the add. The capture then gets no log. Thus
  # these tests do not run at the same time as other tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Web, only: [await: 1]

  alias Web.AsyncContext
  alias Web.CompressionStream
  alias Web.Console
  alias Web.DecompressionStream
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultReader
  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter

  describe "Uint8Array and invalid chunk inputs" do
    test "runtime observation logs inherit async context metadata and console depth" do
      user = AsyncContext.Variable.new(name: "user")

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

    test "DecompressionStream logs runtime observation events with default user and no context suffix" do
      log =
        capture_log(fn ->
          :logger.update_process_metadata(%{web_runtime_observe: true})

          try do
            compressed = :zlib.gzip("hello world")
            source = ReadableStream.from([compressed])
            decompressed = ReadableStream.pipe_through(source, DecompressionStream.new("gzip"))
            assert Web.TestBytes.join(decompressed) == "hello world"
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

            # The transform of a chunk starts only when a read waits.
            _read =
              ds.readable |> ReadableStream.get_reader() |> ReadableStreamDefaultReader.read()

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
end
