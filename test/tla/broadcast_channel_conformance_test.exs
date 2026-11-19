defmodule Web.TLA.BroadcastChannelConformanceTest do
  # Compares the real `Web.BroadcastChannel` with the specification
  # `tla/BroadcastChannel.tla`.
  #
  # The test makes a random list of commands. It does each command on real
  # channels and on the specification. After each command it lets the
  # processes, and the specification, do their work. Then it compares the
  # messages that the listeners of each channel got.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.BroadcastChannel
  alias Web.Test.SpecModel

  @channels [:c1, :c2, :c3]
  @max_posts 5

  # In this test each channel sends, and no channel is slow.
  @constants [
    {"Senders = {c1, c2}", "Senders = {c1, c2, c3}"},
    {"Slow = {c3}", "Slow = {}"},
    {"MaxPosts = 2", "MaxPosts = #{@max_posts}"}
  ]

  # The steps that the processes of the channels do with no command.
  @internal Enum.map(@channels, &{"Deliver", [&1]})

  defp command do
    frequency([
      {8, tuple({constant(:post), member_of(@channels)})},
      {1, tuple({constant(:close), member_of(@channels)})}
    ])
  end

  property "the channels do each step as the specification permits" do
    check all(commands <- list_of(command(), max_length: 20), max_runs: 100) do
      system = start_system()

      try do
        Enum.reduce(commands, {SpecModel.start("BroadcastChannel", @constants), system}, fn
          command, {model, system} ->
            model = command |> run(model, system) |> SpecModel.settle(@internal)
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

  defp start_system do
    test = self()
    run = make_ref()
    name = "conformance-#{System.unique_integer([:positive])}"

    channels =
      Map.new(@channels, fn id ->
        channel =
          BroadcastChannel.onmessage(BroadcastChannel.new(name), fn event ->
            send(test, {run, id, event.data})
          end)

        {id, channel}
      end)

    %{run: run, channels: channels, got: Map.new(@channels, &{&1, []})}
  end

  defp stop_system(system) do
    Enum.each(system.channels, fn {_id, channel} -> BroadcastChannel.close(channel) end)
  end

  defp run({:post, id}, model, system) do
    channel = system.channels[id]

    cond do
      SpecModel.enabled?(model, "Post", [id]) ->
        number = SpecModel.get(model, "posted")[to_string(id)] + 1
        :ok = BroadcastChannel.post_message(channel, [to_string(id), number])
        SpecModel.step!(model, "Post", [id])

      not SpecModel.get(model, "open")[to_string(id)] ->
        # A closed channel cannot send.
        exception =
          assert_raise Web.DOMException, fn -> BroadcastChannel.post_message(channel, :none) end

        assert exception.name == "InvalidStateError"
        model

      true ->
        # The specification has no more messages for this channel.
        model
    end
  end

  defp run({:close, id}, model, system) do
    :ok = BroadcastChannel.close(system.channels[id])

    if SpecModel.enabled?(model, "Close", [id]) do
      SpecModel.step!(model, "Close", [id])
    else
      model
    end
  end

  # Lets the processes of the channels do all their work, then takes the
  # messages from the mailbox.
  defp settle(system) do
    # A server gives a message to its listener process before it answers.
    servers = Enum.map(system.channels, fn {_id, channel} -> channel.address end)
    listeners = Enum.map(servers, &listener/1)
    Enum.each(servers, &state/1)
    Enum.each(listeners, &state/1)

    %{system | got: flush(system.run, system.got)}
  end

  defp listener(server) do
    case state(server) do
      nil -> nil
      %{target: target} -> target.listener
    end
  end

  defp state(nil), do: nil

  defp state(pid) do
    :sys.get_state(pid)
  catch
    :exit, _reason -> nil
  end

  defp flush(run, got) do
    receive do
      {^run, id, message} -> flush(run, Map.update!(got, id, &(&1 ++ [message])))
    after
      0 -> got
    end
  end

  # ---------------------------------------------------------------------------
  # The comparison
  # ---------------------------------------------------------------------------

  defp assert_same_state(model, system, command) do
    expected = SpecModel.get(model, "got")
    open = SpecModel.get(model, "open")

    # The specification has the name of a channel as a string.
    for id <- @channels, name = to_string(id) do
      assert system.got[id] == expected[name],
             "after #{inspect(command)}: the listeners of #{id} got " <>
               "#{inspect(system.got[id])}, and the specification gives #{inspect(expected[name])}"

      assert Process.alive?(system.channels[id].address) == open[name]
    end
  end
end
