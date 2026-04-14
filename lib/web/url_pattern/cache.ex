defmodule Web.URLPattern.Cache do
  @moduledoc false

  # Bounded LRU cache for compiled URLPattern instances backed by ETS.
  #
  # Capacity defaults to 512 entries.  When the cap is reached, the
  # least-recently-used entry is evicted.  Access order is tracked via a
  # monotonic counter stored in the ETS table alongside each entry.
  #
  # The cache stores: {key, compiled_pattern, access_counter}
  # A secondary ETS table maps {access_counter} → key for O(1) LRU lookup.
  #
  # This GenServer serialises writes while reads bypass the process (ETS
  # concurrent reads).

  use GenServer

  @table :web_url_pattern_cache
  @order_table :web_url_pattern_cache_order
  @default_capacity 512

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Fetch a compiled pattern from cache. Returns `{:ok, pattern}` or `:miss`."
  @spec get(term()) :: {:ok, term()} | :miss
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, _seq}] ->
        # Update access order asynchronously (cast to avoid blocking the caller)
        GenServer.cast(__MODULE__, {:touch, key})
        {:ok, value}

      [] ->
        :miss
    end
  end

  @doc "Insert a compiled pattern. Evicts LRU entry if at capacity."
  @spec put(term(), term()) :: :ok
  def put(key, value) do
    GenServer.call(__MODULE__, {:put, key, value})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)

    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@order_table, [:named_table, :public, :ordered_set])

    {:ok, %{capacity: capacity, seq: 0}}
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    seq = state.seq + 1

    case :ets.lookup(@table, key) do
      [{^key, _old_value, old_seq}] ->
        # Update value and access order
        :ets.delete(@order_table, old_seq)
        :ets.insert(@table, {key, value, seq})
        :ets.insert(@order_table, {seq, key})

      [] ->
        # New entry — evict LRU if necessary
        current_size = :ets.info(@table, :size)

        if current_size >= state.capacity do
          evict_lru()
        end

        :ets.insert(@table, {key, value, seq})
        :ets.insert(@order_table, {seq, key})
    end

    {:reply, :ok, %{state | seq: seq}}
  end

  @impl true
  def handle_cast({:touch, key}, state) do
    seq = state.seq + 1

    case :ets.lookup(@table, key) do
      [{^key, value, old_seq}] ->
        :ets.delete(@order_table, old_seq)
        :ets.insert(@table, {key, value, seq})
        :ets.insert(@order_table, {seq, key})

      [] ->
        :ok
    end

    {:noreply, %{state | seq: seq}}
  end

  defp evict_lru do
    case :ets.first(@order_table) do
      :"$end_of_table" ->
        :ok

      oldest_seq ->
        [{^oldest_seq, key}] = :ets.lookup(@order_table, oldest_seq)
        :ets.delete(@table, key)
        :ets.delete(@order_table, oldest_seq)
    end
  end
end
