defmodule Web.MessagePortTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Web.ArrayBuffer
  alias Web.AsyncContext.Snapshot
  alias Web.AsyncContext.Variable
  alias Web.DOMException
  alias Web.Internal.MessagePort, as: Engine
  alias Web.Internal.StructuredData
  alias Web.MessageChannel
  alias Web.MessageEvent
  alias Web.MessagePort

  doctest Web.MessagePort
  doctest Web.MessageChannel
  doctest Web.MessageEvent

  describe "MessageEvent.new/2" do
    test "has the members of MessageEventInit, and no target" do
      {port1, _port2} = channel()

      event =
        MessageEvent.new(:message,
          data: %{id: 1},
          origin: "node://a@b",
          last_event_id: "7",
          source: :a_source,
          ports: [port1],
          target: port1,
          current_target: port1
        )

      assert %MessageEvent{
               type: "message",
               data: %{id: 1},
               origin: "node://a@b",
               last_event_id: "7",
               source: :a_source,
               ports: [^port1],
               target: nil,
               current_target: nil
             } = event
    end

    test "is an Event: it has the fields of EventInit and of Event" do
      before = Web.Performance.now()
      event = MessageEvent.new("message", bubbles: true, cancelable: true, composed: true)

      assert %MessageEvent{bubbles: true, cancelable: true, composed: true, is_trusted: false} =
               event

      assert event.time_stamp >= before

      assert %MessageEvent{bubbles: false, cancelable: false, composed: false} =
               MessageEvent.new(:m)
    end

    test "the functions of Web.Event accept it" do
      event = MessageEvent.new("message", cancelable: true)

      assert Web.Event.event_phase(event) == 0
      assert Web.Event.current_target(event) == nil
      assert Web.Event.composed_path(event) == []
      assert Web.Event.src_element(event) == nil

      :ok = Web.Event.prevent_default(event)
      assert Web.Event.default_prevented?(event)
      refute Web.Event.return_value?(event)

      :ok = Web.Event.stop_propagation(event)
      assert Web.Event.cancel_bubble?(event)

      again = Web.Event.init_event(event, "again", true, false)
      assert %MessageEvent{type: "again", bubbles: true, cancelable: false} = again
      refute Web.Event.default_prevented?(again)
      refute Web.Event.cancel_bubble?(again)
    end

    test "init_message_event/9 initializes the event again, as initMessageEvent()" do
      {port1, _port2} = channel()
      event = MessageEvent.new("message", data: :old, origin: "node://a@b")
      :ok = Web.Event.prevent_default(event)

      assert %MessageEvent{
               type: "message",
               bubbles: false,
               cancelable: false,
               data: nil,
               origin: "",
               last_event_id: "",
               source: nil,
               ports: []
             } = MessageEvent.init_message_event(event, "message")

      assert %MessageEvent{
               type: "x",
               bubbles: true,
               cancelable: true,
               data: 1,
               origin: "o",
               last_event_id: "7",
               source: :s,
               ports: [^port1]
             } = MessageEvent.init_message_event(event, :x, true, true, 1, "o", "7", :s, [port1])

      # Each argument after the type has its default value of Web IDL.
      arguments = [true, true, :data, "o", "7", :s, [port1]]

      for count <- 1..7 do
        given = Enum.take(arguments, count)
        initialized = apply(MessageEvent, :init_message_event, [event, "m" | given])

        assert Enum.take(
                 [
                   initialized.bubbles,
                   initialized.cancelable,
                   initialized.data,
                   initialized.origin,
                   initialized.last_event_id,
                   initialized.source,
                   initialized.ports
                 ],
                 count
               ) == given
      end

      # During a dispatch, the event does not change.
      Web.Event.__put_flag__(event, :dispatch, 1)
      assert MessageEvent.init_message_event(event, "y", true) == event
    end
  end

  describe "the events of a port" do
    test "message, messageerror, and close are trusted" do
      {port1, port2} = channel()
      MessagePort.onmessage(port2, forward(:message))
      MessagePort.onmessageerror(port2, forward(:error))
      MessagePort.onclose(port2, forward(:close))

      :ok = MessagePort.post_message(port1, :hello)
      assert_receive {:message, %MessageEvent{type: "message", is_trusted: true}}

      # A record that is not correct: see the test of messageerror.
      record = %StructuredData.Record{
        plain: false,
        value: %StructuredData.Node{type: :regex, key: nil, data: {"(", []}}
      }

      link = :sys.get_state(port1.address).link
      send(port2.address, {:port_message, link, %{record: record, snapshot: Snapshot.new()}})
      assert_receive {:error, %MessageEvent{type: "messageerror", is_trusted: true}}

      :ok = MessagePort.close(port1)
      assert_receive {:close, %Web.Event{type: "close", is_trusted: true}}
    end

    test "during a listener, the event has the phase AT_TARGET and the current target" do
      {port1, port2} = channel()
      test = self()

      MessagePort.onmessage(port2, fn event ->
        send(test, {:during, Web.Event.event_phase(event), Web.Event.current_target(event)})
        send(test, {:path, Web.Event.composed_path(event), event})
      end)

      :ok = MessagePort.post_message(port1, :hello)
      assert_receive {:during, 2, ^port2}
      assert_receive {:path, [^port2], event}

      # After the dispatch, the event has no phase and no current target.
      assert Web.Event.event_phase(event) == 0
      assert Web.Event.current_target(event) == nil
    end

    test "stop_immediate_propagation/1 stops the listeners after the listener" do
      {port1, port2} = channel()
      test = self()

      port2
      |> MessagePort.add_event_listener("message", fn event ->
        send(test, :first)
        Web.Event.stop_immediate_propagation(event)
      end)
      |> MessagePort.add_event_listener("message", fn -> send(test, :second) end)
      |> MessagePort.add_event_listener("close", fn -> send(test, :closed) end)
      |> MessagePort.start()

      :ok = MessagePort.post_message(port1, :hello)
      :ok = MessagePort.close(port1)

      # The close comes after the message: the second listener did not run.
      assert_receive :first
      assert_receive :closed
      refute_received :second
    end

    test "dispatch_event/2 gives an event that is not trusted" do
      {_port1, port2} = channel()
      MessagePort.add_event_listener(port2, "ping", forward(:ping))

      trusted = %{Web.Event.new("ping") | is_trusted: true}
      assert {^port2, true} = MessagePort.dispatch_event(port2, trusted)
      assert_receive {:ping, %Web.Event{type: "ping", is_trusted: false}}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Makes a channel, and closes its ports at the end of the test.
  defp channel do
    %{port1: port1, port2: port2} = MessageChannel.new()

    on_exit(fn ->
      MessagePort.close(port1)
      MessagePort.close(port2)
    end)

    {port1, port2}
  end

  # A callback that sends the event to the test process.
  defp forward(tag) do
    test = self()
    fn event -> send(test, {tag, event}) end
  end

  defp forward_data(tag) do
    test = self()
    fn event -> send(test, {tag, event.data}) end
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  defp listener_pid(%MessagePort{address: pid}), do: :sys.get_state(pid).target.listener

  defp data_clone_error(fun) do
    exception = assert_raise DOMException, fun
    assert exception.name == "DataCloneError"
    exception.message
  end

  # ---------------------------------------------------------------------------
  # The public functions
  # ---------------------------------------------------------------------------

  test "the module has the functions of the Standard" do
    assert Enum.sort(MessagePort.__info__(:functions)) == [
             {:__struct__, 0},
             {:__struct__, 1},
             {:add_event_listener, 3},
             {:add_event_listener, 4},
             {:close, 1},
             {:dispatch_event, 2},
             {:onclose, 1},
             {:onclose, 2},
             {:onmessage, 1},
             {:onmessage, 2},
             {:onmessageerror, 1},
             {:onmessageerror, 2},
             {:post_message, 2},
             {:post_message, 3},
             {:remove_event_listener, 3},
             {:start, 1}
           ]
  end

  test "a channel has two different ports, as port1 and port2" do
    {port1, port2} = channel()
    assert %MessageChannel{port1: %MessagePort{}, port2: %MessagePort{}} = MessageChannel.new()

    assert %MessagePort{} = port1
    assert %MessagePort{} = port2
    refute port1 == port2
    assert Process.alive?(port1.address)
  end

  # ---------------------------------------------------------------------------
  # Messages
  # ---------------------------------------------------------------------------

  describe "a message" do
    test "arrives at the other port as an event" do
      {port1, port2} = channel()
      MessagePort.onmessage(port2, forward(:port2))
      MessagePort.onmessage(port1, forward(:port1))

      assert :ok = MessagePort.post_message(port1, %{status: :ok, list: [1, {2, "three"}]})

      assert_receive {:port2, %MessageEvent{} = event}
      assert event.type == "message"
      assert event.data == %{status: :ok, list: [1, {2, "three"}]}
      assert event.origin == ""
      assert event.ports == []
      assert event.target == port2
      assert event.current_target == port2

      # The sender does not get its message.
      refute_receive {:port1, _event}, 30
    end

    test "the two directions are independent" do
      {port1, port2} = channel()
      MessagePort.onmessage(port1, forward_data(:port1))
      MessagePort.onmessage(port2, forward_data(:port2))

      MessagePort.post_message(port1, "to 2")
      MessagePort.post_message(port2, "to 1")

      assert_receive {:port2, "to 2"}
      assert_receive {:port1, "to 1"}
    end

    test "a callback with no argument is called" do
      {port1, port2} = channel()
      test = self()
      MessagePort.onmessage(port2, fn -> send(test, :called) end)

      MessagePort.post_message(port1, "trigger")

      assert_receive :called
    end

    test "the messages arrive in the sequence of the calls" do
      {port1, port2} = channel()
      MessagePort.onmessage(port2, forward_data(:got))

      Enum.each(1..200, &MessagePort.post_message(port1, &1))

      for index <- 1..200 do
        assert_receive {:got, ^index}
      end
    end

    test "a listener can answer on the port that got the message" do
      {port1, port2} = channel()
      MessagePort.onmessage(port1, forward_data(:answer))

      MessagePort.onmessage(port2, fn event ->
        MessagePort.post_message(event.target, String.upcase(event.data))
      end)

      MessagePort.post_message(port1, "hello")

      assert_receive {:answer, "HELLO"}
    end

    test "two ports can send to each other from their listeners" do
      {port1, port2} = channel()
      test = self()

      MessagePort.onmessage(port1, fn event ->
        if event.data < 20 do
          MessagePort.post_message(port1, event.data + 1)
        else
          send(test, {:done, event.data})
        end
      end)

      MessagePort.onmessage(port2, fn event ->
        MessagePort.post_message(port2, event.data + 1)
      end)

      MessagePort.post_message(port1, 1)

      assert_receive {:done, 20}
    end

    test "the listener runs in the async context of the sender" do
      {port1, port2} = channel()
      test = self()
      request_id = Variable.new(name: "request_id")

      MessagePort.onmessage(port2, fn _event ->
        send(test, {:request_id, Variable.get(request_id)})
      end)

      Variable.run(request_id, "req-42", fn ->
        MessagePort.post_message(port1, "with context")
      end)

      MessagePort.post_message(port1, "no context")

      assert_receive {:request_id, "req-42"}
      assert_receive {:request_id, nil}
    end

    test "the transfer list can be a keyword list" do
      {port1, port2} = channel()
      MessagePort.onmessage(port2, forward_data(:got))
      buffer = ArrayBuffer.new("bytes")

      assert :ok = MessagePort.post_message(port1, buffer, transfer: [buffer])

      assert_receive {:got, %ArrayBuffer{} = moved}
      assert to_string(moved) == "bytes"
      assert ArrayBuffer.detached?(buffer)
    end

    test "a message that cannot be cloned raises, and changes nothing" do
      {port1, port2} = channel()
      MessagePort.onmessage(port2, forward_data(:got))
      buffer = ArrayBuffer.new("bytes")

      assert data_clone_error(fn -> MessagePort.post_message(port1, self()) end) ==
               "A pid cannot be cloned."

      data_clone_error(fn -> MessagePort.post_message(port1, fn -> :ok end, [buffer]) end)
      refute ArrayBuffer.detached?(buffer)

      # The port continues.
      MessagePort.post_message(port1, "next")
      assert_receive {:got, "next"}
    end

    test "a message that cannot be made gives the event messageerror" do
      {port1, port2} = channel()
      MessagePort.onmessageerror(port2, forward(:error))
      MessagePort.onmessage(port2, forward(:message))

      # A record that is not correct: only a fault of the library, or a
      # different version on a different node, can make one.
      record = %StructuredData.Record{
        plain: false,
        value: %StructuredData.Node{type: :regex, key: nil, data: {"(", []}}
      }

      link = :sys.get_state(port1.address).link
      send(port2.address, {:port_message, link, %{record: record, snapshot: snapshot()}})

      assert_receive {:error, %MessageEvent{type: "messageerror", target: ^port2}}
      refute_receive {:message, _event}, 30
      assert is_function(MessagePort.onmessageerror(port2), 1)
    end
  end

  defp snapshot, do: Snapshot.new()

  # ---------------------------------------------------------------------------
  # The port message queue
  # ---------------------------------------------------------------------------

  describe "the port message queue" do
    test "keeps the messages until onmessage sets a callback" do
      {port1, port2} = channel()

      MessagePort.post_message(port1, "first")
      MessagePort.post_message(port1, "second")
      # The two messages wait in the queue of the second port.
      eventually(fn -> :queue.len(:sys.get_state(port2.address).queue) == 2 end)

      MessagePort.onmessage(port2, forward_data(:got))

      assert_receive {:got, "first"}
      assert_receive {:got, "second"}
    end

    test "add_event_listener does not start the port, and start does" do
      {port1, port2} = channel()
      MessagePort.add_event_listener(port2, "message", forward_data(:got))

      MessagePort.post_message(port1, "kept")
      refute_receive {:got, _data}, 50

      assert :ok = MessagePort.start(port2)
      assert_receive {:got, "kept"}

      # A second call has no effect.
      assert :ok = MessagePort.start(port2)
      MessagePort.post_message(port1, "next")
      assert_receive {:got, "next"}
      refute_receive {:got, _data}, 30
    end

    test "a callback of nil does not start the port" do
      {port1, port2} = channel()
      MessagePort.add_event_listener(port2, "message", forward_data(:got))
      MessagePort.onmessage(port2, nil)

      MessagePort.post_message(port1, "kept")
      refute_receive {:got, _data}, 50
    end

    test "a slow listener gets each message, one at a time" do
      {port1, port2} = channel()
      test = self()

      MessagePort.onmessage(port2, fn event ->
        send(test, {:start, event.data})
        Process.sleep(5)
        send(test, {:end, event.data})
      end)

      Enum.each(1..10, &MessagePort.post_message(port1, &1))

      for index <- 1..10 do
        assert_receive {:start, ^index}
        assert_receive {:end, ^index}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Listeners and event handlers
  # ---------------------------------------------------------------------------

  describe "listeners" do
    test "the event handler has the place of its first callback" do
      {port1, port2} = channel()
      test = self()
      note = fn name -> fn _event -> send(test, name) end end

      port2
      |> MessagePort.add_event_listener("message", note.(:listener_a))
      |> MessagePort.onmessage(note.(:handler))
      |> MessagePort.add_event_listener("message", note.(:listener_b))

      MessagePort.post_message(port1, 1)
      assert_receive :listener_a
      assert_receive :handler
      assert_receive :listener_b
      assert {:messages, []} = Process.info(self(), :messages)

      # A new callback, and a callback after nil, use the same place.
      MessagePort.onmessage(port2, note.(:handler_2))
      MessagePort.post_message(port1, 2)
      assert_receive :listener_a
      assert_receive :handler_2
      assert_receive :listener_b

      MessagePort.onmessage(port2, nil)
      assert MessagePort.onmessage(port2) == nil
      MessagePort.post_message(port1, 3)
      assert_receive :listener_a
      assert_receive :listener_b

      MessagePort.onmessage(port2, note.(:handler_3))
      MessagePort.post_message(port1, 4)
      assert_receive :listener_a
      assert_receive :handler_3
      assert_receive :listener_b
    end

    test "the functions that read and set a callback" do
      {_port1, port2} = channel()
      callback = fn _event -> :ok end

      assert MessagePort.onmessage(port2) == nil
      assert MessagePort.onmessage(port2, callback) == port2
      assert MessagePort.onmessage(port2) == callback

      assert MessagePort.onclose(port2) == nil
      assert MessagePort.onclose(port2, callback) == port2
      assert MessagePort.onclose(port2) == callback

      assert MessagePort.onmessageerror(port2) == nil
      assert MessagePort.onmessageerror(port2, callback) == port2
      assert MessagePort.onmessageerror(port2) == callback

      assert_raise Web.TypeError, ~r/must be a function/, fn ->
        MessagePort.onmessage(port2, :not_a_function)
      end

      assert_raise Web.TypeError, fn -> MessagePort.onclose(port2, fn _a, _b -> :ok end) end
    end

    test "a listener can be removed, and the option :once removes it after one event" do
      {port1, port2} = channel()
      removed = forward_data(:removed)

      port2
      |> MessagePort.add_event_listener("message", forward_data(:kept))
      |> MessagePort.add_event_listener("message", removed)
      |> MessagePort.add_event_listener(:message, forward_data(:once), once: true)
      |> MessagePort.remove_event_listener("message", removed)
      |> MessagePort.start()

      MessagePort.post_message(port1, 1)
      MessagePort.post_message(port1, 2)

      assert_receive {:kept, 1}
      assert_receive {:once, 1}
      assert_receive {:kept, 2}
      refute_receive {:once, 2}, 30
      refute_received {:removed, _data}
    end

    test "the option :signal removes the listener at the abort" do
      {port1, port2} = channel()
      controller = Web.AbortController.new()

      port2
      |> MessagePort.add_event_listener("message", forward_data(:got), signal: controller.signal)
      |> MessagePort.start()

      MessagePort.post_message(port1, 1)
      assert_receive {:got, 1}

      Web.AbortController.abort(controller)
      eventually(fn -> :sys.get_state(listener_pid(port2)).listeners == %{} end)

      MessagePort.post_message(port1, 2)
      refute_receive {:got, 2}, 50
    end

    test "dispatch_event gives an event to the listeners" do
      {_port1, port2} = channel()
      MessagePort.add_event_listener(port2, "custom", forward(:custom))

      event = Web.CustomEvent.new("custom", detail: 7)
      assert {^port2, true} = MessagePort.dispatch_event(port2, event)

      assert_receive {:custom, ^event}

      assert {^port2, true} = Web.EventTarget.dispatch_event(port2, event)
      assert_receive {:custom, ^event}
    end

    test "a listener that raises goes to the log, and the port continues" do
      {port1, port2} = channel()
      test = self()

      port2
      |> MessagePort.onmessage(fn event ->
        if event.data == :bad, do: raise("the listener failed")
        send(test, {:first, event.data})
      end)
      |> MessagePort.add_event_listener("message", fn event ->
        if event.data == :bad, do: throw(:thrown), else: send(test, {:second, event.data})
      end)
      |> MessagePort.add_event_listener("message", forward_data(:third))

      log =
        capture_log(fn ->
          MessagePort.post_message(port1, :bad)
          # Each other listener of the event runs.
          assert_receive {:third, :bad}
        end)

      assert log =~ ~s(A listener of the event "message" failed.)
      assert log =~ "the listener failed"
      assert log =~ "(throw) :thrown"

      MessagePort.post_message(port1, :good)
      assert_receive {:first, :good}
      assert_receive {:second, :good}
      assert_receive {:third, :good}
      assert Process.alive?(port2.address)
    end

    test "a listener can change the callbacks of its port" do
      {port1, port2} = channel()
      test = self()

      MessagePort.onmessage(port2, fn event ->
        send(test, {:first, event.data})
        MessagePort.onmessage(event.target, fn next -> send(test, {:second, next.data}) end)
      end)

      MessagePort.post_message(port1, 1)
      MessagePort.post_message(port1, 2)

      assert_receive {:first, 1}
      assert_receive {:second, 2}
    end
  end

  # ---------------------------------------------------------------------------
  # Close
  # ---------------------------------------------------------------------------

  describe "close" do
    test "the other port gets the event close, after the messages" do
      {port1, port2} = channel()
      MessagePort.onclose(port1, forward(:close1))
      MessagePort.onclose(port2, forward(:close2))
      MessagePort.onmessage(port2, forward_data(:got))

      MessagePort.post_message(port1, "last words")
      assert :ok = MessagePort.close(port1)

      assert_receive {:got, "last words"}
      assert_receive {:close2, %Web.Event{type: "close", target: ^port2}}

      # The port that closed gets no event.
      refute_receive {:close1, _event}, 30
    end

    test "a port that did not start gets the event close immediately" do
      {port1, port2} = channel()
      test = self()

      port2
      |> MessagePort.add_event_listener("message", fn event -> send(test, event.data) end)
      |> MessagePort.add_event_listener("close", fn -> send(test, :close) end)

      MessagePort.post_message(port1, 1)
      MessagePort.close(port1)

      assert_receive :close
      refute_received 1

      # The message is in the queue until the port starts.
      MessagePort.start(port2)
      assert_receive 1
      refute_receive :close, 30
    end

    test "the new holder of a port whose peer closed gets the event close" do
      {port1, port2} = channel()
      MessagePort.post_message(port1, "last words")
      MessagePort.close(port1)
      eventually(fn -> :sys.get_state(port2.address).peer == nil end)

      moved = Web.structured_clone(port2, transfer: [port2])
      MessagePort.onclose(moved, forward(:close))
      MessagePort.onmessage(moved, forward_data(:got))

      assert_receive {:got, "last words"}
      assert_receive {:close, %Web.Event{target: ^moved}}
      refute_receive {:close, _event}, 30
      MessagePort.close(moved)
    end

    test "a closed port has no effect and gives no error" do
      {port1, port2} = channel()
      MessagePort.onmessage(port2, forward_data(:got))
      callback = fn _event -> :ok end

      assert :ok = MessagePort.close(port1)
      assert :ok = MessagePort.close(port1)
      eventually(fn -> not Process.alive?(port1.address) end)

      assert :ok = MessagePort.post_message(port1, "nothing")
      assert :ok = MessagePort.start(port1)
      assert MessagePort.onmessage(port1, callback) == port1
      assert MessagePort.onmessage(port1) == nil
      assert MessagePort.add_event_listener(port1, "message", callback) == port1
      assert MessagePort.remove_event_listener(port1, "message", callback) == port1
      assert {^port1, true} = MessagePort.dispatch_event(port1, %{type: "message"})

      refute_receive {:got, _data}, 30
    end

    test "a message to a closed port is dropped" do
      {port1, port2} = channel()
      MessagePort.onclose(port1, forward(:close))

      MessagePort.close(port2)
      assert_receive {:close, _event}

      assert :ok = MessagePort.post_message(port1, "nothing")
      assert Process.alive?(port1.address)
    end

    test "a port delivers no event after close returns" do
      {port1, port2} = channel()
      test = self()

      MessagePort.onmessage(port2, fn event ->
        send(test, {:got, event.data})

        # The test lets the callback continue when the other messages are in
        # the queue.
        receive do
          :continue -> :ok
        end

        MessagePort.close(event.target)
        send(test, :closed)
      end)

      Enum.each(1..20, &MessagePort.post_message(port1, &1))

      assert_receive {:got, 1}
      eventually(fn -> :queue.len(:sys.get_state(port2.address).queue) == 19 end)
      send(listener_pid(port2), :continue)
      assert_receive :closed
      refute_receive {:got, _data}, 80
    end

    test "the processes of a port stop after close" do
      {port1, port2} = channel()
      server = port1.address
      listener = listener_pid(port1)

      MessagePort.close(port1)

      eventually(fn -> not Process.alive?(server) and not Process.alive?(listener) end)
      assert Process.alive?(port2.address)
    end

    test "the ports close when their holder stops" do
      test = self()

      holder =
        spawn(fn ->
          send(test, {:ports, MessageChannel.new()})
          Process.sleep(:infinity)
        end)

      assert_receive {:ports, %MessageChannel{port1: port1, port2: port2}}

      # The test process becomes the holder of the second port.
      moved = Web.structured_clone(port2, transfer: [port2])
      MessagePort.onclose(moved, forward(:close))
      MessagePort.start(moved)

      Process.exit(holder, :kill)

      assert_receive {:close, %Web.Event{type: "close"}}
      eventually(fn -> not Process.alive?(port1.address) end)
      assert Process.alive?(moved.address)

      MessagePort.close(moved)
    end

    test "a port gets the event close when the server of the other port is killed" do
      {port1, port2} = channel()
      MessagePort.onclose(port1, forward(:close))
      MessagePort.start(port1)

      Process.exit(port2.address, :kill)

      assert_receive {:close, _event}
      assert :ok = MessagePort.post_message(port1, "nothing")
    end

    test "Symbol.dispose closes the port" do
      {port1, port2} = channel()
      MessagePort.onclose(port2, forward(:close))

      assert :ok = Web.Symbol.Protocol.symbol(port1, Web.Symbol.dispose(), [])
      assert_receive {:close, _event}

      assert :ok = Web.Symbol.Protocol.symbol(port2, Web.Symbol.async_dispose(), [])
      assert :unsupported = Web.Symbol.Protocol.symbol(port2, Web.Symbol.iterator(), [])
    end
  end

  # ---------------------------------------------------------------------------
  # Transfer
  # ---------------------------------------------------------------------------

  describe "a transfer" do
    test "moves a port to the listener that gets the message" do
      {port1, port2} = channel()
      {moved, other} = channel()
      test = self()

      MessagePort.onmessage(other, forward_data(:other))

      MessagePort.onmessage(port2, fn event ->
        send(test, {:event, event})
        [port] = event.ports
        MessagePort.post_message(port, "from the new holder")
      end)

      assert :ok = MessagePort.post_message(port1, %{"port" => moved}, [moved])

      assert_receive {:event, %MessageEvent{data: %{"port" => new_handle}, ports: [new_handle]}}
      assert_receive {:other, "from the new holder"}
      assert new_handle.address == moved.address
      refute new_handle == moved

      # The first handle is detached: it has no effect, and it cannot move.
      assert :ok = MessagePort.post_message(moved, "nothing")
      assert MessagePort.onmessage(moved, fn -> :ok end) == moved
      assert MessagePort.onmessage(moved) == nil
      assert :ok = MessagePort.close(moved)
      refute_receive {:other, _data}, 30
      assert Process.alive?(moved.address)

      assert data_clone_error(fn -> MessagePort.post_message(port1, 1, [moved]) end) =~
               "closed or detached"

      MessagePort.close(new_handle)
    end

    test "a port that is not in the message is in the list of ports of the event" do
      {port1, port2} = channel()
      {moved, _other} = channel()
      MessagePort.onmessage(port2, forward(:event))

      MessagePort.post_message(port1, "no port in the data", [moved])

      assert_receive {:event, %MessageEvent{data: "no port in the data", ports: [port]}}
      assert port.address == moved.address
    end

    test "moves the messages of the queue with the port, and not the listeners" do
      {port1, port2} = channel()
      {moved, other} = channel()

      # The port has a listener, and it did not start: the messages stay in
      # the queue.
      MessagePort.add_event_listener(moved, "message", forward_data(:first_listener))
      MessagePort.post_message(other, "before 1")
      MessagePort.post_message(other, "before 2")

      new_listener = forward_data(:new_listener)

      MessagePort.onmessage(port2, fn event ->
        [port] = event.ports
        MessagePort.onmessage(port, new_listener)
      end)

      MessagePort.post_message(port1, nil, [moved])
      MessagePort.post_message(other, "after")

      assert_receive {:new_listener, "before 1"}
      assert_receive {:new_listener, "before 2"}
      assert_receive {:new_listener, "after"}
      refute_received {:first_listener, _data}
    end

    test "a port cannot transfer itself" do
      {port1, port2} = channel()
      MessagePort.onmessage(port2, forward_data(:got))

      assert data_clone_error(fn -> MessagePort.post_message(port1, "self", [port1]) end) ==
               "A MessagePort cannot transfer itself."

      MessagePort.post_message(port1, "next")
      assert_receive {:got, "next"}
    end

    test "a transfer of the port that gets the message drops the message" do
      {port1, port2} = channel()
      MessagePort.onmessage(port2, forward_data(:got))
      MessagePort.onclose(port1, forward(:close))
      MessagePort.start(port1)

      assert :ok = MessagePort.post_message(port1, "doomed", [port2])

      # The port is lost in the transfer: it closes.
      assert_receive {:close, _event}
      refute_received {:got, _data}
      eventually(fn -> not Process.alive?(port2.address) end)
    end

    test "a closed port moves the values of the transfer list, and the ports are lost" do
      {port1, _port2} = channel()
      {moved, other} = channel()
      buffer = ArrayBuffer.new("bytes")
      MessagePort.onclose(other, forward(:close))
      MessagePort.start(other)
      MessagePort.close(port1)

      assert :ok = MessagePort.post_message(port1, "nothing", [buffer, moved])

      assert ArrayBuffer.detached?(buffer)
      assert_receive {:close, _event}
    end

    test "the holder of the port that gets the message becomes the holder" do
      test = self()
      {moved, other} = channel()
      MessagePort.onclose(other, forward(:close))
      MessagePort.start(other)

      receiver =
        spawn(fn ->
          %{port1: port1, port2: port2} = MessageChannel.new()
          MessagePort.onmessage(port2, fn event -> send(test, {:received, event.ports}) end)
          send(test, {:port, port1})
          Process.sleep(:infinity)
        end)

      assert_receive {:port, port1}
      MessagePort.post_message(port1, "a port for you", [moved])
      assert_receive {:received, [new_handle]}

      eventually(fn -> :sys.get_state(new_handle.address).holder == receiver end)
      refute_received {:close, _event}

      Process.exit(receiver, :kill)
      assert_receive {:close, _event}
    end

    test "a port in a message that is not delivered closes with the port that has it" do
      {port1, port2} = channel()
      {moved, other} = channel()
      MessagePort.onclose(other, forward(:close))
      MessagePort.start(other)

      # The second port did not start: the message stays in its queue.
      MessagePort.post_message(port1, "kept", [moved])
      eventually(fn -> :queue.len(:sys.get_state(port2.address).queue) == 1 end)
      refute_received {:close, _event}

      MessagePort.close(port2)
      assert_receive {:close, _event}
    end

    test "a transfer while messages arrive loses no message" do
      {port1, port2} = channel()
      test = self()
      count = 300

      listen = fn port ->
        MessagePort.onmessage(port, fn event -> send(test, {:got, event.data}) end)
      end

      listen.(port2)

      sender = Task.async(fn -> Enum.each(1..count, &MessagePort.post_message(port1, &1)) end)

      # The transfers occur while the listener process has messages.
      last =
        Enum.reduce(1..25, port2, fn _index, port ->
          moved = Web.structured_clone(port, transfer: [port])
          listen.(moved)
          moved
        end)

      Task.await(sender)

      for index <- 1..count do
        assert_receive {:got, ^index}, 2_000
      end

      refute_receive {:got, _data}, 30
      MessagePort.close(last)
    end

    # Makes the listener process of the port wait in a listener, until the
    # returned function is called. An item that the server gives to the
    # listener process in that time stays in its mailbox.
    defp block_listener(port) do
      test = self()

      MessagePort.add_event_listener(port, "block", fn ->
        send(test, {:blocked, self()})

        receive do
          :continue -> :ok
        end
      end)

      MessagePort.dispatch_event(port, %{type: "block"})
      assert_receive {:blocked, listener}
      fn -> send(listener, :continue) end
    end

    test "an item that the first listener process did not start goes to the new holder" do
      {port1, port2} = channel()
      MessagePort.onmessage(port2, forward_data(:first_holder))
      continue = block_listener(port2)

      Enum.each(1..3, &MessagePort.post_message(port1, &1))
      # The first message is in the mailbox of the listener process.
      eventually(fn ->
        match?({_number, {:message, _}}, :sys.get_state(port2.address).in_flight)
      end)

      moved = Web.structured_clone(port2, transfer: [port2])
      MessagePort.onmessage(moved, forward_data(:new_holder))
      continue.()

      # The messages arrive in their sequence: the message that came back
      # is the first one.
      in_sequence =
        for _index <- 1..3 do
          assert_receive {:new_holder, data}
          data
        end

      assert in_sequence == [1, 2, 3]
      refute_received {:first_holder, _data}
      MessagePort.close(moved)
    end

    test "the new holder gets the event close one time, also when one came back" do
      {port1, port2} = channel()
      MessagePort.onclose(port2, forward(:first_holder))
      MessagePort.start(port2)
      continue = block_listener(port2)

      MessagePort.close(port1)
      # The event close is in the mailbox of the listener process.
      eventually(fn -> match?({_number, :close}, :sys.get_state(port2.address).in_flight) end)

      moved = Web.structured_clone(port2, transfer: [port2])
      MessagePort.onclose(moved, forward(:new_holder))
      MessagePort.start(moved)
      continue.()

      assert_receive {:new_holder, %Web.Event{type: "close"}}
      refute_receive {:new_holder, _event}, 50
      refute_received {:first_holder, _event}
      MessagePort.close(moved)
    end

    test "a handle with a token that is not correct has no effect" do
      {port1, port2} = channel()
      MessagePort.onmessage(port2, forward_data(:got))
      forged = %{port1 | token: make_ref()}

      assert :ok = MessagePort.post_message(forged, "forged")
      assert :ok = MessagePort.close(forged)
      assert MessagePort.onmessage(forged) == nil
      assert :ok = MessagePort.start(forged)

      data_clone_error(fn -> Web.structured_clone(forged, transfer: [forged]) end)

      # A message with a link that is not correct is ignored.
      send(port2.address, {:port_message, make_ref(), %{}})
      send(port2.address, {:port_closed, make_ref()})
      send(port2.address, {:set_holder, make_ref(), self()})
      GenServer.cast(port2.address, :unexpected)
      assert GenServer.call(port2.address, :unexpected) == {:error, :detached}

      assert GenServer.call(port2.address, {port2.token, :unexpected}) ==
               {:error, :unknown_request}

      refute_receive {:got, _data}, 30

      MessagePort.post_message(port1, "real")
      assert_receive {:got, "real"}
    end

    test "a value that is not a handle with a pid has no effect" do
      detached = %MessagePort{address: nil, token: nil}

      assert :ok = MessagePort.post_message(detached, "nothing")
      assert :ok = MessagePort.close(detached)
      assert MessagePort.onmessage(detached) == nil
    end

    test "the engine refuses the transfer of a port that closed" do
      {port1, port2} = channel()
      MessagePort.close(port1)

      data_clone_error(fn -> Engine.ensure_transferable(port1) end)
      data_clone_error(fn -> Engine.detach_transferable(port1, self()) end)

      # A message for a peer that closed is dropped.
      eventually(fn -> :sys.get_state(port2.address).peer == nil end)
      assert GenServer.call(port2.address, {port2.token, {:post, %{}}}) == :dropped
    end

    test "the engine makes a channel for the process that calls it" do
      {port1, port2} = Engine.start_pair()

      assert :sys.get_state(port1.address).holder == self()
      MessagePort.close(port1)
      MessagePort.close(port2)
    end
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  describe "properties" do
    property "each message arrives one time, in sequence, in the two directions" do
      check all(
              to_port2 <- list_of(term_gen(), max_length: 20),
              to_port1 <- list_of(term_gen(), max_length: 20),
              max_runs: 50
            ) do
        %{port1: port1, port2: port2} = MessageChannel.new()
        MessagePort.onmessage(port1, forward_data(:port1))
        MessagePort.onmessage(port2, forward_data(:port2))

        Enum.each(to_port2, &MessagePort.post_message(port1, &1))
        Enum.each(to_port1, &MessagePort.post_message(port2, &1))

        for message <- to_port2, do: assert_receive({:port2, ^message})
        for message <- to_port1, do: assert_receive({:port1, ^message})

        MessagePort.close(port1)
        MessagePort.close(port2)
        refute_received {:port1, _data}
        refute_received {:port2, _data}
      end
    end

    property "a port starts at any time and loses no message" do
      check all(
              messages <- list_of(integer(), max_length: 30),
              start_at <- integer(0..30),
              max_runs: 50
            ) do
        %{port1: port1, port2: port2} = MessageChannel.new()
        MessagePort.add_event_listener(port2, "message", forward_data(:got))

        messages
        |> Enum.with_index()
        |> Enum.each(fn {message, index} ->
          if index == start_at, do: MessagePort.start(port2)
          MessagePort.post_message(port1, message)
        end)

        MessagePort.start(port2)

        for message <- messages, do: assert_receive({:got, ^message})

        MessagePort.close(port1)
        MessagePort.close(port2)
      end
    end

    property "the close of a port leaves no process" do
      check all(count <- integer(1..5), close_first <- boolean(), max_runs: 30) do
        channels = for _index <- 1..count, do: MessageChannel.new()

        pids =
          Enum.flat_map(channels, fn %{port1: port1, port2: port2} ->
            [port1.address, listener_pid(port1), port2.address, listener_pid(port2)]
          end)

        Enum.each(channels, fn %{port1: port1, port2: port2} ->
          if close_first, do: MessagePort.close(port1), else: MessagePort.close(port2)
          if close_first, do: MessagePort.close(port2), else: MessagePort.close(port1)
        end)

        eventually(fn -> not Enum.any?(pids, &Process.alive?/1) end)
      end
    end
  end

  defp term_gen do
    one_of([
      integer(),
      binary(max_length: 8),
      atom(:alphanumeric),
      tuple({integer(), binary(max_length: 4)}),
      map_of(atom(:alphanumeric), integer(), max_length: 3)
    ])
  end
end
