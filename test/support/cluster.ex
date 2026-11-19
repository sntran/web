defmodule Web.TestCluster do
  @moduledoc false

  # Starts a second node for the tests with the tag `:cluster`.
  #
  # The tests need Erlang distribution. `start_distribution/0` returns
  # `false` when the machine cannot start it. The test helper then excludes
  # the tests with the tag.

  @cookie :web_test_cluster

  @doc "Makes this VM a node. Returns false when that is not possible."
  def start_distribution do
    if Node.alive?() do
      true
    else
      start_epmd()
      name = String.to_atom("web_test_#{System.unique_integer([:positive])}")

      case Node.start(name, :shortnames) do
        {:ok, _pid} ->
          Node.set_cookie(@cookie)
          true

        {:error, _reason} ->
          false
      end
    end
  end

  defp start_epmd do
    case System.find_executable("epmd") do
      nil -> :ok
      epmd -> System.cmd(epmd, ["-daemon"])
    end
  end

  @doc """
  Starts a node that has the code of this VM, and the application. The node
  stops when the process that calls this function stops.
  """
  def start_peer do
    name = String.to_atom("web_test_peer_#{System.unique_integer([:positive])}")
    cookie = Atom.to_charlist(Node.get_cookie())

    {:ok, peer, node} = :peer.start_link(%{name: name, args: [~c"-setcookie", cookie]})
    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    {:ok, _apps} = :erpc.call(node, Application, :ensure_all_started, [:web])

    {peer, node}
  end

  @doc """
  Starts, on `node`, a process that makes a broadcast channel. The listener
  of the channel sends each message, with its origin, to `test`. It answers
  the message `"answer please"` on its channel.

  The code is in this module because a function of a test file is not on
  the second node.
  """
  def start_channel(node, name, test) do
    Node.spawn(node, __MODULE__, :run_channel, [name, test])
  end

  @doc false
  def run_channel(name, test) do
    channel = Web.BroadcastChannel.new(name)

    Web.BroadcastChannel.onmessage(channel, fn event ->
      send(test, {:remote, event.data, event.origin})

      if event.data == "answer please" do
        Web.BroadcastChannel.post_message(event.target, {"answer from", node()})
      end
    end)

    send(test, :remote_ready)
    Process.sleep(:infinity)
  end
end
