defmodule Web.SocketTest do
  use ExUnit.Case, async: false

  import Web, only: [await: 1]

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
    assert Web.Uint8Array.to_binary(first.value) <> rest == "abcdefgh"

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
    assert catch_exit(await(Socket.start_tls(forged))) == :closed

    # A close with a forged handle returns the promise, and closes nothing.
    assert %Web.Promise{} = Socket.close(forged)

    reader = ReadableStream.get_reader(socket.readable)
    writer = Web.WritableStream.get_writer(socket.writable)

    assert :ok = await(WritableStreamDefaultWriter.write(writer, "still open"))
    assert read_chunk!(reader) == "still open"
    assert :closed = await(Socket.close(socket))
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
    assert :closed = await(Socket.close(socket))
  end

  test "opened and closed reject when the connection fails" do
    socket =
      Web.connect("localhost:9",
        connect_fun: fn _host, _port, _opts, _timeout -> {:error, :timeout} end
      )

    assert :timeout = catch_exit(await(socket.opened))
    assert catch_exit(await(socket.closed)) == :timeout
    assert :timeout = catch_exit(await(socket.upgraded))
  end

  test "opened rejects for unsupported secure transport kinds" do
    socket = Web.connect("localhost:25", secureTransport: "udp")

    assert {:unsupported_secure_transport, "udp"} = catch_exit(await(socket.opened))
    assert catch_exit(await(socket.closed)) == {:unsupported_secure_transport, "udp"}
  end

  test "initial tls connect failures reject the opened promise" do
    socket =
      Web.connect("localhost:465",
        secureTransport: "on",
        ssl_connect_fun: fn _host, _port, _opts, _timeout -> {:error, :ssl_timeout} end
      )

    assert :ssl_timeout = catch_exit(await(socket.opened))
    assert catch_exit(await(socket.closed)) == :ssl_timeout
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

  test "a stream of the socket that stops with a failure closes the socket, and closed rejects" do
    {port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")

    Process.exit(socket.readable.controller_pid, :kill)
    assert catch_exit(await(socket.closed)) == {:stream_down, :killed}
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

    # The chunk is an error of the caller, not of the transport. The write
    # rejects with the TypeError, and the writable side has that error.
    reason = catch_exit(await(WritableStreamDefaultWriter.write(writer, %{bad: :payload})))
    assert %TypeError{} = reason
    assert catch_exit(await(socket.closed)) == reason
    assert catch_exit(await(WritableStreamDefaultWriter.write(writer, "late"))) == reason
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

    socket = Web.connect(%{hostname: "localhost", port: port}, secureTransport: "starttls")
    assert_opened_remote(socket, "localhost:#{port}")

    reader = ReadableStream.get_reader(socket.readable)
    writer = Web.WritableStream.get_writer(socket.writable)

    assert read_chunk!(reader) == "220 localhost ESMTP ready\r\n"
    assert :ok = await(WritableStreamDefaultWriter.write(writer, "STARTTLS\r\n"))
    assert_receive :saw_starttls, 1_000
    assert read_chunk!(reader) == "220 Ready to start TLS\r\n"

    # The socket verifies the certificate of the server with this
    # certificate authority, and it verifies the host name.
    upgraded = await(Socket.start_tls(socket, cacertfile: fixture_path("test_ca.pem")))
    assert %Socket{} = upgraded
    # The TLS socket is a new handle to the same process.
    assert upgraded.token != socket.token
    assert await(socket.upgraded) == upgraded
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
    assert match?({:tls_upgrade_failed, _}, catch_exit(await(socket.closed)))
    assert match?({:tls_upgrade_failed, _}, catch_exit(await(socket.upgraded)))
    assert_stopped(socket)
  end

  test "server closing immediately after connect shuts down the socket and revokes the alias" do
    {port, _task} = start_tcp_server(&:gen_tcp.close/1)

    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")

    assert await(socket.closed) == :closed
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
      assert {:tls_alert, {alert, _text}} = catch_exit(await(socket.opened))
      alert
    end

    test "accepts a certificate from a certificate authority that the caller gives" do
      port = start_verified_server(self())

      socket =
        Web.connect("localhost:#{port}",
          secureTransport: "on",
          ssl_options: [cacertfile: fixture_path("test_ca.pem")]
        )

      assert_opened_remote(socket, "localhost:#{port}")
      assert read_chunk!(ReadableStream.get_reader(socket.readable)) == "verified"
    end

    @tag :capture_log
    test "refuses a certificate from a certificate authority that is not known" do
      port = start_verified_server(self())
      socket = Web.connect("localhost:#{port}", secureTransport: "on")

      assert tls_alert(socket) == :unknown_ca
    end

    @tag :capture_log
    test "refuses a certificate for a different host name" do
      port = start_verified_server(self())

      # The certificate is for the name `localhost`.
      socket =
        Web.connect(%{hostname: "127.0.0.1", port: port},
          secureTransport: "on",
          ssl_options: [cacertfile: fixture_path("test_ca.pem")]
        )

      assert tls_alert(socket) == :bad_certificate
    end

    test "does no verification only when the caller asks for that" do
      port = start_verified_server(self())

      socket =
        Web.connect(%{hostname: "127.0.0.1", port: port},
          secureTransport: "on",
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
      socket = Web.connect("localhost:#{port}", secureTransport: "on")

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
    assert catch_exit(await(tcp_error_socket.closed)) == {:transport_error, :econnreset}
    assert_stopped(tcp_error_socket)

    tcp_closed_handle = {:fake_tcp, make_ref()}

    tcp_closed_socket =
      Web.connect("localhost:0",
        connect_fun: fn _host, _port, _opts, _timeout -> {:ok, tcp_closed_handle} end
      )

    assert_opened_remote(tcp_closed_socket, "localhost:0")
    send(tcp_closed_socket.address, {:tcp_closed, tcp_closed_handle})
    assert await(tcp_closed_socket.closed) == :closed
    assert_stopped(tcp_closed_socket)

    ssl_error_handle = {:fake_ssl, make_ref()}

    ssl_error_socket =
      Web.connect("localhost:0",
        secureTransport: "on",
        ssl_connect_fun: fn _host, _port, _opts, _timeout -> {:ok, ssl_error_handle} end
      )

    assert_opened_remote(ssl_error_socket, "localhost:0")
    send(ssl_error_socket.address, {:ssl_error, ssl_error_handle, :closed})
    assert catch_exit(await(ssl_error_socket.closed)) == {:transport_error, :closed}
    assert_stopped(ssl_error_socket)

    ssl_closed_handle = {:fake_ssl, make_ref()}

    ssl_closed_socket =
      Web.connect("localhost:0",
        secureTransport: "on",
        ssl_connect_fun: fn _host, _port, _opts, _timeout -> {:ok, ssl_closed_handle} end
      )

    assert_opened_remote(ssl_closed_socket, "localhost:0")
    send(ssl_closed_socket.address, {:ssl_closed, ssl_closed_handle})
    assert await(ssl_closed_socket.closed) == :closed
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

    assert :closed = await(Socket.close(socket))
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
    assert :closed = await(Socket.close(socket))
  end

  test "Socket.start_socket/2 uses default options" do
    {port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)
    socket = Socket.start_socket(self(), "localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")
    assert :closed = await(Socket.close(socket))
  end

  test "starttls connection failures reject opened and closed" do
    socket =
      Web.connect("localhost:25",
        secureTransport: "starttls",
        connect_fun: fn _host, _port, _opts, _timeout -> {:error, :starttls_timeout} end
      )

    assert :starttls_timeout = catch_exit(await(socket.opened))
    assert catch_exit(await(socket.closed)) == :starttls_timeout
  end

  test "a write that the transport refuses rejects, and the socket closes with the error" do
    # A socket of Erlang/OTP that is closed: each send gives an error.
    {:ok, closed} = :gen_tcp.listen(0, [:binary])
    :ok = :gen_tcp.close(closed)

    socket =
      Web.connect("localhost:0",
        connect_fun: fn _host, _port, _opts, _timeout -> {:ok, closed} end
      )

    assert_opened_remote(socket, "localhost:0")
    writer = Web.WritableStream.get_writer(socket.writable)

    reason = catch_exit(await(WritableStreamDefaultWriter.write(writer, "data")))
    assert reason in [:closed, :einval]
    assert catch_exit(await(socket.closed)) == {:transport_error, reason}
    assert catch_exit(await(WritableStreamDefaultWriter.write(writer, "late"))) == reason
    assert_stopped(socket)
  end

  test "a close of the writer waits for the connection, then closes the socket" do
    gate = make_ref()
    socket = Web.connect("localhost:0", connect_fun: blocking_connect(self(), gate))
    assert_receive {:connect_blocked, ^gate}, 1_000

    writer = Web.WritableStream.get_writer(socket.writable)
    close = WritableStreamDefaultWriter.close(writer)

    # The close has no time limit: it waits for the connection.
    assert Web.Promise.wait(Web.Promise.race([close, timeout_promise(100)])) ==
             {:fulfilled, :still_pending}

    send(socket.address, {gate, {:ok, {:fake_tcp, make_ref()}}})

    assert :ok = await(close)
    assert await(socket.closed) == :closed
    assert_stopped(socket)
  end

  test "a close of the writer rejects when the connection fails" do
    gate = make_ref()
    socket = Web.connect("localhost:0", connect_fun: blocking_connect(self(), gate))
    assert_receive {:connect_blocked, ^gate}, 1_000

    writer = Web.WritableStream.get_writer(socket.writable)
    close = WritableStreamDefaultWriter.close(writer)
    send(socket.address, {gate, {:error, :connect_timeout}})

    assert :connect_timeout = catch_exit(await(socket.opened))
    assert catch_exit(await(socket.closed)) == :connect_timeout
    assert catch_exit(await(close)) == :connect_timeout
    assert_stopped(socket)
  end

  test "an abort of the writer closes the socket" do
    {port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)
    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")

    writer = Web.WritableStream.get_writer(socket.writable)
    assert :ok = await(WritableStreamDefaultWriter.abort(writer, :user_abort))
    assert await(socket.closed) == :closed
    assert_stopped(socket)
  end

  test "close ends the two streams, and a second close has no effect" do
    {port, _task} = start_tcp_server(&wait_for_tcp_stop_or_close/1)
    socket = Web.connect("localhost:#{port}")
    assert_opened_remote(socket, "localhost:#{port}")
    writer = Web.WritableStream.get_writer(socket.writable)

    assert :closed = await(Socket.close(socket))
    assert :closed = await(Socket.close(socket))

    assert Enum.to_list(socket.readable) == []
    assert catch_exit(await(WritableStreamDefaultWriter.write(writer, "late"))) == :closed
    assert catch_exit(await(Socket.start_tls(socket))) == :closed
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
    assert :closed = await(Socket.close(socket))
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
    assert %{remoteAddress: remote_address} = await(socket.opened)
    assert remote_address == expected_remote_address
  end

  defp socket_debug(socket) do
    socket_request(socket, :debug)
  end

  # The server of the socket stopped.
  defp assert_stopped(socket) do
    assert_eventually(fn -> not Process.alive?(socket.address) end)
  end

  defp socket_request(socket, body) do
    GenServer.call(socket.address, {socket.token, body})
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
