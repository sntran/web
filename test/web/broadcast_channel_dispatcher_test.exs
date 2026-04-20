defmodule Web.BroadcastChannelDispatcherTest do
  use ExUnit.Case, async: false

  alias Web.AsyncContext.Snapshot
  alias Web.BroadcastChannel.Dispatcher
  alias Web.Internal.Envelope
  alias Web.Internal.StructuredData

  test "register preserves creation indexes and unregister tolerates non-server pids" do
    name = unique_name("register")
    dispatcher = Dispatcher.ensure_started(name)

    assert %{dispatcher: ^dispatcher, creation_index: 0} =
             Dispatcher.register(name, self(), make_ref())

    assert %{dispatcher: ^dispatcher, creation_index: 0} =
             Dispatcher.register(name, self(), make_ref())

    crashing_pid =
      spawn(fn ->
        receive do
          _message -> exit(:boom)
        end
      end)

    assert :ok = Dispatcher.unregister(crashing_pid, self())
    assert :ok = Dispatcher.unregister(dispatcher, self())
  end

  test "dispatcher skips stale queued recipients and stops once idle" do
    name = unique_name("stale")
    dispatcher = Dispatcher.ensure_started(name)

    recipient =
      spawn(fn ->
        receive do
          _message -> :ok
        end
      end)

    unknown_pid = spawn(fn -> :ok end)

    await_process_exit(unknown_pid)

    assert %{dispatcher: ^dispatcher} = Dispatcher.register(name, recipient, make_ref())
    assert :ok = Dispatcher.unregister(dispatcher, unknown_pid)

    message = %{
      origin: "node://dispatcher",
      serialized: StructuredData.serialize("stale"),
      snapshot: Snapshot.take()
    }

    :sys.replace_state(dispatcher, fn state ->
      queue =
        :queue.in(
          %{recipients: [%{pid: recipient, token: make_ref()}], message: message},
          state.queue
        )

      %{state | queue: queue}
    end)

    dispatcher_ref = Process.monitor(dispatcher)

    assert :ok = Dispatcher.unregister(dispatcher, recipient)
    assert_receive {:DOWN, ^dispatcher_ref, :process, ^dispatcher, :normal}
  end

  test "dispatcher advances after the current recipient exits and ignores stray info" do
    parent = self()
    name = unique_name("advance")
    dispatcher = Dispatcher.ensure_started(name)

    crashing_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", %Envelope{}} -> exit(:boom)
        end
      end)

    survivor_pid = spawn(fn -> survivor_loop(parent) end)

    assert %{dispatcher: ^dispatcher, creation_index: 0} =
             Dispatcher.register(name, crashing_pid, make_ref())

    assert %{dispatcher: ^dispatcher, creation_index: 1} =
             Dispatcher.register(name, survivor_pid, make_ref())

    send(dispatcher, {:DOWN, make_ref(), :process, crashing_pid, :ignored})
    send(dispatcher, :unexpected_info)

    assert :ok =
             Dispatcher.post(dispatcher, self(), %{
               origin: "node://dispatcher",
               serialized: StructuredData.serialize("ok"),
               snapshot: Snapshot.take()
             })

    assert_receive {:dispatcher_delivery, "node://dispatcher", "ok"}

    dispatcher_ref = Process.monitor(dispatcher)
    Process.exit(survivor_pid, :kill)

    assert_receive {:DOWN, ^dispatcher_ref, :process, ^dispatcher, :normal}
  end

  test "dispatcher keeps running on noreply paths when pending work remains" do
    name = unique_name("noreply")
    dispatcher = Dispatcher.ensure_started(name)

    message = %{
      origin: "node://dispatcher",
      serialized: StructuredData.serialize("queued"),
      snapshot: Snapshot.take()
    }

    :sys.replace_state(dispatcher, fn state ->
      queue = :queue.in(%{recipients: [], message: message}, state.queue)
      %{state | queue: queue}
    end)

    send(dispatcher, {:broadcast_channel_remote, message})

    assert Process.alive?(dispatcher)

    dispatcher_ref = Process.monitor(dispatcher)
    GenServer.stop(dispatcher, :normal)

    assert_receive {:DOWN, ^dispatcher_ref, :process, ^dispatcher, :normal}
  end

  defp survivor_loop(parent) do
    receive do
      {:"$gen_cast",
       %Envelope{
         body: {:deliver, dispatcher, dispatch_ref, %{origin: origin, serialized: serialized}}
       }} ->
        send(parent, {:dispatcher_delivery, origin, StructuredData.deserialize(serialized)})
        send(dispatcher, {:broadcast_channel_delivery_complete, dispatch_ref, self()})
        survivor_loop(parent)
    end
  end

  defp await_process_exit(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      100 -> flunk("expected process to exit")
    end
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
