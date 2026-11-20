defmodule Web.Dispatcher.HTTP.Exchange do
  @moduledoc false

  # The network side of one request of `Web.Dispatcher.HTTP`. The functions
  # run in the process of the request, and keep their state in its process
  # dictionary.
  #
  # The process owns the socket of its connection while the request runs.
  # Thus each message of the socket comes to it directly, and no other
  # process is on the way of the response:
  #
  #   * With the setting `[:http1]`, and with the two versions, the
  #     connection comes from the pool of its origin, and goes back to the
  #     pool at the end of the response: see `Web.Dispatcher.HTTP.Pool`.
  #     With the two versions, a TLS connection can use HTTP/2: it has one
  #     request at a time.
  #   * With the setting `[:http2]`, the requests of an origin share one
  #     connection. Its process sends the events of each response to the
  #     process of the request: see `Web.Dispatcher.HTTP.Multiplex`.
  #
  # `handle/1` takes each message of the network, and `next/0` gives the
  # events of the response in their sequence:
  #
  #   * `{:head, kind, status, headers, location, protocol}`: the kind is
  #     `:body`, `:null` (no body), `:discard` (a redirect to follow), or
  #     `:redirect_error` (a redirect that the redirect mode refuses).
  #   * `{:data, piece}`: a piece of the body, after the content decoding.
  #   * `:done`, or `{:error, reason}`.
  #
  # The process stops to read its socket while it has 64 KiB of the body
  # that no reader took: `credit/1` gives the bytes that left its buffer.
  # This is the backpressure. A connection of HTTP/2 that the requests share
  # does not stop: the other requests use it also.

  alias Web.Dispatcher.HTTP.Multiplex
  alias Web.Dispatcher.HTTP.Pool
  alias Web.Internal.Address
  alias Web.Internal.Bytes
  alias Web.Internal.ContentDecoder

  @state {__MODULE__, :state}
  @events {__MODULE__, :events}
  # The bytes of the body that the process gave and that did not leave its
  # buffer. The content decoder gives its pieces to a function with no
  # other argument, thus the count is not in the state.
  @inflight {__MODULE__, :inflight}

  # The bytes of the body that the process keeps while no reader takes
  # them, and the largest body of a redirect that the process reads to its
  # end: a larger one closes its connection.
  @limit 65_536

  @null_body_statuses [101, 103, 204, 205, 304]
  @redirect_statuses [301, 302, 303, 307, 308]
  @default_receive_timeout 300_000

  @doc """
  Starts the request on the network. The response comes as events: see
  `next/0`. Returns an error when the request cannot be sent, for example
  for a body that is not valid.
  """
  @spec start(Web.Request.t()) :: :ok | {:error, term()}
  def start(%Web.Request{} = request) do
    url = request.url

    state = %{
      origin: {scheme(url), url.hostname, port(url)},
      method: request.method,
      path: url.pathname <> query(url),
      headers: request_headers(request.headers),
      body: request_body(request),
      redirect: redirect_mode(request),
      protocols: Web.Application.http_protocols(),
      protocol: :http1,
      phase: :start,
      # The response
      status: nil,
      kind: :head,
      decoder: nil,
      discarded: 0,
      started?: false,
      failure: nil,
      # The flow of the body: the socket gives one message at a time, see
      # `listen/1`.
      armed?: false,
      paused?: false,
      # The network gave the end of the response, and the decoder has data.
      received?: false,
      deadline: :infinity,
      timeout: Application.get_env(:web, :receive_timeout, @default_receive_timeout),
      # The connection
      conn: nil,
      request_ref: nil,
      reused?: false,
      pool: nil,
      slot: nil,
      monitor: nil,
      connector: nil,
      multiplex: nil,
      # The request body from a stream
      pump: nil,
      pending: "",
      body_end: :sent,
      ack?: false
    }

    Process.put(@events, :queue.new())
    Process.put(@inflight, 0)

    case state.protocols do
      [:http2] -> start_multiplex(state)
      _protocols -> checkout(state)
    end
  rescue
    error -> {:error, error}
  end

  @doc "The next event of the response, or `:none` when no event is ready."
  @spec next() :: {:ok, term()} | :none
  def next do
    case :queue.out(Process.get(@events)) do
      {{:value, event}, queue} ->
        Process.put(@events, queue)
        {:ok, event}

      {:empty, _queue} ->
        :none
    end
  end

  @doc """
  Takes a message of the network. Returns `:unknown` for a different
  message.
  """
  @spec handle(term()) :: :handled | :unknown
  def handle(message), do: handle(message, Process.get(@state))

  @doc """
  The time in milliseconds until the receive timeout, or `:infinity`. The
  time starts again at each message of the network, and it does not apply
  while the process does not read its socket.
  """
  @spec wait_time() :: timeout()
  def wait_time do
    case Process.get(@state) do
      %{deadline: :infinity} -> :infinity
      %{deadline: deadline} -> max(deadline - now(), 0)
    end
  end

  @doc "The receive timeout is over: the request fails."
  @spec expire() :: :ok
  def expire do
    Process.get(@state)
    |> stop()
    |> fail(%Mint.TransportError{reason: :timeout})
  end

  @doc """
  Bytes of the body left the buffer of the process. The process reads its
  socket again when it has less than the limit.
  """
  @spec credit(non_neg_integer()) :: :ok
  def credit(bytes) do
    Process.put(@inflight, Process.get(@inflight) - bytes)

    # The decoder gives its next pieces first. The socket is read again when
    # the decoder needs more data.
    case drain(Process.get(@state)) do
      %{phase: :finished} = state ->
        after_batch(state, nil)

      %{phase: :open, paused?: true} = state ->
        if Process.get(@inflight) < @limit,
          do: state |> listen() |> watch_time() |> put(),
          else: put(state)

      state ->
        put(state)
    end
  end

  @doc """
  The process used the end of the response: the connection goes back to
  the pool. The process calls this after it settled the promise, thus the
  return of the socket does not delay the response.
  """
  @spec finish() :: :ok
  def finish do
    case Process.get(@state) do
      %{phase: :finished} = state -> state |> checkin() |> put()
      _state -> :ok
    end
  end

  @doc """
  Stops the request: an abort, a cancel, or a body that no process reads.
  The connection closes, and no more events come.
  """
  @spec close() :: :ok
  def close do
    Process.put(@events, :queue.new())
    Process.get(@state) |> stop() |> put()
  end

  @doc false
  # The event of a response of the HTTP client with no request reference,
  # or `nil` for a response that is not of a request.
  @spec event(tuple()) :: {reference(), term()} | nil
  def event({:status, ref, status}), do: {ref, {:status, status}}
  def event({:headers, ref, headers}), do: {ref, {:headers, headers}}
  def event({:data, ref, data}), do: {ref, {:data, data}}
  def event({:done, ref}), do: {ref, :done}
  def event({:error, ref, reason}), do: {ref, {:error, reason}}
  def event(_response), do: nil

  @doc false
  # The options of a new connection: the connect timeout, and for TLS the
  # setting `:tls_options`.
  @spec connect_options(:http | :https, [:http1 | :http2]) :: keyword()
  def connect_options(scheme, protocols) do
    tls = if scheme == :https, do: Web.Application.tls_options(), else: []

    # The URL parser makes the request target, as in a browser: the HTTP
    # client does not check it again. For example, a path can have `|`.
    [
      mode: :passive,
      protocols: protocols,
      skip_target_validation: true,
      transport_opts: [timeout: Web.Application.connect_timeout()] ++ tls
    ]
  end

  @doc false
  # Opens a connection of the HTTP client. An IP address goes as a tuple:
  # see `Web.Internal.Address`.
  @spec mint_connect(:http | :https, String.t(), :inet.port_number(), keyword()) ::
          {:ok, Mint.HTTP.t()} | {:error, term()}
  def mint_connect(scheme, host, port, options) do
    Mint.HTTP.connect(scheme, Address.mint(host), port, Address.mint_options(host, options))
  end

  @doc false
  # The body argument of the request of the HTTP client, the bytes to send
  # after it, and the state of the end of the body. HTTP/2 sends a body
  # only in its window: a body that is larger goes in parts.
  @spec body_argument(Mint.HTTP.t(), nil | {:data, iodata()} | :stream | {:stream, term()}) ::
          {nil | iodata() | :stream, binary(), :sent | :ready | :waiting}
  def body_argument(_conn, nil), do: {nil, "", :sent}
  def body_argument(_conn, :stream), do: {:stream, "", :waiting}
  def body_argument(_conn, {:stream, _enumerable}), do: {:stream, "", :waiting}

  def body_argument(conn, {:data, data}) do
    case Mint.HTTP.protocol(conn) do
      :http1 ->
        {data, "", :sent}

      # The window of a new stream is the initial window of the server.
      :http2 ->
        window =
          min(
            Mint.HTTP2.get_window_size(conn, :connection),
            Mint.HTTP2.get_server_setting(conn, :initial_window_size)
          )

        if IO.iodata_length(data) <= window,
          do: {data, "", :sent},
          else: {:stream, IO.iodata_to_binary(data), :ready}
    end
  end

  @doc false
  # Sends the bytes of the request body that the window of HTTP/2 allows,
  # and the end of the body when it is ready. Returns the bytes that wait.
  @spec write_body(Mint.HTTP.t(), reference(), binary(), :sent | :ready | :waiting) ::
          {:ok, Mint.HTTP.t(), binary(), :sent | :ready | :waiting}
          | {:error, Mint.HTTP.t(), term()}
  def write_body(conn, ref, "", :ready) do
    with {:ok, conn} <- Mint.HTTP.stream_request_body(conn, ref, :eof),
         do: {:ok, conn, "", :sent}
  end

  def write_body(conn, _ref, "", body_end), do: {:ok, conn, "", body_end}

  def write_body(conn, ref, data, body_end) do
    case window(conn, ref, byte_size(data)) do
      0 ->
        {:ok, conn, data, body_end}

      size ->
        now = binary_part(data, 0, size)
        rest = binary_part(data, size, byte_size(data) - size)

        with {:ok, conn} <- Mint.HTTP.stream_request_body(conn, ref, now),
             do: write_body(conn, ref, rest, body_end)
    end
  end

  defp window(conn, ref, size) do
    case Mint.HTTP.protocol(conn) do
      :http1 ->
        size

      :http2 ->
        Enum.min([
          size,
          Mint.HTTP2.get_window_size(conn, :connection),
          Mint.HTTP2.get_window_size(conn, {:request, ref})
        ])
    end
  end

  # ---------------------------------------------------------------------------
  # A connection from the pool
  # ---------------------------------------------------------------------------

  # The process asks the pool for a connection, and waits for it with the
  # other messages: an abort stops the wait.
  defp checkout(state) do
    pool = Pool.get(state.origin)
    slot = make_ref()
    send(pool, {:checkout, self(), slot})

    put(%{
      state
      | phase: :checkout,
        kind: :head,
        pool: pool,
        slot: slot,
        monitor: Process.monitor(pool)
    })
  end

  # The pool gives an idle connection, or a slot for a new connection.
  defp handle({slot, grant}, %{phase: :checkout, slot: slot} = state) do
    Process.demonitor(state.monitor, [:flush])
    state = %{state | monitor: nil}

    case grant do
      {:conn, conn} -> send_request(conn, true, state)
      :connect -> connect(state)
    end

    :handled
  end

  defp handle({ref, result}, %{phase: :connect, connector: {pid, ref}} = state) do
    Process.unlink(pid)
    state = %{state | connector: nil}

    case result do
      {:ok, conn} -> send_request(conn, false, state)
      {:error, reason} -> state |> release(:closed) |> fail(reason)
    end

    :handled
  end

  # The pool, or the process of the shared connection, stopped. A process
  # of a shared connection that stops normally gives an error to each
  # request that it has: a request that gets no error did not start, and
  # goes on a new connection.
  defp handle({:DOWN, monitor, :process, _pid, reason}, %{monitor: monitor} = state) do
    state = %{state | monitor: nil}

    if is_pid(state.multiplex) and reason in [:normal, :noproc] and repeatable?(state) do
      start_multiplex(%{state | multiplex: nil})
    else
      %{state | pool: nil, multiplex: nil}
      |> stop()
      |> fail({:connection_process_stopped, reason})
    end

    :handled
  end

  # The pieces of a request body from a stream. On a shared connection,
  # its process sends them, and answers `:sent`.
  defp handle({ref, :chunk, chunk}, %{pump: {_pid, ref}, multiplex: pid} = state)
       when is_pid(pid) do
    send(pid, {:body, state.request_ref, chunk})
    :handled
  end

  defp handle({ref, :chunk, chunk}, %{pump: {_pid, ref}} = state) do
    %{state | pending: chunk, ack?: true} |> write_pending() |> put()
    :handled
  end

  defp handle({ref, :eof}, %{pump: {pid, ref}, multiplex: multiplex} = state)
       when is_pid(multiplex) do
    Process.unlink(pid)
    send(multiplex, {:body, state.request_ref, :eof})
    %{state | pump: nil, body_end: :sent} |> watch_time() |> put()
    :handled
  end

  defp handle({ref, :eof}, %{pump: {pid, ref}} = state) do
    Process.unlink(pid)
    %{state | pump: nil, body_end: :ready} |> write_pending() |> watch_time() |> put()
    :handled
  end

  defp handle({ref, :error, reason}, %{pump: {pid, ref}} = state) do
    Process.unlink(pid)
    %{state | pump: nil} |> stop() |> fail(reason)
    :handled
  end

  # The events of a response on a shared connection.
  defp handle({ref, :events, events}, %{request_ref: ref, multiplex: pid} = state)
       when is_pid(pid) do
    case events |> Enum.reduce(state, &response_event/2) |> drain() do
      %{failure: nil} = state -> state |> watch_time() |> put()
      %{failure: reason} = state -> stream_failure(state, reason)
    end

    :handled
  end

  defp handle({ref, :sent}, %{request_ref: ref, multiplex: pid} = state) when is_pid(pid) do
    ack_pump(state)
    :handled
  end

  # A message of the socket of the connection. After the end of the
  # response, a message can still change the connection: for example, the
  # server closes it.
  defp handle(message, %{phase: phase, conn: conn} = state)
       when phase in [:open, :finished] and conn != nil do
    case Mint.HTTP.stream(conn, message) do
      :unknown ->
        :unknown

      {:ok, conn, responses} ->
        %{state | conn: conn, armed?: false} |> responses(responses) |> after_batch(nil)
        :handled

      {:error, conn, reason, responses} ->
        %{state | conn: conn, armed?: false} |> responses(responses) |> after_batch(reason)
        :handled
    end
  end

  defp handle(_message, _state), do: :unknown

  # A new connection: a short process connects, thus the process of the
  # request answers each message while the connection opens. The process
  # gives the socket to the process of the request.
  defp connect(state) do
    owner = self()
    ref = make_ref()
    {scheme, host, port} = state.origin
    options = connect_options(scheme, state.protocols)

    pid =
      spawn_link(fn ->
        result =
          with {:ok, conn} <- mint_connect(scheme, host, port, options),
               do: Mint.HTTP.controlling_process(conn, owner)

        send(owner, {ref, result})
      end)

    put(%{state | phase: :connect, connector: {pid, ref}})
  end

  defp send_request(conn, reused?, state) do
    {argument, pending, body_end} = body_argument(conn, state.body)
    state = %{state | conn: conn, reused?: reused?}

    case Mint.HTTP.request(conn, state.method, state.path, state.headers, argument) do
      {:ok, conn, ref} ->
        %{
          state
          | phase: :open,
            conn: conn,
            request_ref: ref,
            protocol: Mint.HTTP.protocol(conn),
            pending: pending,
            body_end: body_end
        }
        |> start_pump()
        |> write_pending()
        |> watch_time()
        |> put()

      {:error, conn, reason} ->
        network_failure(%{state | conn: conn}, reason)
    end
  end

  # The connection failed: it closes. A request on a connection that was
  # idle goes again on a different connection, see `retry?/2`.
  defp network_failure(state, reason) do
    state = state |> close_conn() |> release(:closed) |> kill_pump()
    if retry?(state, reason), do: checkout(state), else: fail(state, reason)
  end

  # The request goes on a different connection when nothing of the
  # response came, and the body can be sent again:
  #
  #   * a connection that was idle can be closed by the server before the
  #     request, and
  #   * an HTTP/2 server tells with `:unprocessed` that it did not use the
  #     request, for example when it closes the connection for new streams.
  defp retry?(state, reason) do
    repeatable?(state) and (unprocessed?(reason) or (state.reused? and closed?(reason)))
  end

  defp repeatable?(state) do
    not state.started? and not match?({:stream, _enumerable}, state.body)
  end

  # A stream that the server refused did not run also.
  defp unprocessed?(reason) do
    match?(%Mint.HTTPError{reason: :unprocessed}, reason) or
      match?(%Mint.HTTPError{reason: {:server_closed_request, :refused_stream}}, reason)
  end

  # The pool gives only a connection that is open for requests, thus a
  # connection that closed gives an error of the transport.
  defp closed?(reason), do: match?(%Mint.TransportError{}, reason)

  # The server stopped the stream of the request.
  defp stream_failure(state, reason) do
    # The connection process ended the stream already.
    Process.demonitor(state.monitor, [:flush])
    state = stop(%{state | failure: nil, multiplex: nil, monitor: nil})

    if retry?(state, reason),
      do: start_multiplex(%{state | kind: :head}),
      else: fail(state, reason)
  end

  # The responses of one message of the socket.
  defp responses(state, responses) do
    ref = state.request_ref

    for response <- responses, {^ref, event} <- [event(response)], reduce: state do
      state -> response_event(event, state)
    end
  end

  # After the responses of a message: at the end of the response, the
  # connection waits for `finish/0`, or closes at a failure.
  defp after_batch(%{failure: failure} = state, _reason) when failure != nil do
    network_failure(%{state | failure: nil}, failure)
  end

  defp after_batch(%{phase: :finished} = state, reason) do
    if reason == nil and Mint.HTTP.open?(state.conn) and state.body_end == :sent,
      do: put(%{state | deadline: :infinity}),
      else: state |> close_conn() |> release(:closed) |> kill_pump() |> done()
  end

  defp after_batch(%{phase: :open} = state, nil), do: state |> drain() |> continue()

  defp after_batch(%{phase: :open} = state, reason), do: network_failure(state, reason)

  # A response event closed the connection already.
  defp after_batch(state, _reason), do: put(state)

  # After the pieces of the decoder: the end of the body, or the next
  # message of the socket.
  defp continue(%{phase: :finished} = state), do: after_batch(state, nil)

  defp continue(%{phase: :open} = state),
    do: state |> write_pending() |> watch_time() |> put()

  # The data cannot be decoded: the connection closed.
  defp continue(state), do: put(state)

  defp done(state), do: put(%{state | phase: :done, deadline: :infinity})

  # The process asks for no message after the end of the response, thus
  # the socket is in its passive mode already: see `next_message/1`.
  defp checkin(state) do
    conn = state.conn

    message =
      case Mint.HTTP.controlling_process(conn, state.pool) do
        {:ok, conn} ->
          {:checkin, state.slot, conn}

        {:error, _reason} ->
          Mint.HTTP.close(conn)
          {:checkin, state.slot, :closed}
      end

    send(state.pool, message)
    kill_pump(%{state | conn: nil, slot: nil, phase: :done, deadline: :infinity})
  end

  defp release(%{slot: nil} = state, _conn), do: state

  defp release(state, conn) do
    send(state.pool, {:checkin, state.slot, conn})
    %{state | slot: nil}
  end

  defp close_conn(%{conn: nil} = state), do: state

  defp close_conn(state) do
    Mint.HTTP.close(state.conn)
    %{state | conn: nil}
  end

  # The process stops to read its socket at the limit of the bytes that no
  # reader took: the backpressure.
  defp next_message(%{received?: true} = state), do: state

  defp next_message(state) do
    if Process.get(@inflight) >= @limit, do: %{state | paused?: true}, else: listen(state)
  end

  # The socket gives its next message, and then waits. The connection of
  # the HTTP client stays in its passive mode: the client reads each message
  # that the process gives it, and the process asks for one message at a
  # time. Thus the mailbox has one message of the socket at most, also when
  # the process stops and starts to read many times.
  defp listen(%{armed?: true} = state), do: %{state | paused?: false}

  # The flag is set before the socket can send its message, thus the flag
  # tells the truth at each time: see `FlagMatchesSocket` in
  # `tla/SocketFlow.tla`.
  defp listen(state) do
    armed = %{state | armed?: true, paused?: false}
    put(armed)

    case setopts(Mint.HTTP.get_socket(state.conn), active: :once) do
      :ok ->
        armed

      # The socket is closed: no message comes. The request fails.
      {:error, reason} ->
        network_failure(state, %Mint.TransportError{reason: reason})
        Process.get(@state)
    end
  end

  defp setopts(socket, options) when is_port(socket), do: :inet.setopts(socket, options)
  defp setopts(socket, options), do: :ssl.setopts(socket, options)

  # ---------------------------------------------------------------------------
  # A shared connection of HTTP/2
  # ---------------------------------------------------------------------------

  defp start_multiplex(state) do
    pid = Multiplex.get(state.origin)
    ref = make_ref()

    body =
      case state.body do
        {:stream, _enumerable} -> :stream
        body -> body
      end

    send(pid, {:request, self(), ref, {state.method, state.path, state.headers, body}})

    %{
      state
      | phase: :open,
        multiplex: pid,
        request_ref: ref,
        protocol: :http2,
        monitor: Process.monitor(pid),
        body_end: if(body == :stream, do: :waiting, else: :sent)
    }
    |> start_pump()
    |> watch_time()
    |> put()
  end

  # ---------------------------------------------------------------------------
  # The request body from a stream
  # ---------------------------------------------------------------------------

  # A short process reads the stream, and gives each chunk when the
  # previous chunk is on the network. Thus the process of the request
  # answers each message while the stream gives its chunks.
  defp start_pump(%{phase: :open, body: {:stream, enumerable}} = state) do
    owner = self()
    ref = make_ref()
    pid = spawn_link(fn -> pump(owner, ref, enumerable) end)
    %{state | pump: {pid, ref}}
  end

  defp start_pump(state), do: state

  defp pump(owner, ref, enumerable) do
    Enum.each(enumerable, fn chunk ->
      send(owner, {ref, :chunk, Bytes.to_binary!(chunk, "The request body")})

      receive do
        {^ref, :next} -> :ok
      end
    end)

    send(owner, {ref, :eof})
  catch
    _kind, reason -> send(owner, {ref, :error, reason})
  end

  # The pending bytes go on the network, and the socket gives its next
  # message. A chunk of the stream that is on the network lets the stream
  # give the next one.
  defp write_pending(state) do
    case write_body(state.conn, state.request_ref, state.pending, state.body_end) do
      {:ok, conn, pending, body_end} ->
        state = %{state | conn: conn, pending: pending, body_end: body_end}

        if pending == "" and state.ack?,
          do: next_message(%{ack_pump(state) | ack?: false}),
          else: next_message(state)

      {:error, conn, reason} ->
        network_failure(%{state | conn: conn}, reason)
        Process.get(@state)
    end
  end

  defp ack_pump(%{pump: {pid, ref}} = state) do
    send(pid, {ref, :next})
    state
  end

  # The request does not read its body to the end: the stream of the body
  # stops. The response can come before the end of the body, thus the
  # stream stops only when the request stops to send it.
  defp kill_pump(%{pump: {pid, _ref}} = state) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    release_body(state.body)
    %{state | pump: nil}
  end

  defp kill_pump(state), do: state

  # A body of `Web.Request.new/2` is a stream, and the stream has a process
  # after the start of its read.
  defp release_body({:stream, stream}) do
    with %Web.ReadableStream{} <- stream,
         {:ok, pid} <- Web.ReadableStream.__process__(stream),
         do: Web.Stream.terminate_and_wait(pid, :cancel, :request_complete)
  end

  # ---------------------------------------------------------------------------
  # The end of the request
  # ---------------------------------------------------------------------------

  # Closes each part of the request that runs.
  defp stop(state) do
    state
    |> stop_phase()
    |> kill_pump()
    |> Map.merge(%{phase: :closed, deadline: :infinity, kind: :closed})
  end

  defp stop_phase(%{phase: :checkout} = state), do: cancel_checkout(state)

  defp stop_phase(%{phase: :connect, connector: {pid, ref}} = state) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    monitor = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end

    # The connection can be in the process already, when the connect ended
    # just before the stop.
    receive do
      # coveralls-ignore-next-line
      {^ref, {:ok, conn}} -> Mint.HTTP.close(conn)
    after
      0 -> :ok
    end

    release(%{state | connector: nil}, :closed)
  end

  defp stop_phase(%{multiplex: pid} = state) when is_pid(pid) do
    send(pid, {:cancel, state.request_ref})
    Process.demonitor(state.monitor, [:flush])
    %{state | multiplex: nil, monitor: nil}
  end

  defp stop_phase(state), do: state |> close_conn() |> release(:closed)

  # The pool can give a connection before it gets the cancel: the process
  # gives the connection back.
  defp cancel_checkout(state) do
    slot = state.slot
    monitor = state.monitor
    send(state.pool, {:cancel, self(), slot})

    receive do
      {^slot, {:conn, conn}} -> cancel_checkout(%{state | conn: conn} |> checkin())
      {^slot, :connect} -> cancel_checkout(release(state, :closed))
      {^slot, :canceled} -> Process.demonitor(monitor, [:flush])
      # A pool stops only with the application.
      # coveralls-ignore-next-line
      {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
    end

    %{state | slot: nil, monitor: nil}
  end

  defp fail(state, reason) do
    emit({:error, reason})
    put(%{state | phase: :failed, deadline: :infinity, kind: :closed})
  end

  # ---------------------------------------------------------------------------
  # The events of the response
  # ---------------------------------------------------------------------------

  defp response_event({:status, status}, state), do: %{state | status: status, started?: true}

  # An informational response (a status from 100 to 199, but not 101) comes
  # before the response. The Fetch Standard ignores it.
  defp response_event({:headers, _headers}, %{kind: :head, status: status} = state)
       when status in 100..199 and status != 101 do
    %{state | status: nil}
  end

  defp response_event({:headers, headers}, %{kind: :head} = state) do
    location =
      case List.keyfind(headers, "location", 0) do
        {_name, value} -> value
        nil -> nil
      end

    kind = response_kind(state, location)
    emit({:head, kind, state.status, headers, location, state.protocol})

    case kind do
      :body -> %{state | kind: :body, decoder: ContentDecoder.new(headers)}
      :redirect_error -> stop(state)
      kind -> %{state | kind: kind}
    end
  end

  # The decoder keeps the data: `drain/1` takes its output.
  defp response_event({:data, data}, %{kind: :body} = state) do
    case state.decoder do
      nil ->
        emit_piece(data)
        state

      decoder ->
        %{state | decoder: ContentDecoder.push(decoder, data)}
    end
  end

  # The body of a redirect goes away. A large body closes the connection,
  # and the redirect continues.
  defp response_event({:data, data}, %{kind: :discard} = state) do
    discarded = state.discarded + byte_size(data)

    if discarded > @limit do
      emit(:done)
      stop(state)
    else
      %{state | discarded: discarded}
    end
  end

  # The end of a body that the decoder has: `drain/1` gives the end after
  # the last piece.
  defp response_event(:done, %{kind: :body, decoder: decoder} = state) when decoder != nil do
    %{state | decoder: ContentDecoder.finish(decoder), received?: true}
  end

  defp response_event(:done, %{kind: kind} = state) when kind != :closed, do: finished(state)

  # The server stopped the stream. The function after the events closes the
  # connection, or sends the request again.
  defp response_event({:error, reason}, %{kind: kind} = state) when kind != :closed do
    %{state | failure: reason, kind: :closed}
  end

  # Trailers, data of a response with no body, and each event after a stop.
  defp response_event(_event, state), do: state

  defp finished(%{multiplex: pid} = state) when is_pid(pid) do
    emit(:done)
    Process.demonitor(state.monitor, [:flush])

    kill_pump(%{
      state
      | phase: :done,
        multiplex: nil,
        monitor: nil,
        kind: :closed,
        deadline: :infinity
    })
  end

  defp finished(state) do
    emit(:done)
    %{state | phase: :finished, kind: :closed}
  end

  defp failed(state, reason) do
    emit({:error, reason})
    %{state | phase: :failed, kind: :closed}
  end

  # A piece of the body counts in the bytes that the process has.
  defp emit_piece(piece) do
    emit({:data, piece})
    Process.put(@inflight, Process.get(@inflight) + byte_size(piece))
  end

  # The decoder gives its pieces while the process has less than the limit
  # of bytes that no reader took. Thus a small compressed chunk that expands
  # much does not fill the memory.
  defp drain(%{kind: :body, decoder: decoder} = state) when decoder != nil do
    if Process.get(@inflight) >= @limit do
      state
    else
      case ContentDecoder.pull(decoder) do
        {:piece, piece, decoder} ->
          emit_piece(piece)
          drain(%{state | decoder: decoder})

        {:more, decoder} ->
          %{state | decoder: decoder}

        {:done, decoder} ->
          finished(%{state | decoder: decoder})
      end
    end
  rescue
    error in ContentDecoder.Error -> state |> stop() |> failed(error)
  end

  defp drain(state), do: state

  defp emit(event), do: Process.put(@events, :queue.in(event, Process.get(@events)))

  defp response_kind(%{status: status, redirect: "error"}, location)
       when status in @redirect_statuses and is_binary(location),
       do: :redirect_error

  defp response_kind(%{status: status, redirect: "follow"}, location)
       when status in @redirect_statuses and is_binary(location),
       do: :discard

  defp response_kind(%{status: status, method: method}, _location)
       when method == "HEAD" or status in @null_body_statuses,
       do: :null

  defp response_kind(_state, _location), do: :body

  # ---------------------------------------------------------------------------
  # The receive timeout
  # ---------------------------------------------------------------------------

  # The time starts when the request is on the network, and again at each
  # message. It does not apply while the process does not read its socket,
  # nor after the end of the response.
  defp watch_time(%{phase: :open, body_end: :sent, paused?: false, received?: false} = state)
       when state.timeout != :infinity do
    %{state | deadline: now() + state.timeout}
  end

  defp watch_time(%{phase: :open} = state), do: %{state | deadline: :infinity}
  defp watch_time(state), do: state

  defp now, do: System.monotonic_time(:millisecond)

  defp put(state) do
    Process.put(@state, state)
    :ok
  end

  # ---------------------------------------------------------------------------
  # The parts of the request
  # ---------------------------------------------------------------------------

  defp scheme(%Web.URL{protocol: "https:"}), do: :https
  defp scheme(%Web.URL{protocol: "http:"}), do: :http

  defp port(%Web.URL{port: "", protocol: "https:"}), do: 443
  defp port(%Web.URL{port: ""}), do: 80
  defp port(%Web.URL{port: port}), do: String.to_integer(port)

  # The query of the request target, with its "?". An empty query keeps the
  # "?": the URL "http://a/?" asks for "/?". The getter of `search` gives ""
  # for an empty query.
  defp query(%Web.URL{search: nil}), do: ""

  defp query(url) do
    case Web.URL.search(url) do
      "" -> "?"
      search -> search
    end
  end

  defp redirect_mode(request), do: request.options[:redirect] || request.redirect || "follow"

  defp request_body(%Web.Request{body: nil}), do: nil

  # The data of the body is in memory. Send it as one block, thus the
  # request has a content length.
  defp request_body(%Web.Request{body: %Web.ReadableStream{} = body, body_source: source})
       when not is_nil(source) do
    {:data, Enum.map_join(body, &request_chunk/1)}
  end

  defp request_body(%Web.Request{body: %Web.ReadableStream{} = body}), do: {:stream, body}

  defp request_body(%Web.Request{body: body}) when is_binary(body) or is_list(body),
    do: {:data, body}

  defp request_body(%Web.Request{body: body}) do
    if Enumerable.impl_for(body) do
      {:stream, body}
    else
      raise Web.TypeError, "The request body is not valid: #{inspect(body)}"
    end
  end

  # A chunk of a request body is a chunk of bytes, as the Fetch Standard
  # specifies.
  defp request_chunk(chunk), do: Bytes.to_binary!(chunk, "The request body")

  # The request has no header `accept-encoding`: it gets the codings that
  # the body decoder knows. A request with the header `range` gets
  # `identity`, as the Fetch Standard specifies: the range is a range of the
  # bytes that the server has.
  defp request_headers(headers) do
    headers =
      cond do
        Web.Headers.__has_lower__(headers, "accept-encoding") ->
          headers

        Web.Headers.__has_lower__(headers, "range") ->
          Web.Headers.__set_lower__(headers, "accept-encoding", "identity")

        true ->
          Web.Headers.__set_lower__(headers, "accept-encoding", ContentDecoder.accept_encoding())
      end

    Web.Headers.to_list(headers)
  end
end
