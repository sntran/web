defmodule Web.TLA.SocketCloseConformanceTest do
  # Compares the real `Web.Socket` with the specification
  # `tla/SocketClose.tla`.
  #
  # The test makes a random list of commands, and a random value of the
  # option allowHalfOpen. It does each command on a real socket and on the
  # specification: the connect, a failure, the end of the data of the peer,
  # a cancel of the readable side, a close or an abort of the writer, and
  # close/2. Then the specification does its internal steps, and the test
  # waits until the real socket has the same state: the promises opened and
  # closed, the two streams, the transport, and the end of the data that the
  # peer got. The startTls() of the specification is not a command: a test
  # of `Web.SocketTest` does it on a TLS server.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Promise
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultReader
  alias Web.Socket
  alias Web.Test.SpecModel
  alias Web.WritableStream
  alias Web.WritableStreamDefaultWriter

  # The step that the socket does with no command: it reads the end of the
  # data of the peer.
  @internal [{"ReadEnd", []}]

  # A failure and close/2 end the run: they are less frequent.
  defp command do
    frequency([
      {4, constant("Connected")},
      {1, constant("Fail")},
      {3, constant("PeerFin")},
      {2, constant("Cancel")},
      {2, constant("CloseWriter")},
      {2, constant("AbortWriter")},
      {1, constant("Close")}
    ])
  end

  property "the socket closes as the specification permits" do
    check all(
            half_open? <- boolean(),
            commands <- list_of(command(), max_length: 12),
            max_runs: 100
          ) do
      replace = if half_open?, do: [{"HalfOpen = FALSE", "HalfOpen = TRUE"}]
      system = start_system(half_open?)

      try do
        Enum.reduce(commands, SpecModel.start("SocketClose", replace), fn command, model ->
          model = command |> run(model, system) |> SpecModel.settle(@internal)
          assert_same_state(model, system, command)
          model
        end)
      after
        stop_system(system)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The real system
  # ---------------------------------------------------------------------------

  # The connect of the socket waits for the command `Connected` or `Fail`.
  defp start_system(half_open?) do
    test = self()
    gate = make_ref()
    peer = start_peer()

    connect = fn host, port, options, timeout ->
      send(test, {:connect_blocked, gate, self()})

      receive do
        {^gate, :go} -> :gen_tcp.connect(host, port, options, timeout)
        {^gate, {:error, reason}} -> {:error, reason}
      end
    end

    socket =
      Socket.start_socket(self(), "127.0.0.1:#{peer.port}",
        connect_fun: connect,
        allow_half_open: half_open?
      )

    assert_receive {:connect_blocked, ^gate, connector}, 2_000
    reader = ReadableStream.get_reader(socket.readable)
    writer = WritableStream.get_writer(socket.writable)

    %{
      socket: socket,
      gate: gate,
      connector: connector,
      peer: peer,
      reader: reader,
      writer: writer,
      reader_closed: ReadableStreamDefaultReader.closed(reader),
      writer_closed: WritableStreamDefaultWriter.closed(writer)
    }
  end

  defp stop_system(system) do
    Socket.close(system.socket)
    send(system.peer.pid, :stop)
  end

  # The peer accepts the connection, sends the end of its data at the
  # command of the test, and tells if it got the end of the data of the
  # socket. It keeps its side open until the end of the test.
  defp start_peer do
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, exit_on_close: false])

        {:ok, port} = :inet.port(listener)
        send(test, {:peer_port, self(), port})
        peer_loop(listener, nil)
      end)

    receive do
      {:peer_port, ^pid, port} -> %{pid: pid, port: port}
    end
  end

  defp peer_loop(listener, socket) do
    receive do
      {:fin, from} ->
        :ok = :gen_tcp.shutdown(socket, :write)
        send(from, :fin_sent)
        peer_loop(listener, socket)

      {:eof?, from} ->
        send(from, {:eof, socket != nil and :gen_tcp.recv(socket, 0, 0) == {:error, :closed}})
        peer_loop(listener, socket)

      :stop ->
        :ok
    after
      5 ->
        case socket do
          nil -> peer_loop(listener, accept(listener))
          socket -> peer_loop(listener, socket)
        end
    end
  end

  defp accept(listener) do
    case :gen_tcp.accept(listener, 0) do
      {:ok, socket} -> socket
      {:error, :timeout} -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # One command, on the socket and on the specification
  # ---------------------------------------------------------------------------

  defp run(action, model, system) do
    if SpecModel.enabled?(model, action) do
      :ok = act(action, model, system)
      SpecModel.step!(model, action)
    else
      model
    end
  end

  defp act("Connected", _model, system) do
    send(system.connector, {system.gate, :go})
    :ok
  end

  # A failure at the connect, or a failure of the open connection.
  defp act("Fail", model, system) do
    if SpecModel.get(model, "conn") == "connecting" do
      send(system.connector, {system.gate, {:error, :econnrefused}})
    else
      transport = :sys.get_state(system.socket.address).socket
      send(system.socket.address, {:tcp_error, transport, :econnreset})
    end

    :ok
  end

  defp act("PeerFin", _model, system) do
    send(system.peer.pid, {:fin, self()})
    assert_receive :fin_sent, 2_000
    :ok
  end

  defp act("Cancel", _model, system) do
    Web.await(ReadableStreamDefaultReader.cancel(system.reader, :cancelled))
  end

  defp act("CloseWriter", _model, system) do
    Web.await(WritableStreamDefaultWriter.close(system.writer))
  end

  defp act("AbortWriter", _model, system) do
    Web.await(WritableStreamDefaultWriter.abort(system.writer, :aborted))
  end

  defp act("Close", _model, system) do
    nil = Web.await(Socket.close(system.socket, :reason))
    :ok
  end

  # ---------------------------------------------------------------------------
  # The comparison
  # ---------------------------------------------------------------------------

  defp assert_same_state(model, system, command) do
    expected = expected(model)
    eventually(fn -> observed(system) == expected end)
  rescue
    error in ExUnit.AssertionError ->
      flunk(
        "after #{command}: the socket has #{inspect(observed(system))}, and the " <>
          "specification has #{inspect(expected(model))}. #{Exception.message(error)}"
      )
  end

  defp expected(model) do
    state = SpecModel.to_map(model)

    %{
      conn: state["conn"],
      opened: state["opened"],
      closed: state["closed"],
      readable: state["readable"],
      writable: state["writable"],
      peer_eof: state["finSent"] or (state["conn"] == "closed" and state["opened"] == "fulfilled")
    }
  end

  defp observed(system) do
    opened = promise_state(system.socket.opened)

    %{
      conn: conn(system.socket, opened),
      opened: opened,
      closed: promise_state(system.socket.closed),
      readable:
        if(Promise.peek(system.reader_closed) == :pending, do: "readable", else: "closed"),
      writable: writable(Promise.peek(system.writer_closed)),
      peer_eof: peer_eof?(system.peer)
    }
  end

  defp conn(socket, opened) do
    cond do
      not Process.alive?(socket.address) -> "closed"
      opened == "pending" -> "connecting"
      true -> "open"
    end
  end

  defp promise_state(promise) do
    case Promise.peek(promise) do
      :pending -> "pending"
      {:fulfilled, _value} -> "fulfilled"
      {:rejected, _reason} -> "rejected"
    end
  end

  defp writable(:pending), do: "writable"
  defp writable({:fulfilled, _value}), do: "closed"
  defp writable({:rejected, _reason}), do: "errored"

  defp peer_eof?(peer) do
    send(peer.pid, {:eof?, self()})
    assert_receive {:eof, eof?}, 2_000
    eof?
  end

  # The steps of the processes and of the kernel take some time: the test
  # examines the state again until it is the same.
  defp eventually(fun, attempts \\ 400) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the state did not become the state of the specification")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end
end
