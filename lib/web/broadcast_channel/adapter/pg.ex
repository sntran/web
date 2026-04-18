defmodule Web.BroadcastChannel.Adapter.PG do
  @moduledoc false

  @behaviour Web.BroadcastChannel.Adapter

  @impl true
  def join(name, pid) when is_binary(name) and is_pid(pid) do
    ensure_pg_started()
    :ok = :pg.join(group(name), pid)
  end

  @impl true
  def leave(name, pid) when is_binary(name) and is_pid(pid) do
    if Process.whereis(:pg) do
      :ok = :pg.leave(group(name), pid)
    end

    :ok
  end

  @impl true
  def broadcast(name, sender_pid, message) when is_binary(name) and is_pid(sender_pid) do
    ensure_pg_started()

    name
    |> group()
    |> :pg.get_members()
    |> Enum.reject(&(&1 == sender_pid))
    |> Enum.each(&send(&1, message))

    :ok
  end

  defp group(name), do: {Web.BroadcastChannel, name}

  defp ensure_pg_started do
    case Process.whereis(:pg) do
      nil ->
        # coveralls-ignore-start
        case :pg.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      # coveralls-ignore-stop

      _pid ->
        :ok
    end
  end
end
