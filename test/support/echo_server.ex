defmodule Web.Test.EchoServer do
  @moduledoc false

  # A small HTTP/1.1 server for the fetch tests.
  #
  #   * `/echo` gives the request back as text: the method, the headers, and
  #     the body, each on its own line.
  #   * `/target` gives the request target and the header `host`.
  #   * `/redirect/<status>?to=<location>` gives a redirect to the location.
  #   * `/truncated` gives a body that is shorter than its content length.
  #   * `/hold` gives the start of a body and keeps the connection open. It
  #     sends `:server_connection_closed` to the test process when the client
  #     closes the connection.
  #
  # The server sends `{:server_chunk, data}` to the test process for each
  # chunk of a chunked request body.

  @spec start(pid()) :: non_neg_integer()
  def start(parent) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    {:ok, pid} = Task.start(fn -> accept_loop(listen_socket, parent) end)
    :ok = :gen_tcp.controlling_process(listen_socket, pid)
    port
  end

  defp accept_loop(listen_socket, parent) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        {:ok, pid} = Task.start(fn -> serve(socket, parent) end)
        :gen_tcp.controlling_process(socket, pid)
        accept_loop(listen_socket, parent)

      {:error, _reason} ->
        :ok
    end
  end

  defp serve(socket, parent) do
    with {:ok, head, rest} <- read_head(socket, ""),
         {method, target, headers} = parse_head(head),
         {:ok, body} <- read_body(socket, headers, rest, parent) do
      respond(socket, method, target, headers, body)
      if target == "/hold", do: wait_for_close(socket, parent)
    end

    :gen_tcp.close(socket)
  end

  defp read_head(socket, data) do
    case String.split(data, "\r\n\r\n", parts: 2) do
      [head, rest] -> {:ok, head, rest}
      [_incomplete] -> receive_more(socket, data, &read_head/2)
    end
  end

  defp receive_more(socket, data, continue) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} -> continue.(socket, data <> chunk)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_head(head) do
    [request_line | header_lines] = String.split(head, "\r\n")
    [method, target, _version] = String.split(request_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    {method, target, headers}
  end

  defp read_body(socket, %{"transfer-encoding" => "chunked"}, rest, parent) do
    read_chunks(socket, rest, [], parent)
  end

  defp read_body(socket, headers, rest, _parent) do
    length = headers |> Map.get("content-length", "0") |> String.to_integer()
    read_length(socket, rest, length)
  end

  defp read_length(_socket, data, length) when byte_size(data) >= length do
    {:ok, binary_part(data, 0, length)}
  end

  defp read_length(socket, data, length) do
    receive_more(socket, data, &read_length(&1, &2, length))
  end

  defp read_chunks(socket, data, acc, parent) do
    with [size_line, rest] <- String.split(data, "\r\n", parts: 2),
         size = String.to_integer(size_line, 16),
         true <- byte_size(rest) >= size + 2 do
      if size == 0 do
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
      else
        chunk = binary_part(rest, 0, size)
        send(parent, {:server_chunk, chunk})
        rest = binary_part(rest, size + 2, byte_size(rest) - size - 2)
        read_chunks(socket, rest, [chunk | acc], parent)
      end
    else
      _incomplete -> receive_more(socket, data, &read_chunks(&1, &2, acc, parent))
    end
  end

  defp respond(socket, method, "/echo" <> _query, headers, body) do
    header_text =
      headers
      |> Enum.sort()
      |> Enum.map_join(";", fn {name, value} -> "#{name}=#{value}" end)

    send_response(socket, 200, [], Enum.join([method, header_text, body], "\n"))
  end

  # The request target and the header `host`, as the server got them.
  defp respond(socket, _method, "/target" <> _rest = target, headers, _body) do
    send_response(socket, 200, [], target <> "\n" <> Map.get(headers, "host", ""))
  end

  defp respond(socket, _method, "/redirect/" <> rest, _headers, _body) do
    [status, query] = String.split(rest, "?", parts: 2)
    %{"to" => location} = URI.decode_query(query)
    send_response(socket, String.to_integer(status), [{"location", location}], "")
  end

  defp respond(socket, _method, "/truncated", _headers, _body) do
    :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 50\r\n\r\npartial")
  end

  defp respond(socket, _method, "/hold", _headers, _body) do
    :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\nstart")
  end

  defp respond(socket, _method, _target, _headers, _body) do
    send_response(socket, 404, [], "not found")
  end

  defp wait_for_close(socket, parent) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:error, :closed} -> send(parent, :server_connection_closed)
      _other -> :ok
    end
  end

  defp send_response(socket, status, headers, body) do
    header_text =
      [{"content-length", Integer.to_string(byte_size(body))}, {"connection", "close"} | headers]
      |> Enum.map_join("", fn {name, value} -> "#{name}: #{value}\r\n" end)

    :gen_tcp.send(socket, "HTTP/1.1 #{status} Status\r\n#{header_text}\r\n#{body}")
  end
end
