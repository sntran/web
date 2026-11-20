defmodule Web.TLA.SocketFlowPropertyTest do
  # Checks the properties of `tla/SocketFlow.tla` on the real process of a
  # request of `Web.Dispatcher.HTTP`.
  #
  # A server sends a random body in random chunks, with random pauses. A
  # reader reads the body with random pauses. After each read, the test
  # examines the process of the request: its mailbox, its flag, and the
  # bytes that it keeps. At the end, the reader has the full body, and the
  # process does not read its socket.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Dispatcher.HTTP.Exchange
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultReader

  @limit 65_536

  defp body do
    gen all(
          parts <-
            list_of(
              one_of([
                binary(min_length: 1, max_length: 2_000),
                map(integer(1..40_000), &:crypto.strong_rand_bytes/1),
                map(integer(1..60_000), &:binary.copy("x", &1))
              ]),
              min_length: 1,
              max_length: 12
            )
        ) do
      IO.iodata_to_binary(parts)
    end
  end

  property "the process reads one message at a time, and the reader gets the full body" do
    check all(
            body <- body(),
            coding <- member_of([:identity, :gzip]),
            sizes <- list_of(integer(500..48_000), min_length: 1, max_length: 30),
            pauses <- list_of(integer(0..3), min_length: 1, max_length: 30),
            reads <- list_of(integer(0..4), min_length: 1, max_length: 30),
            upload <- one_of([constant(nil), list_of(integer(1..3), max_length: 8)]),
            max_runs: 40
          ) do
      encoded = if coding == :gzip, do: :zlib.gzip(body), else: body
      port = start_server(encoded, coding, sizes, pauses)
      response = Web.await(Web.fetch("http://localhost:#{port}/", request(upload)))

      case response.body.lazy.source do
        {:held, process} ->
          :erlang.trace(process, true, [:receive])
          reader = ReadableStream.get_reader(response.body)
          assert read_all(reader, process, reads, []) == body
          assert_no_read_after_end(process)

        # The body came in 1 ms: it is in the struct.
        {:bytes, bytes} ->
          assert bytes == body
      end
    end
  end

  # With a list of pauses, the request has a body from a stream: the
  # response comes while the chunks of the request go.
  defp request(nil), do: []

  defp request(pauses) do
    chunks =
      Stream.map(pauses, fn pause ->
        Process.sleep(pause)
        "chunk"
      end)

    [method: "POST", body: ReadableStream.from(chunks), duplex: "half"]
  end

  defp read_all(reader, process, [pause | reads], acc) do
    Process.sleep(pause)

    case Web.await(ReadableStreamDefaultReader.read(reader)) do
      %{done: true} ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()

      %{value: chunk} ->
        assert_flow(process)
        read_all(reader, process, reads ++ [pause], [Web.Uint8Array.to_binary(chunk) | acc])
    end
  end

  # The properties of the specification, on the real process.
  defp assert_flow(process) do
    with {:messages, messages} <- Process.info(process, :messages),
         {:dictionary, dictionary} <- Process.info(process, :dictionary) do
      socket_messages = Enum.filter(messages, &match?({:tcp, _socket, _data}, &1))
      state = :proplists.get_value({Exchange, :state}, dictionary)
      inflight = :proplists.get_value({Exchange, :inflight}, dictionary)

      # MailboxBounded: one message of the socket at most.
      assert length(socket_messages) <= 1

      # The flag is cleared only when the process handles the message.
      if socket_messages != [] and state.phase == :open, do: assert(state.armed?)

      # BufferBounded: the process asks only below its limit. One message,
      # or one piece of the decoder, can come after the limit.
      assert inflight <= @limit + max(largest_message(process), 200_000)
    end
  end

  # The size of the largest message of the socket that the process got. The
  # trace events come after the messages: the test waits for each event of
  # a message that the process got before this time.
  defp largest_message(process) do
    ref = :erlang.trace_delivered(process)

    receive do
      {:trace_delivered, ^process, ^ref} -> :ok
    end

    sizes =
      Stream.repeatedly(fn ->
        receive do
          {:trace, ^process, :receive, {:tcp, _socket, data}} -> byte_size(data)
          {:trace, ^process, :receive, _other} -> 0
        after
          0 -> nil
        end
      end)

    largest = sizes |> Enum.take_while(& &1) |> Enum.max(fn -> 0 end)
    largest = max(largest, Process.get(:largest_message, 0))
    Process.put(:largest_message, largest)
    largest
  end

  # NoReadAfterEnd: after the end of the response, the process does not ask
  # its socket for a message.
  defp assert_no_read_after_end(process) do
    case Process.info(process, :dictionary) do
      {:dictionary, dictionary} ->
        state = :proplists.get_value({Exchange, :state}, dictionary)
        refute state.phase == :open and state.armed?

      # The process stopped at the end of the body.
      nil ->
        :ok
    end

    Process.delete(:largest_message)
  end

  # A server that sends the response in chunks of the sizes, with the
  # pauses in milliseconds between them.
  defp start_server(encoded, coding, sizes, pauses) do
    test = self()

    spawn_link(fn ->
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listener)
      send(test, {:port, port})
      {:ok, socket} = :gen_tcp.accept(listener)
      {:ok, _request} = :gen_tcp.recv(socket, 0)

      encoding = if coding == :gzip, do: "Content-Encoding: gzip\r\n", else: ""
      head = "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(encoded)}\r\n#{encoding}\r\n"
      :ok = :gen_tcp.send(socket, head)
      send_chunks(socket, encoded, sizes, pauses)

      # The server reads the rest of the request until the client closes the
      # connection. A socket that closes with bytes that it did not read
      # sends a reset, and the reset can drop the end of the response.
      drain(socket)
    end)

    receive do
      {:port, port} -> port
    end
  end

  defp drain(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, _data} -> drain(socket)
      {:error, _reason} -> :ok
    end
  end

  # The lists of sizes and pauses start again at their end.
  defp send_chunks(_socket, <<>>, _sizes, _pauses), do: :ok

  defp send_chunks(socket, data, [size | sizes], [pause | pauses]) do
    size = min(size, byte_size(data))
    :ok = :gen_tcp.send(socket, binary_part(data, 0, size))
    Process.sleep(pause)
    rest = binary_part(data, size, byte_size(data) - size)
    send_chunks(socket, rest, sizes ++ [size], pauses ++ [pause])
  end
end
