defmodule Web.TLA.SocketFlowConformanceTest do
  # Compares the network side of a request, `Web.Dispatcher.HTTP.Exchange`,
  # with the specification `tla/SocketFlow.tla`.
  #
  # The test process is the process of the request: it calls the functions
  # of the exchange, as `Web.Dispatcher.HTTP` does, and it decides when each
  # message of the socket is handled. A server of the test sends each chunk
  # when the test asks. The test makes a random list of steps. It does each
  # step on the exchange and on the specification, and it compares the
  # messages of the socket in its mailbox, the flag of the exchange, the
  # mode of the socket, and the bytes that the exchange keeps.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.Dispatcher.HTTP.Exchange
  alias Web.Test.SpecModel

  # The exchange asks for a message while it keeps less than 64 KiB: with
  # chunks of 16 KiB, the limit is 4 chunks.
  @chunk 16_384
  @chunks 8
  @constants [{"Chunks = 4", "Chunks = #{@chunks}"}, {"Limit = 2", "Limit = 4"}]

  defp command, do: member_of(["ServerSend", "Handle", "Read"])

  property "the exchange reads its socket as the specification permits" do
    check all(commands <- list_of(command(), max_length: 40), max_runs: 50) do
      server = start_server()
      start_exchange(server)

      try do
        Enum.reduce(commands, SpecModel.start("SocketFlow", @constants), fn command, model ->
          model = run(command, model, server)
          assert_same_state(model)
          model
        end)
      after
        Exchange.close()
        send(server.pid, :stop)
        flush()
      end
    end
  end

  # The run can end with a message of the socket in the mailbox.
  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # The server, and the start of the exchange
  # ---------------------------------------------------------------------------

  defp start_server do
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
        {:ok, port} = :inet.port(listener)
        send(test, {:port, port})
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0)
        serve(socket, test)
      end)

    receive do
      {:port, port} -> %{pid: pid, port: port}
    end
  end

  defp serve(socket, test) do
    receive do
      {:send, data} ->
        :ok = :gen_tcp.send(socket, data)
        send(test, :sent)
        serve(socket, test)

      :stop ->
        :gen_tcp.close(socket)
    end
  end

  defp server_send(server, data) do
    send(server.pid, {:send, data})
    assert_receive :sent, 2_000
  end

  # The request starts, and the exchange handles the head of the response.
  # Then the exchange asks for the first chunk: the initial state of the
  # specification.
  defp start_exchange(server) do
    request = Web.Request.new("http://localhost:#{server.port}/")
    :ok = Exchange.start(request)
    handle_until(fn -> exchange().phase == :open end)

    head = "HTTP/1.1 200 OK\r\nContent-Length: #{@chunk * @chunks}\r\n\r\n"
    server_send(server, head)
    receive_socket_message() |> Exchange.handle()
    assert {:ok, {:head, :body, 200, _headers, nil, :http1}} = Exchange.next()
  end

  # The grant of the pool, or the connection.
  defp handle_until(done?) do
    unless done?.() do
      receive do
        message -> :handled = Exchange.handle(message)
      end

      handle_until(done?)
    end
  end

  defp receive_socket_message do
    receive do
      {:tcp, _socket, _data} = message -> message
    after
      2_000 -> flunk("the socket gave no message")
    end
  end

  # ---------------------------------------------------------------------------
  # One step, on the exchange and on the specification
  # ---------------------------------------------------------------------------

  # The server sends a chunk. A test step sends one chunk at a time: the
  # socket gives one message for each chunk, as in the specification.
  defp run("ServerSend", model, server) do
    if SpecModel.enabled?(model, "ServerSend") and SpecModel.get(model, "kernel") == 0 do
      server_send(server, :binary.copy("c", @chunk))
      model |> SpecModel.step!("ServerSend") |> deliver()
    else
      model
    end
  end

  # The exchange handles the message of the socket.
  defp run("Handle", model, _server) do
    if SpecModel.enabled?(model, "Handle") do
      :handled = Exchange.handle(receive_socket_message())
      take_events()
      model |> SpecModel.step!("Handle") |> deliver()
    else
      model
    end
  end

  # The reader takes the bytes that the exchange keeps.
  defp run("Read", model, _server) do
    if SpecModel.enabled?(model, "Read") do
      Exchange.credit(SpecModel.get(model, "buffer") * @chunk)
      model |> SpecModel.step!("Read") |> deliver()
    else
      model
    end
  end

  # When the socket is active and has a chunk, it gives the message.
  defp deliver(model) do
    if SpecModel.enabled?(model, "Deliver") do
      assert_receive {:tcp, _socket, _data} = message, 2_000
      send(self(), message)
      SpecModel.step!(model, "Deliver")
    else
      model
    end
  end

  # The data events of the message. The end of the body comes with its last
  # chunk.
  defp take_events do
    case Exchange.next() do
      {:ok, {:data, _piece}} -> take_events()
      {:ok, :done} -> take_events()
      :none -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # The comparison
  # ---------------------------------------------------------------------------

  defp assert_same_state(model) do
    # A message of the socket in the mailbox goes back to its end, thus the
    # sequence of the messages stays.
    {:messages, messages} = Process.info(self(), :messages)
    socket_messages = Enum.count(messages, &match?({:tcp, _socket, _data}, &1))
    assert socket_messages == SpecModel.get(model, "mailbox")

    state = exchange()
    assert state.armed? == SpecModel.get(model, "asked")
    assert Process.get({Exchange, :inflight}) == SpecModel.get(model, "buffer") * @chunk

    if state.conn do
      {:ok, [active: active]} = :inet.getopts(Mint.HTTP.get_socket(state.conn), [:active])
      assert active == :once == SpecModel.get(model, "active")
    end
  end

  defp exchange, do: Process.get({Exchange, :state})
end
