# A short tour of `Web`: fetch, streams, abort signals, and a governor.
#
# The script starts a small HTTP server on this machine, thus it needs no
# network.
#
# Usage: mix run examples/demo.exs

use Web

defmodule Demo.Server do
  # An HTTP server with two paths. "/slow" sends one line each 100 ms, with
  # no end. Each other path sends three lines.
  def start do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    spawn(fn -> accept(listen) end)
    "http://127.0.0.1:#{port}"
  end

  defp accept(listen) do
    {:ok, socket} = :gen_tcp.accept(listen)
    spawn(fn -> serve(socket) end)
    accept(listen)
  end

  defp serve(socket) do
    with {:ok, request} <- :gen_tcp.recv(socket, 0, 5_000) do
      :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n")
      :gen_tcp.send(socket, "transfer-encoding: chunked\r\n\r\n")

      if String.starts_with?(request, "GET /slow") do
        send_lines(socket, Stream.iterate(1, &(&1 + 1)))
      else
        send_lines(socket, 1..3)
        :gen_tcp.send(socket, "0\r\n\r\n")
        serve(socket)
      end
    end
  end

  defp send_lines(socket, numbers) do
    Enum.reduce_while(numbers, :ok, fn number, :ok ->
      line = "line #{number}\n"
      chunk = [Integer.to_string(byte_size(line), 16), "\r\n", line, "\r\n"]
      Process.sleep(100)
      if :gen_tcp.send(socket, chunk) == :ok, do: {:cont, :ok}, else: {:halt, :closed}
    end)
  end
end

base = Demo.Server.start()

IO.puts("1. fetch gives a response before the body is complete")
response = await(fetch(base <> "/lines"))
IO.puts("   status=#{response.status} type=#{Headers.get(response.headers, "content-type")}")

IO.puts("2. the body is a stream: each chunk arrives when the server sends it")

for chunk <- response.body do
  IO.puts("   chunk of #{chunk.byte_length} bytes: #{inspect(Uint8Array.to_binary(chunk))}")
end

IO.puts("3. a pipeline: split the stream, decode one branch, count the other")
[text_branch, count_branch] = ReadableStream.tee(await(fetch(base <> "/lines")).body)
count = Task.async(fn -> Enum.reduce(count_branch, 0, &(&1.byte_length + &2)) end)
text = text_branch |> ReadableStream.pipe_through(TextDecoderStream.new()) |> Enum.join()
IO.puts("   text=#{inspect(text)} bytes=#{Task.await(count)}")

IO.puts("4. an abort signal stops a response that has no end")
response = await(fetch(base <> "/slow", signal: AbortSignal.timeout(350)))

try do
  for chunk <- response.body, do: IO.puts("   got #{inspect(Uint8Array.to_binary(chunk))}")
rescue
  error in DOMException -> IO.puts("   the body stopped: #{error.name}")
end

IO.puts("5. a governor: six requests, two at a time")
governor = CountingGovernor.new(2)
started = System.monotonic_time(:millisecond)

statuses =
  for index <- 1..6 do
    Governor.with(governor, fn ->
      fetch(base <> "/lines?#{index}") |> Promise.then(&Response.text/1)
    end)
  end
  |> Promise.all()
  |> await()
  |> length()

IO.puts("   #{statuses} responses in #{System.monotonic_time(:millisecond) - started} ms")
