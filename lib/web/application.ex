defmodule Web.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Web.Performance.put_time_origin()

    # Eagerly initialize the url_params singleton in :persistent_term so that
    # the Variable handle is stable across all processes from the moment the
    # application boots.
    Web.URLPattern.params()

    children = [
      %{id: :pg, start: {:pg, :start_link, []}},
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
end
