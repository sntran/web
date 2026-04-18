defmodule Web.BroadcastChannelTest do
  use ExUnit.Case, async: false

  doctest Web.BroadcastChannel

  # Port of the portable BroadcastChannel WPT coverage from interface.any.js and
  # basics.any.js. The remaining html/window/worker/origin cases are browser-only
  # and do not map directly onto this BEAM runtime.

  alias Web.ArrayBuffer
  alias Web.AsyncContext.Snapshot
  alias Web.AsyncContext.Variable
  alias Web.BroadcastChannel
  alias Web.BroadcastChannel.ChannelServer
  alias Web.BroadcastChannel.Dispatcher
  alias Web.DOMException
  alias Web.Internal.StructuredData
  alias Web.TypeError
  import ExUnit.CaptureLog

  defmodule SpyAdapter do
    @behaviour Web.BroadcastChannel.Adapter

    @impl true
    def join(name, pid) do
      notify({:spy_join, name, pid})
    end

    @impl true
    def leave(name, pid) do
      notify({:spy_leave, name, pid})
    end

    @impl true
    def broadcast(name, pid, message) do
      notify({:spy_broadcast, name, pid, message})
    end

    defp notify(message) do
      if spy = Application.get_env(:web, :broadcast_adapter_spy) do
        send(spy, message)
      end

      :ok
    end
  end

  defmodule SpyGovernor do
    defstruct [:pid]

    def acquire(%__MODULE__{pid: pid} = governor) do
      ref = make_ref()
      send(pid, {:spy_governor, :acquire, ref})
      Web.Promise.resolve(%Web.Governor.Token{governor: governor, ref: ref})
    end

    def release_token(%__MODULE__{pid: pid}, ref) do
      send(pid, {:spy_governor, :release, ref})
      :ok
    end
  end

  setup do
    original_adapter = Application.get_env(:web, :broadcast_adapter)
    original_adapter_spy = Application.get_env(:web, :broadcast_adapter_spy)
    original_governor = Application.get_env(:web, :broadcast_governor)

    on_exit(fn ->
      restore_env(:broadcast_adapter, original_adapter)
      restore_env(:broadcast_adapter_spy, original_adapter_spy)
      restore_env(:broadcast_governor, original_governor)
    end)

    :ok
  end

  test "default-arg constructor and single-arity post_message are not public" do
    refute function_exported?(BroadcastChannel, :new, 0)
    refute function_exported?(BroadcastChannel, :post_message, 1)
    refute function_exported?(BroadcastChannel, :postMessage, 2)
    refute function_exported?(BroadcastChannel, :addEventListener, 3)
    refute function_exported?(BroadcastChannel, :addEventListener, 4)
    refute function_exported?(BroadcastChannel, :removeEventListener, 3)
  end

  test "constructor coerces channel names and exposes onmessage" do
    channel = BroadcastChannel.new(123)

    assert channel.name == "123"
    assert Map.has_key?(channel, :onmessage)
    assert channel.onmessage == nil
  end

  test "constructor coerces nil to the JavaScript null string" do
    channel = BroadcastChannel.new(nil)
    assert channel.name == "null"
  end

  test "adapter behavior exposes the expected callback contract" do
    assert Enum.sort(BroadcastChannel.Adapter.behaviour_info(:callbacks)) ==
             [broadcast: 3, join: 2, leave: 2]

    assert Enum.sort(BroadcastChannel.Adapter.callback_contract()) ==
             [broadcast: 3, join: 2, leave: 2]
  end

  test "post_message raises TypeError for cloneable-type violations" do
    channel = BroadcastChannel.new(unique_name("type-error"))
    buffer = ArrayBuffer.new("hello")
    ArrayBuffer.detach(buffer)

    assert_raise TypeError, fn ->
      BroadcastChannel.post_message(channel, buffer)
    end
  end

  test "post_message after close raises InvalidStateError before clone validation" do
    channel = BroadcastChannel.new(unique_name("closed-post"))
    assert :ok = BroadcastChannel.close(channel)

    exception =
      assert_raise DOMException, fn ->
        BroadcastChannel.post_message(channel, fn -> :boom end)
      end

    assert exception.name == "InvalidStateError"
  end

  test "post_message raises DataCloneError for uncloneable values while open" do
    channel = BroadcastChannel.new(unique_name("clone-error"))

    exception =
      assert_raise DOMException, fn ->
        BroadcastChannel.post_message(channel, fn -> :boom end)
      end

    assert exception.name == "DataCloneError"
  end

  test "post_message broadcasts to peer channels" do
    parent = self()
    channel_name = unique_name("snake-post-message")
    sender = BroadcastChannel.new(channel_name)

    _receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:snake_post_message, event.data})
      end)

    assert :ok = BroadcastChannel.post_message(sender, "snake")
    assert_receive {:snake_post_message, "snake"}
  end

  test "post_message delivers a MessageEvent with the expected shape" do
    parent = self()
    channel_name = unique_name("event-shape")
    sender = BroadcastChannel.new(channel_name)

    receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:message_event, event})
      end)

    assert :ok = BroadcastChannel.post_message(sender, "hello world")

    assert_receive {:message_event, event}
    assert %Web.MessageEvent{} = event
    assert event.target == receiver
    assert event.type == "message"
    assert event.data == "hello world"
    assert event.source == nil
    assert event.origin == "node://" <> Atom.to_string(node())
  end

  test "message events use the sender origin carried in the dispatcher payload" do
    parent = self()
    channel_name = unique_name("sender-origin")

    receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:payload_origin, event.origin, event.data})
      end)

    dispatcher = :sys.get_state(receiver.pid).dispatcher

    send(dispatcher, {
      :broadcast_channel_remote,
      %{
        origin: "node://remote@example",
        serialized: StructuredData.serialize("from-remote"),
        snapshot: Snapshot.take()
      }
    })

    assert_receive {:payload_origin, "node://remote@example", "from-remote"}
  end

  test "snake_case listener helpers can add and remove listeners" do
    parent = self()
    channel_name = unique_name("camel-case-aliases")
    sender = BroadcastChannel.new(channel_name)
    callback = fn event -> send(parent, {:camel_listener, event.data}) end

    receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.add_event_listener("message", callback)
      |> BroadcastChannel.add_event_listener("message", callback)

    assert BroadcastChannel.onmessage(receiver) == nil

    _receiver = BroadcastChannel.remove_event_listener(receiver, "message", callback)

    assert :ok = BroadcastChannel.post_message(sender, "gone")
    refute_receive {:camel_listener, _}
  end

  test "dispatch_event notifies registered listeners and reports success" do
    parent = self()

    channel =
      BroadcastChannel.new(unique_name("dispatch-event"))
      |> BroadcastChannel.add_event_listener("custom", fn event ->
        send(parent, {:manual_dispatch, event.type, event.data})
      end)

    event = %{type: "custom", data: "payload", target: channel}

    assert {^channel, true} = BroadcastChannel.dispatch_event(channel, event)
    assert_receive {:manual_dispatch, "custom", "payload"}
  end

  test "broadcast adapter is resolved from application config at runtime" do
    parent = self()
    channel_name = unique_name("adapter-config")

    Application.put_env(:web, :broadcast_adapter_spy, parent)
    Application.put_env(:web, :broadcast_adapter, SpyAdapter)

    sender = BroadcastChannel.new(channel_name)

    receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:adapter_receiver, event.data})
      end)

    assert_receive {:spy_join, ^channel_name, _dispatcher_pid}

    assert :ok = BroadcastChannel.post_message(sender, "adapter-path")

    assert_receive {:spy_broadcast, ^channel_name, _dispatcher_pid,
                    {:broadcast_channel_remote,
                     %{origin: _, serialized: %{}, snapshot: %Snapshot{}}}}

    assert_receive {:adapter_receiver, "adapter-path"}

    assert :ok = BroadcastChannel.close(sender)
    assert :ok = BroadcastChannel.close(receiver)
    assert_receive {:spy_leave, ^channel_name, _dispatcher_pid}
  end

  test "configured governor wraps broadcast fan-out and local delivery work" do
    parent = self()
    channel_name = unique_name("governor-path")

    Application.put_env(:web, :broadcast_governor, %SpyGovernor{pid: parent})

    sender = BroadcastChannel.new(channel_name)

    _receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:governor_receiver, event.data})
      end)

    assert :ok = BroadcastChannel.post_message(sender, "throttled")

    governor_events =
      Enum.map(1..4, fn _index ->
        assert_receive {:spy_governor, event, ref}
        {event, ref}
      end)

    acquired = for {:acquire, ref} <- governor_events, do: ref
    released = for {:release, ref} <- governor_events, do: ref

    assert length(acquired) == 2
    assert Enum.sort(acquired) == Enum.sort(released)
    assert_receive {:governor_receiver, "throttled"}
  end

  test "onmessage updates from inside a listener use the local cast path" do
    parent = self()
    channel_name = unique_name("self-onmessage-cast")
    sender = BroadcastChannel.new(channel_name)

    _receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        _channel = BroadcastChannel.onmessage(event.target, nil)
        send(parent, {:self_cast_message, event.data})
      end)

    assert :ok = BroadcastChannel.post_message(sender, "first")
    assert_receive {:self_cast_message, "first"}

    Process.sleep(20)
    assert :ok = BroadcastChannel.post_message(sender, "second")
    refute_receive {:self_cast_message, "second"}
  end

  test "posting from inside a listener uses the self-post path and supports zero-arity onmessage" do
    parent = self()
    channel_name = unique_name("self-post")
    sender = BroadcastChannel.new(channel_name)

    _self_posting =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        if event.data == "first" do
          assert :ok = BroadcastChannel.post_message(event.target, "second")
        end
      end)

    _receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn ->
        send(parent, :zero_arity_message)
      end)

    assert :ok = BroadcastChannel.post_message(sender, "first")

    assert_receive :zero_arity_message
    assert_receive :zero_arity_message
  end

  test "sender does not receive its own broadcast" do
    parent = self()
    channel_name = unique_name("self-delivery")

    sender =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:sender_received, event.data})
      end)

    receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:receiver_received, event.data})
      end)

    assert :ok = BroadcastChannel.post_message(sender, "ping")

    assert_receive {:receiver_received, "ping"}
    refute_receive {:sender_received, _}
    assert receiver.name == channel_name
  end

  test "posting with no other subscribers is a no-op" do
    channel = BroadcastChannel.new(unique_name("solo-post"))
    assert :ok = BroadcastChannel.post_message(channel, "solo")
    refute_receive _message
  end

  test "messages are delivered in channel creation order" do
    parent = self()
    channel_name = unique_name("creation-order")

    c1 =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:delivered, :c1, event.data})
      end)

    c2 =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:delivered, :c2, event.data})
      end)

    c3 =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:delivered, :c3, event.data})
      end)

    assert :ok = BroadcastChannel.post_message(c1, "from c1")
    assert :ok = BroadcastChannel.post_message(c3, "from c3")
    assert :ok = BroadcastChannel.post_message(c2, "done")

    assert_receive {:delivered, :c2, "from c1"}
    assert_receive {:delivered, :c3, "from c1"}
    assert_receive {:delivered, :c1, "from c3"}
    assert_receive {:delivered, :c2, "from c3"}
    assert_receive {:delivered, :c1, "done"}
    assert_receive {:delivered, :c3, "done"}
  end

  test "closing a channel after post_message prevents the queued delivery" do
    parent = self()
    channel_name = unique_name("close-after-post")
    sender = BroadcastChannel.new(channel_name)

    closed_channel =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:closed_channel_received, event.data})
      end)

    _live_channel =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:live_channel_received, event.data})
      end)

    assert :ok = BroadcastChannel.post_message(sender, "test")
    assert :ok = BroadcastChannel.close(closed_channel)

    assert_receive {:live_channel_received, "test"}
    refute_receive {:closed_channel_received, _}
  end

  test "closing and creating channels during delivery updates future broadcasts only" do
    parent = self()
    channel_name = unique_name("create-during-delivery")
    c1 = BroadcastChannel.new(channel_name)

    c2 =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:c2_received, event.data})

        if event.data == "first" do
          assert :ok = BroadcastChannel.close(event.target)

          BroadcastChannel.new(channel_name)
          |> BroadcastChannel.onmessage(fn next_event ->
            send(parent, {:c3_received, next_event.data})
          end)

          assert :ok = BroadcastChannel.post_message(c1, "done")
        end
      end)

    assert :ok = BroadcastChannel.post_message(c1, "first")
    assert :ok = BroadcastChannel.post_message(c2, "second")

    assert_receive {:c2_received, "first"}
    assert_receive {:c3_received, "done"}
    refute_receive {:c2_received, "second"}
  end

  test "channel server cast paths update state and ignore unrelated messages" do
    parent = self()
    channel_name = unique_name("channel-server-casts")
    sender = BroadcastChannel.new(channel_name)
    receiver = BroadcastChannel.new(channel_name)
    listener = fn event -> send(parent, {:cast_listener, event.data}) end

    GenServer.cast(receiver.pid, {
      :set_onmessage,
      fn event -> send(parent, {:cast_onmessage, event.data}) end
    })

    GenServer.cast(receiver.pid, {:add_listener, "message", listener, %{}})
    Process.sleep(20)

    send(receiver.pid, :unrelated_message)
    Process.sleep(20)
    assert Process.alive?(receiver.pid)

    assert :ok = BroadcastChannel.post_message(sender, "casted")
    assert_receive {:cast_onmessage, "casted"}
    assert_receive {:cast_listener, "casted"}

    GenServer.cast(receiver.pid, {:remove_listener, "message", listener})
    Process.sleep(20)

    assert :ok = BroadcastChannel.post_message(sender, "after-remove")
    assert_receive {:cast_onmessage, "after-remove"}
    refute_receive {:cast_listener, "after-remove"}
    assert is_function(BroadcastChannel.onmessage(receiver), 1)
  end

  test "closing inside a listener makes self-post validation fail immediately" do
    parent = self()
    channel_name = unique_name("self-close-post")
    sender = BroadcastChannel.new(channel_name)

    _receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        result =
          try do
            assert :ok = BroadcastChannel.close(event.target)
            BroadcastChannel.post_message(event.target, "again")
            :unexpected_success
          rescue
            exception in [DOMException] -> exception.name
          end

        send(parent, {:self_close_post, result})
      end)

    assert :ok = BroadcastChannel.post_message(sender, "first")
    assert_receive {:self_close_post, "InvalidStateError"}
  end

  test "stale open runtime metadata still raises InvalidStateError for dead pids" do
    channel_name = unique_name("stale-runtime")
    channel = BroadcastChannel.new(channel_name)
    assert :ok = BroadcastChannel.close(channel)

    dead_pid = spawn(fn -> :ok end)
    Process.sleep(20)

    assert ChannelServer.runtime_info(dead_pid) == nil
    assert :ok = ChannelServer.mark_closed(dead_pid)

    true =
      :ets.insert(Web.BroadcastChannel.ChannelServer.Runtime, {
        dead_pid,
        %{dispatcher: self(), closed: false}
      })

    on_exit(fn ->
      case :ets.whereis(Web.BroadcastChannel.ChannelServer.Runtime) do
        :undefined -> :ok
        _table -> :ets.delete(Web.BroadcastChannel.ChannelServer.Runtime, dead_pid)
      end
    end)

    exception =
      assert_raise DOMException, fn ->
        BroadcastChannel.post_message(
          %BroadcastChannel{pid: dead_pid, name: channel_name},
          "stale"
        )
      end

    assert exception.name == "InvalidStateError"
  end

  test "channel server handles event-target cleanup messages" do
    channel = BroadcastChannel.new(unique_name("channel-server-event-target"))

    send(channel.pid, {{Web.EventTarget, :abort_signal}, 0})

    Process.sleep(20)
    assert Process.alive?(channel.pid)
  end

  test "closing in onmessage prevents already queued tasks from firing" do
    parent = self()
    channel_name = unique_name("close-in-onmessage")

    c1 = BroadcastChannel.new(channel_name)

    _c2 =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:event_log, "c2: #{event.data}"})
      end)
      |> BroadcastChannel.add_event_listener("message", fn event ->
        assert :ok = BroadcastChannel.close(event.target)
      end)

    _c3 =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:event_log, "c3: #{event.data}"})
      end)

    assert :ok = BroadcastChannel.post_message(c1, "first")
    assert :ok = BroadcastChannel.post_message(c1, "done")

    assert_receive {:event_log, "c2: first"}
    assert_receive {:event_log, "c3: first"}
    assert_receive {:event_log, "c3: done"}
    refute_receive {:event_log, "c2: done"}
  end

  test "crashing listeners ack the dispatcher so remaining recipients still receive" do
    parent = self()
    channel_name = unique_name("listener-crash")
    sender = BroadcastChannel.new(channel_name)

    crashing =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn _event ->
        raise "boom"
      end)

    monitor_ref = Process.monitor(crashing.pid)

    _receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:after_crash, event.data})
      end)

    log =
      capture_log(fn ->
        assert :ok = BroadcastChannel.post_message(sender, "boom")
        assert_receive {:DOWN, ^monitor_ref, :process, _, _}
        assert_receive {:after_crash, "boom"}
      end)

    assert log =~ "GenServer"
  end

  test "async context snapshots are restored while listeners run" do
    parent = self()
    request_id = Variable.new("request_id")
    channel_name = unique_name("async-context")
    sender = BroadcastChannel.new(channel_name)

    _receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn _event ->
        send(parent, {:request_id, Variable.get(request_id)})
      end)

    Variable.run(request_id, "req-42", fn ->
      assert :ok = BroadcastChannel.post_message(sender, "ok")
    end)

    assert_receive {:request_id, "req-42"}
  end

  test "dispatcher edge paths stay stable for duplicate register, unknown unregister, and empty remote fan-out" do
    channel_name = unique_name("dispatcher-edges")
    channel = BroadcastChannel.new(channel_name)
    channel_state = :sys.get_state(channel.pid)
    dispatcher = channel_state.dispatcher
    creation_index = channel_state.creation_index

    assert %{dispatcher: ^dispatcher, creation_index: ^creation_index} =
             Dispatcher.register(channel_name, channel.pid)

    dead_pid = spawn(fn -> :ok end)
    Process.sleep(20)
    assert :ok = Dispatcher.unregister(dispatcher, dead_pid)

    dead_dispatcher = spawn(fn -> :ok end)
    Process.sleep(20)
    assert :ok = Dispatcher.unregister(dead_dispatcher, self())

    send(dispatcher, {:broadcast_channel_delivery_complete, make_ref(), self()})
    send(dispatcher, :unrelated_dispatcher_message)
    Process.sleep(20)
    assert Process.alive?(dispatcher)

    empty_name = unique_name("dispatcher-empty")
    empty_dispatcher = Dispatcher.ensure_started(empty_name)

    send(empty_dispatcher, {
      :broadcast_channel_remote,
      %{
        origin: BroadcastChannel.origin(),
        serialized: StructuredData.serialize("noop"),
        snapshot: Snapshot.take()
      }
    })

    Process.sleep(20)
    refute Process.alive?(empty_dispatcher)
  end

  test "dispatcher handles catch paths and synthetic queue edge states" do
    caller =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, _request} -> exit(:boom)
        end
      end)

    assert :ok = Dispatcher.unregister(caller, self())

    serialized = StructuredData.serialize("queued")
    snapshot = Snapshot.take()

    down_dispatcher = Dispatcher.ensure_started(unique_name("dispatcher-down-edge"))

    :sys.replace_state(down_dispatcher, fn state ->
      %{
        state
        | subscribers: %{self() => %{creation_index: 0, monitor_ref: make_ref()}},
          subscriber_monitors: %{}
      }
    end)

    send(down_dispatcher, {:DOWN, make_ref(), :process, self(), :normal})
    Process.sleep(20)
    assert Process.alive?(down_dispatcher)

    current_pid = spawn(fn -> Process.sleep(:infinity) end)
    monitor_ref = make_ref()
    current_dispatcher = Dispatcher.ensure_started(unique_name("dispatcher-current-down"))

    :sys.replace_state(current_dispatcher, fn state ->
      %{
        state
        | subscribers: %{current_pid => %{creation_index: 0, monitor_ref: monitor_ref}},
          subscriber_monitors: %{monitor_ref => current_pid},
          current: %{
            ref: make_ref(),
            current_pid: current_pid,
            remaining: [],
            message: %{
              origin: BroadcastChannel.origin(),
              serialized: serialized,
              snapshot: snapshot
            }
          }
      }
    end)

    send(current_dispatcher, {:DOWN, monitor_ref, :process, current_pid, :killed})
    Process.sleep(20)
    refute Process.alive?(current_dispatcher)

    queue_dispatcher = Dispatcher.ensure_started(unique_name("dispatcher-queue-recursion"))

    :sys.replace_state(queue_dispatcher, fn state ->
      %{
        state
        | subscribers: %{},
          queue:
            :queue.from_list([
              %{
                recipients: [spawn(fn -> :ok end)],
                message: %{
                  origin: BroadcastChannel.origin(),
                  serialized: serialized,
                  snapshot: snapshot
                }
              }
            ]),
          dispatch_scheduled: true
      }
    end)

    send(queue_dispatcher, :broadcast_channel_drain)
    Process.sleep(20)
    refute Process.alive?(queue_dispatcher)

    stop_ok_dispatcher = Dispatcher.ensure_started(unique_name("dispatcher-stop-ok"))

    :sys.replace_state(stop_ok_dispatcher, fn state ->
      %{
        state
        | subscribers: %{},
          queue:
            :queue.from_list([
              %{
                recipients: [],
                message: %{
                  origin: BroadcastChannel.origin(),
                  serialized: serialized,
                  snapshot: snapshot
                }
              }
            ])
      }
    end)

    assert :ok = Dispatcher.unregister(stop_ok_dispatcher, self())
    assert Process.alive?(stop_ok_dispatcher)

    stop_noreply_dispatcher = Dispatcher.ensure_started(unique_name("dispatcher-stop-noreply"))

    :sys.replace_state(stop_noreply_dispatcher, fn state ->
      %{
        state
        | subscribers: %{},
          queue:
            :queue.from_list([
              %{
                recipients: [],
                message: %{
                  origin: BroadcastChannel.origin(),
                  serialized: serialized,
                  snapshot: snapshot
                }
              }
            ]),
          dispatch_scheduled: true
      }
    end)

    send(stop_noreply_dispatcher, {
      :broadcast_channel_remote,
      %{origin: BroadcastChannel.origin(), serialized: serialized, snapshot: snapshot}
    })

    Process.sleep(20)
    assert Process.alive?(stop_noreply_dispatcher)
  end

  test "each recipient gets an isolated structured clone" do
    parent = self()
    channel_name = unique_name("isolated-array-buffer")
    sender = BroadcastChannel.new(channel_name)

    _first =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        ArrayBuffer.detach(event.data)
        send(parent, {:first_length, ArrayBuffer.byte_length(event.data)})
      end)

    _second =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:second_length, ArrayBuffer.byte_length(event.data)})
      end)

    assert :ok = BroadcastChannel.post_message(sender, ArrayBuffer.new("hello"))

    assert_receive {:first_length, 0}
    assert_receive {:second_length, 5}
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp restore_env(key, nil) do
    Application.delete_env(:web, key)
  end

  defp restore_env(key, value) do
    Application.put_env(:web, key, value)
  end
end
