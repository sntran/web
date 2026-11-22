defmodule Web.TLA.SocketFlowPropertyTest do
  # Checks the properties of `tla/SocketFlow.tla` on the real process of a
  # request of `Web.Dispatcher.HTTP`, and of `Web.Dispatcher.TCP`.
  #
  # A server sends a random body in random chunks, with random pauses. A
  # reader reads the body with random pauses. After each read, the test
  # examines the process of the request: its mailbox, its flag, and the
  # bytes that it keeps. At the end, the reader has the full body, and the
  # process does not read its socket.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Dispatcher.HTTP.Exchange
  alias Web.Dispatcher.TCP.Connection
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
          assert read_all(reader, {process, Exchange}, reads, []) == body
          assert_no_read_after_end(process, Exchange)

        # The body came in 1 ms: it is in the struct.
        {:bytes, bytes} ->
          assert bytes == body
      end
    end
  end

  property "a tcp: request reads one message at a time, and the reader gets the full body" do
    check all(
            body <- body(),
            sizes <- list_of(integer(500..48_000), min_length: 1, max_length: 30),
            pauses <- list_of(integer(0..3), min_length: 1, max_length: 30),
            reads <- list_of(integer(0..4), min_length: 1, max_length: 30),
            wait? <- boolean(),
            max_runs: 40
          ) do
      {port, server} = start_tcp_server(body, sizes, pauses)

      # The trace starts before the server sends: the test sees each
      # message of the socket.
      promise = Web.fetch("tcp://localhost:#{port}")
      :erlang.trace(promise.pid, true, [:receive])
      send(server, :go)
      response = Web.await(promise)

      case response.body.lazy.source do
        {:held, process} ->
          if wait?, do: wait_at_rest(process, port)
          reader = ReadableStream.get_reader(response.body)
          assert read_all(reader, {process, Connection}, reads, []) == body
          assert_no_read_after_end(process, Connection)

        {:bytes, bytes} ->
          assert bytes == body
          flush_trace(promise.pid)
      end
    end
  end

  # The reader waits until the server sent the full body, and until the
  # process does not ask for more: at the limit, or at the end. Then the
  # buffer has its largest size.
  defp wait_at_rest(process, port) do
    assert_receive {:tcp_server_done, ^port}, 5_000

    at_rest = fn ->
      case Process.info(process, :dictionary) do
        {:dictionary, dictionary} ->
          state = :proplists.get_value({Connection, :state}, dictionary)
          state.phase != :open or not state.armed?

        nil ->
          true
      end
    end

    eventually(at_rest)
    assert_flow({process, Connection})
  end

  defp eventually(fun, attempts \\ 400) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
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

  defp read_all(reader, target, [pause | reads], acc) do
    Process.sleep(pause)

    case Web.await(ReadableStreamDefaultReader.read(reader)) do
      %{done: true} ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()

      %{value: chunk} ->
        assert_flow(target)
        read_all(reader, target, reads ++ [pause], [to_string(chunk) | acc])
    end
  end

  # The properties of the specification, on the real process. The process
  # is suspended while the test examines it: its state, its mailbox, and
  # its socket are then one snapshot.
  defp assert_flow({process, network}) do
    if suspend(process) do
      try do
        assert_snapshot(process, network)
      after
        :erlang.resume_process(process)
      end
    end
  end

  defp assert_snapshot(process, network) do
    {:dictionary, dictionary} = Process.info(process, :dictionary)
    state = :proplists.get_value({network, :state}, dictionary)
    inflight = :proplists.get_value({network, :inflight}, dictionary)

    # The socket first: a message that comes after this is in the mailbox.
    active = active(socket(network, state))
    {:messages, messages} = Process.info(process, :messages)
    socket_messages = Enum.filter(messages, &match?({:tcp, _socket, _data}, &1))

    # MailboxBounded: one message of the socket at most.
    assert length(socket_messages) <= 1

    # FlagMatchesSocket: the process asked when the socket can send a
    # message, or when a message is in the mailbox. A message can be on its
    # way from the socket to the mailbox, thus the test does not examine
    # the other direction.
    if state.phase == :open and (active == :once or socket_messages != []),
      do: assert(state.armed?)

    # BufferBounded: the process asks only below its limit. One message can
    # come after the limit, and for HTTP one piece of the decoder.
    assert inflight <= @limit + slack(network, largest_message(process))
  end

  defp suspend(process) do
    :erlang.suspend_process(process)
  rescue
    # The process stopped at the end of the body.
    ArgumentError -> false
  end

  defp socket(Exchange, %{conn: nil}), do: nil
  defp socket(Exchange, %{conn: conn}), do: Mint.HTTP.get_socket(conn)
  defp socket(Connection, %{socket: socket}), do: socket

  defp active(nil), do: false

  defp active(socket) do
    case :inet.getopts(socket, [:active]) do
      {:ok, [active: active]} -> active
      {:error, _closed} -> false
    end
  end

  defp slack(Exchange, largest), do: max(largest, 200_000)
  defp slack(Connection, largest), do: largest

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
  defp assert_no_read_after_end(process, network) do
    case Process.info(process, :dictionary) do
      {:dictionary, dictionary} ->
        state = :proplists.get_value({network, :state}, dictionary)
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

  # A server of bytes with no protocol: at the message `:go`, it sends the
  # body in chunks, and closes the connection. The client sends nothing.
  defp start_tcp_server(body, sizes, pauses) do
    test = self()

    server =
      spawn_link(fn ->
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
        {:ok, port} = :inet.port(listener)
        send(test, {:port, port})
        {:ok, socket} = :gen_tcp.accept(listener)

        receive do
          :go -> send_chunks(socket, body, sizes, pauses)
        end

        send(test, {:tcp_server_done, port})
        :gen_tcp.close(socket)
      end)

    receive do
      {:port, port} -> {port, server}
    end
  end

  # The trace messages of a process that stopped go away.
  defp flush_trace(process) do
    ref = :erlang.trace_delivered(process)

    receive do
      {:trace_delivered, ^process, ^ref} -> :ok
    end

    flush_trace_messages(process)
  end

  defp flush_trace_messages(process) do
    receive do
      {:trace, ^process, _event, _message} -> flush_trace_messages(process)
    after
      0 -> :ok
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
