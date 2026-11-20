defmodule Web.TLA.SharedConnectionPropertyTest do
  # Checks the properties of `tla/SharedConnection.tla` on the real shared
  # HTTP/2 connection of `Web.Dispatcher.HTTP.Multiplex`.
  #
  # A server allows a random number of streams on a connection, and closes
  # each connection for new streams (GOAWAY) after a random number of
  # requests. A random number of requests go at the same time. The server
  # counts how many times it runs each request, and its streams at the same
  # time. The test changes the HTTP versions, thus it does not run at the
  # same time as other tests.
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag capture_log: true

  defmodule Server do
    @moduledoc false
    import Plug.Conn

    def init(options), do: options

    # Each request has its number in the path. The server counts its runs,
    # and the streams that it runs at the same time on each connection: the
    # port of the client names the connection.
    def call(conn, options) do
      table = Keyword.fetch!(options, :table)
      %{port: client} = get_peer_data(conn)
      running = :ets.update_counter(table, {:running, client}, 1, {{:running, client}, 0})
      raise_largest(table, {:largest, client}, running)

      {:ok, body, conn} = read_body(conn)
      "/" <> id = conn.request_path
      :ets.update_counter(table, {:runs, id}, 1, {{:runs, id}, 0})
      # The body of the request gives the time of the work: a random pause.
      Process.sleep(String.to_integer(body))
      :ets.update_counter(table, {:running, client}, -1)
      send_resp(conn, 200, id)
    end

    defp raise_largest(table, key, running) do
      :ets.insert_new(table, {key, 0})
      [{^key, largest}] = :ets.lookup(table, key)
      pattern = [{{key, largest}, [], [{{{key}, running}}]}]

      if running > largest and :ets.select_replace(table, pattern) == 0,
        do: raise_largest(table, key, running)
    end
  end

  setup do
    previous = Application.get_env(:web, :http_protocols)
    Application.put_env(:web, :http_protocols, [:http2])
    restart_pools()

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:web, :http_protocols),
        else: Application.put_env(:web, :http_protocols, previous)

      restart_pools()
    end)
  end

  defp restart_pools do
    :ok = Supervisor.terminate_child(Web.Supervisor, Web.Dispatcher.HTTP)
    {:ok, _pid} = Supervisor.restart_child(Web.Supervisor, Web.Dispatcher.HTTP)
  end

  # With one stream at a time, a stream does not run when the server closes
  # its connection: each request has its response.
  property "with one stream at a time, each request ends with its response, and runs one time" do
    check all(
            requests_each <- member_of([0, 1, 2, 3]),
            pauses <- list_of(integer(0..5), min_length: 1, max_length: 10),
            max_runs: 25
          ) do
      {outcomes, server} = run_requests(1, requests_each, pauses)

      for {outcome, id} <- outcomes do
        # EachRequestEnds, and ErrorOnlyAfterFailure.
        assert {:fulfilled, response} = outcome
        assert Web.await(Web.Response.text(response)) == "#{id}"
        # AtMostOnce: the server ran the request one time.
        assert runs(server, id) == 1
      end

      assert_streams_bounded(server, 1)
      stop(server)
    end
  end

  # With more streams, the server can close a connection while it runs
  # streams on it: a request that can have run gives an error, and does
  # not go again.
  property "the server runs each request one time at most, and a request fails only when its connection closed" do
    check all(
            streams <- integer(1..3),
            requests_each <- member_of([0, 1, 2, 3]),
            pauses <- list_of(integer(0..5), min_length: 1, max_length: 10),
            max_runs: 25
          ) do
      {outcomes, server} = run_requests(streams, requests_each, pauses)

      for {outcome, id} <- outcomes do
        case outcome do
          {:fulfilled, response} ->
            assert Web.await(Web.Response.text(response)) == "#{id}"
            assert runs(server, id) == 1

          # ErrorOnlyAfterFailure: a request that the server did not
          # process went again, thus the only error is a closed connection.
          {:rejected, error} ->
            assert %Web.TypeError{cause: %Mint.TransportError{reason: :closed}} = error
            assert runs(server, id) <= 1
        end
      end

      assert_streams_bounded(server, streams)
      stop(server)
    end
  end

  # A server with its limits, the first request, and then the requests with
  # the pauses at the same time. Each request ends: the test waits for each
  # outcome.
  defp run_requests(streams, requests_each, pauses) do
    table = :ets.new(:runs, [:public, :set])

    http_2_options = [
      max_requests: requests_each,
      default_local_settings: [max_concurrent_streams: streams]
    ]

    {:ok, pid} =
      Bandit.start_link(
        plug: {Server, table: table},
        scheme: :http,
        port: 0,
        startup_log: false,
        http_2_options: http_2_options
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    server = %{pid: pid, table: table}

    # The first request makes the connection, and the settings of the
    # server come.
    assert Web.await(Web.fetch("http://localhost:#{port}/0", method: "POST", body: "0")).ok

    outcomes =
      pauses
      |> Enum.with_index(1)
      |> Enum.map(fn {pause, id} ->
        {Web.fetch("http://localhost:#{port}/#{id}", method: "POST", body: "#{pause}"), id}
      end)
      |> Enum.map(fn {promise, id} -> {Web.Promise.wait(promise), id} end)

    {outcomes, server}
  end

  defp runs(server, id) do
    case :ets.lookup(server.table, {:runs, "#{id}"}) do
      [{_key, runs}] -> runs
      [] -> 0
    end
  end

  # StreamsBounded: no connection had more streams than the server allows.
  defp assert_streams_bounded(server, streams) do
    largest = :ets.select(server.table, [{{{:largest, :_}, :"$1"}, [], [:"$1"]}])
    assert Enum.max(largest) <= streams
  end

  defp stop(server) do
    Supervisor.stop(server.pid)
    :ets.delete(server.table)
  end
end
