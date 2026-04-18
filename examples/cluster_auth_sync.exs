defmodule ClusterAuthSyncExample do
  @moduledoc """
  Demonstrates BroadcastChannel fan-out across two BEAM nodes.

  Usage:
    mix run examples/cluster_auth_sync.exs
  """

  use Web

  alias Web.ArrayBuffer
  alias Web.AsyncContext

  def run do
    ensure_host_node!()

    {:ok, peer, peer_node} = start_peer!()
    local_channel = BroadcastChannel.new(unique_channel_name())
    request_id = AsyncContext.Variable.new("request_id")

    try do
      prime_remote_node!(peer_node)
      remote_receiver = start_remote_receiver!(peer_node, self(), local_channel.name, request_id)
      await_remote_ready!(peer_node)

      original_payload = %{
        "token" => "token-A",
        "meta" => %{"source" => "node-a", "scope" => "auth"},
        "buffer" => ArrayBuffer.new("token-A")
      }

      request_value = "req-" <> Integer.to_string(System.unique_integer([:positive]))

      AsyncContext.Variable.run(request_id, request_value, fn ->
        :ok = BroadcastChannel.post_message(local_channel, original_payload)
      end)

      updated_local_payload = Map.put(original_payload, "token", "revoked-on-node-a")
      ArrayBuffer.detach(original_payload["buffer"])

      {remote_payload, remote_request_id} = await_remote_payload!(peer_node)

      verify!(
        updated_local_payload,
        original_payload,
        remote_payload,
        request_value,
        remote_request_id
      )

      print_summary(
        local_channel.name,
        updated_local_payload,
        original_payload,
        remote_payload,
        remote_request_id
      )

      send(remote_receiver, {:shutdown, self()})
      await_remote_shutdown!(peer_node)
    after
      :ok = BroadcastChannel.close(local_channel)
      :ok = :peer.stop(peer)
    end
  end

  defp ensure_host_node! do
    if Node.alive?() do
      Node.set_cookie(:web_broadcast_sync)
      :ok
    else
      maybe_start_epmd()
      name = String.to_atom("web_auth_sync_host_#{System.unique_integer([:positive])}")

      case Node.start(name, :shortnames) do
        {:ok, _pid} ->
          Node.set_cookie(:web_broadcast_sync)
          :ok

        {:error, {:already_started, _pid}} ->
          Node.set_cookie(:web_broadcast_sync)
          :ok

        {:error, reason} ->
          raise "failed to start distributed host node: #{inspect(reason)}"
      end
    end
  end

  defp maybe_start_epmd do
    case System.find_executable("epmd") do
      nil ->
        :ok

      epmd ->
        _ = System.cmd(epmd, ["-daemon"])
        :ok
    end
  end

  defp start_peer! do
    peer_name = String.to_atom("web_auth_sync_peer_#{System.unique_integer([:positive])}")
    cookie = Node.get_cookie() |> Atom.to_charlist()

    case :peer.start_link(%{name: peer_name, args: [~c"-setcookie", cookie]}) do
      {:ok, peer, peer_node} -> {:ok, peer, peer_node}
      {:error, reason} -> raise "failed to start peer node: #{inspect(reason)}"
    end
  end

  defp prime_remote_node!(peer_node) do
    :ok = rpc!(peer_node, :code, :add_paths, [:code.get_path()])
    {:ok, _apps} = rpc!(peer_node, Application, :ensure_all_started, [:web])
    :ok
  end

  defp start_remote_receiver!(peer_node, parent, channel_name, request_id) do
    code = """
    spawn(fn ->
      channel =
        Web.BroadcastChannel.new(channel_name)
        |> Web.BroadcastChannel.onmessage(fn event ->
          send(parent, {
            :remote_received,
            node(),
            event.data,
            Web.AsyncContext.Variable.get(request_id)
          })
        end)

      send(parent, {:remote_ready, node()})

      receive do
        {:shutdown, caller} ->
          Web.BroadcastChannel.close(channel)
          send(caller, {:remote_stopped, node()})
      end
    end)
    """

    {receiver_pid, _binding} =
      rpc!(peer_node, Code, :eval_string, [
        code,
        [parent: parent, channel_name: channel_name, request_id: request_id]
      ])

    receiver_pid
  end

  defp await_remote_ready!(peer_node) do
    receive do
      {:remote_ready, ^peer_node} -> :ok
    after
      5_000 -> raise "timed out waiting for the remote BroadcastChannel subscriber"
    end
  end

  defp await_remote_payload!(peer_node) do
    receive do
      {:remote_received, ^peer_node, payload, request_id} -> {payload, request_id}
    after
      5_000 -> raise "timed out waiting for the remote BroadcastChannel payload"
    end
  end

  defp await_remote_shutdown!(peer_node) do
    receive do
      {:remote_stopped, ^peer_node} -> :ok
    after
      5_000 -> raise "timed out waiting for the remote BroadcastChannel shutdown"
    end
  end

  defp verify!(
         updated_local_payload,
         original_payload,
         remote_payload,
         request_value,
         remote_request_id
       ) do
    if remote_payload["token"] != "token-A" do
      raise "expected remote token to stay at token-A, got #{inspect(remote_payload["token"])}"
    end

    if updated_local_payload["token"] != "revoked-on-node-a" do
      raise "expected local token mutation to stick, got #{inspect(updated_local_payload["token"])}"
    end

    if ArrayBuffer.byte_length(original_payload["buffer"]) != 0 do
      raise "expected the detached local buffer to be empty"
    end

    if ArrayBuffer.byte_length(remote_payload["buffer"]) != 7 do
      raise "expected the remote buffer clone to stay intact"
    end

    if remote_request_id != request_value do
      raise "expected remote request_id #{inspect(request_value)}, got #{inspect(remote_request_id)}"
    end
  end

  defp print_summary(
         channel_name,
         updated_local_payload,
         original_payload,
         remote_payload,
         remote_request_id
       ) do
    IO.puts("BroadcastChannel: #{channel_name}")
    IO.puts("Local token after mutation: #{updated_local_payload["token"]}")
    IO.puts("Remote token after delivery: #{remote_payload["token"]}")

    IO.puts(
      "Local buffer length after detach: #{ArrayBuffer.byte_length(original_payload["buffer"])}"
    )

    IO.puts(
      "Remote buffer length after delivery: #{ArrayBuffer.byte_length(remote_payload["buffer"])}"
    )

    IO.puts("Remote request_id propagated through AsyncContext: #{remote_request_id}")
  end

  defp rpc!(peer_node, module, function, args) do
    case :rpc.call(peer_node, module, function, args) do
      {:badrpc, reason} ->
        raise "remote call #{inspect({module, function, length(args)})} failed: #{inspect(reason)}"

      result ->
        result
    end
  end

  defp unique_channel_name do
    "cluster-auth-sync-#{System.unique_integer([:positive, :monotonic])}"
  end
end

ClusterAuthSyncExample.run()
