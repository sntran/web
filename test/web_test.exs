defmodule WebTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Web
  doctest Web.AbortController
  doctest Web.AbortSignal
  doctest Web.Headers
  doctest Web.Request
  doctest Web.Response
  doctest Web.Resolver
  doctest Web.URL
  doctest Web.URLSearchParams

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
end
