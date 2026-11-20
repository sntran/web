# Measures `Web.fetch/2` of a `tcp:` URL on one server of the machine.
#
#     mix run bench/tcp_fetch.exs
#
# The script measures the processes of a body that no process reads yet, a
# small response, and a stream read of a large body.

defmodule Bench.TCPFetch.Server do
  # A server that accepts each connection, and answers with `reply`.
  def start(reply) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, backlog: 1_024])

    {:ok, port} = :inet.port(listener)
    spawn(fn -> accept(listener, reply) end)
    port
  end

  defp accept(listener, reply) do
    {:ok, socket} = :gen_tcp.accept(listener)
    pid = spawn(fn -> serve(socket, reply) end)
    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, :go)
    accept(listener, reply)
  end

  defp serve(socket, reply) do
    receive do
      :go -> :ok
    end

    case reply do
      # The connection stays open: the body does not end.
      {:hold, data} ->
        :gen_tcp.send(socket, data)
        :gen_tcp.recv(socket, 0, 60_000)

      {:large, chunk, count} ->
        for _index <- 1..count, do: :gen_tcp.send(socket, chunk)

      data ->
        :gen_tcp.send(socket, data)
    end

    :gen_tcp.close(socket)
  end
end

alias Bench.TCPFetch.Server

median = fn list -> list |> Enum.sort() |> Enum.at(div(length(list), 2)) end

# The processes of 100 bodies that no process reads yet. Each request has a
# signal. The count does not include the processes of the server.
hold = Server.start({:hold, "data"})
Process.sleep(100)
before = :erlang.system_info(:process_count)
controller = Web.AbortController.new()

held =
  for _index <- 1..100 do
    Web.await(Web.fetch("tcp://localhost:#{hold}", signal: controller.signal))
  end

Process.sleep(100)
count = :erlang.system_info(:process_count) - before - 1 - 100
IO.puts("Processes for each body that no process reads: #{count / 100}")
for response <- held, do: Web.ReadableStream.cancel(response.body, :done)

# A small response: the server sends 5 bytes, and closes the connection.
small = Server.start("hello")

small_request = fn ->
  {time, "hello"} =
    :timer.tc(fn ->
      response = Web.await(Web.fetch("tcp://localhost:#{small}"))
      Web.await(Web.Response.text(response))
    end)

  time
end

for _index <- 1..200, do: small_request.()
times = for _index <- 1..2_000, do: small_request.()
IO.puts("Small response: median #{median.(times)} µs")

# A stream read of 64 MiB.
large = Server.start({:large, :binary.copy("x", 65_536), 1_024})

rates =
  for _index <- 1..5 do
    {time, size} =
      :timer.tc(fn ->
        response = Web.await(Web.fetch("tcp://localhost:#{large}"))

        Enum.reduce(response.body, 0, fn chunk, size ->
          size + byte_size(Web.Uint8Array.to_binary(chunk))
        end)
      end)

    round(size / 1_048_576 / (time / 1_000_000))
  end

IO.puts("Stream read of 64 MiB: median #{median.(rates)} MiB/s, runs #{inspect(rates, charlists: :as_lists)}")
