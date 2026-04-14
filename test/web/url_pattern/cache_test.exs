defmodule Web.URLPattern.CacheTest do
  use ExUnit.Case, async: false

  alias Web.URLPattern.Cache

  @table :web_url_pattern_cache
  @order_table :web_url_pattern_cache_order

  setup do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    if :ets.whereis(@order_table) != :undefined do
      :ets.delete_all_objects(@order_table)
    end

    :ok
  end

  test "returns miss for unknown keys" do
    assert :miss == Cache.get(:missing)
  end

  test "updates existing keys and evicts the oldest key when capacity is exceeded" do
    {:reply, :ok, state} = Cache.handle_call({:put, :a, 1}, self(), %{capacity: 2, seq: 0})
    {:reply, :ok, state} = Cache.handle_call({:put, :a, 2}, self(), state)

    assert [{:a, 2, _seq}] = :ets.lookup(@table, :a)

    {:reply, :ok, state} = Cache.handle_call({:put, :b, 3}, self(), state)
    {:reply, :ok, _state} = Cache.handle_call({:put, :c, 4}, self(), state)

    assert [] = :ets.lookup(@table, :a)
    assert [{:b, 3, _seq}] = :ets.lookup(@table, :b)
    assert [{:c, 4, _seq}] = :ets.lookup(@table, :c)
  end

  test "touch updates existing keys and ignores missing keys" do
    :ets.insert(@table, {:a, 1, 1})
    :ets.insert(@order_table, {1, :a})

    assert {:noreply, %{seq: 2}} = Cache.handle_cast({:touch, :a}, %{capacity: 2, seq: 1})
    assert [{:a, 1, 2}] = :ets.lookup(@table, :a)

    assert {:noreply, %{seq: 3}} = Cache.handle_cast({:touch, :missing}, %{capacity: 2, seq: 2})
  end

  test "eviction tolerates empty order tables" do
    assert {:reply, :ok, %{seq: 1}} =
             Cache.handle_call({:put, :a, 1}, self(), %{capacity: 0, seq: 0})
  end
end
