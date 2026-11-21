defmodule Web.Dispatcher.HTTPProcessTest do
  # These tests stop the processes of a request at a known time. A stream
  # that loses its source writes an error to the log, thus the tests do not
  # run at the same time as tests that examine the log.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  # The process of a request is also the promise of `fetch`: it stays for
  # the linger time after its work. A short linger time lets the tests see
  # it stop.
  setup do
    previous = Application.get_env(:web, :linger)
    Application.put_env(:web, :linger, 20)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:web, :linger, previous),
        else: Application.delete_env(:web, :linger)
    end)
  end

  alias Web.Dispatcher.HTTP
  alias Web.Dispatcher.HTTP.Exchange
  alias Web.Dispatcher.HTTPTest.HTTPServer
  alias Web.ReadableStream
  alias Web.Request

  # Runs the request in a different process, and returns that process with
  # the process of the request: the process that `HTTP.fetch/1` makes. That
  # process is also the promise. The process has no link to the test, thus a
  # test can stop it.
  defp start_fetch(req) do
    test = self()

    pid =
      spawn(fn ->
        receive do
          :go -> :ok
        end

        send(test, {:fetched, self(), HTTP.fetch(req)})

        receive do
          :stop -> :ok
        end
      end)

    :erlang.trace(pid, true, [:procs])
    send(pid, :go)
    assert_receive {:trace, ^pid, :spawn, request, _mfa}, 1_000
    {%{pid: pid}, request}
  end

  defp await_fetch(%{pid: pid}) do
    assert_receive {:fetched, ^pid, result}, 5_000
    result
  end

  # Runs the request, and returns the response with the process of the
  # request.
  defp fetch_with_process(req) do
    {task, request} = start_fetch(req)
    assert {:ok, resp} = await_fetch(task)
    {resp, request}
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  defp stopped?(pids), do: not Enum.any?(pids, &Process.alive?/1)

  # The state of the network side of the process of a request, or `nil`
  # before the start of the request and after the stop of the process.
  defp exchange(request) do
    case Process.info(request, :dictionary) do
      {:dictionary, dictionary} -> :proplists.get_value({Exchange, :state}, dictionary, nil)
      nil -> nil
    end
  end

  # The process of the request has the head of the response, and waits for
  # the end of a body that it does not give.
  defp at_head?(request, kind), do: match?(%{kind: ^kind}, exchange(request))

  # A response whose body has one chunk, and then nothing for a long time.
  defp stalled_response(options \\ []) do
    port =
      HTTPServer.start_link([
        "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\ndata",
        {:sleep, 2_000}
      ])

    fetch_with_process(Request.new("http://localhost:#{port}/stalled", options))
  end

  # Reads all the bytes into views of three bytes.
  defp read_byob(reader, acc) do
    view = Web.Uint8Array.new(Web.ArrayBuffer.new(3))

    case Web.await(Web.ReadableStreamBYOBReader.read(reader, view)) do
      %{done: true} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
      %{value: view} -> read_byob(reader, [Web.Uint8Array.to_binary(view) | acc])
    end
  end

  # Reads the first chunk, then starts the read of the subsequent one.
  defp read_until_stalled(resp) do
    reader = ReadableStream.get_reader(resp.body)
    assert %{done: false} = Web.await(Web.ReadableStreamDefaultReader.read(reader))
    Web.ReadableStreamDefaultReader.read(reader)
  end

  describe "a body that is complete when the promise settles" do
    test "has no process, and the process of the request stops" do
      port = HTTPServer.start_link(["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndata"])
      {resp, request} = fetch_with_process(Request.new("http://localhost:#{port}/"))

      assert resp.body.controller_pid == nil
      assert {:bytes, "data"} = resp.body.lazy.source
      eventually(fn -> stopped?([request]) end)

      assert Enum.map(resp.body, &Web.Uint8Array.to_binary/1) == ["data"]
    end

    test "gives the reason of an abort that came before the read" do
      port = HTTPServer.start_link(["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndata"])
      controller = Web.AbortController.new()
      request = Request.new("http://localhost:#{port}/", signal: controller.signal)
      {resp, process} = fetch_with_process(request)

      eventually(fn -> stopped?([process]) end)
      Web.AbortController.abort(controller, :stop)

      assert catch_exit(Web.await(Web.Response.text(resp))) == :stop
    end
  end

  describe "a body that the process of the request holds" do
    test "gives all its bytes to a read at the end of the body" do
      port =
        HTTPServer.start_link([
          "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\ndata",
          {:sleep, 100},
          "more"
        ])

      {resp, request} = fetch_with_process(Request.new("http://localhost:#{port}/"))
      assert {:held, ^request} = resp.body.lazy.source

      assert Web.await(Web.Response.text(resp)) == "datamore"
      eventually(fn -> stopped?([request]) end)
    end

    test "is a byte stream, which a BYOB reader reads, and has immutable headers" do
      port =
        HTTPServer.start_link([
          "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\ndata",
          {:sleep, 50},
          "more"
        ])

      {resp, request} = fetch_with_process(Request.new("http://localhost:#{port}/"))
      assert {:held, ^request} = resp.body.lazy.source
      assert resp.headers.guard == "immutable"

      reader = ReadableStream.get_reader(resp.body, mode: "byob")
      assert read_byob(reader, []) == "datamore"
    end

    test "gives a body larger than its queue to a read of all the bytes" do
      body = :binary.copy("x", 200_000)

      port =
        HTTPServer.start_link([
          "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\n\r\n",
          {:sleep, 50},
          body
        ])

      {resp, _request} = fetch_with_process(Request.new("http://localhost:#{port}/"))
      assert Web.await(Web.Response.text(resp)) == body
    end

    test "gives its bytes to one copy only" do
      port =
        HTTPServer.start_link([
          "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\ndata",
          {:sleep, 50},
          "more"
        ])

      {resp, _request} = fetch_with_process(Request.new("http://localhost:#{port}/"))
      copy = Task.async(fn -> resp end) |> Task.await()

      assert Web.await(Web.Response.text(resp)) == "datamore"
      assert Web.Response.body_used?(copy)
      assert %Web.TypeError{} = catch_exit(Web.await(Web.Response.text(copy)))
    end

    test "gives an error to a reader that waits when the process stops" do
      {resp, request} = stalled_response()
      read = read_until_stalled(resp)

      Process.exit(request, :kill)

      assert %Web.TypeError{
               message: "The response body is not complete.",
               cause: {:connection_process_stopped, :killed}
             } = catch_exit(Web.await(read))
    end

    test "gives an error to a read of all the bytes when the process stops" do
      {resp, request} = stalled_response()
      {:monitored_by, before} = Process.info(request, :monitored_by)
      read = Web.Response.text(resp)
      assert Web.Response.body_used?(resp)

      # The process of the promise monitors the holder, and asks it for the
      # bytes.
      eventually(fn ->
        {:monitored_by, now} = Process.info(request, :monitored_by)
        length(now) > length(before)
      end)

      Process.exit(request, :kill)

      assert %Web.TypeError{cause: {:connection_process_stopped, :killed}} =
               catch_exit(Web.await(read))
    end

    test "stops its process when the process that reads it stops" do
      {resp, request} = stalled_response()
      parent = self()

      reader =
        spawn(fn ->
          _read = read_until_stalled(resp)
          send(parent, :reading)
          Process.sleep(:infinity)
        end)

      assert_receive :reading, 1_000
      Process.exit(reader, :kill)

      eventually(fn -> stopped?([request]) end)
    end

    test "stops its process at a cancel" do
      {resp, request} = stalled_response()

      assert :ok = Web.await(ReadableStream.cancel(resp.body, :no_more))
      eventually(fn -> stopped?([request]) end)
    end

    test "stops its process when the process that called fetch stops" do
      {task, request} =
        start_fetch(
          Request.new(
            "http://localhost:#{HTTPServer.start_link(["HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\ndata", {:sleep, 2_000}])}/"
          )
        )

      assert {:ok, _resp} = await_fetch(task)
      Process.exit(task.pid, :kill)

      eventually(fn -> stopped?([request]) end)
    end

    test "stops its process when the stream stops while the process waits for a pull" do
      # The part of the body that came is larger than the queue of the
      # stream: the process waits. The rest of the body does not come.
      body = :binary.copy("x", 200_000)

      port =
        HTTPServer.start_link([
          "HTTP/1.1 200 OK\r\nContent-Length: #{2 * byte_size(body)}\r\n\r\n",
          body,
          {:sleep, 2_000}
        ])

      {resp, request} = fetch_with_process(Request.new("http://localhost:#{port}/"))
      _reader = ReadableStream.get_reader(resp.body)
      {:ok, stream} = ReadableStream.__process__(resp.body)

      # The queue of the stream is full: the process waits for a pull.
      eventually(fn -> ReadableStream.get_desired_size(stream) <= 0 end)

      Process.exit(stream, :kill)

      eventually(fn -> stopped?([request]) end)
    end
  end

  # The socket of the process of a request. The process owns the socket
  # while the response comes, thus the process is linked to its port.
  defp socket_of(request) do
    case Process.info(request, :links) do
      {:links, links} -> Enum.find(links, &is_port/1)
      nil -> nil
    end
  end

  # A server that sends the head of a response only when the test lets it.
  defp late_server(response) do
    HTTPServer.start_link([:gate | response])
  end

  describe "a response with no body, or a redirect, before its end" do
    @stalled_no_body [
      "HTTP/1.1 205 Reset Content\r\nContent-Length: 10\r\n\r\nab",
      {:sleep, 2_000}
    ]

    test "rejects at an abort" do
      controller = Web.AbortController.new()
      port = HTTPServer.start_link(@stalled_no_body)

      {task, request} =
        start_fetch(Request.new("http://localhost:#{port}/", signal: controller.signal))

      eventually(fn -> at_head?(request, :null) end)
      Web.AbortController.abort(controller, :stop)

      assert await_fetch(task) == {:error, :aborted}
      eventually(fn -> stopped?([request]) end)
    end

    test "of a redirect rejects at an abort" do
      controller = Web.AbortController.new()

      port =
        HTTPServer.start_link([
          "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 10\r\n\r\nab",
          {:sleep, 2_000}
        ])

      {task, request} =
        start_fetch(Request.new("http://localhost:#{port}/", signal: controller.signal))

      eventually(fn -> at_head?(request, :discard) end)
      Web.AbortController.abort(controller, :stop)
      assert await_fetch(task) == {:error, :aborted}
    end

    test "stops when the owner stops" do
      port = HTTPServer.start_link(@stalled_no_body)
      {task, request} = start_fetch(Request.new("http://localhost:#{port}/"))

      eventually(fn -> at_head?(request, :null) end)
      Process.exit(task.pid, :kill)
      eventually(fn -> stopped?([request]) end)
    end

    test "answers an inspect of its promise" do
      port = HTTPServer.start_link(@stalled_no_body)
      promise = Web.fetch("http://localhost:#{port}/")

      eventually(fn -> at_head?(promise.pid, :null) end)
      assert inspect(promise) == "#Web.Promise<pending>"
    end
  end

  describe "the signal of a request" do
    test "can be a process that sends the abort" do
      # The process of the signal stays alive during the test.
      signal = spawn(fn -> Process.sleep(2_000) end)
      port = late_server(["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndata"])
      {task, request} = start_fetch(Request.new("http://localhost:#{port}/", signal: signal))

      send(request, {:abort, signal, :stop})
      assert await_fetch(task) == {:error, :aborted}
    end

    test "can be a token" do
      for message <- [&{:abort, &1}, &{:abort, &1, :stop}] do
        token = make_ref()
        port = late_server(["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndata"])
        {task, request} = start_fetch(Request.new("http://localhost:#{port}/", signal: token))

        send(request, message.(token))
        assert await_fetch(task) == {:error, :aborted}
      end
    end

    test "aborts when its process stops with no abort" do
      controller = Web.AbortController.new()
      port = late_server(["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndata"])

      {task, request} =
        start_fetch(Request.new("http://localhost:#{port}/", signal: controller.signal))

      # The request starts after the subscription to the signal.
      eventually(fn -> exchange(request) != nil end)
      Process.exit(controller.signal.pid, :kill)
      assert await_fetch(task) == {:error, :aborted}
    end
  end

  describe "a body that the process of the request holds, at its end" do
    test "gives an error to a reader when the connection closes" do
      # The server closes the connection after the first read.
      port = HTTPServer.start_link(["HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\ndata", :gate])

      {resp, request} = fetch_with_process(Request.new("http://localhost:#{port}/"))
      read = read_until_stalled(resp)
      assert_receive {:http_server_gate, ^port, server}, 5_000
      send(server, :go)

      assert %Web.TypeError{
               message: "The response body is not complete.",
               cause: %Mint.TransportError{reason: :closed}
             } = catch_exit(Web.await(read))

      eventually(fn -> stopped?([request]) end)
    end

    test "gives all its bytes to a read after the end" do
      port =
        HTTPServer.start_link([
          "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\ndata",
          {:sleep, 50},
          "more"
        ])

      {resp, request} = fetch_with_process(Request.new("http://localhost:#{port}/"))
      # At the end of the body, the socket goes back to the pool.
      eventually(fn -> socket_of(request) == nil end)

      # A message with no use has no effect.
      send(request, :no_use)
      assert Web.await(Web.Response.text(resp)) == "datamore"
    end

    test "with no time limit stays for a later read" do
      previous = Application.get_env(:web, :unread_body_timeout)
      Application.put_env(:web, :unread_body_timeout, :infinity)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:web, :unread_body_timeout, previous),
          else: Application.delete_env(:web, :unread_body_timeout)
      end)

      {resp, _request} = stalled_response()
      # The read comes some time after the response. The body has no time
      # limit, thus it stays.
      Process.sleep(50)

      assert %{done: false} =
               Web.await(
                 Web.ReadableStreamDefaultReader.read(ReadableStream.get_reader(resp.body))
               )
    end

    test "stops after the linger time when its owner stops with no failure" do
      port =
        HTTPServer.start_link([
          "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\ndata",
          {:sleep, 2_000}
        ])

      test = self()

      {owner, monitor} =
        spawn_monitor(fn ->
          send(test, {:response, Web.await(Web.fetch("http://localhost:#{port}/"))})
        end)

      assert_receive {:response, resp}, 2_000
      # The owner stops after it sent the response.
      assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1_000
      refute Process.alive?(owner)
      %{source: {:held, request}} = resp.body.lazy

      eventually(fn -> stopped?([request]) end)
      assert %Web.TypeError{} = catch_exit(Web.await(Web.Response.text(resp)))
    end

    test "stays for a stream read when its owner stops" do
      port =
        HTTPServer.start_link([
          "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\ndata",
          {:sleep, 100},
          "more"
        ])

      test = self()

      owner =
        spawn(fn ->
          send(test, {:response, Web.await(Web.fetch("http://localhost:#{port}/"))})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:response, resp}, 2_000
      reader = ReadableStream.get_reader(resp.body)
      send(owner, :stop)

      assert Enum.join(read_chunks(reader)) == "datamore"
    end

    test "gives the reason of an abort to a read of all the bytes that waits" do
      controller = Web.AbortController.new()
      {resp, request} = stalled_response(signal: controller.signal)
      :erlang.trace(request, true, [:receive])
      read = Web.Response.text(resp)

      # The body is used when `text/1` returns. The process of the promise
      # then asks the holder for the bytes: the request is in the mailbox of
      # the holder before the abort.
      assert Web.Response.body_used?(resp)

      assert_receive {:trace, ^request, :receive, {:web_body, _ref, {:take, _monitor, _pid}}},
                     1_000

      :erlang.trace(request, false, [:receive])

      Web.AbortController.abort(controller, :stop)
      assert catch_exit(Web.await(read)) == :stop
    end
  end

  defp read_chunks(reader) do
    case Web.await(Web.ReadableStreamDefaultReader.read(reader)) do
      %{done: true} -> []
      %{value: chunk} -> [Web.Uint8Array.to_binary(chunk) | read_chunks(reader)]
    end
  end

  describe "the time before the promise settles" do
    # The process of the request stops after it sent the request, while the
    # response comes. Thus the messages of the socket wait in its mailbox,
    # before the message of the test.
    defp suspended_fetch(response, options) do
      port = late_server(response)
      {task, request} = start_fetch(Request.new("http://localhost:#{port}/", options))
      assert_receive {:http_server_gate, ^port, server}, 5_000
      eventually(fn -> listens?(request) end)
      :erlang.suspend_process(request)
      send(server, :go)
      eventually(fn -> Enum.any?(mailbox(request), &match?({:tcp, _socket, _data}, &1)) end)
      {task, request}
    end

    # The socket sends its next message to the process of the request.
    defp listens?(request) do
      case socket_of(request) do
        nil -> false
        socket -> :inet.getopts(socket, [:active]) == {:ok, [active: :once]}
      end
    end

    defp mailbox(pid) do
      {:messages, messages} = Process.info(pid, :messages)
      messages
    end

    @partial ["HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\ndata", {:sleep, 2_000}]

    test "an abort gives a response whose body has the reason" do
      controller = Web.AbortController.new()
      {task, request} = suspended_fetch(@partial, signal: controller.signal)

      Web.AbortController.abort(controller, :stop)
      :erlang.resume_process(request)

      assert {:ok, resp} = await_fetch(task)
      assert catch_exit(Web.await(Web.Response.text(resp))) == :stop
    end

    test "the end of the owner stops the request" do
      {task, request} = suspended_fetch(@partial, [])

      Process.exit(task.pid, :kill)
      :erlang.resume_process(request)
      eventually(fn -> stopped?([request]) end)
    end

    test "a message with no use has no effect" do
      {task, request} = suspended_fetch(@partial, [])

      send(request, :no_use)
      :erlang.resume_process(request)
      assert {:ok, %Web.Response{status: 200}} = await_fetch(task)
    end

    test "an abort after the end of the body keeps the response" do
      controller = Web.AbortController.new()

      {task, request} =
        suspended_fetch(["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndata"],
          signal: controller.signal
        )

      # The full response is in the mailbox before the abort.
      Web.AbortController.abort(controller, :stop)
      :erlang.resume_process(request)

      assert {:ok, resp} = await_fetch(task)
      assert {:bytes, "data"} = resp.body.lazy.source
    end
  end

  describe "an abort" do
    test "with an exception as the reason gives that exception to the reader" do
      controller = Web.AbortController.new()
      {resp, request} = stalled_response(signal: controller.signal)
      read = read_until_stalled(resp)

      reason = %RuntimeError{message: "the caller stopped the request"}
      assert :ok = Web.AbortController.abort(controller, reason)

      assert catch_exit(Web.await(read)) == reason
      # The abort stops the process of the request.
      eventually(fn -> stopped?([request]) end)
    end

    test "before the response of a HEAD request rejects, and stops the request" do
      controller = Web.AbortController.new()

      port = late_server(["HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"])

      req =
        Request.new("http://localhost:#{port}/head", method: "HEAD", signal: controller.signal)

      {task, request} = start_fetch(req)

      # The server has the request.
      assert_receive {:http_server_gate, ^port, _server}, 5_000
      assert :ok = Web.AbortController.abort(controller, :stop)

      assert await_fetch(task) == {:error, :aborted}
      eventually(fn -> stopped?([request]) end)
    end

    test "of a fetch rejects with the reason of the signal" do
      controller = Web.AbortController.new()
      port = late_server(["HTTP/1.1 204 No Content\r\n\r\n"])
      promise = Web.fetch("http://localhost:#{port}/", signal: controller.signal)

      # The server has the request.
      assert_receive {:http_server_gate, ^port, _server}, 5_000
      assert :ok = Web.AbortController.abort(controller, :stopped)
      assert catch_exit(Web.await(promise)) == :stopped
    end
  end

  describe "a response with no body" do
    test "gives an error when its connection fails" do
      # A response with the status 205 has no body for the Fetch Standard. The
      # HTTP client reads its content length, and the connection closes
      # before the end.
      port =
        HTTPServer.start_link(["HTTP/1.1 205 Reset Content\r\nContent-Length: 10\r\n\r\nab"])

      {task, _request} = start_fetch(Request.new("http://localhost:#{port}/"))

      assert {:error, %Web.TypeError{message: "The response body is not complete."}} =
               await_fetch(task)
    end

    test "gives an error when the process of the request stops" do
      port =
        HTTPServer.start_link([
          "HTTP/1.1 205 Reset Content\r\nContent-Length: 10\r\n\r\nab",
          {:sleep, 2_000}
        ])

      {task, request} = start_fetch(Request.new("http://localhost:#{port}/"))
      eventually(fn -> at_head?(request, :null) end)
      Process.exit(request, :kill)

      # The process is the promise: the await gets the error of a promise
      # that stopped.
      assert {:error, %Web.TypeError{message: "The promise is not available." <> _}} =
               await_fetch(task)
    end
  end
end
