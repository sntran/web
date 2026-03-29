defmodule Web.FetchSignalTest do
  use ExUnit.Case, async: true

  defmodule SlowDispatcher do
    @behaviour Web.Dispatcher

    def fetch(%Web.Request{} = req) do
      Process.sleep(50)
      {:ok, Web.Response.new(status: 200, body: ["data"], url: req.url, ok: true)}
    end
  end

  defmodule NeverDispatcher do
    @behaviour Web.Dispatcher

    def fetch(_req) do
      send(self(), :dispatcher_called)
      {:ok, Web.Response.new(status: 200, body: [], url: "mock://never", ok: true)}
    end
  end

  defmodule DelayedHTTPServer do
    def start_link(delay_ms) do
      parent = self()

      {:ok, pid} =
        Task.start(fn ->
          {:ok, listen_socket} =
            :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

          {:ok, port} = :inet.port(listen_socket)
          send(parent, {:port, port})

          {:ok, socket} = :gen_tcp.accept(listen_socket)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 1000)
          Process.sleep(delay_ms)

          case :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndata") do
            :ok -> :ok
            {:error, :closed} -> :ok
          end

          case :gen_tcp.recv(socket, 0, 200) do
            {:error, :closed} -> send(parent, :client_closed)
            _ -> :ok
          end

          :gen_tcp.close(socket)
          :gen_tcp.close(listen_socket)
        end)

      port =
        receive do
          {:port, port} -> port
        after
          1000 -> raise "DelayedHTTPServer failed to start"
        end

      %{pid: pid, port: port}
    end
  end

  test "abort controller creates a signal and abort stops it" do
    controller = Web.AbortController.new()
    assert %Web.AbortSignal{} = controller.signal
    assert Process.alive?(controller.signal.pid)

    assert :ok = Web.AbortController.abort(controller, :boom)
    Process.sleep(10)
    refute Process.alive?(controller.signal.pid)
  end

  test "fetch stops immediately if message received before fetch" do
    req = Web.Request.new("mock://slow", signal: :my_ref, dispatcher: SlowDispatcher)
    send(self(), {:abort, :my_ref})
    assert {:error, :aborted} = Web.fetch(req)
  end

  test "fetch stops immediately for string input when the abort message is already queued" do
    send(self(), {:abort, :my_ref})

    assert {:error, :aborted} =
             Web.fetch("mock://slow", signal: :my_ref, dispatcher: SlowDispatcher)
  end

  test "fetch stops immediately if signal PID is dead before fetch" do
    dead_pid = spawn(fn -> :ok end)
    Process.sleep(10)

    req = Web.Request.new("mock://slow", signal: dead_pid, dispatcher: SlowDispatcher)
    assert {:error, :aborted} = Web.fetch(req)
  end

  test "fetch aborts when a pid signal dies during http header I/O" do
    server = DelayedHTTPServer.start_link(200)

    signal_pid =
      spawn(fn ->
        receive do
          :die -> exit(:kill)
        end
      end)

    task =
      Task.async(fn ->
        Web.fetch("http://localhost:#{server.port}/slow", signal: signal_pid)
      end)

    Process.sleep(50)
    send(signal_pid, :die)

    assert {:ok, {:error, reason}} = Task.yield(task, 1000)
    assert reason == :aborted or match?(%Mint.TransportError{reason: :closed}, reason)
    Process.exit(server.pid, :kill)
  end

  test "fetch links and succeeds if signal PID stays alive" do
    alive_pid = spawn(fn -> Process.sleep(5000) end)
    req = Web.Request.new("mock://slow", signal: alive_pid, dispatcher: SlowDispatcher)

    assert {:ok, resp} = Web.fetch(req)
    assert resp.status == 200

    Process.exit(alive_pid, :kill)
  end

  test "fetch returns aborted immediately when given an already-aborted signal" do
    assert {:error, :aborted} =
             Web.fetch("mock://never",
               signal: Web.AbortSignal.abort(:manual_cancel),
               dispatcher: NeverDispatcher
             )

    refute_received :dispatcher_called
  end

  test "fetch returns aborted when an abort controller triggers before headers arrive" do
    server = DelayedHTTPServer.start_link(200)
    controller = Web.AbortController.new()

    task =
      Task.async(fn ->
        Web.fetch("http://localhost:#{server.port}/slow", signal: controller.signal)
      end)

    Process.sleep(50)
    assert :ok = Web.AbortController.abort(controller, :timeout)
    assert {:error, :aborted} = Task.await(task, 2000)

    refute Process.alive?(controller.signal.pid)
    Process.exit(server.pid, :kill)
  end

  test "receive_abort/2 returns ok for an alive pid signal with no abort message" do
    alive_pid = spawn(fn -> Process.sleep(100) end)
    {:ok, subscription} = Web.AbortSignal.subscribe(alive_pid)

    assert :ok = Web.AbortSignal.receive_abort(subscription, 0)

    Web.AbortSignal.unsubscribe(subscription)
    Process.exit(alive_pid, :kill)
  end
end
