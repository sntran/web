defmodule Web.Socket do
  @moduledoc """
  A TCP or TLS socket, as `Socket` of the Sockets API of WinterTC.

  `Web.connect/2` makes a socket:

      socket = Web.connect("example.com:80")
      writer = Web.WritableStream.get_writer(socket.writable)
      Web.await(Web.WritableStreamDefaultWriter.write(writer, "GET / HTTP/1.0\\r\\n\\r\\n"))

      for chunk <- socket.readable do
        IO.write(to_string(chunk))
      end

  ## The fields

    * `readable` - a `Web.ReadableStream` of the bytes from the peer. Each
      chunk is a `Web.Uint8Array`. The socket reads from the network only
      when the stream wants data.
    * `writable` - a `Web.WritableStream` of the bytes to the peer. A chunk
      is a binary, a `Web.Uint8Array`, a `Web.ArrayBuffer`, or iodata. A
      write is complete when the operating system has the bytes: a slow
      peer makes the writes wait, and does not stop the reads.
    * `opened` - a `Web.Promise` that fulfils with the information of the
      connection, a `SocketInfo` map with the keys `:remote_address`,
      `:local_address`, and `:alpn`. For a TLS socket, it fulfils after the
      handshake. It rejects when the connection fails.
    * `closed` - a `Web.Promise` that fulfils with `nil` when the socket
      closes, as `Promise<undefined>`. It rejects with a `SocketError` when
      the connection fails.

  `upgraded?/1` gives the attribute `upgraded`: it is `true` after
  `start_tls/1`.

  ## The close

  The promise `closed` fulfils at one of these times, as the Sockets API
  specifies:

    * `close/2` closes the socket;
    * the peer closes the connection, and the socket does not have the
      option `allow_half_open: true`. The readable side gets the end of the
      data, and the writable side closes.

  The socket sees the close of the peer when the readable side reads: the
  stream reads while it has space, also with no reader. A readable side that
  is cancelled, or full, does not read.

  A cancel of the readable side and a close of the writable side do not
  close the socket. A close or an abort of the writable side sends the end
  of the data to the peer (a TCP half close), and the readable side
  continues.

  ## Errors

  A `SocketError` is a `Web.TypeError` with a message that starts with
  `"SocketError: "`. Its field `cause` has the reason of Erlang/OTP, for
  example `:econnrefused`. When the connection fails, the promises
  `opened` (if it is pending) and `closed` reject with the `SocketError`,
  the readable side is cancelled with it, and the writable side is aborted
  with it.

  ## Options of `Web.connect/2`

  The members of `SocketOptions`:

    * `:secure_transport` - `"off"` (the default), `"on"` for TLS, or
      `"starttls"` for a connection that becomes TLS with `start_tls/1`.
      Each other value raises `Web.TypeError`;
    * `:allow_half_open` - with `true`, a close of the connection by the
      peer closes only the readable side: the writable side stays open
      until `close/2`. The default is `false`. Erlang/OTP closes a TLS
      connection when the peer closes it, thus the option has an effect
      only for a TCP connection;
    * `:sni` - the Server Name Indication of the TLS handshake. The default
      is the host name of the address. The socket verifies the certificate
      of the server with this name;
    * `:alpn` - the list of the protocols of the Application-Layer Protocol
      Negotiation. The `SocketInfo` of `opened` has the protocol that the
      server selected in `:alpn`, or `nil`.

  The options `:sni` and `:alpn` need a secure transport (`"on"` or
  `"starttls"`): with `"off"`, `Web.connect/2` raises a `SocketError`.

  ## Settings

    * `config :web, tls_options: [...]` - options of the Erlang application
      `:ssl` for each TLS connection. The socket verifies the certificate of
      the server and its host name, unless the options have
      `verify: :verify_none`;
    * `config :web, connect_timeout: ms` - the time to open the connection.

  ## Lifetime

  A socket stays until `close/2`, until the peer closes (with no option
  `allow_half_open: true`), until the connection fails, or until the process
  that made it stops: the socket then closes as with `close/2`. A
  function on a socket that is closed has no effect. Close a socket when
  the work is complete, or use `Web.using/2`.
  """

  use GenServer, restart: :temporary

  alias Web.ByteLengthQueuingStrategy
  alias Web.Internal.Address
  alias Web.Internal.Bytes
  alias Web.Internal.MessageTarget
  alias Web.Promise
  alias Web.ReadableStream
  alias Web.TypeError
  alias Web.WritableStream

  defstruct [:address, :token, :flags, :opened, :closed, :readable, :writable]

  # The time for the TLS handshake of `start_tls/1`.
  @handshake_timeout 5_000
  @readable_hwm 65_536

  @secure_transports ["off", "on", "starttls"]

  @typedoc "A handle to one socket. The fields `address`, `token`, and `flags` are private."
  @type t :: %__MODULE__{
          address: pid(),
          token: reference(),
          flags: :atomics.atomics_ref(),
          opened: Web.Promise.t(),
          closed: Web.Promise.t(),
          readable: Web.ReadableStream.t(),
          writable: Web.WritableStream.t()
        }

  @doc false
  # Makes a socket for `Web.connect/2`. The options are the options of
  # `Web.connect/2`, and these options of the library, for its tests:
  #
  #   * `:ssl_options` - options of `:ssl`. They come before the setting
  #     `:tls_options`;
  #   * `:tcp_options` - options of `:gen_tcp`;
  #   * `:connect_timeout` - the time to open the connection, in
  #     milliseconds. The default is the setting `:connect_timeout`;
  #   * `:readable_high_water_mark` - the bytes that the readable side
  #     keeps;
  #   * `:writable_high_water_mark` - the chunks that the writable side
  #     keeps;
  #   * `:connect_fun` and `:ssl_connect_fun` - a function in the place of
  #     the connect function of Erlang/OTP.
  @spec start_socket(pid(), String.t() | map() | keyword(), map() | keyword()) :: t()
  def start_socket(holder_pid, address, options \\ %{}) when is_pid(holder_pid) do
    {host, port} = normalize_address!(address)
    options = normalize_options!(options)
    promises = deferred_socket_promises()
    boot_ref = make_ref()

    pid =
      MessageTarget.start_server(
        __MODULE__,
        {holder_pid, host, port, options, promises, self(), boot_ref}
      )

    receive do
      {__MODULE__, ^boot_ref, ^pid, socket} -> socket
    end
  end

  @doc """
  Closes the socket, as `close(reason)`. Returns the promise `closed`.

  The readable side is cancelled with `reason`, and the writable side is
  aborted with `reason`. A promise `opened` that is pending rejects with
  `reason`. The promise `closed` fulfils with `nil`. The default reason is
  `nil`, as `undefined`.

  A second call has no effect.
  """
  @spec close(t(), any()) :: Web.Promise.t()
  def close(%__MODULE__{} = socket, reason \\ nil) do
    _reply = MessageTarget.call(socket, {:close, reason})
    socket.closed
  end

  @doc """
  Returns `true` after `start_tls/1` on this socket, as the attribute
  `upgraded`.
  """
  @spec upgraded?(t()) :: boolean()
  def upgraded?(%__MODULE__{flags: flags}), do: :atomics.get(flags, 1) == 1

  @doc """
  Starts TLS on a socket that was made with `secure_transport: "starttls"`,
  as `startTls()`. Returns the new TLS socket at once.

  The first socket closes, and its connection stays: its promise `closed`
  fulfils with `nil`, its readable side gets the end of the data, its
  writable side closes, and `upgraded?/1` gives `true`. The TLS handshake
  runs on the connection after the call: the promise `opened` of the new
  socket fulfils after the handshake. When the handshake fails, the new
  socket fails with a `SocketError`. The TLS options come from the setting
  `config :web, tls_options: [...]`, and from the options `:sni` and
  `:alpn` of `Web.connect/2`.

  Raises a `SocketError` when the socket is not made with
  `secure_transport: "starttls"`, when it uses TLS already, when it started
  TLS before, and when it is closed.
  """
  @spec start_tls(t()) :: t()
  def start_tls(%__MODULE__{} = socket), do: __start_tls__(socket, [])

  @doc false
  # `start_tls/1` with options of `:ssl`, for the tests of this library. The
  # options come before the setting `:tls_options`.
  @spec __start_tls__(t(), map() | keyword()) :: t()
  def __start_tls__(%__MODULE__{} = socket, options) do
    case MessageTarget.call(socket, {:start_tls, normalize_ssl_options(options)}) do
      %__MODULE__{} = tls_socket -> tls_socket
      {:error, reason} -> raise socket_error(start_tls_message(reason))
    end
  end

  defp start_tls_message(:not_starttls),
    do: "startTls() needs the option secureTransport \"starttls\""

  defp start_tls_message(:already_tls), do: "startTls() cannot start TLS on a TLS socket"
  defp start_tls_message(:upgraded), do: "startTls() can start TLS only one time"
  defp start_tls_message(_closed_or_detached), do: "the socket is closed"

  def start_link(argument), do: GenServer.start_link(__MODULE__, argument)

  @doc false
  def init({holder_pid, host, port, options, promises, boot_pid, boot_ref}) do
    Process.flag(:message_queue_data, :off_heap)
    state = build_state(holder_pid, {host, port}, options, promises)
    send(boot_pid, {__MODULE__, boot_ref, self(), public_socket(state)})
    {:ok, state, {:continue, :connect}}
  end

  @doc false
  def handle_continue(:connect, state) do
    {:noreply, start_connector(state, :connect, nil, fn -> connect_transport(state) end)}
  end

  @doc false
  # A request of the process of a sink waits for the end of a connect: the
  # server answers it after the connect.
  def handle_call({token, request}, from, %{token: token} = state) do
    if waits_for_connect?(request, state) do
      {:noreply, %{state | waiting: state.waiting ++ [{from, {token, request}}]}}
    else
      do_handle_call(request, state)
    end
  end

  # The handle of the socket before `start_tls/1`: the socket is closed.
  def handle_call({token, request}, _from, state) when is_map_key(state.upgraded_tokens, token) do
    case request do
      {:start_tls, _options} -> {:reply, {:error, :upgraded}, state}
      _request -> {:reply, {:error, :closed}, state}
    end
  end

  # The handle does not have the token of the socket: it is not a handle of
  # this socket.
  def handle_call(_request, _from, state), do: {:reply, {:error, :detached}, state}

  @doc false
  def handle_cast({token, request}, %{token: token} = state) do
    do_handle_cast(request, state)
  end

  def handle_cast(_request, state), do: {:noreply, state}

  @doc false
  # The process that made the socket stopped: the socket closes, as with
  # `close/2`.
  def handle_info({:DOWN, holder_monitor, :process, holder_pid, _reason}, state)
      when holder_monitor == state.holder_monitor and holder_pid == state.holder_pid do
    {:stop, :normal, local_close(state, nil)}
  end

  # A pull of the readable stream: see `init_streams/2`.
  def handle_info({:web_stream_pull, ref, stream}, %{readable_pid: stream} = state) do
    {:noreply, listen(%{state | pull: {ref, stream}})}
  end

  def handle_info({:tcp, socket, data}, %{transport: :tcp, socket: socket} = state) do
    {:noreply, handle_transport_data(data, state)}
  end

  def handle_info({:ssl, socket, data}, %{transport: :ssl, socket: socket} = state) do
    {:noreply, handle_transport_data(data, state)}
  end

  def handle_info({:tcp_closed, socket}, %{transport: :tcp, socket: socket} = state) do
    peer_closed(state, state.allow_half_open)
  end

  # Erlang/OTP closes a TLS connection when the peer closes it: the socket
  # cannot stay half open.
  def handle_info({:ssl_closed, socket}, %{transport: :ssl, socket: socket} = state) do
    peer_closed(state, false)
  end

  def handle_info({:tcp_error, socket, reason}, %{transport: :tcp, socket: socket} = state) do
    fail(state, socket_error("connection failed", reason))
  end

  def handle_info({:ssl_error, socket, reason}, %{transport: :ssl, socket: socket} = state) do
    fail(state, socket_error("connection failed", reason))
  end

  # The connector opened the connection, or the TLS handshake is complete:
  # the server owns the socket now.
  def handle_info({__MODULE__, :connected, ref, result}, %{connecting: {ref, _pid, kind}} = state) do
    state = %{state | connecting: nil}

    case result do
      {:ok, socket, transport} ->
        next_state =
          %{state | socket: socket, transport: transport}
          |> settle_opened_info()
          |> listen()
          |> answer_waiting()

        {:noreply, next_state}

      {:error, reason} ->
        fail(state, socket_error(failure_message(kind), reason))
    end
  end

  # The connector stopped with no result: a different process killed it.
  def handle_info({:EXIT, pid, reason}, %{connecting: {_ref, pid, kind}} = state)
      when reason != :normal do
    fail(%{state | connecting: nil}, socket_error(failure_message(kind), reason))
  end

  # One of the two streams stopped with a failure: the connection cannot
  # continue.
  def handle_info({:EXIT, pid, reason}, %{readable_pid: readable, writable_pid: writable} = state)
      when pid in [readable, writable] and reason != :normal do
    error = socket_error("connection failed", {:stream_down, reason})
    {:stop, :normal, next_state} = fail(state, error)
    {:stop, {:shutdown, {:stream_down, reason}}, next_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  # Each path to the end settles the promises before it stops. A stop for a
  # different cause, for example the stop of the application, rejects the
  # promises that are pending.
  def terminate(reason, state) do
    clear_monitor(state.holder_monitor)
    error = socket_error("connection failed", reason)

    state
    |> stop_connector()
    |> refuse_waiting()
    |> close_transport()
    |> settle_opened({:error, error})
    |> settle_closed({:error, error})

    :ok
  end

  defp build_state(holder_pid, {host, port}, options, promises) do
    authority = init_authority()
    {readable, writable} = init_streams(authority, options, promises.closed)

    # The streams are parts of the socket. If the socket stops with a
    # failure, the streams stop. If one of the streams stops with a failure,
    # the socket settles its promises and stops: see the EXIT message.
    Process.flag(:trap_exit, true)
    Process.link(readable.controller_pid)
    Process.link(writable.controller_pid)

    holder_pid
    |> init_connection_state(host, port, options)
    |> Map.merge(authority)
    |> Map.merge(init_stream_state(readable, writable))
    |> Map.merge(init_promises(promises))
  end

  # The handle of one socket: a new socket of `start_tls/1` has a new
  # handle. The flag of `upgraded?/1` is in an `:atomics` array: a struct
  # cannot change, and the flag stays after the server stops.
  defp init_authority do
    %{address: self(), token: make_ref(), flags: :atomics.new(1, signed: false)}
  end

  defp init_connection_state(holder_pid, host, port, options) do
    %{
      holder_pid: holder_pid,
      holder_monitor: Process.monitor(holder_pid),
      host: host,
      endpoint: Address.endpoint(host),
      port: port,
      options: options,
      secure_transport: options.secure_transport,
      allow_half_open: options.allow_half_open,
      transport: :tcp,
      socket: nil,
      active: false,
      pull: nil,
      reading?: true,
      writing?: true,
      upgraded_tokens: %{},
      connecting: nil,
      waiting: []
    }
  end

  # The readable stream sends each pull to the server directly, with no
  # callback in a worker: the server then asks its socket for one message.
  # The pull is complete when the server enqueued the chunk of that
  # message, thus the stream has one pull at a time, as the Streams Standard
  # specifies.
  defp init_streams(%{address: address, token: token} = handle, options, closed) do
    readable_hwm = Map.get(options, :readable_high_water_mark, @readable_hwm)

    readable =
      ReadableStream.__new__(
        %{cancel: fn _reason -> GenServer.cast(address, {token, :readable_cancel}) end},
        [
          high_water_mark: readable_hwm,
          strategy: ByteLengthQueuingStrategy.new(high_water_mark: readable_hwm),
          cancel_on_reader_exit: true
        ],
        direct_pull: {:process, address}
      )

    writable =
      WritableStream.new(
        %{
          write: fn chunk, _controller -> sink_write(handle, chunk, closed) end,
          close: fn _controller -> sink_close(handle, closed) end,
          abort: fn _reason -> sink_abort(handle) end
        },
        high_water_mark: Map.get(options, :writable_high_water_mark, 1)
      )

    {readable, writable}
  end

  defp init_stream_state(readable, writable) do
    %{
      readable: readable,
      readable_pid: readable.controller_pid,
      writable: writable,
      writable_pid: writable.controller_pid
    }
  end

  defp init_promises(promises) do
    %{
      opened: promises.opened,
      opened_info: promises.opened_info,
      opened_settled?: false,
      closed: promises.closed,
      closed_info: promises.closed_info,
      closed_settled?: false
    }
  end

  # A request for the tests of this library: the state of the transport.
  defp do_handle_call(:debug, state) do
    {:reply, debug_info(state), state}
  end

  defp do_handle_call({:close, reason}, state) do
    {:stop, :normal, :ok, local_close(state, reason)}
  end

  # A close or an abort of the writable side: the socket sends the end of
  # its data to the peer, and the readable side continues.
  defp do_handle_call(:sink_close, state) do
    {:reply, :ok, shut_write(state)}
  end

  # The process of the sink sends the bytes: see `sink_write/2`. The server
  # handles this request after the connection is open.
  defp do_handle_call(:transport, state) do
    {:reply, {:ok, state.transport, state.socket}, state}
  end

  defp do_handle_call({:start_tls, options}, state) do
    cond do
      state.secure_transport != "starttls" ->
        {:reply, {:error, :not_starttls}, state}

      state.transport != :tcp ->
        {:reply, {:error, :already_tls}, state}

      true ->
        tcp_socket = state.socket
        next_state = %{upgrade_generation(state) | socket: nil}

        # The connector owns the TCP socket during the handshake, and then
        # gives the TLS socket to the server.
        connecting =
          start_connector(next_state, :handshake, tcp_socket, fn ->
            upgrade_transport(tcp_socket, options, next_state)
          end)

        {:reply, public_socket(connecting), connecting}
    end
  end

  defp do_handle_call(_request, state) do
    {:reply, {:error, :unsupported_operation}, state}
  end

  # A write failed in the process of the sink. The write rejects with its
  # error, thus the writable side has that error already. A chunk that is
  # not bytes is an error of the caller: the writable side ends. Each other
  # error is a failure of the connection.
  defp do_handle_cast({:write_failed, %TypeError{message: "SocketError: " <> _} = error}, state) do
    fail(state, error)
  end

  defp do_handle_cast({:write_failed, %TypeError{}}, state) do
    {:noreply, shut_write(state)}
  end

  # A cancel of the readable side: the socket reads no more data. The
  # socket does not close, as the Sockets API specifies.
  defp do_handle_cast(:readable_cancel, state) do
    {:noreply, stop_reading(state)}
  end

  defp do_handle_cast(_request, state) do
    {:noreply, state}
  end

  # Each chunk of the readable side is a `Web.Uint8Array`. The socket sent
  # one message, and waits: the next pull of the stream asks for the next
  # message. Thus the server does not wait for the stream, and the stream
  # keeps its limit: it pulls only while it has space.
  defp handle_transport_data(data, state) do
    ReadableStream.enqueue(state.readable_pid, Web.Uint8Array.from(data))
    %{complete_pull(state) | active: false}
  end

  # The enqueue and the end of the pull go from this process to the stream,
  # thus the stream gets them in their sequence.
  defp complete_pull(%{pull: {ref, stream}} = state) do
    Web.Stream.__send_info__(stream, {ref, :pulled})
    %{state | pull: nil}
  end

  defp complete_pull(state), do: state

  # The socket gives one message for a pull of the stream, when the
  # connection is open.
  defp listen(%{pull: {_ref, _stream}, active: false, reading?: true, socket: socket} = state)
       when socket != nil do
    _ = transport_set_active_safe(state.transport, socket, :once)
    %{state | active: :once}
  end

  defp listen(state), do: state

  # The connect and the TLS handshake are blocking calls of Erlang/OTP.
  # They run in a linked process, the connector, thus the server always
  # answers, also a `close/2` during a connect. `give` is a socket that the
  # connector uses: the server gives it to the connector first. At the end,
  # the connector gives its socket to the server, and sends the result.
  defp start_connector(state, kind, give, fun) do
    server = self()
    ref = make_ref()

    pid =
      spawn_link(fn ->
        receive do
          {^ref, :go} -> :ok
        end

        result = run_connect(fun)
        hand_over(result, server)
        send(server, {__MODULE__, :connected, ref, result})
      end)

    if give, do: :gen_tcp.controlling_process(give, pid)
    send(pid, {ref, :go})
    %{state | connecting: {ref, pid, kind}}
  end

  # A connect function that raises, for example a function of a test,
  # gives the error of the connect.
  defp run_connect(fun) do
    fun.()
  catch
    kind, reason -> {:error, Exception.normalize(kind, reason, __STACKTRACE__)}
  end

  # A socket of a test can be a term that is not a socket of Erlang/OTP.
  defp hand_over({:ok, socket, transport}, server) do
    transport_controlling_process(transport, socket, server)
  rescue
    _not_a_socket -> :ok
  end

  defp hand_over({:error, _reason}, _server), do: :ok

  defp stop_connector(%{connecting: {_ref, pid, _kind}} = state) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    %{state | connecting: nil}
  end

  defp stop_connector(state), do: state

  defp failure_message(:connect), do: "connection failed"
  defp failure_message(:handshake), do: "TLS handshake failed"

  # The requests of the process of a sink, and `start_tls/1`, need the
  # connection.
  defp waits_for_connect?(_request, %{connecting: nil}), do: false
  defp waits_for_connect?({:start_tls, _options}, _state), do: true
  defp waits_for_connect?(request, _state), do: request in [:transport, :sink_close]

  defp answer_waiting(%{waiting: waiting} = state) do
    Enum.reduce(waiting, %{state | waiting: []}, fn {from, message}, state ->
      {:reply, reply, next_state} = handle_call(message, from, state)
      GenServer.reply(from, reply)
      next_state
    end)
  end

  # The socket stops: the requests that wait get no connection.
  defp refuse_waiting(%{waiting: waiting} = state) do
    Enum.each(waiting, fn {from, _message} -> GenServer.reply(from, {:error, :closed}) end)
    %{state | waiting: []}
  end

  # The peer closed the connection: the readable side gets the end of the
  # data. With `allowHalfOpen: false`, the writable side and the socket
  # close too, and `closed` fulfils.
  defp peer_closed(state, true) do
    {:noreply, end_reading(state)}
  end

  defp peer_closed(state, false) do
    next_state = end_reading(state)
    Web.Stream.terminate(next_state.writable_pid, :close, nil)

    final_state =
      next_state
      |> settle_closed({:ok, nil})
      |> close_transport()

    {:stop, :normal, final_state}
  end

  defp end_reading(state) do
    next_state = state |> complete_pull() |> Map.put(:reading?, false)
    ReadableStream.close(next_state.readable_pid)
    next_state
  end

  defp stop_reading(%{active: :once, socket: socket} = state) when socket != nil do
    _ = transport_set_active_safe(state.transport, socket, false)
    %{state | active: false, reading?: false, pull: nil}
  end

  defp stop_reading(state), do: %{state | reading?: false, pull: nil}

  # The server handles this step only with a connection: a request of the
  # sink waits for the connect. A second shutdown has no effect.
  defp shut_write(state) do
    _ = transport_shutdown_safe(state.transport, state.socket, :write)
    %{state | writing?: false}
  end

  # The steps of `close(reason)`: the readable side is cancelled, and the
  # writable side is aborted, with the reason. A pending `opened` rejects
  # with the reason. Then `closed` fulfils.
  defp local_close(state, reason) do
    ReadableStream.__cancel__(state.readable_pid, reason)
    WritableStream.error(state.writable_pid, reason)

    state
    |> stop_connector()
    |> refuse_waiting()
    |> settle_opened({:error, reason})
    |> settle_closed({:ok, nil})
    |> close_transport()
  end

  # The steps for a connection that fails: `opened` and `closed` reject
  # with the `SocketError`, the readable side is cancelled with it, and the
  # writable side is aborted with it.
  defp fail(state, error) do
    ReadableStream.__cancel__(state.readable_pid, error)
    WritableStream.error(state.writable_pid, error)

    final_state =
      state
      |> stop_connector()
      |> refuse_waiting()
      |> settle_opened({:error, error})
      |> settle_closed({:error, error})
      |> close_transport()

    {:stop, :normal, final_state}
  end

  defp socket_error(message, cause) do
    TypeError.exception(message: "SocketError: " <> message, cause: cause)
  end

  defp socket_error(message), do: TypeError.exception("SocketError: " <> message)

  defp close_transport(%{socket: nil} = state), do: state

  defp close_transport(state) do
    _ = transport_close_safe(state.transport, state.socket)
    %{state | socket: nil, active: false}
  end

  defp settle_opened(%{opened_settled?: false} = state, {:ok, value}) do
    state.opened_info.resolve.(value)
    %{state | opened_settled?: true}
  end

  defp settle_opened(%{opened_settled?: false} = state, {:error, reason}) do
    state.opened_info.reject.(reason)
    %{state | opened_settled?: true}
  end

  defp settle_opened(state, _result), do: state

  defp settle_opened_info(state), do: settle_opened(state, {:ok, socket_info(state)})

  defp settle_closed(%{closed_settled?: false} = state, {:ok, value}) do
    state.closed_info.resolve.(value)
    %{state | closed_settled?: true}
  end

  defp settle_closed(%{closed_settled?: false} = state, {:error, reason}) do
    state.closed_info.reject.(reason)
    %{state | closed_settled?: true}
  end

  defp settle_closed(state, _result), do: state

  # The steps of `startTls()`: the first socket is upgraded and closed, and
  # its connection stays for the new socket. The new socket has new
  # streams, new promises, and a new handle. The handshake comes after the
  # reply.
  defp upgrade_generation(state) do
    :atomics.put(state.flags, 1, 1)
    _ = transport_set_active_safe(:tcp, state.socket, false)

    # The first stream gets the end of its pull, if it has one: it then
    # closes.
    old_state = complete_pull(state)
    ReadableStream.close(old_state.readable_pid)
    Web.Stream.terminate(old_state.writable_pid, :close, nil)
    old_state.closed_info.resolve.(nil)

    authority = init_authority()
    # The promises belong to the holder, as the promises of the first
    # socket: they stay after the server stops.
    promises = Promise.with_owner(state.holder_pid, &deferred_socket_promises/0)
    {readable, writable} = init_streams(authority, state.options, promises.closed)
    Process.link(readable.controller_pid)
    Process.link(writable.controller_pid)

    %{
      old_state
      | address: authority.address,
        token: authority.token,
        flags: authority.flags,
        active: false,
        reading?: true,
        writing?: true,
        upgraded_tokens: Map.put(state.upgraded_tokens, state.token, true)
    }
    |> Map.merge(init_stream_state(readable, writable))
    |> Map.merge(init_promises(promises))
  end

  defp connect_transport(state) do
    timeout = Map.get_lazy(state.options, :connect_timeout, &Web.Application.connect_timeout/0)
    transport_connect(transport_mode(state.secure_transport), state, timeout)
  end

  defp transport_mode("on"), do: :ssl
  defp transport_mode(_off_or_starttls), do: :tcp

  # The options `:connect_fun` and `:ssl_connect_fun` are for the tests of
  # this library: a test gives a function in the place of the connect
  # function of Erlang/OTP.
  defp transport_connect(:tcp, state, timeout) do
    connect_fun = Map.get(state.options, :connect_fun, &:gen_tcp.connect/4)
    options = tcp_connect_options(state.options)

    case connect_fun.(state.endpoint, state.port, options, timeout) do
      {:ok, socket} -> {:ok, socket, :tcp}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transport_connect(:ssl, state, timeout) do
    connect_fun = Map.get(state.options, :ssl_connect_fun, &:ssl.connect/4)

    options = tls_connect_options(state.options.ssl_options, state)

    case connect_fun.(state.endpoint, state.port, options, timeout) do
      {:ok, socket} -> {:ok, socket, :ssl}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upgrade_transport(tcp_socket, options, state) do
    case :ssl.connect(tcp_socket, tls_connect_options(options, state), @handshake_timeout) do
      {:ok, ssl_socket} -> {:ok, ssl_socket, :ssl}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_payload(chunk) do
    case Bytes.to_binary(chunk) do
      {:ok, payload} ->
        {:ok, payload}

      :error ->
        {:error,
         TypeError.exception("Socket writes must be a binary, a Uint8Array, or an ArrayBuffer")}
    end
  end

  defp debug_info(state) do
    %{
      active: state.active,
      transport: state.transport,
      reading?: state.reading?,
      writing?: state.writing?,
      queued_size: queued_size(state),
      desired_size: ReadableStream.get_desired_size(state.readable_pid)
    }
  end

  defp queued_size(state) do
    state.readable_pid
    |> ReadableStream.__get_slots__()
    |> Map.get(:total_queued_size)
  end

  # The `SocketInfo` of the connection.
  defp socket_info(state) do
    %{
      remote_address: Address.format(state.host, state.port),
      local_address: local_address(state.transport, state.socket),
      alpn: negotiated_protocol(state.transport, state.socket)
    }
  end

  # The members of `SocketInfo` that the socket cannot get are `nil`, as
  # `null`.
  defp local_address(transport, socket) do
    case transport_sockname(transport, socket) do
      {:ok, {ip, port}} -> Address.format(to_string(:inet.ntoa(ip)), port)
      _other -> nil
    end
  rescue
    _not_a_socket -> nil
  end

  defp transport_sockname(:tcp, socket), do: :inet.sockname(socket)
  defp transport_sockname(:ssl, socket), do: :ssl.sockname(socket)

  defp negotiated_protocol(:ssl, socket) do
    case :ssl.negotiated_protocol(socket) do
      {:ok, protocol} -> protocol
      {:error, _not_negotiated} -> nil
    end
  rescue
    _not_a_socket -> nil
  end

  defp negotiated_protocol(:tcp, _socket), do: nil

  # A message of the socket has 64 KiB at most. The default buffer of
  # `:gen_tcp` gives messages of approximately 9 KiB, and each message costs
  # messages between the server and the stream: a read of 64 MiB gave
  # 426 MiB/s with the default, and 1466 MiB/s with this buffer.
  defp tcp_connect_options(options) do
    [:binary, packet: :raw, active: false, buffer: 65_536] ++
      tcp_socket_options(options) ++ options.tcp_options
  end

  # A socket that stays half open writes after the peer closed: the port
  # of `:gen_tcp` must not close at that time.
  defp tcp_socket_options(%{allow_half_open: true}), do: [exit_on_close: false]
  defp tcp_socket_options(_options), do: []

  # The options of a TLS connection. The socket verifies the certificate of
  # the server and its host name, unless the caller gives the option
  # `verify: :verify_none`. The options of the caller come before the
  # setting `:tls_options` of the application. The option `sni` is the
  # name of the handshake and of the verification, and the option `alpn`
  # gives the protocols.
  defp tls_connect_options(options, state) do
    Web.Application.tls_options()
    |> Keyword.merge(options)
    |> Keyword.put_new(:active, false)
    |> Keyword.put_new(:mode, :binary)
    |> Keyword.put_new(:packet, :raw)
    |> Keyword.put_new(:verify, :verify_peer)
    |> Keyword.put_new(:server_name_indication, String.to_charlist(server_name(state)))
    |> put_alpn(state.options.alpn)
    |> add_trust_options()
  end

  defp server_name(%{options: %{sni: sni}}) when is_binary(sni), do: sni
  defp server_name(state), do: Address.hostname(state.host)

  defp put_alpn(options, []), do: options
  defp put_alpn(options, alpn), do: Keyword.put_new(options, :alpn_advertised_protocols, alpn)

  defp add_trust_options(options) do
    if options[:verify] == :verify_peer do
      options
      |> add_trust_store()
      |> Keyword.put_new(:depth, 4)
      |> Keyword.put_new(:customize_hostname_check,
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      )
    else
      options
    end
  end

  # The trust store: the option of the caller or of the application, then
  # the store of the operating system, then the store of the package
  # `castore`.
  defp add_trust_store(options) do
    if Keyword.has_key?(options, :cacertfile) or Keyword.has_key?(options, :cacerts) do
      options
    else
      try do
        Keyword.put(options, :cacerts, :public_key.cacerts_get())
      rescue
        # Only an operating system with no trust store comes here.
        # coveralls-ignore-next-line
        _error -> Keyword.put(options, :cacertfile, CAStore.file_path())
      end
    end
  end

  defp transport_send(:tcp, socket, payload), do: :gen_tcp.send(socket, payload)
  defp transport_send(:ssl, socket, payload), do: :ssl.send(socket, payload)

  defp transport_set_active(:tcp, socket, value), do: :inet.setopts(socket, active: value)
  defp transport_set_active(:ssl, socket, value), do: :ssl.setopts(socket, active: value)

  defp transport_set_active_safe(transport, socket, value) do
    transport_set_active(transport, socket, value)
  rescue
    _error -> {:error, :bad_socket}
  end

  defp transport_shutdown(:tcp, socket, how), do: :gen_tcp.shutdown(socket, how)
  defp transport_shutdown(:ssl, socket, how), do: :ssl.shutdown(socket, how)

  defp transport_shutdown_safe(transport, socket, how) do
    transport_shutdown(transport, socket, how)
  rescue
    _error -> {:error, :bad_socket}
  end

  defp transport_controlling_process(:tcp, socket, pid),
    do: :gen_tcp.controlling_process(socket, pid)

  defp transport_controlling_process(:ssl, socket, pid), do: :ssl.controlling_process(socket, pid)

  defp transport_close(:tcp, socket), do: :gen_tcp.close(socket)
  defp transport_close(:ssl, socket), do: :ssl.close(socket)

  defp transport_close_safe(transport, socket) do
    transport_close(transport, socket)
  rescue
    _error -> :ok
  end

  defp public_socket(state) do
    %__MODULE__{
      address: state.address,
      token: state.token,
      flags: state.flags,
      opened: state.opened,
      closed: state.closed,
      readable: state.readable,
      writable: state.writable
    }
  end

  defp deferred_socket_promises do
    {opened, opened_info} = deferred_promise()
    {closed, closed_info} = deferred_promise()
    %{opened: opened, opened_info: opened_info, closed: closed, closed_info: closed_info}
  end

  defp deferred_promise do
    # The `opened` and `closed` promises are attributes of the socket. A
    # caller can await them at any time, thus they do not expire.
    {promise, resolve, reject} = Promise.__with_resolvers__(linger: :infinity)
    {promise, %{resolve: resolve, reject: reject}}
  end

  # The process of the sink sends the bytes, not the server. Thus a write
  # that waits for a slow peer does not stop the server, which reads the
  # data from the peer.
  defp sink_write(handle, chunk, closed) do
    with {:ok, payload} <- normalize_payload(chunk),
         {:ok, transport, socket} <- transport_of(handle, closed),
         :ok <- transport_send(transport, socket, payload) do
      :ok
    else
      # A chunk that is not bytes is an error of the caller. The write
      # rejects with the `TypeError`, and the writable side ends.
      {:error, %TypeError{} = error} -> fail_write(handle, error)
      # The transport failed, or the socket closed during the write.
      {:error, reason} -> fail_write(handle, socket_error("connection failed", reason))
    end
  end

  # The worker of the sink asks the server for the transport one time: the
  # transport of a writable stream does not change. A TLS upgrade makes a
  # new writable stream, with a new worker. When the socket stopped, the
  # error is the error of the failure, or the error of a closed socket.
  defp transport_of(handle, closed) do
    key = {__MODULE__, :transport, handle.token}

    case Process.get(key) do
      nil ->
        case MessageTarget.call(handle, :transport) do
          {:ok, _transport, _socket} = found ->
            Process.put(key, found)
            found

          {:error, _stopped} ->
            {:error, closed_error(closed)}
        end

      found ->
        found
    end
  end

  defp closed_error(closed) do
    case Promise.peek(closed) do
      {:rejected, %TypeError{} = error} -> error
      _closed -> socket_error("the socket is closed")
    end
  end

  # The write rejects with the error, and the server gets the notice with
  # no wait.
  defp fail_write(handle, error) do
    GenServer.cast(handle.address, {handle.token, {:write_failed, error}})
    Promise.reject(error)
  end

  # A close of the writable side sends the end of the data. The socket can
  # stop with a failure before it gets the close, for example when the
  # connection fails: the close then rejects with that failure, which is
  # the rejection of the promise `closed`. An error of the stream during the
  # close does not change the result of the close, as the Streams Standard
  # specifies.
  defp sink_close(handle, closed) do
    with {:error, _stopped} <- MessageTarget.call(handle, :sink_close),
         {:rejected, reason} <- Promise.peek(closed) do
      Promise.reject(reason)
    else
      _closed -> :ok
    end
  end

  # An abort of the writable side sends the end of the data too.
  defp sink_abort(handle) do
    _reply = MessageTarget.call(handle, :sink_close)
    :ok
  end

  defp clear_monitor(monitor_ref) when is_reference(monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
    :ok
  end

  # An IPv6 address in the text of an address has brackets, as in a URL:
  # `"[::1]:8080"`.
  defp normalize_address!(address) when is_binary(address) do
    with {host, port_text} when host != "" and port_text != "" <- split_address(address),
         {port, ""} when port in 0..65_535 <- Integer.parse(port_text) do
      {host, port}
    else
      _invalid -> raise socket_error("invalid address")
    end
  end

  defp normalize_address!(address) when is_list(address) do
    if Keyword.keyword?(address) do
      address
      |> Enum.into(%{})
      |> normalize_address!()
    else
      raise socket_error("invalid address")
    end
  end

  defp normalize_address!(%{} = address) do
    host =
      Map.get(address, :hostname) ||
        Map.get(address, "hostname")

    port = Map.get(address, :port) || Map.get(address, "port")

    if is_binary(host) and is_integer(port) and port in 0..65_535 do
      {host, port}
    else
      raise socket_error("invalid address")
    end
  end

  defp normalize_address!(_address) do
    raise socket_error("invalid address")
  end

  defp split_address("[" <> rest) do
    case String.split(rest, "]:", parts: 2) do
      [host, port_text] -> {"[" <> host <> "]", port_text}
      _other -> :error
    end
  end

  defp split_address(address) do
    case String.split(address, ":", parts: 2) do
      [host, port_text] -> {host, port_text}
      _other -> :error
    end
  end

  # The conversion of the dictionary `SocketOptions` of Web IDL, and of the
  # options of the library for its tests.
  defp normalize_options!(options) when is_list(options),
    do: options |> Enum.into(%{}) |> normalize_options!()

  defp normalize_options!(options) when is_map(options) do
    secure_transport = secure_transport!(Map.get(options, :secure_transport))
    sni = sni!(Map.get(options, :sni))
    alpn = alpn!(Map.get(options, :alpn, []))

    if secure_transport == "off" and (sni != nil or alpn != []) do
      raise socket_error("the options sni and alpn need a secure transport")
    end

    options
    |> Map.merge(%{
      secure_transport: secure_transport,
      allow_half_open: Map.get(options, :allow_half_open) == true,
      sni: sni,
      alpn: alpn
    })
    |> Map.update(:tcp_options, [], &normalize_list_options/1)
    |> Map.update(:ssl_options, [], &normalize_ssl_options/1)
  end

  defp normalize_options!(_options) do
    raise socket_error("invalid options")
  end

  # The enumeration `SecureTransportKind`: Web IDL refuses each other
  # value.
  defp secure_transport!(nil), do: "off"
  defp secure_transport!(kind) when kind in @secure_transports, do: kind

  defp secure_transport!(kind) do
    raise socket_error("invalid secureTransport #{inspect(kind)}")
  end

  defp sni!(nil), do: nil
  defp sni!(sni) when is_binary(sni) or is_atom(sni), do: to_string(sni)
  defp sni!(sni), do: raise(socket_error("invalid sni #{inspect(sni)}"))

  defp alpn!(nil), do: []

  defp alpn!(alpn) when is_list(alpn) do
    Enum.map(alpn, fn
      protocol when is_binary(protocol) or is_atom(protocol) -> to_string(protocol)
      protocol -> raise socket_error("invalid alpn protocol #{inspect(protocol)}")
    end)
  end

  defp alpn!(alpn), do: raise(socket_error("invalid alpn #{inspect(alpn)}"))

  defp normalize_ssl_options(options) when is_map(options), do: Map.to_list(options)
  defp normalize_ssl_options(options) when is_list(options), do: options
  defp normalize_ssl_options(_options), do: []

  defp normalize_list_options(options) when is_list(options), do: options
  defp normalize_list_options(nil), do: []
  defp normalize_list_options(option), do: [option]
end
