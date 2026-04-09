defmodule Web.FetchRedirectTest do
  use ExUnit.Case, async: false
  import Web, only: [await: 1]

  defmodule RedirectServer do
    def start_link do
      parent = self()

      {:ok, pid} =
        Task.start(fn ->
          {:ok, listen_socket} =
            :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

          {:ok, port} = :inet.port(listen_socket)
          send(parent, {:redirect_server_port, port})
          accept_loop(listen_socket, port, parent)
        end)

      port =
        receive do
          {:redirect_server_port, port} -> port
        after
          1000 -> raise "redirect server failed to start"
        end

      %{pid: pid, port: port}
    end

    defp accept_loop(listen_socket, port, parent) do
      {:ok, socket} = :gen_tcp.accept(listen_socket)
      Task.start(fn -> handle_socket(socket, port, parent) end)
      accept_loop(listen_socket, port, parent)
    end

    defp handle_socket(socket, port, parent) do
      handle_requests(socket, port, parent)
    end

    defp handle_requests(socket, port, parent) do
      case read_request(socket) do
        {:ok, {method, path, body}} ->
          case path do
            "/redir-301" ->
              send_response(socket, 301, %{"location" => url(port, "/success")}, "")

            "/redir-303" ->
              send_response(socket, 303, %{"location" => url(port, "/see-other-target")}, "")

            "/redir-relative" ->
              send_response(socket, 307, %{"location" => "/keep-method"}, "")

            "/redir-308" ->
              send_response(socket, 308, %{"location" => "/stream-target"}, "")

            "/redir-no-location" ->
              send_response(socket, 301, %{}, "")

            "/loop" ->
              send_response(socket, 302, %{"location" => url(port, "/loop")}, "")

            "/success" ->
              send_response(socket, 200, %{}, "success")

            "/see-other-target" ->
              send_response(socket, 200, %{}, "#{method}:#{body}")

            "/keep-method" ->
              send_response(socket, 200, %{}, "#{method}:#{body}")

            "/stream-target" ->
              send(parent, {:stream_target_body, body})
              send_response(socket, 200, %{}, "#{method}:#{body}")

            "/redirect-stream" ->
              send_response(socket, 301, %{"location" => url(port, "/success")}, "chunk")

              Task.start(fn ->
                case :gen_tcp.recv(socket, 0, 2000) do
                  {:error, :closed} -> send(parent, :redirect_body_closed)
                  _ -> :ok
                end
              end)

            _ ->
              send_response(socket, 404, %{}, "missing")
          end

          handle_requests(socket, port, parent)

        :closed ->
          :gen_tcp.close(socket)
      end
    end

    defp read_request(socket, data \\ "") do
      case String.split(data, "\r\n\r\n", parts: 2) do
        [headers, rest] ->
          [request_line | header_lines] = String.split(headers, "\r\n", trim: true)
          [method, path, _version] = String.split(request_line, " ", parts: 3)

          content_length =
            header_lines
            |> parse_headers()
            |> Map.get("content-length", "0")
            |> String.to_integer()

          cond do
            byte_size(rest) >= content_length ->
              {:ok, {method, path, binary_part(rest, 0, content_length)}}

            content_length == 0 ->
              {:ok, {method, path, ""}}

            true ->
              case :gen_tcp.recv(socket, 0, 5000) do
                {:ok, chunk} -> read_request(socket, data <> chunk)
                {:error, :timeout} -> {:ok, {method, path, rest}}
                {:error, :closed} -> :closed
              end
          end

        [_incomplete] ->
          case :gen_tcp.recv(socket, 0, 5000) do
            {:ok, chunk} -> read_request(socket, data <> chunk)
            {:error, :closed} -> :closed
          end
      end
    end

    defp parse_headers(lines) do
      Enum.reduce(lines, %{}, fn line, headers ->
        [key, value] = String.split(line, ":", parts: 2)
        Map.put(headers, String.downcase(key), String.trim_leading(value))
      end)
    end

    defp send_response(socket, status, headers, body) do
      reason =
        case status do
          200 -> "OK"
          301 -> "Moved Permanently"
          302 -> "Found"
          303 -> "See Other"
          307 -> "Temporary Redirect"
          308 -> "Permanent Redirect"
          404 -> "Not Found"
        end

      response_headers =
        headers
        |> Map.put_new("content-length", Integer.to_string(byte_size(body)))
        |> Enum.map_join("", fn {key, value} -> "#{key}: #{value}\r\n" end)

      :gen_tcp.send(socket, "HTTP/1.1 #{status} #{reason}\r\n#{response_headers}\r\n#{body}")
    end

    defp url(port, path), do: "http://localhost:#{port}#{path}"
  end

  setup do
    server = RedirectServer.start_link()
    on_exit(fn -> Process.exit(server.pid, :kill) end)
    {:ok, port: server.port}
  end

  test "301 redirect following resolves to the successful target", %{port: port} do
    resp = await(Web.fetch("http://localhost:#{port}/redir-301", redirect: "follow"))

    assert resp.status == 200
    assert resp.url == "http://localhost:#{port}/success"
    assert Enum.to_list(resp.body) == ["success"]
  end

  test "redirect loop stops after the fetch maximum", %{port: port} do
    assert :too_many_redirects =
             catch_exit(await(Web.fetch("http://localhost:#{port}/loop")))
  end

  test "redirect manual returns the original 301 response", %{port: port} do
    resp = await(Web.fetch("http://localhost:#{port}/redir-301", redirect: "manual"))

    assert resp.status == 301
    assert Web.Headers.get(resp.headers, "location") == "http://localhost:#{port}/success"
  end

  test "redirect error returns redirect_error", %{port: port} do
    assert :redirect_error =
             catch_exit(await(Web.fetch("http://localhost:#{port}/redir-301", redirect: "error")))
  end

  test "303 switches to GET and strips the request body", %{port: port} do
    resp =
      await(
        Web.fetch("http://localhost:#{port}/redir-303",
          method: "POST",
          headers: %{"content-length" => "7"},
          body: "payload"
        )
      )

    assert resp.status == 200
    assert Enum.to_list(resp.body) == ["GET:"]
  end

  test "307 keeps method and body while following a relative location", %{port: port} do
    resp =
      await(
        Web.fetch("http://localhost:#{port}/redir-relative",
          method: "POST",
          headers: %{"content-length" => "7"},
          body: "payload"
        )
      )

    assert resp.status == 200
    assert resp.url == "http://localhost:#{port}/keep-method"
    assert Enum.to_list(resp.body) == ["POST:payload"]
  end

  test "307 preserves a streaming request body through redirect follow", %{port: port} do
    body =
      Web.ReadableStream.new(%{
        start: fn controller ->
          Web.ReadableStreamDefaultController.enqueue(controller, "pay")
          Web.ReadableStreamDefaultController.enqueue(controller, "load")
          Web.ReadableStreamDefaultController.close(controller)
        end
      })

    resp =
      await(
        Web.fetch("http://localhost:#{port}/redir-relative",
          method: "POST",
          headers: %{"content-length" => "7"},
          body: body
        )
      )

    assert resp.status == 200
    assert Enum.to_list(resp.body) == ["POST:payload"]
  end

  test "follow closes the previous response body before opening the next request", %{port: port} do
    resp = await(Web.fetch("http://localhost:#{port}/redirect-stream", redirect: "follow"))

    assert Enum.to_list(resp.body) == ["success"]
  end

  test "308 preserves a streaming request body through redirect follow", %{port: port} do
    body =
      Web.ReadableStream.new(%{
        start: fn controller ->
          Web.ReadableStreamDefaultController.enqueue(controller, "pay")
          Web.ReadableStreamDefaultController.enqueue(controller, "load")
          Web.ReadableStreamDefaultController.close(controller)
        end
      })

    resp =
      await(
        Web.fetch("http://localhost:#{port}/redir-308",
          method: "POST",
          headers: %{"content-length" => "7"},
          body: body
        )
      )

    assert resp.status == 200
    assert_receive {:stream_target_body, "payload"}
    assert Enum.to_list(resp.body) == ["POST:payload"]
  end

  test "redirect with no location returns the original response", %{port: port} do
    resp = await(Web.fetch("http://localhost:#{port}/redir-no-location", redirect: "follow"))

    assert resp.status == 301
    assert Enum.to_list(resp.body) == []
  end
end
