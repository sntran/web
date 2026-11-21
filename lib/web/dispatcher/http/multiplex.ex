defmodule Web.Dispatcher.HTTP.Multiplex do
  @moduledoc false

  # The HTTP/2 connection of one origin, for the setting `[:http2]`. The
  # requests of the origin share the connection: each request is a stream
  # of the connection. This process owns the socket, and sends the events
  # of each response to the process of its request.
  #
  #   * The process connects when it starts. A request that comes before
  #     the connection is open waits in the mailbox.
  #   * When the server allows no more streams now, a request waits in a
  #     queue until a stream ends.
  #   * A request body goes in the window of HTTP/2: a part that is larger
  #     waits for the server to make the window larger.
  #   * The process monitors each process of a request. A request whose
  #     process stops is cancelled.
  #   * When the connection fails, each request on it gets the error, and
  #     the process stops. When the server closes the connection for new
  #     streams, the next requests use a new process. Thus a connection
  #     that closes never takes new requests. A request in the queue did not
  #     go to the server: it gets `:unprocessed`, and goes again on a new
  #     connection. See `tla/SharedConnection.tla`.
  #
  # The messages of a request: `{:request, pid, ref, {method, path,
  # headers, body}}`, then `{:body, ref, chunk}` and `{:body, ref, :eof}`
  # for a body from a stream, and `{:cancel, ref}`. The answers:
  # `{ref, :events, events}`, and `{ref, :sent}` when a chunk of the body is
  # on the network. See `Web.Dispatcher.HTTP.Exchange`.

  use GenServer

  alias Web.Dispatcher.HTTP.Exchange

  @registry Web.Dispatcher.HTTP.Registry
  @supervisor Web.Dispatcher.HTTP.Connections

  @unprocessed %Mint.HTTPError{module: Mint.HTTP2, reason: :unprocessed}

  @doc false
  def child_spec(origin) do
    %{id: {__MODULE__, origin}, start: {__MODULE__, :start_link, [origin]}, restart: :temporary}
  end

  @doc false
  def start_link(origin) do
    GenServer.start_link(__MODULE__, origin, name: {:via, Registry, {@registry, key(origin)}})
  end

  @doc "The process of the connection of an origin. It starts at the first request."
  @spec get({:http | :https, String.t(), :inet.port_number()}) :: pid()
  def get(origin) do
    case Registry.lookup(@registry, key(origin)) do
      [{pid, _value}] -> pid
      [] -> start(origin)
    end
  end

  defp start(origin) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, origin}) do
      {:ok, pid} -> pid
      # Two requests started the process at the same time.
      # coveralls-ignore-next-line
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp key(origin), do: {__MODULE__, origin}

  @impl true
  def init(origin) do
    state = %{
      origin: origin,
      conn: nil,
      failed: nil,
      # The settings of the server came: they come in its first frame.
      ready?: false,
      # The requests by the reference of the process of the request, the
      # references of the HTTP client, the monitors, and the queue.
      entries: %{},
      refs: %{},
      monitors: %{},
      queue: :queue.new()
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    {scheme, host, port} = state.origin

    options =
      scheme
      |> Exchange.connect_options([:http2])
      |> Keyword.merge(mode: :active, client_settings: [enable_push: false])

    case Exchange.mint_connect(scheme, host, port, options) do
      {:ok, conn} ->
        {:noreply, %{state | conn: conn}}

      # Each request in the mailbox gets the error, then the process
      # stops. A new request starts a new process.
      {:error, reason} ->
        Registry.unregister(@registry, key(state.origin))
        {:noreply, %{state | failed: reason}, 0}
    end
  end

  @impl true
  def handle_info(:timeout, %{failed: reason} = state) when reason != nil do
    {:stop, :normal, state}
  end

  def handle_info({:request, pid, ref, _request}, %{failed: reason} = state)
      when reason != nil do
    send(pid, {ref, :events, [{:error, reason}]})
    {:noreply, state, 0}
  end

  def handle_info(_message, %{failed: reason} = state) when reason != nil do
    {:noreply, state, 0}
  end

  def handle_info({:request, pid, ref, {method, path, headers, body}}, state) do
    monitor = Process.monitor(pid)

    entry = %{
      pid: pid,
      ref: ref,
      monitor: monitor,
      request: {method, path, headers},
      body: body,
      request_ref: nil,
      pending: "",
      body_end: :sent,
      ack?: false
    }

    state = %{
      state
      | entries: Map.put(state.entries, ref, entry),
        monitors: Map.put(state.monitors, monitor, ref),
        queue: :queue.in(ref, state.queue)
    }

    state |> start_queued() |> noreply()
  end

  def handle_info({:body, ref, chunk}, state) do
    case Map.fetch(state.entries, ref) do
      {:ok, entry} ->
        entry =
          if chunk == :eof,
            do: %{entry | body_end: :ready},
            else: %{entry | pending: chunk, ack?: true}

        state |> put_entry(entry) |> write(entry) |> check() |> noreply()

      # The response ended while the chunk was on its way.
      # coveralls-ignore-next-line
      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:cancel, ref}, state), do: state |> cancel(ref) |> check() |> noreply()

  # A request that ends removes its monitor, thus each monitor that stops is
  # of a request that runs.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    state |> cancel(Map.fetch!(state.monitors, monitor)) |> check() |> noreply()
  end

  def handle_info(message, state) do
    case Mint.HTTP.stream(state.conn, message) do
      :unknown ->
        state

      {:ok, conn, responses} ->
        %{state | conn: conn, ready?: true} |> deliver(responses) |> write_all() |> check()

      # The client does not ask the socket for the next message after an
      # error, for example a GOAWAY with an error code: the process asks
      # for it, thus it sees the close of the server.
      {:error, conn, reason, responses} ->
        state = %{state | conn: conn, ready?: true} |> deliver(responses)

        with true <- Mint.HTTP.open?(conn, :read),
             {:ok, conn} <- Mint.HTTP.set_mode(conn, :active) do
          check(%{state | conn: conn})
        else
          _closed -> fail_all(state, reason)
        end
    end
    |> noreply()
  end

  defp noreply({:stop, _reason, _state} = stop), do: stop
  defp noreply(state), do: {:noreply, state}

  # The requests in the queue start while the server allows more streams.
  # A write that failed closed the connection: its requests get their
  # errors, and the process stops.
  defp start_queued(state) do
    with {{:value, ref}, queue} <- :queue.out(state.queue),
         true <- stream_allowed?(state) do
      %{state | queue: queue} |> open_stream(Map.fetch!(state.entries, ref)) |> start_queued()
    else
      _no ->
        if Mint.HTTP.open?(state.conn, :read),
          do: state,
          else: fail_all(state, %Mint.TransportError{reason: :closed})
    end
  end

  # Before the settings of the server, the client does not know its limit:
  # the connection has one stream.
  defp stream_allowed?(%{conn: conn, ready?: ready?}) do
    limit = if ready?, do: Mint.HTTP2.get_server_setting(conn, :max_concurrent_streams), else: 1
    Mint.HTTP.open?(conn) and Mint.HTTP.open_request_count(conn) < limit
  end

  defp open_stream(state, entry) do
    {method, path, headers} = entry.request
    {argument, pending, body_end} = Exchange.body_argument(state.conn, entry.body)

    case Mint.HTTP.request(state.conn, method, path, headers, argument) do
      {:ok, conn, request_ref} ->
        entry = %{
          entry
          | request_ref: request_ref,
            pending: entry.pending <> pending,
            body_end: merge_end(entry.body_end, body_end)
        }

        %{state | conn: conn, refs: Map.put(state.refs, request_ref, entry.ref)}
        |> put_entry(entry)
        |> write(entry)

      # The write of the request failed: the server closed the socket, and
      # the close is not in the mailbox yet. The server did not get the
      # request, thus it goes again on a new connection. `stream_allowed?/1`
      # gives no request to a connection that Mint knows closed or full, and
      # a write has no time limit: each error here is the error of the
      # transport. Mint keeps the connection open after it: the process
      # closes it, and `start_queued/1` gives the other requests their
      # errors.
      {:error, conn, %Mint.TransportError{}} ->
        send(entry.pid, {entry.ref, :events, [{:error, @unprocessed}]})
        {:ok, conn} = Mint.HTTP.close(conn)
        %{state | conn: conn} |> remove(entry)
    end
  end

  # A body from a stream can have its end before its stream opens.
  defp merge_end(:ready, :waiting), do: :ready
  defp merge_end(_entry_end, body_end), do: body_end

  defp put_entry(state, entry), do: %{state | entries: Map.put(state.entries, entry.ref, entry)}

  # The bytes of a request body go in the window. The process of the
  # request gets `:sent` when its chunk is on the network.
  defp write(state, %{request_ref: nil}), do: state

  defp write(state, entry) do
    case Exchange.write_body(state.conn, entry.request_ref, entry.pending, entry.body_end) do
      {:ok, conn, pending, body_end} ->
        entry = %{entry | pending: pending, body_end: body_end}

        entry =
          if pending == "" and entry.ack? do
            send(entry.pid, {entry.ref, :sent})
            %{entry | ack?: false}
          else
            entry
          end

        put_entry(%{state | conn: conn}, entry)

      {:error, conn, reason} ->
        send(entry.pid, {entry.ref, :events, [{:error, reason}]})
        %{state | conn: conn} |> cancel(entry.ref)
    end
  end

  # A window can be larger after a message of the server.
  defp write_all(state) do
    state.entries
    |> Map.values()
    |> Enum.filter(&(&1.request_ref != nil and (&1.pending != "" or &1.body_end == :ready)))
    |> Enum.reduce(state, &write(&2, Map.fetch!(&2.entries, &1.ref)))
  end

  # The events of each response go to the process of its request.
  defp deliver(state, responses) do
    grouped =
      for response <- responses,
          {request_ref, event} <- [Exchange.event(response)],
          reduce: %{} do
        acc -> Map.update(acc, request_ref, [event], &[event | &1])
      end

    # The events of a request that was cancelled go away.
    for {request_ref, events} <- grouped,
        ref = Map.get(state.refs, request_ref),
        ref != nil,
        reduce: state do
      state ->
        entry = Map.fetch!(state.entries, ref)
        events = :lists.reverse(events)
        send(entry.pid, {entry.ref, :events, events})
        if Enum.any?(events, &final?/1), do: remove(state, entry), else: state
    end
  end

  defp final?(:done), do: true
  defp final?({:error, _reason}), do: true
  defp final?(_event), do: false

  defp cancel(state, ref) do
    case Map.fetch(state.entries, ref) do
      {:ok, %{request_ref: nil} = entry} ->
        remove(state, entry)

      {:ok, entry} ->
        # The result is `{:ok, conn}`, or `{:error, conn, reason}` for a
        # connection that closed: the next message tells it.
        conn = state.conn |> Mint.HTTP2.cancel_request(entry.request_ref) |> elem(1)
        remove(%{state | conn: conn}, entry)

      # The response ended while the cancel was on its way.
      # coveralls-ignore-start
      :error ->
        state
        # coveralls-ignore-stop
    end
  end

  defp remove(state, entry) do
    Process.demonitor(entry.monitor, [:flush])

    %{
      state
      | entries: Map.delete(state.entries, entry.ref),
        refs: Map.delete(state.refs, entry.request_ref),
        monitors: Map.delete(state.monitors, entry.monitor),
        queue: :queue.delete(entry.ref, state.queue)
    }
  end

  # After each change: the queue gets the free streams. A connection that
  # does not take new streams stops when no stream of it runs: the requests
  # in the queue go again on a new connection.
  defp check(state) do
    cond do
      not Mint.HTTP.open?(state.conn, :read) ->
        fail_all(state, %Mint.TransportError{reason: :closed})

      Mint.HTTP.open?(state.conn, :write) ->
        start_queued(state)

      true ->
        Registry.unregister(@registry, key(state.origin))

        if Enum.all?(Map.values(state.entries), &(&1.request_ref == nil)),
          do: fail_all(state, @unprocessed),
          else: state
    end
  end

  # A request in the queue did not go to the server: it gets the error
  # `:unprocessed`, and goes again on a new connection.
  defp fail_all(state, reason) do
    for {_ref, entry} <- state.entries do
      error = if entry.request_ref == nil, do: @unprocessed, else: reason
      send(entry.pid, {entry.ref, :events, [{:error, error}]})
    end

    {:stop, :normal, state}
  end
end
