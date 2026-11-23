defmodule Web.SocketTest do
  use ExUnit.Case, async: false

  import Web, only: [await: 1]

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultReader
  alias Web.Socket
  alias Web.TypeError
  alias Web.WritableStreamDefaultWriter

  # A socket with the options of the library for its tests: see
  # `Web.Socket.start_socket/3`. `Web.connect/2` has only the options of the
  # Sockets API.
  defp connect(address, options), do: Socket.start_socket(self(), address, options)

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

    assert await(Socket.close(socket)) == nil
    assert_receive :tcp_server_closed, 1_000
  end

  test "the readable side gives Uint8Array values, and a write accepts each form of bytes" do
    parent = self()
    {port, _task} = start_tcp_server(fn socket -> tcp_echo_loop(socket, parent) end)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")

    reader = ReadableStream.get_reader(socket.readable)
    writer = Web.WritableStream.get_writer(socket.writable)

    for chunk <- ["ab", Web.Uint8Array.from("cd"), Web.ArrayBuffer.new("ef"), [?g, "h"]] do
      assert :ok = await(WritableStreamDefaultWriter.write(writer, chunk))
    end

    assert %{value: %Web.Uint8Array{}} = first = await(ReadableStreamDefaultReader.read(reader))
    rest = read_bytes!(reader, 8 - first.value.byte_length)
    assert to_string(first.value) <> rest == "abcdefgh"

    assert %TypeError{message: message} =
             catch_exit(await(WritableStreamDefaultWriter.write(writer, :not_bytes)))

    assert message == "Socket writes must be a binary, a Uint8Array, or an ArrayBuffer"

    Socket.close(socket)
  end

  test "a handle with a token that is not correct has no effect" do
    parent = self()

    {port, _task} =
      start_tcp_server(fn socket ->
        tcp_echo_loop(socket, parent)
      end)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")
    forged = %{socket | token: make_ref()}

    assert GenServer.call(socket.address, {make_ref(), {:close, :closed}}) == {:error, :detached}
    assert GenServer.call(socket.address, {make_ref(), :debug}) == {:error, :detached}
    assert GenServer.call(socket.address, :not_a_request) == {:error, :detached}

    assert_raise TypeError, "SocketError: the socket is closed", fn ->
      Socket.start_tls(forged)
    end

    # A close with a forged handle returns the promise, and closes nothing.
    assert %Web.Promise{} = Socket.close(forged)

    reader = ReadableStream.get_reader(socket.readable)
    writer = Web.WritableStream.get_writer(socket.writable)

    assert :ok = await(WritableStreamDefaultWriter.write(writer, "still open"))
    assert read_chunk!(reader) == "still open"
    assert await(Socket.close(socket)) == nil
  end

  test "the server ignores a request and a message that it does not know" do
    {port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")

    refute Map.has_key?(socket_debug(socket), :server_pid)
    refute Map.has_key?(socket_debug(socket), :socket)
    assert socket_request(socket, :bogus) == {:error, :unsupported_operation}

    GenServer.cast(socket.address, {socket.token, :bogus_cast})
    GenServer.cast(socket.address, :bogus)
    send(socket.address, :bogus_info)

    assert %{transport: :tcp} = socket_debug(socket)
    assert await(Socket.close(socket)) == nil
  end

  test "opened and closed reject with a SocketError when the connection fails" do
    socket =
      connect("localhost:9",
        connect_fun: fn _host, _port, _opts, _timeout -> {:error, :timeout} end
      )

    error = catch_exit(await(socket.opened))
    assert %TypeError{message: "SocketError: connection failed", cause: :timeout} = error
    assert catch_exit(await(socket.closed)) == error

    # The readable side is cancelled with the error, and the writable side
    # is aborted with it.
    assert Enum.to_list(socket.readable) == []
    writer = Web.WritableStream.get_writer(socket.writable)
    assert catch_exit(await(WritableStreamDefaultWriter.write(writer, "late"))) == error
    refute Socket.upgraded?(socket)
  end

  test "connect/2 ignores each option that is not a member of SocketOptions" do
    {port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)

    # A dictionary of Web IDL has only its members: `secureTransport` is
    # `secure_transport`, and the options of the library have no effect.
    socket =
      Web.connect("localhost:#{port}",
        secureTransport: "udp",
        connect_fun: fn _host, _port, _opts, _timeout -> {:error, :from_the_test} end,
        readable_high_water_mark: 1
      )

    assert_opened_remote(socket, "localhost:#{port}")
    assert await(Socket.close(socket)) == nil
  end

  test "connect/2 raises a SocketError for a value of SocketOptions that is not valid" do
    # `SecureTransportKind` is an enumeration of Web IDL.
    assert_raise TypeError, ~r/SocketError: invalid secureTransport "udp"/, fn ->
      Web.connect("localhost:25", secure_transport: "udp")
    end

    assert_raise TypeError, ~r/SocketError: invalid alpn/, fn ->
      Web.connect("localhost:25", secure_transport: "on", alpn: "h2")
    end

    assert_raise TypeError, ~r/SocketError: invalid alpn protocol 1/, fn ->
      Web.connect("localhost:25", secure_transport: "on", alpn: [1])
    end

    assert_raise TypeError, ~r/SocketError: invalid sni/, fn ->
      Web.connect("localhost:25", secure_transport: "on", sni: 1)
    end

    # `sni` and `alpn` need a secure transport.
    for options <- [[sni: "example.com"], [alpn: ["h2"]], [secure_transport: "off", sni: :a]] do
      assert_raise TypeError, ~r/SocketError: the options sni and alpn need a secure/, fn ->
        Web.connect("localhost:25", options)
      end
    end

    # `nil` is `undefined`: the default value.
    socket = Web.connect("localhost:9", sni: nil, alpn: nil)
    assert await(Socket.close(socket)) == nil
  end

  test "a connect function that raises fails the socket" do
    socket =
      connect("localhost:9", connect_fun: fn _host, _port, _opts, _timeout -> raise "no" end)

    assert %TypeError{message: "SocketError: connection failed", cause: %RuntimeError{}} =
             error = catch_exit(await(socket.opened))

    assert catch_exit(await(socket.closed)) == error
    assert_stopped(socket)
  end

  test "a connector that a different process kills fails the socket" do
    gate = make_ref()
    socket = connect("localhost:0", connect_fun: blocking_connect(self(), gate))
    assert_receive {:connect_blocked, ^gate, connector}, 1_000

    Process.exit(connector, :kill)

    assert %TypeError{message: "SocketError: connection failed", cause: :killed} =
             catch_exit(await(socket.closed))

    assert_stopped(socket)
  end

  test "a write during the connect gets the error of the connect, or of a close" do
    gate = make_ref()
    socket = connect("localhost:0", connect_fun: blocking_connect(self(), gate))
    assert_receive {:connect_blocked, ^gate, connector}, 1_000

    writer = Web.WritableStream.get_writer(socket.writable)
    write = WritableStreamDefaultWriter.write(writer, "early")
    assert eventually_debug(socket, fn _debug -> waiting(socket) == 1 end)
    send(connector, {gate, {:error, :econnrefused}})

    assert %TypeError{cause: :econnrefused} = error = catch_exit(await(socket.closed))
    assert catch_exit(await(write)) == error

    gate = make_ref()
    socket = connect("localhost:0", connect_fun: blocking_connect(self(), gate))
    assert_receive {:connect_blocked, ^gate, _connector}, 1_000

    writer = Web.WritableStream.get_writer(socket.writable)
    write = WritableStreamDefaultWriter.write(writer, "early")
    assert eventually_debug(socket, fn _debug -> waiting(socket) == 1 end)
    assert await(Socket.close(socket, :bye)) == nil

    assert %TypeError{message: "SocketError: the socket is closed"} = catch_exit(await(write))
  end

  test "initial tls connect failures reject the opened promise" do
    socket =
      connect("localhost:465",
        secure_transport: "on",
        ssl_connect_fun: fn _host, _port, _opts, _timeout -> {:error, :ssl_timeout} end
      )

    assert %TypeError{message: "SocketError: connection failed", cause: :ssl_timeout} =
             error = catch_exit(await(socket.opened))

    assert catch_exit(await(socket.closed)) == error
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

    socket =
      connect("localhost:#{port}", readable_high_water_mark: 4, tcp_options: [nodelay: true])

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
    assert await(Socket.close(socket)) == nil
  end

  test "a cancel of the readable side does not close the socket" do
    parent = self()
    {port, _task} = start_tcp_server(&tcp_observe(&1, parent))

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")

    assert :ok = await(ReadableStream.cancel(socket.readable, :reader_cancelled))
    assert eventually_debug(socket, &(&1.reading? == false))

    # The writable side works, and closed is pending.
    writer = Web.WritableStream.get_writer(socket.writable)
    assert :ok = await(WritableStreamDefaultWriter.write(writer, "after cancel"))
    assert_receive {:tcp_server_got, "after cancel"}, 1_000
    assert Web.Promise.peek(socket.closed) == :pending

    assert await(Socket.close(socket)) == nil
    assert_receive :tcp_server_closed, 1_000
  end

  test "a stream of the socket that stops with a failure closes the socket, and closed rejects" do
    {port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")

    Process.exit(socket.readable.controller_pid, :kill)

    assert %TypeError{message: "SocketError: connection failed", cause: {:stream_down, :killed}} =
             catch_exit(await(socket.closed))
  end

  test "a close of the writer sends the end of the data, and the readable side continues" do
    parent = self()

    {port, _task} =
      start_tcp_server(fn peer ->
        # The peer reads until the end of the data of the client. It
        # answers when the test tells it, then it closes.
        assert {:ok, "request"} = :gen_tcp.recv(peer, 0, 5_000)
        assert {:error, :closed} = :gen_tcp.recv(peer, 0, 5_000)
        send(parent, {:peer_saw_end, self()})

        receive do
          :answer -> :ok = :gen_tcp.send(peer, "answer")
        end

        :gen_tcp.close(peer)
      end)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")
    writer = Web.WritableStream.get_writer(socket.writable)
    reader = ReadableStream.get_reader(socket.readable)

    assert :ok = await(WritableStreamDefaultWriter.write(writer, "request"))
    assert :ok = await(WritableStreamDefaultWriter.close(writer))
    assert_receive {:peer_saw_end, peer}, 1_000

    # The close of the writable side does not close the socket.
    assert Web.Promise.peek(socket.closed) == :pending
    send(peer, :answer)
    assert read_chunk!(reader) == "answer"

    # The peer closed: with no allowHalfOpen, the socket closes.
    assert %{done: true} = await(ReadableStreamDefaultReader.read(reader))
    assert await(socket.closed) == nil
    assert_stopped(socket)
  end

  test "an abort of the writer sends the end of the data, and the socket stays" do
    parent = self()
    {port, _task} = start_tcp_server(&tcp_observe(&1, parent))

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")

    writer = Web.WritableStream.get_writer(socket.writable)
    assert :ok = await(WritableStreamDefaultWriter.abort(writer, :user_abort))
    assert_receive :tcp_server_closed, 1_000
    assert eventually_debug(socket, &(&1.writing? == false))
    assert Web.Promise.peek(socket.closed) == :pending

    assert await(Socket.close(socket)) == nil
    assert_stopped(socket)
  end

  test "a chunk that is not bytes ends the writable side, and the socket stays" do
    parent = self()
    {port, _task} = start_tcp_server(&tcp_observe(&1, parent))

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")
    writer = Web.WritableStream.get_writer(socket.writable)

    # The chunk is an error of the caller, not of the transport. The write
    # rejects with the TypeError, and the writable side has that error.
    reason = catch_exit(await(WritableStreamDefaultWriter.write(writer, %{bad: :payload})))
    assert %TypeError{message: "Socket writes must be" <> _} = reason
    assert catch_exit(await(WritableStreamDefaultWriter.write(writer, "late"))) == reason

    # The peer gets the end of the data. The socket is not closed.
    assert_receive :tcp_server_closed, 1_000
    assert eventually_debug(socket, &(&1.writing? == false))
    assert Web.Promise.peek(socket.closed) == :pending
    assert await(Socket.close(socket)) == nil
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

    assert_receive {:holder_socket, socket}, 1_000
    Process.exit(holder, :boom)

    # The socket closes as with close/2. The promises belong to the holder:
    # they stopped with it.
    assert_receive :tcp_server_closed, 1_000
    assert_stopped(socket)
  end

  test "start_tls returns a new secure socket at once, and upgrades the first socket" do
    parent = self()
    certfile = fixture_path("test_server_cert.pem")
    keyfile = fixture_path("test_server_key.pem")

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

    socket = Web.connect(%{hostname: "localhost", port: port}, secure_transport: "starttls")
    assert_opened_remote(socket, "localhost:#{port}")

    reader = ReadableStream.get_reader(socket.readable)
    writer = Web.WritableStream.get_writer(socket.writable)

    assert read_chunk!(reader) == "220 localhost ESMTP ready\r\n"
    assert :ok = await(WritableStreamDefaultWriter.write(writer, "STARTTLS\r\n"))
    assert_receive :saw_starttls, 1_000
    assert read_chunk!(reader) == "220 Ready to start TLS\r\n"

    # The socket verifies the certificate of the server with the certificate
    # authority of the setting `:tls_options`, and it verifies the host name.
    previous = Application.get_env(:web, :tls_options)
    Application.put_env(:web, :tls_options, cacertfile: fixture_path("test_ca.pem"))

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:web, :tls_options),
        else: Application.put_env(:web, :tls_options, previous)
    end)

    refute Socket.upgraded?(socket)
    upgraded = Socket.start_tls(socket)
    assert %Socket{} = upgraded
    # The TLS socket is a new handle to the same process.
    assert upgraded.token != socket.token
    assert upgraded.address == socket.address

    # The first socket is upgraded and closed. Its readers and writers do
    # not work.
    assert Socket.upgraded?(socket)
    refute Socket.upgraded?(upgraded)
    assert await(socket.closed) == nil
    assert %{done: true} = await(ReadableStreamDefaultReader.read(reader))
    assert %TypeError{} = catch_exit(await(WritableStreamDefaultWriter.write(writer, "plain")))
    assert await(Socket.close(socket)) == nil

    # The promise opened of the TLS socket fulfils after the handshake.
    assert %{remote_address: remote, alpn: nil} = await(upgraded.opened)
    assert remote == "localhost:#{port}"

    upgraded_reader = ReadableStream.get_reader(upgraded.readable)
    upgraded_writer = Web.WritableStream.get_writer(upgraded.writable)

    assert :ok =
             await(WritableStreamDefaultWriter.write(upgraded_writer, "EHLO secure.example\r\n"))

    assert_receive :saw_secure_ehlo, 1_000
    assert read_chunk!(upgraded_reader) == "250 encrypted\r\n"
    assert await(upgraded.closed) == nil
  end

  test "a handshake that fails fails the new socket with a SocketError" do
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

    socket = Web.connect("localhost:#{port}", secure_transport: "starttls")
    assert_opened_remote(socket, "localhost:#{port}")

    reader = ReadableStream.get_reader(socket.readable)
    writer = Web.WritableStream.get_writer(socket.writable)

    assert read_chunk!(reader) == "220 localhost ESMTP ready\r\n"
    assert :ok = await(WritableStreamDefaultWriter.write(writer, "STARTTLS\r\n"))
    assert read_chunk!(reader) == "220 Ready to start TLS\r\n"

    tls_socket = Socket.__start_tls__(socket, verify: :verify_none)

    assert %TypeError{message: "SocketError: TLS handshake failed"} =
             error = catch_exit(await(tls_socket.opened))

    assert catch_exit(await(tls_socket.closed)) == error
    assert Socket.upgraded?(socket)
    assert await(socket.closed) == nil
    assert_stopped(socket)
  end

  test "server closing immediately after connect shuts down the socket and revokes the alias" do
    {port, _task} = start_tcp_server(&:gen_tcp.close/1)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")

    assert await(socket.closed) == nil
    assert_stopped(socket)
  end

  describe "the verification of the server certificate" do
    # Starts a TLS server that sends one message, and returns its port. The
    # server stays in operation when the client refuses the handshake.
    defp start_verified_server(parent) do
      options =
        server_ssl_options(
          fixture_path("test_server_cert.pem"),
          fixture_path("test_server_key.pem")
        )

      {:ok, _task} =
        Task.start_link(fn ->
          {:ok, listen_socket} = :ssl.listen(0, options)
          {:ok, {_address, port}} = :ssl.sockname(listen_socket)
          send(parent, {:verified_server_port, port})

          with {:ok, transport_socket} <- :ssl.transport_accept(listen_socket, 5_000),
               {:ok, socket} <- :ssl.handshake(transport_socket, 5_000) do
            :ssl.send(socket, "verified")
            :ssl.close(socket)
          end

          :ssl.close(listen_socket)
        end)

      assert_receive {:verified_server_port, port}, 1_000
      port
    end

    defp tls_alert(socket) do
      assert %TypeError{
               message: "SocketError: connection failed",
               cause: {:tls_alert, {alert, _}}
             } =
               catch_exit(await(socket.opened))

      alert
    end

    test "accepts a certificate from a certificate authority that the caller gives" do
      port = start_verified_server(self())

      socket =
        connect("localhost:#{port}",
          secure_transport: "on",
          ssl_options: [cacertfile: fixture_path("test_ca.pem")]
        )

      assert_opened_remote(socket, "localhost:#{port}")
      assert read_chunk!(ReadableStream.get_reader(socket.readable)) == "verified"
    end

    @tag :capture_log
    test "refuses a certificate from a certificate authority that is not known" do
      port = start_verified_server(self())
      socket = Web.connect("localhost:#{port}", secure_transport: "on")

      assert tls_alert(socket) == :unknown_ca
    end

    @tag :capture_log
    test "refuses a certificate for a different host name" do
      port = start_verified_server(self())

      # The certificate is for the name `localhost`.
      socket =
        connect(%{hostname: "127.0.0.1", port: port},
          secure_transport: "on",
          ssl_options: [cacertfile: fixture_path("test_ca.pem")]
        )

      assert tls_alert(socket) == :bad_certificate
    end

    test "verifies the certificate with the name of the option sni" do
      port = start_verified_server(self())

      # The certificate is for the name `localhost`: the address is not.
      socket =
        connect(%{hostname: "127.0.0.1", port: port},
          secure_transport: "on",
          sni: "localhost",
          ssl_options: [cacertfile: fixture_path("test_ca.pem")]
        )

      assert_opened_remote(socket, "127.0.0.1:#{port}")
      assert read_chunk!(ReadableStream.get_reader(socket.readable)) == "verified"
    end

    test "does no verification only when the caller asks for that" do
      port = start_verified_server(self())

      socket =
        connect(%{hostname: "127.0.0.1", port: port},
          secure_transport: "on",
          ssl_options: [verify: :verify_none]
        )

      assert_opened_remote(socket, "127.0.0.1:#{port}")
    end

    test "uses the setting :tls_options of the application" do
      previous = Application.get_env(:web, :tls_options)
      Application.put_env(:web, :tls_options, cacertfile: fixture_path("test_ca.pem"))

      on_exit(fn ->
        if previous == nil,
          do: Application.delete_env(:web, :tls_options),
          else: Application.put_env(:web, :tls_options, previous)
      end)

      port = start_verified_server(self())
      socket = Web.connect("localhost:#{port}", secure_transport: "on")

      assert_opened_remote(socket, "localhost:#{port}")
    end
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
      connect("localhost:#{port}", secure_transport: "on", ssl_options: [verify: :verify_none])

    assert_opened_remote(socket, "localhost:#{port}")

    reader = ReadableStream.get_reader(socket.readable)

    assert_receive :ssl_server_sent, 1_000
    assert read_chunk!(reader) == "secure hello"
    assert await(socket.closed) == nil
    refute Socket.upgraded?(socket)
  end

  test "the option alpn gives the protocols, and SocketInfo has the selected protocol" do
    certfile = fixture_path("socket_test_cert.pem")
    keyfile = fixture_path("socket_test_key.pem")

    {port, _task} =
      start_ssl_server(
        &wait_for_ssl_stop_or_close/1,
        certfile,
        keyfile,
        alpn_preferred_protocols: ["h2", "http/1.1"]
      )

    socket =
      connect("localhost:#{port}",
        secure_transport: "on",
        alpn: ["http/1.1", :other],
        ssl_options: [verify: :verify_none]
      )

    assert %{alpn: "http/1.1", local_address: "127.0.0.1:" <> local_port} = await(socket.opened)
    assert {_port, ""} = Integer.parse(local_port)

    # A close of the writer ends the data of the TLS connection. The server
    # then closes: TLS has no half close.
    writer = Web.WritableStream.get_writer(socket.writable)
    assert :ok = await(WritableStreamDefaultWriter.close(writer))
    assert await(socket.closed) == nil
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
      connect("localhost:#{port}", secure_transport: "on", ssl_options: [verify: :verify_none])

    assert_opened_remote(socket, "localhost:#{port}")

    assert_raise TypeError, ~r/SocketError: startTls\(\) needs the option secureTransport/, fn ->
      Socket.__start_tls__(socket, verify: :verify_none)
    end

    refute Socket.upgraded?(socket)
    assert Web.Promise.peek(socket.closed) == :pending
    assert await(Socket.close(socket)) == nil
  end

  test "start_tls after a cancel of the first readable side" do
    certfile = fixture_path("socket_test_cert.pem")
    keyfile = fixture_path("socket_test_key.pem")

    {port, _task} =
      start_tcp_server(fn socket ->
        {:ok, ssl_socket} = :ssl.handshake(socket, server_ssl_options(certfile, keyfile), 5_000)
        :ok = :ssl.send(ssl_socket, "secure")
        wait_for_ssl_stop_or_close(ssl_socket)
      end)

    socket = Web.connect("localhost:#{port}", secure_transport: "starttls")
    assert_opened_remote(socket, "localhost:#{port}")
    assert :ok = await(ReadableStream.cancel(socket.readable, :not_needed))
    assert eventually_debug(socket, &(&1.reading? == false))

    tls_socket = Socket.__start_tls__(socket, verify: :verify_none)
    assert %{remote_address: _remote} = await(tls_socket.opened)
    assert read_chunk!(ReadableStream.get_reader(tls_socket.readable)) == "secure"
    assert await(Socket.close(tls_socket)) == nil
  end

  test "start_tls during the connect waits for the connection" do
    certfile = fixture_path("socket_test_cert.pem")
    keyfile = fixture_path("socket_test_key.pem")

    {port, _task} =
      start_tcp_server(fn socket ->
        {:ok, ssl_socket} = :ssl.handshake(socket, server_ssl_options(certfile, keyfile), 5_000)
        :ok = :ssl.send(ssl_socket, "secure")
        wait_for_ssl_stop_or_close(ssl_socket)
      end)

    test = self()
    gate = make_ref()

    connect = fn host, port, options, timeout ->
      send(test, {:connect_blocked, gate, self()})

      receive do
        {^gate, :go} -> :gen_tcp.connect(host, port, options, timeout)
      end
    end

    socket = connect("localhost:#{port}", secure_transport: "starttls", connect_fun: connect)
    assert_receive {:connect_blocked, ^gate, connector}, 1_000

    task = Task.async(fn -> Socket.__start_tls__(socket, verify: :verify_none) end)

    # The call waits for the connection. The check of an absence waits a
    # short time.
    refute Task.yield(task, 100)
    send(connector, {gate, :go})

    tls_socket = Task.await(task)
    assert Socket.upgraded?(socket)
    assert %{remote_address: _remote} = await(tls_socket.opened)
    assert read_chunk!(ReadableStream.get_reader(tls_socket.readable)) == "secure"
    assert await(Socket.close(tls_socket)) == nil
  end

  test "start_tls on a TLS socket, and a second start_tls, raise a SocketError" do
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

    socket = Web.connect("localhost:#{port}", secure_transport: "starttls")
    assert_opened_remote(socket, "localhost:#{port}")

    reader = ReadableStream.get_reader(socket.readable)
    writer = Web.WritableStream.get_writer(socket.writable)
    assert read_chunk!(reader) == "220 localhost ESMTP ready\r\n"
    assert :ok = await(WritableStreamDefaultWriter.write(writer, "STARTTLS\r\n"))
    assert read_chunk!(reader) == "220 Ready to start TLS\r\n"

    upgraded = Socket.__start_tls__(socket, verify: :verify_none)
    assert_receive :tls_upgrade_complete, 1_000
    assert %{alpn: nil} = await(upgraded.opened)

    assert_raise TypeError, ~r/SocketError: startTls\(\) cannot start TLS on a TLS socket/, fn ->
      Socket.__start_tls__(upgraded, verify: :verify_none)
    end

    assert_raise TypeError, ~r/SocketError: startTls\(\) can start TLS only one time/, fn ->
      Socket.start_tls(socket)
    end

    assert await(Socket.close(upgraded)) == nil
  end

  test "capability-safe synthetic transport events drive shutdown branches" do
    tcp_error_handle = {:fake_tcp, make_ref()}

    tcp_error_socket =
      connect("localhost:0",
        connect_fun: fn _host, _port, _opts, _timeout -> {:ok, tcp_error_handle} end
      )

    assert_opened_remote(tcp_error_socket, "localhost:0")
    send(tcp_error_socket.address, {:tcp_error, tcp_error_handle, :econnreset})

    assert %TypeError{message: "SocketError: connection failed", cause: :econnreset} =
             catch_exit(await(tcp_error_socket.closed))

    assert_stopped(tcp_error_socket)

    tcp_closed_handle = {:fake_tcp, make_ref()}

    tcp_closed_socket =
      connect("localhost:0",
        connect_fun: fn _host, _port, _opts, _timeout -> {:ok, tcp_closed_handle} end
      )

    assert_opened_remote(tcp_closed_socket, "localhost:0")
    send(tcp_closed_socket.address, {:tcp_closed, tcp_closed_handle})
    assert await(tcp_closed_socket.closed) == nil
    assert_stopped(tcp_closed_socket)

    ssl_error_handle = {:fake_ssl, make_ref()}

    ssl_error_socket =
      connect("localhost:0",
        secure_transport: "on",
        ssl_connect_fun: fn _host, _port, _opts, _timeout -> {:ok, ssl_error_handle} end
      )

    assert_opened_remote(ssl_error_socket, "localhost:0")
    send(ssl_error_socket.address, {:ssl_error, ssl_error_handle, :closed})

    assert %TypeError{message: "SocketError: connection failed", cause: :closed} =
             catch_exit(await(ssl_error_socket.closed))

    assert_stopped(ssl_error_socket)

    ssl_closed_handle = {:fake_ssl, make_ref()}

    ssl_closed_socket =
      connect("localhost:0",
        secure_transport: "on",
        ssl_connect_fun: fn _host, _port, _opts, _timeout -> {:ok, ssl_closed_handle} end
      )

    assert_opened_remote(ssl_closed_socket, "localhost:0")
    send(ssl_closed_socket.address, {:ssl_closed, ssl_closed_handle})
    assert await(ssl_closed_socket.closed) == nil
    assert_stopped(ssl_closed_socket)
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

    assert await(Socket.close(socket)) == nil
    assert_stopped(socket)
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

    # An IPv6 address needs its brackets, and the port after them.
    for address <- ["[::1", "[::1]8080", "::1:8080"] do
      assert_raise TypeError, ~r/SocketError: invalid address/, fn -> Web.connect(address) end
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
    assert await(Socket.close(socket)) == nil
  end

  test "Socket.start_socket/2 uses default options" do
    {port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)
    socket = Socket.start_socket(self(), "localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")
    assert await(Socket.close(socket)) == nil
  end

  test "starttls connection failures reject opened and closed" do
    socket =
      connect("localhost:25",
        secure_transport: "starttls",
        connect_fun: fn _host, _port, _opts, _timeout -> {:error, :starttls_timeout} end
      )

    assert %TypeError{cause: :starttls_timeout} = error = catch_exit(await(socket.opened))
    assert catch_exit(await(socket.closed)) == error
  end

  test "a write that the transport refuses rejects, and the socket closes with the error" do
    # A socket of Erlang/OTP that is closed: each send gives an error.
    {:ok, closed} = :gen_tcp.listen(0, [:binary])
    :ok = :gen_tcp.close(closed)

    socket =
      connect("localhost:0",
        connect_fun: fn _host, _port, _opts, _timeout -> {:ok, closed} end
      )

    assert_opened_remote(socket, "localhost:0")
    writer = Web.WritableStream.get_writer(socket.writable)

    error = catch_exit(await(WritableStreamDefaultWriter.write(writer, "data")))
    assert %TypeError{message: "SocketError: connection failed", cause: reason} = error
    assert reason in [:closed, :einval]
    assert catch_exit(await(socket.closed)) == error
    assert catch_exit(await(WritableStreamDefaultWriter.write(writer, "late"))) == error
    assert_stopped(socket)
  end

  test "a close of the writer waits for the connection" do
    gate = make_ref()
    socket = connect("localhost:0", connect_fun: blocking_connect(self(), gate))
    assert_receive {:connect_blocked, ^gate, connector}, 1_000

    writer = Web.WritableStream.get_writer(socket.writable)
    close = WritableStreamDefaultWriter.close(writer)

    # The close has no time limit: it waits for the connection.
    assert Web.Promise.wait(Web.Promise.race([close, timeout_promise(100)])) ==
             {:fulfilled, :still_pending}

    send(connector, {gate, {:ok, {:fake_tcp, make_ref()}}})

    assert :ok = await(close)
    assert Web.Promise.peek(socket.closed) == :pending
    assert await(Socket.close(socket)) == nil
    assert_stopped(socket)
  end

  test "a close of the writer rejects when the connection fails" do
    gate = make_ref()
    socket = connect("localhost:0", connect_fun: blocking_connect(self(), gate))
    assert_receive {:connect_blocked, ^gate, connector}, 1_000

    writer = Web.WritableStream.get_writer(socket.writable)
    close = WritableStreamDefaultWriter.close(writer)
    send(connector, {gate, {:error, :connect_timeout}})

    assert %TypeError{cause: :connect_timeout} = error = catch_exit(await(socket.opened))
    assert catch_exit(await(socket.closed)) == error
    assert catch_exit(await(close)) == error
    assert_stopped(socket)
  end

  test "close ends the two streams, and a second close has no effect" do
    {port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)
    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")
    writer = Web.WritableStream.get_writer(socket.writable)

    assert await(Socket.close(socket)) == nil
    assert await(Socket.close(socket)) == nil

    # The reason of close/1 is nil, as undefined.
    assert Enum.to_list(socket.readable) == []
    assert catch_exit(await(WritableStreamDefaultWriter.write(writer, "late"))) == nil

    assert_raise TypeError, "SocketError: the socket is closed", fn ->
      Socket.start_tls(socket)
    end
  end

  test "close(reason) cancels the readable side and aborts the writable side with the reason" do
    parent = self()

    {port, _task} =
      start_tcp_server(fn peer ->
        :ok = :gen_tcp.send(peer, "queued")
        send(parent, :peer_sent)
        tcp_observe(peer, parent)
      end)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")
    assert_receive :peer_sent, 1_000
    assert eventually_debug(socket, &(&1.queued_size > 0))

    reader = ReadableStream.get_reader(socket.readable)
    writer = Web.WritableStream.get_writer(socket.writable)

    assert await(Socket.close(socket, :done)) == nil
    assert_receive :tcp_server_closed, 1_000

    # A cancel discards the chunks in the queue.
    assert %{done: true} = await(ReadableStreamDefaultReader.read(reader))
    assert :ok = await(ReadableStreamDefaultReader.closed(reader))
    assert catch_exit(await(WritableStreamDefaultWriter.write(writer, "late"))) == :done
    assert catch_exit(await(WritableStreamDefaultWriter.closed(writer))) == :done
  end

  test "close(reason) rejects a pending opened with the reason" do
    gate = make_ref()
    socket = connect("localhost:0", connect_fun: blocking_connect(self(), gate))
    assert_receive {:connect_blocked, ^gate, connector}, 1_000

    close = Socket.close(socket, :not_needed)
    send(connector, {gate, {:ok, {:fake_tcp, make_ref()}}})

    assert close == socket.closed
    assert await(close) == nil
    assert catch_exit(await(socket.opened)) == :not_needed
  end

  test "with no allowHalfOpen, a close by the peer closes the writable side and the socket" do
    {port, _task} = start_tcp_server(&:gen_tcp.close/1)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")
    writer = Web.WritableStream.get_writer(socket.writable)

    assert await(socket.closed) == nil
    assert Enum.to_list(socket.readable) == []

    # The writable side is closed, not errored.
    assert :ok = await(WritableStreamDefaultWriter.closed(writer))
    assert %TypeError{} = catch_exit(await(WritableStreamDefaultWriter.write(writer, "late")))
    assert_stopped(socket)
  end

  test "with allowHalfOpen, a close by the peer closes only the readable side" do
    parent = self()

    {port, _task} =
      start_tcp_server(fn peer ->
        :ok = :gen_tcp.shutdown(peer, :write)
        send(parent, :peer_shut)
        tcp_observe(peer, parent)
      end)

    socket = Web.connect("localhost:#{port}", allow_half_open: true)
    assert_opened_remote(socket, "localhost:#{port}")
    assert_receive :peer_shut, 1_000

    # The readable side ends, and the socket stays open for writes.
    assert Enum.to_list(socket.readable) == []
    writer = Web.WritableStream.get_writer(socket.writable)
    assert :ok = await(WritableStreamDefaultWriter.write(writer, "after the end"))
    assert_receive {:tcp_server_got, "after the end"}, 1_000
    assert Web.Promise.peek(socket.closed) == :pending

    # A close of the writer sends the end. The socket closes at close/2.
    assert :ok = await(WritableStreamDefaultWriter.close(writer))
    assert_receive :tcp_server_closed, 1_000
    assert Web.Promise.peek(socket.closed) == :pending
    assert await(Socket.close(socket)) == nil
    assert_stopped(socket)
  end

  test "a write that waits for a slow peer does not stop the reads" do
    parent = self()

    # The peer sends data, and reads nothing until the test tells it.
    {port, _task} =
      start_tcp_server(fn peer ->
        :ok = :gen_tcp.send(peer, "from the peer")
        send(parent, {:peer, self()})

        receive do
          :read -> :ok
        end

        drain = fn drain ->
          case :gen_tcp.recv(peer, 0, 2_000) do
            {:ok, _data} -> drain.(drain)
            {:error, _reason} -> :ok
          end
        end

        drain.(drain)
      end)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")
    assert_receive {:peer, peer}

    # The test writes until the buffers of the two sides are full: that
    # write waits.
    writer = Web.WritableStream.get_writer(socket.writable)
    chunk = :binary.copy("x", 8_000_000)

    write =
      Enum.find_value(1..40, fn _index ->
        write = WritableStreamDefaultWriter.write(writer, chunk)

        case Web.Promise.wait(Web.Promise.race([write, timeout_promise(200)])) do
          {:fulfilled, :still_pending} -> write
          {:fulfilled, :ok} -> nil
        end
      end)

    assert %Web.Promise{} = write

    # The socket reads while the write waits.
    reader = ReadableStream.get_reader(socket.readable)
    assert read_chunk!(reader) == "from the peer"

    send(peer, :read)
    assert :ok = await(write)
    assert await(Socket.close(socket)) == nil
  end

  defp timeout_promise(ms) do
    Web.Promise.new(fn resolve, _reject ->
      Process.sleep(ms)
      resolve.(:still_pending)
    end)
  end

  test "connect normalizes alternate address and option forms" do
    {tcp_port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)

    socket =
      connect(%{"hostname" => "localhost", port: tcp_port},
        secure_transport: "off",
        tcp_options: nil
      )

    assert_opened_remote(socket, "localhost:#{tcp_port}")
    assert await(Socket.close(socket)) == nil

    {tcp_port2, _task2} = start_tcp_server(&wait_for_tcp_stop_or_close/1)

    socket2 =
      connect("localhost:#{tcp_port2}",
        tcp_options: {:send_timeout, 1_000},
        ssl_options: :bogus
      )

    assert_opened_remote(socket2, "localhost:#{tcp_port2}")
    assert await(Socket.close(socket2)) == nil

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
      connect("localhost:#{ssl_port}",
        secure_transport: "on",
        ssl_options: %{verify: :verify_none}
      )

    assert_opened_remote(socket3, "localhost:#{ssl_port}")
    assert await(Socket.close(socket3)) == nil
  end

  defp start_tcp_server(handler) do
    parent = self()

    {:ok, task} =
      Task.start_link(fn ->
        # A peer can write after the end of the data of the client.
        {:ok, listen_socket} =
          :gen_tcp.listen(0, [
            :binary,
            packet: :raw,
            active: false,
            reuseaddr: true,
            exit_on_close: false
          ])

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

  defp start_ssl_server(handler, certfile, keyfile, options \\ []) do
    parent = self()

    {:ok, task} =
      Task.start_link(fn ->
        {:ok, listen_socket} = :ssl.listen(0, server_ssl_options(certfile, keyfile) ++ options)
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

  # A peer that tells the test about each data that it gets, and about the
  # end of the data. After the end, the peer keeps its side open until the
  # end of the test.
  defp tcp_observe(socket, observer) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        send(observer, {:tcp_server_got, data})
        tcp_observe(socket, observer)

      {:error, :timeout} ->
        tcp_observe(socket, observer)

      {:error, :closed} ->
        send(observer, :tcp_server_closed)

        receive do
          :stop -> :gen_tcp.close(socket)
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
      %{done: false, value: value} -> Web.TestBytes.binary(value)
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
    assert %{remote_address: remote_address} = await(socket.opened)
    assert remote_address == expected_remote_address
  end

  defp socket_debug(socket) do
    socket_request(socket, :debug)
  end

  # The requests that wait for the connect.
  defp waiting(socket), do: length(:sys.get_state(socket.address).waiting)

  # The state of the server becomes the state of `fun`.
  defp eventually_debug(socket, fun) do
    assert_eventually(fn -> fun.(socket_debug(socket)) end)
    true
  end

  # The server of the socket stopped.
  defp assert_stopped(socket) do
    assert_eventually(fn -> not Process.alive?(socket.address) end)
  end

  defp socket_request(socket, body) do
    GenServer.call(socket.address, {socket.token, body})
  end

  # A connect that waits for the test. The connect runs in a process of the
  # socket: the test sends the result to that process.
  defp blocking_connect(parent, gate) do
    fn _host, _port, _opts, _timeout ->
      send(parent, {:connect_blocked, gate, self()})

      receive do
        {^gate, result} -> result
      end
    end
  end
end
