defmodule Web.SocketTest do
  use ExUnit.Case, async: false

  import Web, only: [await: 1]

  alias Web.Internal.Envelope
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultReader
  alias Web.Socket
  alias Web.TypeError
  alias Web.WritableStreamDefaultWriter

  test "connect/2 streams data over tcp and closes cleanly" do
    parent = self()

    {port, _task} =
      start_tcp_server(fn socket ->
        tcp_echo_loop(socket, parent)
      end)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")

    reader = ReadableStream.get_reader(socket.readable)
    writer = Web.WritableStream.get_writer(socket.writable)

    assert :ok = await(WritableStreamDefaultWriter.write(writer, "ping"))
    assert read_chunk!(reader) == "ping"

    assert :closed = await(Socket.close(socket))
    assert_receive :tcp_server_closed, 1_000
  end

  test "wrong authorization tokens cannot close or write to the socket server" do
    parent = self()

    {port, _task} =
      start_tcp_server(fn socket ->
        tcp_echo_loop(socket, parent)
      end)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")

    bad_close_ref = make_ref()

    send(
      socket.address,
      {:"$gen_call", {self(), bad_close_ref}, Envelope.new(make_ref(), {:close, :closed})}
    )

    assert_receive {^bad_close_ref, {:error, :unauthorized}}, 1_000

    bad_debug_ref = make_ref()

    send(
      socket.address,
      {:"$gen_call", {self(), bad_debug_ref}, Envelope.new(make_ref(), :debug)}
    )

    assert_receive {^bad_debug_ref, {:error, :unauthorized}}, 1_000

    bad_write_ref = make_ref()

    send(
      socket.address,
      {:"$gen_call", {self(), bad_write_ref}, Envelope.new(make_ref(), {:write, "nope"})}
    )

    assert_receive {^bad_write_ref, {:error, :unauthorized}}, 1_000

    reader = ReadableStream.get_reader(socket.readable)
    writer = Web.WritableStream.get_writer(socket.writable)

    assert :ok = await(WritableStreamDefaultWriter.write(writer, "still open"))
    assert read_chunk!(reader) == "still open"
    assert :closed = await(Socket.close(socket))
  end

  test "server handles envelope wrappers, unsupported operations, and stray info messages" do
    {port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")

    envelope = Envelope.new(socket.token, :debug)

    assert %{transport: :tcp} = socket_raw_request(socket.address, {:envelope, envelope})
    refute Map.has_key?(socket_debug(socket), :server_pid)
    refute Map.has_key?(socket_debug(socket), :socket)
    assert socket_raw_request(socket.address, {:envelope, :bogus}) == {:error, :unauthorized}

    assert socket_raw_request(socket.address, Envelope.new(socket.token, :bogus)) ==
             {:error, :unsupported_operation}

    socket_raw_cast(socket.address, {:envelope, Envelope.new(socket.token, :bogus_cast)})
    socket_raw_cast(socket.address, {:envelope, :bogus})
    socket_raw_cast(socket.address, %Envelope{})
    send(socket.address, :bogus_info)

    assert %{transport: :tcp} = socket_debug(socket)
    assert :closed = await(Socket.close(socket))
  end

  test "opened rejects on connection timeout and closed resolves with the timeout reason" do
    socket =
      Web.connect("localhost:9",
        connect_fun: fn _host, _port, _opts, _timeout -> {:error, :timeout} end
      )

    assert :timeout = catch_exit(await(socket.opened))
    assert await(socket.closed) == :timeout
    assert :timeout = catch_exit(await(socket.upgraded))
  end

  test "opened rejects for unsupported secure transport kinds" do
    socket = Web.connect("localhost:25", secureTransport: "udp")

    assert {:unsupported_secure_transport, "udp"} = catch_exit(await(socket.opened))
    assert await(socket.closed) == {:unsupported_secure_transport, "udp"}
  end

  test "initial tls connect failures reject the opened promise" do
    socket =
      Web.connect("localhost:465",
        secureTransport: "on",
        ssl_connect_fun: fn _host, _port, _opts, _timeout -> {:error, :ssl_timeout} end
      )

    assert :ssl_timeout = catch_exit(await(socket.opened))
    assert await(socket.closed) == :ssl_timeout
    assert :ssl_timeout = catch_exit(await(socket.upgraded))
  end

  test "readable backpressure moves the underlying tcp socket to passive mode" do
    parent = self()

    {port, server_task} =
      start_tcp_server(fn socket ->
        :ok = :gen_tcp.send(socket, "ab")
        :ok = :gen_tcp.send(socket, "cd")
        send(parent, :first_two_chunks_sent)

        receive do
          :send_third_chunk ->
            :ok = :gen_tcp.send(socket, "ef")
            send(parent, :third_chunk_sent)
        after
          5_000 -> :ok
        end

        wait_for_tcp_stop_or_close(socket)
      end)

    socket = Web.connect("localhost:#{port}", readable_high_water_mark: 4)
    assert_opened_remote(socket, "localhost:#{port}")
    assert_receive :first_two_chunks_sent, 1_000

    assert_eventually(fn ->
      info = socket_debug(socket)
      info.active == false and info.queued_size == 4 and info.desired_size == 0
    end)

    send(server_task, :send_third_chunk)
    assert_receive :third_chunk_sent, 1_000

    assert_eventually(fn ->
      info = socket_debug(socket)
      info.active == false and info.queued_size == 4 and info.desired_size == 0
    end)

    reader = ReadableStream.get_reader(socket.readable)
    first_chunk = read_chunk!(reader)
    assert first_chunk in ["ab", "abcd"]

    remaining = read_bytes!(reader, 6 - byte_size(first_chunk))
    assert first_chunk <> remaining == "abcdef"
    assert :closed = await(Socket.close(socket))
  end

  test "cancelling the readable stream closes the socket" do
    {port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")

    assert :ok = await(ReadableStream.cancel(socket.readable, :reader_cancelled))
    assert await(socket.closed) == {:readable_cancel, :reader_cancelled}
    assert {:readable_cancel, :reader_cancelled} = catch_exit(await(socket.upgraded))
  end

  test "writer close and abort route through the socket sink" do
    {port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")

    writer = Web.WritableStream.get_writer(socket.writable)
    assert :ok = await(WritableStreamDefaultWriter.close(writer))
    assert await(socket.closed) == :closed

    {port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")

    writer = Web.WritableStream.get_writer(socket.writable)
    assert :ok = await(WritableStreamDefaultWriter.abort(writer, :user_abort))
    assert await(socket.closed) == :closed
  end

  test "invalid socket write payloads reject and close the server" do
    {port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")
    writer = Web.WritableStream.get_writer(socket.writable)

    reason = catch_exit(await(WritableStreamDefaultWriter.write(writer, %{bad: :payload})))
    assert match?(%TypeError{}, reason)
    assert match?({:transport_error, %TypeError{}}, await(socket.closed))
  end

  test "server closes the transport when the holder process crashes" do
    parent = self()

    {port, _task} =
      start_tcp_server(fn socket ->
        tcp_observe_close(socket, parent)
      end)

    holder =
      spawn(fn ->
        socket = Web.connect("localhost:#{port}")
        await(socket.opened)
        send(parent, {:holder_socket, socket})

        receive do
          :keep_alive -> :ok
        end
      end)

    assert_receive {:holder_socket, _socket}, 1_000
    Process.exit(holder, :boom)

    assert_receive :tcp_server_closed, 1_000
  end

  test "start_tls resolves upgraded with a new secure socket" do
    parent = self()
    certfile = fixture_path("socket_test_cert.pem")
    keyfile = fixture_path("socket_test_key.pem")

    {port, _task} =
      start_tcp_server(fn socket ->
        :ok = :gen_tcp.send(socket, "220 localhost ESMTP ready\r\n")
        assert {:ok, "STARTTLS\r\n"} = :gen_tcp.recv(socket, 0, 5_000)
        send(parent, :saw_starttls)
        :ok = :gen_tcp.send(socket, "220 Ready to start TLS\r\n")
        {:ok, ssl_socket} = :ssl.handshake(socket, server_ssl_options(certfile, keyfile), 5_000)
        assert {:ok, "EHLO secure.example\r\n"} = :ssl.recv(ssl_socket, 0, 5_000)
        send(parent, :saw_secure_ehlo)
        :ok = :ssl.send(ssl_socket, "250 encrypted\r\n")
        :ssl.close(ssl_socket)
      end)

    socket = Web.connect(%{hostname: "127.0.0.1", port: port}, secureTransport: "starttls")
    assert_opened_remote(socket, "127.0.0.1:#{port}")

    reader = ReadableStream.get_reader(socket.readable)
    writer = Web.WritableStream.get_writer(socket.writable)

    assert read_chunk!(reader) == "220 localhost ESMTP ready\r\n"
    assert :ok = await(WritableStreamDefaultWriter.write(writer, "STARTTLS\r\n"))
    assert_receive :saw_starttls, 1_000
    assert read_chunk!(reader) == "220 Ready to start TLS\r\n"

    upgraded = await(Socket.start_tls(socket))
    assert %Socket{} = upgraded
    assert upgraded.address != socket.address
    assert upgraded.token != socket.token
    assert await(socket.upgraded).address == upgraded.address
    assert await(socket.closed) == :upgraded

    upgraded_reader = ReadableStream.get_reader(upgraded.readable)
    upgraded_writer = Web.WritableStream.get_writer(upgraded.writable)

    assert :ok =
             await(WritableStreamDefaultWriter.write(upgraded_writer, "EHLO secure.example\r\n"))

    assert_receive :saw_secure_ehlo, 1_000
    assert read_chunk!(upgraded_reader) == "250 encrypted\r\n"
    assert await(upgraded.upgraded).address == upgraded.address
    assert await(upgraded.closed) == :closed
  end

  test "start_tls rejects on handshake failure and closes the socket" do
    {port, _task} =
      start_tcp_server(fn socket ->
        :ok = :gen_tcp.send(socket, "220 localhost ESMTP ready\r\n")
        assert {:ok, "STARTTLS\r\n"} = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :gen_tcp.send(socket, "220 Ready to start TLS\r\n")

        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, _client_hello} -> :gen_tcp.close(socket)
          {:error, _reason} -> :gen_tcp.close(socket)
        end
      end)

    socket = Web.connect("localhost:#{port}", secureTransport: "starttls")
    assert_opened_remote(socket, "localhost:#{port}")

    reader = ReadableStream.get_reader(socket.readable)
    writer = Web.WritableStream.get_writer(socket.writable)

    assert read_chunk!(reader) == "220 localhost ESMTP ready\r\n"
    assert :ok = await(WritableStreamDefaultWriter.write(writer, "STARTTLS\r\n"))
    assert read_chunk!(reader) == "220 Ready to start TLS\r\n"

    reason = catch_exit(await(Socket.start_tls(socket, verify: :verify_none)))
    assert match?({:tls_upgrade_failed, _}, reason)
    assert match?({:tls_upgrade_failed, _}, await(socket.closed))
    assert match?({:tls_upgrade_failed, _}, catch_exit(await(socket.upgraded)))
    assert_alias_revoked(socket.address, Envelope.new(socket.token, :debug))
  end

  test "server closing immediately after connect shuts down the socket and revokes the alias" do
    {port, _task} = start_tcp_server(&:gen_tcp.close/1)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")

    assert await(socket.closed) == :closed
    assert_alias_revoked(socket.address, Envelope.new(socket.token, :debug))
  end

  test "connect/2 supports initial tls sockets" do
    parent = self()
    certfile = fixture_path("socket_test_cert.pem")
    keyfile = fixture_path("socket_test_key.pem")

    {port, _task} =
      start_ssl_server(
        fn socket ->
          :ok = :ssl.send(socket, "secure hello")
          send(parent, :ssl_server_sent)
          :ssl.close(socket)
        end,
        certfile,
        keyfile
      )

    socket =
      Web.connect("localhost:#{port}", secureTransport: "on", ssl_options: [verify: :verify_none])

    assert_opened_remote(socket, "localhost:#{port}")

    reader = ReadableStream.get_reader(socket.readable)

    assert_receive :ssl_server_sent, 1_000
    assert read_chunk!(reader) == "secure hello"
    assert await(socket.closed) == :closed
    assert :closed = catch_exit(await(socket.upgraded))
  end

  test "calling start_tls on a non-starttls socket rejects without closing it" do
    certfile = fixture_path("socket_test_cert.pem")
    keyfile = fixture_path("socket_test_key.pem")

    {port, _task} =
      start_ssl_server(
        fn socket ->
          wait_for_ssl_stop_or_close(socket)
        end,
        certfile,
        keyfile
      )

    socket =
      Web.connect("localhost:#{port}", secureTransport: "on", ssl_options: [verify: :verify_none])

    assert_opened_remote(socket, "localhost:#{port}")

    reason = catch_exit(await(Socket.start_tls(socket, verify: :verify_none)))
    assert :not_starttls = reason
    assert :closed = await(Socket.close(socket))
  end

  test "calling start_tls on an already upgraded socket rejects with already_tls" do
    parent = self()
    certfile = fixture_path("socket_test_cert.pem")
    keyfile = fixture_path("socket_test_key.pem")

    {port, _task} =
      start_tcp_server(fn socket ->
        :ok = :gen_tcp.send(socket, "220 localhost ESMTP ready\r\n")
        assert {:ok, "STARTTLS\r\n"} = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :gen_tcp.send(socket, "220 Ready to start TLS\r\n")
        {:ok, ssl_socket} = :ssl.handshake(socket, server_ssl_options(certfile, keyfile), 5_000)
        send(parent, :tls_upgrade_complete)
        wait_for_ssl_stop_or_close(ssl_socket)
      end)

    socket = Web.connect("localhost:#{port}", secureTransport: "starttls")
    assert_opened_remote(socket, "localhost:#{port}")

    reader = ReadableStream.get_reader(socket.readable)
    writer = Web.WritableStream.get_writer(socket.writable)
    assert read_chunk!(reader) == "220 localhost ESMTP ready\r\n"
    assert :ok = await(WritableStreamDefaultWriter.write(writer, "STARTTLS\r\n"))
    assert read_chunk!(reader) == "220 Ready to start TLS\r\n"

    upgraded = await(Socket.start_tls(socket, verify: :verify_none))
    assert_receive :tls_upgrade_complete, 1_000

    reason = catch_exit(await(Socket.start_tls(upgraded, verify: :verify_none)))
    assert :already_tls = reason
    assert :closed = await(Socket.close(upgraded))
  end

  test "capability-safe synthetic transport events drive shutdown branches" do
    tcp_error_handle = {:fake_tcp, make_ref()}

    tcp_error_socket =
      Web.connect("localhost:0",
        connect_fun: fn _host, _port, _opts, _timeout -> {:ok, tcp_error_handle} end
      )

    assert_opened_remote(tcp_error_socket, "localhost:0")
    send(tcp_error_socket.address, {:tcp_error, tcp_error_handle, :econnreset})
    assert await(tcp_error_socket.closed) == {:transport_error, :econnreset}
    assert_alias_revoked(tcp_error_socket.address, Envelope.new(tcp_error_socket.token, :debug))

    tcp_closed_handle = {:fake_tcp, make_ref()}

    tcp_closed_socket =
      Web.connect("localhost:0",
        connect_fun: fn _host, _port, _opts, _timeout -> {:ok, tcp_closed_handle} end
      )

    assert_opened_remote(tcp_closed_socket, "localhost:0")
    send(tcp_closed_socket.address, {:tcp_closed, tcp_closed_handle})
    assert await(tcp_closed_socket.closed) == :closed
    assert_alias_revoked(tcp_closed_socket.address, Envelope.new(tcp_closed_socket.token, :debug))

    ssl_error_handle = {:fake_ssl, make_ref()}

    ssl_error_socket =
      Web.connect("localhost:0",
        secureTransport: "on",
        ssl_start_fun: fn :ssl -> {:ok, []} end,
        ssl_connect_fun: fn _host, _port, _opts, _timeout -> {:ok, ssl_error_handle} end
      )

    assert_opened_remote(ssl_error_socket, "localhost:0")
    send(ssl_error_socket.address, {:ssl_error, ssl_error_handle, :closed})
    assert await(ssl_error_socket.closed) == {:transport_error, :closed}
    assert_alias_revoked(ssl_error_socket.address, Envelope.new(ssl_error_socket.token, :debug))

    ssl_closed_handle = {:fake_ssl, make_ref()}

    ssl_closed_socket =
      Web.connect("localhost:0",
        secureTransport: "on",
        ssl_start_fun: fn :ssl -> {:ok, []} end,
        ssl_connect_fun: fn _host, _port, _opts, _timeout -> {:ok, ssl_closed_handle} end
      )

    assert_opened_remote(ssl_closed_socket, "localhost:0")
    send(ssl_closed_socket.address, {:ssl_closed, ssl_closed_handle})
    assert await(ssl_closed_socket.closed) == :closed
    assert_alias_revoked(ssl_closed_socket.address, Envelope.new(ssl_closed_socket.token, :debug))
  end

  test "debug transport info exposes metadata without backend pid" do
    {port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)
    socket = Web.connect(hostname: "localhost", port: port)
    assert_opened_remote(socket, "localhost:#{port}")

    info = socket_debug(socket)
    refute Map.has_key?(info, :server_pid)
    refute Map.has_key?(info, :socket)
    assert Map.has_key?(info, :active)
    assert Map.has_key?(info, :transport)
    assert Map.has_key?(info, :queued_size)
    assert Map.has_key?(info, :desired_size)

    assert :closed = await(Socket.close(socket))
    assert_alias_revoked(socket.address, Envelope.new(socket.token, :debug))
  end

  test "connect raises for invalid address formats" do
    assert_raise TypeError, ~r/SocketError: invalid address/, fn ->
      Web.connect("localhost")
    end

    assert_raise TypeError, ~r/SocketError: invalid address/, fn ->
      Web.connect("localhost:notaport")
    end

    assert_raise TypeError, ~r/SocketError: invalid address/, fn ->
      Web.connect(~c"localhost:1234")
    end

    assert_raise TypeError, ~r/SocketError: invalid address/, fn ->
      Web.connect(%{hostname: "localhost", port: "1234"})
    end

    assert_raise TypeError, ~r/SocketError: invalid address/, fn ->
      Web.connect(1234)
    end
  end

  test "connect raises for invalid option types" do
    assert_raise TypeError, ~r/SocketError: invalid options/, fn ->
      Web.connect(%{hostname: "localhost", port: 80}, :bogus)
    end
  end

  test "connect accepts keyword socket addresses" do
    {port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)
    socket = Web.connect(hostname: "localhost", port: port)
    assert_opened_remote(socket, "localhost:#{port}")
    assert :closed = await(Socket.close(socket))
  end

  test "Socket.start_socket/2 uses default options" do
    {port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)
    socket = Socket.start_socket(self(), "localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")
    assert :closed = await(Socket.close(socket))
  end

  test "start_tls rejects when the connection probe never attached a transport" do
    socket =
      Web.connect("localhost:0",
        secureTransport: "starttls",
        connect_fun: fn _host, _port, _opts, _timeout -> {:ok, nil} end
      )

    assert_opened_remote(socket, "localhost:0")

    info = socket_debug(socket)
    assert info.active == false
    assert info.transport == :tcp
    refute Map.has_key?(info, :socket)

    assert :not_connected = catch_exit(await(Socket.start_tls(socket)))
    assert :closed = await(Socket.close(socket))
    assert_alias_revoked(socket.address, Envelope.new(socket.token, :debug))
  end

  test "starttls connection failures reject opened and closed" do
    socket =
      Web.connect("localhost:25",
        secureTransport: "starttls",
        connect_fun: fn _host, _port, _opts, _timeout -> {:error, :starttls_timeout} end
      )

    assert :starttls_timeout = catch_exit(await(socket.opened))
    assert await(socket.closed) == :starttls_timeout
  end

  test "ssl bootstrap failures reject secure connections" do
    socket =
      Web.connect("localhost:443",
        secureTransport: "on",
        ssl_start_fun: fn :ssl -> {:error, :ssl_boot_failed} end
      )

    assert :ssl_boot_failed = catch_exit(await(socket.opened))
    assert await(socket.closed) == :ssl_boot_failed
  end

  test "writer close times out while connect is blocked and the alias is later revoked" do
    gate = make_ref()

    socket =
      Web.connect("localhost:0",
        request_timeout: 25,
        connect_fun: blocking_connect(self(), gate)
      )

    assert_receive {:connect_blocked, ^gate}, 1_000

    writer = Web.WritableStream.get_writer(socket.writable)

    assert %TypeError{message: "The stream is errored."} =
             catch_exit(await(WritableStreamDefaultWriter.close(writer)))

    send(socket.address, {gate, {:error, :connect_timeout}})

    assert :connect_timeout = catch_exit(await(socket.opened))
    assert await(socket.closed) == :connect_timeout
    assert_alias_revoked(socket.address, Envelope.new(socket.token, :debug))
  end

  test "writer abort keeps API semantics while the sink timeout path rejects in the background" do
    gate = make_ref()

    socket =
      Web.connect("localhost:0",
        request_timeout: 25,
        connect_fun: blocking_connect(self(), gate)
      )

    assert_receive {:connect_blocked, ^gate}, 1_000

    writer = Web.WritableStream.get_writer(socket.writable)
    assert :ok = await(WritableStreamDefaultWriter.abort(writer, :user_abort))

    send(socket.address, {gate, {:error, :abort_connect_timeout}})

    assert :abort_connect_timeout = catch_exit(await(socket.opened))
    assert await(socket.closed) == :abort_connect_timeout
    Process.sleep(75)
    assert_alias_revoked(socket.address, Envelope.new(socket.token, :debug))
  end

  test "connect normalizes alternate address and option forms" do
    {tcp_port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)

    socket =
      Web.connect(%{"hostname" => "localhost", port: tcp_port},
        secure_transport: "off",
        tcp_options: nil
      )

    assert_opened_remote(socket, "localhost:#{tcp_port}")
    assert :closed = await(Socket.close(socket))

    {tcp_port2, _task2} = start_tcp_server(&wait_for_tcp_stop_or_close/1)

    socket2 =
      Web.connect("localhost:#{tcp_port2}",
        tcp_options: {:send_timeout, 1000},
        ssl_options: :bogus
      )

    assert_opened_remote(socket2, "localhost:#{tcp_port2}")
    assert :closed = await(Socket.close(socket2))

    certfile = fixture_path("socket_test_cert.pem")
    keyfile = fixture_path("socket_test_key.pem")

    {ssl_port, _ssl_task} =
      start_ssl_server(
        fn socket ->
          wait_for_ssl_stop_or_close(socket)
        end,
        certfile,
        keyfile
      )

    socket3 =
      Web.connect("localhost:#{ssl_port}",
        secure_transport: "on",
        ssl_options: %{verify: :verify_none}
      )

    assert_opened_remote(socket3, "localhost:#{ssl_port}")
    assert :closed = await(Socket.close(socket3))
    assert :closed = catch_exit(await(socket3.upgraded))
  end

  defp start_tcp_server(handler) do
    parent = self()

    {:ok, task} =
      Task.start_link(fn ->
        {:ok, listen_socket} =
          :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

        {:ok, port} = :inet.port(listen_socket)
        send(parent, {:tcp_server_port, self(), port})

        try do
          {:ok, socket} = :gen_tcp.accept(listen_socket)
          handler.(socket)
        after
          :gen_tcp.close(listen_socket)
        end
      end)

    on_exit(fn ->
      if Process.alive?(task) do
        send(task, :stop)
      end
    end)

    receive do
      {:tcp_server_port, ^task, port} -> {port, task}
    after
      1_000 -> flunk("tcp test server failed to start")
    end
  end

  defp start_ssl_server(handler, certfile, keyfile) do
    parent = self()

    {:ok, task} =
      Task.start_link(fn ->
        {:ok, listen_socket} = :ssl.listen(0, server_ssl_options(certfile, keyfile))
        {:ok, {_address, port}} = :ssl.sockname(listen_socket)
        send(parent, {:ssl_server_port, self(), port})

        try do
          {:ok, transport_socket} = :ssl.transport_accept(listen_socket, 5_000)
          {:ok, socket} = :ssl.handshake(transport_socket, 5_000)
          handler.(socket)
        after
          :ssl.close(listen_socket)
        end
      end)

    on_exit(fn ->
      if Process.alive?(task) do
        send(task, :stop)
      end
    end)

    receive do
      {:ssl_server_port, ^task, port} -> {port, task}
    after
      1_000 -> flunk("ssl test server failed to start")
    end
  end

  defp server_ssl_options(certfile, keyfile) do
    [
      certfile: certfile,
      keyfile: keyfile,
      reuseaddr: true,
      active: false,
      mode: :binary,
      packet: :raw
    ]
  end

  defp tcp_echo_loop(socket, observer) do
    receive do
      :stop ->
        :gen_tcp.close(socket)
    after
      25 ->
        case :gen_tcp.recv(socket, 0, 25) do
          {:ok, data} ->
            :ok = :gen_tcp.send(socket, data)
            tcp_echo_loop(socket, observer)

          {:error, :timeout} ->
            tcp_echo_loop(socket, observer)

          {:error, :closed} ->
            send(observer, :tcp_server_closed)
        end
    end
  end

  defp tcp_observe_close(socket, observer) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:error, :closed} -> send(observer, :tcp_server_closed)
      {:ok, _data} -> tcp_observe_close(socket, observer)
      {:error, :timeout} -> tcp_observe_close(socket, observer)
    end
  end

  defp wait_for_tcp_stop_or_close(socket) do
    receive do
      :stop ->
        :gen_tcp.close(socket)
    after
      25 ->
        case :gen_tcp.recv(socket, 0, 25) do
          {:error, :closed} -> :ok
          {:error, :timeout} -> wait_for_tcp_stop_or_close(socket)
          {:ok, _data} -> wait_for_tcp_stop_or_close(socket)
        end
    end
  end

  defp wait_for_ssl_stop_or_close(socket) do
    receive do
      :stop ->
        :ssl.close(socket)
    after
      25 ->
        case :ssl.recv(socket, 0, 25) do
          {:error, :closed} -> :ok
          {:error, :timeout} -> wait_for_ssl_stop_or_close(socket)
          {:ok, _data} -> wait_for_ssl_stop_or_close(socket)
        end
    end
  end

  defp read_chunk!(reader) do
    case await(ReadableStreamDefaultReader.read(reader)) do
      %{done: false, value: value} -> value
      %{done: true} -> flunk("expected a chunk, got stream termination")
    end
  end

  defp read_bytes!(reader, byte_count, acc \\ "")

  defp read_bytes!(_reader, 0, acc), do: acc

  defp read_bytes!(reader, byte_count, acc) when byte_count > 0 do
    chunk = read_chunk!(reader)
    read_bytes!(reader, byte_count - byte_size(chunk), acc <> chunk)
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(_fun, 0), do: flunk("condition was not met in time")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp fixture_path(file_name) do
    Path.expand("../support/ssl/" <> file_name, __DIR__)
  end

  defp assert_opened_remote(socket, expected_remote_address) do
    assert %{remoteAddress: remote_address} = await(socket.opened)
    assert remote_address == expected_remote_address
  end

  defp socket_debug(socket) do
    socket_request(socket, :debug)
  end

  defp socket_raw_cast(target, body) do
    send(target, {:"$gen_cast", body})
    :ok
  end

  defp socket_request(socket, body, timeout \\ 1_000) do
    socket_raw_request(socket.address, Envelope.new(socket.token, body), timeout)
  end

  defp socket_raw_request(target, body, timeout \\ 1_000) do
    reply_ref = make_ref()
    send(target, {:"$gen_call", {self(), reply_ref}, body})

    receive do
      {^reply_ref, reply} -> reply
    after
      timeout -> flunk("socket request timed out")
    end
  end

  defp assert_alias_revoked(target, body, timeout \\ 100) do
    reply_ref = make_ref()
    send(target, {:"$gen_call", {self(), reply_ref}, body})
    refute_receive {^reply_ref, _reply}, timeout
  end

  defp blocking_connect(parent, gate) do
    fn _host, _port, _opts, _timeout ->
      send(parent, {:connect_blocked, gate})

      receive do
        {^gate, result} -> result
      end
    end
  end
end
