defmodule Web.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Web.Performance.put_time_origin()
    ensure_broadcast_channel_runtime_table()

    # Eagerly initialize the url_params singleton in :persistent_term so that
    # the Variable handle is stable across all processes from the moment the
    # application boots.
    Web.URLPattern.params()

    children = [
      %{id: :pg, start: {:pg, :start_link, []}},
      {Registry, keys: :unique, name: Web.Registry, partitions: System.schedulers_online()},
      Web.BroadcastChannel.DispatcherSupervisor,
      {Task.Supervisor, name: Web.TaskSupervisor},
      Web.URLPattern.Cache,
      {Finch,
       name: Web.Finch,
       pools: %{
         # Sensible default for high-concurrency assets
         :default => [size: 25, count: 1]
       }}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Web.Supervisor)
  end

  defp ensure_broadcast_channel_runtime_table do
    if :ets.whereis(Web.BroadcastChannel.ChannelServer.Runtime) == :undefined do
      :ets.new(Web.BroadcastChannel.ChannelServer.Runtime, [
        :named_table,
        :public,
        :set,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])
    end

    :ok
  end
end
