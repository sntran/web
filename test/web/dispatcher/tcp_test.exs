defmodule Web.Dispatcher.TCPTest do
  use ExUnit.Case, async: true

  alias Web.Request
  alias Web.Dispatcher.TCP

  defmodule TCPServer do
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
              :gen_tcp.send(socket, "llo")

            {false, chunks} when is_list(chunks) ->
              Enum.each(chunks, fn
                {:sleep, ms} -> Process.sleep(ms)
                chunk -> :gen_tcp.send(socket, chunk)
              end)

            {false, _} ->
              :gen_tcp.send(socket, response_data)
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
  end

  test "fetch/1 handles standard tcp scheme and yields chunks dynamically" do
    port = TCPServer.start_link("", true)

    req = Request.new("tcp://localhost:#{port}", body: "sent body payload")
    {:ok, resp} = TCP.fetch(req)

    assert resp.status == 200
    chunks = resp.body |> Enum.to_list()
    assert Enum.join(chunks) == "hello"
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

  test "fetch/1 halts before consuming when the signal is already aborted" do
    controller = Web.AbortController.new()
    port = TCPServer.start_link("data")

    req = Request.new("tcp://localhost:#{port}", signal: controller.signal)
    {:ok, resp} = TCP.fetch(req)

    assert :ok = Web.AbortController.abort(controller, :timeout)
    assert Enum.to_list(resp.body) == []
  end

  test "fetch/1 returns an empty body when the signal is already aborted before fetch" do
    controller = Web.AbortController.new()
    assert :ok = Web.AbortController.abort(controller, :timeout)
    port = TCPServer.start_link("data")

    req = Request.new("tcp://localhost:#{port}", signal: controller.signal)
    {:ok, resp} = TCP.fetch(req)

    assert Enum.to_list(resp.body) == []
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
end
