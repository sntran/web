defmodule Web.BroadcastChannel.Adapter do
  @moduledoc false

  # The transport of `Web.BroadcastChannel`: an extension point of the
  # library, not a public API.
  #
  # An adapter keeps one group of processes for each channel name, and sends
  # a message to the members of a group. The default adapter is
  # `Web.BroadcastChannel.Adapter.PG`. The setting
  # `config :web, broadcast_adapter: module` gives a different one. A channel
  # reads the setting when it is made.
  #
  #   * `join/2` - adds a process to the group of a name;
  #   * `leave/2` - removes a process from the group of a name. The process
  #     can be stopped already;
  #   * `broadcast/3` - sends the message, with `send/2`, to each member of
  #     the group of a name. It does not send to `sender`.
  #
  # The messages that one sender gives to `broadcast/3` must arrive at each
  # member in their sequence.

  @callback join(name :: String.t(), member :: pid()) :: :ok
  @callback leave(name :: String.t(), member :: pid()) :: :ok
  @callback broadcast(name :: String.t(), sender :: pid(), message :: term()) :: :ok

  @doc false
  @spec callback_contract() :: keyword()
  def callback_contract do
    [join: 2, leave: 2, broadcast: 3]
  end
end
