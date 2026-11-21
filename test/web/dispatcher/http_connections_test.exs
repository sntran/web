defmodule Web.Dispatcher.HTTPConnectionsTest do
  # The connections of `Web.Dispatcher.HTTP`: the pool of an origin, the
  # shared HTTP/2 connection, and the network side of a request. The tests
  # stop processes at a known time and change the settings, thus they do
  # not run at the same time as other tests.
  use ExUnit.Case, async: false
  use Web

  alias Web.Dispatcher.HTTP.Exchange
  alias Web.Dispatcher.HTTP.Multiplex
  alias Web.Dispatcher.HTTP.Pool

  @moduletag capture_log: true

  @ssl_directory Path.expand("../../support/ssl", __DIR__)

  defmodule Server do
    @moduledoc false
    import Plug.Conn

    def init(options), do: options

    def call(conn, options) do
      {:ok, body, conn} = read_body(conn, length: 100_000_000)
      route(conn.request_path, conn, body, Keyword.fetch!(options, :test))
    end

    # The handler waits until the test releases it.
    defp route("/hold", conn, _body, test) do
      send(test, {:held, self()})

      receive do
        :release -> send_resp(conn, 200, "held")
        :close -> conn |> put_resp_header("connection", "close") |> send_resp(200, "closed")
      end
    end

    defp route("/size", conn, body, _test), do: send_resp(conn, 200, "#{byte_size(body)}")

    defp route("/echo-path" <> _rest, conn, _body, _test),
      do: send_resp(conn, 200, conn.request_path)

    defp route("/big", conn, _body, _test), do: send_resp(conn, 200, :binary.copy("x", 5_000_000))

    defp route("/big-redirect", conn, _body, _test) do
      conn |> put_resp_header("location", "/") |> send_resp(302, :binary.copy("r", 100_000))
    end

    defp route(_path, conn, _body, _test), do: send_resp(conn, 200, "ok")
  end

  defp start_server(options \\ []) do
    options =
      [plug: {Server, test: self()}, scheme: :http, port: 0, startup_log: false]
      |> Keyword.merge(options)

    id = make_ref()
    {:ok, server} = start_supervised({Bandit, options}, id: id)
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    scheme = Keyword.fetch!(options, :scheme)
    %{server: id, port: port, base: "#{scheme}://localhost:#{port}"}
  end

  defp start_tls_server(options) do
    start_server(
      [
        scheme: :https,
        certfile: Path.join(@ssl_directory, "test_server_cert.pem"),
        keyfile: Path.join(@ssl_directory, "test_server_key.pem")
      ] ++ options
    )
  end

  defp set_env(key, value) do
    previous = Application.get_env(:web, key)
    Application.put_env(:web, key, value)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:web, key),
        else: Application.put_env(:web, key, previous)
    end)
  end

  # Sets the HTTP versions, and starts the pools again. The functions for
  # the end of a test run in the opposite sequence: the pools start again
  # after the setting is restored.
  defp use_protocols(protocols) do
    on_exit(&restart_pools/0)
    set_env(:http_protocols, protocols)
    restart_pools()
  end

  defp restart_pools do
    :ok = Supervisor.terminate_child(Web.Supervisor, Web.Dispatcher.HTTP)
    {:ok, _pid} = Supervisor.restart_child(Web.Supervisor, Web.Dispatcher.HTTP)
  end

  defp trust_test_authority(protocols) do
    on_exit(&restart_pools/0)
    set_env(:tls_options, cacertfile: Path.join(@ssl_directory, "test_ca.pem"))
    use_protocols(protocols)
  end

  defp eventually(fun, attempts \\ 400) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  defp origin(port, scheme \\ :http), do: {scheme, "localhost", port}
  defp pool(%{port: port}), do: Pool.get(origin(port))
  defp idle(pool), do: :sys.get_state(pool).idle
  defp slots(pool), do: map_size(:sys.get_state(pool).slots)
  defp waiting(pool), do: :queue.len(:sys.get_state(pool).waiting)

  defp held(count) do
    for _index <- 1..count do
      assert_receive {:held, pid}, 5_000
      pid
    end
  end

  defp queue_length(pid), do: elem(Process.info(pid, :message_queue_len), 1)

  # The port of the socket that a process owns.
  defp port_of(pid) do
    Enum.find(:erlang.ports(), &(Port.info(&1, :connected) == {:connected, pid}))
  end

  defp exchange(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    :proplists.get_value({Exchange, :state}, dictionary)
  end

  # The 25 connections of the origin are in use.
  defp fill(context) do
    busy = for _index <- 1..25, do: fetch(context.base <> "/hold")
    {busy, held(25)}
  end

  defp finish(busy, handlers) do
    for handler <- handlers, do: send(handler, :release)
    for promise <- busy, do: assert(await(promise).status == 200)
  end

  describe "the pool of an origin" do
    setup do
      start_server()
    end

    test "gives a free connection to a request that waits", context do
      {busy, [first | rest]} = fill(context)
      pool = pool(context)
      assert slots(pool) == 25

      waiting = fetch(context.base <> "/")
      eventually(fn -> waiting(pool) == 1 end)

      send(first, :release)
      assert await(Response.text(await(waiting))) == "ok"

      finish(tl(busy), rest)
      eventually(fn -> length(idle(pool)) == 25 and slots(pool) == 0 end)
    end

    test "stops the wait of an aborted request", context do
      {busy, handlers} = fill(context)
      pool = pool(context)
      controller = AbortController.new()

      waiting = fetch(context.base <> "/", signal: controller.signal)
      eventually(fn -> waiting(pool) == 1 end)
      AbortController.abort(controller, :stop)

      assert catch_exit(await(waiting)) == :stop
      assert waiting(pool) == 0
      finish(busy, handlers)
    end

    test "removes a request whose process stops while it waits", context do
      {busy, handlers} = fill(context)
      pool = pool(context)

      waiting = fetch(context.base <> "/")
      eventually(fn -> waiting(pool) == 1 end)
      Process.exit(waiting.pid, :kill)

      eventually(fn -> waiting(pool) == 0 end)
      finish(busy, handlers)
    end

    test "gets back a connection that it gave to a request that aborted", context do
      {busy, [first | rest]} = fill(context)
      pool = pool(context)
      controller = AbortController.new()
      waiting = fetch(context.base <> "/", signal: controller.signal)
      eventually(fn -> waiting(pool) == 1 end)

      # The abort is in the mailbox before the connection.
      :erlang.suspend_process(waiting.pid)
      AbortController.abort(controller, :stop)
      eventually(fn -> queue_length(waiting.pid) > 0 end)
      count = queue_length(waiting.pid)
      send(first, :release)
      eventually(fn -> queue_length(waiting.pid) > count end)
      :erlang.resume_process(waiting.pid)

      assert catch_exit(await(waiting)) == :stop
      eventually(fn -> length(idle(pool)) == 1 and waiting(pool) == 0 end)
      finish(tl(busy), rest)
    end

    test "gets back a slot that it gave to a request that aborted", context do
      {busy, [first | rest]} = fill(context)
      pool = pool(context)
      controller = AbortController.new()
      waiting = fetch(context.base <> "/", signal: controller.signal)
      eventually(fn -> waiting(pool) == 1 end)

      :erlang.suspend_process(waiting.pid)
      AbortController.abort(controller, :stop)
      eventually(fn -> queue_length(waiting.pid) > 0 end)
      count = queue_length(waiting.pid)

      # The connection of the first request closes: the slot goes to the
      # request that waits.
      send(first, :close)
      eventually(fn -> queue_length(waiting.pid) > count end)
      :erlang.resume_process(waiting.pid)

      assert catch_exit(await(waiting)) == :stop
      eventually(fn -> slots(pool) == 24 end)
      finish(tl(busy), rest)
    end

    test "does not give an idle connection whose socket closed", context do
      assert await(fetch(context.base <> "/")).status == 200
      pool = pool(context)
      eventually(fn -> length(idle(pool)) == 1 end)

      [conn] = idle(pool)
      :erlang.port_close(Mint.HTTP.get_socket(conn))

      assert await(Response.text(await(fetch(context.base <> "/")))) == "ok"
      eventually(fn -> length(idle(pool)) == 1 and idle(pool) != [conn] end)
    end

    test "does not keep a connection whose socket closed on its way back", context do
      promise = fetch(context.base <> "/hold")
      [handler] = held(1)
      pool = pool(context)
      port = port_of(promise.pid)

      :erlang.suspend_process(pool)
      send(handler, :release)
      eventually(fn -> Port.info(port, :connected) == {:connected, pool} end)
      :erlang.port_close(port)
      :erlang.resume_process(pool)

      assert await(promise).status == 200
      eventually(fn -> idle(pool) == [] and slots(pool) == 0 end)
    end

    test "sends the request again on a new connection when the socket of an idle one closed",
         context do
      {busy, [first | rest]} = fill(context)
      pool = pool(context)
      waiting = fetch(context.base <> "/")
      eventually(fn -> waiting(pool) == 1 end)

      # The pool gives the connection, and its socket closes before the
      # request is on it.
      :erlang.suspend_process(waiting.pid)
      send(first, :release)
      eventually(fn -> port_of(waiting.pid) != nil end)
      :erlang.port_close(port_of(waiting.pid))
      :erlang.resume_process(waiting.pid)

      send(hd(rest), :release)
      assert await(Response.text(await(waiting))) == "ok"
      finish(tl(tl(busy)), tl(rest))
    end

    test "stops the connect of an aborted request, and gets back its slot" do
      # The server accepts the connection, and does not answer: the TLS
      # connect waits.
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listener)
      spawn_link(fn -> silent_server(listener) end)

      controller = AbortController.new()
      promise = fetch("https://localhost:#{port}/", signal: controller.signal)
      pool = Pool.get(origin(port, :https))
      eventually(fn -> slots(pool) == 1 end)

      AbortController.abort(controller, :stop)
      assert catch_exit(await(promise)) == :stop
      eventually(fn -> slots(pool) == 0 end)
    end

    test "removes the idle connections that the server closes", _context do
      context = start_server(thousand_island_options: [read_timeout: 200])
      promises = for _index <- 1..2, do: fetch(context.base <> "/hold")
      for handler <- held(2), do: send(handler, :release)
      for promise <- promises, do: assert(await(promise).status == 200)

      pool = pool(context)
      eventually(fn -> length(idle(pool)) == 2 end)

      # A message with no use has no effect.
      send(pool, :no_use)
      assert length(idle(pool)) == 2

      eventually(fn -> idle(pool) == [] end)
    end
  end

  describe "a request on a connection of the pool" do
    setup do
      start_server()
    end

    test "closes the connection of a redirect with a large body, and follows it", context do
      # With no compression, the body of the redirect is larger than the
      # limit.
      identity = [{"accept-encoding", "identity"}]
      response = await(fetch(context.base <> "/big-redirect", headers: identity))
      assert {response.status, response.redirected} == {200, true}
      assert await(Response.text(response)) == "ok"
    end

    test "decodes a compressed body that expands much only as the reader takes it", context do
      # The server compresses the 5 MB of the body to a few KB.
      response = await(fetch(context.base <> "/big"))
      {:held, process} = response.body.lazy.source
      eventually(fn -> exchange(process).received? end)

      {:dictionary, dictionary} = Process.info(process, :dictionary)
      assert :proplists.get_value({Exchange, :inflight}, dictionary) < 200_000
      assert byte_size(await(Response.text(response))) == 5_000_000
    end

    test "gives a full compressed body when the socket closes after the end", context do
      # The full body came. The decoder keeps it until the reader takes it.
      response = await(fetch(context.base <> "/big"))
      {:held, process} = response.body.lazy.source
      eventually(fn -> exchange(process).received? end)

      :erlang.port_close(port_of(process))
      assert byte_size(await(Response.text(response))) == 5_000_000
    end

    test "fails when the socket closes while the body waits for a reader", context do
      response = await(fetch(context.base <> "/big", headers: [{"accept-encoding", "identity"}]))
      {:held, process} = response.body.lazy.source
      eventually(fn -> exchange(process).paused? end)

      :erlang.port_close(port_of(process))

      assert %TypeError{message: "The response body is not complete."} =
               catch_exit(await(Response.text(response)))
    end

    test "fails when the socket closes while the request body goes", context do
      test = self()
      gate = make_ref()

      # The source gives the second chunk when the test lets it.
      chunks =
        Stream.map(1..2, fn index ->
          if index == 2 do
            send(test, {:second, gate, self()})

            receive do
              {^gate, :go} -> :ok
            end
          end

          "chunk"
        end)

      promise =
        fetch(context.base <> "/size",
          method: "POST",
          body: ReadableStream.from(chunks),
          duplex: "half"
        )

      assert_receive {:second, ^gate, source}, 2_000
      :erlang.port_close(port_of(promise.pid))
      send(source, {gate, :go})

      assert %TypeError{message: "fetch failed"} = catch_exit(await(promise))
    end

    test "rejects a header value that the HTTP client refuses", context do
      # The HTTP client takes the visible ASCII characters only.
      error = catch_exit(await(fetch(context.base <> "/", headers: [{"x-test", "é"}])))
      assert %TypeError{cause: %Mint.HTTPError{reason: {:invalid_header_value, _, _}}} = error
    end

    test "sends the path of the URL with no change", context do
      response = await(fetch(context.base <> "/echo-path/a|b"))
      assert await(Response.text(response)) == "/echo-path/a|b"
    end
  end

  describe "a connection that the server closes after it was idle" do
    # The server answers the first request on a connection, and closes the
    # connection when it gets the second. Then it answers the second request
    # on a new connection.
    defp closing_server do
      test = self()
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listener)

      spawn_link(fn ->
        {:ok, first} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(first, 0)
        :ok = :gen_tcp.send(first, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nfirst")
        {:ok, _request} = :gen_tcp.recv(first, 0)
        :gen_tcp.close(first)

        {:ok, second} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(second, 0)
        # The message comes before the response, thus the test has it when
        # it has the response.
        send(test, :answered)
        :ok = :gen_tcp.send(second, "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nsecond")
        read_until_closed(second)
      end)

      "http://localhost:#{port}/"
    end

    # The server keeps the connection open until the client closes it.
    defp read_until_closed(socket) do
      case :gen_tcp.recv(socket, 0) do
        {:ok, _data} -> read_until_closed(socket)
        {:error, _reason} -> :ok
      end
    end

    test "gets the request again on a new connection" do
      url = closing_server()
      assert await(Response.text(await(fetch(url)))) == "first"
      assert await(Response.text(await(fetch(url)))) == "second"
      assert_received :answered
    end

    test "does not send a body from a stream again" do
      url = closing_server()
      assert await(Response.text(await(fetch(url)))) == "first"

      # The reason of the error depends on the time of the close: the client
      # can see it when it sends the body (for example `:einval`), or when it
      # reads the response (`:closed`). A request that goes again gets the
      # answer "second" and does not fail.
      body = ReadableStream.from(["one", "two"])
      error = catch_exit(await(fetch(url, method: "POST", body: body, duplex: "half")))
      assert %TypeError{cause: %Mint.TransportError{}} = error
    end
  end

  # The window of HTTP/2 is 65_535 bytes at the start of a connection.
  describe "the HTTP/2 connection of a TLS origin with the two versions" do
    setup do
      trust_test_authority([:http1, :http2])
      start_tls_server([])
    end

    test "sends a body from memory that is larger than the window", context do
      body = :binary.copy("b", 200_000)
      response = await(fetch(context.base <> "/size", method: "POST", body: body))
      assert {response.status_text, await(Response.text(response))} == {"", "200000"}
    end

    test "keeps an idle connection that gets a frame from the server", context do
      assert await(fetch(context.base <> "/")).status == 200
      pool = Pool.get(origin(context.port, :https))
      eventually(fn -> length(idle(pool)) == 1 end)

      # The pool sends a ping on the idle connection. The answer of the
      # server comes to the pool.
      :sys.replace_state(pool, fn state ->
        [conn] = state.idle
        {:ok, conn, _ref} = Mint.HTTP2.ping(conn)
        %{state | idle: [conn]}
      end)

      eventually(fn -> match?([%Mint.HTTP2{ping_queue: {[], []}}], idle(pool)) end)
      assert await(fetch(context.base <> "/")).status == 200
    end

    test "sends a body from a stream that is larger than the window", context do
      body = ReadableStream.from([:binary.copy("a", 100_000), :binary.copy("b", 100_000)])

      response =
        await(fetch(context.base <> "/size", method: "POST", body: body, duplex: "half"))

      assert await(Response.text(response)) == "200000"
    end
  end

  describe "a connection that the server closes for new streams" do
    test "goes away, and the next request uses a new one" do
      trust_test_authority([:http1, :http2])
      context = start_tls_server(http_2_options: [max_requests: 1])

      for _index <- 1..3 do
        assert await(Response.text(await(fetch(context.base <> "/")))) == "ok"
      end
    end
  end

  describe "the shared HTTP/2 connection" do
    setup do
      use_protocols([:http2])
      start_server()
    end

    defp multiplex(context), do: Multiplex.get(origin(context.port))

    test "cancels the stream of an aborted request", context do
      controller = AbortController.new()
      promise = fetch(context.base <> "/hold", signal: controller.signal)
      [handler] = held(1)
      mux = multiplex(context)
      assert map_size(:sys.get_state(mux).entries) == 1

      AbortController.abort(controller, :stop)
      assert catch_exit(await(promise)) == :stop
      eventually(fn -> :sys.get_state(mux).entries == %{} end)
      send(handler, :release)

      # A message with no use has no effect.
      send(mux, :no_use)
      assert await(fetch(context.base <> "/")).status == 200
    end

    test "cancels the stream of a request whose process stops", context do
      promise = fetch(context.base <> "/hold")
      [handler] = held(1)
      mux = multiplex(context)

      Process.exit(promise.pid, :kill)
      eventually(fn -> :sys.get_state(mux).entries == %{} end)
      send(handler, :release)
    end

    test "gives an error to each request when the connection closes", context do
      promise = fetch(context.base <> "/hold")
      [_handler] = held(1)
      mux = multiplex(context)
      ref = Process.monitor(mux)

      :ok = stop_supervised(context.server)
      assert %TypeError{} = catch_exit(await(promise))
      assert_receive {:DOWN, ^ref, :process, ^mux, :normal}, 2_000
    end

    test "sends a request again on a new connection when its write fails on a closed socket",
         context do
      held = fetch(context.base <> "/hold")
      [handler] = held(1)
      mux = multiplex(context)
      ref = Process.monitor(mux)

      # The socket closes with no message to the process of the connection:
      # the process still thinks that the connection is open, and the write
      # of the next request fails. The server did not get that request, thus
      # it goes again. The server can have processed the request on the
      # network: it gets the error.
      :erlang.port_close(Mint.HTTP.get_socket(:sys.get_state(mux).conn))

      assert await(Response.text(await(fetch(context.base <> "/")))) == "ok"
      assert %TypeError{cause: %Mint.TransportError{reason: :closed}} = catch_exit(await(held))
      assert_receive {:DOWN, ^ref, :process, ^mux, :normal}, 2_000
      send(handler, :release)
    end

    test "gives the error of the process of the connection when it stops", context do
      promise = fetch(context.base <> "/hold")
      [handler] = held(1)

      Process.exit(multiplex(context), :kill)

      assert %TypeError{cause: {:connection_process_stopped, :killed}} =
               catch_exit(await(promise))

      send(handler, :release)
    end

    test "sends a body from memory and from a stream that are larger than the window",
         context do
      body = :binary.copy("m", 200_000)
      response = await(fetch(context.base <> "/size", method: "POST", body: body))
      assert await(Response.text(response)) == "200000"

      stream = ReadableStream.from([:binary.copy("s", 100_000), :binary.copy("t", 100_000)])

      response =
        await(fetch(context.base <> "/size", method: "POST", body: stream, duplex: "half"))

      assert await(Response.text(response)) == "200000"
    end

    test "sends a request that a stopped process of the connection did not take on a new one",
         context do
      # A process with the name of the connection of the origin. It stops
      # with the request in its mailbox.
      test = self()

      fake =
        spawn(fn ->
          key = {Multiplex, origin(context.port)}
          {:ok, _owner} = Registry.register(Web.Dispatcher.HTTP.Registry, key, nil)
          send(test, :registered)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :registered
      promise = fetch(context.base <> "/")
      eventually(fn -> queue_length(fake) == 1 end)
      send(fake, :stop)

      assert await(Response.text(await(promise))) == "ok"
    end

    test "gives an error to a request whose body cannot go on the connection", context do
      # The frames of the start of the connection come before the request.
      assert await(fetch(context.base <> "/")).status == 200
      mux = multiplex(context)
      test = self()
      gate = make_ref()

      # The source gives the second chunk when the test lets it.
      chunks =
        Stream.map(1..2, fn index ->
          if index == 2 do
            send(test, {:second, gate, self()})

            receive do
              {^gate, :go} -> :ok
            end
          end

          "chunk"
        end)

      body = ReadableStream.from(chunks)
      promise = fetch(context.base <> "/size", method: "POST", body: body, duplex: "half")
      assert_receive {:second, ^gate, source}, 2_000

      # When its handler reads the first chunk, the server makes the window
      # of the stream larger. Then the second chunk is the only message of
      # the process of the connection when the socket closes: the process
      # writes it.
      eventually(fn -> stream_window(mux, promise.pid) > 65_535 end)

      ref = Process.monitor(mux)
      socket = Mint.HTTP.get_socket(:sys.get_state(mux).conn)
      :erlang.suspend_process(mux)
      send(source, {gate, :go})

      eventually(fn ->
        match?({:messages, [{:body, _ref, "chunk"}]}, Process.info(mux, :messages))
      end)

      :erlang.port_close(socket)
      :erlang.resume_process(mux)

      assert %TypeError{} = catch_exit(await(promise))
      assert_receive {:DOWN, ^ref, :process, ^mux, :normal}, 2_000
    end

    defp stream_window(mux, pid) do
      state = :sys.get_state(mux)
      [entry] = for {_ref, %{pid: ^pid} = entry} <- state.entries, do: entry
      Mint.HTTP2.get_window_size(state.conn, {:request, entry.request_ref})
    end

    test "stops when the server closes it for new streams, and the request goes on a new one" do
      context = start_server(http_2_options: [max_requests: 1])
      assert await(fetch(context.base <> "/")).status == 200
      mux = multiplex(context)
      ref = Process.monitor(mux)

      # The server refuses the second stream: the request did not run, and
      # goes on a new connection.
      assert await(Response.text(await(fetch(context.base <> "/")))) == "ok"
      assert_receive {:DOWN, ^ref, :process, ^mux, :normal}, 2_000
    end
  end

  describe "the queue of the shared HTTP/2 connection" do
    setup do
      use_protocols([:http2])
      start_server(http_2_options: [default_local_settings: [max_concurrent_streams: 1]])
    end

    # The settings of the server come after the connect: the first request
    # waits for them.
    setup context do
      assert await(fetch(context.base <> "/")).status == 200
      :ok
    end

    test "starts a request when a stream ends", context do
      first = fetch(context.base <> "/hold")
      [handler] = held(1)
      mux = Multiplex.get(origin(context.port))

      # The empty body ends before its stream starts.
      second =
        fetch(context.base <> "/size",
          method: "POST",
          body: ReadableStream.from([]),
          duplex: "half"
        )

      controller = AbortController.new()
      third = fetch(context.base <> "/", signal: controller.signal)
      eventually(fn -> :queue.len(:sys.get_state(mux).queue) == 2 end)

      # A request in the queue can stop.
      AbortController.abort(controller, :stop)
      assert catch_exit(await(third)) == :stop
      eventually(fn -> :queue.len(:sys.get_state(mux).queue) == 1 end)

      release_stream(handler, mux)
      assert await(first).status == 200
      assert await(Response.text(await(second))) == "0"
    end

    test "keeps a chunk of a stream body until its stream starts", context do
      first = fetch(context.base <> "/hold")
      [handler] = held(1)

      second =
        fetch(context.base <> "/size",
          method: "POST",
          body: ReadableStream.from(["one", "two"]),
          duplex: "half"
        )

      mux = Multiplex.get(origin(context.port))

      try do
        eventually(fn -> match?([%{pending: "one"}], queued(mux)) end)
      rescue
        error -> flunk("#{Exception.message(error)}: #{inspect(:sys.get_state(mux))}")
      end

      release_stream(handler, mux)
      assert await(first).status == 200
      assert await(Response.text(await(second))) == "6"
    end

    defp queued(mux) do
      state = :sys.get_state(mux)
      for ref <- :queue.to_list(state.queue), do: state.entries[ref]
    end

    # The server counts a stream until the process of its handler stops.
    # The client can see the end of the stream before that time. Then a new
    # stream gets a refusal. Thus the test suspends the process of the
    # shared connection until the server removed the stream. The process of
    # the handler is linked to the process of the server connection.
    defp release_stream(handler, mux) do
      {:parent, server} = Process.info(handler, :parent)
      monitor = Process.monitor(handler)
      :erlang.suspend_process(mux)
      send(handler, :release)
      assert_receive {:DOWN, ^monitor, :process, ^handler, _reason}, 2_000

      # The server has the exit message of the handler, and then the
      # message of the test.
      eventually(fn -> handler not in elem(Process.info(server, :links), 1) end)
      :sys.get_state(server)
      :erlang.resume_process(mux)
    end
  end

  describe "the connect of the shared HTTP/2 connection" do
    setup do
      use_protocols([:http2])
      set_env(:connect_timeout, 300)

      # The server accepts the connection, and does not answer.
      # A TLS connect waits for the answer of the server.
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listener)
      server = spawn_link(fn -> silent_server(listener) end)
      %{base: "https://localhost:#{port}", server: server, origin: origin(port, :https)}
    end

    defp silent_server(listener) do
      {:ok, _socket} = :gen_tcp.accept(listener)
      silent_server(listener)
    end

    test "gives its failure to each request that waits", context do
      controller = AbortController.new()
      aborted = fetch(context.base <> "/", signal: controller.signal)
      waiting = fetch(context.base <> "/")

      # The two requests wait in the mailbox while the process connects.
      # Then the cancel of the abort waits there too.
      eventually(fn ->
        case Registry.lookup(Web.Dispatcher.HTTP.Registry, {Multiplex, context.origin}) do
          [{mux, _value}] -> queue_length(mux) == 2
          [] -> false
        end
      end)

      AbortController.abort(controller, :stop)
      assert catch_exit(await(aborted)) == :stop
      assert %TypeError{} = catch_exit(await(waiting))
    end
  end

  describe "the events of the HTTP client" do
    test "have no reference, and a response that is not of a request has no event" do
      ref = make_ref()
      assert Exchange.event({:error, ref, :reset}) == {ref, {:error, :reset}}
      assert Exchange.event({:pong, ref}) == nil
    end
  end
end
