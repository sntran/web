defmodule Web.Dispatcher.HTTPTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Web.Request
  alias Web.Dispatcher.HTTP

  defmodule HTTPServer do
    def start_link(
          responses \\ [],
          close_early? \\ false,
          drop_on_body? \\ false,
          observer \\ nil
        ) do
      parent = self()

      Task.start_link(fn ->
        {:ok, listen_socket} =
          :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

        {:ok, port} = :inet.port(listen_socket)
        send(parent, {:port, port})

        {:ok, socket} = :gen_tcp.accept(listen_socket)

        if close_early? do
          :gen_tcp.close(socket)
          :gen_tcp.close(listen_socket)
        else
          {:ok, _req} = :gen_tcp.recv(socket, 0)

          Enum.each(responses, fn
            {:sleep, ms} ->
              Process.sleep(ms)

            chunk ->
              :gen_tcp.send(socket, chunk)
          end)

          if observer do
            case :gen_tcp.recv(socket, 0, 200) do
              {:error, :closed} -> send(observer, :http_client_closed)
              _ -> :ok
            end
          end

          if drop_on_body? do
            :gen_tcp.close(socket)
          else
            # Give the client enough time to consume the final buffered bytes under suite load.
            Process.sleep(50)
            :gen_tcp.close(socket)
          end

          :gen_tcp.close(listen_socket)
        end
      end)

      receive do
        {:port, port} -> port
      after
        1000 -> raise "HTTPServer failed to start"
      end
    end
  end

  test "fetch/1 properly streams HTTP headers and chunks without pooling cache" do
    headers_packet = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n"
    port = HTTPServer.start_link([headers_packet, "he", "llo"])

    req =
      Request.new("http://localhost:#{port}/path",
        method: :post,
        body: "data",
        headers: %{"custom" => "header"}
      )

    {:ok, resp} = HTTP.fetch(req)

    assert resp.status == 200
    assert resp.status_text == "OK"
    assert Web.Headers.get(resp.headers, "content-length") == "5"

    chunks = resp.body |> Enum.to_list()
    assert Enum.join(chunks) == "hello"
  end

  test "fetch/1 accepts a raw request with a nil body" do
    port = HTTPServer.start_link(["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"])

    req = %Request{
      url: Web.URL.new("http://localhost:#{port}/raw-nil"),
      method: "GET",
      headers: Web.Headers.new(),
      body: nil,
      dispatcher: nil,
      redirect: "follow",
      signal: nil,
      options: [redirect: "follow", signal: nil]
    }

    assert {:ok, resp} = HTTP.fetch(req)
    assert Enum.to_list(resp.body) == ["ok"]
  end

  test "fetch/1 streams enumerable request bodies without normalizing them to readable streams" do
    headers_packet = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
    port = HTTPServer.start_link([headers_packet])

    req =
      Request.new("http://localhost:#{port}/stream-body",
        method: :post,
        body: Stream.map(["da", "ta"], & &1)
      )

    assert {:ok, resp} = HTTP.fetch(req)
    assert Enum.to_list(resp.body) == ["ok"]
  end

  test "fetch/1 accepts raw iodata list bodies" do
    port = HTTPServer.start_link(["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"])

    req = %Request{
      url: Web.URL.new("http://localhost:#{port}/raw-list"),
      method: "POST",
      headers: Web.Headers.new(),
      body: ["da", "ta"],
      dispatcher: nil,
      redirect: "follow",
      signal: nil,
      options: [redirect: "follow", signal: nil]
    }

    assert {:ok, resp} = HTTP.fetch(req)
    assert Enum.to_list(resp.body) == ["ok"]
  end

  test "fetch/1 surfaces raw invalid body types as request build errors" do
    port = HTTPServer.start_link([])

    req = %Request{
      url: Web.URL.new("http://localhost:#{port}/raw-invalid"),
      method: "POST",
      headers: Web.Headers.new(),
      body: %{bad: :body},
      dispatcher: nil,
      redirect: "follow",
      signal: nil,
      options: [redirect: "follow", signal: nil]
    }

    assert {:error, _} = HTTP.fetch(req)
  end

  test "fetch/1 surfaces non-enumerable raw body types as request build errors" do
    port = HTTPServer.start_link([])

    req = %Request{
      url: Web.URL.new("http://localhost:#{port}/raw-atom"),
      method: "POST",
      headers: Web.Headers.new(),
      body: :bad,
      dispatcher: nil,
      redirect: "follow",
      signal: nil,
      options: [redirect: "follow", signal: nil]
    }

    assert {:error, _} = HTTP.fetch(req)
  end

  test "fetch/1 handles unified packets cleanly routing data remainder payload" do
    port = HTTPServer.start_link(["HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"])

    req = Request.new("http://localhost:#{port}/path", method: :get)
    {:ok, resp} = HTTP.fetch(req)

    chunks = resp.body |> Enum.to_list()
    assert Enum.join(chunks) == "hello"
  end

  test "fetch/1 covers invalid connection path cleanly" do
    req = Request.new("http://localhost_nxdomain_host_never_exist:1234")
    assert {:error, _} = HTTP.fetch(req)
  end

  test "fetch/1 covers early unparseable socket drop gracefully" do
    port = HTTPServer.start_link([], true)

    req = Request.new("http://localhost:#{port}")
    assert {:error, _} = HTTP.fetch(req)
  end

  test "fetch/1 treats https gracefully verifying loosely" do
    req = Request.new("https://localhost_nxdomain_https_safe_guard")
    assert {:error, _} = HTTP.fetch(req)
  end

  test "fetch/1 handles error midway during active read cycle" do
    port =
      HTTPServer.start_link(["HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n", "he"], false, true)

    req = Request.new("http://localhost:#{port}")
    {:ok, resp} = HTTP.fetch(req)

    chunks = resp.body |> Enum.to_list()
    assert Enum.join(chunks) == "he"
  end

  test "fetch/1 handles query variables in path explicitly correctly" do
    req = Request.new("http://localhost_nxdomain:80/?query=1")
    assert {:error, _} = HTTP.fetch(req)
  end

  test "fetch/1 defaults empty protocol urls to http before connecting" do
    req = Request.new("/relative-only")
    assert {:error, _} = HTTP.fetch(req)
  end

  test "fetch/1 returns request errors after connecting when the request target is invalid" do
    port = HTTPServer.start_link([])

    req = Request.new("http://localhost:#{port}?query=1")
    assert {:error, _} = HTTP.fetch(req)
  end

  test "fetch/1 returns request errors for invalid request metadata after connecting" do
    port = HTTPServer.start_link([])

    req =
      Request.new("http://localhost:#{port}/path",
        method: "bad method",
        headers: %{"bad header" => "value"}
      )

    assert {:error, _} = HTTP.fetch(req)
  end

  test "fetch/1 handles a deferred chunked completion with an empty body" do
    port =
      HTTPServer.start_link([
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
        {:sleep, 10},
        "0\r\n\r\n"
      ])

    req = Request.new("http://localhost:#{port}/empty")
    {:ok, resp} = HTTP.fetch(req)

    assert resp.status == 200
    assert Enum.to_list(resp.body) == []
  end

  test "fetch/1 keeps polling when chunk framing arrives incomplete" do
    port =
      HTTPServer.start_link([
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
        {:sleep, 10},
        "0\r\nX-Trail",
        {:sleep, 10},
        "er: done\r\n\r\n"
      ])

    req = Request.new("http://localhost:#{port}/trailers")
    {:ok, resp} = HTTP.fetch(req)

    assert resp.status == 200
    assert Enum.to_list(resp.body) == []
  end

  test "fetch/1 keeps reading when headers arrive across multiple socket reads" do
    port =
      HTTPServer.start_link([
        "HTTP/1.1 200 OK\r\n",
        {:sleep, 10},
        "Content-Length: 0\r\n\r\n"
      ])

    req = Request.new("http://localhost:#{port}/split-headers")
    {:ok, resp} = HTTP.fetch(req)

    assert resp.status == 200
    assert Enum.to_list(resp.body) == []
  end

  test "fetch/1 reads body data that arrives after headers in later recv cycles" do
    port =
      HTTPServer.start_link([
        "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n",
        {:sleep, 10},
        "data"
      ])

    req = Request.new("http://localhost:#{port}/deferred-body")
    {:ok, resp} = HTTP.fetch(req)

    assert Enum.to_list(resp.body) == ["data"]
  end

  test "fetch/1 aborts an in-flight body stream and closes the connection" do
    controller = Web.AbortController.new()
    parent = self()

    port =
      HTTPServer.start_link(
        ["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n", {:sleep, 200}, "data"],
        false,
        false,
        self()
      )

    req = Request.new("http://localhost:#{port}/abort", signal: controller.signal)
    {:ok, resp} = HTTP.fetch(req)

    task =
      Task.async(fn ->
        send(parent, :http_body_started)
        Enum.to_list(resp.body)
      end)

    assert_receive :http_body_started
    Process.sleep(100)
    assert :ok = Web.AbortController.abort(controller, :timeout)

    assert {:ok, []} = Task.yield(task, 1000)
    assert_receive :http_client_closed, 1000
  end

  test "fetch/1 returns aborted for an already-aborted signal before streaming begins" do
    controller = Web.AbortController.new()
    assert :ok = Web.AbortController.abort(controller, :timeout)

    port = HTTPServer.start_link(["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndata"])
    req = Request.new("http://localhost:#{port}/pre-aborted", signal: controller.signal)

    assert {:error, :aborted} = HTTP.fetch(req)
  end

  test "fetch/1 halts buffered body delivery when the signal is aborted before consumption" do
    controller = Web.AbortController.new()
    port = HTTPServer.start_link(["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndata"])

    req = Request.new("http://localhost:#{port}/buffered", signal: controller.signal)
    {:ok, resp} = HTTP.fetch(req)

    assert :ok = Web.AbortController.abort(controller, :timeout)
    assert Enum.to_list(resp.body) == []
  end

  test "fetch/1 halts before the first body recv when aborted after headers" do
    controller = Web.AbortController.new()

    port =
      HTTPServer.start_link([
        "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n",
        {:sleep, 200},
        "data"
      ])

    req = Request.new("http://localhost:#{port}/token-precheck", signal: controller.signal)
    {:ok, resp} = HTTP.fetch(req)

    assert :ok = Web.AbortController.abort(controller, :timeout)
    assert Enum.to_list(resp.body) == []
  end

  test "fetch/1 normalizes transport closure to aborted when abort arrives during recv" do
    parent = self()

    port =
      HTTPServer.start_link(
        [
          "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n",
          {:sleep, 10}
        ],
        false,
        true
      )

    req = Request.new("http://localhost:#{port}/token-close", signal: :queued_abort)
    {:ok, resp} = HTTP.fetch(req)

    task =
      Task.async(fn ->
        send(parent, :http_recv_started)
        Enum.to_list(resp.body)
      end)

    assert_receive :http_recv_started, 100
    Process.sleep(1)
    send(task.pid, {:abort, :queued_abort})

    assert {:ok, []} = Task.yield(task, 1000)
  end

  test "fetch/1 returns error when bridge process dies before response head" do
    port =
      HTTPServer.start_link([
        {:sleep, 200},
        "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndata"
      ])

    req = Request.new("http://localhost:#{port}/bridge-down")

    task =
      Task.async(fn ->
        receive do
          :go -> HTTP.fetch(req)
        end
      end)

    task_pid = task.pid

    :erlang.trace(task_pid, true, [:procs])

    try do
      send(task_pid, :go)

      bridge_pid =
        receive do
          {:trace, ^task_pid, :spawn, spawned_pid, _mfa} ->
            spawned_pid
        after
          1000 ->
            flunk("did not capture bridge spawn")
        end

      Process.exit(bridge_pid, :kill)

      assert {:ok, {:error, :killed}} = Task.yield(task, 2000)
    after
      if Process.alive?(task_pid) do
        :erlang.trace(task_pid, false, [:procs])
      end
    end
  end

  test "fetch/1 aborts on next pull after first chunk" do
    controller = Web.AbortController.new()

    port =
      HTTPServer.start_link([
        "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\n",
        "data",
        {:sleep, 100},
        "more"
      ])

    req = Request.new("http://localhost:#{port}/abort-next-pull", signal: controller.signal)
    {:ok, resp} = HTTP.fetch(req)

    chunks =
      Enum.reduce(resp.body, [], fn chunk, acc ->
        if acc == [] do
          :ok = Web.AbortController.abort(controller, :timeout)
        end

        [chunk | acc]
      end)

    # Aborting after the first delivered chunk should stop subsequent pulls.
    assert Enum.reverse(chunks) == ["data"]
  end

  test "fetch/1 populates status_text from HTTP status code map" do
    # Test 200 OK
    port = HTTPServer.start_link(["HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"])
    req = Request.new("http://localhost:#{port}/200", method: :get)
    {:ok, resp} = HTTP.fetch(req)
    assert resp.status_text == "OK"

    # Test 404 Not Found
    port = HTTPServer.start_link(["HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"])
    req = Request.new("http://localhost:#{port}/404", method: :get)
    {:ok, resp} = HTTP.fetch(req)
    assert resp.status_text == "Not Found"

    # Test 500 Internal Server Error
    port = HTTPServer.start_link(["HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n"])
    req = Request.new("http://localhost:#{port}/500", method: :get)
    {:ok, resp} = HTTP.fetch(req)
    assert resp.status_text == "Internal Server Error"
  end
end
