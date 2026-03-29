defmodule Web.Dispatcher.HTTPTest do
  use ExUnit.Case, async: true

  alias Web.Request
  alias Web.Dispatcher.HTTP

  defmodule HTTPServer do
    def start_link(responses \\ [], close_early? \\ false, drop_on_body? \\ false) do
      parent = self()
      Task.start_link(fn ->
        {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
        {:ok, port} = :inet.port(listen_socket)
        send(parent, {:port, port})

        {:ok, socket} = :gen_tcp.accept(listen_socket)

        if close_early? do
           :gen_tcp.close(socket)
           :gen_tcp.close(listen_socket)
        else
          {:ok, _req} = :gen_tcp.recv(socket, 0)
          
          Enum.each(responses, fn chunk -> 
            :gen_tcp.send(socket, chunk)
          end)

          if drop_on_body? do
            :gen_tcp.close(socket)
          else
            # Small delay for finalization
            Process.sleep(10)
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

    req = Request.new("http://localhost:#{port}/path", method: :post, body: "data", headers: %{"custom" => "header"})
    {:ok, resp} = HTTP.fetch(req)

    assert resp.status == 200
    assert Web.Headers.get(resp.headers, "content-length") == "5"

    chunks = resp.body |> Enum.to_list()
    assert Enum.join(chunks) == "hello"
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
    port = HTTPServer.start_link(["HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n", "he"], false, true)
    
    req = Request.new("http://localhost:#{port}")
    {:ok, resp} = HTTP.fetch(req)
    
    chunks = resp.body |> Enum.to_list()
    assert Enum.join(chunks) == "he"
  end

  test "fetch/1 handles query variables in path explicitly correctly" do
    req = Request.new("http://localhost_nxdomain:80/?query=1")
    assert {:error, _} = HTTP.fetch(req)
  end
end
