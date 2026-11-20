defmodule Web.Dispatcher.TCP.Connection do
  @moduledoc false

  # The network side of one request of `Web.Dispatcher.TCP`: a TCP socket
  # with no protocol on it. The functions run in the process of the request,
  # and keep their state in its process dictionary. They are the callbacks
  # of `Web.Dispatcher.RequestProcess`.
  #
  # A short process opens the connection, and gives the socket to the
  # process of the request. The process then writes the request body, and
  # gives the event `:open`. Each message of the socket comes to the process
  # directly. The events of the body are `{:data, piece}` for each message,
  # and `:done` when the peer closes the connection, or `{:error, reason}`.
  #
  # The process asks its socket for one message at a time, and stops to ask
  # while it has 64 KiB that no reader took: the backpressure. See
  # `tla/SocketFlow.tla`.

  @behaviour Web.Dispatcher.RequestProcess

  alias Web.Internal.Address
  alias Web.Internal.Bytes

  @state {__MODULE__, :state}
  @events {__MODULE__, :events}
  # The bytes of the body that the process gave and that did not leave its
  # buffer.
  @inflight {__MODULE__, :inflight}

  # The bytes of the body that the process keeps while no reader takes
  # them.
  @limit 65_536

  @doc """
  Starts the connection. Returns an error for a request body that is not
  bytes: the process then makes no connection.
  """
  @spec start(Web.Request.t()) :: :ok | {:error, Web.TypeError.t()}
  def start(%Web.Request{} = request) do
    body = request_body(request)
    {host, port} = target(request.url)

    Process.put(@events, :queue.new())
    Process.put(@inflight, 0)

    put(%{
      phase: :connect,
      socket: nil,
      connector: connect(host, port),
      body: body,
      armed?: false
    })
  rescue
    error in Web.TypeError -> {:error, error}
  end

  @impl true
  def next do
    case :queue.out(Process.get(@events)) do
      {{:value, event}, queue} ->
        Process.put(@events, queue)
        {:ok, event}

      {:empty, _queue} ->
        :none
    end
  end

  @impl true
  def handle(message), do: handle(message, Process.get(@state))

  # A stream of bytes has no receive timeout: a peer can send nothing for a
  # long time.
  @impl true
  def wait_time, do: :infinity

  @impl true
  def expire, do: :ok

  @impl true
  def credit(bytes) do
    Process.put(@inflight, Process.get(@inflight) - bytes)
    state = Process.get(@state)

    if state.phase == :open and Process.get(@inflight) < @limit,
      do: state |> listen() |> put(),
      else: :ok
  end

  # The peer closed the connection: the socket is closed already.
  @impl true
  def finish, do: :ok

  @impl true
  def close do
    Process.put(@events, :queue.new())
    Process.get(@state) |> stop() |> put()
  end

  # ---------------------------------------------------------------------------
  # The connection
  # ---------------------------------------------------------------------------

  # A short process connects, thus the process of the request answers each
  # message while the connection opens.
  defp connect(host, port) do
    owner = self()
    ref = make_ref()
    options = [:binary, packet: :raw, active: false]
    timeout = Web.Application.connect_timeout()

    pid =
      spawn_link(fn ->
        result =
          with {:ok, socket} <- :gen_tcp.connect(Address.endpoint(host), port, options, timeout),
               :ok <- :gen_tcp.controlling_process(socket, owner),
               do: {:ok, socket}

        send(owner, {ref, result})
      end)

    {pid, ref}
  end

  defp handle({ref, result}, %{phase: :connect, connector: {_pid, ref}} = state) do
    state = %{state | connector: nil}

    case result do
      {:ok, socket} -> put(open(%{state | socket: socket}))
      {:error, reason} -> put(fail(state, reason))
    end

    :handled
  end

  defp handle({:tcp, socket, data}, %{phase: :open, socket: socket} = state) do
    Process.put(@inflight, Process.get(@inflight) + byte_size(data))
    emit({:data, data})
    state = %{state | armed?: false}
    if Process.get(@inflight) < @limit, do: state |> listen() |> put(), else: put(state)
    :handled
  end

  defp handle({:tcp_closed, socket}, %{phase: :open, socket: socket} = state) do
    :gen_tcp.close(socket)
    emit(:done)
    put(%{state | phase: :done, socket: nil, armed?: false})
    :handled
  end

  defp handle({:tcp_error, socket, reason}, %{phase: :open, socket: socket} = state) do
    :gen_tcp.close(socket)
    put(fail(%{state | socket: nil}, reason))
    :handled
  end

  defp handle(_message, _state), do: :unknown

  # The request body goes first, then the body of the response comes.
  defp open(state) do
    case send_body(state.socket, state.body) do
      :ok ->
        emit(:open)
        listen(%{state | phase: :open, body: nil})

      {:error, reason} ->
        :gen_tcp.close(state.socket)
        fail(%{state | socket: nil}, reason)
    end
  end

  defp send_body(_socket, nil), do: :ok
  defp send_body(socket, body), do: :gen_tcp.send(socket, body)

  # The socket gives its next message, and then waits. Thus the mailbox has
  # one message of the socket at most. The flag is set before the socket can
  # send its message, thus the flag tells the truth at each time: see
  # `FlagMatchesSocket` in `tla/SocketFlow.tla`.
  defp listen(%{armed?: true} = state), do: state

  defp listen(state) do
    armed = %{state | armed?: true}
    put(armed)

    case :inet.setopts(state.socket, active: :once) do
      :ok ->
        armed

      # The socket is closed: no message comes. The body fails.
      {:error, reason} ->
        :gen_tcp.close(state.socket)
        fail(%{state | socket: nil}, reason)
    end
  end

  defp fail(state, reason) do
    emit({:error, reason})
    %{state | phase: :failed, armed?: false}
  end

  # Closes each part of the request that runs.
  defp stop(%{connector: {pid, ref}} = state) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    monitor = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end

    # The socket can be in the process already, when the connect ended just
    # before the stop.
    receive do
      # coveralls-ignore-next-line
      {^ref, {:ok, socket}} -> :gen_tcp.close(socket)
    after
      0 -> :ok
    end

    stop(%{state | connector: nil})
  end

  defp stop(%{socket: socket} = state) when socket != nil do
    :gen_tcp.close(socket)
    stop(%{state | socket: nil})
  end

  defp stop(state), do: %{state | phase: :closed, armed?: false}

  defp emit(event), do: Process.put(@events, :queue.in(event, Process.get(@events)))

  defp put(state) do
    Process.put(@state, state)
    :ok
  end

  # ---------------------------------------------------------------------------
  # The request
  # ---------------------------------------------------------------------------

  # A request with the method GET or HEAD has no body. The chunks of a body
  # are chunks of bytes: binaries, `Web.Uint8Array` values, `Web.ArrayBuffer`
  # values, or iodata. A body from a stream is read to its end first.
  defp request_body(%Web.Request{method: method}) when method in ["GET", "HEAD"], do: nil
  defp request_body(%Web.Request{body: body}), do: body_bytes(body)

  defp body_bytes(nil), do: nil
  defp body_bytes(<<>>), do: nil
  defp body_bytes(body) when is_binary(body), do: body
  defp body_bytes(%Web.ReadableStream{} = body), do: body |> Enum.to_list() |> body_bytes()
  defp body_bytes(body) when is_list(body), do: list_bytes(body)

  defp body_bytes(body) do
    if Enumerable.impl_for(body),
      do: body |> Enum.to_list() |> list_bytes(),
      else: not_readable!()
  end

  defp list_bytes(list) do
    case Bytes.to_binary(list) do
      {:ok, binary} -> body_bytes(binary)
      :error -> list |> Enum.map_join(&chunk_bytes/1) |> body_bytes()
    end
  end

  defp chunk_bytes(chunk) do
    case Bytes.to_binary(chunk) do
      {:ok, binary} -> binary
      :error -> not_readable!()
    end
  end

  defp not_readable!, do: raise(Web.TypeError, "body is not readable")

  # The host and the port of the URL. The port 80 is the default. An rclone
  # remote, such as `remote:host:port/path`, has the host in its path.
  defp target(url) do
    if Web.URL.rclone?(url) or remote_like?(url) do
      [authority | _path] = url |> Web.URL.pathname() |> String.split("/", parts: 2)

      case String.split(authority, ":", parts: 2) do
        [host, port] -> {host, String.to_integer(port)}
        [host] -> {host, 80}
      end
    else
      case Web.URL.port(url) do
        "" -> {Web.URL.hostname(url), 80}
        port -> {Web.URL.hostname(url), String.to_integer(port)}
      end
    end
  end

  defp remote_like?(url) do
    Web.URL.hostname(url) == "" and Web.URL.protocol(url) != "" and
      not String.starts_with?(Web.URL.pathname(url), "/")
  end
end
