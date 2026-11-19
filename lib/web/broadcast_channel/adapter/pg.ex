defmodule Web.BroadcastChannel.Adapter.PG do
  @moduledoc """
  The default adapter of `Web.BroadcastChannel`. It uses the module `:pg` of
  Erlang/OTP.

  The groups are in a scope of `:pg` that only this library uses. The scope
  connects to the same scope on each node of the cluster, thus a message
  goes to the channels of all the connected nodes. No node and no process is
  necessary for the other nodes to continue.
  """

  @behaviour Web.BroadcastChannel.Adapter

  @scope Web.BroadcastChannel

  @doc false
  # The supervisor of the application starts the scope.
  def child_spec(_argument) do
    %{id: __MODULE__, start: {:pg, :start_link, [@scope]}}
  end

  @impl true
  def join(name, pid) when is_binary(name) and is_pid(pid) do
    :pg.join(@scope, name, pid)
  end

  @impl true
  def leave(name, pid) when is_binary(name) and is_pid(pid) do
    _result = :pg.leave(@scope, name, pid)
    :ok
  end

  @impl true
  def broadcast(name, sender, message) when is_binary(name) and is_pid(sender) do
    for member <- :pg.get_members(@scope, name), member != sender do
      send(member, message)
    end

    :ok
  end
end
