defmodule Web.TLA.SocketReadPropertyTest do
  # Checks the properties of `tla/SocketFlow.tla` on the server process of a
  # `Web.Socket`.
  #
  # A peer sends a random body in random chunks, with random pauses. A
  # reader reads the readable side with random pauses. After each read, the
  # test examines the server: its mailbox, its flag, its socket, and the
  # queue of the readable stream. At the end, the reader has the full body.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultReader

  # The high water mark of the readable side.
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

  property "the server reads one message at a time, and the reader gets the full body" do
    check all(
            body <- body(),
            sizes <- list_of(integer(500..48_000), min_length: 1, max_length: 30),
            pauses <- list_of(integer(0..3), min_length: 1, max_length: 30),
            reads <- list_of(integer(0..4), min_length: 1, max_length: 30),
            wait? <- boolean(),
            max_runs: 40
          ) do
      {port, peer} = start_peer(body, sizes, pauses)
      socket = Web.connect("127.0.0.1:#{port}")
      _info = Web.await(socket.opened)
      send(peer, :go)

      # The reader waits until the peer sent the full body, and until the
      # server does not ask for more: the queue then has its largest size.
      if wait? do
        assert_receive {:peer_done, ^port}, 5_000
        eventually(fn -> at_rest?(socket) end)
        assert_flow(socket)
      end

      reader = ReadableStream.get_reader(socket.readable)
      assert read_all(reader, socket, reads, []) == body
    end
  end

  defp read_all(reader, socket, [pause | reads], acc) do
    Process.sleep(pause)

    case Web.await(ReadableStreamDefaultReader.read(reader)) do
      %{done: true} ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()

      %{value: chunk} ->
        assert_flow(socket)
        read_all(reader, socket, reads ++ [pause], [Web.Uint8Array.to_binary(chunk) | acc])
    end
  end

  # The properties of the specification, on the real server. `:sys.suspend/1`
  # makes the server handle its earlier messages, and then it handles no
  # other message: its state, its mailbox, and its socket are one snapshot.
  defp assert_flow(socket) do
    server = socket.address

    if suspend(server) do
      try do
        assert_snapshot(socket, server)
      after
        :sys.resume(server)
      end
    end

    # BufferBounded: the stream pulls only below its limit, and the server
    # asks for one message for each pull. One message can come after the
    # limit: a message has 64 KiB at most. The stream keeps its queue also
    # after the server stopped.
    assert queued(socket) <= @limit + 65_536
  end

  defp assert_snapshot(socket, server) do
    state = :sys.get_state(server)
    active = active(state.socket)
    {:messages, messages} = Process.info(server, :messages)
    socket_messages = Enum.filter(messages, &match?({:tcp, _socket, _data}, &1))

    # MailboxBounded: one message of the socket at most.
    assert length(socket_messages) <= 1

    # FlagMatchesSocket: the server asked when the socket can send a
    # message, or when a message is in the mailbox.
    if active == :once or socket_messages != [], do: assert(state.active == :once)
  end

  defp suspend(server) do
    :sys.suspend(server)
    true
  catch
    # The server stopped at the end of the body.
    :exit, _reason -> false
  end

  defp active(nil), do: false

  defp active(socket) do
    case :inet.getopts(socket, [:active]) do
      {:ok, [active: active]} -> active
      {:error, _closed} -> false
    end
  end

  defp queued(socket) do
    socket.readable.controller_pid
    |> ReadableStream.__get_slots__()
    |> Map.get(:total_queued_size)
  catch
    :exit, _reason -> 0
  end

  # The server does not ask for more: at the limit, or at the end.
  defp at_rest?(socket) do
    state = :sys.get_state(socket.address)
    state.active == false and state.pull == nil
  catch
    :exit, _reason -> true
  end

  defp eventually(fun, attempts \\ 400) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  # A peer that sends the body in chunks at the message `:go`, with the
  # pauses in milliseconds between them, and then closes the connection.
  defp start_peer(body, sizes, pauses) do
    test = self()

    peer =
      spawn_link(fn ->
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
        {:ok, port} = :inet.port(listener)
        send(test, {:port, port})
        {:ok, socket} = :gen_tcp.accept(listener)

        receive do
          :go -> send_chunks(socket, body, sizes, pauses)
        end

        send(test, {:peer_done, port})
        :gen_tcp.close(socket)
      end)

    receive do
      {:port, port} -> {port, peer}
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
