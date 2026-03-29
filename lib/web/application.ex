defmodule Web.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch,
        name: Web.Finch,
        pools: %{
          :default => [size: 25, count: 1] # Sensible default for high-concurrency assets
        }}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Web.Supervisor)
  end
end
