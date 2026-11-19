defmodule Web.FetchRulesTest do
  # These tests set the linger time for the application. Thus they cannot run
  # at the same time as other tests.
  use ExUnit.Case, async: false

  use Web

  alias Web.Test.EchoServer

  @linger 100

  setup do
    previous = Application.get_env(:web, :linger)
    Application.put_env(:web, :linger, @linger)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:web, :linger)
      else
        Application.put_env(:web, :linger, previous)
      end
    end)

    {:ok, port: EchoServer.start(self())}
  end

  defp url(port, path, host \\ "localhost"), do: "http://#{host}:#{port}#{path}"

  defp redirect(port, status, location, host \\ "localhost") do
    url(port, "/redirect/#{status}?" <> URI.encode_query(%{"to" => location}), host)
  end

  # Returns the method, the headers, and the body that the server got.
  defp echo(response) do
    [method, header_text, body] =
      response |> Response.text() |> await() |> String.split("\n", parts: 3)

    headers =
      header_text
      |> String.split(";", trim: true)
      |> Map.new(fn pair -> pair |> String.split("=", parts: 2) |> List.to_tuple() end)

    %{method: method, headers: headers, body: body}
  end

  defp settle(baseline, attempts \\ 150) do
    difference = :erlang.system_info(:process_count) - baseline

    if difference <= 10 or attempts == 0 do
      difference
    else
      Process.sleep(20)
      settle(baseline, attempts - 1)
    end
  end

  defp assert_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
  end

  describe "a redirect changes the method" do
    test "301 and 302 change POST to GET and remove the body", %{port: port} do
      for status <- [301, 302] do
        response =
          await(
            fetch(redirect(port, status, "/echo"),
              method: "POST",
              body: "payload",
              headers: %{"content-type" => "text/x-test", "x-keep" => "yes"}
            )
          )

        assert %{method: "GET", body: "", headers: headers} = echo(response)
        refute Map.has_key?(headers, "content-type")
        refute Map.has_key?(headers, "content-length")
        assert headers["x-keep"] == "yes"
      end
    end

    test "301 and 302 keep a method that is not POST", %{port: port} do
      response = await(fetch(redirect(port, 302, "/echo"), method: "PUT", body: "payload"))
      assert %{method: "PUT", body: "payload"} = echo(response)
    end

    test "303 changes each method to GET, but not GET and HEAD", %{port: port} do
      response = await(fetch(redirect(port, 303, "/echo"), method: "PUT", body: "payload"))
      assert %{method: "GET", body: ""} = echo(response)

      response = await(fetch(redirect(port, 303, "/echo")))
      assert %{method: "GET"} = echo(response)
    end

    test "307 and 308 keep the method and the body", %{port: port} do
      for status <- [307, 308] do
        response =
          await(
            fetch(redirect(port, status, "/echo"),
              method: "POST",
              body: "payload",
              headers: %{"content-type" => "text/x-test"}
            )
          )

        assert %{method: "POST", body: "payload", headers: headers} = echo(response)
        assert headers["content-type"] == "text/x-test"
        assert headers["content-length"] == "7"
      end
    end
  end

  describe "a redirect with a request body" do
    test "sends a body from memory again", %{port: port} do
      params = URLSearchParams.new("a=1&b=2")
      response = await(fetch(redirect(port, 307, "/echo"), method: "POST", body: params))
      assert %{method: "POST", body: "a=1&b=2"} = echo(response)

      response = await(fetch(redirect(port, 308, "/echo"), method: "POST", body: ["a", "b"]))
      assert %{method: "POST", body: "ab"} = echo(response)
    end

    test "rejects when the body is a stream", %{port: port} do
      for status <- [307, 308] do
        body = ReadableStream.from(Stream.map(["a", "b"], & &1))
        promise = fetch(redirect(port, status, "/echo"), method: "POST", body: body)
        assert %TypeError{cause: :redirect_stream_body} = catch_exit(await(promise))
      end
    end

    test "follows 303 when the body is a stream", %{port: port} do
      body = ReadableStream.from(Stream.map(["a", "b"], & &1))
      response = await(fetch(redirect(port, 303, "/echo"), method: "POST", body: body))
      assert %{method: "GET", body: ""} = echo(response)
    end
  end

  describe "a redirect and credentials" do
    @credentials %{
      "authorization" => "Bearer secret",
      "cookie" => "session=secret",
      "proxy-authorization" => "Basic secret",
      "x-other" => "kept"
    }

    test "keeps the credential headers for the same origin", %{port: port} do
      response = await(fetch(redirect(port, 302, "/echo"), headers: @credentials))
      assert %{headers: headers} = echo(response)

      assert headers["authorization"] == "Bearer secret"
      assert headers["cookie"] == "session=secret"
      assert headers["proxy-authorization"] == "Basic secret"
    end

    test "removes the credential headers for a different origin", %{port: port} do
      # The same server with a different host name is a different origin.
      location = url(port, "/echo", "127.0.0.1")
      response = await(fetch(redirect(port, 302, location), headers: @credentials))
      assert %{headers: headers} = echo(response)

      refute Map.has_key?(headers, "authorization")
      refute Map.has_key?(headers, "cookie")
      refute Map.has_key?(headers, "proxy-authorization")
      assert headers["x-other"] == "kept"
    end
  end

  describe "the location of a redirect" do
    test "is relative to the URL of the request", %{port: port} do
      response = await(fetch(redirect(port, 302, "../echo?from=relative")))
      assert response.url == url(port, "/echo?from=relative")
      assert %{method: "GET"} = echo(response)
    end

    test "gets the fragment of the request when it has none", %{port: port} do
      response = await(fetch(redirect(port, 302, "/echo") <> "#section"))
      assert response.url == url(port, "/echo#section")

      response = await(fetch(redirect(port, 302, "/echo#other") <> "#section"))
      assert response.url == url(port, "/echo#other")
    end

    test "must have the scheme http or https", %{port: port} do
      promise = fetch(redirect(port, 302, "ftp://example.com/file"))
      assert %TypeError{cause: :redirect_unsupported_scheme} = catch_exit(await(promise))
    end

    test "must be a valid URL", %{port: port} do
      promise = fetch(redirect(port, 302, "http://[not-valid"))
      assert %TypeError{cause: :redirect_invalid_location} = catch_exit(await(promise))
    end
  end

  describe "the response" do
    test "shows if a redirect occurred", %{port: port} do
      assert %Response{redirected: false} = await(fetch(url(port, "/echo")))
      assert %Response{redirected: true} = await(fetch(redirect(port, 302, "/echo")))
    end

    test "stays as it is in the manual mode", %{port: port} do
      response = await(fetch(redirect(port, 302, "/echo"), redirect: "manual"))
      assert response.status == 302
      assert Headers.get(response.headers, "location") == "/echo"
      refute response.redirected
    end
  end

  describe "a response body" do
    test "gives an error when it is shorter than its content length", %{port: port} do
      response = await(fetch(url(port, "/truncated")))
      assert response.status == 200

      # The reader does not get a part of the body as the full body.
      assert %TypeError{message: "The response body is not complete.", cause: cause} =
               catch_exit(await(Response.text(response)))

      assert is_exception(cause)
    end

    test "gives the abort reason when the signal aborts", %{port: port} do
      controller = AbortController.new()
      response = await(fetch(url(port, "/echo"), signal: controller.signal))

      assert AbortController.abort(controller, :stop_now) == :ok
      assert catch_exit(await(Response.text(response))) == :stop_now
    end

    test "gives an error when the process of the signal stops", %{port: port} do
      controller = AbortController.new()
      response = await(fetch(url(port, "/echo"), signal: controller.signal))

      Process.exit(controller.signal.pid, :kill)
      assert %DOMException{name: "AbortError"} = catch_exit(await(Response.text(response)))
    end
  end

  describe "a response body that no process reads" do
    setup do
      Application.put_env(:web, :unread_body_timeout, 150)
      on_exit(fn -> Application.delete_env(:web, :unread_body_timeout) end)
    end

    test "releases its connection after the time limit", %{port: port} do
      response = await(fetch(url(port, "/hold")))
      assert response.status == 200

      assert_receive :server_connection_closed, 2_000
      assert_down(response.body.controller_pid)

      assert %TypeError{} = catch_exit(await(Response.text(response)))
    end

    test "does not leave processes in a process that stays alive", %{port: port} do
      baseline = :erlang.system_info(:process_count)

      for _ <- 1..20 do
        assert %Response{status: 200} = await(fetch(url(port, "/echo")))
        assert %Response{status: 200} = await(fetch(url(port, "/hold")))
      end

      assert settle(baseline) <= 10
    end

    test "is not changed by the time limit when a process reads it", %{port: port} do
      response = await(fetch(url(port, "/echo"), method: "POST", body: "kept"))
      reader = ReadableStream.get_reader(response.body)
      Process.sleep(300)

      assert %{value: value, done: false} = await(ReadableStreamDefaultReader.read(reader))
      assert value =~ "kept"
    end
  end

  describe "a request body" do
    test "from memory has a content length", %{port: port} do
      response = await(fetch(url(port, "/echo"), method: "POST", body: "in memory"))

      assert %{method: "POST", body: "in memory", headers: headers} = echo(response)
      assert headers["content-length"] == "9"
      refute Map.has_key?(headers, "transfer-encoding")
    end

    test "from a stream goes to the server chunk by chunk", %{port: port} do
      parent = self()

      enumerable =
        Stream.resource(
          fn -> :first end,
          fn
            :first ->
              {["first"], :second}

            :second ->
              send(parent, {:source_waits, self()})

              receive do
                :continue -> {["second"], :done}
              end

            :done ->
              {:halt, :done}
          end,
          fn _state -> :ok end
        )

      promise = fetch(url(port, "/echo"), method: "POST", body: ReadableStream.from(enumerable))

      # The server gets the first chunk while the source has more data.
      assert_receive {:server_chunk, "first"}, 2_000
      assert_receive {:source_waits, source}, 2_000
      send(source, :continue)

      assert %{method: "POST", body: "firstsecond", headers: headers} = echo(await(promise))
      assert headers["transfer-encoding"] == "chunked"
    end

    test "is released when the request is complete", %{port: port} do
      request = Request.new(url(port, "/echo"), method: "POST", body: "payload")
      assert %{body: "payload"} = echo(await(fetch(request)))
      assert_down(request.body.controller_pid)
    end

    test "is released when the request fails" do
      request = Request.new("http://localhost:1/", method: "POST", body: "payload")
      catch_exit(await(fetch(request)))
      assert_down(request.body.controller_pid)
    end
  end
end
