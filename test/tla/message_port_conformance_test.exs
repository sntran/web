defmodule Web.TLA.MessagePortConformanceTest do
  # Compares the real `Web.MessagePort` with the specification
  # `tla/MessagePort.tla`.
  #
  # The test makes a random list of commands. It does each command on a real
  # channel and on the specification. After each command it lets the
  # processes, and the specification, do their work. Then it compares the
  # events that the listeners got.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.MessageChannel
  alias Web.MessagePort
  alias Web.Test.SpecModel

  @max_messages 6
  @max_transfers 3

  @constants [
    {"MaxMessages = 2", "MaxMessages = #{@max_messages}"},
    {"MaxTransfers = 1", "MaxTransfers = #{@max_transfers}"}
  ]

  # The steps that the processes of the ports do with no command.
  @internal [
    {"ANotice", []},
    {"Receive", []},
    {"Pump", []},
    {"Run", []},
    {"RunDirect", []},
    {"Answer", []}
  ]

  # The numbers of the specification for the two events close.
  @close 0
  @early @max_messages + 2

  defp command do
    frequency([
      {8, constant(:post)},
      {4, constant(:start)},
      {3, constant(:transfer)},
      {1, constant(:close_a)},
      {1, constant(:close_b)}
    ])
  end

  property "the ports do each step as the specification permits" do
    check all(commands <- list_of(command(), max_length: 20), max_runs: 100) do
      system = start_system()

      try do
        Enum.reduce(commands, {SpecModel.start("MessagePort", @constants), system}, fn
          command, {model, system} ->
            {model, system} = run(command, model, system)
            model = SpecModel.settle(model, @internal)
            system = settle(system)
            assert_same_state(model, system, command)
            {model, system}
        end)
      after
        stop_system(system)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The real system
  # ---------------------------------------------------------------------------

  # Each event has the reference of its run: an event of a run that ended
  # is not an event of the next run.
  defp start_system do
    {a, b} = MessageChannel.new()
    test = self()
    run = make_ref()
    MessagePort.add_event_listener(a, "close", fn -> send(test, {run, :a_close}) end)

    %{run: run, a: a, b: listen(b, run), events: [], a_closes: 0}
  end

  # The listeners do not start the port.
  defp listen(port, run) do
    test = self()

    port
    |> MessagePort.add_event_listener("message", fn event -> send(test, {run, :b, event.data}) end)
    |> MessagePort.add_event_listener("close", fn -> send(test, {run, :b, :close}) end)
  end

  defp stop_system(system) do
    MessagePort.close(system.a)
    MessagePort.close(system.b)
  end

  defp run(:post, model, system) do
    if SpecModel.enabled?(model, "Post") do
      :ok = MessagePort.post_message(system.a, SpecModel.get(model, "sent") + 1)
      {SpecModel.step!(model, "Post"), system}
    else
      # Port a is closed, or the specification has no more messages.
      if not SpecModel.get(model, "a_open"), do: :ok = MessagePort.post_message(system.a, :none)
      {model, system}
    end
  end

  defp run(:start, model, system) do
    :ok = MessagePort.start(system.b)
    {step_if_enabled(model, "Start"), system}
  end

  defp run(:close_a, model, system) do
    :ok = MessagePort.close(system.a)
    {step_if_enabled(model, "CloseA"), system}
  end

  defp run(:close_b, model, system) do
    :ok = MessagePort.close(system.b)
    {step_if_enabled(model, "CloseB"), system}
  end

  defp run(:transfer, model, system) do
    cond do
      SpecModel.enabled?(model, "Transfer") ->
        moved = Web.structured_clone(system.b, transfer: [system.b])
        {SpecModel.step!(model, "Transfer"), %{system | b: listen(moved, system.run)}}

      not SpecModel.get(model, "b_open") ->
        # A closed port cannot move.
        assert_raise Web.DOMException, fn ->
          Web.structured_clone(system.b, transfer: [system.b])
        end

        {model, system}

      true ->
        # The specification has no more transfers.
        {model, system}
    end
  end

  defp step_if_enabled(model, action) do
    if SpecModel.enabled?(model, action), do: SpecModel.step!(model, action), else: model
  end

  # Lets the processes of the two ports do all their work, then takes the
  # events from the mailbox.
  defp settle(system) do
    sync(system.a.address)
    wait_for_idle(system.b.address, 400)
    sync(system.a.address)
    sync_listener(system.a.address)
    sync_listener(system.b.address)

    events = flush(system.run, [])
    a_closes = Enum.count(events, &(&1 == :a_close))
    b_events = for {:b, event} <- events, do: event

    %{system | events: system.events ++ b_events, a_closes: system.a_closes + a_closes}
  end

  # The server of port b has nothing to do when the listener process has no
  # item.
  defp wait_for_idle(server, attempts) do
    case state(server) do
      nil ->
        :ok

      %{in_flight: nil} ->
        :ok

      _busy when attempts > 0 ->
        Process.sleep(1)
        wait_for_idle(server, attempts - 1)

      state ->
        flunk("the port did not become idle: #{inspect(state)}")
    end
  end

  defp sync(server), do: state(server)

  defp sync_listener(server) do
    case state(server) do
      nil -> :ok
      %{target: target} -> state(target.listener)
    end
  end

  defp state(pid) do
    :sys.get_state(pid)
  catch
    :exit, _reason -> nil
  end

  defp flush(run, events) do
    receive do
      {^run, :a_close} -> flush(run, [:a_close | events])
      {^run, :b, event} -> flush(run, [{:b, event} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  # ---------------------------------------------------------------------------
  # The comparison
  # ---------------------------------------------------------------------------

  defp assert_same_state(model, system, command) do
    expected =
      model
      |> SpecModel.get("delivered")
      |> Enum.map(fn
        number when number in [@close, @early] -> :close
        number -> number
      end)

    assert system.events == expected,
           "after #{command}: the listeners of port b got #{inspect(system.events)}, " <>
             "and the specification gives #{inspect(expected)}"

    assert system.a_closes == SpecModel.get(model, "a_closes"),
           "after #{command}: port a got #{system.a_closes} events close"

    assert Process.alive?(system.a.address) == SpecModel.get(model, "a_open")
    assert Process.alive?(system.b.address) == SpecModel.get(model, "b_open")

    if SpecModel.get(model, "b_open") do
      state = :sys.get_state(system.b.address)
      assert state.started? == SpecModel.get(model, "started")
      assert state.peer != nil == SpecModel.get(model, "b_peer")

      queue =
        Enum.map(:queue.to_list(state.queue), fn
          :close -> @close
          {:message, %{record: record}} -> record.value
        end)

      assert queue == SpecModel.get(model, "queue")
    end
  end
end
