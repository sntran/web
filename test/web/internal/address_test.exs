defmodule Web.Internal.AddressTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Web, only: [await: 1]

  alias Web.Internal.Address

  defp ipv4, do: tuple({integer(0..255), integer(0..255), integer(0..255), integer(0..255)})
  defp ipv6, do: map(list_of(integer(0..65_535), length: 8), &List.to_tuple/1)

  describe "ip/1 and endpoint/1" do
    property "give the tuple of each IPv4 address" do
      check all(address <- ipv4()) do
        text = address |> :inet.ntoa() |> to_string()
        assert Address.ip(text) == {:ok, address}
        assert Address.endpoint(text) == address
        assert Address.mint(text) == address
      end
    end

    property "give the tuple of each IPv6 address, with or with no brackets" do
      check all(address <- ipv6()) do
        text = address |> :inet.ntoa() |> to_string()
        assert Address.ip(text) == {:ok, address}
        assert Address.ip("[" <> text <> "]") == {:ok, address}
        assert Address.endpoint("[" <> text <> "]") == address
      end
    end

    test "keep a name, for a lookup by the connect" do
      for host <- ["localhost", "example.com", "1.2.3", "[localhost]", "[::1", "[::1]x"] do
        assert Address.ip(host) == :error
        assert Address.endpoint(host) == String.to_charlist(host)
        assert Address.mint(host) == host
      end
    end
  end

  test "hostname/1 and mint_options/2 remove the brackets of an IPv6 address" do
    assert Address.hostname("[::1]") == "::1"
    assert Address.hostname("example.com") == "example.com"
    assert Address.mint_options("[::1]", mode: :passive) == [hostname: "::1", mode: :passive]
  end

  test "format/2 puts brackets on an IPv6 address" do
    assert Address.format("::1", 80) == "[::1]:80"
    assert Address.format("[::1]", 80) == "[::1]:80"
    assert Address.format("127.0.0.1", 80) == "127.0.0.1:80"
    assert Address.format("localhost", 80) == "localhost:80"
  end

  describe "a connection to an IPv4 address" do
    setup do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listener)

      spawn_link(fn -> serve(listener) end)
      %{port: port}
    end

    test "fetch of an http: URL", %{port: port} do
      response = await(Web.fetch("http://127.0.0.1:#{port}/"))
      assert await(Web.Response.text(response)) == "ok"
    end

    test "fetch of a tcp: URL", %{port: port} do
      response = await(Web.fetch("tcp://127.0.0.1:#{port}"))
      assert await(Web.Response.text(response)) =~ "ok"
    end

    test "Web.connect/2", %{port: port} do
      socket = Web.connect("127.0.0.1:#{port}")
      assert %{remoteAddress: remote} = await(socket.opened)
      assert remote == "127.0.0.1:#{port}"
      await(Web.Socket.close(socket))
    end
  end

  # A machine with no IPv6 refuses the address (`:eafnosupport` or
  # `:econnrefused`). The test then shows that Erlang tried the address:
  # before, the result was `:nxdomain`, with no try.
  describe "a connection to an IPv6 address" do
    setup do
      case :gen_tcp.listen(0, [:binary, :inet6, active: false, reuseaddr: true]) do
        {:ok, listener} ->
          {:ok, port} = :inet.port(listener)
          spawn_link(fn -> serve(listener) end)
          %{port: port, ipv6?: true}

        {:error, _reason} ->
          %{port: 9, ipv6?: false}
      end
    end

    test "fetch of an http: URL", %{port: port, ipv6?: ipv6?} do
      case {ipv6?, Web.Promise.wait(Web.fetch("http://[::1]:#{port}/"))} do
        {true, {:fulfilled, response}} ->
          assert await(Web.Response.text(response)) == "ok"

        {false, {:rejected, %Web.TypeError{cause: %Mint.TransportError{reason: reason}}}} ->
          refute reason == :nxdomain
      end
    end

    test "fetch of a tcp: URL", %{port: port, ipv6?: ipv6?} do
      case {ipv6?, Web.Promise.wait(Web.fetch("tcp://[::1]:#{port}"))} do
        {true, {:fulfilled, response}} ->
          assert await(Web.Response.text(response)) =~ "ok"

        {false, {:rejected, %Web.TypeError{cause: reason}}} ->
          refute reason == :nxdomain
      end
    end

    test "Web.connect/2 with the text of the address, and with a map", %{port: port} = context do
      for address <- ["[::1]:#{port}", %{hostname: "::1", port: port}] do
        socket = Web.connect(address)

        case {context.ipv6?, Web.Promise.wait(socket.opened)} do
          {true, {:fulfilled, %{remoteAddress: remote}}} ->
            assert remote == "[::1]:#{port}"
            await(Web.Socket.close(socket))

          {false, {:rejected, reason}} ->
            refute reason == :nxdomain
        end
      end
    end
  end

  # Each connection gets an HTTP response, then the server closes it.
  defp serve(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        _request = :gen_tcp.recv(socket, 0, 100)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok"
        )

        :gen_tcp.close(socket)
        serve(listener)

      {:error, _closed} ->
        :ok
    end
  end
end
