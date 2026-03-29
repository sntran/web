defmodule Web.Dispatcher.TCPTest do
  use ExUnit.Case, async: true

  alias Web.Request
  alias Web.Dispatcher.TCP

  defmodule TCPServer do
    def start_link(response_data \\ "hello\nworld", chunking \\ false, drop \\ false) do
      parent = self()
      Task.start_link(fn ->
        # Port 0 lets the OS pick an available port
        {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
        {:ok, port} = :inet.port(listen_socket)
        send(parent, {:port, port})

        {:ok, socket} = :gen_tcp.accept(listen_socket)
        
        if drop do
           :gen_tcp.close(socket)
           :gen_tcp.close(listen_socket)
        else
          if chunking do
            :gen_tcp.send(socket, "he")
            :gen_tcp.send(socket, "llo")
          else
            :gen_tcp.send(socket, response_data)
          end

          :gen_tcp.close(socket)
          :gen_tcp.close(listen_socket)
        end
      end)
      
      receive do
        {:port, port} -> port
      after
        1000 -> raise "TCPServer failed to start"
      end
    end
  end

  test "fetch/1 handles standard tcp scheme and yields chunks dynamically" do
    port = TCPServer.start_link("", true)

    req = Request.new("tcp://localhost:#{port}", body: "sent body payload")
    {:ok, resp} = TCP.fetch(req)

    assert resp.status == 200
    chunks = resp.body |> Enum.to_list()
    assert Enum.join(chunks) == "hello"
  end

  test "fetch/1 handles remote identifier style URL correctly without body" do
    port = TCPServer.start_link("remote_resp", false)

    req = Request.new("remote:localhost:#{port}/path-item")
    {:ok, resp} = TCP.fetch(req)
    
    chunks = resp.body |> Enum.to_list()
    assert Enum.join(chunks) == "remote_resp"
  end

  test "fetch/1 parses missing port accurately defaulting to 80 erroring as appropriate" do
    req = Request.new("tcp://localhost_nxdomain/path")
    assert {:error, _} = TCP.fetch(req)
  end

  test "fetch/1 streaming yields appropriately on clean closed termination" do
    port = TCPServer.start_link("data", false, true) # Drop immediately

    req = Request.new("tcp://localhost:#{port}")
    {:ok, resp} = TCP.fetch(req)
    chunks = resp.body |> Enum.to_list()
    assert chunks == []
  end
end
