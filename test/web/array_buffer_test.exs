defmodule Web.ArrayBufferTest do
  use ExUnit.Case, async: false

  alias Web.ArrayBuffer

  test "new/1 supports byte lengths and exposes a stable identity" do
    buffer = ArrayBuffer.new(4)

    assert ArrayBuffer.data(buffer) == <<0, 0, 0, 0>>
    assert ArrayBuffer.byte_length(buffer) == 4
    assert is_reference(ArrayBuffer.identity(buffer))
  end

  test "detaching managed buffers raises on data access" do
    buffer = ArrayBuffer.new("hello")
    detached = ArrayBuffer.detach(buffer)

    assert detached.byte_length == 0
    assert detached.data == <<>>
    assert ArrayBuffer.byte_length(buffer) == 0
    assert ArrayBuffer.detached?(buffer)

    assert_raise Web.TypeError, "Cannot access a detached ArrayBuffer", fn ->
      ArrayBuffer.data(buffer)
    end
  end

  test "manual fallback buffers keep working without table state" do
    buffer = ArrayBuffer.new("hello")
    table = :ets.whereis(Web.ArrayBuffer)
    true = :ets.delete(table, ArrayBuffer.identity(buffer))

    assert ArrayBuffer.data(buffer) == "hello"
    assert ArrayBuffer.byte_length(buffer) == 5
    refute ArrayBuffer.detached?(buffer)

    legacy = %ArrayBuffer{id: nil, data: "legacy", byte_length: 6}
    detached_legacy = ArrayBuffer.detach(legacy)

    assert ArrayBuffer.identity(legacy) == nil
    assert ArrayBuffer.data(legacy) == "legacy"
    assert ArrayBuffer.byte_length(legacy) == 6
    refute ArrayBuffer.detached?(legacy)
    assert detached_legacy.data == <<>>
    assert detached_legacy.byte_length == 0
  end

  test "write_at/3 writes into managed buffers at the requested offset" do
    buffer = ArrayBuffer.new(5)

    assert :ok = ArrayBuffer.write_at(buffer, 1, "hey")
    assert ArrayBuffer.data(buffer) == <<0, ?h, ?e, ?y, 0>>
    assert ArrayBuffer.byte_length(buffer) == 5
  end

  test "write_at/3 can replace and extend existing managed buffer contents" do
    buffer = ArrayBuffer.new("abc")

    assert :ok = ArrayBuffer.write_at(buffer, 2, "def")
    assert ArrayBuffer.data(buffer) == "abdef"
    assert ArrayBuffer.byte_length(buffer) == 5
  end

  test "write_at/3 rejects offsets beyond the current managed buffer length" do
    buffer = ArrayBuffer.new("abc")

    assert_raise ArgumentError, "invalid byte offset", fn ->
      ArrayBuffer.write_at(buffer, 4, "z")
    end
  end

  test "write_at/3 rejects detached managed buffers" do
    buffer = ArrayBuffer.new("hello")
    _detached = ArrayBuffer.detach(buffer)

    assert_raise Web.TypeError, "Cannot write to a detached ArrayBuffer", fn ->
      ArrayBuffer.write_at(buffer, 0, "x")
    end
  end

  test "write_at/3 rejects missing managed buffers" do
    buffer = ArrayBuffer.new("hello")
    true = :ets.delete(:ets.whereis(Web.ArrayBuffer), ArrayBuffer.identity(buffer))

    assert_raise Web.TypeError, "ArrayBuffer not found", fn ->
      ArrayBuffer.write_at(buffer, 0, "x")
    end
  end

  test "new/1 tolerates concurrent ETS table creation races" do
    parent = self()

    for _round <- 1..8 do
      reset_owner()

      tasks =
        for _ <- 1..64 do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> :ok
            end

            buffer = ArrayBuffer.new("x")
            {ArrayBuffer.data(buffer), ArrayBuffer.byte_length(buffer)}
          end)
        end

      Enum.each(1..64, fn _ ->
        assert_receive {:ready, _pid}
      end)

      Enum.each(tasks, fn task ->
        send(task.pid, :go)
      end)

      assert Enum.map(tasks, &Task.await(&1, 5_000)) == List.duplicate({"x", 1}, 64)
    end
  end

  defp reset_owner do
    case Process.whereis(Web.ArrayBuffer.TableOwner) do
      nil ->
        :ok

      pid ->
        Process.exit(pid, :kill)
        assert_eventually(fn -> Process.whereis(Web.ArrayBuffer.TableOwner) == nil end)
    end
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(1)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met in time")
end
