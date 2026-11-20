# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule Web.Dispatcher.TCPTest do
  use ExUnit.Case, async: true

  import Web, only: [await: 1]

  alias Web.Dispatcher.TCP
  alias Web.Dispatcher.TCP.Connection
  alias Web.Headers
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultReader
  alias Web.Request
  alias Web.Response

  defmodule TCPServer do
    # credo:disable-for-next-line
    def start_link(
          response_data \\ "hello\nworld",
          chunking \\ false,
          drop \\ false,
          observer \\ nil
        ) do
      parent = self()

      Task.start_link(fn ->
        # Port 0 lets the OS pick an available port
        {:ok, listen_socket} =
          :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

        {:ok, port} = :inet.port(listen_socket)
        send(parent, {:port, port})

        {:ok, socket} = :gen_tcp.accept(listen_socket)

        if drop do
          :gen_tcp.close(socket)
          :gen_tcp.close(listen_socket)
        else
          case {chunking, response_data} do
            {true, _} ->
              :gen_tcp.send(socket, "he")
              notify_chunk_sent(observer, "he")
              :gen_tcp.send(socket, "llo")
              notify_chunk_sent(observer, "llo")

            {false, chunks} when is_list(chunks) ->
              Enum.each(chunks, fn
                # The pause is a part of the scenario: a slow server.
                {:sleep, ms} ->
                  Process.sleep(ms)

                chunk ->
                  :gen_tcp.send(socket, chunk)
                  notify_chunk_sent(observer, chunk)
              end)

            {false, _} ->
              :gen_tcp.send(socket, response_data)
              notify_chunk_sent(observer, response_data)
          end

          # The client closes the connection at the end of the body. A
          # machine that is busy can make the close come late: the server
          # reads until the close.
          if observer do
            read_until_closed(socket)
            send(observer, :tcp_client_closed)
          end

          :gen_tcp.close(socket)
          :gen_tcp.close(listen_socket)
        end
      end)

      receive do
        {:port, port} -> port
      after
        1000 -> raise "TCPServer failed to start"
      end
    end

    defp read_until_closed(socket) do
      case :gen_tcp.recv(socket, 0) do
        {:ok, _data} -> read_until_closed(socket)
        {:error, _reason} -> :ok
      end
    end

    defp notify_chunk_sent(nil, _chunk), do: :ok
    defp notify_chunk_sent(observer, chunk), do: send(observer, {:tcp_server_sent, chunk})
  end

  test "fetch/1 handles standard tcp scheme and yields chunks dynamically" do
    port = TCPServer.start_link("", true)

    # The request has no body. This server does not read, thus a body that
    # the client writes causes a TCP reset, and the last chunk can be lost.
    req = Request.new("tcp://localhost:#{port}")
    {:ok, resp} = TCP.fetch(req)

    assert resp.status == 200
    assert Web.TestBytes.join(resp.body) == "hello"
  end

  test "fetch/1 writes request bodies for non-GET methods" do
    parent = self()
    {listener, port} = listen()

    Task.start_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      assert {:ok, "sent body payload"} = :gen_tcp.recv(socket, 0, 1_000)
      send(parent, :request_body_received)
      :ok = :gen_tcp.send(socket, "ok")
      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end)

    req = Request.new("tcp://localhost:#{port}", method: "POST", body: "sent body payload")
    {:ok, resp} = TCP.fetch(req)

    assert Web.TestBytes.join(resp.body) == "ok"
    assert_receive :request_body_received, 1_000
  end

  test "fetch/1 writes a request body that is iodata, a list of chunks of bytes, or a stream" do
    for {body, expected} <- [
          {["io", [?d, "ata"]], "iodata"},
          {["ab", Web.Uint8Array.from("cd"), Web.ArrayBuffer.new("ef")], "abcdef"},
          {ReadableStream.from(["str", "eam"]), "stream"},
          {Stream.map(["enum", "erable"], & &1), "enumerable"}
        ] do
      parent = self()
      {listener, port} = listen()

      Task.start_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, received} = :gen_tcp.recv(socket, byte_size(expected), 1_000)
        send(parent, {:request_body, received})
        :ok = :gen_tcp.send(socket, "ok")
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

      {:ok, resp} = TCP.fetch(raw_request("tcp://localhost:#{port}", "POST", body))
      assert Web.TestBytes.join(resp.body) == "ok"
      assert_receive {:request_body, ^expected}, 1_000
    end
  end

  test "fetch/1 accepts empty binary request bodies for non-GET methods" do
    port = TCPServer.start_link("ok", false)

    req = raw_request("tcp://localhost:#{port}", "POST", "")
    {:ok, resp} = TCP.fetch(req)

    assert Web.TestBytes.join(resp.body) == "ok"
  end

  test "fetch/1 accepts nil request bodies for non-GET methods" do
    port = TCPServer.start_link("ok", false)

    req = raw_request("tcp://localhost:#{port}", "POST", nil)
    {:ok, resp} = TCP.fetch(req)

    assert Web.TestBytes.join(resp.body) == "ok"
  end

  test "fetch/1 rejects a request body that is not bytes, and makes no connection" do
    {listener, port} = listen()

    for body <- [Stream.map([97, :bad], & &1), 123] do
      req = raw_request("tcp://localhost:#{port}", "POST", body)
      assert {:error, %Web.TypeError{message: "body is not readable"}} = TCP.fetch(req)
    end

    assert :gen_tcp.accept(listener, 0) == {:error, :timeout}
  end

  test "fetch/1 handles remote identifier style URL correctly without body" do
    port = TCPServer.start_link("remote_resp", false)

    req = Request.new("remote:localhost:#{port}/path-item")
    {:ok, resp} = TCP.fetch(req)

    assert Web.TestBytes.join(resp.body) == "remote_resp"
  end

  test "fetch/1 parses missing port accurately defaulting to 80 erroring as appropriate" do
    req = Request.new("tcp://localhost_nxdomain/path")
    assert {:error, _} = TCP.fetch(req)
  end

  test "fetch/1 parses rclone style urls without an explicit port by defaulting to 80" do
    req = Request.new("remote:localhost/path")
    assert {:error, _} = TCP.fetch(req)
  end

  test "fetch/1 rejects with the reason of a connection that fails" do
    {listener, port} = listen()
    :gen_tcp.close(listener)

    assert TCP.fetch(Request.new("tcp://localhost:#{port}")) == {:error, :econnrefused}
  end

  test "fetch/1 streaming yields appropriately on clean closed termination" do
    # Drop immediately
    port = TCPServer.start_link("data", false, true)

    req = Request.new("tcp://localhost:#{port}")
    {:ok, resp} = TCP.fetch(req)
    chunks = resp.body |> Enum.to_list()
    assert chunks == []
  end

  test "fetch/1 gives the data that comes after a pause" do
    port = TCPServer.start_link([{:sleep, 100}, "data"])

    req = Request.new("tcp://localhost:#{port}")
    {:ok, resp} = TCP.fetch(req)

    assert Web.TestBytes.binaries(resp.body) == ["data"]
  end

  test "fetch/1 returns response with protocol-specific status_text" do
    port = TCPServer.start_link("test data", false)

    req = Request.new("tcp://localhost:#{port}")
    {:ok, resp} = TCP.fetch(req)

    assert resp.status == 200
    assert resp.status_text == "Connected"
    assert resp.url == "tcp://localhost:#{port}"
  end

  test "Web.fetch/2 of a tcp: URL is the process of the request" do
    port = TCPServer.start_link([{:sleep, 100}, "data"])
    promise = Web.fetch("tcp://localhost:#{port}")

    # The promise is the process that holds the body.
    response = await(promise)
    assert {:held, holder} = response.body.lazy.source
    assert holder == promise.pid
    assert await(Response.text(response)) == "data"
  end

  describe "the process of the request" do
    test "stops to read the socket at 64 KiB that no reader took" do
      chunks = List.duplicate(String.duplicate("x", 8_192), 32)
      port = TCPServer.start_link(chunks, false, false, self())

      {:ok, resp} = TCP.fetch(Request.new("tcp://localhost:#{port}"))
      holder = holder(resp)

      # The server sent 256 KiB. The process asks for no more message, and
      # the socket keeps the rest.
      for _chunk <- chunks, do: assert_receive({:tcp_server_sent, _chunk}, 2_000)

      eventually(fn ->
        {state, inflight} = connection(holder)
        not state.armed? and inflight >= 65_536
      end)

      {_state, inflight} = connection(holder)
      # One message can come after the limit: a message has 64 KiB at most.
      assert inflight < 65_536 + 65_536
      refute Enum.any?(mailbox(holder), &match?({:tcp, _socket, _data}, &1))

      # A reader gets each byte that the server sent. The server waits for
      # the close of the client, thus the reader cancels after the bytes.
      reader = ReadableStream.get_reader(resp.body)
      assert read_bytes(reader, 32 * 8_192) == 32 * 8_192
      assert :ok = await(ReadableStreamDefaultReader.cancel(reader, :done))
      assert_receive :tcp_client_closed, 3_000
    end

    test "ignores a message that it does not know" do
      port = TCPServer.start_link([{:sleep, 100}, "data"])
      {:ok, resp} = TCP.fetch(Request.new("tcp://localhost:#{port}"))

      send(holder(resp), :not_a_message_of_the_request)

      assert Web.TestBytes.binaries(resp.body) == ["data"]
    end

    test "a cancel of the body closes the socket" do
      port = TCPServer.start_link([{:sleep, 200}, "data"], false, false, self())
      {:ok, resp} = TCP.fetch(Request.new("tcp://localhost:#{port}"))

      assert :ok = Web.Promise.await(ReadableStream.cancel(resp.body, :manual_cancel))
      assert_receive :tcp_client_closed, 3_000
    end

    test "the stop of the owner of the reader closes the socket" do
      port = TCPServer.start_link([{:sleep, 200}, "data"], false, false, self())
      {:ok, resp} = TCP.fetch(Request.new("tcp://localhost:#{port}"))
      parent = self()

      reader_owner =
        spawn(fn ->
          _reader = ReadableStream.get_reader(resp.body)
          send(parent, :reader_locked)

          receive do
            :keep_alive -> :ok
          end
        end)

      assert_receive :reader_locked, 1_000
      Process.exit(reader_owner, :kill)
      assert_receive :tcp_client_closed, 3_000
    end

    test "a reset of the connection errors the body" do
      port = TCPServer.start_link([{:sleep, 2_000}, "late"], false, false, self())
      {:ok, resp} = TCP.fetch(Request.new("tcp://localhost:#{port}"))
      holder = holder(resp)
      {%{socket: socket}, _inflight} = connection(holder)

      send(holder, {:tcp_error, socket, :econnreset})

      assert %Web.TypeError{message: "The response body is not complete.", cause: :econnreset} =
               catch_exit(await(Response.text(resp)))

      assert_receive :tcp_client_closed, 3_000
    end

    test "a socket that closes while the process does not read it errors the body" do
      chunks = List.duplicate(String.duplicate("x", 8_192), 16) ++ [{:sleep, 2_000}]
      port = TCPServer.start_link(chunks, false, false, self())
      {:ok, resp} = TCP.fetch(Request.new("tcp://localhost:#{port}"))
      holder = holder(resp)

      eventually(fn ->
        {state, inflight} = connection(holder)
        not state.armed? and inflight >= 65_536
      end)

      # The socket closes with no message to the process: the next request
      # for a message fails.
      {%{socket: socket}, _inflight} = connection(holder)
      :erlang.port_close(socket)

      assert %Web.TypeError{message: "The response body is not complete.", cause: :einval} =
               catch_exit(await(Response.text(resp)))
    end

    # The network side runs in the process that calls it: the test takes the
    # socket from the connect, and closes it before the write.
    test "a failure of the write of the request body gives an error" do
      {listener, port} = listen()
      req = Request.new("tcp://localhost:#{port}", method: "POST", body: "body")
      assert Connection.start(req) == :ok

      assert_receive {_ref, {:ok, socket}} = connected, 2_000
      :ok = :gen_tcp.close(socket)

      assert Connection.handle(connected) == :handled
      assert {:ok, {:error, reason}} = Connection.next()
      assert reason in [:closed, :einval]
      assert Connection.next() == :none
      :gen_tcp.close(listener)
    end

    test "has no receive timeout" do
      assert Connection.wait_time() == :infinity
      assert Connection.expire() == :ok
    end
  end

  describe "an abort" do
    test "while the body is read errors the body and closes the socket" do
      controller = Web.AbortController.new()
      port = TCPServer.start_link([{:sleep, 2_000}, "data"], false, false, self())

      req = Request.new("tcp://localhost:#{port}", signal: controller.signal)
      {:ok, resp} = TCP.fetch(req)
      reader = ReadableStream.get_reader(resp.body)
      read = ReadableStreamDefaultReader.read(reader)

      assert :ok = Web.AbortController.abort(controller, :timeout)
      assert catch_exit(await(read)) == :timeout
      assert_receive :tcp_client_closed, 3_000
    end

    test "before a read errors the body and closes the socket" do
      controller = Web.AbortController.new()
      port = TCPServer.start_link([{:sleep, 2_000}, "data"], false, false, self())

      req = Request.new("tcp://localhost:#{port}", signal: controller.signal)
      {:ok, resp} = TCP.fetch(req)

      assert :ok = Web.AbortController.abort(controller, :timeout)
      assert_receive :tcp_client_closed, 3_000
      assert catch_exit(await(Response.text(resp))) == :timeout
    end

    test "before the fetch rejects the fetch, and makes no connection" do
      controller = Web.AbortController.new()
      assert :ok = Web.AbortController.abort(controller, :timeout)
      {listener, port} = listen()

      req = Request.new("tcp://localhost:#{port}", signal: controller.signal)
      assert TCP.fetch(req) == {:error, :aborted}
      assert catch_exit(await(Web.fetch(req))) == :timeout
      assert :gen_tcp.accept(listener, 0) == {:error, :timeout}
    end

    test "while the connection opens rejects the fetch, and stops the connect" do
      controller = Web.AbortController.new()
      port = full_listener()

      promise = Web.fetch("tcp://localhost:#{port}", signal: controller.signal)
      eventually(fn -> match?({%{phase: :connect}, _inflight}, connection(promise.pid)) end)
      {%{connector: {connector, _ref}}, _inflight} = connection(promise.pid)
      monitor = Process.monitor(connector)

      # A process that awaits the promise while the connection opens.
      waiter = Task.async(fn -> catch_exit(await(promise)) end)
      eventually(fn -> {:messages, []} == Process.info(promise.pid, :messages) end)

      assert :ok = Web.AbortController.abort(controller, :timeout)
      assert Task.await(waiter) == :timeout
      assert_receive {:DOWN, ^monitor, :process, ^connector, :killed}, 1_000
    end

    test "the stop of the owner while the connection opens stops the request" do
      port = full_listener()
      test = self()

      owner =
        spawn(fn ->
          send(test, {:promise, Web.fetch("tcp://localhost:#{port}")})

          receive do
            :keep_alive -> :ok
          end
        end)

      assert_receive {:promise, promise}, 1_000
      eventually(fn -> match?({%{phase: :connect}, _inflight}, connection(promise.pid)) end)
      monitor = Process.monitor(promise.pid)

      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 1_000
    end
  end

  defp raw_request(url, method, body) do
    %Request{
      url: Web.URL.new(url),
      method: method,
      headers: Headers.new(),
      body: body,
      dispatcher: nil,
      redirect: "follow",
      signal: nil,
      options: [redirect: "follow", signal: nil]
    }
  end

  defp listen(options \\ []) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true] ++ options)

    {:ok, port} = :inet.port(listener)
    {listener, port}
  end

  # A listener with a full accept queue: the kernel drops each new connect,
  # thus a connect waits until its time limit.
  defp full_listener do
    {listener, port} = listen(backlog: 0)
    {:ok, first} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])
    on_exit(fn -> :gen_tcp.close(first) && :gen_tcp.close(listener) end)
    port
  end

  defp holder(%Response{body: body}) do
    {:held, holder} = body.lazy.source
    holder
  end

  # The state of the network side, in the process dictionary of the
  # process of the request.
  defp connection(holder) do
    {:dictionary, dictionary} = Process.info(holder, :dictionary)

    {:proplists.get_value({Connection, :state}, dictionary),
     :proplists.get_value({Connection, :inflight}, dictionary)}
  end

  defp read_bytes(reader, size, got \\ 0)
  defp read_bytes(_reader, size, got) when got >= size, do: got

  defp read_bytes(reader, size, got) do
    %{value: chunk} = await(ReadableStreamDefaultReader.read(reader))
    read_bytes(reader, size, got + byte_size(Web.Uint8Array.to_binary(chunk)))
  end

  defp mailbox(holder) do
    {:messages, messages} = Process.info(holder, :messages)
    messages
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end
end
