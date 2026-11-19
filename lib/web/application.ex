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
      Web.AbortSignal.Reasons,
      Web.URLPattern.Cache,
      {Finch, name: Web.Finch, pools: finch_pools()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Web.Supervisor)
  end

  @default_connect_timeout 10_000
  @default_unread_body_timeout 300_000

  @doc false
  # The time that the body of a `Web.fetch/2` response stays when no process
  # starts to read it. After that time the body releases its connection.
  @spec unread_body_timeout() :: non_neg_integer() | :infinity
  def unread_body_timeout do
    Application.get_env(:web, :unread_body_timeout, @default_unread_body_timeout)
  end

  @doc false
  # The time that `Web.fetch/2` and `Web.connect/2` wait for a connection.
  @spec connect_timeout() :: non_neg_integer() | :infinity
  def connect_timeout do
    Application.get_env(:web, :connect_timeout, @default_connect_timeout)
  end

  @doc false
  # The pools of the HTTP connections. Each origin has 25 connections. A
  # request waits for a connection when all of them are in use.
  def finch_pools do
    %{
      :default => [
        size: 25,
        count: 1,
        conn_opts: [transport_opts: [timeout: connect_timeout()]]
      ]
    }
  end
end
