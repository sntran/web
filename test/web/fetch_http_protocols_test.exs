defmodule Web.FetchHTTPProtocolsTest do
  # The setting `:http_protocols`, and the status text of a response for
  # each HTTP version. The tests start the connection pools again, thus they
  # do not run at the same time as other tests.
  use ExUnit.Case, async: false
  use Web

  alias Web.Dispatcher.HTTP

  defmodule Server do
    @moduledoc false
    import Plug.Conn

    def init(options), do: options

    # Gives the HTTP version, the method, and the body that the server got.
    def call(conn, _options) do
      {:ok, body, conn} = read_body(conn)
      status = if conn.request_path == "/missing", do: 404, else: 200

      conn
      |> put_resp_header("x-http-version", to_string(get_http_protocol(conn)))
      |> send_resp(status, "#{conn.method}:#{body}")
    end
  end

  setup_all do
    {:ok, server} = Bandit.start_link(plug: Server, scheme: :http, port: 0, startup_log: false)
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    %{base: "http://localhost:#{port}"}
  end

  # Sets the protocols and starts the pools again.
  defp use_protocols(protocols) do
    previous = Application.get_env(:web, :http_protocols)
    Application.put_env(:web, :http_protocols, protocols)
    restart_pools()

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:web, :http_protocols),
        else: Application.put_env(:web, :http_protocols, previous)

      restart_pools()
    end)
  end

  defp restart_pools do
    :ok = Supervisor.terminate_child(Web.Supervisor, Web.Finch)
    {:ok, _pid} = Supervisor.restart_child(Web.Supervisor, Web.Finch)
  end

  defp version(response), do: Headers.get(response.headers, "x-http-version", nil)

  describe "the default" do
    test "is HTTP/1.1, and the status text comes from the table", %{base: base} do
      assert Web.Application.http_protocols() == [:http1]

      response = await(fetch(base <> "/"))
      assert {response.status, response.status_text, version(response)} == {200, "OK", "HTTP/1.1"}

      response = await(fetch(base <> "/missing"))
      assert {response.status, response.status_text} == {404, "Not Found"}
    end
  end

  describe "the setting [:http2]" do
    setup do
      use_protocols([:http2])
    end

    test "uses HTTP/2, and gives the empty status text", %{base: base} do
      assert Web.Application.http_protocols() == [:http2]

      response = await(fetch(base <> "/"))
      assert {response.status, response.status_text, version(response)} == {200, "", "HTTP/2"}
      assert response.ok
      assert await(Response.text(response)) == "GET:"

      response = await(fetch(base <> "/missing"))
      assert {response.status, response.status_text, response.ok} == {404, "", false}
    end

    test "sends a body from memory and a body from a stream", %{base: base} do
      response = await(fetch(base <> "/", method: "POST", body: "payload"))
      assert version(response) == "HTTP/2"
      assert await(Response.text(response)) == "POST:payload"

      stream = ReadableStream.from(["pay", Uint8Array.from("load")])
      response = await(fetch(base <> "/", method: "POST", body: stream, duplex: "half"))
      assert await(Response.text(response)) == "POST:payload"
    end

    test "gives the body as Uint8Array chunks", %{base: base} do
      response = await(fetch(base <> "/", method: "PUT", body: "data"))
      chunks = Enum.to_list(response.body)

      assert Enum.all?(chunks, &match?(%Uint8Array{}, &1))
      assert Enum.map_join(chunks, &Uint8Array.to_binary/1) == "PUT:data"
    end
  end

  describe "the setting with the two versions" do
    setup do
      # The sequence and a second occurrence of a version have no effect.
      use_protocols([:http2, :http1, :http2])
    end

    test "uses HTTP/1.1 for a connection with no TLS, with the text of the table", %{base: base} do
      assert Web.Application.http_protocols() == [:http1, :http2]

      response = await(fetch(base <> "/"))
      assert {response.status, response.status_text, version(response)} == {200, "OK", "HTTP/1.1"}
    end

    test "gives the empty status text for a TLS connection, which can use HTTP/2" do
      assert HTTP.status_text(200, URL.new("https://example.com/")) == ""
      assert HTTP.status_text(200, URL.new("http://example.com/")) == "OK"
    end
  end

  describe "a setting that is not valid" do
    test "stops the start of the pools with an ArgumentError" do
      previous = Application.get_env(:web, :http_protocols)

      on_exit(fn ->
        if previous == nil,
          do: Application.delete_env(:web, :http_protocols),
          else: Application.put_env(:web, :http_protocols, previous)
      end)

      for value <- [[], [:http3], :spdy, [:http1, :other]] do
        Application.put_env(:web, :http_protocols, value)

        assert_raise ArgumentError, ~r/The setting :http_protocols of :web must be/, fn ->
          Web.Application.start_finch()
        end
      end

      # The pools that run are not changed.
      assert Web.Application.http_protocols() == [:http1]
    end

    test "accepts one version that is not in a list" do
      use_protocols(:http2)
      assert Web.Application.http_protocols() == [:http2]
    end
  end
end
