defmodule Web.Dispatcher.HTTPBridgeTest do
  # These tests stop the processes of a connection at a known time. A task
  # of a stream that loses its source writes an error to the log, thus the
  # tests do not run at the same time as tests that examine the log.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Web.Dispatcher.HTTP
  alias Web.Dispatcher.HTTPTest.HTTPServer
  alias Web.Request

  # Runs the request, and returns the response with the bridge process of
  # its connection. The bridge is the first process that the request makes.
  defp fetch_with_bridge(req) do
    task =
      Task.async(fn ->
        receive do
          :go -> HTTP.fetch(req)
        end
      end)

    :erlang.trace(task.pid, true, [:procs])
    send(task.pid, :go)
    assert_receive {:trace, _fetcher, :spawn, bridge, _mfa}, 1_000
    assert {:ok, resp} = Task.await(task)
    {resp, bridge}
  end

  defp monitored(pid) do
    {:monitors, monitors} = Process.info(pid, :monitors)
    for {:process, monitored} <- monitors, do: monitored
  end

  # The two processes that the bridge monitors when a reader waits: the
  # worker, which runs the request of the HTTP client, and the process that
  # reads the body.
  defp worker_and_consumer(bridge) do
    eventually(fn -> length(monitored(bridge)) == 2 end)
    {[worker], [consumer]} = Enum.split_with(monitored(bridge), &in_http_client?/1)
    {worker, consumer}
  end

  defp in_http_client?(pid) do
    {:current_stacktrace, stacktrace} = Process.info(pid, :current_stacktrace)

    Enum.any?(stacktrace, fn {module, _function, _arity, _location} ->
      module |> Atom.to_string() |> String.starts_with?("Elixir.Finch")
    end)
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition did not become true")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  # A response whose body has one chunk, and then nothing for a long time.
  defp stalled_response(options) do
    port =
      HTTPServer.start_link([
        "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\ndata",
        {:sleep, 2_000}
      ])

    fetch_with_bridge(Request.new("http://localhost:#{port}/stalled", options))
  end

  # Reads the first chunk, then starts the read of the subsequent one.
  defp read_until_stalled(resp) do
    reader = Web.ReadableStream.get_reader(resp.body)
    assert %{done: false} = Web.await(Web.ReadableStreamDefaultReader.read(reader))
    Web.ReadableStreamDefaultReader.read(reader)
  end

  test "a reader that waits gets an error when the bridge process stops" do
    {resp, bridge} = stalled_response([])
    read = read_until_stalled(resp)

    {_worker, _consumer} = worker_and_consumer(bridge)
    Process.exit(bridge, :kill)

    assert %Web.TypeError{
             message: "The response body is not complete.",
             cause: {:connection_process_stopped, :killed}
           } = catch_exit(Web.await(read))
  end

  test "a reader that waits gets an error when the connection process stops" do
    {resp, bridge} = stalled_response([])
    read = read_until_stalled(resp)

    {worker, _consumer} = worker_and_consumer(bridge)
    Process.exit(worker, :kill)

    assert %Web.TypeError{
             message: "The response body is not complete.",
             cause: {:connection_process_stopped, :killed}
           } = catch_exit(Web.await(read))
  end

  test "the connection processes stop when the process that reads the body stops" do
    {resp, bridge} = stalled_response([])
    _read = read_until_stalled(resp)

    {worker, consumer} = worker_and_consumer(bridge)
    Process.exit(consumer, :kill)

    eventually(fn -> not Process.alive?(bridge) and not Process.alive?(worker) end)
  end

  test "an abort with an exception as the reason gives that exception to the reader" do
    controller = Web.AbortController.new()
    {resp, bridge} = stalled_response(signal: controller.signal)
    read = read_until_stalled(resp)
    {worker, _consumer} = worker_and_consumer(bridge)

    reason = %RuntimeError{message: "the caller stopped the request"}
    assert :ok = Web.AbortController.abort(controller, reason)

    assert catch_exit(Web.await(read)) == reason
    # The abort stops the connection processes.
    eventually(fn -> not Process.alive?(bridge) and not Process.alive?(worker) end)
  end

  test "an abort that comes together with the head of a response stops the request" do
    controller = Web.AbortController.new()

    port =
      HTTPServer.start_link([{:sleep, 100}, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"])

    # A response to this method has no body: the request reads the response
    # to its end before it returns.
    req = Request.new("http://localhost:#{port}/head", method: "HEAD", signal: controller.signal)

    task =
      Task.async(fn ->
        receive do
          :go -> :ok
        end

        try do
          HTTP.fetch(req)
        rescue
          error -> {:raised, error}
        end
      end)

    :erlang.trace(task.pid, true, [:procs])
    send(task.pid, :go)
    assert_receive {:trace, _fetcher, :spawn, _bridge, _mfa}, 1_000

    # The process of the request stops for a short time. The head of the
    # response arrives in its mailbox, and then the abort.
    :erlang.suspend_process(task.pid)

    eventually(fn ->
      {:messages, messages} = Process.info(task.pid, :messages)
      Enum.any?(messages, &match?({:bridge_ready, _ref, 200, _headers}, &1))
    end)

    reason = %RuntimeError{message: "the caller stopped the request"}
    assert :ok = Web.AbortController.abort(controller, reason)
    eventually(fn -> not Process.alive?(controller.signal.pid) end)
    :erlang.resume_process(task.pid)

    assert Task.await(task) == {:raised, reason}
  end
end
