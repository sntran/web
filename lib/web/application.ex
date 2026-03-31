defmodule Web.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Web.TaskSupervisor},
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
