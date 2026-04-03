defmodule WebTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Web, only: [await: 1]

  doctest Web
  doctest Web.AbortController
  doctest Web.AbortSignal
  doctest Web.Body
  doctest Web.Headers
  doctest Web.Request
  doctest Web.Response
  doctest Web.Resolver
  doctest Web.URL
  doctest Web.URLSearchParams
  doctest Web.DSL

  defmodule MockDispatcher do
    @behaviour Web.Dispatcher

    def fetch(%Web.Request{} = req) when is_struct(req.url, Web.URL) do
      case Web.URL.href(req.url) do
        "mock://success/" ->
          {:ok, Web.Response.new(status: 200, url: Web.URL.href(req.url))}

        "mock://error/" ->
          {:error, :simulated_error}
      end
    end
  end

  defmodule UsingWeb do
    use Web

    def fetch_with_import(input, init \\ []) do
      fetch(input, init)
    end

    def aliases_work? do
      url = URL.new("mock://success")
      request = Request.new(url, dispatcher: WebTest.MockDispatcher)

      response =
        Response.new(status: 200, headers: Headers.new(%{"x-test" => "1"}), url: URL.href(url))

      controller = AbortController.new()
      params = URLSearchParams.new("a=1")

      is_struct(url, URL) and
        is_struct(request, Request) and
        is_struct(response, Response) and
        is_struct(controller.signal, AbortSignal) and
        is_struct(params, URLSearchParams)
    end
  end

  test "Web.fetch routes to provided dispatcher directly via options" do
    assert {:ok, %Web.Response{ok: true, url: "mock://success/"}} =
             Web.fetch("mock://success", dispatcher: MockDispatcher)

    assert {:error, :simulated_error} =
             Web.fetch("mock://error", dispatcher: MockDispatcher)
  end

  test "Web.fetch accepts a Web.URL input" do
    assert {:ok, %Web.Response{ok: true, url: "mock://success/"}} =
             Web.fetch(Web.URL.new("mock://success"), dispatcher: MockDispatcher)
  end

  test "Web.fetch routes to resolved dispatcher when missing from options" do
    # Resolver.resolve("tcp://localhost:9999") -> Web.Dispatcher.TCP
    # Attempting a real TCP fetch will result in :econnrefused or :nxdomain
    assert {:error, _} = Web.fetch("tcp://localhost:59999")
  end

  test "use Web imports fetch/1 and fetch/2" do
    assert {:ok, %Web.Response{ok: true, url: "mock://success/"}} =
             UsingWeb.fetch_with_import("mock://success", dispatcher: MockDispatcher)

    assert {:ok, %Web.Response{ok: true, url: "mock://success/"}} =
             UsingWeb.fetch_with_import(Web.URL.new("mock://success"),
               dispatcher: MockDispatcher
             )
  end

  test "use Web aliases the public Web modules" do
    assert UsingWeb.aliases_work?()
  end

  test "await macro returns value on {:ok, value}" do
    response = await(Web.fetch("mock://success/", dispatcher: MockDispatcher))
    assert %Web.Response{ok: true, url: "mock://success/"} = response
  end

  test "await macro raises on {:error, reason}" do
    assert_raise RuntimeError, ~r/await: fetch failed: :simulated_error/, fn ->
      await(Web.fetch("mock://error/", dispatcher: MockDispatcher))
    end
  end

  test "await macro raises on unexpected result" do
    assert_raise RuntimeError, ~r/await: unexpected result: :something_else/, fn ->
      await(:something_else)
    end
  end

  test "use Web imports await macro" do
    defmodule AwaitTest do
      use Web

      def test_await do
        await(fetch("mock://success/", dispatcher: WebTest.MockDispatcher))
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
    assert {:error, :aborted} = Web.fetch("https://example.com", signal: controller.signal)

    # Also via Web.URL
    url = Web.URL.new("https://example.com")
    assert {:error, :aborted} = Web.fetch(url, signal: controller.signal)

    # Also via Web.Request
    req = Web.Request.new(url, signal: controller.signal)
    assert {:error, :aborted} = Web.fetch(req)
  end
end
