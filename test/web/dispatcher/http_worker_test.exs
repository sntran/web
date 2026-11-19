defmodule Web.Dispatcher.HTTPWorkerTest do
  # These tests stop the processes of a request at a known time. A task of a
  # stream that loses its source writes an error to the log, thus the tests
  # do not run at the same time as tests that examine the log.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Web.Dispatcher.HTTP
  alias Web.Dispatcher.HTTPTest.HTTPServer
  alias Web.Request

  # Runs the request in a different process, and returns that process with
  # the worker of the request: the first process that the request makes.
  # The process has no link to the test, thus a test can stop it.
  defp start_fetch(req) do
    test = self()

    pid =
      spawn(fn ->
        receive do
          :go -> :ok
        end

        result =
          try do
            HTTP.fetch(req)
          rescue
            error -> {:raised, error}
          end

        send(test, {:fetched, self(), result})
      end)

    :erlang.trace(pid, true, [:procs])
    send(pid, :go)
    assert_receive {:trace, ^pid, :spawn, worker, _mfa}, 1_000
    {%{pid: pid}, worker}
  end

  defp await_fetch(%{pid: pid}) do
    assert_receive {:fetched, ^pid, result}, 5_000
    result
  end

  # Runs the request, and returns the response with the worker and the
  # watcher of its body: the first two processes that the request makes.
  defp fetch_with_processes(req) do
    {task, worker} = start_fetch(req)
    assert_receive {:trace, _fetcher, :spawn, watcher, _mfa}, 1_000
    assert {:ok, resp} = await_fetch(task)
    {resp, worker, watcher}
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

    fetch_with_processes(Request.new("http://localhost:#{port}/stalled", options))
  end

  # Reads the first chunk, then starts the read of the subsequent one.
  defp read_until_stalled(resp) do
    reader = Web.ReadableStream.get_reader(resp.body)
    assert %{done: false} = Web.await(Web.ReadableStreamDefaultReader.read(reader))
    Web.ReadableStreamDefaultReader.read(reader)
  end

  test "a reader that waits gets an error when the worker stops" do
    {resp, worker, watcher} = stalled_response()
    read = read_until_stalled(resp)

    Process.exit(worker, :kill)

    assert %Web.TypeError{
             message: "The response body is not complete.",
             cause: {:connection_process_stopped, :killed}
           } = catch_exit(Web.await(read))

    eventually(fn -> stopped?([watcher]) end)
  end

  test "a body continues when the watcher stops" do
    port = HTTPServer.start_link(["HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\ndata", "more"])
    {resp, _worker, watcher} = fetch_with_processes(Request.new("http://localhost:#{port}/"))

    Process.exit(watcher, :kill)

    assert Web.await(Web.Response.text(resp)) == "datamore"
  end

  test "the processes of a request stop when the process that reads the body stops" do
    {resp, worker, watcher} = stalled_response()
    parent = self()

    reader =
      spawn(fn ->
        _read = read_until_stalled(resp)
        send(parent, :reading)
        Process.sleep(:infinity)
      end)

    assert_receive :reading, 1_000
    Process.exit(reader, :kill)

    eventually(fn -> stopped?([worker, watcher]) end)
  end

  test "an abort with an exception as the reason gives that exception to the reader" do
    controller = Web.AbortController.new()
    {resp, worker, watcher} = stalled_response(signal: controller.signal)
    read = read_until_stalled(resp)

    reason = %RuntimeError{message: "the caller stopped the request"}
    assert :ok = Web.AbortController.abort(controller, reason)

    assert catch_exit(Web.await(read)) == reason
    # The abort stops the processes of the request.
    eventually(fn -> stopped?([worker, watcher]) end)
  end

  # The process of the request stops for a short time. The head of the
  # response arrives in its mailbox. Then the function runs.
  defp after_head(task, fun) do
    :erlang.suspend_process(task.pid)

    eventually(fn ->
      {:messages, messages} = Process.info(task.pid, :messages)
      Enum.any?(messages, &match?({:http_head, _ref, _status, _headers}, &1))
    end)

    fun.()
  end

  test "an abort that comes together with the head of a response stops the request" do
    controller = Web.AbortController.new()

    port =
      HTTPServer.start_link([{:sleep, 100}, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"])

    # A response to this method has no body: the request reads the response
    # to its end before it returns.
    req = Request.new("http://localhost:#{port}/head", method: "HEAD", signal: controller.signal)
    {task, worker} = start_fetch(req)

    reason = %RuntimeError{message: "the caller stopped the request"}

    after_head(task, fn ->
      assert :ok = Web.AbortController.abort(controller, reason)
      eventually(fn -> not Process.alive?(controller.signal.pid) end)
      :erlang.resume_process(task.pid)
    end)

    assert await_fetch(task) == {:raised, reason}
    eventually(fn -> stopped?([worker]) end)
  end

  test "an abort with a reason that is not an exception gives an AbortError" do
    controller = Web.AbortController.new()

    port =
      HTTPServer.start_link([{:sleep, 100}, "HTTP/1.1 204 No Content\r\n\r\n"])

    req = Request.new("http://localhost:#{port}/", signal: controller.signal)
    {task, _worker} = start_fetch(req)

    after_head(task, fn ->
      assert :ok = Web.AbortController.abort(controller, :stopped)
      eventually(fn -> not Process.alive?(controller.signal.pid) end)
      :erlang.resume_process(task.pid)
    end)

    assert {:raised, %Web.DOMException{name: "AbortError", message: ":stopped"}} =
             await_fetch(task)
  end

  test "the worker stops when the process that called fetch stops before the body" do
    parent = self()

    port =
      HTTPServer.start_link(
        ["HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\ndata", {:sleep, 2_000}],
        false,
        false,
        parent
      )

    {task, worker} = start_fetch(Request.new("http://localhost:#{port}/"))
    after_head(task, fn -> Process.exit(task.pid, :kill) end)

    eventually(fn -> stopped?([worker]) end)
  end

  test "the worker stops when the stream is errored before the next chunk" do
    controller = Web.AbortController.new()

    port =
      HTTPServer.start_link([
        "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\ndata",
        {:sleep, 200},
        "more"
      ])

    {_resp, worker, watcher} =
      fetch_with_processes(Request.new("http://localhost:#{port}/", signal: controller.signal))

    # The watcher does not stop the worker at the abort. Thus the worker
    # finds the errored stream when the next chunk arrives.
    :erlang.suspend_process(watcher)
    assert :ok = Web.AbortController.abort(controller, :no_more)

    eventually(fn -> stopped?([worker]) end)
    :erlang.resume_process(watcher)
    eventually(fn -> stopped?([watcher]) end)
  end

  test "the worker stops when the stream stops while the worker waits for a pull" do
    # The body is larger than the queue of the stream: the worker waits.
    body = :binary.copy("x", 200_000)

    port =
      HTTPServer.start_link([
        "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\n\r\n",
        body,
        {:sleep, 2_000}
      ])

    {resp, worker, watcher} = fetch_with_processes(Request.new("http://localhost:#{port}/"))

    eventually(fn ->
      {:current_function, function} = Process.info(worker, :current_function)
      function == {Web.Dispatcher.HTTP, :await_demand, 2}
    end)

    Process.exit(resp.body.controller_pid, :kill)

    eventually(fn -> stopped?([worker, watcher]) end)
  end

  test "the worker keeps a full body readable until a process reads it" do
    port = HTTPServer.start_link(["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndata"])
    {resp, worker, watcher} = fetch_with_processes(Request.new("http://localhost:#{port}/"))

    # The response is complete, and the worker waits until the queue of the
    # stream is empty. A stream that stops ends the wait.
    eventually(fn ->
      {:current_function, function} = Process.info(worker, :current_function)
      function == {Web.Dispatcher.HTTP, :await_drain, 1}
    end)

    Process.exit(resp.body.controller_pid, :kill)

    eventually(fn -> stopped?([worker, watcher]) end)
  end

  test "a response with no body gives an error when its connection fails" do
    # A response with the status 205 has no body for the Fetch Standard. The
    # HTTP client reads its content length, and the connection closes
    # before the end.
    port = HTTPServer.start_link(["HTTP/1.1 205 Reset Content\r\nContent-Length: 10\r\n\r\nab"])
    {task, _worker} = start_fetch(Request.new("http://localhost:#{port}/"))

    assert {:raised, %Web.TypeError{message: "The response body is not complete."}} =
             await_fetch(task)
  end

  test "a response with no body gives an error when its worker stops" do
    port =
      HTTPServer.start_link([
        "HTTP/1.1 205 Reset Content\r\nContent-Length: 10\r\n\r\nab",
        {:sleep, 2_000}
      ])

    {task, worker} = start_fetch(Request.new("http://localhost:#{port}/"))
    after_head(task, fn -> :ok end)
    Process.exit(worker, :kill)
    :erlang.resume_process(task.pid)

    assert {:raised,
            %Web.TypeError{
              message: "The response body is not complete.",
              cause: {:connection_process_stopped, :killed}
            }} = await_fetch(task)
  end
end
