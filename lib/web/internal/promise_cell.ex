defmodule Web.Internal.PromiseCell do
  @moduledoc false

  # The state of a promise in a process of this library that runs its own
  # loop, for example the process of a `fetch` request: see
  # `Web.Dispatcher.HTTP`. Thus the promise and the work are one process,
  # and the outcome goes to the processes that await it with no other
  # process between them.
  #
  # The functions speak the protocol of the cell of `Web.Promise`: an await
  # sends `{:subscribe, ref}`, and an inspect sends `{:peek, ref}`. They keep
  # the state in the process dictionary of the process, thus each receive of
  # the process can give its messages to `handle/1`.
  #
  # The rules are the rules of `Web.Promise`: a pending promise stops when
  # its owner stops, and a settled promise keeps its outcome for the linger
  # time after its first delivery. The process can continue after that time
  # for its other work.

  @key {__MODULE__, :cell}

  @doc "Starts the promise of the calling process. Returns its struct."
  @spec start(pid()) :: Web.Promise.t()
  def start(owner) do
    Process.put(@key, %{
      owner_monitor: Process.monitor(owner),
      token: make_ref(),
      status: :pending,
      waiters: [],
      expiry_started?: false,
      # The linger time ended, or the owner stopped, while the process did
      # its other work: see `linger/0`.
      done?: false
    })

    promise(self())
  end

  @doc "The promise of a process that runs `start/1`."
  @spec promise(pid()) :: Web.Promise.t()
  def promise(pid), do: %Web.Promise{pid: pid}

  @doc """
  Settles the promise, and gives the outcome to each process that awaits.
  A second outcome has no effect.
  """
  @spec settle(Web.Promise.outcome()) :: :ok
  def settle(outcome) do
    case Process.get(@key) do
      %{status: :pending, waiters: waiters} = cell ->
        for ref <- waiters, do: deliver(ref, outcome)
        Process.put(@key, start_expiry(%{cell | status: outcome, waiters: []}, waiters != []))
        :ok

      _settled ->
        :ok
    end
  end

  @doc """
  Handles a message of the promise. Returns `:handled`,
  `{:owner_down, reason}`, `:expired` at the end of the linger time, or
  `:unknown` for each other message.
  """
  @spec handle(term()) :: :handled | {:owner_down, term()} | :expired | :unknown
  def handle(message) do
    cell = Process.get(@key)

    case message do
      {:subscribe, ref} when is_reference(ref) ->
        subscribe(cell, ref)
        :handled

      {:peek, ref} when is_reference(ref) ->
        deliver(ref, public_status(cell.status))
        :handled

      {:DOWN, monitor, :process, _owner, reason} when monitor == cell.owner_monitor ->
        Process.put(@key, %{cell | owner_monitor: nil, done?: true})
        {:owner_down, reason}

      {:expire, token} when token == cell.token ->
        Process.put(@key, %{cell | done?: true})
        :expired

      _other ->
        :unknown
    end
  end

  @doc """
  Keeps the outcome for the processes that await it, until the end of the
  linger time or the end of the owner, and then the process stops.

  The process first lets the other processes run: a process that awaits
  the outcome gets it at once. Then it hibernates: the VM makes its memory
  as small as its data. Thus a process that had a large heap for its work
  does not keep that heap for the linger time.
  """
  @spec linger() :: no_return()
  def linger do
    if Process.get(@key).done?, do: exit(:normal)
    :erlang.yield()
    Process.flag(:min_heap_size, 233)
    wait()
  end

  @doc false
  def wait, do: :erlang.hibernate(__MODULE__, :wake, [])

  @doc false
  def wake do
    receive do
      message ->
        case handle(message) do
          :handled -> wait()
          :unknown -> wait()
          _expired_or_owner_down -> exit(:normal)
        end
    end
  end

  defp subscribe(%{status: :pending} = cell, ref) do
    Process.put(@key, %{cell | waiters: [ref | cell.waiters]})
  end

  defp subscribe(cell, ref) do
    deliver(ref, cell.status)
    Process.put(@key, start_expiry(cell, true))
  end

  defp deliver(ref, outcome), do: send(ref, {:web_promise, ref, outcome})

  defp public_status(:pending), do: :pending
  defp public_status(outcome), do: outcome

  defp start_expiry(%{expiry_started?: false} = cell, true) do
    case Web.Promise.default_linger() do
      :infinity ->
        cell

      linger ->
        Process.send_after(self(), {:expire, cell.token}, linger)
        %{cell | expiry_started?: true}
    end
  end

  defp start_expiry(cell, _delivered?), do: cell
end
