defmodule Web.MessagePortTest do
  use ExUnit.Case, async: false
  use Web

  alias Web.ArrayBuffer
  alias Web.AsyncContext.Snapshot
  alias Web.AsyncContext.Variable
  alias Web.DOMException
  alias Web.Internal.Envelope
  alias Web.Internal.MessagePort, as: Engine
  alias Web.Internal.StructuredData
  alias Web.MessageChannel
  alias Web.MessageEvent
  alias Web.MessagePort
  alias Web.Symbol
  alias Web.TypeError
  import ExUnit.CaptureLog

  test "message port public surface only exports standard-facing methods" do
    exported = MessagePort.__info__(:functions)

    refute {:debug_server_pid, 1} in exported
    refute {:deserialize, 1} in exported
    refute {:ensure_transferable, 1} in exported

    assert Enum.sort(exported) == [
             {:__struct__, 0},
             {:__struct__, 1},
             {:add_event_listener, 3},
             {:add_event_listener, 4},
             {:close, 1},
             {:dispatch_event, 2},
             {:onmessage, 1},
             {:onmessage, 2},
             {:post_message, 2},
             {:post_message, 3},
             {:remove_event_listener, 3}
           ]
  end

  test "MessageChannel.new/0 returns entangled capability handles" do
    parent = self()
    {port1, port2} = MessageChannel.new()
    persistent = fn event -> send(parent, {:listener, event.data}) end
    removed = fn event -> send(parent, {:removed, event.data}) end

    assert is_reference(port1.address)
    assert is_reference(port1.token)

    port2 =
      MessagePort.onmessage(port2, fn event ->
        send(parent, {:onmessage, event.data})
      end)

    assert is_function(MessagePort.onmessage(port2), 1)

    port2 =
      port2
      |> MessagePort.add_event_listener("message", persistent)
      |> MessagePort.add_event_listener("message", removed)
      |> MessagePort.remove_event_listener("message", removed)

    assert :ok = MessagePort.post_message(port1, %{"value" => 1})

    assert_receive {:onmessage, %{"value" => 1}}
    assert_receive {:listener, %{"value" => 1}}
    refute_receive {:removed, _}

    port2 =
      MessagePort.add_event_listener(port2, "manual", fn event ->
        send(parent, {:manual, event.data})
      end)

    assert {^port2, true} =
             MessagePort.dispatch_event(
               port2,
               MessageEvent.new("manual", data: "manual", target: port2)
             )

    assert_receive {:manual, "manual"}

    assert :ok = MessagePort.close(port1)
    await_data_clone_error(fn -> MessagePort.onmessage(port1) end)
    await_data_clone_error(fn -> MessagePort.post_message(port2, "closed") end)
  end

  test "engine default start_pair and unexpected info messages keep ports operational" do
    parent = self()
    {port1, port2} = Engine.start_pair()

    port1 =
      MessagePort.onmessage(port1, fn event ->
        send(parent, {:engine_default, event.data})
      end)

    send(Engine.debug_server_pid(port1), :unexpected_info)

    assert :ok = MessagePort.post_message(port2, "ok")
    assert_receive {:engine_default, "ok"}

    assert :ok = MessagePort.close(port1)
    await_data_clone_error(fn -> MessagePort.post_message(port2, "closed") end)
  end

  test "spoofed handles with a valid alias and invalid token are rejected" do
    {port1, port2} = MessageChannel.new()
    spoofed = %{port1 | token: make_ref()}

    assert_data_clone_error(fn -> MessagePort.onmessage(spoofed) end)
    assert_data_clone_error(fn -> MessagePort.onmessage(spoofed, nil) end)

    assert_data_clone_error(fn ->
      MessagePort.add_event_listener(spoofed, "message", fn _ -> :ok end)
    end)

    assert_data_clone_error(fn ->
      MessagePort.remove_event_listener(spoofed, "message", fn _ -> :ok end)
    end)

    assert_data_clone_error(fn ->
      MessagePort.dispatch_event(spoofed, %{type: "message", target: spoofed})
    end)

    assert_data_clone_error(fn -> MessagePort.post_message(spoofed, "boom") end)
    assert_data_clone_error(fn -> MessagePort.close(spoofed) end)

    send(
      port1.address,
      {:"$gen_cast", Envelope.new(make_ref(), :peer_closed, Snapshot.take())}
    )

    assert :ok = MessagePort.post_message(port1, "still-open")
    assert :ok = MessagePort.close(port1)
    await_data_clone_error(fn -> MessagePort.post_message(port2, "closed") end)
  end

  test "post_message transfers message ports, detaches the old handle, and preserves async context" do
    parent = self()
    request_id = Variable.new("request_id")
    {port1, port2} = MessageChannel.new()
    {transfer_port, sibling} = MessageChannel.new()

    port2 =
      MessagePort.onmessage(port2, fn event ->
        send(parent, {:request_id, Variable.get(request_id)})

        transferred = event.data["port"]
        assert %MessagePort{} = transferred
        assert :ok = MessagePort.post_message(transferred, "forwarded")
      end)

    sibling =
      MessagePort.onmessage(sibling, fn event ->
        send(parent, {:forwarded, event.data})
      end)

    Variable.run(request_id, "req-42", fn ->
      assert :ok = MessagePort.post_message(port1, %{"port" => transfer_port}, [transfer_port])
    end)

    assert_receive {:request_id, "req-42"}
    assert_receive {:forwarded, "forwarded"}

    await_data_clone_error(fn -> MessagePort.post_message(transfer_port, "boom") end)
    await_data_clone_error(fn -> MessagePort.onmessage(transfer_port) end)

    assert :ok = MessagePort.close(port1)
    await_data_clone_error(fn -> MessagePort.post_message(port2, "closed") end)
    await_data_clone_error(fn -> MessagePort.post_message(sibling, "closed") end)
  end

  test "ports can transfer themselves to their sibling owner" do
    parent = self()
    {port1, port2} = MessageChannel.new()

    port2 =
      port2
      |> MessagePort.onmessage(fn event ->
        case event.data do
          %{"self" => transferred} ->
            send(parent, :received_self)
            assert :ok = MessagePort.post_message(transferred, "after-self-transfer")

          _other ->
            :ok
        end
      end)
      |> MessagePort.add_event_listener("message", fn event ->
        if event.data == "after-self-transfer" do
          send(parent, :self_transfer_forwarded)
        end
      end)

    assert :ok = MessagePort.post_message(port1, %{"self" => port1}, [port1])

    assert_receive :received_self
    assert_receive :self_transfer_forwarded
    await_data_clone_error(fn -> MessagePort.post_message(port1, "boom") end)

    assert :ok = MessagePort.close(port2)
  end

  test "structured_clone rejects MessagePort values unless they are transferred" do
    {port1, port2} = MessageChannel.new()

    assert_data_clone_error(fn -> Web.structured_clone(%{"port" => port1}) end)

    assert :ok = MessagePort.close(port1)
    await_data_clone_error(fn -> MessagePort.post_message(port2, "closed") end)
  end

  test "post_message returns clone errors without closing an open sender" do
    {port1, port2} = MessageChannel.new()
    buffer = ArrayBuffer.new("hello")
    ArrayBuffer.detach(buffer)

    assert {:error, %DOMException{name: "DataCloneError"}} =
             raw_request(port1, {:post_message, fn -> :boom end, []})

    assert {:error, %TypeError{}} = raw_request(port1, {:post_message, buffer, []})

    assert_data_clone_error(fn -> MessagePort.post_message(port1, fn -> :boom end) end)
    assert_raise TypeError, fn -> MessagePort.post_message(port1, buffer) end
    assert :ok = MessagePort.post_message(port1, "still-open")

    assert :ok = MessagePort.close(port1)
    await_data_clone_error(fn -> MessagePort.post_message(port2, "closed") end)
  end

  test "ports without onmessage still dispatch message listeners" do
    parent = self()
    {port1, port2} = MessageChannel.new()

    port2 =
      MessagePort.add_event_listener(port2, "message", fn event ->
        send(parent, {:listener_only, event.data})
      end)

    assert :ok = MessagePort.post_message(port1, "listener-only")
    assert_receive {:listener_only, "listener-only"}

    assert :ok = MessagePort.close(port1)
    await_data_clone_error(fn -> MessagePort.post_message(port2, "closed") end)
  end

  test "0-arity onmessage callbacks are invoked on delivery" do
    parent = self()
    {port1, port2} = MessageChannel.new()

    port1 = MessagePort.onmessage(port1, fn -> send(parent, :zero_arity_cb) end)

    assert :ok = MessagePort.post_message(port2, "trigger")
    assert_receive :zero_arity_cb

    assert :ok = MessagePort.close(port1)
    await_data_clone_error(fn -> MessagePort.post_message(port2, "closed") end)
  end

  test "surviving ports close when their sibling server dies" do
    {port1, port2} = MessageChannel.new()
    sibling_pid = Engine.debug_server_pid(port2)

    Process.exit(sibling_pid, :kill)

    await_data_clone_error(fn -> MessagePort.post_message(port1, "boom") end)
  end

  test "owner shutdown tears down the capability handle" do
    parent = self()

    _owner =
      spawn(fn ->
        {port, _peer} = MessageChannel.new()
        send(parent, {:owned_port, port})
      end)

    port =
      receive do
        {:owned_port, port} -> port
      after
        1_000 -> flunk("expected owned port")
      end

    await_data_clone_error(fn -> MessagePort.onmessage(port) end)
  end

  test "symbol protocol supports async dispose and iterator for ports" do
    {port1, port2} = MessageChannel.new()

    assert :unsupported = Web.Symbol.Protocol.symbol(port1, Symbol.iterator(), [])
    assert :ok = Web.Symbol.Protocol.symbol(port1, Symbol.async_dispose(), [])

    await_data_clone_error(fn -> MessagePort.post_message(port1, "boom") end)
    await_data_clone_error(fn -> MessagePort.post_message(port2, "boom") end)
  end

  test "internal message port guards reject closed and malformed traffic" do
    parent = self()
    callback = fn event -> send(parent, {:unexpected_delivery, event.data}) end
    {port, _peer} = MessageChannel.new()
    pid = Engine.debug_server_pid(port)

    :sys.replace_state(pid, &%{&1 | closed: true, onmessage: callback})

    assert_data_clone_error(fn -> MessagePort.onmessage(port) end)
    assert_data_clone_error(fn -> MessagePort.onmessage(port, callback) end)
    assert_data_clone_error(fn -> MessagePort.add_event_listener(port, "message", callback) end)

    assert_data_clone_error(fn ->
      MessagePort.remove_event_listener(port, "message", callback)
    end)

    assert_data_clone_error(fn ->
      MessagePort.dispatch_event(port, MessageEvent.new("message", data: "bad", target: port))
    end)

    assert_data_clone_error(fn -> Engine.ensure_transferable(port) end)

    assert_raw_data_clone_error(
      raw_request(port, {:post_message, StructuredData.serialize("closed"), []})
    )

    assert_raw_data_clone_error(raw_request_with_token(port, make_ref(), :unexpected_call))
    assert_raw_data_clone_error(raw_request(port, {:transfer, self()}))
    assert_raw_data_clone_error(raw_request(port, :unexpected_call))

    assert :ok = raw_cast(port, {:deliver, StructuredData.serialize("ignored")})
    assert :ok = raw_cast(port, :unexpected_cast)
    refute_receive {:unexpected_delivery, _}

    assert :ok = raw_request(port, :close)
    await_process_exit(pid)
  end

  test "internal message port accepts legacy envelope wrappers and ignores malformed ones" do
    parent = self()
    {port1, port2} = MessageChannel.new()

    port2 =
      MessagePort.onmessage(port2, fn event ->
        send(parent, {:legacy_wrapper_delivery, event.data})
      end)

    assert :ok = legacy_raw_request(port1, {:post_message, "legacy-call", []})
    assert_receive {:legacy_wrapper_delivery, "legacy-call"}

    assert :ok = legacy_raw_cast(port2, {:deliver, StructuredData.serialize("legacy-cast")})
    assert_receive {:legacy_wrapper_delivery, "legacy-cast"}

    assert_raw_data_clone_error(legacy_raw_request(port1, :malformed_wrapper))

    assert :ok = malformed_legacy_raw_cast(port2, :ignored)
    refute_receive {:legacy_wrapper_delivery, "ignored"}

    assert :ok = MessagePort.close(port1)
    await_data_clone_error(fn -> MessagePort.post_message(port2, "closed") end)
  end

  test "internal message port callback clauses accept legacy envelope wrappers" do
    {port, peer} = MessageChannel.new()
    pid = Engine.debug_server_pid(port)
    state = :sys.get_state(pid)
    envelope = Envelope.new(port.token, :debug_server_pid, Snapshot.take())
    from = {self(), make_ref()}

    assert {:reply, test_pid, ^state} = Engine.handle_call({:envelope, envelope}, from, state)
    assert test_pid == self()

    assert {:reply, {:error, %DOMException{name: "DataCloneError"}}, ^state} =
             Engine.handle_call({:envelope, :bad}, from, state)

    assert {:noreply, ^state} =
             Engine.handle_cast({:envelope, Envelope.new(port.token, :noop)}, state)

    assert {:noreply, ^state} = Engine.handle_cast({:envelope, :bad}, state)

    assert :ok = MessagePort.close(port)
    await_data_clone_error(fn -> MessagePort.post_message(peer, "closed") end)
  end

  test "internal peer validation rejects missing and dead peers" do
    {ensure_port, _peer} = MessageChannel.new()
    ensure_pid = Engine.debug_server_pid(ensure_port)
    :sys.replace_state(ensure_pid, &%{&1 | peer_pid: nil, peer_token: nil, peer_monitor: nil})
    assert_data_clone_error(fn -> Engine.ensure_transferable(ensure_port) end)
    refute Process.alive?(ensure_pid)

    {post_port, _peer} = MessageChannel.new()
    post_pid = Engine.debug_server_pid(post_port)
    :sys.replace_state(post_pid, &%{&1 | peer_pid: nil, peer_token: nil, peer_monitor: nil})
    assert_data_clone_error(fn -> MessagePort.post_message(post_port, "boom") end)
    refute Process.alive?(post_pid)

    {transfer_port, _peer} = MessageChannel.new()
    transfer_pid = Engine.debug_server_pid(transfer_port)
    :sys.replace_state(transfer_pid, &%{&1 | peer_pid: nil, peer_token: nil, peer_monitor: nil})
    assert_raw_data_clone_error(raw_request(transfer_port, {:transfer, self()}))
    refute Process.alive?(transfer_pid)

    {dead_peer_port, _peer} = MessageChannel.new()
    dead_peer_pid = Engine.debug_server_pid(dead_peer_port)
    dead_pid = spawn(fn -> :ok end)
    await_process_exit(dead_pid)

    :sys.replace_state(dead_peer_pid, fn state ->
      %{state | peer_pid: dead_pid, peer_token: make_ref(), peer_monitor: nil}
    end)

    assert_data_clone_error(fn -> Engine.ensure_transferable(dead_peer_port) end)
    refute Process.alive?(dead_peer_pid)
  end

  test "local ensure_transferable raises for closed and invalid embedded state" do
    key = {Engine, :local_state}
    on_exit(fn -> Process.delete(key) end)

    {closed_port, closed_peer} = MessageChannel.new()
    closed_state = :sys.get_state(Engine.debug_server_pid(closed_port))

    Process.put(key, %{
      key: {closed_port.address, closed_port.token},
      state: %{closed_state | closed: true}
    })

    assert_data_clone_error(fn -> Engine.ensure_transferable(closed_port) end)

    {invalid_port, invalid_peer} = MessageChannel.new()
    invalid_state = :sys.get_state(Engine.debug_server_pid(invalid_port))

    Process.put(key, %{
      key: {invalid_port.address, invalid_port.token},
      state: %{invalid_state | peer_pid: nil, peer_token: nil, peer_monitor: nil}
    })

    assert_data_clone_error(fn -> Engine.ensure_transferable(invalid_port) end)
    assert %{state: %{closed: true}} = Process.get(key)

    assert :ok = MessagePort.close(closed_port)
    await_data_clone_error(fn -> MessagePort.post_message(closed_peer, "closed") end)

    assert :ok = MessagePort.close(invalid_port)
    await_data_clone_error(fn -> MessagePort.post_message(invalid_peer, "closed") end)
  end

  test "raw transfer requests validate recipients and transferred handles" do
    {port, _peer} = MessageChannel.new()

    dead_pid = spawn(fn -> :ok end)
    await_process_exit(dead_pid)

    assert_raw_data_clone_error(raw_request(port, {:transfer, dead_pid}))
    assert_raw_data_clone_error(raw_request(port, {:transfer, :not_a_pid}))

    {foreign_port, _foreign_peer} = MessageChannel.new()
    spoofed_foreign_port = %{foreign_port | token: make_ref()}

    assert_raw_data_clone_error(raw_request(port, {:post_message, "ok", [spoofed_foreign_port]}))

    {transfer_port, _transfer_peer} = MessageChannel.new()

    serialized =
      StructuredData.serialize(%{"other" => foreign_port},
        transfer: [foreign_port],
        message_port_recipient: self()
      )

    assert %{"other" => %MessagePort{}} = StructuredData.deserialize(serialized)
    await_data_clone_error(fn -> MessagePort.post_message(foreign_port, "boom") end)

    assert :ok = raw_request(port, {:post_message, "ok", [transfer_port]})
  end

  test "unexpected serialization failures crash the sender and restore prior local state" do
    parent = self()
    {port1, port2} = MessageChannel.new()
    sender_pid = Engine.debug_server_pid(port1)
    sender_ref = Process.monitor(sender_pid)
    sentinel = %{key: :sentinel, state: :sentinel}

    :sys.replace_state(sender_pid, fn state ->
      Process.put({Engine, :local_state}, sentinel)
      state
    end)

    log =
      capture_log(fn ->
        assert_data_clone_error(fn ->
          MessagePort.post_message(port1, "boom", [%MessagePort{}])
        end)

        assert_receive {:DOWN, ^sender_ref, :process, ^sender_pid, _reason}
      end)

    assert log =~ "FunctionClauseError"

    {restored_left, restored_right} = MessageChannel.new()
    restored_pid = Engine.debug_server_pid(restored_left)

    :sys.replace_state(restored_pid, fn state ->
      Process.put({Engine, :local_state}, sentinel)
      state
    end)

    assert :ok = MessagePort.post_message(restored_left, "ok")

    :sys.replace_state(restored_pid, fn state ->
      send(parent, {:restored_local_state, Process.get({Engine, :local_state})})
      state
    end)

    assert_receive {:restored_local_state, ^sentinel}

    assert :ok = MessagePort.close(restored_left)
    await_data_clone_error(fn -> MessagePort.post_message(restored_right, "closed") end)
    await_data_clone_error(fn -> MessagePort.post_message(port2, "closed") end)
  end

  test "MessagePort values remain valid transferables alongside other transferables" do
    parent = self()
    {port1, port2} = MessageChannel.new()
    {transfer_port, sibling} = MessageChannel.new()
    buffer = ArrayBuffer.new("hello")

    port2 =
      MessagePort.onmessage(port2, fn event ->
        transferred = event.data["port"]
        send(parent, {:buffer_length, ArrayBuffer.byte_length(event.data["buffer"])})
        assert :ok = MessagePort.post_message(transferred, "mixed-transfer")
      end)

    sibling =
      MessagePort.onmessage(sibling, fn event ->
        send(parent, {:mixed_transfer, event.data})
      end)

    assert :ok =
             MessagePort.post_message(
               port1,
               %{"buffer" => buffer, "port" => transfer_port},
               [buffer, transfer_port]
             )

    assert_receive {:buffer_length, 5}
    assert_receive {:mixed_transfer, "mixed-transfer"}

    assert :ok = MessagePort.close(port1)
    await_data_clone_error(fn -> MessagePort.post_message(port2, "closed") end)
    await_data_clone_error(fn -> MessagePort.post_message(sibling, "closed") end)
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

  defp raw_request(%MessagePort{} = port, body, timeout \\ 100) do
    reply_ref = make_ref()

    send(port.address, {:"$gen_call", {self(), reply_ref}, Envelope.new(port.token, body)})

    receive do
      {^reply_ref, reply} -> reply
    after
      timeout -> flunk("expected raw request reply")
    end
  end

  defp raw_cast(%MessagePort{} = port, body) do
    send(port.address, {:"$gen_cast", Envelope.new(port.token, body)})
    :ok
  end

  defp raw_request_with_token(%MessagePort{} = port, token, body, timeout \\ 100) do
    reply_ref = make_ref()

    send(port.address, {:"$gen_call", {self(), reply_ref}, Envelope.new(token, body)})

    receive do
      {^reply_ref, reply} -> reply
    after
      timeout -> flunk("expected raw request reply")
    end
  end

  defp legacy_raw_request(%MessagePort{} = port, body, timeout \\ 100) do
    reply_ref = make_ref()

    send(
      port.address,
      {:"$gen_call", {self(), reply_ref}, {:envelope, Envelope.new(port.token, body)}}
    )

    receive do
      {^reply_ref, reply} -> reply
    after
      timeout -> flunk("expected legacy raw request reply")
    end
  end

  defp legacy_raw_cast(%MessagePort{} = port, body) do
    send(port.address, {:"$gen_cast", {:envelope, Envelope.new(port.token, body)}})
    :ok
  end

  defp malformed_legacy_raw_cast(%MessagePort{} = port, body) do
    send(port.address, {:"$gen_cast", {:envelope, body}})
    :ok
  end

  defp await_process_exit(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      100 -> flunk("expected process to exit")
    end
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
