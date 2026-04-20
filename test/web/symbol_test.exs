defmodule Web.SymbolTest do
  use ExUnit.Case, async: false
  use Web

  alias Web.BroadcastChannel
  alias Web.DOMException

  test "well-known symbols expose their TC39 names" do
    assert Symbol.dispose() == :dispose
    assert Symbol.async_dispose() == :async_dispose
    assert Symbol.iterator() == :iterator
  end

  test "symbol protocol disposes broadcast channels directly" do
    channel = BroadcastChannel.new(unique_name("symbol-dispose"))

    assert :ok = Web.Symbol.Protocol.symbol(channel, :dispose, [])
    assert_data_clone_error(channel)
  end

  test "symbol protocol closes ports and falls back to unsupported for unknown resources" do
    port = Port.open({:spawn, "cat"}, [:binary])
    assert Port.info(port)

    assert :ok = Web.Symbol.Protocol.symbol(port, :dispose, [])
    Process.sleep(20)
    refute Port.info(port)

    owner = self()

    borrowed_port =
      spawn(fn ->
        port = Port.open({:spawn, "cat"}, [:binary])
        send(owner, {:borrowed_port, port})

        receive do
          :stop -> :ok
        end
      end)

    port =
      receive do
        {:borrowed_port, port} -> port
      after
        1_000 -> flunk("expected borrowed port")
      end

    assert :ok = Web.Symbol.Protocol.symbol(port, :dispose, [])
    send(borrowed_port, :stop)

    assert :unsupported = Web.Symbol.Protocol.symbol(port, :iterator, [])
    assert :ok = Web.Symbol.Protocol.symbol(port, :async_dispose, [])

    assert :unsupported = Web.Symbol.Protocol.symbol(:not_disposable, :dispose, [])
  end

  test "broadcast channel symbol helpers support async_dispose and iterator fallback" do
    channel = BroadcastChannel.new(unique_name("symbol-async-dispose"))

    assert :ok = Web.Symbol.Protocol.symbol(channel, :async_dispose, [])
    assert_data_clone_error(channel)
    assert :unsupported = Web.Symbol.Protocol.symbol(channel, :iterator, [])
  end

  test "using with <- binding disposes channels on success" do
    channel =
      using resource <- BroadcastChannel.new(unique_name("using-left-arrow")) do
        assert %BroadcastChannel{} = resource
        resource
      end

    assert_data_clone_error(channel)
  end

  test "using with = binding disposes channels when the block raises" do
    channel = BroadcastChannel.new(unique_name("using-equals"))

    assert_raise RuntimeError, fn ->
      using resource = channel do
        assert resource == channel
        raise "boom"
      end
    end

    assert_data_clone_error(channel)
  end

  test "using without an explicit binding still evaluates the block" do
    assert :ok =
             Web.using(BroadcastChannel.new(unique_name("using-implicit")), do: :ok)
  end

  defp assert_data_clone_error(channel) do
    exception =
      assert_raise DOMException, fn ->
        BroadcastChannel.post_message(channel, "boom")
      end

    assert exception.name == "DataCloneError"
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
