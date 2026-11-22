defmodule WebTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Web, only: [await: 1]

  doctest Web
  doctest Web.AbortController
  doctest Web.AbortSignal
  doctest Web.ArrayBuffer
  doctest Web.Uint8Array
  doctest Web.Blob
  doctest Web.CustomEvent
  doctest Web.EventTarget
  doctest Web.Headers
  doctest Web.ByteLengthQueuingStrategy
  doctest Web.CountQueuingStrategy
  doctest Web.Request
  doctest Web.Response
  doctest Web.URL
  doctest Web.URLSearchParams
  doctest Web.DSL

  defmodule MockDispatcher do
    @behaviour Web.Dispatcher

    def fetch(%Web.Request{} = req) when is_struct(req.url, Web.URL) do
      case Web.URL.href(req.url) do
        "mock://success/" ->
          {:ok, Web.Response.__network__(status: 200, url: Web.URL.href(req.url))}

        "mock://error/" ->
          {:error, :simulated_error}

        "mock://type-error/" ->
          {:error, Web.TypeError.exception("the dispatcher refused the request")}

        "mock://dom-exception/" ->
          {:error, Web.DOMException.exception(name: "NetworkError", message: "no network")}

        # A dispatcher throws when it finds that the signal aborted.
        "mock://abort/" ->
          Web.AbortSignal.check!(Web.AbortSignal.abort(:stopped_by_the_caller))
      end
    end
  end

  # The dispatcher of a request is an internal field: the public API has no
  # option for it.
  defp mock(input, dispatcher \\ MockDispatcher, init \\ []),
    do: %{Web.Request.new(input, init) | dispatcher: dispatcher}

  defmodule UsingWeb do
    use Web

    def fetch_with_import(input, init \\ []) do
      fetch(input, init)
    end

    def base64_with_imports(value) do
      encoded = btoa(value)
      {encoded, atob(encoded)}
    end

    def aliases_work? do
      url = URL.new("mock://success")
      request = Request.new(url)
      response = Response.new(nil, status: 200, headers: Headers.new(%{"x-test" => "1"}))

      controller = AbortController.new()
      params = URLSearchParams.new("a=1")

      is_struct(url, URL) and
        is_struct(request, Request) and
        is_struct(response, Response) and
        is_struct(controller.signal, AbortSignal) and
        is_struct(params, URLSearchParams)
    end
  end

  test "Web.fetch uses the dispatcher of the request" do
    assert %Web.Response{ok: true, url: "mock://success/"} =
             await(Web.fetch(mock("mock://success")))

    assert %Web.TypeError{message: "fetch failed", cause: :simulated_error} =
             catch_exit(await(Web.fetch(mock("mock://error"))))
  end

  test "Web.fetch accepts a Web.URL input" do
    assert %Web.Response{ok: true, url: "mock://success/"} =
             await(Web.fetch(mock(Web.URL.new("mock://success"))))
  end

  test "Web.fetch finds the dispatcher of a request that has none" do
    # Resolver.resolve("tcp://localhost:9999") -> Web.Dispatcher.TCP
    # Attempting a real TCP fetch will result in :econnrefused or :nxdomain
    assert _reason = catch_exit(await(Web.fetch("tcp://localhost:59999")))
  end

  test "use Web imports fetch/1 and fetch/2" do
    assert %Web.Response{ok: true, url: "mock://success/"} =
             UsingWeb.fetch_with_import(mock("mock://success")) |> await()

    assert %Web.Response{ok: true, url: "mock://success/"} =
             UsingWeb.fetch_with_import(mock(Web.URL.new("mock://success")), [])
             |> await()
  end

  test "use Web aliases the public Web modules" do
    assert UsingWeb.aliases_work?()
  end

  test "use Web imports atob/1 and btoa/1" do
    assert {"aGVsbG8=", "hello"} = UsingWeb.base64_with_imports("hello")
  end

  test "fetch rejects with the error of a dispatcher that is a TypeError or a DOMException" do
    assert %Web.TypeError{message: "the dispatcher refused the request", cause: nil} =
             catch_exit(await(Web.fetch(mock("mock://type-error/"))))

    assert %Web.DOMException{name: "NetworkError", message: "no network"} =
             catch_exit(await(Web.fetch(mock("mock://dom-exception/"))))
  end

  test "fetch rejects with the abort reason that a dispatcher throws" do
    assert catch_exit(await(Web.fetch(mock("mock://abort/")))) ==
             :stopped_by_the_caller
  end

  test "await returns the value of a promise" do
    response = await(Web.fetch(mock("mock://success/")))
    assert %Web.Response{ok: true, url: "mock://success/"} = response
  end

  test "await exits with the reason of a rejection" do
    assert %Web.TypeError{message: "fetch failed", cause: :simulated_error} =
             catch_exit(await(Web.fetch(mock("mock://error/"))))
  end

  test "await returns a value that is not a promise, as ECMAScript" do
    assert await(:something_else) == :something_else
    # The function needs no require.
    assert Web.await(Web.Promise.resolve(1)) == 1
  end

  test "use Web imports await" do
    defmodule AwaitTest do
      use Web

      def test_await do
        request = %{Web.Request.new("mock://success/") | dispatcher: WebTest.MockDispatcher}
        await(fetch(request))
      end
    end

    response = AwaitTest.test_await()
    assert %Web.Response{ok: true, url: "mock://success/"} = response
  end

  test "new/2 macro creates a new URL" do
    defmodule NewUrlDSL do
      use Web

      def test_new do
        new(URL, "https://example.com")
      end
    end

    url = NewUrlDSL.test_new()
    assert is_struct(url, Web.URL)
    assert url.hostname == "example.com"
  end

  test "new/2 macro creates a new Request" do
    defmodule NewRequestDSL do
      use Web

      def test_new do
        new(Request, "https://example.com")
      end
    end

    req = NewRequestDSL.test_new()
    assert is_struct(req, Web.Request)
    assert req.url.hostname == "example.com"
  end

  test "Web.fetch handles already aborted signals" do
    controller = Web.AbortController.new()
    Web.AbortController.abort(controller)

    assert %Web.DOMException{name: "AbortError"} =
             catch_exit(await(Web.fetch("https://example.com", signal: controller.signal)))

    # Also via Web.URL
    url = Web.URL.new("https://example.com")

    assert %Web.DOMException{name: "AbortError"} =
             catch_exit(await(Web.fetch(url, signal: controller.signal)))

    # Also via Web.Request
    req = Web.Request.new(url, signal: controller.signal)
    assert %Web.DOMException{name: "AbortError"} = catch_exit(await(Web.fetch(req)))
  end

  defmodule RecordingDispatcher do
    @behaviour Web.Dispatcher

    # Tells the test process about each request that gets to the dispatcher.
    def fetch(%Web.Request{} = request) do
      send(request.options[:test], {:dispatched, request})
      {:ok, Web.Response.__network__(status: 200, url: Web.URL.href(request.url))}
    end
  end

  describe "Web.fetch with input that the Request constructor refuses" do
    test "rejects with TypeError and does not raise" do
      for {input, init, message} <- [
            {"", [], ~r/Invalid URL/},
            {"not a url", [], ~r/Invalid URL/},
            {"/relative-only", [], ~r/Invalid URL/},
            {"http://exa mple.com/", [], ~r/Invalid URL/},
            {"https://user:secret@example.com/", [], ~r/includes credentials/},
            {"https://example.com/", [method: "BAD METHOD"], ~r/not a valid HTTP method/},
            {"https://example.com/", [method: "TRACE"], ~r/HTTP method is unsupported/},
            {"https://example.com/", [body: "x"], ~r/GET\/HEAD method cannot have body/},
            {"https://example.com/", [headers: %{"bad name" => "x"}], ~r/Invalid header name/},
            {"https://example.com/", [headers: [{"x", "a\r\nb"}]], ~r/Invalid header value/},
            {"https://example.com/", [redirect: "sometimes"], ~r/not a valid redirect mode/},
            {123, [], ~r/Request input must be/},
            {nil, [], ~r/Request input must be/},
            {"https://example.com/", %{}, ~r/Request init must be a keyword list/}
          ] do
        promise = Web.fetch(input, init)
        assert %Web.Promise{} = promise

        assert {:rejected, %Web.TypeError{message: text, cause: nil}} = Web.Promise.wait(promise)
        assert text =~ message
      end
    end

    test "makes no connection" do
      request = mock("mock://success/", RecordingDispatcher, test: self())

      for extra <- [
            [method: "BAD METHOD"],
            [body: "x"],
            [headers: %{"bad name" => "x"}],
            [redirect: "sometimes"]
          ] do
        assert {:rejected, %Web.TypeError{}} =
                 Web.Promise.wait(Web.fetch(request, extra))
      end

      refute_receive {:dispatched, _request}, 50

      # The same dispatcher gets a request that is valid.
      assert %Web.Response{status: 200} = await(Web.fetch(request))
      assert_receive {:dispatched, %Web.Request{method: "GET"}}
    end

    test "rejects when the body of the request is already read, and makes no connection" do
      init = [test: self(), method: "POST"]

      for body <- ["in memory", Web.ReadableStream.from(["a", "b"])] do
        request =
          mock("mock://success/", RecordingDispatcher, init ++ [body: body, duplex: "half"])

        assert is_binary(await(Web.Request.text(request)))

        assert {:rejected, %Web.TypeError{message: "Request body is already used"}} =
                 Web.Promise.wait(Web.fetch(request))

        assert_raise Web.TypeError, "Request body is already used", fn ->
          Web.Request.new(request, method: "PUT")
        end
      end

      refute_receive {:dispatched, _request}, 50
    end

    test "rejects when the body of the request has a reader" do
      request =
        mock("mock://success/", RecordingDispatcher,
          test: self(),
          method: "POST",
          body: Web.ReadableStream.from(["a"]),
          duplex: "half"
        )

      reader = Web.ReadableStream.get_reader(request.body)

      assert {:rejected, %Web.TypeError{message: "Request body is locked"}} =
               Web.Promise.wait(Web.fetch(request))

      refute_receive {:dispatched, _request}, 50

      # The request can be sent after the lock is released.
      Web.ReadableStreamDefaultReader.release_lock(reader)
      assert %Web.Response{status: 200} = await(Web.fetch(request))
      assert_receive {:dispatched, _request}
    end

    test "applies init to a request that is the input" do
      request = mock("mock://success/", RecordingDispatcher, test: self())

      assert %Web.Response{status: 200} =
               await(Web.fetch(request, method: "post", headers: %{"x-test" => "1"}, body: "x"))

      assert_receive {:dispatched, %Web.Request{method: "POST"} = dispatched}
      assert Web.Headers.get(dispatched.headers, "x-test") == "1"

      assert {:rejected, %Web.TypeError{message: message}} =
               Web.Promise.wait(Web.fetch(request, body: "x"))

      assert message =~ "GET/HEAD method cannot have body"
    end
  end

  test "Web.btoa and Web.atob round-trip latin1 byte strings" do
    assert Web.btoa("hello") == "aGVsbG8="
    assert Web.atob("aGVsbG8=") == "hello"
    assert Web.atob(" Y Q==\n") == "a"
    assert Web.atob("YQ") == "a"
    assert Web.atob(Web.btoa("ÿ")) == "ÿ"
  end

  test "Web.btoa rejects codepoints outside the latin1 range" do
    assert_raise Web.TypeError, ~r/outside the Latin1 range/, fn ->
      Web.btoa("snowman ☃")
    end
  end

  test "Web.atob rejects malformed input" do
    assert_raise Web.TypeError, ~r/malformed base64 input/, fn ->
      Web.atob("abcde")
    end

    assert_raise Web.TypeError, ~r/malformed base64 input/, fn ->
      Web.atob("ab=c")
    end

    assert_raise Web.TypeError, ~r/malformed base64 input/, fn ->
      Web.atob("A===")
    end
  end

  test "Web.atob accepts empty input" do
    assert Web.atob("") == ""
  end
end
