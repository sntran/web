defmodule Web.AsyncContextTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.AsyncContext
  alias Web.AsyncContext.{Snapshot, Variable}
  alias Web.{Promise, ReadableStream, TransformStream, WritableStream}
  alias Web.ReadableStreamDefaultController
  alias Web.ReadableStreamDefaultReader
  alias Web.WritableStreamDefaultWriter

  # ===========================================================================
  # Variable — basic API
  # ===========================================================================

  describe "Variable.new/2" do
    test "creates a named variable" do
      var = Variable.new("test_var")
      assert var.name == "test_var"
      assert is_tuple(var.key)
    end

    test "supports a default value" do
      var = Variable.new("with_default", default: :fallback)
      assert var.default == :fallback
    end

    test "default is nil when not specified" do
      var = Variable.new("no_default")
      assert var.default == nil
    end
  end

  describe "Variable.get/1" do
    test "returns default when unset" do
      var = Variable.new("unset_var", default: 42)
      assert Variable.get(var) == 42
    end

    test "returns nil when unset with no default" do
      var = Variable.new("nil_var")
      assert Variable.get(var) == nil
    end
  end

  describe "Variable.run/3" do
    test "sets value within scope" do
      var = Variable.new("scoped")
      result = Variable.run(var, :hello, fn -> Variable.get(var) end)
      assert result == :hello
    end

    test "restores previous value after scope" do
      var = Variable.new("restore_test")

      Variable.run(var, :outer, fn ->
        assert Variable.get(var) == :outer

        Variable.run(var, :inner, fn ->
          assert Variable.get(var) == :inner
        end)

        assert Variable.get(var) == :outer
      end)
    end

    test "restores original (unset) state after scope" do
      var = Variable.new("unset_restore", default: :default_val)

      Variable.run(var, :temp, fn ->
        assert Variable.get(var) == :temp
      end)

      assert Variable.get(var) == :default_val
    end

    test "restores value even on exception" do
      var = Variable.new("exception_test")

      Variable.run(var, :safe, fn ->
        assert_raise RuntimeError, fn ->
          Variable.run(var, :unsafe, fn ->
            raise "boom"
          end)
        end

        assert Variable.get(var) == :safe
      end)
    end
  end

  # ===========================================================================
  # Snapshot — take/run
  # ===========================================================================

  describe "Snapshot.take/0" do
    test "captures logger metadata" do
      :logger.update_process_metadata(%{request_id: "snap-test"})
      snap = Snapshot.take()
      assert snap.logger_metadata[:request_id] == "snap-test"
    after
      :logger.set_process_metadata(%{})
    end

    test "captures registered variables" do
      var = Variable.new("snap_var")

      Variable.run(var, "captured", fn ->
        snap = Snapshot.take()
        assert Map.has_key?(snap.variables, var.key)
        assert snap.variables[var.key] == "captured"
      end)
    end

    test "captures $callers" do
      Process.put(:"$callers", [self()])
      snap = Snapshot.take()
      assert snap.callers == [self()]
    after
      Process.delete(:"$callers")
    end

    test "captures ambient signal" do
      controller = Web.AbortController.new()

      AsyncContext.with_signal(controller.signal, fn ->
        snap = Snapshot.take()
        assert snap.ambient_signal == controller.signal
      end)

      Web.AbortController.abort(controller)
    end

    test "empty context produces clean snapshot" do
      snap = Snapshot.take()
      assert snap.variables == %{}
      assert snap.callers == []
    end
  end

  describe "Snapshot.run/2" do
    test "re-enters logger metadata inside a new process" do
      :logger.update_process_metadata(%{trace_id: "t-123"})
      snap = Snapshot.take()

      task =
        Task.async(fn ->
          Snapshot.run(snap, fn ->
            :logger.get_process_metadata()
          end)
        end)

      meta = Task.await(task)
      assert meta[:trace_id] == "t-123"
    after
      :logger.set_process_metadata(%{})
    end

    test "re-enters variables inside a new process" do
      var = Variable.new("cross_process")

      Variable.run(var, "propagated", fn ->
        snap = Snapshot.take()

        task =
          Task.async(fn ->
            Snapshot.run(snap, fn ->
              Variable.get(var)
            end)
          end)

        assert Task.await(task) == "propagated"
      end)
    end

    test "re-enters $callers inside a new process" do
      Process.put(:"$callers", [self()])
      snap = Snapshot.take()

      task =
        Task.async(fn ->
          Snapshot.run(snap, fn ->
            Process.get(:"$callers")
          end)
        end)

      assert Task.await(task) == [self()]
    after
      Process.delete(:"$callers")
    end

    test "allows nested snapshots after re-entry" do
      var1 = Variable.new("v1")
      var2 = Variable.new("v2")

      Variable.run(var1, "a", fn ->
        Variable.run(var2, "b", fn ->
          snap = Snapshot.take()

          task =
            Task.async(fn ->
              Snapshot.run(snap, fn ->
                inner_snap = Snapshot.take()
                {inner_snap.variables[var1.key], inner_snap.variables[var2.key]}
              end)
            end)

          assert Task.await(task) == {"a", "b"}
        end)
      end)
    end

    test "restores previous variable values after the run scope" do
      var = Variable.new("snapshot_scope")

      Variable.run(var, :outer, fn ->
        snap = Variable.run(var, :inner, fn -> Snapshot.take() end)

        Snapshot.run(snap, fn ->
          assert Variable.get(var) == :inner
        end)

        assert Variable.get(var) == :outer
      end)
    end

    test "restores previous logger metadata after the run scope" do
      :logger.update_process_metadata(%{scope: "inner"})
      snap = Snapshot.take()
      :logger.set_process_metadata(%{scope: "outer"})

      Snapshot.run(snap, fn ->
        assert :logger.get_process_metadata()[:scope] == "inner"
      end)

      assert :logger.get_process_metadata()[:scope] == "outer"
    after
      :logger.set_process_metadata(%{})
    end
  end

  describe "internal async-context helpers" do
    test "with_signal restores the previous ambient signal when nested" do
      outer = Web.AbortController.new()
      inner = Web.AbortController.new()

      AsyncContext.with_signal(outer.signal, fn ->
        AsyncContext.with_signal(inner.signal, fn ->
          assert Snapshot.take().ambient_signal == inner.signal
        end)

        assert Snapshot.take().ambient_signal == outer.signal
      end)

      assert Snapshot.take().ambient_signal == nil

      Web.AbortController.abort(outer)
      Web.AbortController.abort(inner)
    end

    test "restore merges snapshot values into the current process" do
      var = Variable.new("restore_internal")

      snap =
        Variable.run(var, :captured, fn ->
          :logger.update_process_metadata(%{restore_meta: true})
          Process.put(:"$callers", [self()])
          Snapshot.take()
        end)

      Snapshot.restore(snap)

      assert Variable.get(var) == :captured
      assert :logger.get_process_metadata()[:restore_meta] == true
      assert Process.get(:"$callers") == [self()]
    after
      :logger.set_process_metadata(%{})
      Process.delete(:"$callers")
    end
  end

  # ===========================================================================
  # Promise — context propagation
  # ===========================================================================

  describe "Promise context propagation" do
    test "logger metadata flows into Promise.new/1" do
      :logger.update_process_metadata(%{promise_trace: "p-1"})

      promise =
        Promise.new(fn resolve, _reject ->
          meta = :logger.get_process_metadata()
          resolve.(meta[:promise_trace])
        end)

      assert await(promise) == "p-1"
    after
      :logger.set_process_metadata(%{})
    end

    test "variables flow into Promise.new/1" do
      var = Variable.new("promise_var")

      Variable.run(var, "promise_value", fn ->
        promise =
          Promise.new(fn resolve, _reject ->
            resolve.(Variable.get(var))
          end)

        assert await(promise) == "promise_value"
      end)
    end

    test "$callers flow into Promise.new/1" do
      promise =
        Promise.new(fn resolve, _reject ->
          callers = Process.get(:"$callers", [])
          resolve.(callers)
        end)

      callers = await(promise)
      assert is_list(callers)
    end

    test "context propagates through chained Promise.new calls" do
      var = Variable.new("chain_var")

      result =
        Variable.run(var, "chain", fn ->
          :logger.update_process_metadata(%{chain_id: "c-1"})

          promise =
            Promise.new(fn resolve, _reject ->
              resolve.({Variable.get(var), :logger.get_process_metadata()[:chain_id]})
            end)

          await(promise)
        end)

      assert result == {"chain", "c-1"}
    after
      :logger.set_process_metadata(%{})
    end
  end

  # ===========================================================================
  # Stream — context propagation
  # ===========================================================================

  describe "Stream context propagation" do
    test "logger metadata flows into ReadableStream pull callback" do
      :logger.update_process_metadata(%{stream_trace: "s-1"})

      stream =
        ReadableStream.new(%{
          pull: fn ctrl ->
            meta = :logger.get_process_metadata()
            ReadableStreamDefaultController.enqueue(ctrl, meta[:stream_trace])
            ReadableStreamDefaultController.close(ctrl)
          end
        })

      reader = ReadableStream.get_reader(stream)
      %{value: chunk} = await(ReadableStreamDefaultReader.read(reader))
      assert chunk == "s-1"
      ReadableStreamDefaultReader.release_lock(reader)
    after
      :logger.set_process_metadata(%{})
    end

    test "variables flow into ReadableStream pull callback" do
      var = Variable.new("stream_var")

      Variable.run(var, "stream_value", fn ->
        stream =
          ReadableStream.new(%{
            pull: fn ctrl ->
              ReadableStreamDefaultController.enqueue(ctrl, Variable.get(var))
              ReadableStreamDefaultController.close(ctrl)
            end
          })

        reader = ReadableStream.get_reader(stream)
        %{value: chunk} = await(ReadableStreamDefaultReader.read(reader))
        assert chunk == "stream_value"
        ReadableStreamDefaultReader.release_lock(reader)
      end)
    end

    test "logger metadata flows into WritableStream write callback" do
      :logger.update_process_metadata(%{write_trace: "w-1"})
      test_pid = self()

      stream =
        WritableStream.new(%{
          write: fn chunk, _ctrl ->
            meta = :logger.get_process_metadata()
            send(test_pid, {:write_meta, chunk, meta[:write_trace]})
          end
        })

      writer = WritableStream.get_writer(stream)
      await(WritableStreamDefaultWriter.write(writer, "data"))
      await(WritableStreamDefaultWriter.close(writer))

      assert_receive {:write_meta, "data", "w-1"}, 5000
    after
      :logger.set_process_metadata(%{})
    end

    test "logger metadata flows into TransformStream transform callback" do
      :logger.update_process_metadata(%{transform_trace: "t-1"})

      transform =
        TransformStream.new(%{
          transform: fn chunk, ctrl ->
            meta = :logger.get_process_metadata()
            ReadableStreamDefaultController.enqueue(ctrl, {chunk, meta[:transform_trace]})
          end
        })

      # Write to the writable side
      writer = WritableStream.get_writer(transform.writable)
      await(WritableStreamDefaultWriter.write(writer, "input"))
      await(WritableStreamDefaultWriter.close(writer))

      # Read from the readable side
      reader = ReadableStream.get_reader(transform.readable)
      %{value: chunk} = await(ReadableStreamDefaultReader.read(reader))
      assert chunk == {"input", "t-1"}
      ReadableStreamDefaultReader.release_lock(reader)
    after
      :logger.set_process_metadata(%{})
    end

    test "variables flow into TransformStream flush callback" do
      var = Variable.new("flush_var")
      test_pid = self()

      Variable.run(var, "flush_val", fn ->
        transform =
          TransformStream.new(%{
            transform: fn chunk, ctrl ->
              ReadableStreamDefaultController.enqueue(ctrl, chunk)
            end,
            flush: fn ctrl ->
              send(test_pid, {:flush_ctx, Variable.get(var)})
              ReadableStreamDefaultController.close(ctrl)
            end
          })

        writer = WritableStream.get_writer(transform.writable)
        await(WritableStreamDefaultWriter.write(writer, "x"))
        await(WritableStreamDefaultWriter.close(writer))

        reader = ReadableStream.get_reader(transform.readable)
        assert %{value: "x"} = await(ReadableStreamDefaultReader.read(reader))
        assert %{done: true} = await(ReadableStreamDefaultReader.read(reader))
        ReadableStreamDefaultReader.release_lock(reader)

        assert_receive {:flush_ctx, "flush_val"}, 5000
      end)
    end
  end

  # ===========================================================================
  # Ambient signal — auto-cancellation
  # ===========================================================================

  describe "ambient signal auto-cancellation" do
    test "stream auto-cancels when ambient signal fires" do
      controller = Web.AbortController.new()

      stream =
        AsyncContext.with_signal(controller.signal, fn ->
          ReadableStream.new(%{
            pull: fn ctrl ->
              ReadableStreamDefaultController.enqueue(ctrl, "chunk")
            end
          })
        end)

      reader = ReadableStream.get_reader(stream)
      _ = await(ReadableStreamDefaultReader.read(reader))

      # Now abort
      Web.AbortController.abort(controller, :cancelled)
      Process.sleep(100)

      # Stream should be cancelled — subsequent reads return done or reject
      result =
        try do
          await(ReadableStreamDefaultReader.read(reader))
        catch
          :exit, _ -> :errored
        end

      assert match?(%{done: true}, result) or result == :errored

      try do
        ReadableStreamDefaultReader.release_lock(reader)
      rescue
        _ -> :ok
      end
    end

    test "stream auto-cancels when created with already-aborted signal" do
      signal = Web.AbortSignal.abort(:already_gone)

      stream =
        AsyncContext.with_signal(signal, fn ->
          ReadableStream.new(%{
            pull: fn ctrl ->
              ReadableStreamDefaultController.enqueue(ctrl, "should_not_get")
            end
          })
        end)

      reader = ReadableStream.get_reader(stream)
      Process.sleep(100)

      result =
        try do
          await(ReadableStreamDefaultReader.read(reader))
        catch
          :exit, _ -> :errored
        end

      assert match?(%{done: true}, result) or result == :errored

      try do
        ReadableStreamDefaultReader.release_lock(reader)
      rescue
        _ -> :ok
      end
    end

    test "no auto-cancel without ambient signal" do
      stream =
        ReadableStream.new(%{
          pull: fn ctrl ->
            ReadableStreamDefaultController.enqueue(ctrl, "ok")
          end
        })

      reader = ReadableStream.get_reader(stream)
      %{value: chunk} = await(ReadableStreamDefaultReader.read(reader))
      assert chunk == "ok"
      ReadableStreamDefaultReader.release_lock(reader)
    end
  end

  # ===========================================================================
  # Property-based tests — context integrity across deep chains
  # ===========================================================================

  describe "property: context integrity across deep Promise.then chains" do
    property "unique context value is preserved through nested then chains" do
      check all(
              depth <- integer(1..10),
              ctx_value <- string(:alphanumeric, min_length: 1, max_length: 32)
            ) do
        var = Variable.new("prop_var")

        result =
          Variable.run(var, ctx_value, fn ->
            initial = Promise.resolve(0)

            final =
              Enum.reduce(1..depth, initial, fn _i, acc ->
                Promise.then(acc, fn val ->
                  assert Variable.get(var) == ctx_value
                  val + 1
                end)
              end)

            await(final)
          end)

        assert result == depth
      end
    end

    property "logger metadata is preserved through Promise chains" do
      check all(
              depth <- integer(1..8),
              trace_id <- string(:alphanumeric, min_length: 4, max_length: 16)
            ) do
        :logger.update_process_metadata(%{prop_trace: trace_id})

        final_promise =
          Enum.reduce(1..depth, Promise.resolve(nil), fn _i, acc ->
            Promise.then(acc, fn _ ->
              :logger.get_process_metadata()[:prop_trace]
            end)
          end)

        result = await(final_promise)
        assert result == trace_id
        :logger.set_process_metadata(%{})
      end
    end

    property "context survives Promise.new spawning" do
      check all(ctx_value <- string(:alphanumeric, min_length: 1, max_length: 32)) do
        var = Variable.new("spawn_prop")

        result =
          Variable.run(var, ctx_value, fn ->
            promise =
              Promise.new(fn resolve, _reject ->
                resolve.(Variable.get(var))
              end)

            await(promise)
          end)

        assert result == ctx_value
      end
    end
  end

  # ===========================================================================
  # Property-based tests — TransformStream deep pipelines
  # ===========================================================================

  describe "property: context integrity through TransformStream" do
    property "variable flows through transform callbacks" do
      check all(
              value <- string(:alphanumeric, min_length: 1, max_length: 16),
              chunks <-
                list_of(string(:alphanumeric, min_length: 1), min_length: 1, max_length: 5)
            ) do
        var = Variable.new("transform_prop")

        Variable.run(var, value, fn ->
          transform =
            TransformStream.new(%{
              transform: fn chunk, ctrl ->
                ctx = Variable.get(var)
                ReadableStreamDefaultController.enqueue(ctrl, {chunk, ctx})
              end
            })

          writer = WritableStream.get_writer(transform.writable)

          for chunk <- chunks do
            await(WritableStreamDefaultWriter.write(writer, chunk))
          end

          await(WritableStreamDefaultWriter.close(writer))

          reader = ReadableStream.get_reader(transform.readable)

          results =
            Enum.map(chunks, fn _chunk ->
              %{value: val} = await(ReadableStreamDefaultReader.read(reader))
              val
            end)

          %{done: true} = await(ReadableStreamDefaultReader.read(reader))
          ReadableStreamDefaultReader.release_lock(reader)

          for {result, chunk} <- Enum.zip(results, chunks) do
            assert result == {chunk, value}
          end
        end)
      end
    end
  end

  # ===========================================================================
  # Concurrency stress test — isolation verification
  # ===========================================================================

  describe "concurrency: context isolation under load" do
    @tag timeout: 60_000
    test "1000 concurrent streams do not cross-pollinate context" do
      tasks =
        for i <- 1..1000 do
          Task.async(fn ->
            var = Variable.new("isolation_#{i}")
            unique_value = "ctx-#{i}-#{:rand.uniform(1_000_000)}"

            Variable.run(var, unique_value, fn ->
              :logger.update_process_metadata(%{isolation_id: unique_value})

              promise =
                Promise.new(fn resolve, _reject ->
                  ctx = Variable.get(var)
                  meta = :logger.get_process_metadata()
                  resolve.({ctx, meta[:isolation_id]})
                end)

              {ctx, meta_id} = await(promise)

              assert ctx == unique_value,
                     "Variable leaked: expected #{unique_value}, got #{ctx}"

              assert meta_id == unique_value,
                     "Logger metadata leaked: expected #{unique_value}, got #{meta_id}"

              :ok
            end)
          end)
        end

      results = Task.await_many(tasks, 30_000)
      assert Enum.all?(results, &(&1 == :ok))
    end

    @tag timeout: 60_000
    test "1000 concurrent ReadableStreams with unique context" do
      tasks =
        for i <- 1..1000 do
          Task.async(fn ->
            var = Variable.new("stream_iso_#{i}")
            unique_value = "stream-#{i}-#{:rand.uniform(1_000_000)}"

            Variable.run(var, unique_value, fn ->
              stream =
                ReadableStream.new(%{
                  pull: fn ctrl ->
                    ReadableStreamDefaultController.enqueue(ctrl, Variable.get(var))
                    ReadableStreamDefaultController.close(ctrl)
                  end
                })

              reader = ReadableStream.get_reader(stream)
              %{value: chunk} = await(ReadableStreamDefaultReader.read(reader))
              ReadableStreamDefaultReader.release_lock(reader)

              assert chunk == unique_value,
                     "Stream context leaked: expected #{unique_value}, got #{chunk}"

              :ok
            end)
          end)
        end

      results = Task.await_many(tasks, 30_000)
      assert Enum.all?(results, &(&1 == :ok))
    end
  end

  # ===========================================================================
  # Edge cases
  # ===========================================================================

  describe "edge cases" do
    test "Variable.run with nil value" do
      var = Variable.new("nil_val", default: :not_nil)
      result = Variable.run(var, nil, fn -> Variable.get(var) end)
      assert result == nil
    end

    test "multiple variables captured in same snapshot" do
      v1 = Variable.new("multi_1")
      v2 = Variable.new("multi_2")
      v3 = Variable.new("multi_3")

      Variable.run(v1, "a", fn ->
        Variable.run(v2, "b", fn ->
          Variable.run(v3, "c", fn ->
            snap = Snapshot.take()

            task =
              Task.async(fn ->
                Snapshot.run(snap, fn ->
                  {Variable.get(v1), Variable.get(v2), Variable.get(v3)}
                end)
              end)

            assert Task.await(task) == {"a", "b", "c"}
          end)
        end)
      end)
    end

    test "snapshot does not capture unset variables" do
      var = Variable.new("unset_snap")
      snap = Snapshot.take()
      refute Map.has_key?(snap.variables, var.key)
      _ = var
    end

    test "ambient signal nil by default in snapshot" do
      snap = Snapshot.take()
      assert snap.ambient_signal == nil
    end
  end

  # ===========================================================================
  # Shape verification — every read yields %{value, done} (WHATWG §3.5)
  # ===========================================================================

  describe "property: ReadableStreamReadResult shape" do
    property "ReadableStream read always yields %{value, done} map" do
      check all(chunks <- list_of(term(), min_length: 1, max_length: 10)) do
        stream =
          ReadableStream.new(%{
            start: fn ctrl ->
              Enum.each(chunks, &Web.ReadableStreamDefaultController.enqueue(ctrl, &1))
              Web.ReadableStreamDefaultController.close(ctrl)
            end
          })

        reader = ReadableStream.get_reader(stream)

        for chunk <- chunks do
          result = await(ReadableStreamDefaultReader.read(reader))
          assert %{value: ^chunk, done: false} = result
          assert is_map_key(result, :value)
          assert is_map_key(result, :done)
        end

        done_result = await(ReadableStreamDefaultReader.read(reader))
        assert %{value: nil, done: true} = done_result
        ReadableStreamDefaultReader.release_lock(reader)
      end
    end

    property "TransformStream read yields %{value, done} map" do
      check all(
              chunks <-
                list_of(string(:alphanumeric, min_length: 1), min_length: 1, max_length: 5)
            ) do
        ts = TransformStream.new(%{})
        writer = WritableStream.get_writer(ts.writable)

        for chunk <- chunks do
          await(Web.WritableStreamDefaultWriter.write(writer, chunk))
        end

        await(Web.WritableStreamDefaultWriter.close(writer))

        reader = ReadableStream.get_reader(ts.readable)

        for chunk <- chunks do
          result = await(ReadableStreamDefaultReader.read(reader))
          assert %{value: ^chunk, done: false} = result
        end

        assert %{value: nil, done: true} = await(ReadableStreamDefaultReader.read(reader))
        ReadableStreamDefaultReader.release_lock(reader)
      end
    end
  end

  # ===========================================================================
  # Backpressure: :readable_strategy integration
  # ===========================================================================

  describe "TransformStream :readable_strategy" do
    test "readable_strategy controls readable-side high water mark" do
      strategy = Web.CountQueuingStrategy.new(4)
      ts = TransformStream.new(%{}, readable_strategy: strategy, high_water_mark: 1)

      pid = ts.readable.controller_pid
      writer = WritableStream.get_writer(ts.writable)

      # Write 4 chunks — should all fit within the readable queue
      for i <- 1..4 do
        assert :ok = await(Web.WritableStreamDefaultWriter.write(writer, "chunk-#{i}"))
      end

      # Readable queue should be at capacity (4 items)
      slots = ReadableStream.__get_slots__(pid)
      assert :queue.len(slots.queue) == 4

      # Reading should free capacity and allow more writes
      reader = ReadableStream.get_reader(ts.readable)
      %{value: "chunk-1"} = await(ReadableStreamDefaultReader.read(reader))
      %{value: "chunk-2"} = await(ReadableStreamDefaultReader.read(reader))
      %{value: "chunk-3"} = await(ReadableStreamDefaultReader.read(reader))
      %{value: "chunk-4"} = await(ReadableStreamDefaultReader.read(reader))

      ReadableStreamDefaultReader.release_lock(reader)
      await(Web.WritableStreamDefaultWriter.close(writer))
    end

    test "upstream pull rate is throttled by readable_strategy high water mark" do
      pull_count = :counters.new(1, [])

      strategy = Web.CountQueuingStrategy.new(2)

      ts =
        TransformStream.new(
          %{
            transform: fn chunk, ctrl ->
              :counters.add(pull_count, 1, 1)
              Web.ReadableStreamDefaultController.enqueue(ctrl, chunk)
            end
          },
          readable_strategy: strategy,
          high_water_mark: 1
        )

      writer = WritableStream.get_writer(ts.writable)

      # Write 2 chunks — fills readable queue to HWM
      await(Web.WritableStreamDefaultWriter.write(writer, "a"))
      await(Web.WritableStreamDefaultWriter.write(writer, "b"))

      # Writer.ready should now block because readable side is at capacity
      ready_task = Task.async(fn -> await(Web.WritableStreamDefaultWriter.ready(writer)) end)
      assert Task.yield(ready_task, 100) == nil

      # Consume from readable side to free capacity
      reader = ReadableStream.get_reader(ts.readable)
      %{value: "a"} = await(ReadableStreamDefaultReader.read(reader))

      # Now ready should complete
      assert {:ok, :ok} = Task.yield(ready_task, 2_000)

      # Write a 3rd chunk now that there's capacity
      await(Web.WritableStreamDefaultWriter.write(writer, "c"))

      %{value: "b"} = await(ReadableStreamDefaultReader.read(reader))
      %{value: "c"} = await(ReadableStreamDefaultReader.read(reader))

      ReadableStreamDefaultReader.release_lock(reader)
      await(Web.WritableStreamDefaultWriter.close(writer))

      # All 3 transforms should have been invoked
      assert :counters.get(pull_count, 1) == 3
    end
  end
end
