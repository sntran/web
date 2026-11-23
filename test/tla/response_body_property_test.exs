defmodule Web.TLA.ResponseBodyPropertyTest do
  # Checks the properties of `tla/ResponseBody.tla` on the real body of a
  # response of `Web.Dispatcher.HTTP`.
  #
  # A server sends a random body in random chunks, and can close the
  # connection before the end. A reader reads all the bytes, reads a
  # stream, cancels the stream, or stops the process of the request. The
  # reader gets the full body or an error, each reader gets an end, and the
  # connection closes after a cancel or a stop.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Web.ReadableStream
  alias Web.ReadableStreamDefaultReader

  @moduletag capture_log: true

  defp reader do
    one_of([
      constant(:bytes),
      constant(:stream),
      # The first chunk is always there: a read of it does not wait for the
      # chunk that the server keeps.
      tuple({constant(:cancel), integer(0..1)}),
      constant(:stop_holder)
    ])
  end

  property "the reader gets the full body or an error, and a cancel closes the connection" do
    check all(
            chunks <-
              list_of(binary(min_length: 1, max_length: 30_000), min_length: 2, max_length: 8),
            failure <- one_of([constant(nil), integer(1..6)]),
            reader <- reader(),
            max_runs: 60
          ) do
      body = IO.iodata_to_binary(chunks)
      # A reader that cancels, or stops the process of the request, does it
      # before the end of the body: the server keeps the last chunk until
      # the test lets it go.
      hold? = match?({:cancel, _count}, reader) or reader == :stop_holder
      failure = if hold? or (failure && failure >= length(chunks)), do: nil, else: failure
      server = start_server(chunks, failure, hold?)
      response = Web.await(Web.fetch("http://localhost:#{server.port}/"))

      check_reader(reader, response, body, failure, server)
      send(server.pid, :finish)
    end
  end

  # FullBodyOrError: the full body, or an error for a body that is not
  # complete.
  defp check_reader(:bytes, response, body, failure, _server) do
    case Web.Promise.wait(Web.Response.bytes(response)) do
      {:fulfilled, bytes} -> assert failure == nil and Web.Uint8Array.to_binary(bytes) == body
      {:rejected, error} -> assert failure != nil and match?(%Web.TypeError{}, error)
    end
  end

  # A stream read gives a prefix of the body, then the end or an error.
  defp check_reader(:stream, response, body, failure, _server) do
    reader = ReadableStream.get_reader(response.body)

    case read_all(reader, []) do
      {:done, bytes} -> assert failure == nil and bytes == body
      {:error, bytes} -> assert failure != nil and String.starts_with?(body, bytes)
    end
  end

  # CancelClosesConnection: the cancel closes the connection. The wait is
  # shorter than the linger time of 5 s: the close does not come from the
  # stop of the process of the request at the end of that time.
  defp check_reader({:cancel, count}, response, _body, _failure, server) do
    reader = ReadableStream.get_reader(response.body)
    for _index <- 1..count//1, do: Web.await(ReadableStreamDefaultReader.read(reader))
    assert :ok = Web.await(ReadableStreamDefaultReader.cancel(reader))
    assert_receive {:client_closed, ^server}, 2_000
  end

  # A holder that stops gives an error to the reader, and its socket closes.
  defp check_reader(:stop_holder, response, body, _failure, server) do
    reader = ReadableStream.get_reader(response.body)
    read = ReadableStreamDefaultReader.read(reader)

    case response.body.lazy.source do
      {:held, holder} -> Process.exit(holder, :kill)
    end

    # A chunk that was in the queue comes before the error.
    assert {:error, bytes} = read_rest(read, reader)
    assert String.starts_with?(body, bytes)
    assert_receive {:client_closed, ^server}, 3_000
  end

  defp read_all(reader, acc), do: read_rest(ReadableStreamDefaultReader.read(reader), reader, acc)

  defp read_rest(read, reader, acc \\ []) do
    case Web.Promise.wait(read) do
      {:fulfilled, %{done: true}} -> {:done, finish(acc)}
      {:fulfilled, %{value: chunk}} -> read_all(reader, [Web.Uint8Array.to_binary(chunk) | acc])
      {:rejected, _error} -> {:error, finish(acc)}
    end
  end

  defp finish(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # A server that sends the chunks with a short pause. With a failure, it
  # closes the connection after that number of chunks. With `hold?`, it
  # keeps the last chunk until the test lets it go, and tells the test when
  # the client closes the connection.
  defp start_server(chunks, failure, hold?) do
    test = self()
    ref = make_ref()

    pid =
      spawn_link(fn ->
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
        {:ok, port} = :inet.port(listener)
        send(test, {ref, port})
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0)

        size = chunks |> Enum.map(&byte_size/1) |> Enum.sum()
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: #{size}\r\n\r\n")
        {sent, last} = if hold?, do: Enum.split(chunks, -1), else: {chunks, []}
        sent = if failure, do: Enum.take(sent, failure), else: sent

        for chunk <- sent do
          _result = :gen_tcp.send(socket, chunk)
          Process.sleep(1)
        end

        if failure, do: :gen_tcp.close(socket)
        if hold?, do: wait_for_close(socket, test, %{pid: self(), port: port}, last)

        receive do
          :finish -> :ok
        end
      end)

    receive do
      {^ref, port} -> %{pid: pid, port: port}
    end
  end

  defp wait_for_close(socket, test, server, _last) do
    case :gen_tcp.recv(socket, 0, 3_000) do
      {:error, :closed} -> send(test, {:client_closed, server})
      _other -> :ok
    end
  end
end
