# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule Web.Dispatcher.TCPTest do
  use ExUnit.Case, async: true

  import Web, only: [await: 1]

  alias Web.Dispatcher.TCP
  alias Web.Headers
  alias Web.Internal.Envelope
  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultController
  alias Web.Request
  alias Web.Socket

  defmodule TCPServer do
    # credo:disable-for-next-line
    def start_link(
          response_data \\ "hello\nworld",
          chunking \\ false,
          drop \\ false,
          observer \\ nil
        ) do
      parent = self()

      Task.start_link(fn ->
        # Port 0 lets the OS pick an available port
        {:ok, listen_socket} =
          :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

        {:ok, port} = :inet.port(listen_socket)
        send(parent, {:port, port})

        {:ok, socket} = :gen_tcp.accept(listen_socket)

        if drop do
          :gen_tcp.close(socket)
          :gen_tcp.close(listen_socket)
        else
          case {chunking, response_data} do
            {true, _} ->
              :gen_tcp.send(socket, "he")
              notify_chunk_sent(observer, "he")
              :gen_tcp.send(socket, "llo")
              notify_chunk_sent(observer, "llo")

            {false, chunks} when is_list(chunks) ->
              Enum.each(chunks, fn
                {:sleep, ms} ->
                  Process.sleep(ms)

                chunk ->
                  :gen_tcp.send(socket, chunk)
                  notify_chunk_sent(observer, chunk)
              end)

            {false, _} ->
              :gen_tcp.send(socket, response_data)
              notify_chunk_sent(observer, response_data)
          end

          if observer do
            case :gen_tcp.recv(socket, 0, 200) do
              {:error, :closed} -> send(observer, :tcp_client_closed)
              _ -> :ok
            end
          end

          :gen_tcp.close(socket)
          :gen_tcp.close(listen_socket)
        end
      end)

      receive do
        {:port, port} -> port
      after
        1000 -> raise "TCPServer failed to start"
      end
    end

    defp notify_chunk_sent(nil, _chunk), do: :ok
    defp notify_chunk_sent(observer, chunk), do: send(observer, {:tcp_server_sent, chunk})
  end

  defmodule ReaderReplyServer do
    @behaviour :gen_statem

    def start_link(reply) do
      :gen_statem.start_link(__MODULE__, reply, [])
    end

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init(reply) do
      {:ok, :ready, reply}
    end

    @impl true
    def handle_event({:call, from}, {:read, _pid}, _state, reply) do
      {:keep_state, reply, [{:reply, from, reply}]}
    end

    def handle_event(_type, _content, _state, reply) do
      {:keep_state, reply}
    end
  end

  test "fetch/1 handles standard tcp scheme and yields chunks dynamically" do
    port = TCPServer.start_link("", true)

    req = Request.new("tcp://localhost:#{port}", body: "sent body payload")
    {:ok, resp} = TCP.fetch(req)

    assert resp.status == 200
    chunks = resp.body |> Enum.to_list()
    assert Enum.join(chunks) == "hello"
  end

  test "fetch/1 writes request bodies for non-GET methods" do
    parent = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)

    Task.start_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      assert {:ok, "sent body payload"} = :gen_tcp.recv(socket, 0, 1_000)
      send(parent, :request_body_received)
      :ok = :gen_tcp.send(socket, "ok")
      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end)

    req = Request.new("tcp://localhost:#{port}", method: "POST", body: "sent body payload")
    {:ok, resp} = TCP.fetch(req)

    assert Enum.join(resp.body) == "ok"
    assert_receive :request_body_received, 1_000
  end

  test "fetch/1 accepts empty binary request bodies for non-GET methods" do
    port = TCPServer.start_link("ok", false)

    req = raw_request("tcp://localhost:#{port}", "POST", "")
    {:ok, resp} = TCP.fetch(req)

    assert Enum.join(resp.body) == "ok"
  end

  test "fetch/1 accepts nil request bodies for non-GET methods" do
    port = TCPServer.start_link("ok", false)

    req = raw_request("tcp://localhost:#{port}", "POST", nil)
    {:ok, resp} = TCP.fetch(req)

    assert Enum.join(resp.body) == "ok"
  end

  test "fetch/1 rejects non-iodata enumerable request bodies" do
    req = raw_request("tcp://localhost:0", "POST", Stream.map([97, :bad], & &1))

    assert_raise Web.TypeError, "body is not readable", fn ->
      TCP.fetch(req)
    end
  end

  test "fetch/1 handles remote identifier style URL correctly without body" do
    port = TCPServer.start_link("remote_resp", false)

    req = Request.new("remote:localhost:#{port}/path-item")
    {:ok, resp} = TCP.fetch(req)

    chunks = resp.body |> Enum.to_list()
    assert Enum.join(chunks) == "remote_resp"
  end

  test "fetch/1 parses missing port accurately defaulting to 80 erroring as appropriate" do
    req = Request.new("tcp://localhost_nxdomain/path")
    assert {:error, _} = TCP.fetch(req)
  end

  test "fetch/1 parses rclone style urls without an explicit port by defaulting to 80" do
    req = Request.new("remote:localhost/path")
    assert {:error, _} = TCP.fetch(req)
  end

  test "fetch/1 streaming yields appropriately on clean closed termination" do
    # Drop immediately
    port = TCPServer.start_link("data", false, true)

    req = Request.new("tcp://localhost:#{port}")
    {:ok, resp} = TCP.fetch(req)
    chunks = resp.body |> Enum.to_list()
    assert chunks == []
  end

  test "fetch/1 retries after socket timeouts while waiting for data" do
    port = TCPServer.start_link([{:sleep, 100}, "data"])

    req = Request.new("tcp://localhost:#{port}")
    {:ok, resp} = TCP.fetch(req)

    assert Enum.to_list(resp.body) == ["data"]
  end

  test "fetch/1 propagates paused consumer backpressure into the socket passive mode" do
    chunk = String.duplicate("x", 8_192)

    chunks =
      List.duplicate(chunk, 32)
      |> Kernel.++([{:sleep, 500}])

    port = TCPServer.start_link(chunks, false, false, self())

    req = Request.new("tcp://localhost:#{port}")
    {:ok, resp} = TCP.fetch(req)
    socket = dispatcher_socket(resp.body)

    assert_eventually(
      fn ->
        info = socket_debug(socket)
        info.active == false and info.desired_size <= 0 and info.queued_size >= 65_536
      end,
      120
    )

    assert :ok = Task.await(ReadableStream.cancel(resp.body, :backpressure_proven).task, 1_000)
    assert_receive :tcp_client_closed, 1_000
  end

  test "pull closure closes the bridge when the abort signal is already set" do
    controller = Web.AbortController.new()
    {bridge_pid, socket} = start_debug_bridge([{:sleep, 200}, "late"], controller.signal)
    source = TCP.__debug_body_source__(bridge_pid, socket, controller.signal)
    proxy = proxy_stream()

    assert :ok = Web.AbortController.abort(controller, :signal_aborted)
    assert :ok = source.pull.(controller_for(proxy))
    assert Enum.to_list(proxy) == []
    assert_receive :tcp_client_closed, 1_000
  end

  test "bridge pull promise resolves when the bridge dies after accepting demand" do
    controller = Web.AbortController.new()
    {bridge_pid, socket} = start_debug_bridge([{:sleep, 500}, "late"], controller.signal)
    source = TCP.__debug_body_source__(bridge_pid, socket, controller.signal)
    proxy = proxy_stream()
    assert :ok = source.start.(controller_for(proxy))

    parent = self()

    pull_task =
      Task.async(fn ->
        promise = source.pull.(controller_for(proxy))
        send(parent, :debug_pull_started)
        await(promise)
      end)

    assert_receive :debug_pull_started, 1_000
    Process.exit(bridge_pid, :kill)

    assert :ok = Task.await(pull_task, 1_000)
    _ = Socket.close(socket)
    assert_receive :tcp_client_closed, 1_000
  end

  test "pull closure resolves immediately when the bridge is already gone" do
    {bridge_pid, socket} = start_debug_bridge([{:sleep, 500}, "late"])
    source = TCP.__debug_body_source__(bridge_pid, socket, nil)
    Process.exit(bridge_pid, :kill)

    assert :ok = await(source.pull.(controller_for(proxy_stream())))
    _ = Socket.close(socket)
    assert_receive :tcp_client_closed, 1_000
  end

  test "bridge queues demand while no controller is registered yet" do
    {bridge_pid, socket} = start_debug_bridge([{:sleep, 500}, "late"], nil)
    reply_ref = make_ref()

    send(bridge_pid, {:pull, {self(), reply_ref}})
    refute_receive {^reply_ref, :ok}, 100

    send(bridge_pid, {:cancel, :manual_cleanup})
    assert_receive :tcp_client_closed, 1_000
    _ = socket
  end

  test "bridge treats readable cancellation as a clean end-of-stream" do
    {bridge_pid, socket} = start_debug_bridge([{:sleep, 500}, "late"], nil)
    source = TCP.__debug_body_source__(bridge_pid, socket, nil)
    proxy = proxy_stream()
    assert :ok = source.start.(controller_for(proxy))
    Process.sleep(25)

    parent = self()

    pull_task =
      Task.async(fn ->
        promise = source.pull.(controller_for(proxy))
        send(parent, :debug_pull_started)
        await(promise)
      end)

    assert_receive :debug_pull_started, 1_000
    Process.sleep(50)
    assert :ok = await(ReadableStream.cancel(socket.readable, :bridge_cancelled))
    assert :ok = Task.await(pull_task, 1_000)
    assert Enum.to_list(proxy) == []
    assert_receive :tcp_client_closed, 1_000
  end

  test "bridge closes cleanly when the socket readable crashes mid-pull" do
    {bridge_pid, socket} = start_debug_bridge([{:sleep, 500}, "late"], nil)
    source = TCP.__debug_body_source__(bridge_pid, socket, nil)
    proxy = proxy_stream()
    assert :ok = source.start.(controller_for(proxy))
    Process.sleep(25)

    parent = self()

    pull_task =
      Task.async(fn ->
        promise = source.pull.(controller_for(proxy))
        send(parent, :debug_pull_started)
        await(promise)
      end)

    assert_receive :debug_pull_started, 1_000
    Process.sleep(50)
    Process.exit(socket.readable.controller_pid, :kill)

    assert :ok = Task.await(pull_task, 1_000)
    refute Process.alive?(bridge_pid)
    assert Enum.to_list(proxy) == []
    assert_receive :tcp_client_closed, 1_000
  end

  test "fetch/1 treats socket readable cancellation as a clean response end" do
    port = TCPServer.start_link([{:sleep, 500}, "late"], false, false, self())

    req = Request.new("tcp://localhost:#{port}")
    {:ok, resp} = TCP.fetch(req)
    socket = dispatcher_socket(resp.body)

    read_task = Task.async(fn -> Enum.to_list(resp.body) end)

    Process.sleep(50)
    assert :ok = await(ReadableStream.cancel(socket.readable, :bridge_cancelled))
    assert {:ok, []} = Task.yield(read_task, 1_000)
    assert_receive :tcp_client_closed, 1_000
  end

  test "fetch/1 closes cleanly when the underlying socket readable dies mid-pull" do
    port = TCPServer.start_link([{:sleep, 500}, "late"], false, false, self())

    req = Request.new("tcp://localhost:#{port}")
    {:ok, resp} = TCP.fetch(req)
    socket = dispatcher_socket(resp.body)

    read_task = Task.async(fn -> Enum.to_list(resp.body) end)

    Process.sleep(50)
    Process.exit(socket.readable.controller_pid, :kill)

    assert {:ok, []} = Task.yield(read_task, 1_000)
    assert_receive :tcp_client_closed, 1_000
  end

  test "__debug_await_socket_chunk__/1 maps socket readable cancellation to done" do
    {:ok, pid} = ReaderReplyServer.start_link({:error, {:readable_cancel, :bridge_cancelled}})
    reader = %Web.ReadableStreamDefaultReader{controller_pid: pid}

    assert {:done, :bridge_cancelled} = TCP.__debug_await_socket_chunk__(reader)
  end

  test "__debug_await_socket_chunk__/1 maps non-cancel reader failures to done" do
    port = TCPServer.start_link([{:sleep, 500}, "late"], false, false, self())
    socket = Web.connect("localhost:#{port}")
    assert %{remoteAddress: _remote_address} = await(socket.opened)

    reader = ReadableStream.get_reader(socket.readable)
    read_task = Task.async(fn -> TCP.__debug_await_socket_chunk__(reader) end)

    Process.sleep(50)
    Process.exit(socket.readable.controller_pid, :kill)

    assert {:ok, {:done, reason}} = Task.yield(read_task, 1_000)
    assert reason != :bridge_cancelled
    _ = Socket.close(socket)
    assert_receive :tcp_client_closed, 1_000
  end

  test "bridge abort messages cancel the registered proxy controller" do
    {bridge_pid, socket} = start_debug_bridge([{:sleep, 500}, "late"], nil)
    source = TCP.__debug_body_source__(bridge_pid, socket, nil)
    proxy = proxy_stream()
    assert :ok = source.start.(controller_for(proxy))

    send(bridge_pid, {:abort, :forced_abort})

    assert Enum.to_list(proxy) == []
    assert_receive :tcp_client_closed, 1_000
  end

  test "fetch/1 aborts an in-flight tcp stream and closes the socket" do
    controller = Web.AbortController.new()
    port = TCPServer.start_link([{:sleep, 200}, "data"], false, false, self())

    req = Request.new("tcp://localhost:#{port}", signal: controller.signal)
    {:ok, resp} = TCP.fetch(req)

    task = Task.async(fn -> Enum.to_list(resp.body) end)

    Process.sleep(50)
    assert :ok = Web.AbortController.abort(controller, :timeout)

    assert {:ok, []} = Task.yield(task, 1000)
    assert_receive :tcp_client_closed, 1000
  end

  test "fetch/1 returns a readable stream body that closes the socket when canceled" do
    port = TCPServer.start_link([{:sleep, 200}, "data"], false, false, self())

    req = Request.new("tcp://localhost:#{port}")
    {:ok, resp} = TCP.fetch(req)

    assert %ReadableStream{} = resp.body
    assert :ok = Task.await(ReadableStream.cancel(resp.body, :manual_cancel).task, 1_000)
    assert_receive :tcp_client_closed, 1_000
  end

  test "fetch/1 closes the socket when the response reader owner dies" do
    port = TCPServer.start_link([{:sleep, 200}, "data"], false, false, self())

    req = Request.new("tcp://localhost:#{port}")
    {:ok, resp} = TCP.fetch(req)
    parent = self()

    reader_owner =
      spawn(fn ->
        _reader = ReadableStream.get_reader(resp.body)
        send(parent, :reader_locked)

        receive do
          :keep_alive -> :ok
        end
      end)

    assert_receive :reader_locked, 1_000
    Process.exit(reader_owner, :kill)
    assert_receive :tcp_client_closed, 1_000
  end

  test "fetch/1 halts before consuming when the signal is already aborted" do
    controller = Web.AbortController.new()
    port = TCPServer.start_link([{:sleep, 200}, "data"], false, false, self())

    req = Request.new("tcp://localhost:#{port}", signal: controller.signal)
    {:ok, resp} = TCP.fetch(req)

    assert :ok = Web.AbortController.abort(controller, :timeout)
    assert Enum.to_list(resp.body) == []
    assert_receive :tcp_client_closed, 1000
  end

  test "fetch/1 returns an empty body when the signal is already aborted before fetch" do
    controller = Web.AbortController.new()
    assert :ok = Web.AbortController.abort(controller, :timeout)
    port = TCPServer.start_link("data", false, false, self())

    req = Request.new("tcp://localhost:#{port}", signal: controller.signal)
    {:ok, resp} = TCP.fetch(req)

    assert Enum.to_list(resp.body) == []
    assert_receive :tcp_client_closed, 1000
  end

  test "fetch/1 raises for unreadable raw request bodies" do
    port = TCPServer.start_link("data")

    req = %Request{
      url: Web.URL.new("tcp://localhost:#{port}"),
      method: "POST",
      headers: Web.Headers.new(),
      body: 123,
      dispatcher: nil,
      redirect: "follow",
      signal: nil,
      options: [redirect: "follow", signal: nil]
    }

    assert_raise Web.TypeError, "body is not readable", fn ->
      TCP.fetch(req)
    end
  end

  test "fetch/1 returns response with protocol-specific status_text" do
    port = TCPServer.start_link("test data", false)

    req = Request.new("tcp://localhost:#{port}")
    {:ok, resp} = TCP.fetch(req)

    assert resp.status == 200
    assert resp.status_text == "Connected"
  end

  test "__debug_start_socket_bridge__/3 supports its default body and signal arguments" do
    port = TCPServer.start_link("data", false, false, self())

    assert {:ok, bridge_pid, socket} =
             TCP.__debug_start_socket_bridge__(%{hostname: "localhost", port: port})

    assert is_pid(bridge_pid)
    _ = Socket.close(socket)
    assert_receive :tcp_client_closed, 1_000

    port = TCPServer.start_link("data", false, false, self())

    assert {:ok, bridge_pid, socket} =
             TCP.__debug_start_socket_bridge__(%{hostname: "localhost", port: port}, nil)

    assert is_pid(bridge_pid)
    _ = Socket.close(socket)
    assert_receive :tcp_client_closed, 1_000
  end

  defp raw_request(url, method, body) do
    %Request{
      url: Web.URL.new(url),
      method: method,
      headers: Headers.new(),
      body: body,
      dispatcher: nil,
      redirect: "follow",
      signal: nil,
      options: [redirect: "follow", signal: nil]
    }
  end

  defp start_debug_bridge(response_data, signal \\ nil) do
    port = TCPServer.start_link(response_data, false, false, self())

    {:ok, bridge_pid, socket} =
      TCP.__debug_start_socket_bridge__(%{hostname: "localhost", port: port}, nil, signal)

    {bridge_pid, socket}
  end

  defp dispatcher_source(%ReadableStream{} = body) do
    body.controller_pid
    |> ReadableStream.__get_slots__()
    |> Map.fetch!(:impl_state)
    |> Map.fetch!(:source)
  end

  defp dispatcher_socket(%ReadableStream{} = body) do
    dispatcher_source(body).debug_socket
  end

  defp controller_for(%ReadableStream{} = stream) do
    %ReadableStreamDefaultController{pid: stream.controller_pid}
  end

  defp proxy_stream do
    ReadableStream.new()
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met in time")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp socket_debug(socket) do
    socket_request(socket, :debug)
  end

  defp socket_request(socket, body, timeout \\ 1_000) do
    socket_raw_request(socket.address, Envelope.new(socket.token, body), timeout)
  end

  defp socket_raw_request(target, body, timeout) do
    reply_ref = make_ref()
    send(target, {:"$gen_call", {self(), reply_ref}, body})

    receive do
      {^reply_ref, reply} -> reply
    after
      timeout -> flunk("socket request timed out")
    end
  end
end
