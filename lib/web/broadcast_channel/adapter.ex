defmodule Web.BroadcastChannel.Adapter do
  @moduledoc false

  @callback join(String.t(), pid()) :: :ok
  @callback leave(String.t(), pid()) :: :ok
  @callback broadcast(String.t(), pid(), term()) :: :ok

  @doc false
  @spec callback_contract() :: keyword()
  def callback_contract do
    [join: 2, leave: 2, broadcast: 3]
  end
end
