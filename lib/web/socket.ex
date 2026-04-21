defmodule Web.Socket do
  @moduledoc """
  Capability-gated TCP/TLS socket handle.
  """

  use GenServer

  alias Web.AsyncContext.Snapshot
  alias Web.ByteLengthQueuingStrategy
  alias Web.Internal.Envelope
  alias Web.Promise
  alias Web.ReadableStream
  alias Web.TypeError
  alias Web.WritableStream

  defstruct [:address, :token, :opened, :closed, :upgraded, :readable, :writable]

  @call_timeout 5_000
  @connect_timeout 5_000
  @readable_hwm 65_536

  @type t :: %__MODULE__{
          address: reference(),
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

    {:ok, pid} =
      GenServer.start(
        __MODULE__,
        {holder_pid, host, port, options, opened, opened_info, closed, closed_info, upgraded,
         upgraded_info, self(), boot_ref}
      )

    receive do
      {__MODULE__, ^boot_ref, ^pid, socket} -> socket
    end
  end

  @spec close(t(), any()) :: Web.Promise.t()
  def close(%__MODULE__{} = socket, reason \\ :closed) do
    _ = cast_target(socket.address, socket.token, {:close, reason})
    socket.closed
  end

  @spec start_tls(t(), map() | keyword()) :: Web.Promise.t()
  def start_tls(%__MODULE__{} = socket, options \\ %{}) do
    promises = deferred_socket_promises()
    promise_request(socket, {:start_tls, normalize_ssl_options(options), promises})
  end

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
  def handle_call(
        %Envelope{
          headers: %{"Authorization" => token, "X-Async-Context" => snapshot},
          body: body
        },
        _from,
        %{token: token} = state
      ) do
    do_handle_call(body, snapshot, state)
  end

  def handle_call({:envelope, %Envelope{} = envelope}, from, state) do
    handle_call(envelope, from, state)
  end

  def handle_call(%Envelope{}, _from, state) do
    {:reply, {:error, :unauthorized}, state}
  end

  def handle_call({:envelope, _envelope}, _from, state) do
    {:reply, {:error, :unauthorized}, state}
  end

  @doc false
  def handle_cast(
        %Envelope{
          headers: %{"Authorization" => token, "X-Async-Context" => snapshot},
          body: body
        },
        %{token: token} = state
      ) do
    do_handle_cast(body, snapshot, state)
  end

  def handle_cast({:envelope, %Envelope{} = envelope}, state) do
    handle_cast(envelope, state)
  end

  def handle_cast(%Envelope{}, state), do: {:noreply, state}
  def handle_cast({:envelope, _envelope}, state), do: {:noreply, state}

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

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def terminate(_reason, state) do
    clear_monitor(state.holder_monitor)

    state
    |> close_transport_if_needed()
    |> settle_opened_if_needed({:error, state.close_reason || :closed})
    |> settle_closed_if_needed(state.close_reason || :closed)
    |> settle_upgraded_if_needed({:error, state.close_reason || :closed})

    Process.unalias(state.address)
    :ok
  end

  @doc false
  defp build_state(holder_pid, {host, port}, options, promises) do
    authority = init_authority()
    {readable, writable} = init_streams(authority, options)

    holder_pid
    |> init_connection_state(host, port, options)
    |> Map.merge(authority)
    |> Map.merge(init_stream_state(readable, writable))
    |> Map.merge(promises)
  end

  @doc false
  defp init_authority do
    %{address: Process.alias(), token: make_ref()}
  end

  @doc false
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
      close_reason: nil
    }
  end

  @doc false
  defp init_streams(%{address: address, token: token}, options) do
    readable_hwm = Map.get(options, :readable_high_water_mark, @readable_hwm)
    request_timeout = Map.get(options, :request_timeout, @call_timeout)

    readable =
      ReadableStream.new(
        %{
          pull: fn _controller -> cast_target(address, token, :readable_pull) end,
          cancel: fn reason -> cast_target(address, token, {:readable_cancel, reason}) end
        },
        high_water_mark: readable_hwm,
        strategy: ByteLengthQueuingStrategy.new(readable_hwm)
      )

    writable =
      WritableStream.new(%{
        high_water_mark: Map.get(options, :writable_high_water_mark, 1),
        write: fn chunk, _controller -> write_promise(address, token, chunk, request_timeout) end,
        close: fn _controller -> close_promise(address, token, request_timeout) end,
        abort: fn reason -> abort_promise(address, token, reason, request_timeout) end
      })

    {readable, writable}
  end

  @doc false
  defp init_stream_state(readable, writable) do
    %{
      readable: readable,
      readable_pid: readable.controller_pid,
      writable: writable,
      writable_pid: writable.controller_pid
    }
  end

  @doc false
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

  defp do_handle_call(:debug, _snapshot, state) do
    {:reply, debug_info(state), state}
  end

  defp do_handle_call({:close, reason}, _snapshot, state) do
    next_state = shutdown_state(state, reason, :local_close)
    {:stop, :normal, :ok, next_state}
  end

  defp do_handle_call({:write, chunk}, _snapshot, state) do
    with :ok <- ensure_connected(state),
         {:ok, payload} <- normalize_payload(chunk),
         :ok <- transport_send(state.transport, state.socket, payload) do
      {:reply, :ok, state}
    else
      {:error, reason} ->
        next_state = shutdown_state(state, {:transport_error, reason}, :transport_error)
        {:stop, :normal, {:error, reason}, next_state}
    end
  end

  defp do_handle_call({:start_tls, options, promises}, _snapshot, state) do
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

  defp do_handle_call(_body, _snapshot, state) do
    {:reply, {:error, :unsupported_operation}, state}
  end

  defp do_handle_cast(:readable_pull, _snapshot, state) do
    {:noreply, maybe_resume_transport(state)}
  end

  defp do_handle_cast({:readable_cancel, reason}, _snapshot, state) do
    next_state = shutdown_state(state, {:readable_cancel, reason}, :readable_cancel)
    {:stop, :normal, next_state}
  end

  defp do_handle_cast({:close, reason}, _snapshot, state) do
    next_state = shutdown_state(state, reason, :local_close)
    {:stop, :normal, next_state}
  end

  defp do_handle_cast(_body, _snapshot, state) do
    {:noreply, state}
  end

  defp handle_transport_data(data, state) do
    ReadableStream.enqueue(state.readable_pid, data)
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

  defp shutdown_state(state, reason, mode) do
    state
    |> Map.put(:close_reason, reason)
    |> settle_opened_if_needed({:error, reason})
    |> settle_closed_if_needed(reason)
    |> settle_upgraded_if_needed({:error, reason})
    |> notify_streams(reason, mode)
    |> close_transport_if_needed()
  end

  defp notify_streams(state, _reason, :local_close) do
    ReadableStream.close(state.readable_pid)
    state
  end

  defp notify_streams(state, _reason, :transport_closed) do
    ReadableStream.close(state.readable_pid)
    WritableStream.error(state.writable_pid, :closed)
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
    send(state.opened_info.pid, {state.opened_info.ref, {:ok, value}})
    %{state | opened_settled?: true}
  end

  defp settle_opened(%{opened_settled?: false} = state, {:error, reason}) do
    send(state.opened_info.pid, {state.opened_info.ref, {:error, reason}})
    %{state | opened_settled?: true}
  end

  defp settle_opened(state, _result), do: state

  defp settle_opened_if_needed(state, result), do: settle_opened(state, result)

  defp settle_closed_if_needed(%{closed_settled?: false} = state, reason) do
    send(state.closed_info.pid, {state.closed_info.ref, {:ok, reason}})
    %{state | closed_settled?: true}
  end

  defp settle_closed_if_needed(state, _reason), do: state

  defp settle_upgraded(%{upgraded_settled?: false} = state, {:ok, value}) do
    send(state.upgraded_info.pid, {state.upgraded_info.ref, {:ok, value}})
    %{state | upgraded_settled?: true}
  end

  defp settle_upgraded(%{upgraded_settled?: false} = state, {:error, reason}) do
    send(state.upgraded_info.pid, {state.upgraded_info.ref, {:error, reason}})
    %{state | upgraded_settled?: true}
  end

  defp settle_upgraded(state, _result), do: state

  defp settle_upgraded_if_needed(state, result), do: settle_upgraded(state, result)

  defp upgrade_generation(state, ssl_socket, promises) do
    old_address = state.address
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
    send(state.closed_info.pid, {state.closed_info.ref, {:ok, :upgraded}})
    send(state.upgraded_info.pid, {state.upgraded_info.ref, {:ok, tls_socket}})
    Process.unalias(old_address)

    {next_state, tls_socket}
  end

  @doc false
  defp connect_transport(state) do
    timeout = Map.get(state.options, :connect_timeout, @connect_timeout)

    with {:ok, transport} <- transport_mode(state.secure_transport) do
      transport_connect(transport, state, timeout)
    end
  end

  @doc false
  defp transport_mode("off"), do: {:ok, :tcp}

  @doc false
  defp transport_mode("starttls"), do: {:ok, :starttls}

  @doc false
  defp transport_mode("on"), do: {:ok, :ssl}

  @doc false
  defp transport_mode(other), do: {:error, {:unsupported_secure_transport, other}}

  @doc false
  defp transport_connect(:tcp, state, timeout) do
    connect_fun = Map.get(state.options, :connect_fun, &:gen_tcp.connect/4)

    case connect_fun.(state.endpoint, state.port, tcp_connect_options(state.options), timeout) do
      {:ok, socket} -> {:ok, socket, :tcp}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  defp transport_connect(:starttls, state, timeout) do
    transport_connect(:tcp, state, timeout)
  end

  @doc false
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

    case :ssl.connect(state.socket, merge_ssl_options(options, state.host), @call_timeout) do
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
    {:ok, IO.iodata_to_binary(chunk)}
  rescue
    _error -> {:error, TypeError.exception("Socket writes must be binary or iodata")}
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

  defp merge_ssl_options(options, host) do
    options
    |> Keyword.put_new(:active, false)
    |> Keyword.put_new(:mode, :binary)
    |> Keyword.put_new(:packet, :raw)
    |> Keyword.put_new(:verify, :verify_none)
    |> Keyword.put_new(:server_name_indication, String.to_charlist(host))
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
    ref = make_ref()

    promise =
      Promise.new(fn resolve, reject ->
        receive do
          {^ref, {:ok, value}} -> resolve.(value)
          {^ref, {:error, reason}} -> reject.(reason)
        end
      end)

    {promise, %{pid: promise.task.pid, ref: ref}}
  end

  defp promise_request(%__MODULE__{} = socket, body) do
    Promise.new(fn resolve, reject ->
      case request_target(socket.address, socket.token, body, @call_timeout) do
        {:error, reason} -> reject.(reason)
        value -> resolve.(value)
      end
    end)
  end

  defp write_promise(address, token, chunk, timeout) do
    Promise.new(fn resolve, reject ->
      case request_target(address, token, {:write, chunk}, timeout) do
        :ok -> resolve.(:ok)
        {:error, reason} -> reject.(reason)
      end
    end)
  end

  defp close_promise(address, token, timeout) do
    Promise.new(fn resolve, reject ->
      case request_target(address, token, {:close, :closed}, timeout) do
        :ok -> resolve.(:ok)
        {:error, reason} -> reject.(reason)
      end
    end)
  end

  defp abort_promise(address, token, reason, timeout) do
    Promise.new(fn resolve, reject ->
      case request_target(address, token, {:close, :closed}, timeout) do
        :ok -> resolve.(:ok)
        {:error, abort_reason} -> reject.({reason, abort_reason})
      end
    end)
  end

  defp request_target(target, token, body, timeout)
       when is_reference(target) and is_reference(token) do
    reply_ref = make_ref()
    send(target, {:"$gen_call", {self(), reply_ref}, Envelope.new(token, body)})

    receive do
      {^reply_ref, reply} -> reply
    after
      timeout -> {:error, :closed}
    end
  end

  defp cast_target(target, token, body, snapshot \\ Snapshot.take())
       when is_reference(target) and is_reference(token) do
    send(target, {:"$gen_cast", Envelope.new(token, body, snapshot)})
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
