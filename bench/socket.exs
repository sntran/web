# Measures a read and a write of 64 MiB on a `Web.connect/2` socket, and a
# read with raw `:gen_tcp` in the process that reads, in turns.
#
#     mix run bench/socket.exs

defmodule Bench.Socket.Server do
  # A server on the machine. The first byte of a connection selects the
  # work: "r" sends 64 MiB, and "w" reads until the client closes.
  def start(chunk, count) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, backlog: 64])
    {:ok, port} = :inet.port(listener)
    spawn(fn -> accept(listener, chunk, count) end)
    port
  end

  defp accept(listener, chunk, count) do
    {:ok, socket} = :gen_tcp.accept(listener)
    pid = spawn(fn -> serve(socket, chunk, count) end)
    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, :go)
    accept(listener, chunk, count)
  end

  defp serve(socket, chunk, count) do
    receive do
      :go -> :ok
    end

    case :gen_tcp.recv(socket, 1) do
      {:ok, "r"} -> for _index <- 1..count, do: :gen_tcp.send(socket, chunk)
      {:ok, "w"} -> read_to_close(socket)
    end

    :gen_tcp.close(socket)
  end

  defp read_to_close(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, _data} -> read_to_close(socket)
      {:error, _closed} -> :ok
    end
  end
end

alias Web.WritableStream
alias Web.WritableStreamDefaultWriter

chunk = :binary.copy("x", 65_536)
count = 1_024
size = count * 65_536
port = Bench.Socket.Server.start(chunk, count)

web_read = fn ->
  socket = Web.connect("127.0.0.1:#{port}")
  writer = WritableStream.get_writer(socket.writable)
  Web.await(WritableStreamDefaultWriter.write(writer, "r"))
  WritableStreamDefaultWriter.release_lock(writer)

  ^size =
    Enum.reduce(socket.readable, 0, fn chunk, total ->
      total + byte_size(to_string(chunk))
    end)
end

web_write = fn ->
  socket = Web.connect("127.0.0.1:#{port}")
  writer = WritableStream.get_writer(socket.writable)
  Web.await(WritableStreamDefaultWriter.write(writer, "w"))
  for _index <- 1..count, do: Web.await(WritableStreamDefaultWriter.write(writer, chunk))
  Web.await(WritableStreamDefaultWriter.close(writer))
end

raw_read = fn ->
  {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
  :ok = :gen_tcp.send(socket, "r")

  read = fn read, total ->
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} -> read.(read, total + byte_size(data))
      {:error, :closed} -> total
    end
  end

  ^size = read.(read, 0)
end

rate = fn fun ->
  {time, _result} = :timer.tc(fun)
  round(size / 1_048_576 / (time / 1_000_000))
end

cases = [
  {"Web.connect read", web_read},
  {"raw gen_tcp read", raw_read},
  {"Web.connect write", web_write}
]

results =
  for _round <- 1..5, {name, fun} <- cases, reduce: %{} do
    results ->
      value = rate.(fun)
      Map.update(results, name, [value], &[value | &1])
  end

for {name, _fun} <- cases do
  rates = Enum.sort(results[name])
  IO.puts("#{String.pad_trailing(name, 20)} median #{Enum.at(rates, 2)} MiB/s")
end
