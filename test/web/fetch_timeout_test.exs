defmodule Web.FetchTimeoutTest do
  # These tests set the timeouts for the application. Thus they cannot run at
  # the same time as other tests.
  use ExUnit.Case, async: false

  use Web

  alias Web.Dispatcher.HTTP.Exchange

  @receive_timeout 150

  setup do
    set_env(:receive_timeout, @receive_timeout)
    :ok
  end

  defp set_env(key, value) do
    previous = Application.get_env(:web, key)
    Application.put_env(:web, key, value)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:web, key)
      else
        Application.put_env(:web, key, previous)
      end
    end)
  end

  # Starts a server that reads one request and then does `script` with the
  # socket. Returns the port.
  defp start_server(script) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)

    pid =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
        script.(socket)

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(pid, :stop) end)
    port
  end

  defp elapsed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started}
  end

  describe "the receive timeout" do
    test "rejects a fetch when the server gives no response headers" do
      port = start_server(fn _socket -> :ok end)

      {outcome, time} = elapsed(fn -> Promise.wait(fetch("http://localhost:#{port}/")) end)

      assert {:rejected, %Web.TypeError{message: message, cause: cause}} = outcome
      assert message == "fetch failed: the server did not answer in time"
      assert %{reason: :timeout} = cause
      assert time >= @receive_timeout
      assert time < 20 * @receive_timeout
    end

    test "puts the body in the errored state when the server stops in the body" do
      port =
        start_server(fn socket ->
          :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\nhello")
        end)

      response = await(fetch("http://localhost:#{port}/"))
      assert response.status == 200

      {outcome, time} = elapsed(fn -> Promise.wait(Response.text(response)) end)

      assert {:rejected, %Web.TypeError{message: "The response body is not complete."} = error} =
               outcome

      assert %{reason: :timeout} = error.cause
      assert time < 20 * @receive_timeout
    end

    test "does not include the time that the reader of the body uses" do
      body = String.duplicate("x", 200_000)

      port =
        start_server(fn socket ->
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n\r\n",
            body
          ])
        end)

      response = await(fetch("http://localhost:#{port}/"))

      # The reader waits for more than the timeout before each read.
      reader = ReadableStream.get_reader(response.body)
      Process.sleep(3 * @receive_timeout)
      assert %{value: first, done: false} = await(ReadableStreamDefaultReader.read(reader))
      Process.sleep(3 * @receive_timeout)

      rest =
        Stream.repeatedly(fn -> await(ReadableStreamDefaultReader.read(reader)) end)
        |> Enum.take_while(&(not &1.done))
        |> Enum.map_join(&Web.TestBytes.binary(&1.value))

      assert Web.TestBytes.binary(first) <> rest == body
    end

    test "does not stop a response that arrives slowly but with no long pause" do
      port =
        start_server(fn socket ->
          :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\n")

          # Each pause is shorter than the timeout.
          for byte <- ~w(h e l l o) do
            Process.sleep(div(@receive_timeout, 3))
            :gen_tcp.send(socket, byte)
          end
        end)

      assert await(Response.text(await(fetch("http://localhost:#{port}/")))) == "hello"
    end

    test "can be removed with the value :infinity" do
      set_env(:receive_timeout, :infinity)

      port =
        start_server(fn socket ->
          # The pause is longer than the timeout that the other tests use.
          Process.sleep(4 * @receive_timeout)
          :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
        end)

      assert await(Response.text(await(fetch("http://localhost:#{port}/")))) == "ok"
    end

    test "stops when the signal of the request aborts first" do
      set_env(:receive_timeout, 60_000)
      port = start_server(fn _socket -> :ok end)

      {outcome, time} =
        elapsed(fn ->
          Promise.wait(fetch("http://localhost:#{port}/", signal: AbortSignal.timeout(100)))
        end)

      assert {:rejected, %Web.DOMException{name: "TimeoutError"}} = outcome
      assert time < 2_000
    end
  end

  describe "the unread time of a tcp: response" do
    test "releases the socket of a body that no process reads, and the read rejects" do
      set_env(:unread_body_timeout, 100)
      test = self()

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listener)

      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        :gen_tcp.send(socket, "data")
        # The server sees the close of the client.
        send(test, {:server_recv, :gen_tcp.recv(socket, 0, 2_000)})
      end)

      response = await(fetch("tcp://localhost:#{port}"))
      assert_receive {:server_recv, {:error, :closed}}, 2_000

      assert %Web.TypeError{message: "The response body is not complete."} =
               catch_exit(await(Response.text(response)))
    end

    test "does not stop a body that a process reads" do
      set_env(:unread_body_timeout, 100)

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listener)

      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        # The data comes after the time limit of a body that no process reads.
        Process.sleep(300)
        :gen_tcp.send(socket, "late data")
        :gen_tcp.close(socket)
      end)

      response = await(fetch("tcp://localhost:#{port}"))
      assert await(Response.text(response)) == "late data"
    end
  end

  describe "the connect timeout" do
    test "has the default of 10 seconds, and comes from the application setting" do
      assert Web.Application.connect_timeout() == 10_000

      set_env(:connect_timeout, 1_234)
      assert Web.Application.connect_timeout() == 1_234

      # Each new connection reads the setting.
      assert Exchange.connect_options(:http, [:http1]) ==
               [
                 mode: :passive,
                 protocols: [:http1],
                 skip_target_validation: true,
                 transport_opts: [timeout: 1_234]
               ]
    end

    test "is the connect time of a socket, unless the socket has its own option" do
      set_env(:connect_timeout, 4_321)
      parent = self()

      connect = fn _host, _port, _opts, timeout ->
        send(parent, {:connect_timeout, timeout})
        {:error, :timeout}
      end

      socket = Web.Socket.start_socket(self(), "localhost:1", %{connect_fun: connect})
      assert_receive {:connect_timeout, 4_321}
      assert catch_exit(await(socket.opened))

      socket =
        Web.Socket.start_socket(self(), "localhost:1", %{
          connect_fun: connect,
          connect_timeout: 77
        })

      assert_receive {:connect_timeout, 77}
      assert catch_exit(await(socket.opened))
    end

    test "rejects a fetch with the cause of the transport" do
      # Port 1 of the local host refuses the connection immediately.
      assert {:rejected, %Web.TypeError{message: "fetch failed", cause: %{reason: :econnrefused}}} =
               Promise.wait(fetch("http://localhost:1/"))
    end
  end

  describe "the wait for a connection" do
    test "has no time limit: more requests than connections are all answered" do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, backlog: 128])

      {:ok, port} = :inet.port(listener)

      acceptor =
        spawn(fn ->
          Stream.repeatedly(fn -> :gen_tcp.accept(listener) end)
          |> Stream.take_while(&match?({:ok, _socket}, &1))
          |> Enum.each(fn {:ok, socket} ->
            spawn(fn ->
              serve = fn serve ->
                case :gen_tcp.recv(socket, 0, 5_000) do
                  # The server answers slowly, thus the requests wait for a
                  # connection of the pool.
                  {:ok, _request} ->
                    Process.sleep(20)
                    :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
                    serve.(serve)

                  {:error, _reason} ->
                    :ok
                end
              end

              serve.(serve)
            end)
            |> then(&:gen_tcp.controlling_process(socket, &1))
          end)
        end)

      on_exit(fn -> Process.exit(acceptor, :kill) end)

      # The pool has 25 connections for one origin.
      texts =
        for _ <- 1..60 do
          fetch("http://localhost:#{port}/") |> Promise.then(&Response.text/1)
        end
        |> Promise.all()
        |> await()

      assert texts == List.duplicate("ok", 60)
    end
  end
end
