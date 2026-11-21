defmodule Web.Application do
  @moduledoc false

  use Application

  alias Web.Internal.LazyStream

  @impl true
  def start(_type, _args) do
    Web.Performance.put_time_origin()

    # Eagerly initialize the url_params singleton in :persistent_term so that
    # the Variable handle is stable across all processes from the moment the
    # application boots.
    Web.URLPattern.params()

    children = [
      # The groups of the broadcast channels. The scope has its own name,
      # thus it does not conflict with a `:pg` scope of the application.
      Web.BroadcastChannel.Adapter.PG,
      # The servers of the message ports, the broadcast channels, and the
      # sockets.
      {DynamicSupervisor, name: Web.HandleSupervisor, strategy: :one_for_one},
      Web.AbortSignal.Reasons,
      # The blob URL store of `Web.URL.create_object_url/1`.
      Web.Internal.BlobURLStore,
      # The stream processes of the streams that started with no process:
      # see `Web.Internal.LazyStream`.
      {Registry,
       keys: :unique, name: LazyStream.registry(), partitions: System.schedulers_online()},
      Web.URLPattern.Cache,
      # The pools of the HTTP connections. The function reads the setting
      # `:http_protocols` each time the pools start.
      %{id: Web.Dispatcher.HTTP, start: {__MODULE__, :start_http, []}, type: :supervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Web.Supervisor)
  end

  @default_connect_timeout 10_000
  @default_unread_body_timeout 300_000
  @default_http_protocols [:http1]
  @http_protocols_key {__MODULE__, :http_protocols}

  @doc false
  # Starts the pools of the HTTP connections with the setting
  # `:http_protocols`. Each origin gets its pool, or its HTTP/2 connection,
  # at its first request: see `Web.Dispatcher.HTTP.Pool` and
  # `Web.Dispatcher.HTTP.Multiplex`. A new connection reads the settings
  # `:connect_timeout` and `:tls_options`.
  def start_http do
    protocols = configured_http_protocols()
    :persistent_term.put(@http_protocols_key, protocols)

    children = [
      {Registry, keys: :unique, name: Web.Dispatcher.HTTP.Registry},
      {DynamicSupervisor, name: Web.Dispatcher.HTTP.Connections, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_all)
  end

  @doc false
  # The TLS options of `Web.fetch/2` and `Web.connect/2`, from the setting
  # `:tls_options`: a keyword list of options of the application `:ssl` of
  # Erlang. For example, `cacertfile: path` names a file of certificate
  # authorities. Without the setting, the trust store of the operating
  # system is used.
  @spec tls_options() :: keyword()
  def tls_options, do: configured_tls_options()

  defp configured_tls_options do
    options = Application.get_env(:web, :tls_options, [])

    if Keyword.keyword?(options) do
      options
    else
      raise ArgumentError,
            "The setting :tls_options of :web must be a keyword list, got: #{inspect(options)}"
    end
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
end
