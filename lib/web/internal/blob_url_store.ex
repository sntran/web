defmodule Web.Internal.BlobURLStore do
  @moduledoc false

  # The blob URL store of the File API: a map from each blob URL to its
  # blob URL entry. `Web.URL.create_object_url/1` adds an entry, and
  # `Web.URL.revoke_object_url/1` removes it.
  #
  # The store is one process of the application for the node, with a
  # table that each process can read: the steps "resolve a blob URL" read
  # the table, and only this process writes to it.
  #
  # The lifetime of an entry: the File API removes the entries of a global
  # when the global goes away. On the BEAM, the global of an entry is the
  # process that made it. The store monitors each such process, and
  # removes its entries when it stops. Thus a URL that a process forgets to
  # revoke does not stay.
  #
  # The design has no race of two writers: only the store writes, and it
  # does the requests one at a time. A process that stops while its add
  # waits in the mailbox: the store then monitors a process that stopped,
  # and the monitor gives the stop at once. A process with a monitor that
  # stops after an add: the stop comes after the add, because the signals
  # from one process come in their sequence. A fetch that read the table
  # before a revoke keeps the blob, as the File API permits.

  use GenServer

  @table __MODULE__

  @doc false
  def start_link(_init), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The steps "add an entry to the blob URL store": `url` gets `blob`, for
  the calling process.
  """
  @spec add(String.t(), Web.Blob.t() | Web.File.t()) :: :ok
  def add(url, blob), do: GenServer.call(__MODULE__, {:add, url, blob, self()})

  @doc """
  The steps "remove an entry from the blob URL store". A URL that is not
  in the store has no effect.
  """
  @spec remove(String.t()) :: :ok
  def remove(url), do: GenServer.call(__MODULE__, {:remove, url})

  @doc """
  The steps "resolve a blob URL": the object of the entry of `url`, or
  `nil`. `url` is the serialization of the URL with no fragment.
  """
  @spec resolve(String.t()) :: Web.Blob.t() | Web.File.t() | nil
  def resolve(url) do
    case :ets.lookup(@table, url) do
      [{^url, object, _owner}] -> object
      [] -> nil
    end
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:add, url, blob, owner}, _from, state) do
    true = :ets.insert(@table, {url, blob, owner})
    monitors = Map.put_new_lazy(state.monitors, owner, fn -> Process.monitor(owner) end)
    {:reply, :ok, %{state | monitors: monitors}}
  end

  def handle_call({:remove, url}, _from, state) do
    true = :ets.delete(@table, url)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, owner, _reason}, state) do
    true = :ets.match_delete(@table, {:_, :_, owner})
    {:noreply, %{state | monitors: Map.delete(state.monitors, owner)}}
  end
end
