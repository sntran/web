defmodule Web.FetchSignalTest do
  use ExUnit.Case, async: true
  import Web, only: [await: 1]

  defmodule SlowDispatcher do
    @behaviour Web.Dispatcher

    # The pause is a part of the scenario: a slow dispatcher.
    def fetch(%Web.Request{} = req) do
      Process.sleep(50)
      {:ok, Web.Response.__network__(status: 200, body: ["data"], url: Web.URL.href(req.url))}
    end
  end

  defmodule NeverDispatcher do
    @behaviour Web.Dispatcher

    def fetch(_req) do
      send(self(), :dispatcher_called)
      {:ok, Web.Response.__network__(status: 200, body: [], url: "mock://never")}
    end
  end

  # The dispatcher of a request is an internal field: the public API has no
  # option for it.
  defp slow(input, init \\ []),
    do: %{Web.Request.new(input, init) | dispatcher: SlowDispatcher}

  # A server that reads the request, tells the test, and gives no response.
  # Thus the test can do a step while the client waits for the response
  # headers.
  defmodule SilentHTTPServer do
    def start_link do
      parent = self()

      {:ok, pid} =
        Task.start(fn ->
          {:ok, listen_socket} =
            :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

          {:ok, port} = :inet.port(listen_socket)
          send(parent, {:port, port})

          {:ok, socket} = :gen_tcp.accept(listen_socket)
          {:ok, _request} = :gen_tcp.recv(socket, 0)
          send(parent, {:request_read, self()})

          # The server keeps the connection open until the test stops it.
          Process.sleep(:infinity)
        end)

      port =
        receive do
          {:port, port} -> port
        after
          1000 -> raise "SilentHTTPServer failed to start"
        end

      %{pid: pid, port: port}
    end
  end

  test "abort controller creates a signal and abort stops it" do
    controller = Web.AbortController.new()
    assert %Web.AbortSignal{} = controller.signal
    assert Process.alive?(controller.signal.pid)

    monitor = Process.monitor(controller.signal.pid)

    assert :ok = Web.AbortController.abort(controller, :boom)
    # The process of the signal stops after its answer to the abort.
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 1_000
    refute Process.alive?(controller.signal.pid)
  end

  test "fetch rejects with TypeError for a signal that is not an AbortSignal" do
    # The member `signal` of `RequestInit` has the type `AbortSignal?` in
    # the Fetch Standard.
    for signal <- [:my_ref, make_ref(), self(), "signal", %{aborted: true}] do
      assert %Web.TypeError{message: "The value is not an AbortSignal: " <> _} =
               catch_exit(await(Web.fetch("mock://slow", signal: signal)))

      req = %{Web.Request.new("mock://never") | dispatcher: NeverDispatcher}
      assert %Web.TypeError{} = catch_exit(await(Web.fetch(req, signal: signal)))
    end

    refute_received :dispatcher_called
  end

  test "fetch rejects when the process of the signal stopped before the fetch" do
    controller = Web.AbortController.new()
    monitor = Process.monitor(controller.signal.pid)
    Process.exit(controller.signal.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 1_000

    req = slow("mock://slow", signal: controller.signal)
    assert %Web.DOMException{name: "AbortError"} = catch_exit(await(Web.fetch(req)))
  end

  test "fetch aborts when the process of the signal stops during http header I/O" do
    server = SilentHTTPServer.start_link()
    server_pid = server.pid
    controller = Web.AbortController.new()

    promise = Web.fetch("http://localhost:#{server.port}/slow", signal: controller.signal)

    # The client sent the request, and waits for the response headers.
    assert_receive {:request_read, ^server_pid}, 5_000
    Process.exit(controller.signal.pid, :kill)

    assert %Web.DOMException{name: "AbortError"} = catch_exit(await(promise))
    Process.exit(server.pid, :kill)
  end

  test "fetch succeeds when the signal does not abort" do
    controller = Web.AbortController.new()
    req = slow("mock://slow", signal: controller.signal)

    resp = await(Web.fetch(req))
    assert resp.status == 200
  end

  test "a dispatcher of the caller runs with the signal of the request as the ambient signal" do
    controller = Web.AbortController.new()

    response =
      await(Web.fetch(slow("mock://slow"), signal: controller.signal))

    assert response.status == 200
    assert response.snapshot.ambient_signal == controller.signal
  end

  test "fetch returns aborted immediately when given an already-aborted signal" do
    assert :manual_cancel =
             catch_exit(
               await(
                 Web.fetch(%{Web.Request.new("mock://never") | dispatcher: NeverDispatcher},
                   signal: Web.AbortSignal.abort(:manual_cancel)
                 )
               )
             )

    refute_received :dispatcher_called
  end

  test "fetch returns aborted when an abort controller triggers before headers arrive" do
    server = SilentHTTPServer.start_link()
    server_pid = server.pid
    controller = Web.AbortController.new()
    monitor = Process.monitor(controller.signal.pid)

    promise = Web.fetch("http://localhost:#{server.port}/slow", signal: controller.signal)

    # The client sent the request, and waits for the response headers.
    assert_receive {:request_read, ^server_pid}, 5_000
    assert :ok = Web.AbortController.abort(controller, :timeout)
    assert catch_exit(await(promise)) in [:aborted, :timeout]

    # The process of the signal stops after its answer to the abort.
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 1_000
    refute Process.alive?(controller.signal.pid)
    Process.exit(server.pid, :kill)
  end

  test "receive_abort/3 returns ok for an alive pid signal with no abort message" do
    alive_pid = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, subscription} = Web.AbortSignal.subscribe(alive_pid)

    assert :ok = Web.AbortSignal.receive_abort(subscription, 0, true)

    Web.AbortSignal.unsubscribe(subscription)
    Process.exit(alive_pid, :kill)
  end
end
