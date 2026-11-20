defmodule Web.BroadcastChannelTest do
  # The tests change the settings of the application, thus they cannot run
  # at the same time as other tests.
  use ExUnit.Case, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog

  doctest Web.BroadcastChannel

  alias Web.ArrayBuffer
  alias Web.AsyncContext.Snapshot
  alias Web.AsyncContext.Variable
  alias Web.BroadcastChannel
  alias Web.BroadcastChannel.Adapter
  alias Web.DOMException
  alias Web.Internal.StructuredData
  alias Web.MessageEvent

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
    settings = [:broadcast_adapter, :broadcast_adapter_spy, :broadcast_governor]
    original = Map.new(settings, &{&1, Application.get_env(:web, &1)})

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> Application.delete_env(:web, key)
        {key, value} -> Application.put_env(:web, key, value)
      end)
    end)

    {:ok, name: "test-#{System.unique_integer([:positive, :monotonic])}"}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Makes a channel, and closes it at the end of the test.
  defp open(name) do
    channel = BroadcastChannel.new(name)
    on_exit(fn -> BroadcastChannel.close(channel) end)
    channel
  end

  # Makes a channel whose listener sends the data to the test process.
  defp listen(name, tag) do
    BroadcastChannel.onmessage(open(name), forward_data(tag))
  end

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

  defp listener_pid(%BroadcastChannel{address: pid}), do: :sys.get_state(pid).target.listener

  defp members(name), do: :pg.get_members(Web.BroadcastChannel, name)

  defp dom_exception(name, fun) do
    exception = assert_raise DOMException, fun
    assert exception.name == name
    exception.message
  end

  # ---------------------------------------------------------------------------
  # The public functions
  # ---------------------------------------------------------------------------

  test "the module has the functions of the Standard" do
    assert Enum.sort(BroadcastChannel.__info__(:functions)) == [
             {:__struct__, 0},
             {:__struct__, 1},
             {:add_event_listener, 3},
             {:add_event_listener, 4},
             {:close, 1},
             {:dispatch_event, 2},
             {:new, 1},
             {:onmessage, 1},
             {:onmessage, 2},
             {:onmessageerror, 1},
             {:onmessageerror, 2},
             {:post_message, 2},
             {:remove_event_listener, 3}
           ]
  end

  test "the name becomes a string" do
    for {input, name} <- [{:news, "news"}, {42, "42"}, {nil, "null"}, {"text", "text"}] do
      channel = BroadcastChannel.new(input)
      assert %BroadcastChannel{name: ^name} = channel
      assert is_pid(channel.address)
      BroadcastChannel.close(channel)
    end
  end

  test "the adapter has the contract of its callbacks" do
    assert Adapter.callback_contract() == [join: 2, leave: 2, broadcast: 3]
  end

  # ---------------------------------------------------------------------------
  # Messages
  # ---------------------------------------------------------------------------

  describe "a message" do
    test "arrives at each other channel with the same name", %{name: name} do
      sender = BroadcastChannel.onmessage(open(name), forward(:sender))
      first = BroadcastChannel.onmessage(open(name), forward(:first))
      second = BroadcastChannel.onmessage(open(name), forward(:second))
      _other = listen(name <> "-other", :other)

      assert :ok = BroadcastChannel.post_message(sender, %{id: 7, state: :done})

      assert_receive {:first, %MessageEvent{} = event}
      assert event.type == "message"
      assert event.data == %{id: 7, state: :done}
      assert event.origin == "node://" <> Atom.to_string(node())
      assert event.ports == []
      assert event.target == first

      assert_receive {:second, %MessageEvent{target: ^second, data: %{id: 7}}}

      # The sender, and a channel with a different name, get nothing.
      refute_receive {:sender, _event}, 30
      refute_received {:other, _data}
    end

    test "with no other channel has no effect", %{name: name} do
      sender = listen(name, :sender)

      assert :ok = BroadcastChannel.post_message(sender, "nobody")
      refute_receive {:sender, _data}, 30
    end

    test "the messages of one channel arrive in the sequence of the calls", %{name: name} do
      sender = open(name)
      _first = listen(name, :first)
      _second = listen(name, :second)

      Enum.each(1..200, &BroadcastChannel.post_message(sender, &1))

      for index <- 1..200 do
        assert_receive {:first, ^index}
        assert_receive {:second, ^index}
      end
    end

    test "a callback with no argument is called", %{name: name} do
      test = self()
      sender = open(name)
      BroadcastChannel.onmessage(open(name), fn -> send(test, :called) end)

      BroadcastChannel.post_message(sender, "trigger")

      assert_receive :called
    end

    test "each channel gets its own clone", %{name: name} do
      sender = open(name)
      _first = listen(name, :first)
      _second = listen(name, :second)
      buffer = ArrayBuffer.new("shared")

      BroadcastChannel.post_message(sender, %{"buffer" => buffer})

      assert_receive {:first, %{"buffer" => first}}
      assert_receive {:second, %{"buffer" => second}}

      assert ArrayBuffer.data(first) == "shared"
      refute first.id == second.id
      refute first.id == buffer.id

      ArrayBuffer.detach(first)
      assert ArrayBuffer.data(second) == "shared"
      assert ArrayBuffer.data(buffer) == "shared"
    end

    test "the listener runs in the async context of the sender", %{name: name} do
      test = self()
      request_id = Variable.new("request_id")
      sender = open(name)

      BroadcastChannel.onmessage(open(name), fn _event ->
        send(test, {:request_id, Variable.get(request_id)})
      end)

      Variable.run(request_id, "req-42", fn ->
        BroadcastChannel.post_message(sender, "with context")
      end)

      assert_receive {:request_id, "req-42"}
    end

    test "a message that cannot be cloned raises DataCloneError", %{name: name} do
      sender = open(name)
      _receiver = listen(name, :got)

      assert dom_exception("DataCloneError", fn ->
               BroadcastChannel.post_message(sender, self())
             end) == "A pid cannot be cloned."

      # The channel continues.
      BroadcastChannel.post_message(sender, "next")
      assert_receive {:got, "next"}
    end

    test "a message that cannot be made gives the event messageerror", %{name: name} do
      receiver =
        open(name)
        |> BroadcastChannel.onmessage(forward(:message))
        |> BroadcastChannel.onmessageerror(forward(:error))

      record = %StructuredData.Record{
        plain: false,
        value: %StructuredData.Node{type: :regex, key: nil, data: {"(", []}}
      }

      payload = %{record: record, origin: "node://other@host", snapshot: Snapshot.take()}
      send(receiver.address, {:broadcast_channel_message, payload})

      assert_receive {:error, %MessageEvent{type: "messageerror", origin: "node://other@host"}}
      refute_receive {:message, _event}, 30
      assert is_function(BroadcastChannel.onmessageerror(receiver), 1)
    end

    test "the origin is the node of the sender", %{name: name} do
      receiver = BroadcastChannel.onmessage(open(name), forward(:got))

      payload = %{
        record: StructuredData.serialize("from a different node"),
        origin: "node://remote@example",
        snapshot: Snapshot.take()
      }

      send(receiver.address, {:broadcast_channel_message, payload})

      assert_receive {:got, %MessageEvent{origin: "node://remote@example", data: data}}
      assert data == "from a different node"
    end
  end

  # ---------------------------------------------------------------------------
  # Listeners
  # ---------------------------------------------------------------------------

  describe "listeners" do
    test "a slow listener does not delay the other channels", %{name: name} do
      test = self()
      sender = open(name)
      slow = open(name)
      _fast = listen(name, :fast)

      # The slow listener waits until the test lets it continue.
      BroadcastChannel.onmessage(slow, fn event ->
        receive do
          :continue -> :ok
        end

        send(test, {:slow, event.data})
      end)

      {time, :ok} =
        :timer.tc(fn ->
          Enum.each(1..5, &BroadcastChannel.post_message(sender, &1))
          for index <- 1..5, do: assert_receive({:fast, ^index})
          :ok
        end)

      assert time < 300_000
      refute_received {:slow, _data}

      listener = listener_pid(slow)
      for _index <- 1..5, do: send(listener, :continue)
      for index <- 1..5, do: assert_receive({:slow, ^index})
    end

    test "the event handler and the listeners get the event", %{name: name} do
      sender = open(name)
      removed = forward_data(:removed)

      receiver =
        open(name)
        |> BroadcastChannel.add_event_listener("message", forward_data(:listener))
        |> BroadcastChannel.onmessage(forward_data(:handler))
        |> BroadcastChannel.add_event_listener("message", removed)
        |> BroadcastChannel.add_event_listener(:message, forward_data(:once), once: true)
        |> BroadcastChannel.remove_event_listener("message", removed)

      assert is_function(BroadcastChannel.onmessage(receiver), 1)

      BroadcastChannel.post_message(sender, 1)
      BroadcastChannel.post_message(sender, 2)

      assert_receive {:listener, 1}
      assert_receive {:handler, 1}
      assert_receive {:once, 1}
      assert_receive {:listener, 2}
      assert_receive {:handler, 2}
      refute_receive {:once, 2}, 30
      refute_received {:removed, _data}

      assert BroadcastChannel.onmessage(receiver, nil) == receiver
      assert BroadcastChannel.onmessage(receiver) == nil

      assert_raise Web.TypeError, ~r/must be a function/, fn ->
        BroadcastChannel.onmessage(receiver, :not_a_function)
      end
    end

    test "dispatch_event gives an event to the listeners", %{name: name} do
      channel = BroadcastChannel.add_event_listener(open(name), "custom", forward(:custom))
      event = Web.CustomEvent.new("custom", detail: 7)

      assert {^channel, true} = BroadcastChannel.dispatch_event(channel, event)
      assert_receive {:custom, ^event}

      assert {^channel, true} = Web.EventTarget.dispatch_event(channel, event)
      assert_receive {:custom, ^event}
    end

    test "a listener that raises goes to the log, and the channel continues", %{name: name} do
      test = self()
      sender = open(name)

      receiver =
        open(name)
        |> BroadcastChannel.onmessage(fn event ->
          if event.data == :bad, do: raise("the listener failed")
          send(test, {:first, event.data})
        end)
        |> BroadcastChannel.add_event_listener("message", forward_data(:second))

      log =
        capture_log(fn ->
          BroadcastChannel.post_message(sender, :bad)
          assert_receive {:second, :bad}
        end)

      assert log =~ ~s(A listener of the event "message" failed.)
      assert log =~ "the listener failed"

      BroadcastChannel.post_message(sender, :good)
      assert_receive {:first, :good}
      assert_receive {:second, :good}
      assert Process.alive?(receiver.address)
    end

    test "a listener can use its channel", %{name: name} do
      test = self()
      first = listen(name, :first)

      second =
        BroadcastChannel.onmessage(open(name), fn event ->
          # Send, change the callback, and close, from the listener.
          BroadcastChannel.post_message(event.target, {:answer, event.data})

          BroadcastChannel.onmessage(event.target, fn next ->
            send(test, {:second_callback, next.data})
            BroadcastChannel.close(next.target)
            send(test, :closed)
          end)
        end)

      BroadcastChannel.post_message(first, 1)
      assert_receive {:first, {:answer, 1}}

      BroadcastChannel.post_message(first, 2)
      BroadcastChannel.post_message(first, 3)
      assert_receive {:second_callback, 2}
      assert_receive :closed
      refute_receive {:second_callback, 3}, 50

      eventually(fn -> not Process.alive?(second.address) end)
    end
  end

  # ---------------------------------------------------------------------------
  # Close
  # ---------------------------------------------------------------------------

  describe "close" do
    test "a closed channel gets no message", %{name: name} do
      sender = open(name)
      receiver = listen(name, :got)

      BroadcastChannel.post_message(sender, 1)
      assert_receive {:got, 1}

      assert :ok = BroadcastChannel.close(receiver)
      BroadcastChannel.post_message(sender, 2)
      refute_receive {:got, 2}, 50
    end

    test "a channel delivers no event after close returns", %{name: name} do
      test = self()
      sender = open(name)
      receiver = open(name)

      BroadcastChannel.onmessage(receiver, fn event ->
        send(test, {:got, event.data})

        # The test lets the callback continue when the other messages are in
        # the mailbox of the listener process.
        receive do
          :continue -> :ok
        end

        BroadcastChannel.close(event.target)
        send(test, :closed)
      end)

      Enum.each(1..20, &BroadcastChannel.post_message(sender, &1))

      assert_receive {:got, 1}
      listener = listener_pid(receiver)

      eventually(fn ->
        {:messages, messages} = Process.info(listener, :messages)
        Enum.count(messages, &match?({:"$gen_cast", {:task, _task}}, &1)) == 19
      end)

      send(listener, :continue)
      assert_receive :closed
      refute_receive {:got, _data}, 80
    end

    test "post_message on a closed channel raises InvalidStateError", %{name: name} do
      channel = open(name)
      assert :ok = BroadcastChannel.close(channel)

      assert dom_exception("InvalidStateError", fn ->
               BroadcastChannel.post_message(channel, "nothing")
             end) == "The BroadcastChannel is closed."

      # The Standard examines the closed state before the message.
      dom_exception("InvalidStateError", fn -> BroadcastChannel.post_message(channel, self()) end)
    end

    test "each other function on a closed channel has no effect", %{name: name} do
      channel = open(name)
      callback = fn _event -> :ok end

      assert :ok = BroadcastChannel.close(channel)
      assert :ok = BroadcastChannel.close(channel)

      assert BroadcastChannel.onmessage(channel, callback) == channel
      assert BroadcastChannel.onmessage(channel) == nil
      assert BroadcastChannel.add_event_listener(channel, "message", callback) == channel
      assert BroadcastChannel.remove_event_listener(channel, "message", callback) == channel
      assert {^channel, true} = BroadcastChannel.dispatch_event(channel, %{type: "message"})
    end

    test "the processes stop, and the channel leaves its group", %{name: name} do
      channel = open(name)
      server = channel.address
      listener = listener_pid(channel)
      assert members(name) == [server]

      BroadcastChannel.close(channel)

      eventually(fn -> not Process.alive?(server) and not Process.alive?(listener) end)
      assert members(name) == []
    end

    test "the channel closes when its holder stops", %{name: name} do
      test = self()

      holder =
        spawn(fn ->
          send(test, {:channel, BroadcastChannel.new(name)})
          Process.sleep(:infinity)
        end)

      assert_receive {:channel, channel}
      assert members(name) == [channel.address]

      Process.exit(holder, :kill)

      eventually(fn -> not Process.alive?(channel.address) end)
      eventually(fn -> members(name) == [] end)
    end

    test "a server that is killed leaves its group", %{name: name} do
      sender = open(name)
      receiver = listen(name, :got)

      Process.exit(receiver.address, :kill)
      eventually(fn -> members(name) == [sender.address] end)

      assert :ok = BroadcastChannel.post_message(sender, "nobody")
      refute_receive {:got, _data}, 30
    end

    test "Symbol.dispose closes the channel", %{name: name} do
      channel = open(name)

      assert :ok = Web.Symbol.Protocol.symbol(channel, Web.Symbol.dispose(), [])
      dom_exception("InvalidStateError", fn -> BroadcastChannel.post_message(channel, 1) end)

      assert :ok = Web.Symbol.Protocol.symbol(channel, Web.Symbol.async_dispose(), [])
      assert :unsupported = Web.Symbol.Protocol.symbol(channel, Web.Symbol.iterator(), [])
    end
  end

  # ---------------------------------------------------------------------------
  # The handle
  # ---------------------------------------------------------------------------

  describe "a handle" do
    test "with a token that is not correct has no effect", %{name: name} do
      sender = open(name)
      _receiver = listen(name, :got)
      forged = %{sender | token: make_ref()}

      dom_exception("InvalidStateError", fn -> BroadcastChannel.post_message(forged, "forged") end)

      assert :ok = BroadcastChannel.close(forged)
      assert BroadcastChannel.onmessage(forged) == nil
      refute_receive {:got, _data}, 30

      # The server ignores a message that it does not know.
      send(sender.address, :unexpected)
      send(sender.address, {:broadcast_channel_message, :not_a_payload})
      GenServer.cast(sender.address, :unexpected)
      assert GenServer.call(sender.address, :unexpected) == {:error, :detached}

      assert GenServer.call(sender.address, {sender.token, :unexpected}) ==
               {:error, :unknown_request}

      BroadcastChannel.post_message(sender, "real")
      assert_receive {:got, "real"}
    end

    test "can be used from a different process", %{name: name} do
      sender = open(name)
      _receiver = listen(name, :got)

      Task.await(Task.async(fn -> BroadcastChannel.post_message(sender, "from a task") end))

      assert_receive {:got, "from a task"}
    end
  end

  # ---------------------------------------------------------------------------
  # Settings
  # ---------------------------------------------------------------------------

  describe "settings" do
    test "the adapter is read when the channel is made", %{name: name} do
      Application.put_env(:web, :broadcast_adapter_spy, self())
      Application.put_env(:web, :broadcast_adapter, SpyAdapter)

      channel = BroadcastChannel.new(name)
      server = channel.address
      assert_receive {:spy_join, ^name, ^server}

      Application.delete_env(:web, :broadcast_adapter)

      assert :ok = BroadcastChannel.post_message(channel, "by the adapter")

      assert_receive {:spy_broadcast, ^name, ^server, {:broadcast_channel_message, payload}}
      assert %{origin: "node://" <> _, record: record, snapshot: %Snapshot{}} = payload
      assert StructuredData.deserialize(record) == "by the adapter"

      assert :ok = BroadcastChannel.close(channel)
      assert_receive {:spy_leave, ^name, ^server}
    end

    test "the governor limits post_message in the process that sends", %{name: name} do
      Application.put_env(:web, :broadcast_governor, %SpyGovernor{pid: self()})

      sender = open(name)
      _receiver = listen(name, :got)

      assert :ok = BroadcastChannel.post_message(sender, "limited")

      assert_receive {:spy_governor, :acquire, ref}
      assert_receive {:spy_governor, :release, ^ref}
      assert_receive {:got, "limited"}
      refute_received {:spy_governor, _event, _ref}
    end
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  describe "properties" do
    property "each open channel gets the messages of the others, in sequence" do
      check all(
              count <- integer(2..4),
              posts <- list_of(integer(0..3), max_length: 30),
              max_runs: 40
            ) do
        name = "property-#{System.unique_integer([:positive])}"
        test = self()

        channels =
          for index <- 0..(count - 1) do
            BroadcastChannel.onmessage(BroadcastChannel.new(name), fn event ->
              send(test, {:got, index, event.data})
            end)
          end

        posts =
          posts
          |> Enum.map(&rem(&1, count))
          |> Enum.with_index()

        Enum.each(posts, fn {sender, number} ->
          BroadcastChannel.post_message(Enum.at(channels, sender), {sender, number})
        end)

        for receiver <- 0..(count - 1), sender <- 0..(count - 1), sender != receiver do
          expected = for {^sender, number} <- posts, do: {sender, number}
          assert collect(receiver, length(expected), sender) == expected
        end

        Enum.each(channels, &BroadcastChannel.close/1)
        refute_received {:got, _receiver, _data}
      end
    end

    property "a channel that closed gets nothing more, and the others continue" do
      check all(
              before <- list_of(integer(), max_length: 10),
              later <- list_of(integer(), min_length: 1, max_length: 10),
              max_runs: 40
            ) do
        name = "property-#{System.unique_integer([:positive])}"
        sender = BroadcastChannel.new(name)
        closing = BroadcastChannel.onmessage(BroadcastChannel.new(name), forward_data(:closing))
        staying = BroadcastChannel.onmessage(BroadcastChannel.new(name), forward_data(:staying))

        Enum.each(before, &BroadcastChannel.post_message(sender, &1))
        for message <- before, do: assert_receive({:closing, ^message})

        BroadcastChannel.close(closing)
        Enum.each(later, &BroadcastChannel.post_message(sender, &1))

        for message <- before ++ later, do: assert_receive({:staying, ^message})
        refute_received {:closing, _data}

        BroadcastChannel.close(sender)
        BroadcastChannel.close(staying)
      end
    end
  end

  # The messages that `receiver` got from `sender`, in their sequence.
  defp collect(_receiver, 0, _sender), do: []

  defp collect(receiver, count, sender) do
    receive do
      {:got, ^receiver, {^sender, _number} = data} ->
        [data | collect(receiver, count - 1, sender)]
    after
      1_000 -> flunk("channel #{receiver} did not get #{count} messages of #{sender}")
    end
  end

  # ---------------------------------------------------------------------------
  # A cluster
  # ---------------------------------------------------------------------------

  describe "a cluster" do
    @describetag :cluster

    setup do
      # The second node stops with the test process.
      {_peer, node} = Web.TestCluster.start_peer()
      {:ok, node: node}
    end

    test "a message goes to the channels of the other nodes", %{name: name, node: node} do
      local = listen(name, :local)

      # A process on the second node makes a channel, and sends back each
      # message with the origin.
      remote_holder = Web.TestCluster.start_channel(node, name, self())

      assert_receive :remote_ready, 5_000
      eventually(fn -> length(members(name)) == 2 end)

      buffer = ArrayBuffer.new("bytes")
      BroadcastChannel.post_message(local, %{"buffer" => buffer, key: :value})

      local_origin = "node://" <> Atom.to_string(node())
      assert_receive {:remote, %{"buffer" => remote_buffer, key: :value}, ^local_origin}, 5_000
      assert remote_buffer.data == "bytes"

      BroadcastChannel.post_message(local, "answer please")
      assert_receive {:local, {"answer from", ^node}}, 5_000

      # The channel of a node that stops leaves the group.
      Process.exit(remote_holder, :kill)
      eventually(fn -> members(name) == [local.address] end)
    end
  end
end
