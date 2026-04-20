defmodule Web.BroadcastChannelTest do
  use ExUnit.Case, async: false

  doctest Web.BroadcastChannel

  alias Web.ArrayBuffer
  alias Web.AsyncContext.Snapshot
  alias Web.AsyncContext.Variable
  alias Web.BroadcastChannel
  alias Web.BroadcastChannel.Adapter
  alias Web.DOMException
  alias Web.Internal.BroadcastChannel, as: Engine
  alias Web.Internal.Envelope
  alias Web.Internal.StructuredData
  alias Web.TypeError
  import ExUnit.CaptureLog

  defmodule SpyAdapter do
    @behaviour Web.BroadcastChannel.Adapter

    @impl true
    def join(name, pid), do: notify({:spy_join, name, pid})

    @impl true
    def leave(name, pid), do: notify({:spy_leave, name, pid})

    @impl true
    def broadcast(name, pid, message), do: notify({:spy_broadcast, name, pid, message})

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

  test "constructor coerces names and exposes capability fields" do
    channel = BroadcastChannel.new(123)
    null_channel = BroadcastChannel.new(nil)
    internal_channel = Engine.new(unique_name("internal-default"))

    assert channel.name == "123"
    assert null_channel.name == "null"
    assert internal_channel.name =~ "internal-default"
    assert is_reference(channel.address)
    assert is_reference(channel.token)
    assert channel.onmessage == nil
    assert BroadcastChannel.onmessage(channel) == nil
  end

  test "broadcast adapter exposes the callback contract" do
    assert [join: 2, leave: 2, broadcast: 3] == Adapter.callback_contract()
  end

  test "broadcast channel public surface only exports standard-facing methods" do
    exported = BroadcastChannel.__info__(:functions)

    refute {:debug_server_pid, 1} in exported
    refute {:origin, 0} in exported

    assert Enum.sort(exported) == [
             {:__struct__, 0},
             {:__struct__, 1},
             {:add_event_listener, 3},
             {:add_event_listener, 4},
             {:close, 1},
             {:dispatch_event, 2},
             {:new, 1},
             {:onmessage, 1},
             {:onmessage, 2},
             {:post_message, 2},
             {:remove_event_listener, 3}
           ]
  end

  test "spoofed handles with a valid alias and invalid token are rejected" do
    channel = BroadcastChannel.new(unique_name("spoof"))
    spoofed = %{channel | token: make_ref()}
    callback = fn _event -> :ok end

    assert_data_clone_error(fn -> BroadcastChannel.onmessage(spoofed) end)
    assert_data_clone_error(fn -> BroadcastChannel.onmessage(spoofed, callback) end)

    assert_data_clone_error(fn ->
      BroadcastChannel.add_event_listener(spoofed, "message", callback)
    end)

    assert_data_clone_error(fn ->
      BroadcastChannel.remove_event_listener(spoofed, "message", callback)
    end)

    assert_data_clone_error(fn ->
      BroadcastChannel.dispatch_event(spoofed, %{type: "x", target: spoofed})
    end)

    assert_data_clone_error(fn -> BroadcastChannel.post_message(spoofed, "boom") end)
  end

  test "closing a channel detaches the capability so all public methods fail with DataCloneError" do
    channel = BroadcastChannel.new(unique_name("closed-post"))
    callback = fn _event -> :ok end
    event = %{type: "x", target: channel}

    assert :ok = BroadcastChannel.close(channel)

    assert_data_clone_error(fn -> BroadcastChannel.onmessage(channel) end)
    assert_data_clone_error(fn -> BroadcastChannel.onmessage(channel, callback) end)

    assert_data_clone_error(fn ->
      BroadcastChannel.add_event_listener(channel, "message", callback)
    end)

    assert_data_clone_error(fn ->
      BroadcastChannel.remove_event_listener(channel, "message", callback)
    end)

    assert_data_clone_error(fn -> BroadcastChannel.dispatch_event(channel, event) end)
    assert_data_clone_error(fn -> BroadcastChannel.post_message(channel, fn -> :boom end) end)
  end

  test "post_message raises DataCloneError or TypeError for invalid payloads while open" do
    channel = BroadcastChannel.new(unique_name("clone-error"))
    buffer = ArrayBuffer.new("hello")
    ArrayBuffer.detach(buffer)

    exception =
      assert_raise DOMException, fn ->
        BroadcastChannel.post_message(channel, fn -> :boom end)
      end

    assert exception.name == "DataCloneError"

    assert_raise TypeError, fn ->
      BroadcastChannel.post_message(channel, buffer)
    end
  end

  test "post_message broadcasts to peer channels and preserves event shape" do
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
    assert event.origin == origin()
  end

  test "message events use the sender origin carried in dispatcher payloads" do
    parent = self()
    channel_name = unique_name("sender-origin")

    receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:payload_origin, event.origin, event.data})
      end)

    send(dispatcher_pid(receiver), {
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
    channel_name = unique_name("listener-helpers")
    sender = BroadcastChannel.new(channel_name)
    callback = fn event -> send(parent, {:listener, event.data}) end

    receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.add_event_listener("message", callback)
      |> BroadcastChannel.add_event_listener("message", callback)

    assert BroadcastChannel.onmessage(receiver) == nil

    _receiver = BroadcastChannel.remove_event_listener(receiver, "message", callback)

    assert :ok = BroadcastChannel.post_message(sender, "gone")
    refute_receive {:listener, _}
  end

  test "dispatch_event notifies listeners and reports success" do
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

  test "configured governor wraps remote and local delivery work" do
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

  test "onmessage updates from inside an onmessage callback use the local path" do
    parent = self()
    channel_name = unique_name("self-onmessage")
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

  test "listener helpers use the local path from inside delivery callbacks" do
    parent = self()
    channel_name = unique_name("local-listener-helpers")
    sender = BroadcastChannel.new(channel_name)
    local_listener = fn event -> send(parent, {:local_dispatch, event.data}) end

    _receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        assert is_function(BroadcastChannel.onmessage(event.target), 1)

        target = BroadcastChannel.add_event_listener(event.target, "local", local_listener)

        assert {^target, true} =
                 BroadcastChannel.dispatch_event(target, %{
                   type: "local",
                   data: event.data,
                   target: target
                 })

        _target = BroadcastChannel.remove_event_listener(target, "local", local_listener)

        send(parent, {:local_helpers_complete, event.data})
      end)

    assert :ok = BroadcastChannel.post_message(sender, "ping")

    assert_receive {:local_dispatch, "ping"}
    assert_receive {:local_helpers_complete, "ping"}
  end

  test "posting from inside onmessage uses the self-post path and supports zero-arity callbacks" do
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

  test "closing inside onmessage makes self-post validation fail immediately" do
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
    assert_receive {:self_close_post, "DataCloneError"}
  end

  test "closing inside onmessage makes local getters fail immediately" do
    parent = self()
    channel_name = unique_name("self-close-get")
    sender = BroadcastChannel.new(channel_name)

    _receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        result =
          try do
            assert :ok = BroadcastChannel.close(event.target)
            BroadcastChannel.onmessage(event.target)
            :unexpected_success
          rescue
            exception in [DOMException] -> exception.name
          end

        send(parent, {:self_close_get, result})
      end)

    assert :ok = BroadcastChannel.post_message(sender, "first")
    assert_receive {:self_close_get, "DataCloneError"}
  end

  test "internal broadcast channel guards ignore malformed envelopes and unknown messages" do
    parent = self()
    channel_name = unique_name("internal-guards")
    sender = BroadcastChannel.new(channel_name)

    receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:guarded_delivery, event.data})
      end)

    send(
      receiver.address,
      {:"$gen_cast",
       Envelope.new(
         make_ref(),
         {:deliver, self(), make_ref(),
          %{origin: origin(), serialized: StructuredData.serialize("spoof")}},
         Snapshot.take()
       )}
    )

    send(channel_pid(receiver), :unexpected_info)

    refute_receive {:guarded_delivery, "spoof"}

    assert :ok = BroadcastChannel.post_message(sender, "ok")
    assert_receive {:guarded_delivery, "ok"}
  end

  test "internal broadcast channel rejects authenticated methods and ignores casts while closed" do
    parent = self()

    channel =
      BroadcastChannel.new(unique_name("internal-closed"))
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:closed_delivery, event.data})
      end)

    pid = channel_pid(channel)
    callback = fn _event -> :ok end
    event = %{type: "x", target: channel}

    :sys.replace_state(pid, &%{&1 | closed: true})

    assert_raw_data_clone_error(raw_request(channel, :get_onmessage))
    assert_raw_data_clone_error(raw_request(channel, {:set_onmessage, callback}))

    assert_raw_data_clone_error(
      raw_request(channel, {:add_event_listener, "message", callback, %{}})
    )

    assert_raw_data_clone_error(
      raw_request(channel, {:remove_event_listener, "message", callback})
    )

    assert_raw_data_clone_error(raw_request(channel, {:dispatch_event, event}))
    assert_raw_data_clone_error(raw_request(channel, {:post_message, "closed", origin()}))
    assert_raw_data_clone_error(raw_request_with_token(channel, make_ref(), :unexpected_call))
    assert_raw_data_clone_error(raw_request(channel, :unexpected_call))

    assert :ok =
             raw_cast(
               channel,
               {:deliver, self(), make_ref(),
                %{origin: origin(), serialized: StructuredData.serialize("ignored")}}
             )

    assert :ok = raw_cast(channel, :unexpected_cast)
    refute_receive {:closed_delivery, _}

    assert :ok = BroadcastChannel.close(channel)
  end

  test "internal broadcast channel accepts legacy envelope wrappers and ignores malformed ones" do
    parent = self()
    channel_name = unique_name("legacy-envelope")
    sender = BroadcastChannel.new(channel_name)

    receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:legacy_wrapper_delivery, event.data})
      end)

    assert :ok = legacy_raw_request(sender, {:post_message, "legacy-call", origin()})
    assert_receive {:legacy_wrapper_delivery, "legacy-call"}

    assert :ok =
             legacy_raw_cast(
               receiver,
               {:deliver, self(), make_ref(),
                %{origin: origin(), serialized: StructuredData.serialize("legacy-cast")}}
             )

    assert_receive {:legacy_wrapper_delivery, "legacy-cast"}

    assert_raw_data_clone_error(legacy_raw_request(sender, :malformed_wrapper))

    assert :ok = malformed_legacy_raw_cast(receiver, :ignored)
    refute_receive {:legacy_wrapper_delivery, "ignored"}
  end

  test "internal broadcast channel callback clauses accept legacy envelope wrappers" do
    channel = BroadcastChannel.new(unique_name("legacy-envelope-callbacks"))
    pid = channel_pid(channel)
    state = :sys.get_state(pid)
    envelope = Envelope.new(channel.token, :debug_server_pid, Snapshot.take())
    from = {self(), make_ref()}

    assert {:reply, test_pid, ^state} = Engine.handle_call({:envelope, envelope}, from, state)
    assert test_pid == self()

    assert {:reply, {:error, %DOMException{name: "DataCloneError"}}, ^state} =
             Engine.handle_call({:envelope, :bad}, from, state)

    assert {:noreply, ^state} =
             Engine.handle_cast({:envelope, Envelope.new(channel.token, :noop)}, state)

    assert {:noreply, ^state} = Engine.handle_cast({:envelope, :bad}, state)

    assert :ok = BroadcastChannel.close(channel)
  end

  test "crashing listeners acknowledge the dispatcher so remaining recipients still receive" do
    parent = self()
    channel_name = unique_name("listener-crash")
    sender = BroadcastChannel.new(channel_name)

    crashing =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn _event ->
        raise "boom"
      end)

    monitor_ref = Process.monitor(channel_pid(crashing))

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

  test "tampering with local state crashes only that recipient after it acks delivery" do
    parent = self()
    channel_name = unique_name("tampered-local-state")
    sender = BroadcastChannel.new(channel_name)

    tampered =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn _event ->
        Process.delete({Engine, :local_state})
      end)

    tampered_ref = Process.monitor(channel_pid(tampered))

    _receiver =
      BroadcastChannel.new(channel_name)
      |> BroadcastChannel.onmessage(fn event ->
        send(parent, {:after_tamper, event.data})
      end)

    log =
      capture_log(fn ->
        assert :ok = BroadcastChannel.post_message(sender, "boom")
        assert_receive {:DOWN, ^tampered_ref, :process, _, _}
        assert_receive {:after_tamper, "boom"}
      end)

    assert log =~ "missing local BroadcastChannel state"
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

  test "owner shutdown tears down the capability handle" do
    parent = self()

    _owner =
      spawn(fn ->
        channel = BroadcastChannel.new(unique_name("owned"))
        send(parent, {:owned_channel, channel})
      end)

    channel =
      receive do
        {:owned_channel, channel} -> channel
      after
        1_000 -> flunk("expected owned channel")
      end

    await_data_clone_error(fn -> BroadcastChannel.onmessage(channel) end)
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp origin do
    "node://" <> Atom.to_string(node())
  end

  defp channel_pid(channel) do
    Engine.debug_server_pid(channel)
  end

  defp dispatcher_pid(channel) do
    channel
    |> channel_pid()
    |> :sys.get_state()
    |> Map.fetch!(:dispatcher)
  end

  defp restore_env(key, nil) do
    Application.delete_env(:web, key)
  end

  defp restore_env(key, value) do
    Application.put_env(:web, key, value)
  end

  defp assert_data_clone_error(fun) do
    exception = assert_raise DOMException, fun
    assert exception.name == "DataCloneError"
    exception
  end

  defp assert_raw_data_clone_error(reply) do
    assert {:error, %DOMException{name: "DataCloneError"} = exception} = reply
    exception
  end

  defp raw_request(%BroadcastChannel{} = channel, body, timeout \\ 100) do
    reply_ref = make_ref()

    send(channel.address, {:"$gen_call", {self(), reply_ref}, Envelope.new(channel.token, body)})

    receive do
      {^reply_ref, reply} -> reply
    after
      timeout -> flunk("expected raw request reply")
    end
  end

  defp raw_cast(%BroadcastChannel{} = channel, body) do
    send(channel.address, {:"$gen_cast", Envelope.new(channel.token, body)})
    :ok
  end

  defp raw_request_with_token(%BroadcastChannel{} = channel, token, body, timeout \\ 100) do
    reply_ref = make_ref()

    send(channel.address, {:"$gen_call", {self(), reply_ref}, Envelope.new(token, body)})

    receive do
      {^reply_ref, reply} -> reply
    after
      timeout -> flunk("expected raw request reply")
    end
  end

  defp legacy_raw_request(%BroadcastChannel{} = channel, body, timeout \\ 100) do
    reply_ref = make_ref()

    send(
      channel.address,
      {:"$gen_call", {self(), reply_ref}, {:envelope, Envelope.new(channel.token, body)}}
    )

    receive do
      {^reply_ref, reply} -> reply
    after
      timeout -> flunk("expected legacy raw request reply")
    end
  end

  defp legacy_raw_cast(%BroadcastChannel{} = channel, body) do
    send(channel.address, {:"$gen_cast", {:envelope, Envelope.new(channel.token, body)}})
    :ok
  end

  defp malformed_legacy_raw_cast(%BroadcastChannel{} = channel, body) do
    send(channel.address, {:"$gen_cast", {:envelope, body}})
    :ok
  end

  defp await_data_clone_error(fun, attempts \\ 10)

  defp await_data_clone_error(_fun, 0), do: flunk("expected DataCloneError")

  defp await_data_clone_error(fun, attempts) do
    assert_data_clone_error(fun)
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      await_data_clone_error(fun, attempts - 1)
  end
end
