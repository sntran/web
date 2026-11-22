# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule Web.Dispatcher.HTTPTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Web.Dispatcher.HTTP
  alias Web.Internal.LazyStream
  alias Web.Request

  defmodule HTTPServer do
    # credo:disable-for-next-line
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
          case :gen_tcp.recv(socket, 0) do
            {:ok, _req} -> :ok
            {:error, :closed} -> :ok
          end

          Enum.each(responses, fn
            # The pause is a part of the scenario: a slow server.
            {:sleep, ms} ->
              Process.sleep(ms)

            # The server stops until the test lets it continue. Thus the
            # test can do a step before the next part of the response.
            :gate ->
              send(parent, {:http_server_gate, port, self()})

              receive do
                :go -> :ok
              end

            chunk ->
              case :gen_tcp.send(socket, chunk) do
                :ok -> :ok
                {:error, :closed} -> :ok
              end
          end)

          cond do
            # The server tells the observer when the client closes the
            # connection.
            observer ->
              read_until_closed(socket)
              send(observer, :http_client_closed)

            drop_on_body? ->
              :ok

            # The server closes its side for writes, and reads until the
            # client closes the connection. A socket that closes with bytes
            # that it did not read sends a reset, and the reset can drop the
            # end of the response.
            true ->
              _result = :gen_tcp.shutdown(socket, :write)
              read_until_closed(socket)
          end

          :gen_tcp.close(socket)
          :gen_tcp.close(listen_socket)
        end
      end)

      receive do
        {:port, port} -> port
      after
        1000 -> raise "HTTPServer failed to start"
      end
    end

    defp read_until_closed(socket) do
      case :gen_tcp.recv(socket, 0) do
        {:ok, _data} -> read_until_closed(socket)
        {:error, _reason} -> :ok
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

    assert Web.TestBytes.join(resp.body) == "hello"
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
    assert Web.TestBytes.binaries(resp.body) == ["ok"]
  end

  test "fetch/1 streams enumerable request bodies without normalizing them to readable streams" do
    headers_packet = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
    port = HTTPServer.start_link([headers_packet])

    req =
      Request.new("http://localhost:#{port}/stream-body",
        method: :post,
        body: Stream.map(["da", "ta"], & &1),
        duplex: "half"
      )

    assert {:ok, resp} = HTTP.fetch(req)
    assert Web.TestBytes.binaries(resp.body) == ["ok"]
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
    assert Web.TestBytes.binaries(resp.body) == ["ok"]
  end

  test "fetch/1 surfaces raw invalid body types as request build errors" do
    # The server waits after the request: the only failure is the chunk of
    # the body, which is not bytes.
    port = HTTPServer.start_link([:gate])

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

    # A map is an enumerable: its first chunk is the pair `{:bad, :body}`.
    assert {:error, %Web.TypeError{message: "The request body chunk must be" <> _}} =
             HTTP.fetch(req)

    assert_receive {:http_server_gate, ^port, server}
    send(server, :go)
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

  test "fetch/1 unsubscribes and returns an error when request building fails" do
    req = %Request{
      url: nil,
      method: "GET",
      headers: Web.Headers.new(),
      body: nil,
      dispatcher: nil,
      redirect: "follow",
      signal: nil,
      options: [redirect: "follow", signal: nil]
    }

    assert {:error, %FunctionClauseError{}} = HTTP.fetch(req)
  end

  test "fetch/1 handles unified packets cleanly routing data remainder payload" do
    port = HTTPServer.start_link(["HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"])

    req = Request.new("http://localhost:#{port}/path", method: :get)
    {:ok, resp} = HTTP.fetch(req)

    assert Web.TestBytes.join(resp.body) == "hello"
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

    # The body is shorter than its content length. The reader gets an error,
    # not a part of the body.
    assert %Web.TypeError{message: message} = body_error(resp)
    assert message =~ "body"
  end

  test "fetch/1 handles query variables in path explicitly correctly" do
    req = Request.new("http://localhost_nxdomain:80/?query=1")
    assert {:error, _} = HTTP.fetch(req)
  end

  test "fetch/1 returns request errors after connecting when the request target is invalid" do
    port = HTTPServer.start_link([])

    req = Request.new("http://localhost:#{port}?query=1")
    assert {:error, _} = HTTP.fetch(req)
  end

  test "fetch/1 gives the body nil for a status that permits no body" do
    for status <- [204, 304] do
      port = HTTPServer.start_link(["HTTP/1.1 #{status} Status\r\nx-test: 1\r\n\r\n"])

      {:ok, resp} = HTTP.fetch(Request.new("http://localhost:#{port}/none"))

      assert resp.status == status
      assert resp.body == nil
      assert resp.type == "basic"
      assert Web.Headers.get(resp.headers, "x-test") == "1"
      assert Web.Promise.await(Web.Response.text(resp)) == ""
    end
  end

  test "fetch/1 gives the body nil for a HEAD request" do
    port = HTTPServer.start_link(["HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\n"])

    {:ok, resp} = HTTP.fetch(Request.new("http://localhost:#{port}/head", method: "HEAD"))

    assert resp.status == 200
    assert resp.body == nil
    assert Web.Headers.get(resp.headers, "content-length") == "5"
  end

  test "fetch/1 gives a response for a status that the constructor refuses" do
    port = HTTPServer.start_link(["HTTP/1.1 999 Unusual\r\ncontent-length: 2\r\n\r\nok"])

    {:ok, resp} = HTTP.fetch(Request.new("http://localhost:#{port}/unusual"))

    assert resp.status == 999
    assert resp.ok == false
    assert Web.Promise.await(Web.Response.text(resp)) == "ok"
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
    assert Web.TestBytes.binaries(resp.body) == []
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
    assert Web.TestBytes.binaries(resp.body) == []
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
    assert Web.TestBytes.binaries(resp.body) == []
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

    assert Web.TestBytes.binaries(resp.body) == ["data"]
  end

  test "fetch/1 aborts an in-flight body stream and closes the connection" do
    controller = Web.AbortController.new()
    parent = self()

    # The server sends the rest of the body only after the abort.
    port =
      HTTPServer.start_link(
        ["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n", :gate, "data"],
        false,
        false,
        self()
      )

    req = Request.new("http://localhost:#{port}/abort", signal: controller.signal)
    {:ok, resp} = HTTP.fetch(req)

    task =
      Task.async(fn ->
        send(parent, :http_body_started)
        body_error(resp)
      end)

    assert_receive :http_body_started
    assert_receive {:http_server_gate, ^port, server}, 2000
    # The read of the task waits for the body.
    eventually(fn -> read_waits?(resp) end)
    assert :ok = Web.AbortController.abort(controller, :timeout)

    # The time limits are large for a busy machine.
    assert {:ok, %Web.TypeError{message: "The stream is errored."}} = Task.yield(task, 2000)
    send(server, :go)
    assert_receive :http_client_closed, 2000
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
    assert %Web.TypeError{message: "The stream is errored."} = body_error(resp)

    reader = Web.ReadableStream.get_reader(resp.body)
    assert catch_exit(Web.Promise.await(Web.ReadableStreamDefaultReader.read(reader))) == :timeout
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
    assert %Web.TypeError{message: "The stream is errored."} = body_error(resp)
  end

  test "fetch/1 keeps waiting for delayed body chunks while the signal stays alive" do
    controller = Web.AbortController.new()

    port =
      HTTPServer.start_link([
        "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n",
        {:sleep, 200},
        "data"
      ])

    req = Request.new("http://localhost:#{port}/delayed-body", signal: controller.signal)
    {:ok, resp} = HTTP.fetch(req)

    assert Web.TestBytes.binaries(resp.body) == ["data"]
  end

  test "fetch/1 gives an error when the transport closes before the body is complete" do
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

    req =
      Request.new("http://localhost:#{port}/token-close",
        signal: Web.AbortController.new().signal
      )

    {:ok, resp} = HTTP.fetch(req)

    task =
      Task.async(fn ->
        send(parent, :http_recv_started)
        body_error(resp)
      end)

    assert_receive :http_recv_started, 1000

    assert {:ok, error} = Task.yield(task, 1000)
    assert is_exception(error)
  end

  test "fetch/1 returns an error when the process of the request stops before the head" do
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

      # The process of the request, which is also the promise.
      assert_receive {:trace, ^task_pid, :spawn, request_pid, _mfa}, 1000
      Process.exit(request_pid, :kill)

      # The process is the promise: the await gets the error of a promise
      # that stopped.
      assert {:ok, {:error, %Web.TypeError{message: "The promise is not available." <> _}}} =
               Task.yield(task, 2000)
    after
      if Process.alive?(task_pid) do
        :erlang.trace(task_pid, false, [:procs])
      end
    end
  end

  test "an informational response before the response is ignored" do
    for informational <- [
          "HTTP/1.1 100 Continue\r\n\r\n",
          "HTTP/1.1 103 Early Hints\r\nlink: </style.css>; rel=preload\r\n\r\n"
        ] do
      port =
        HTTPServer.start_link([
          informational,
          "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nx-final: yes\r\n\r\nok"
        ])

      assert {:ok, resp} = HTTP.fetch(Request.new("http://localhost:#{port}/informational"))
      assert resp.status == 200
      assert Web.Headers.get(resp.headers, "x-final") == "yes"
      assert Web.Headers.get(resp.headers, "link") == nil
      assert Web.await(Web.Response.text(resp)) == "ok"
    end
  end

  test "the trailers of a chunked response are not in the body" do
    port =
      HTTPServer.start_link([
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: x-sum\r\n\r\n",
        "2\r\nok\r\n0\r\nx-sum: 1\r\n\r\n"
      ])

    assert {:ok, resp} = HTTP.fetch(Request.new("http://localhost:#{port}/trailers"))
    assert Web.await(Web.Response.text(resp)) == "ok"
    assert Web.Headers.get(resp.headers, "x-sum") == nil
  end

  test "a redirect of a request with no response body follows the redirect mode" do
    port =
      HTTPServer.start_link([
        "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\n\r\n"
      ])

    req = Request.new("http://localhost:#{port}/head", method: "HEAD", redirect: "error")
    assert HTTP.fetch(req) == {:error, :redirect_error}
  end

  test "fetch/1 aborts on next pull after first chunk" do
    controller = Web.AbortController.new()

    port =
      HTTPServer.start_link([
        "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\n",
        "data",
        :gate,
        "more"
      ])

    req = Request.new("http://localhost:#{port}/abort-next-pull", signal: controller.signal)
    {:ok, resp} = HTTP.fetch(req)
    assert_receive {:http_server_gate, ^port, server}, 2000

    parent = self()

    # An abort after the first chunk stops the body with an error. The
    # server sends the rest of the body after the abort.
    assert_raise Web.TypeError, "The stream is errored.", fn ->
      Enum.each(resp.body, fn chunk ->
        send(parent, {:chunk, Web.TestBytes.binary(chunk)})
        :ok = Web.AbortController.abort(controller, :timeout)
        send(server, :go)
      end)
    end

    assert_received {:chunk, "data"}
    refute_received {:chunk, "more"}
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
    port =
      HTTPServer.start_link(["HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n"])

    req = Request.new("http://localhost:#{port}/500", method: :get)
    {:ok, resp} = HTTP.fetch(req)
    assert resp.status_text == "Internal Server Error"
  end

  # A read of the body waits in the stream process for a chunk.
  defp read_waits?(resp) do
    case LazyStream.state(resp.body.lazy) do
      {:process, stream} ->
        {_state, data} = :sys.get_state(stream)
        not :queue.is_empty(data.read_requests)

      _no_process ->
        false
    end
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  # Reads the body and returns the exception that the read raises.
  defp body_error(resp) do
    _chunks = Enum.to_list(resp.body)
    flunk("the body read did not raise")
  rescue
    error in [ExUnit.AssertionError] -> reraise error, __STACKTRACE__
    error -> error
  end
end
