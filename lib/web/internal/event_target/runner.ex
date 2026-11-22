defmodule Web.Internal.EventTarget.Runner do
  @moduledoc false

  # The listener process of a message port or a broadcast channel: it fires
  # the events of the port or the channel, one at a time, in the sequence of
  # their tasks. The listeners are in a store (see
  # `Web.Internal.EventTarget.Store`), and each event goes through the steps
  # "dispatch" of the DOM Standard (see `Web.Internal.EventTarget.Dispatch`).
  #
  # A value that a listener throws does not stop the process: the dispatch
  # writes it to the log and continues, as a browser reports an exception
  # of a listener and continues.
  #
  # ## The gate
  #
  # The option `:gate` is an `:atomics` array with one slot. When the slot
  # is not 0, the process drops each event that it did not start. The owner
  # of a target closes the gate to stop the events immediately, also when
  # the mailbox of this process has events.

  use GenServer

  require Logger

  alias Web.AsyncContext.Snapshot
  alias Web.Internal.EventTarget.Dispatch

  @typedoc """
  A task makes its event in this process, immediately before the dispatch.
  `build` is a module, a function, and its arguments. The function returns
  the event, or `nil` for no event. `target` gets the event, and `store`
  has its listeners. `reply_to` gets `{:event_done, tag}` after the
  dispatch, or `{:event_returned, tag}` when the gate was closed.
  """
  @type task :: %{
          required(:build) => {module(), atom(), list()},
          required(:snapshot) => Snapshot.t(),
          required(:target) => term(),
          required(:store) => pid(),
          optional(:reply_to) => {pid(), term()}
        }

  @spec start_link(:atomics.atomics_ref()) :: GenServer.on_start()
  def start_link(gate), do: GenServer.start_link(__MODULE__, gate)

  @doc "Adds a task to the events of the target. Does not wait."
  @spec run_task(pid(), task()) :: :ok
  def run_task(pid, %{build: {_module, _function, _args}} = task) when is_pid(pid) do
    GenServer.cast(pid, {:task, task})
  end

  @doc "Stops the process after the event that it does now. Does not wait."
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid), do: GenServer.cast(pid, :stop)

  @impl true
  def init(gate) do
    Process.flag(:message_queue_data, :off_heap)
    {:ok, gate}
  end

  @impl true
  def handle_cast({:task, task}, gate) do
    if :atomics.get(gate, 1) == 0 do
      Snapshot.run(task.snapshot, fn -> fire(task) end)
      reply(task, :event_done)
    else
      reply(task, :event_returned)
    end

    {:noreply, gate}
  end

  def handle_cast(:stop, gate), do: {:stop, :normal, gate}

  # A listener can send a message to this process. No code takes it.
  @impl true
  def handle_info(_message, gate), do: {:noreply, gate}

  # The steps "fire an event": the event is trusted. A task that gives no
  # event, or that fails, has no event.
  defp fire(%{build: {module, function, args}} = task) do
    case apply(module, function, args) do
      %{type: _type} = event -> Dispatch.dispatch(task.target, event, task.store, trusted: true)
      nil -> false
    end
  catch
    kind, reason ->
      Logger.error(
        "The task of an event failed.\n" <> Exception.format(kind, reason, __STACKTRACE__)
      )
  end

  defp reply(%{reply_to: {pid, tag}}, result), do: send(pid, {result, tag})
  defp reply(_task, _result), do: :ok
end
