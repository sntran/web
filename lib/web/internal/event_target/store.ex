defmodule Web.Internal.EventTarget.Store do
  @moduledoc false

  # The process of a `Web.EventTarget` that `Web.EventTarget.new/0` makes.
  # It keeps the event listener list (see `Web.Internal.EventTarget.Listeners`)
  # and answers each request at once: it never runs the code of a user. The
  # process that dispatches an event runs the listeners: see
  # `Web.Internal.EventTarget.Dispatch`.
  #
  # The lifetime: the process monitors its owner, the process that made the
  # target, and the owners of the listeners. When the owner stopped and no
  # listener is left, the target has no use. The process then waits for the
  # linger time, because a different process can have the target from a
  # message, and it stops when no request came in that time.
  #
  # The specification is `tla/EventTarget.tla`.

  use GenServer

  alias Web.Internal.EventTarget.Listeners

  @handoff_linger 5_000

  @spec start(pid()) :: pid()
  def start(owner) do
    {:ok, pid} = GenServer.start(__MODULE__, owner)
    pid
  end

  @doc """
  Does a request of `Web.Internal.EventTarget.Listeners.handle/3`. Returns
  `default` when the process stopped.
  """
  @spec request(pid(), term(), term()) :: term()
  def request(pid, request, default) do
    GenServer.call(pid, {:listeners, request}, :infinity)
  catch
    :exit, _reason -> default
  end

  @doc false
  # The abort steps of a listener with a signal: "remove an event listener".
  @spec remove_listener(pid(), non_neg_integer()) :: :ok
  def remove_listener(pid, id) do
    _ok = request(pid, {:remove_id, id}, :ok)
    :ok
  end

  @impl true
  def init(owner) do
    {:ok,
     %{
       listeners: Listeners.new(),
       monitors: %{},
       owner_ref: Process.monitor(owner),
       owner_down?: false
     }}
  end

  @impl true
  def handle_call({:listeners, request}, {client, _tag}, state) do
    {reply, listeners} = Listeners.handle(state.listeners, request, client)
    state = %{state | listeners: listeners}
    state = %{state | monitors: Listeners.monitor_owners(listeners, state.monitors)}
    reply(reply, state)
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _owner, _reason}, %{owner_ref: ref} = state) do
    noreply(%{state | owner_down?: true})
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    listeners = Listeners.remove_owner(state.listeners, pid)
    noreply(%{state | listeners: listeners, monitors: Map.delete(state.monitors, pid)})
  end

  # The linger time is complete, and no request came in that time.
  def handle_info(:timeout, state) do
    if unused?(state), do: {:stop, :normal, state}, else: {:noreply, state}
  end

  defp reply(reply, state) do
    if unused?(state),
      do: {:reply, reply, state, linger()},
      else: {:reply, reply, state}
  end

  defp noreply(state) do
    if unused?(state), do: {:noreply, state, linger()}, else: {:noreply, state}
  end

  defp unused?(state), do: state.owner_down? and Listeners.empty?(state.listeners)

  defp linger do
    case Web.Promise.default_linger() do
      linger when is_integer(linger) -> linger
      _infinity -> @handoff_linger
    end
  end
end
