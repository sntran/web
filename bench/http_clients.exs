Mix.Task.run("app.start")

defmodule Web.Benchmarks.HTTPClients do
  @moduledoc false

  # Compares `Web.fetch/2` with Finch and Req, with the same server and the
  # same number of connections.
  #
  #   * Finch and Req use one Finch pool of 25 HTTP/1.1 connections, which
  #     the script starts: Req gets it with the option `finch: [name: ...]`.
  #     `Web.fetch/2` has its own pool of 25 connections for the origin.
  #   * The server sends no compressed response, thus each client gets the
  #     same bytes.
  #   * Each pair does the same work: `Req.get!` with its JSON decode and
  #     `fetch` with `json/1` give a map, and `Req.get!` with no decode and
  #     `fetch` with `text/1` give a binary.
  #
  # Usage: mix run bench/http_clients.exs

  defmodule Server do
    @moduledoc false
    @behaviour Plug

    @big 256 * 1024 * 1024
    @chunk :binary.copy(<<0>>, 1024 * 1024)

    @impl true
    def init(options), do: options

    @impl true
    def call(%{request_path: "/big"} = conn, _options) do
      conn =
        conn
        |> Plug.Conn.put_resp_header("content-length", Integer.to_string(@big))
        |> Plug.Conn.send_chunked(200)

      Enum.reduce(1..div(@big, byte_size(@chunk)), conn, fn _index, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, @chunk)
        conn
      end)
    end

    def call(conn, _options) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"ok":true,"items":[1,2,3]}))
    end
  end

  # The clients run in turns: each round runs each client one time. Thus a
  # slow time of the machine has an effect on each client, not on one only.
  @rounds 8
  @sequential 400
  @processes 50
  @requests_each 100

  def run do
    {:ok, server} =
      Bandit.start_link(
        plug: Server,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false,
        http_options: [compress: false]
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, _finch} = Finch.start_link(name: __MODULE__.Finch, pools: %{default: [size: 25]})
    run(port)
  end

  def run(port) do
    small = "http://127.0.0.1:#{port}/small"
    big = "http://127.0.0.1:#{port}/big"
    req = Req.new(retry: false, finch: [name: __MODULE__.Finch])

    clients = [
      {"Finch.request", fn -> finch_body(small) end},
      {"Req.get!, JSON decode", fn -> Req.get!(req, url: small).body end},
      {"Web.fetch + json", fn -> Web.await(Web.Response.json(Web.await(Web.fetch(small)))) end},
      {"Req.get!, no decode", fn -> Req.get!(req, url: small, decode_body: false).body end},
      {"Web.fetch + text", fn -> Web.await(Web.Response.text(Web.await(Web.fetch(small)))) end}
    ]

    # The pools open their connections, and the code is loaded.
    for {_label, client} <- clients, _index <- 1..300, do: client.()

    IO.puts(
      "== A small JSON response, one request at a time " <>
        "(median of #{@rounds * @sequential}, in #{@rounds} rounds)"
    )

    samples =
      in_turns(clients, fn client ->
        for _index <- 1..@sequential, do: elem(:timer.tc(client), 0)
      end)

    for {label, _client} <- clients do
      times = Enum.sort(samples[label])
      IO.puts(row(label, "#{Enum.at(times, div(length(times), 2))} µs"))
    end

    IO.puts(
      "== A small JSON response, #{@processes} processes at the same time " <>
        "(median of #{@rounds} rounds)"
    )

    rates = in_turns(clients, &[rate(&1)])

    for {label, _client} <- clients do
      values = Enum.sort(rates[label])
      IO.puts(row(label, "#{Enum.at(values, div(length(values), 2))} requests/s"))
    end

    IO.puts("== A body of 256 MiB")

    bodies = [
      {"Req.get!, body in memory", fn -> byte_size(Req.get!(req, url: big).body) end},
      {"Req.get!, into: a function", fn -> req_stream(req, big) end},
      {"Web.fetch, body read with Enum", fn -> fetch_stream(big) end},
      {"Web.fetch + array_buffer", fn -> fetch_buffer(big) end}
    ]

    for {label, client} <- bodies do
      # One read first: the pool and the code are ready.
      _bytes = client.()
      {time, bytes, memory} = with_peak_memory(client)
      speed = round(bytes / 1_048_576 / (time / 1_000_000))
      IO.puts(row(label, "#{speed} MiB/s, memory +#{div(memory, 1_048_576)} MiB"))
    end
  end

  # Runs `measure` for each client in each round. Returns the results of
  # each client, as one list.
  defp in_turns(clients, measure) do
    Enum.reduce(1..@rounds, %{}, fn _round, acc ->
      Enum.reduce(clients, acc, fn {label, client}, acc ->
        result = measure.(client)
        Map.update(acc, label, result, &(result ++ &1))
      end)
    end)
  end

  defp rate(client) do
    {time, _failures} =
      :timer.tc(fn ->
        1..@processes
        |> Enum.map(fn _index -> Task.async(fn -> run_requests(client) end) end)
        |> Task.await_many(120_000)
        |> Enum.sum()
      end)

    round(@processes * @requests_each / (time / 1_000_000))
  end

  defp run_requests(client), do: Enum.count(1..@requests_each, &failed?(client, &1))

  # A request that fails is counted, and the benchmark continues.
  defp failed?(client, _index) do
    _result = client.()
    false
  catch
    _kind, _reason -> true
  end

  defp finch_body(url) do
    {:ok, response} = Finch.request(Finch.build(:get, url), __MODULE__.Finch)
    response.body
  end

  defp req_stream(req, url) do
    counter = :counters.new(1, [])

    Req.get!(req,
      url: url,
      into: fn {:data, data}, acc ->
        :counters.add(counter, 1, byte_size(data))
        {:cont, acc}
      end
    )

    :counters.get(counter, 1)
  end

  defp fetch_stream(url) do
    response = Web.await(Web.fetch(url))
    Enum.reduce(response.body, 0, fn chunk, bytes -> bytes + chunk.byte_length end)
  end

  defp fetch_buffer(url) do
    response = Web.await(Web.fetch(url))
    Web.ArrayBuffer.byte_length(Web.await(Web.Response.array_buffer(response)))
  end

  # The time, the result, and the largest increase of the memory of the VM.
  defp with_peak_memory(fun) do
    :erlang.garbage_collect()
    start = :erlang.memory(:total)
    parent = self()

    sampler =
      spawn(fn ->
        sample = fn sample, peak ->
          receive do
            :stop -> send(parent, {:peak, peak})
          after
            5 -> sample.(sample, max(peak, :erlang.memory(:total)))
          end
        end

        sample.(sample, start)
      end)

    {time, result} = :timer.tc(fun)
    send(sampler, :stop)

    peak =
      receive do
        {:peak, peak} -> peak
      end

    {time, result, max(peak - start, 0)}
  end

  defp row(label, value), do: String.pad_trailing(label, 36) <> value
end

Web.Benchmarks.HTTPClients.run()
