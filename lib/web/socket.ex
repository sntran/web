defmodule Web.Socket do
  @moduledoc """
  A TCP or TLS socket, as `Socket` of the Sockets API of WinterTC.

  `Web.connect/2` makes a socket:

      socket = Web.connect("example.com:80")
      writer = Web.WritableStream.get_writer(socket.writable)
      Web.await(Web.WritableStreamDefaultWriter.write(writer, "GET / HTTP/1.0\r\n\r\n"))

      for chunk <- socket.readable do
        IO.write(Web.Uint8Array.to_binary(chunk))
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
      connection, or rejects when the connection fails.
    * `closed` - a `Web.Promise` that fulfils when the socket closes, with
      the cause: `:closed`, `:upgraded`, or `{:readable_cancel, reason}`. It
      rejects with the error when the socket fails.
    * `upgraded` - a `Web.Promise` that fulfils with the TLS socket after
      `start_tls/2`.

  ## Options of `Web.connect/2`

    * `:secure_transport` - `"off"` (the default), `"on"` for TLS, or
      `"starttls"` for a connection that becomes TLS with `start_tls/2`;
    * `:ssl_options` - options of the Erlang application `:ssl`. The socket
      verifies the certificate of the server and its host name, unless the
      options have `verify: :verify_none`;
    * `:tcp_options` - options of `:gen_tcp`;
    * `:connect_timeout` - the time to open the connection, in
      milliseconds;
    * `:readable_high_water_mark` - the bytes that the readable side keeps.

  ## Lifetime

  A socket stays until `close/2`, until the peer closes, or until the
  process that made it stops. A function on a socket that is closed has no
  effect. Close a socket when the work is complete, or use `Web.using/2`.
  """

  use GenServer, restart: :temporary

  alias Web.ByteLengthQueuingStrategy
  alias Web.Internal.Bytes
  alias Web.Internal.MessageTarget
  alias Web.Promise
  alias Web.ReadableStream
  alias Web.TypeError
  alias Web.WritableStream

  defstruct [:address, :token, :opened, :closed, :upgraded, :readable, :writable]

  # The time for the TLS handshake of `start_tls/2`.
  @handshake_timeout 5_000
  @readable_hwm 65_536

  @typedoc "A handle to one socket. The fields `address` and `token` are private."
  @type t :: %__MODULE__{
          address: pid(),
          token: reference(),
          opened: Web.Promise.t(),
          closed: Web.Promise.t(),
          upgraded: Web.Promise.t(),
          readable: Web.ReadableStream.t(),
          writable: Web.WritableStream.t()
        }

  @doc false
  @spec start_socket(pid(), String.t() | map() | keyword(), map() | keyword()) :: t()
  def start_socket(holder_pid, address, options \\ %{}) when is_pid(holder_pid) do
    {host, port} = normalize_address!(address)
    options = normalize_options(options)
    {opened, opened_info} = deferred_promise()
    {closed, closed_info} = deferred_promise()
    {upgraded, upgraded_info} = deferred_promise()
    boot_ref = make_ref()

    pid =
      MessageTarget.start_server(
        __MODULE__,
        {holder_pid, host, port, options, opened, opened_info, closed, closed_info, upgraded,
         upgraded_info, self(), boot_ref}
      )

    receive do
      {__MODULE__, ^boot_ref, ^pid, socket} -> socket
    end
  end

  @doc """
  Closes the socket and its two streams. Returns the promise `closed`.

  A second call has no effect.
  """
  @spec close(t(), any()) :: Web.Promise.t()
  def close(%__MODULE__{} = socket, reason \\ :closed) do
    _reply = MessageTarget.call(socket, {:close, reason})
    socket.closed
  end

  @doc """
  Starts TLS on a socket that was made with `secure_transport: "starttls"`.

  Returns a promise of the TLS socket. The first socket closes: its promise
  `closed` fulfils with `:upgraded`, and its streams end. `options` are
  options of the Erlang application `:ssl`.

  The promise rejects with `:not_starttls`, `:already_tls`, or
  `:not_connected` when the socket cannot start TLS, and with `:closed` when
  the socket is closed. It rejects with `{:tls_upgrade_failed, reason}`
  when the handshake fails: the socket then closes.
  """
  @spec start_tls(t(), map() | keyword()) :: Web.Promise.t()
  def start_tls(%__MODULE__{} = socket, options \\ %{}) do
    promises = deferred_socket_promises()
    request = {:start_tls, normalize_ssl_options(options), promises}

    Promise.detached(fn resolve, reject ->
      case MessageTarget.call(socket, request) do
        {:error, :detached} -> reject.(:closed)
        {:error, reason} -> reject.(reason)
        tls_socket -> resolve.(tls_socket)
      end
    end)
  end

  def start_link(argument), do: GenServer.start_link(__MODULE__, argument)

  @doc false
  def init(
        {holder_pid, host, port, options, opened, opened_info, closed, closed_info, upgraded,
         upgraded_info, boot_pid, boot_ref}
      ) do
    Process.flag(:message_queue_data, :off_heap)

    state =
      build_state(
        holder_pid,
        {host, port},
        options,
        init_promises(
          {opened, opened_info},
          {closed, closed_info},
          {upgraded, upgraded_info}
        )
      )

    send(boot_pid, {__MODULE__, boot_ref, self(), public_socket(state)})
    {:ok, state, {:continue, :connect}}
  end

  @doc false
  def handle_continue(:connect, state) do
    case connect_transport(state) do
      {:ok, socket, transport} ->
        next_state =
          state
          |> Map.put(:socket, socket)
          |> Map.put(:transport, transport)
          |> settle_opened({:ok, socket_info(state)})
          |> maybe_resume_transport()

        {:noreply, next_state}

      {:error, reason} ->
        next_state = shutdown_state(state, reason, :startup_error)
        {:stop, :normal, next_state}
    end
  end

  @doc false
  def handle_call({token, request}, _from, %{token: token} = state) do
    do_handle_call(request, state)
  end

  # The handle does not have the token of the socket: it is the handle of a
  # socket that started TLS, or it is not a handle of this socket.
  def handle_call(_request, _from, state), do: {:reply, {:error, :detached}, state}

  @doc false
  def handle_cast({token, request}, %{token: token} = state) do
    do_handle_cast(request, state)
  end

  def handle_cast(_request, state), do: {:noreply, state}

  @doc false
  def handle_info({:DOWN, holder_monitor, :process, holder_pid, reason}, state)
      when holder_monitor == state.holder_monitor and holder_pid == state.holder_pid do
    next_state = shutdown_state(state, {:holder_down, reason}, :holder_down)
    {:stop, :normal, next_state}
  end

  def handle_info({:tcp, socket, data}, %{transport: :tcp, socket: socket} = state) do
    {:noreply, handle_transport_data(data, state)}
  end

  def handle_info({:ssl, socket, data}, %{transport: :ssl, socket: socket} = state) do
    {:noreply, handle_transport_data(data, state)}
  end

  def handle_info({:tcp_closed, socket}, %{transport: :tcp, socket: socket} = state) do
    next_state = shutdown_state(state, :closed, :transport_closed)
    {:stop, :normal, next_state}
  end

  def handle_info({:ssl_closed, socket}, %{transport: :ssl, socket: socket} = state) do
    next_state = shutdown_state(state, :closed, :transport_closed)
    {:stop, :normal, next_state}
  end

  def handle_info({:tcp_error, socket, reason}, %{transport: :tcp, socket: socket} = state) do
    next_state = shutdown_state(state, {:transport_error, reason}, :transport_error)
    {:stop, :normal, next_state}
  end

  def handle_info({:ssl_error, socket, reason}, %{transport: :ssl, socket: socket} = state) do
    next_state = shutdown_state(state, {:transport_error, reason}, :transport_error)
    {:stop, :normal, next_state}
  end

  # One of the two streams stopped with a failure. A process that waits for
  # `closed` or `opened` gets the reason.
  def handle_info({:EXIT, pid, reason}, %{readable_pid: readable, writable_pid: writable} = state)
      when pid in [readable, writable] and reason != :normal do
    next_state = shutdown_state(state, {:stream_down, reason}, :stream_down)
    {:stop, {:shutdown, {:stream_down, reason}}, next_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def terminate(_reason, state) do
    clear_monitor(state.holder_monitor)

    state
    |> close_transport_if_needed()
    |> settle_opened_if_needed({:error, state.close_reason || :closed})
    |> settle_closed_if_needed(state.close_reason || :closed)
    |> settle_upgraded_if_needed({:error, state.close_reason || :closed})

    :ok
  end

  defp build_state(holder_pid, {host, port}, options, promises) do
    authority = init_authority()
    {readable, writable} = init_streams(authority, options)

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
    |> Map.merge(promises)
  end

  defp init_authority do
    %{address: self(), token: make_ref()}
  end

  defp init_connection_state(holder_pid, host, port, options) do
    %{
      holder_pid: holder_pid,
      holder_monitor: Process.monitor(holder_pid),
      host: host,
      endpoint: String.to_charlist(host),
      port: port,
      options: options,
      secure_transport: Map.get(options, :secure_transport, "off"),
      transport: :tcp,
      socket: nil,
      active: false,
      close_reason: nil,
      failed?: false
    }
  end

  defp init_streams(%{address: address, token: token} = handle, options) do
    readable_hwm = Map.get(options, :readable_high_water_mark, @readable_hwm)

    readable =
      ReadableStream.new(
        %{
          pull: fn _controller -> GenServer.cast(address, {token, :readable_pull}) end,
          cancel: fn reason -> GenServer.cast(address, {token, {:readable_cancel, reason}}) end
        },
        high_water_mark: readable_hwm,
        strategy: ByteLengthQueuingStrategy.new(readable_hwm),
        cancel_on_reader_exit: true
      )

    writable =
      WritableStream.new(%{
        high_water_mark: Map.get(options, :writable_high_water_mark, 1),
        write: fn chunk, _controller -> sink_write(handle, chunk) end,
        close: fn _controller -> sink_close(handle) end,
        abort: fn _reason -> sink_close(handle) end
      })

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

  defp init_promises({opened, opened_info}, {closed, closed_info}, {upgraded, upgraded_info}) do
    %{
      opened: opened,
      opened_info: opened_info,
      opened_settled?: false,
      closed: closed,
      closed_info: closed_info,
      closed_settled?: false,
      upgraded: upgraded,
      upgraded_info: upgraded_info,
      upgraded_settled?: false
    }
  end

  defp do_handle_call(:debug, state) do
    {:reply, debug_info(state), state}
  end

  defp do_handle_call({:close, reason}, state) do
    next_state = shutdown_state(state, reason, :local_close)
    {:stop, :normal, :ok, next_state}
  end

  # A close of the writable side closes the socket. The writable side is
  # closing already, thus the socket does not give it an error.
  defp do_handle_call(:sink_close, state) do
    next_state = shutdown_state(state, :closed, :sink_close)
    {:stop, :normal, :ok, next_state}
  end

  # The process of the sink sends the bytes: see `sink_write/2`.
  defp do_handle_call(:transport, state) do
    case ensure_connected(state) do
      :ok -> {:reply, {:ok, state.transport, state.socket}, state}
      error -> {:reply, error, state}
    end
  end

  defp do_handle_call({:write_failed, reason}, state) do
    next_state = shutdown_state(state, reason, :write_error)
    {:stop, :normal, :ok, next_state}
  end

  defp do_handle_call({:start_tls, options, promises}, state) do
    with :ok <- ensure_connected(state),
         :ok <- ensure_starttls(state),
         :ok <- ensure_tcp(state),
         :ok <- ensure_ssl_started(state.options),
         {:ok, ssl_socket} <- upgrade_transport(state, options) do
      {next_state, tls_socket} = upgrade_generation(state, ssl_socket, promises)
      {:reply, tls_socket, next_state}
    else
      {:error, :already_tls} = error ->
        {:reply, error, state}

      {:error, :not_starttls} = error ->
        {:reply, error, state}

      {:error, :not_connected} = error ->
        {:reply, error, state}

      {:error, reason} ->
        tls_reason = {:tls_upgrade_failed, reason}
        next_state = shutdown_state(state, tls_reason, :transport_error)
        {:stop, :normal, {:error, tls_reason}, next_state}
    end
  end

  defp do_handle_call(_request, state) do
    {:reply, {:error, :unsupported_operation}, state}
  end

  defp do_handle_cast(:readable_pull, state) do
    {:noreply, maybe_resume_transport(state)}
  end

  defp do_handle_cast({:readable_cancel, reason}, state) do
    next_state = shutdown_state(state, {:readable_cancel, reason}, :readable_cancel)
    {:stop, :normal, next_state}
  end

  defp do_handle_cast(_request, state) do
    {:noreply, state}
  end

  # Each chunk of the readable side is a `Web.Uint8Array`.
  defp handle_transport_data(data, state) do
    ReadableStream.enqueue(state.readable_pid, Web.Uint8Array.from(data))
    maybe_resume_transport(state)
  end

  defp maybe_resume_transport(%{socket: nil} = state), do: state

  defp maybe_resume_transport(state) do
    case ReadableStream.get_desired_size(state.readable_pid) do
      desired when is_integer(desired) and desired > 0 ->
        _ = transport_set_active_safe(state.transport, state.socket, :once)
        %{state | active: :once}

      _ ->
        _ = transport_set_active_safe(state.transport, state.socket, false)
        %{state | active: false}
    end
  end

  # The modes of a close that is not a failure. For each other mode, the
  # promise `closed` rejects, as the Sockets API specifies.
  @graceful [:local_close, :sink_close, :transport_closed, :readable_cancel]

  defp shutdown_state(state, reason, mode) do
    state
    |> Map.put(:close_reason, reason)
    |> Map.put(:failed?, mode not in @graceful)
    |> settle_opened_if_needed({:error, reason})
    |> settle_closed_if_needed(reason)
    |> settle_upgraded_if_needed({:error, reason})
    |> notify_streams(reason, mode)
    |> close_transport_if_needed()
  end

  # `close/2` ends the two streams.
  defp notify_streams(state, _reason, :local_close) do
    ReadableStream.close(state.readable_pid)
    WritableStream.error(state.writable_pid, :closed)
    state
  end

  defp notify_streams(state, _reason, :sink_close) do
    ReadableStream.close(state.readable_pid)
    state
  end

  defp notify_streams(state, _reason, :transport_closed) do
    ReadableStream.close(state.readable_pid)
    WritableStream.error(state.writable_pid, :closed)
    state
  end

  defp notify_streams(state, reason, :write_error) do
    ReadableStream.close(state.readable_pid)
    WritableStream.error(state.writable_pid, reason)
    state
  end

  defp notify_streams(state, reason, _mode) do
    ReadableStream.error(state.readable_pid, reason)
    WritableStream.error(state.writable_pid, reason)
    state
  end

  defp close_transport_if_needed(%{socket: nil} = state), do: state

  defp close_transport_if_needed(state) do
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

  defp settle_opened_if_needed(state, result), do: settle_opened(state, result)

  defp settle_closed_if_needed(%{closed_settled?: false, failed?: true} = state, reason) do
    state.closed_info.reject.(reason)
    %{state | closed_settled?: true}
  end

  defp settle_closed_if_needed(%{closed_settled?: false} = state, reason) do
    state.closed_info.resolve.(reason)
    %{state | closed_settled?: true}
  end

  defp settle_closed_if_needed(state, _reason), do: state

  defp settle_upgraded(%{upgraded_settled?: false} = state, {:ok, value}) do
    state.upgraded_info.resolve.(value)
    %{state | upgraded_settled?: true}
  end

  defp settle_upgraded(%{upgraded_settled?: false} = state, {:error, reason}) do
    state.upgraded_info.reject.(reason)
    %{state | upgraded_settled?: true}
  end

  defp settle_upgraded(state, _result), do: state

  defp settle_upgraded_if_needed(state, result), do: settle_upgraded(state, result)

  defp upgrade_generation(state, ssl_socket, promises) do
    old_readable_pid = state.readable_pid
    old_writable_pid = state.writable_pid

    authority = init_authority()
    {readable, writable} = init_streams(authority, state.options)

    next_state =
      %{
        state
        | address: authority.address,
          token: authority.token,
          transport: :ssl,
          socket: ssl_socket,
          active: false,
          readable: readable,
          readable_pid: readable.controller_pid,
          writable: writable,
          writable_pid: writable.controller_pid,
          opened: promises.opened,
          opened_info: promises.opened_info,
          opened_settled?: false,
          closed: promises.closed,
          closed_info: promises.closed_info,
          closed_settled?: false,
          upgraded: promises.upgraded,
          upgraded_info: promises.upgraded_info,
          upgraded_settled?: false,
          close_reason: nil
      }
      |> settle_opened({:ok, socket_info(state)})

    tls_socket = public_socket(next_state)

    next_state =
      next_state
      |> settle_upgraded({:ok, tls_socket})
      |> maybe_resume_transport()

    ReadableStream.close(old_readable_pid)
    WritableStream.error(old_writable_pid, :upgraded)
    state.closed_info.resolve.(:upgraded)
    state.upgraded_info.resolve.(tls_socket)

    {next_state, tls_socket}
  end

  defp connect_transport(state) do
    timeout = Map.get_lazy(state.options, :connect_timeout, &Web.Application.connect_timeout/0)

    with {:ok, transport} <- transport_mode(state.secure_transport) do
      transport_connect(transport, state, timeout)
    end
  end

  defp transport_mode("off"), do: {:ok, :tcp}

  defp transport_mode("starttls"), do: {:ok, :starttls}

  defp transport_mode("on"), do: {:ok, :ssl}

  defp transport_mode(other), do: {:error, {:unsupported_secure_transport, other}}

  defp transport_connect(:tcp, state, timeout) do
    connect_fun = Map.get(state.options, :connect_fun, &:gen_tcp.connect/4)

    case connect_fun.(state.endpoint, state.port, tcp_connect_options(state.options), timeout) do
      {:ok, socket} -> {:ok, socket, :tcp}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transport_connect(:starttls, state, timeout) do
    transport_connect(:tcp, state, timeout)
  end

  defp transport_connect(:ssl, state, timeout) do
    with :ok <- ensure_ssl_started(state.options) do
      connect_fun = Map.get(state.options, :ssl_connect_fun, &:ssl.connect/4)

      case connect_fun.(
             state.endpoint,
             state.port,
             ssl_connect_options(state.options, state.host),
             timeout
           ) do
        {:ok, socket} -> {:ok, socket, :ssl}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp upgrade_transport(state, options) do
    _ = transport_set_active_safe(:tcp, state.socket, false)

    case :ssl.connect(state.socket, merge_ssl_options(options, state.host), @handshake_timeout) do
      {:ok, ssl_socket} -> {:ok, ssl_socket}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_connected(%{socket: nil}), do: {:error, :not_connected}
  defp ensure_connected(_state), do: :ok

  defp ensure_starttls(%{secure_transport: "starttls"}), do: :ok
  defp ensure_starttls(_state), do: {:error, :not_starttls}

  defp ensure_tcp(%{transport: :tcp}), do: :ok
  defp ensure_tcp(_state), do: {:error, :already_tls}

  defp ensure_ssl_started(options) do
    ssl_start_fun = Map.get(options, :ssl_start_fun, &Application.ensure_all_started/1)

    case ssl_start_fun.(:ssl) do
      {:ok, _apps} -> :ok
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
      queued_size: queued_size(state),
      desired_size: ReadableStream.get_desired_size(state.readable_pid)
    }
  end

  defp queued_size(state) do
    state.readable_pid
    |> ReadableStream.__get_slots__()
    |> Map.get(:total_queued_size)
  end

  defp socket_info(state) do
    %{remoteAddress: "#{state.host}:#{state.port}", localAddress: nil, alpn: nil}
  end

  defp tcp_connect_options(options) do
    [:binary, packet: :raw, active: false] ++
      normalize_list_options(Map.get(options, :tcp_options, []))
  end

  defp ssl_connect_options(options, host) do
    options
    |> Map.get(:ssl_options, [])
    |> normalize_ssl_options()
    |> merge_ssl_options(host)
  end

  # The options of a TLS connection. The socket verifies the certificate of
  # the server and its host name, unless the caller gives the option
  # `verify: :verify_none`. The options of the caller come before the
  # setting `:tls_options` of the application.
  defp merge_ssl_options(options, host) do
    Web.Application.tls_options()
    |> Keyword.merge(options)
    |> Keyword.put_new(:active, false)
    |> Keyword.put_new(:mode, :binary)
    |> Keyword.put_new(:packet, :raw)
    |> Keyword.put_new(:verify, :verify_peer)
    |> Keyword.put_new(:server_name_indication, String.to_charlist(host))
    |> add_trust_options()
  end

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
      opened: state.opened,
      closed: state.closed,
      upgraded: state.upgraded,
      readable: state.readable,
      writable: state.writable
    }
  end

  defp deferred_socket_promises do
    {opened, opened_info} = deferred_promise()
    {closed, closed_info} = deferred_promise()
    {upgraded, upgraded_info} = deferred_promise()

    %{
      opened: opened,
      opened_info: opened_info,
      closed: closed,
      closed_info: closed_info,
      upgraded: upgraded,
      upgraded_info: upgraded_info
    }
  end

  defp deferred_promise do
    # The `opened`, `closed`, and `upgraded` promises are attributes of the
    # socket. A caller can await them at any time, thus they do not expire.
    {promise, resolve, reject} = Promise.with_resolvers(linger: :infinity)
    {promise, %{resolve: resolve, reject: reject}}
  end

  # The process of the sink sends the bytes, not the server. Thus a write
  # that waits for a slow peer does not stop the server, which reads the
  # data from the peer.
  defp sink_write(handle, chunk) do
    with {:ok, payload} <- normalize_payload(chunk),
         {:ok, transport, socket} <- MessageTarget.call(handle, :transport),
         :ok <- transport_send(transport, socket, payload) do
      :ok
    else
      # A chunk that is not bytes is an error of the caller. The write
      # rejects with the `TypeError`, and the socket closes.
      {:error, %TypeError{} = error} ->
        _reply = MessageTarget.call(handle, {:write_failed, error})
        Promise.reject(error)

      # The socket is closed, or it started TLS.
      {:error, reason} when reason in [:closed, :detached, :not_connected] ->
        Promise.reject(:closed)

      {:error, reason} ->
        _reply = MessageTarget.call(handle, {:write_failed, {:transport_error, reason}})
        Promise.reject(reason)
    end
  end

  # A close and an abort of the writable side close the socket.
  defp sink_close(handle) do
    _reply = MessageTarget.call(handle, :sink_close)
    :ok
  end

  defp clear_monitor(monitor_ref) when is_reference(monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
    :ok
  end

  defp normalize_address!(address) when is_binary(address) do
    case String.split(address, ":", parts: 2) do
      [host, port_text] when host != "" and port_text != "" ->
        case Integer.parse(port_text) do
          {port, ""} when port in 0..65_535 -> {host, port}
          _ -> raise(TypeError.exception("SocketError: invalid address"))
        end

      _ ->
        raise(TypeError.exception("SocketError: invalid address"))
    end
  end

  defp normalize_address!(address) when is_list(address) do
    if Keyword.keyword?(address) do
      address
      |> Enum.into(%{})
      |> normalize_address!()
    else
      raise(TypeError.exception("SocketError: invalid address"))
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
      raise(TypeError.exception("SocketError: invalid address"))
    end
  end

  defp normalize_address!(_address) do
    raise(TypeError.exception("SocketError: invalid address"))
  end

  defp normalize_options(options) when is_list(options),
    do: options |> Enum.into(%{}) |> normalize_options()

  defp normalize_options(options) when is_map(options) do
    secure_transport =
      Map.get(options, :secure_transport) ||
        Map.get(options, :secureTransport) ||
        Map.get(options, "secure_transport") ||
        Map.get(options, "secureTransport") ||
        "off"

    options
    |> Map.put(:secure_transport, secure_transport)
    |> Map.update(:tcp_options, [], &normalize_list_options/1)
    |> Map.update(:ssl_options, [], &normalize_ssl_options/1)
  end

  defp normalize_options(_options) do
    raise(TypeError.exception("SocketError: invalid options"))
  end

  defp normalize_ssl_options(options) when is_map(options), do: Map.to_list(options)
  defp normalize_ssl_options(options) when is_list(options), do: options
  defp normalize_ssl_options(_options), do: []

  defp normalize_list_options(options) when is_list(options), do: options
  defp normalize_list_options(nil), do: []
  defp normalize_list_options(option), do: [option]
end
