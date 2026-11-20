defmodule Web.Dispatcher.HTTPWorkerTest do
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

  # A response whose body has one chunk, and then nothing for a long time.
  defp stalled_response(options \\ []) do
    port =
      HTTPServer.start_link([
        "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\ndata",
        {:sleep, 2_000}
      ])

    fetch_with_process(Request.new("http://localhost:#{port}/stalled", options))
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
      read = Web.Response.text(resp)
      eventually(fn -> Web.Response.body_used?(resp) end)

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
      # The body is larger than the queue of the stream: the process waits.
      body = :binary.copy("x", 200_000)

      port =
        HTTPServer.start_link([
          "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\n\r\n",
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

      port =
        HTTPServer.start_link([{:sleep, 300}, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"])

      req =
        Request.new("http://localhost:#{port}/head", method: "HEAD", signal: controller.signal)

      {task, request} = start_fetch(req)

      Process.sleep(50)
      assert :ok = Web.AbortController.abort(controller, :stop)

      assert await_fetch(task) == {:error, :aborted}
      eventually(fn -> stopped?([request]) end)
    end

    test "of a fetch rejects with the reason of the signal" do
      controller = Web.AbortController.new()
      port = HTTPServer.start_link([{:sleep, 300}, "HTTP/1.1 204 No Content\r\n\r\n"])
      promise = Web.fetch("http://localhost:#{port}/", signal: controller.signal)

      Process.sleep(50)
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
      Process.sleep(100)
      Process.exit(request, :kill)

      # The process is the promise: the await gets the error of a promise
      # that stopped.
      assert {:error, %Web.TypeError{message: "The promise is not available." <> _}} =
               await_fetch(task)
    end
  end
end
