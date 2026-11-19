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
      # The function reads the settings each time the pools start.
      %{id: Web.Finch, start: {__MODULE__, :start_finch, []}, type: :supervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Web.Supervisor)
  end

  @default_connect_timeout 10_000
  @default_unread_body_timeout 300_000
  @default_http_protocols [:http1]
  @http_protocols_key {__MODULE__, :http_protocols}

  @doc false
  # Starts the pools of the HTTP connections with the settings of the
  # application.
  def start_finch do
    protocols = configured_http_protocols()
    :persistent_term.put(@http_protocols_key, protocols)
    Finch.start_link(name: Web.Finch, pools: finch_pools(protocols))
  end

  @doc false
  # The HTTP versions that the pools use, from the setting `:http_protocols`:
  # `[:http1]` (the default), `[:http2]`, or `[:http1, :http2]`. With the two
  # versions, a TLS connection uses the version that the server selects.
  # The pools read the setting when they start.
  @spec http_protocols() :: [:http1 | :http2]
  def http_protocols, do: :persistent_term.get(@http_protocols_key, @default_http_protocols)

  defp configured_http_protocols do
    protocols = Application.get_env(:web, :http_protocols, @default_http_protocols)
    sorted = protocols |> List.wrap() |> Enum.uniq() |> Enum.sort()

    if sorted in [[:http1], [:http2], [:http1, :http2]] do
      sorted
    else
      raise ArgumentError,
            "The setting :http_protocols of :web must be [:http1], [:http2], or " <>
              "[:http1, :http2], got: #{inspect(protocols)}"
    end
  end

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
  def finch_pools(protocols \\ @default_http_protocols) do
    %{
      :default => [
        protocols: protocols,
        size: 25,
        count: 1,
        conn_opts: [transport_opts: [timeout: connect_timeout()]]
      ]
    }
  end
end
